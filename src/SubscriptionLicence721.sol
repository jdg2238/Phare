// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {ISubscriptionLicence721} from "./interfaces/ISubscriptionLicence721.sol";
import {LicenceNegotiation} from "./LicenceNegotiation.sol";
import {FeeSchedule} from "./FeeSchedule.sol";
import {
    Licence,
    LicenceTerms,
    LicenceState,
    BindingTrigger,
    RescissionGround,
    AuthorisedParty,
    PaymentRule,
    ProposalState
} from "./Types.sol";

/// @title SubscriptionLicence721 — LEVEL 3/4 of the dependency graph (§5)
/// @notice One ERC-721 token per executed agreement. Holds the immutable LicenceTerms (I11), the
///         §8.2 state machine, the cl. 2.6 authorised-party list, the cl. 7 assignment hook, cl. 9.1
///         notice and computed expiry, and cl. 5.5 rescission on the carve-out grounds only.
///
///         Deliberately absent (§8.2): no SUSPENDED, no licensor-initiated TERMINATED, no RENEWED-in-place,
///         no "pause" button. The Licensor's only exit is {rescind}, which requires the RESOLVER role
///         (OPEN-Q9: a 2-of-3 of licensor + licensee + PHARE), not the licensor key.
contract SubscriptionLicence721 is
    ISubscriptionLicence721,
    Initializable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    // ---------------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------------
    bytes32 public constant PLATFORM_ROLE = keccak256("PLATFORM_ROLE"); // PHARE — observes downloads (cl. 6.3)
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE"); // OPEN-Q9 multisig — rescission
    bytes32 public constant FEE_ROLE = keccak256("FEE_ROLE"); // FeeSchedule — payment binding + hold
    bytes32 public constant LEDGER_ROLE = keccak256("LEDGER_ROLE"); // ClearanceLedger — first-sync binding
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint8 internal constant TRIGGER_NONE = type(uint8).max;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    struct Consent {
        address to;
        uint64 validUntil;
    }

    LicenceNegotiation public negotiation;
    FeeSchedule public feeSchedule;
    uint256 public nextTokenId;

    mapping(uint256 tokenId => Licence) private _licences;
    mapping(uint256 tokenId => bool) private _paymentHold; // OPEN-Q3
    mapping(uint256 tokenId => mapping(address => bool)) private _affiliates; // cl. 7
    mapping(uint256 tokenId => mapping(address => AuthorisedParty)) private _authorised; // cl. 2.6
    mapping(uint256 tokenId => Consent) private _consents; // cl. 7
    mapping(uint256 proposalId => uint256 tokenId) public tokenOfProposal;

    // ---------------------------------------------------------------------
    // Events (beyond the §7 interface)
    // ---------------------------------------------------------------------
    event LicenceIssued(uint256 indexed tokenId, address indexed licensor, address indexed licensee, bytes32 termsHash);
    event AffiliateSet(uint256 indexed tokenId, address affiliate, bool isAffiliate);
    event PaymentHoldSet(uint256 indexed tokenId, bool onHold);
    event Renewed(uint256 indexed oldTokenId, uint256 indexed newTokenId);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error ZeroAddress();
    error AlreadySet();
    error LicenceUnknown(uint256 tokenId);
    error ProposalNotAccepted(uint256 proposalId);
    error ProposalExpired(uint256 proposalId);
    error ProposalAlreadyMinted(uint256 proposalId, uint256 tokenId);
    error NotLicensee(uint256 tokenId, address caller);
    error NotLicensor(uint256 tokenId, address caller);
    error NotAParty(uint256 tokenId, address caller);
    error InvalidTrigger(uint8 trigger);
    error TriggerNotAuthorised(uint8 trigger, address caller);
    error WrongState(uint256 tokenId, LicenceState state);
    error InvalidRole(uint8 role);
    error TransferNotPermitted(uint256 tokenId, address to); // cl. 7 "null and void"
    error ConsentExpiry(uint64 validUntil);
    error NoticePeriodRunning(uint256 tokenId, uint64 effectiveAt); // I17
    error InvalidRescissionGround(uint8 ground); // I15
    error RescissionGroundUnresolved(uint8 ground); // OPEN-Q6
    error PartiesMismatch(uint256 proposalId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, LicenceNegotiation negotiation_) external initializer {
        if (admin == address(0) || address(negotiation_) == address(0)) revert ZeroAddress();
        __ERC721_init("PHARE Sync Licence", "PHARE-SL");
        __AccessControl_init();
        negotiation = negotiation_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    /// @notice Wire the FeeSchedule once; it receives FEE_ROLE.
    function setFeeSchedule(FeeSchedule feeSchedule_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(feeSchedule) != address(0)) revert AlreadySet();
        if (address(feeSchedule_) == address(0)) revert ZeroAddress();
        feeSchedule = feeSchedule_;
        _grantRole(FEE_ROLE, address(feeSchedule_));
    }

    // ---------------------------------------------------------------------
    // LEVEL 3 — binding (cl. 6.3)
    // ---------------------------------------------------------------------

    /// @notice Mint the token for an accepted proposal AND record the binding event in one call.
    /// @dev Records exactly one BindingTrigger and boundAt (I18). Caller must be entitled to assert
    ///      that trigger — see {_authoriseTrigger}.
    function mintFromProposal(uint256 proposalId, uint8 trigger) external override returns (uint256 tokenId) {
        tokenId = _mintLicence(proposalId, 0);
        _bind(tokenId, trigger, msg.sender);
    }

    /// @notice Mint the token in ISSUED ("sent to licensee; not yet bound"). Binding follows via {bind}
    ///         (written acceptance / download), an instalment settlement (payment), or the first
    ///         declareSync (first sync). Lapses at terms.proposalExpiry if nothing binds it.
    function issue(uint256 proposalId) external returns (uint256 tokenId) {
        LicenceNegotiation.Proposal memory p = negotiation.getProposal(proposalId);
        if (msg.sender != p.licensor && msg.sender != p.licensee && !hasRole(PLATFORM_ROLE, msg.sender)) {
            revert NotAParty(0, msg.sender);
        }
        tokenId = _mintLicence(proposalId, 0);
    }

    /// @notice Record the observable event that bound the Licensee (cl. 6.3). ISSUED → ACTIVE.
    function bind(uint256 tokenId, uint8 trigger) external {
        if (_computed(tokenId) != LicenceState.ISSUED) revert WrongState(tokenId, _computed(tokenId));
        _bind(tokenId, trigger, msg.sender);
    }

    /// @notice Renewal is a new token (§8.2): mint from a fresh accepted proposal, linked via renewalOf.
    function mintRenewal(uint256 oldTokenId, uint256 proposalId, uint8 trigger) external returns (uint256 tokenId) {
        _requireExists(oldTokenId);
        tokenId = _mintLicence(proposalId, oldTokenId);
        _bind(tokenId, trigger, msg.sender);
        emit Renewed(oldTokenId, tokenId);
    }

    // ---------------------------------------------------------------------
    // State (§8.2) — expiry and payment hold are computed, persisted lazily
    // ---------------------------------------------------------------------

    /// @inheritdoc ISubscriptionLicence721
    function state(uint256 tokenId) external view override returns (uint8) {
        _requireExists(tokenId);
        return uint8(_computed(tokenId));
    }

    /// @inheritdoc ISubscriptionLicence721
    /// @dev canDeclare == state ∈ {ACTIVE, NOTICE_GIVEN} && !paymentHold && now ∈ [syncTermStart, syncTermEnd]
    function canDeclare(uint256 tokenId) public view override returns (bool) {
        Licence storage l = _licences[tokenId];
        if (l.tokenId == 0) return false;
        LicenceState s = _computed(tokenId);
        if (s != LicenceState.ACTIVE && s != LicenceState.NOTICE_GIVEN) return false;
        if (_paymentHold[tokenId]) return false; // OPEN-Q3
        return block.timestamp >= l.terms.syncTermStart && block.timestamp <= l.terms.syncTermEnd;
    }

    /// @notice Persist a computed terminal state (EXPIRED / LAPSED) and emit for indexers. Anyone may call.
    function touch(uint256 tokenId) public returns (LicenceState) {
        Licence storage l = _licences[tokenId];
        if (l.tokenId == 0) revert LicenceUnknown(tokenId);
        LicenceState stored = l.state;
        LicenceState now_ = _computed(tokenId);
        if (now_ != stored && _isTerminal(now_)) {
            l.state = now_;
            l.terminatedAt = uint64(block.timestamp);
            emit LicenceStateChanged(tokenId, uint8(stored), uint8(now_));
            if (now_ == LicenceState.LAPSED) {
                _burn(tokenId); // §8.2: token burned; proposal may be re-issued. Licence record kept.
            }
        }
        return now_;
    }

    // ---------------------------------------------------------------------
    // cl. 2.6 — authorised parties
    // ---------------------------------------------------------------------

    /// @inheritdoc ISubscriptionLicence721
    function setAuthorisedParty(uint256 tokenId, address party, uint8 role, bool active) external override {
        _onlyLicensee(tokenId);
        if (party == address(0)) revert ZeroAddress();
        if (role == 0 || role > 3) revert InvalidRole(role);
        AuthorisedParty storage ap = _authorised[tokenId][party];
        ap.party = party;
        ap.role = role;
        ap.active = active;
        emit AuthorisedPartySet(tokenId, party, role, active);
    }

    /// @notice Same as {setAuthorisedParty} with an off-chain party identifier (hash only — I20).
    function setAuthorisedPartyWithId(uint256 tokenId, address party, uint8 role, bytes32 partyId, bool active)
        external
    {
        _onlyLicensee(tokenId);
        if (party == address(0)) revert ZeroAddress();
        if (role == 0 || role > 3) revert InvalidRole(role);
        _authorised[tokenId][party] = AuthorisedParty({party: party, role: role, partyId: partyId, active: active});
        emit AuthorisedPartySet(tokenId, party, role, active);
    }

    /// @inheritdoc ISubscriptionLicence721
    function isAuthorised(uint256 tokenId, address who) public view override returns (bool) {
        Licence storage l = _licences[tokenId];
        if (l.tokenId == 0) return false;
        return who == l.licensee || _authorised[tokenId][who].active;
    }

    function authorisedParty(uint256 tokenId, address who) external view returns (AuthorisedParty memory) {
        return _authorised[tokenId][who];
    }

    // ---------------------------------------------------------------------
    // cl. 7 — assignment
    // ---------------------------------------------------------------------

    /// @inheritdoc ISubscriptionLicence721
    function setAffiliate(uint256 tokenId, address affiliate, bool flag) external override {
        _onlyLicensee(tokenId);
        if (affiliate == address(0)) revert ZeroAddress();
        _affiliates[tokenId][affiliate] = flag;
        emit AffiliateSet(tokenId, affiliate, flag);
    }

    function isAffiliate(uint256 tokenId, address who) external view returns (bool) {
        return _affiliates[tokenId][who];
    }

    /// @inheritdoc ISubscriptionLicence721
    function consentToTransfer(uint256 tokenId, address to, uint64 validUntil) external override {
        _onlyLicensor(tokenId);
        if (to == address(0)) revert ZeroAddress();
        if (validUntil <= block.timestamp) revert ConsentExpiry(validUntil);
        _consents[tokenId] = Consent({to: to, validUntil: validUntil});
        emit TransferConsented(tokenId, to, validUntil);
    }

    function transferConsent(uint256 tokenId) external view returns (address to, uint64 validUntil) {
        Consent storage c = _consents[tokenId];
        return (c.to, c.validUntil);
    }

    /// @dev cl. 7 implemented literally: to an affiliate → free (I7b); to an address with unexpired
    ///      licensor consent → ok (consent consumed); otherwise the transfer is "null and void" (I7).
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            if (!_affiliates[tokenId][to]) {
                Consent storage c = _consents[tokenId];
                if (c.to != to || c.validUntil < block.timestamp) revert TransferNotPermitted(tokenId, to);
                delete _consents[tokenId];
            }
            _licences[tokenId].licensee = to;
        }
        return super._update(to, tokenId, auth);
    }

    // ---------------------------------------------------------------------
    // cl. 9 — exit (licensee only; the licensor has no termination right)
    // ---------------------------------------------------------------------

    /// @inheritdoc ISubscriptionLicence721
    function giveNotice(uint256 tokenId) external override {
        _onlyLicensee(tokenId);
        LicenceState s = _computed(tokenId);
        if (s != LicenceState.ACTIVE && s != LicenceState.PAYMENT_HOLD) revert WrongState(tokenId, s);
        Licence storage l = _licences[tokenId];
        LicenceState prev = l.state;
        l.state = LicenceState.NOTICE_GIVEN;
        l.noticeGivenAt = uint64(block.timestamp);
        uint64 effectiveAt = uint64(block.timestamp + uint256(l.terms.licenseeNoticeDays) * 1 days);
        emit NoticeGiven(tokenId, l.noticeGivenAt, effectiveAt);
        emit LicenceStateChanged(tokenId, uint8(prev), uint8(LicenceState.NOTICE_GIVEN));
    }

    /// @inheritdoc ISubscriptionLicence721
    function finaliseTermination(uint256 tokenId) external override {
        LicenceState s = touch(tokenId); // an expiry that arrived first wins (equivalent for cl. 9.2)
        if (s != LicenceState.NOTICE_GIVEN) revert WrongState(tokenId, s);
        Licence storage l = _licences[tokenId];
        uint64 effectiveAt = uint64(l.noticeGivenAt + uint256(l.terms.licenseeNoticeDays) * 1 days);
        if (block.timestamp < effectiveAt) revert NoticePeriodRunning(tokenId, effectiveAt); // I17
        l.state = LicenceState.TERMINATED;
        l.terminatedAt = uint64(block.timestamp);
        emit LicenceStateChanged(tokenId, uint8(LicenceState.NOTICE_GIVEN), uint8(LicenceState.TERMINATED));
    }

    /// @inheritdoc ISubscriptionLicence721
    /// @dev cl. 5.5 — only the four carve-out grounds exist (I15); BREACH_CL_8_SIC is rejected until
    ///      OPEN-Q6 is resolved. Existing declarations are untouched (OPEN-Q9: prospective only).
    function rescind(uint256 tokenId, uint8 ground, bytes32 evidenceHash) external override onlyRole(RESOLVER_ROLE) {
        if (ground > uint8(RescissionGround.BREACH_CL_8_SIC)) revert InvalidRescissionGround(ground);
        if (ground == uint8(RescissionGround.BREACH_CL_8_SIC)) revert RescissionGroundUnresolved(ground); // OPEN-Q6
        LicenceState s = touch(tokenId);
        if (_isTerminal(s)) revert WrongState(tokenId, s);
        Licence storage l = _licences[tokenId];
        LicenceState prev = l.state;
        l.state = LicenceState.RESCINDED;
        l.terminatedAt = uint64(block.timestamp);
        emit Rescinded(tokenId, ground, evidenceHash);
        emit LicenceStateChanged(tokenId, uint8(prev), uint8(LicenceState.RESCINDED));
    }

    // ---------------------------------------------------------------------
    // cl. 6.1 — variation: a new accepted proposal → a new token; old token closed and linked
    // ---------------------------------------------------------------------

    /// @inheritdoc ISubscriptionLicence721
    /// @dev Terms are immutable (I11); a variation is a new token. Outstanding instalments on the old
    ///      token are NOT cancelled (cl. 2.4 / 6.2).
    function supersede(uint256 tokenId, uint256 newProposalId) external override returns (uint256 newTokenId) {
        Licence storage old = _licences[tokenId];
        if (old.tokenId == 0) revert LicenceUnknown(tokenId);
        if (msg.sender != old.licensor && msg.sender != old.licensee) revert NotAParty(tokenId, msg.sender);
        LicenceState s = touch(tokenId);
        if (_isTerminal(s)) revert WrongState(tokenId, s);

        LicenceNegotiation.Proposal memory p = negotiation.getProposal(newProposalId);
        if (p.licensor != old.licensor || p.licensee != old.licensee) revert PartiesMismatch(newProposalId);

        newTokenId = _mintLicence(newProposalId, 0);
        // Both signatures are on the accepted variation (cl. 6.1) — that is written acceptance.
        _bindUnchecked(newTokenId, BindingTrigger.WRITTEN_ACCEPTANCE);

        LicenceState prev = old.state;
        old.supersededBy = newTokenId;
        old.state = LicenceState.TERMINATED;
        old.terminatedAt = uint64(block.timestamp);
        emit Superseded(tokenId, newTokenId);
        emit LicenceStateChanged(tokenId, uint8(prev), uint8(LicenceState.TERMINATED));
    }

    // ---------------------------------------------------------------------
    // Hooks for FeeSchedule (OPEN-Q3 payment hold)
    // ---------------------------------------------------------------------

    function setPaymentHold(uint256 tokenId) external onlyRole(FEE_ROLE) {
        _requireExists(tokenId);
        if (_paymentHold[tokenId]) return;
        LicenceState before = _computed(tokenId);
        _paymentHold[tokenId] = true;
        emit PaymentHoldSet(tokenId, true);
        if (before == LicenceState.ACTIVE) {
            emit LicenceStateChanged(tokenId, uint8(LicenceState.ACTIVE), uint8(LicenceState.PAYMENT_HOLD));
        }
    }

    function clearPaymentHold(uint256 tokenId) external onlyRole(FEE_ROLE) {
        _requireExists(tokenId);
        if (!_paymentHold[tokenId]) return;
        LicenceState before = _computed(tokenId);
        _paymentHold[tokenId] = false;
        emit PaymentHoldSet(tokenId, false);
        if (before == LicenceState.PAYMENT_HOLD) {
            emit LicenceStateChanged(tokenId, uint8(LicenceState.PAYMENT_HOLD), uint8(LicenceState.ACTIVE));
        }
    }

    function inPaymentHold(uint256 tokenId) external view returns (bool) {
        return _paymentHold[tokenId];
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Full licence record with the computed state.
    function licenceOf(uint256 tokenId) external view returns (Licence memory l) {
        _requireExists(tokenId);
        l = _licences[tokenId];
        l.state = _computed(tokenId);
    }

    function termsOf(uint256 tokenId) external view returns (LicenceTerms memory) {
        _requireExists(tokenId);
        return _licences[tokenId].terms;
    }

    function licensorOf(uint256 tokenId) external view returns (address) {
        _requireExists(tokenId);
        return _licences[tokenId].licensor;
    }

    function licenseeOf(uint256 tokenId) external view returns (address) {
        _requireExists(tokenId);
        return _licences[tokenId].licensee;
    }

    function paymentTermsOf(uint256 tokenId) external view returns (PaymentRule rule, uint32 dueDays, bytes3 currency) {
        _requireExists(tokenId);
        LicenceTerms storage t = _licences[tokenId].terms;
        return (t.paymentRule, t.dueDaysAfterInvoice, t.currency);
    }

    /// @dev The HCS negotiation trail referenced from the terms is non-contractual (OPEN-Q11).
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _licences[tokenId].terms.termsURI;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _mintLicence(uint256 proposalId, uint256 renewalOf) private returns (uint256 tokenId) {
        LicenceNegotiation.Proposal memory p = negotiation.getProposal(proposalId);
        if (p.state != ProposalState.ACCEPTED) revert ProposalNotAccepted(proposalId);
        if (p.tokenId != 0) revert ProposalAlreadyMinted(proposalId, p.tokenId);
        if (block.timestamp > p.terms.proposalExpiry) revert ProposalExpired(proposalId);

        tokenId = ++nextTokenId;
        Licence storage l = _licences[tokenId];
        l.tokenId = tokenId;
        l.licensor = p.licensor;
        l.licensee = p.licensee;
        l.terms = p.terms; // immutable from here on (I11): no setter exists
        l.state = LicenceState.ISSUED;
        l.renewalOf = renewalOf;
        tokenOfProposal[proposalId] = tokenId;

        negotiation.markMinted(proposalId, tokenId);
        feeSchedule.createInstalments(tokenId, p.fees); // I1 — instalments exist for every minted licence
        _mint(p.licensee, tokenId);
        emit LicenceIssued(tokenId, p.licensor, p.licensee, p.terms.termsHash);
    }

    function _bind(uint256 tokenId, uint8 trigger, address caller) private {
        if (trigger > uint8(BindingTrigger.COUNTERSIGNATURE)) revert InvalidTrigger(trigger);
        BindingTrigger t = BindingTrigger(trigger);
        if (!_authoriseTrigger(tokenId, t, caller)) revert TriggerNotAuthorised(trigger, caller);
        _bindUnchecked(tokenId, t);
    }

    /// @dev Who may assert which cl. 6.3 event:
    ///      WRITTEN_ACCEPTANCE — the licensee; PAYMENT — FeeSchedule; FIRST_SYNC — ClearanceLedger;
    ///      DOWNLOAD — PHARE platform; COUNTERSIGNATURE — the licensor.
    function _authoriseTrigger(uint256 tokenId, BindingTrigger t, address caller) private view returns (bool) {
        Licence storage l = _licences[tokenId];
        if (t == BindingTrigger.WRITTEN_ACCEPTANCE) return caller == l.licensee;
        if (t == BindingTrigger.PAYMENT) return hasRole(FEE_ROLE, caller);
        if (t == BindingTrigger.FIRST_SYNC) return hasRole(LEDGER_ROLE, caller);
        if (t == BindingTrigger.DOWNLOAD) return hasRole(PLATFORM_ROLE, caller);
        return caller == l.licensor; // COUNTERSIGNATURE
    }

    function _bindUnchecked(uint256 tokenId, BindingTrigger t) private {
        Licence storage l = _licences[tokenId];
        if (l.state != LicenceState.ISSUED) revert WrongState(tokenId, l.state);
        l.boundBy = t;
        l.boundAt = uint64(block.timestamp);
        l.state = LicenceState.ACTIVE;
        emit LicenceMinted(
            tokenId, l.licensor, l.licensee, l.terms.termsHash, uint8(t), l.terms.syncTermStart, l.terms.syncTermEnd
        );
        emit LicenceStateChanged(tokenId, uint8(LicenceState.ISSUED), uint8(LicenceState.ACTIVE));
    }

    /// @dev §8.2: expiry and lapse are computed without a transaction; PAYMENT_HOLD is ACTIVE + hold.
    function _computed(uint256 tokenId) private view returns (LicenceState) {
        Licence storage l = _licences[tokenId];
        LicenceState s = l.state;
        if (_isTerminal(s)) return s;
        if (s == LicenceState.ISSUED && block.timestamp > l.terms.proposalExpiry) return LicenceState.LAPSED;
        if (block.timestamp > l.terms.syncTermEnd) return LicenceState.EXPIRED;
        if (s == LicenceState.ACTIVE && _paymentHold[tokenId]) return LicenceState.PAYMENT_HOLD;
        return s;
    }

    function _isTerminal(LicenceState s) private pure returns (bool) {
        return s == LicenceState.TERMINATED || s == LicenceState.EXPIRED || s == LicenceState.RESCINDED
            || s == LicenceState.LAPSED;
    }

    function _requireExists(uint256 tokenId) private view {
        if (_licences[tokenId].tokenId == 0) revert LicenceUnknown(tokenId);
    }

    function _onlyLicensee(uint256 tokenId) private view {
        _requireExists(tokenId);
        if (msg.sender != _licences[tokenId].licensee) revert NotLicensee(tokenId, msg.sender);
    }

    function _onlyLicensor(uint256 tokenId) private view {
        _requireExists(tokenId);
        if (msg.sender != _licences[tokenId].licensor) revert NotLicensor(tokenId, msg.sender);
    }
}
