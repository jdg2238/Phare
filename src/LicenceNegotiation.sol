// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ILicenceNegotiation} from "./interfaces/ILicenceNegotiation.sol";
import {IFeePlanValidator} from "./interfaces/IFeePlanValidator.sol";
import {RightsRegistry} from "./RightsRegistry.sol";
import {LicenceTerms, FeeInstalment, LicenceScope, PaymentRule, ProposalState} from "./Types.sol";

/// @title LicenceNegotiation — LEVEL 2 of the dependency graph (§5)
/// @notice propose → counter* → accept. The contract stores the outcome only. The message-by-message
///         trail lives on an HCS topic (terms.hcsTopicId) and does NOT form part of the agreement (cl. 6.1,
///         OPEN-Q11): nothing here ever reads it.
/// @dev Offers alternate strictly: whoever did not make the standing offer may counter or accept it.
contract LicenceNegotiation is ILicenceNegotiation {
    struct Proposal {
        address licensor; // derived from the registry (catalogue or track owner)
        address licensee; // the proposer
        address lastOfferor; // whose offer currently stands
        ProposalState state;
        uint64 createdAt;
        uint64 lastActionAt;
        uint256 tokenId; // set by SubscriptionLicence721 on mint
        LicenceTerms terms;
        FeeInstalment[] fees;
    }

    RightsRegistry public immutable registry;
    address public immutable admin;
    address public licenceContract; // the only address allowed to consume an accepted proposal
    IFeePlanValidator public feeValidator; // FeeSchedule
    uint256 public proposalCount;

    mapping(uint256 proposalId => Proposal) private _proposals;

    event Rejected(uint256 indexed proposalId, address indexed by);
    event Withdrawn(uint256 indexed proposalId, address indexed by);
    event Lapsed(uint256 indexed proposalId);
    event Minted(uint256 indexed proposalId, uint256 indexed tokenId);

    error NotAdmin();
    error AlreadySet();
    error ZeroAddress();
    error ProposalUnknown(uint256 proposalId);
    error NotOpen(uint256 proposalId, ProposalState state);
    error NotAccepted(uint256 proposalId, ProposalState state);
    error NotAParty(uint256 proposalId, address caller);
    error NotYourTurn(uint256 proposalId, address caller);
    error NotOfferor(uint256 proposalId, address caller);
    error NotLicenceContract(address caller);
    error AlreadyMinted(uint256 proposalId, uint256 tokenId);
    error NotYetLapsed(uint256 proposalId);
    error LicensorUnknown();
    error LicensorMismatch(address expected, address actual);
    error SelfDealing();
    error InvalidTerms(string reason);

    constructor(address admin_, RightsRegistry registry_) {
        if (admin_ == address(0) || address(registry_) == address(0)) revert ZeroAddress();
        admin = admin_;
        registry = registry_;
    }

    // ---------------------------------------------------------------------
    // Wiring (once)
    // ---------------------------------------------------------------------

    function setLicenceContract(address licence) external {
        if (msg.sender != admin) revert NotAdmin();
        if (licenceContract != address(0)) revert AlreadySet();
        if (licence == address(0)) revert ZeroAddress();
        licenceContract = licence;
    }

    function setFeeValidator(IFeePlanValidator validator) external {
        if (msg.sender != admin) revert NotAdmin();
        if (address(feeValidator) != address(0)) revert AlreadySet();
        if (address(validator) == address(0)) revert ZeroAddress();
        feeValidator = validator;
    }

    // ---------------------------------------------------------------------
    // §8.1 Proposal state machine
    // ---------------------------------------------------------------------

    /// @notice A prospective licensee opens negotiation on a catalogue or a track. The licensor is
    ///         whoever the RightsRegistry says owns that catalogue / track.
    function propose(LicenceTerms calldata terms, FeeInstalment[] calldata fees)
        external
        override
        returns (uint256 proposalId)
    {
        address licensor = _validate(terms, fees);
        if (licensor == msg.sender) revert SelfDealing();

        proposalId = ++proposalCount;
        Proposal storage p = _proposals[proposalId];
        p.licensor = licensor;
        p.licensee = msg.sender;
        p.lastOfferor = msg.sender;
        p.state = ProposalState.PROPOSED;
        p.createdAt = uint64(block.timestamp);
        p.lastActionAt = uint64(block.timestamp);
        _store(p, terms, fees);

        emit Proposed(proposalId, msg.sender, _scopeKey(terms), terms.termsHash, terms.hcsTopicId);
    }

    /// @notice The counterparty of the standing offer replaces it with revised terms.
    function counter(uint256 proposalId, LicenceTerms calldata revised, FeeInstalment[] calldata fees)
        external
        override
    {
        Proposal storage p = _open(proposalId);
        _requireCounterparty(p, proposalId);
        address licensor = _validate(revised, fees);
        if (licensor != p.licensor) revert LicensorMismatch(p.licensor, licensor);
        _store(p, revised, fees);
        p.lastOfferor = msg.sender;
        p.state = ProposalState.COUNTERED;
        p.lastActionAt = uint64(block.timestamp);
        emit Countered(proposalId, msg.sender, revised.termsHash);
    }

    /// @notice The counterparty of the standing offer accepts it as-is.
    function accept(uint256 proposalId) external override {
        Proposal storage p = _open(proposalId);
        _requireCounterparty(p, proposalId);
        p.state = ProposalState.ACCEPTED;
        p.lastActionAt = uint64(block.timestamp);
        emit Accepted(proposalId, p.terms.termsHash);
    }

    function reject(uint256 proposalId) external override {
        Proposal storage p = _open(proposalId);
        if (msg.sender != p.licensor && msg.sender != p.licensee) revert NotAParty(proposalId, msg.sender);
        p.state = ProposalState.REJECTED;
        p.lastActionAt = uint64(block.timestamp);
        emit Rejected(proposalId, msg.sender);
    }

    function withdraw(uint256 proposalId) external override {
        Proposal storage p = _open(proposalId);
        if (msg.sender != p.lastOfferor) revert NotOfferor(proposalId, msg.sender);
        p.state = ProposalState.WITHDRAWN;
        p.lastActionAt = uint64(block.timestamp);
        emit Withdrawn(proposalId, msg.sender);
    }

    /// @notice Persist a lapse that {stateOf} already reports. Anyone may call.
    function lapse(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        if (p.licensee == address(0)) revert ProposalUnknown(proposalId);
        if (stateOf(proposalId) != ProposalState.LAPSED) revert NotYetLapsed(proposalId);
        if (p.state != ProposalState.LAPSED) {
            p.state = ProposalState.LAPSED;
            p.lastActionAt = uint64(block.timestamp);
            emit Lapsed(proposalId);
        }
    }

    /// @notice Called by SubscriptionLicence721 when an accepted proposal becomes a token.
    function markMinted(uint256 proposalId, uint256 tokenId) external {
        if (msg.sender != licenceContract) revert NotLicenceContract(msg.sender);
        Proposal storage p = _proposals[proposalId];
        if (p.licensee == address(0)) revert ProposalUnknown(proposalId);
        if (p.state != ProposalState.ACCEPTED) revert NotAccepted(proposalId, p.state);
        if (p.tokenId != 0) revert AlreadyMinted(proposalId, p.tokenId);
        p.tokenId = tokenId;
        emit Minted(proposalId, tokenId);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @dev Expiry is computed: an open proposal past terms.proposalExpiry reads as LAPSED.
    function stateOf(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage p = _proposals[proposalId];
        ProposalState s = p.state;
        if ((s == ProposalState.PROPOSED || s == ProposalState.COUNTERED) && block.timestamp > p.terms.proposalExpiry) {
            return ProposalState.LAPSED;
        }
        return s;
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory p) {
        p = _proposals[proposalId];
        if (p.licensee == address(0)) revert ProposalUnknown(proposalId);
        p.state = stateOf(proposalId);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _open(uint256 proposalId) private view returns (Proposal storage p) {
        p = _proposals[proposalId];
        if (p.licensee == address(0)) revert ProposalUnknown(proposalId);
        ProposalState s = stateOf(proposalId);
        if (s != ProposalState.PROPOSED && s != ProposalState.COUNTERED) revert NotOpen(proposalId, s);
    }

    function _requireCounterparty(Proposal storage p, uint256 proposalId) private view {
        if (msg.sender != p.licensor && msg.sender != p.licensee) revert NotAParty(proposalId, msg.sender);
        if (msg.sender == p.lastOfferor) revert NotYourTurn(proposalId, msg.sender);
    }

    function _store(Proposal storage p, LicenceTerms calldata terms, FeeInstalment[] calldata fees) private {
        p.terms = terms;
        delete p.fees;
        for (uint256 i = 0; i < fees.length; i++) {
            p.fees.push(fees[i]);
        }
    }

    function _scopeKey(LicenceTerms calldata terms) private pure returns (bytes32) {
        return terms.scope == LicenceScope.CATALOGUE ? terms.catalogueId : terms.trackId;
    }

    /// @dev Structural validation only. Commercial values are never defaulted here — they are read
    ///      from the terms the parties supply (§4.3, §4.4).
    function _validate(LicenceTerms calldata t, FeeInstalment[] calldata fees) private view returns (address licensor) {
        if (t.scope == LicenceScope.CATALOGUE) {
            if (t.catalogueId == bytes32(0)) revert InvalidTerms("catalogueId");
            licensor = registry.catalogueOwner(t.catalogueId);
        } else {
            if (t.trackId == bytes32(0)) revert InvalidTerms("trackId");
            licensor = registry.ownerOfTrack(t.trackId);
        }
        if (licensor == address(0)) revert LicensorUnknown();
        if (t.rightsMask == 0) revert InvalidTerms("rightsMask");
        if (t.contentMask == 0) revert InvalidTerms("contentMask");
        if (t.mediaMask == 0) revert InvalidTerms("mediaMask");
        // I19: retrospective effect is permitted (effectiveFrom <= executedAt); the sync clock starts
        // at effectiveFrom.
        if (t.syncTermStart != t.effectiveFrom) revert InvalidTerms("syncTermStart != effectiveFrom");
        if (t.executedAt != 0 && t.executedAt < t.effectiveFrom) revert InvalidTerms("executedAt < effectiveFrom");
        if (t.syncTermEnd <= t.syncTermStart) revert InvalidTerms("syncTermEnd");
        if (!t.distributionPerpetual && t.distributionTermEnd < t.syncTermEnd) {
            revert InvalidTerms("distributionTermEnd");
        }
        if (t.currency == bytes3(0)) revert InvalidTerms("currency");
        if (t.paymentRule == PaymentRule.DAYS_AFTER_INVOICE && t.dueDaysAfterInvoice == 0) {
            revert InvalidTerms("dueDaysAfterInvoice");
        }
        if (t.proposalExpiry <= block.timestamp) revert InvalidTerms("proposalExpiry");
        if (fees.length == 0) revert InvalidTerms("fees");
        if (address(feeValidator) != address(0)) feeValidator.validatePlan(fees);
    }
}
