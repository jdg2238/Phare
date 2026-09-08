// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFeeSchedule} from "./interfaces/IFeeSchedule.sol";
import {IFeePlanValidator} from "./interfaces/IFeePlanValidator.sol";
import {SubscriptionLicence721} from "./SubscriptionLicence721.sol";
import {RoyaltySplitter} from "./RoyaltySplitter.sol";
import {DateTime} from "./libraries/DateTime.sol";
import {FeeInstalment, InstalmentState, LicenceState, BindingTrigger, PaymentRule} from "./Types.sol";

/// @title FeeSchedule — cl. 2.1 / 2.4 / 6.2 / Key Terms
/// @notice Instalments are created at mint and are never deleted, reduced, refunded or cancelled
///         (I1, I1b, I1c; cl. 2.4 "unconditional", cl. 6.2 "no credits or refunds"; OPEN-Q4 default:
///         the Year-2 instalment stays payable after a cl. 9.1 termination).
///         Primary settlement path is fiat against a GBP invoice, attested on-chain by PHARE's
///         SETTLEMENT_ATTESTOR role; an on-chain (HBAR / ERC-20) path also exists.
contract FeeSchedule is IFeeSchedule, IFeePlanValidator, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLEMENT_ATTESTOR_ROLE = keccak256("SETTLEMENT_ATTESTOR_ROLE");
    bytes32 public constant LICENCE_ROLE = keccak256("LICENCE_ROLE"); // SubscriptionLicence721

    /// @dev OPEN-Q3: an overdue instalment suspends NEW declarations after this grace period.
    uint64 public constant PAYMENT_HOLD_GRACE = 30 days;

    SubscriptionLicence721 public immutable licence;
    RoyaltySplitter public splitter;

    /// @dev OPEN-Q10: fee amounts are hash-committed, not stored in plaintext, until this is switched
    ///      on by the admin once the confidentiality question is closed (I20).
    bool public feeAmountsDisclosed;

    mapping(uint256 licenceId => FeeInstalment[]) private _plans;

    event InstalmentsCreated(uint256 indexed licenceId, uint256 count);
    event AmountDisclosed(uint256 indexed licenceId, uint8 index, uint256 amountMinor);
    event FeeAmountDisclosureSet(bool disclosed);

    error ZeroAddress();
    error AlreadySet();
    error PlanExists(uint256 licenceId);
    error InvalidPlan(string reason);
    error InstalmentUnknown(uint256 licenceId, uint8 index);
    error WrongState(uint256 licenceId, uint8 index, InstalmentState state);
    error NotLicensor(uint256 licenceId, address caller);
    error NotAParty(uint256 licenceId, address caller);
    error NotYetDue(uint256 licenceId, uint8 index, uint64 dueAt);
    error AmountUndisclosed(uint256 licenceId, uint8 index);
    error AmountAlreadyDisclosed(uint256 licenceId, uint8 index);
    error CommitmentMismatch(uint256 licenceId, uint8 index);
    error AmountMismatch(uint256 expected, uint256 actual);
    error ValueMismatch(uint256 expected, uint256 actual);
    error SplitterNotSet();

    constructor(address admin, SubscriptionLicence721 licence_) {
        if (admin == address(0) || address(licence_) == address(0)) revert ZeroAddress();
        licence = licence_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(LICENCE_ROLE, address(licence_));
    }

    // ---------------------------------------------------------------------
    // Admin wiring
    // ---------------------------------------------------------------------

    function setSplitter(RoyaltySplitter splitter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(splitter) != address(0)) revert AlreadySet();
        if (address(splitter_) == address(0)) revert ZeroAddress();
        splitter = splitter_;
    }

    /// @notice OPEN-Q10 — flip once the parties confirm fee amounts may be public on the ledger.
    function setFeeAmountsDisclosed(bool disclosed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeAmountsDisclosed = disclosed;
        emit FeeAmountDisclosureSet(disclosed);
    }

    // ---------------------------------------------------------------------
    // Plan validation (also used by LicenceNegotiation at propose-time)
    // ---------------------------------------------------------------------

    /// @inheritdoc IFeePlanValidator
    function validatePlan(FeeInstalment[] calldata plan) public view override {
        if (plan.length == 0) revert InvalidPlan("empty");
        for (uint256 i = 0; i < plan.length; i++) {
            FeeInstalment calldata f = plan[i];
            if (f.index != i + 1) revert InvalidPlan("index");
            if (f.scheduledFor == 0) revert InvalidPlan("scheduledFor");
            if (f.state != InstalmentState.SCHEDULED) revert InvalidPlan("state");
            if (f.invoicedAt != 0 || f.dueAt != 0 || f.paidAt != 0 || f.settlementRef != 0 || f.settledOnChain) {
                revert InvalidPlan("lifecycle fields must be zero");
            }
            if (feeAmountsDisclosed) {
                if (f.amountMinor == 0) revert InvalidPlan("amountMinor");
            } else {
                // I20 / OPEN-Q10: no plaintext amount on-chain; a commitment is mandatory instead.
                if (f.amountMinor != 0) revert InvalidPlan("plaintext amount while undisclosed");
                if (f.amountCommitment == bytes32(0)) revert InvalidPlan("amountCommitment");
            }
        }
    }

    // ---------------------------------------------------------------------
    // §8.3 Instalment state machine
    // ---------------------------------------------------------------------

    /// @inheritdoc IFeeSchedule
    function createInstalments(uint256 licenceId, FeeInstalment[] calldata plan)
        external
        override
        onlyRole(LICENCE_ROLE)
    {
        if (_plans[licenceId].length != 0) revert PlanExists(licenceId);
        validatePlan(plan);
        for (uint256 i = 0; i < plan.length; i++) {
            _plans[licenceId].push(plan[i]);
        }
        emit InstalmentsCreated(licenceId, plan.length);
    }

    /// @notice OPEN-Q10 — either party reveals an amount against its commitment. Needed before an
    ///         on-chain settlement (the amount must match) or an on-chain distribution.
    function discloseAmount(uint256 licenceId, uint8 index, uint256 amountMinor, bytes32 salt) external {
        if (msg.sender != licence.licensorOf(licenceId) && msg.sender != licence.licenseeOf(licenceId)) {
            revert NotAParty(licenceId, msg.sender);
        }
        FeeInstalment storage f = _instalment(licenceId, index);
        if (f.amountMinor != 0) revert AmountAlreadyDisclosed(licenceId, index);
        if (amountMinor == 0) revert InvalidPlan("amountMinor");
        if (keccak256(abi.encode(index, amountMinor, salt)) != f.amountCommitment) {
            revert CommitmentMismatch(licenceId, index);
        }
        f.amountMinor = amountMinor;
        emit AmountDisclosed(licenceId, index, amountMinor);
    }

    /// @inheritdoc IFeeSchedule
    function markInvoiced(uint256 licenceId, uint8 index, bytes32 invoiceHash) external override {
        if (msg.sender != licence.licensorOf(licenceId)) revert NotLicensor(licenceId, msg.sender);
        FeeInstalment storage f = _instalment(licenceId, index);
        if (f.state != InstalmentState.SCHEDULED) revert WrongState(licenceId, index, f.state);
        (PaymentRule rule, uint32 dueDays,) = licence.paymentTermsOf(licenceId);
        f.invoicedAt = uint64(block.timestamp);
        // OPEN-Q2: Key Terms (60 days from invoice) vs cl. 2.1 (end of month following receipt).
        if (rule == PaymentRule.DAYS_AFTER_INVOICE) {
            f.dueAt = uint64(block.timestamp + uint256(dueDays) * 1 days);
        } else {
            f.dueAt = uint64(DateTime.endOfFollowingMonth(block.timestamp));
        }
        f.state = InstalmentState.INVOICED;
        emit Invoiced(licenceId, index, invoiceHash, f.dueAt);
    }

    /// @inheritdoc IFeeSchedule
    /// @dev `token == address(0)` settles in the native coin (HBAR). Amounts are compared 1:1 with
    ///      `amountMinor`, so the token's minor unit must equal the fee's minor unit (e.g. a 2-decimal
    ///      GBP token). Funds are forwarded straight to the RoyaltySplitter pot for this instalment.
    function settleOnChain(uint256 licenceId, uint8 index, address token, uint256 amount) external payable override {
        if (address(splitter) == address(0)) revert SplitterNotSet();
        FeeInstalment storage f = _instalment(licenceId, index);
        _requirePayable(licenceId, index, f);
        if (f.amountMinor == 0) revert AmountUndisclosed(licenceId, index);
        if (amount != f.amountMinor) revert AmountMismatch(f.amountMinor, amount);

        if (token == address(0)) {
            if (msg.value != amount) revert ValueMismatch(amount, msg.value);
            splitter.receiveInstalment{value: amount}(licenceId, index, token, amount);
        } else {
            if (msg.value != 0) revert ValueMismatch(0, msg.value);
            IERC20(token).safeTransferFrom(msg.sender, address(splitter), amount);
            splitter.receiveInstalment(licenceId, index, token, amount);
        }

        f.paidAt = uint64(block.timestamp);
        f.settlementRef = keccak256(abi.encode(block.chainid, block.number, msg.sender, token, amount));
        f.settledOnChain = true;
        f.state = InstalmentState.PAID;
        emit Settled(licenceId, index, amount, true, f.settlementRef);
        _afterSettlement(licenceId);
    }

    /// @inheritdoc IFeeSchedule
    function attestFiatSettlement(uint256 licenceId, uint8 index, bytes32 bankRef)
        external
        override
        onlyRole(SETTLEMENT_ATTESTOR_ROLE)
    {
        FeeInstalment storage f = _instalment(licenceId, index);
        _requirePayable(licenceId, index, f);
        f.paidAt = uint64(block.timestamp);
        f.settlementRef = bankRef;
        f.settledOnChain = false;
        f.state = InstalmentState.PAID;
        emit Settled(licenceId, index, f.amountMinor, false, bankRef);
        _afterSettlement(licenceId);
    }

    /// @inheritdoc IFeeSchedule
    /// @dev Anyone may call after dueAt. Past dueAt + PAYMENT_HOLD_GRACE the licence goes on payment
    ///      hold (OPEN-Q3): no NEW declarations; existing declarations are untouched (cl. 9.2).
    function markOverdue(uint256 licenceId, uint8 index) external override {
        FeeInstalment storage f = _instalment(licenceId, index);
        if (f.state != InstalmentState.INVOICED && f.state != InstalmentState.OVERDUE) {
            revert WrongState(licenceId, index, f.state);
        }
        if (block.timestamp <= f.dueAt) revert NotYetDue(licenceId, index, f.dueAt);
        if (f.state == InstalmentState.INVOICED) {
            f.state = InstalmentState.OVERDUE;
            emit Overdue(licenceId, index, uint64(block.timestamp));
        }
        if (block.timestamp > uint256(f.dueAt) + PAYMENT_HOLD_GRACE && !licence.inPaymentHold(licenceId)) {
            licence.setPaymentHold(licenceId); // OPEN-Q3
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function instalment(uint256 licenceId, uint8 index) external view override returns (FeeInstalment memory) {
        return _instalment(licenceId, index);
    }

    function instalmentCount(uint256 licenceId) external view returns (uint256) {
        return _plans[licenceId].length;
    }

    function allPaid(uint256 licenceId) public view override returns (bool) {
        FeeInstalment[] storage plan = _plans[licenceId];
        if (plan.length == 0) return false;
        for (uint256 i = 0; i < plan.length; i++) {
            if (plan[i].state != InstalmentState.PAID) return false;
        }
        return true;
    }

    function anyOverdue(uint256 licenceId) public view override returns (bool) {
        FeeInstalment[] storage plan = _plans[licenceId];
        for (uint256 i = 0; i < plan.length; i++) {
            InstalmentState s = plan[i].state;
            if (s == InstalmentState.OVERDUE) return true;
            if (s == InstalmentState.INVOICED && block.timestamp > plan[i].dueAt) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _instalment(uint256 licenceId, uint8 index) private view returns (FeeInstalment storage) {
        FeeInstalment[] storage plan = _plans[licenceId];
        if (index == 0 || index > plan.length) revert InstalmentUnknown(licenceId, index);
        return plan[index - 1];
    }

    function _requirePayable(uint256 licenceId, uint8 index, FeeInstalment storage f) private view {
        InstalmentState s = f.state;
        if (s != InstalmentState.SCHEDULED && s != InstalmentState.INVOICED && s != InstalmentState.OVERDUE) {
            revert WrongState(licenceId, index, s);
        }
    }

    /// @dev cl. 6.3 — payment binds an ISSUED licence; a cleared arrears lifts the OPEN-Q3 hold.
    function _afterSettlement(uint256 licenceId) private {
        if (licence.state(licenceId) == uint8(LicenceState.ISSUED)) {
            licence.bind(licenceId, uint8(BindingTrigger.PAYMENT));
        }
        if (licence.inPaymentHold(licenceId) && !anyOverdue(licenceId)) {
            licence.clearPaymentHold(licenceId);
        }
    }
}
