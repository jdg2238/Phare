// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IRoyaltySplitter} from "./interfaces/IRoyaltySplitter.sol";
import {FeeSchedule} from "./FeeSchedule.sol";
import {SubscriptionLicence721} from "./SubscriptionLicence721.sol";
import {RightsRegistry} from "./RightsRegistry.sol";
import {ClearanceLedger} from "./ClearanceLedger.sol";
import {
    FeeInstalment,
    InstalmentState,
    IncomeType,
    ApportionmentPolicy,
    LicenceScope,
    LicenceTerms,
    SplitSet,
    SyncDeclaration
} from "./Types.sol";

/// @title RoyaltySplitter — cl. 3.2 / cl. 4 / OPEN-Q7
/// @notice Distributes each settled instalment per ApportionmentPolicy and the SYNC split set of each
///         track. Typed to one IncomeType per call — it never reads a split set of another pot (I5).
///         Every unit of a settled amount is accounted for; integer-division dust goes to the split
///         set's residualPayee (I6).
///
///         Two ledgers: `claimable` (funds actually held here after an on-chain settlement — pull
///         payments via {withdraw}) and `fiatOwed` (accounting entitlements for fiat-settled instalments,
///         paid off-chain and attested down by the SETTLEMENT_ATTESTOR).
contract RoyaltySplitter is IRoyaltySplitter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant FEE_ROLE = keccak256("FEE_ROLE"); // FeeSchedule
    bytes32 public constant SETTLEMENT_ATTESTOR_ROLE = keccak256("SETTLEMENT_ATTESTOR_ROLE");

    uint256 private constant BPS = 10_000;

    struct Pot {
        address token; // address(0) = native
        uint256 amount;
        bool funded;
    }

    struct Ctx {
        uint256 licenceId;
        uint8 incomeType;
        bool onChain;
        address token;
        bytes3 currency;
    }

    FeeSchedule public immutable feeSchedule;
    SubscriptionLicence721 public immutable licence;
    RightsRegistry public immutable registry;
    ClearanceLedger public ledger;

    mapping(uint256 licenceId => mapping(uint8 index => Pot)) private _pots;
    mapping(uint256 licenceId => mapping(uint8 index => bool)) public distributed;
    mapping(address token => mapping(address payee => uint256)) public claimable;
    mapping(bytes3 currency => mapping(address payee => uint256)) public fiatOwed;
    /// @dev WEIGHTED_BY_DURATION needs off-chain duration data per declaration, attested here first.
    mapping(uint256 licenceId => mapping(bytes32 declarationId => uint64)) public declarationWeight;

    event InstalmentReceived(uint256 indexed licenceId, uint8 index, address token, uint256 amount);
    event Withdrawn(address indexed token, address indexed payee, uint256 amount);
    event FiatPayoutAttested(bytes3 indexed currency, address indexed payee, uint256 amountMinor, bytes32 ref);
    event DeclarationWeightsSet(uint256 indexed licenceId, uint256 count);

    error ZeroAddress();
    error AlreadySet();
    error InvalidPolicy(uint8 policy);
    error InvalidIncomeType(uint8 incomeType);
    error NotLicensorOrAttestor(uint256 licenceId, address caller);
    error InstalmentNotPaid(uint256 licenceId, uint8 index);
    error AlreadyDistributed(uint256 licenceId, uint8 index);
    error AmountUndisclosed(uint256 licenceId, uint8 index);
    error PotNotFunded(uint256 licenceId, uint8 index);
    error PotAlreadyFunded(uint256 licenceId, uint8 index);
    error NoDeclarations(uint256 licenceId);
    error NoWeights(uint256 licenceId);
    error EmptyCatalogue(bytes32 catalogueId);
    error NoSplitSet(bytes32 trackId, uint8 incomeType);
    error ValueMismatch(uint256 expected, uint256 actual);
    error ZeroAmount();
    error LengthMismatch();
    error InsufficientFiatOwed(bytes3 currency, address payee, uint256 owed, uint256 requested);

    constructor(address admin, FeeSchedule feeSchedule_, SubscriptionLicence721 licence_, RightsRegistry registry_) {
        if (
            admin == address(0) || address(feeSchedule_) == address(0) || address(licence_) == address(0)
                || address(registry_) == address(0)
        ) revert ZeroAddress();
        feeSchedule = feeSchedule_;
        licence = licence_;
        registry = registry_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEE_ROLE, address(feeSchedule_));
    }

    function setLedger(ClearanceLedger ledger_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(ledger) != address(0)) revert AlreadySet();
        if (address(ledger_) == address(0)) revert ZeroAddress();
        ledger = ledger_;
    }

    // ---------------------------------------------------------------------
    // Inbound funds (on-chain settlement path)
    // ---------------------------------------------------------------------

    /// @notice FeeSchedule forwards an on-chain settlement here. ERC-20 amounts have already been
    ///         transferred to this contract; native amounts arrive as msg.value.
    function receiveInstalment(uint256 licenceId, uint8 index, address token, uint256 amount)
        external
        payable
        onlyRole(FEE_ROLE)
    {
        if (_pots[licenceId][index].funded) revert PotAlreadyFunded(licenceId, index);
        if (token == address(0)) {
            if (msg.value != amount) revert ValueMismatch(amount, msg.value);
        } else if (msg.value != 0) {
            revert ValueMismatch(0, msg.value);
        }
        _pots[licenceId][index] = Pot({token: token, amount: amount, funded: true});
        emit InstalmentReceived(licenceId, index, token, amount);
    }

    // ---------------------------------------------------------------------
    // §7 — distribution
    // ---------------------------------------------------------------------

    /// @inheritdoc IRoyaltySplitter
    /// @dev OPEN-Q7: the policy is chosen per instalment by the licensor (or PHARE's settlement role).
    ///      LIBRARY_RETAINS is the stated default for a production library that owns both master and
    ///      publishing; the other three are implemented and selectable.
    function distributeInstalment(uint256 licenceId, uint8 index, uint8 policy) external override nonReentrant {
        if (policy > uint8(ApportionmentPolicy.PRO_RATA_CATALOGUE)) revert InvalidPolicy(policy);
        address licensor = licence.licensorOf(licenceId);
        if (msg.sender != licensor && !hasRole(SETTLEMENT_ATTESTOR_ROLE, msg.sender)) {
            revert NotLicensorOrAttestor(licenceId, msg.sender);
        }
        FeeInstalment memory inst = feeSchedule.instalment(licenceId, index);
        if (inst.state != InstalmentState.PAID) revert InstalmentNotPaid(licenceId, index);
        if (distributed[licenceId][index]) revert AlreadyDistributed(licenceId, index);
        uint256 amount = inst.amountMinor;
        if (amount == 0) revert AmountUndisclosed(licenceId, index); // OPEN-Q10

        LicenceTerms memory terms = licence.termsOf(licenceId);
        Ctx memory ctx = Ctx({
            licenceId: licenceId,
            incomeType: uint8(IncomeType.SYNC),
            onChain: inst.settledOnChain,
            token: address(0),
            currency: terms.currency
        });
        if (inst.settledOnChain) {
            Pot storage funded = _pots[licenceId][index];
            if (!funded.funded || funded.amount != amount) revert PotNotFunded(licenceId, index);
            ctx.token = funded.token;
        }
        distributed[licenceId][index] = true;

        bytes32 scopeKey = terms.scope == LicenceScope.CATALOGUE ? terms.catalogueId : terms.trackId;
        uint256 declarations;
        ApportionmentPolicy p = ApportionmentPolicy(policy);

        if (p == ApportionmentPolicy.LIBRARY_RETAINS) {
            _credit(ctx, scopeKey, licensor, amount);
        } else if (p == ApportionmentPolicy.EQUAL_PER_DECLARATION) {
            declarations = _equalPerDeclaration(ctx, licensor, amount);
        } else if (p == ApportionmentPolicy.WEIGHTED_BY_DURATION) {
            declarations = _weightedByDuration(ctx, licensor, amount);
        } else {
            _proRataCatalogue(ctx, terms, licensor, amount);
        }
        emit Apportioned(licenceId, index, policy, declarations, amount);
    }

    /// @inheritdoc IRoyaltySplitter
    /// @dev Direct on-chain distribution of any income pot for one track (e.g. a performance royalty
    ///      remitted on-chain). Reads ONLY the split set of `incomeType` (I5).
    function distributeTrack(bytes32 trackId, uint8 incomeType, address token, uint256 amountMinor)
        external
        payable
        override
        nonReentrant
    {
        if (incomeType > uint8(IncomeType.OTHER)) revert InvalidIncomeType(incomeType);
        if (amountMinor == 0) revert ZeroAmount();
        if (token == address(0)) {
            if (msg.value != amountMinor) revert ValueMismatch(amountMinor, msg.value);
        } else {
            if (msg.value != 0) revert ValueMismatch(0, msg.value);
            IERC20(token).safeTransferFrom(msg.sender, address(this), amountMinor);
        }
        Ctx memory ctx = Ctx({licenceId: 0, incomeType: incomeType, onChain: true, token: token, currency: 0});
        _distributeTrack(ctx, trackId, amountMinor);
    }

    // ---------------------------------------------------------------------
    // Payee side
    // ---------------------------------------------------------------------

    function withdraw(address token) external nonReentrant {
        uint256 amount = claimable[token][msg.sender];
        if (amount == 0) revert ZeroAmount();
        claimable[token][msg.sender] = 0;
        if (token == address(0)) {
            Address.sendValue(payable(msg.sender), amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
        emit Withdrawn(token, msg.sender, amount);
    }

    /// @notice PHARE's settlement role records an off-chain payout against a fiat entitlement.
    function attestFiatPayout(bytes3 currency, address payee, uint256 amountMinor, bytes32 ref)
        external
        onlyRole(SETTLEMENT_ATTESTOR_ROLE)
    {
        uint256 owed = fiatOwed[currency][payee];
        if (amountMinor == 0) revert ZeroAmount();
        if (amountMinor > owed) revert InsufficientFiatOwed(currency, payee, owed, amountMinor);
        fiatOwed[currency][payee] = owed - amountMinor;
        emit FiatPayoutAttested(currency, payee, amountMinor, ref);
    }

    /// @notice Attest per-declaration duration weights (off-chain data) ahead of WEIGHTED_BY_DURATION.
    function setDeclarationWeights(uint256 licenceId, bytes32[] calldata declarationIds, uint64[] calldata weights)
        external
        onlyRole(SETTLEMENT_ATTESTOR_ROLE)
    {
        if (declarationIds.length != weights.length) revert LengthMismatch();
        for (uint256 i = 0; i < declarationIds.length; i++) {
            declarationWeight[licenceId][declarationIds[i]] = weights[i];
        }
        emit DeclarationWeightsSet(licenceId, declarationIds.length);
    }

    function pot(uint256 licenceId, uint8 index) external view returns (Pot memory) {
        return _pots[licenceId][index];
    }

    // ---------------------------------------------------------------------
    // Policies (OPEN-Q7)
    // ---------------------------------------------------------------------

    function _equalPerDeclaration(Ctx memory ctx, address licensor, uint256 amount) private returns (uint256 n) {
        bytes32[] memory ids = ledger.declarationIdsOf(ctx.licenceId);
        n = ids.length;
        if (n == 0) revert NoDeclarations(ctx.licenceId);
        uint256 share = amount / n;
        for (uint256 i = 0; i < n; i++) {
            SyncDeclaration memory d = ledger.declaration(ids[i]);
            _distributeTrack(ctx, d.trackId, share);
        }
        uint256 remainder = amount - share * n;
        if (remainder > 0) _credit(ctx, bytes32(0), licensor, remainder); // apportionment dust → library
    }

    function _weightedByDuration(Ctx memory ctx, address licensor, uint256 amount) private returns (uint256 n) {
        bytes32[] memory ids = ledger.declarationIdsOf(ctx.licenceId);
        n = ids.length;
        if (n == 0) revert NoDeclarations(ctx.licenceId);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            total += declarationWeight[ctx.licenceId][ids[i]];
        }
        if (total == 0) revert NoWeights(ctx.licenceId);
        uint256 paid;
        for (uint256 i = 0; i < n; i++) {
            uint256 share = amount * declarationWeight[ctx.licenceId][ids[i]] / total;
            if (share == 0) continue;
            paid += share;
            SyncDeclaration memory d = ledger.declaration(ids[i]);
            _distributeTrack(ctx, d.trackId, share);
        }
        if (amount > paid) _credit(ctx, bytes32(0), licensor, amount - paid);
    }

    function _proRataCatalogue(Ctx memory ctx, LicenceTerms memory terms, address licensor, uint256 amount) private {
        if (terms.scope == LicenceScope.TRACK) {
            _distributeTrack(ctx, terms.trackId, amount);
            return;
        }
        bytes32[] memory tracks = registry.catalogueTracks(terms.catalogueId);
        uint256 n = tracks.length;
        if (n == 0) revert EmptyCatalogue(terms.catalogueId);
        uint256 share = amount / n;
        for (uint256 i = 0; i < n; i++) {
            _distributeTrack(ctx, tracks[i], share);
        }
        uint256 remainder = amount - share * n;
        if (remainder > 0) _credit(ctx, bytes32(0), licensor, remainder);
    }

    /// @dev Reads exactly one split set: (trackId, ctx.incomeType). Σ credited == amount (I6).
    function _distributeTrack(Ctx memory ctx, bytes32 trackId, uint256 amount) private {
        if (amount == 0) return;
        SplitSet memory ss = registry.splitSet(trackId, ctx.incomeType);
        if (ss.entries.length == 0) revert NoSplitSet(trackId, ctx.incomeType);
        uint256 total;
        for (uint256 i = 0; i < ss.entries.length; i++) {
            uint256 part = amount * ss.entries[i].bps / BPS;
            total += part;
            _credit(ctx, trackId, ss.entries[i].payee, part);
        }
        uint256 dust = amount - total;
        if (dust > 0) _credit(ctx, trackId, ss.residualPayee, dust);
    }

    function _credit(Ctx memory ctx, bytes32 trackId, address payee, uint256 amount) private {
        if (amount == 0) return;
        if (ctx.onChain) {
            claimable[ctx.token][payee] += amount;
        } else {
            fiatOwed[ctx.currency][payee] += amount;
        }
        emit Distributed(trackId, ctx.incomeType, payee, amount, ctx.licenceId);
    }
}
