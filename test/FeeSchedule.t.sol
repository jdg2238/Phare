// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BaseTest} from "./BaseTest.sol";
import {FeeSchedule} from "../src/FeeSchedule.sol";
import {LicenceNegotiation} from "../src/LicenceNegotiation.sol";
import {ClearanceLedger} from "../src/ClearanceLedger.sol";
import {IFeeSchedule} from "../src/interfaces/IFeeSchedule.sol";
import "../src/Types.sol";

/// @notice §11 step 3 — the I1 family, I20, the §8.3 instalment machine and OPEN-Q2/Q3/Q4/Q10 defaults.
contract FeeScheduleTest is BaseTest {
    // I1 — two FeeInstalment records exist for every minted licence and are never deleted
    function test_I1_twoInstalmentsCreatedAtMintAndNeverDeleted() public {
        uint256 id = mintActive();
        assertEq(fees.instalmentCount(id), 2);
        FeeInstalment memory f1 = fees.instalment(id, 1);
        FeeInstalment memory f2 = fees.instalment(id, 2);
        assertEq(f1.index, 1);
        assertEq(f2.index, 2);
        assertEq(f1.scheduledFor, EXECUTED_AT);
        assertEq(f2.scheduledFor, YEAR2_SCHEDULED); // OPEN-Q8
        assertEq(uint8(f1.state), uint8(InstalmentState.SCHEDULED));

        // licensee walks away in Year 1 (cl. 9.1) — records persist, nothing is cancelled (OPEN-Q4)
        vm.prank(licensee);
        licence.giveNotice(id);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        licence.finaliseTermination(id);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.TERMINATED));
        assertEq(fees.instalmentCount(id), 2);
        assertEq(keccak256(abi.encode(fees.instalment(id, 2))), keccak256(abi.encode(f2)));

        // OPEN-Q4 default: the Year-2 instalment is still payable after termination
        vm.warp(YEAR2_SCHEDULED);
        invoiceAndAttest(id, 2);
        assertEq(uint8(fees.instalment(id, 2).state), uint8(InstalmentState.PAID));
        assertEq(fees.instalmentCount(id), 2);
    }

    // I1b — no refund() or fee-reducing function exists anywhere
    function test_I1b_noRefundOrFeeReducingEntrypoints() public {
        uint256 id = mintActive();
        string[7] memory sigs = [
            "refund(uint256,uint8)",
            "refund(uint256)",
            "cancelInstalment(uint256,uint8)",
            "cancel(uint256,uint8)",
            "reduceAmount(uint256,uint8,uint256)",
            "setAmount(uint256,uint8,uint256)",
            "deleteInstalments(uint256)"
        ];
        address[2] memory targets = [address(fees), address(splitter)];
        for (uint256 t = 0; t < targets.length; t++) {
            for (uint256 i = 0; i < sigs.length; i++) {
                vm.prank(admin);
                (bool ok,) = targets[t].call(abi.encodeWithSignature(sigs[i], id, uint8(1), uint256(0)));
                assertFalse(ok, sigs[i]);
            }
        }
        assertEq(fees.instalmentCount(id), 2);
        assertEq(uint8(fees.instalment(id, 1).state), uint8(InstalmentState.SCHEDULED));
    }

    // I1c — zero declarations never alters any instalment
    function test_I1c_zeroDeclarationsNeverAltersInstalments() public {
        uint256 id = mintActive();
        bytes32 before = keccak256(abi.encode(fees.instalment(id, 1), fees.instalment(id, 2)));
        vm.warp(SYNC_TERM_END + 1); // whole term elapses with no use at all (cl. 2.4)
        assertEq(ledger.declarationCount(id), 0);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.EXPIRED));
        assertEq(keccak256(abi.encode(fees.instalment(id, 1), fees.instalment(id, 2))), before);
        assertFalse(fees.allPaid(id));
    }

    // I20 — no plaintext fee amount on-chain until OPEN-Q10 is closed
    function test_I20_plaintextAmountRejectedWhileUndisclosed() public {
        FeeInstalment[] memory plan = agreementFees();
        plan[0].amountMinor = YEAR1_AMOUNT;
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(FeeSchedule.InvalidPlan.selector, "plaintext amount while undisclosed"));
        negotiation.propose(agreementTerms(), plan);

        plan = agreementFees();
        plan[1].amountCommitment = bytes32(0);
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(FeeSchedule.InvalidPlan.selector, "amountCommitment"));
        negotiation.propose(agreementTerms(), plan);

        uint256 id = mintActive();
        assertEq(fees.instalment(id, 1).amountMinor, 0);
        assertEq(fees.instalment(id, 1).amountCommitment, commitment(1, YEAR1_AMOUNT, SALT1));
    }

    function test_I20_plaintextAllowedOnceDisclosureConfirmed() public {
        vm.prank(admin);
        fees.setFeeAmountsDisclosed(true); // OPEN-Q10 closed
        FeeInstalment[] memory plan = agreementFees();
        plan[0].amountMinor = YEAR1_AMOUNT;
        plan[0].amountCommitment = 0;
        plan[1].amountMinor = YEAR2_AMOUNT;
        plan[1].amountCommitment = 0;
        uint256 pid = proposeAndAccept(agreementTerms(), plan);
        vm.prank(licensee);
        uint256 id = licence.mintFromProposal(pid, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
        assertEq(fees.instalment(id, 1).amountMinor, YEAR1_AMOUNT);
        assertEq(fees.instalment(id, 2).amountMinor, YEAR2_AMOUNT);
    }

    function test_discloseAmount_verifiesCommitment() public {
        uint256 id = mintActive();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeeSchedule.NotAParty.selector, id, stranger));
        fees.discloseAmount(id, 1, YEAR1_AMOUNT, SALT1);

        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(FeeSchedule.CommitmentMismatch.selector, id, 1));
        fees.discloseAmount(id, 1, YEAR1_AMOUNT + 1, SALT1);

        vm.prank(licensee);
        fees.discloseAmount(id, 1, YEAR1_AMOUNT, SALT1);
        assertEq(fees.instalment(id, 1).amountMinor, YEAR1_AMOUNT);

        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(FeeSchedule.AmountAlreadyDisclosed.selector, id, 1));
        fees.discloseAmount(id, 1, YEAR1_AMOUNT, SALT1);
    }

    // OPEN-Q2 default — DAYS_AFTER_INVOICE, 60
    function test_markInvoiced_licensorOnly_dueIn60Days() public {
        uint256 id = mintActive();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeeSchedule.NotLicensor.selector, id, stranger));
        fees.markInvoiced(id, 1, keccak256("inv"));

        vm.prank(licensor);
        vm.expectEmit(true, false, false, true);
        emit IFeeSchedule.Invoiced(id, 1, keccak256("inv"), uint64(vm.getBlockTimestamp() + 60 days));
        fees.markInvoiced(id, 1, keccak256("inv"));
        FeeInstalment memory f = fees.instalment(id, 1);
        assertEq(uint8(f.state), uint8(InstalmentState.INVOICED));
        assertEq(f.invoicedAt, vm.getBlockTimestamp());
        assertEq(f.dueAt, vm.getBlockTimestamp() + 60 days);

        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(FeeSchedule.WrongState.selector, id, 1, InstalmentState.INVOICED));
        fees.markInvoiced(id, 1, keccak256("inv-again"));
    }

    // cl. 2.1 alternative — END_OF_MONTH_FOLLOWING
    function test_endOfMonthFollowingRule() public {
        LicenceTerms memory t = agreementTerms();
        t.paymentRule = PaymentRule.END_OF_MONTH_FOLLOWING;
        uint256 id = mintActive(t);

        vm.warp(1736899200); // 2025-01-15
        vm.prank(licensor);
        fees.markInvoiced(id, 1, keccak256("inv-1"));
        assertEq(fees.instalment(id, 1).dueAt, 1740787199); // 2025-02-28 23:59:59

        vm.warp(1764892800); // 2025-12-05 — crosses the year boundary
        vm.prank(licensor);
        fees.markInvoiced(id, 2, keccak256("inv-2"));
        assertEq(fees.instalment(id, 2).dueAt, 1769903999); // 2026-01-31 23:59:59
    }

    // OPEN-Q3 — overdue → (grace) → PAYMENT_HOLD → paid → ACTIVE; existing declarations untouched
    function test_OPENQ3_overdueGraceHoldAndRelease() public {
        uint256 id = mintActive();
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        vm.prank(licensor);
        fees.markInvoiced(id, 1, keccak256("inv"));
        uint64 dueAt = fees.instalment(id, 1).dueAt;

        vm.expectRevert(abi.encodeWithSelector(FeeSchedule.NotYetDue.selector, id, 1, dueAt));
        fees.markOverdue(id, 1);

        vm.warp(dueAt + 1);
        vm.expectEmit(true, false, false, true);
        emit IFeeSchedule.Overdue(id, 1, uint64(vm.getBlockTimestamp()));
        fees.markOverdue(id, 1);
        assertEq(uint8(fees.instalment(id, 1).state), uint8(InstalmentState.OVERDUE));
        assertTrue(fees.anyOverdue(id));
        assertFalse(licence.inPaymentHold(id)); // still inside the 30-day grace
        assertTrue(licence.canDeclare(id));

        vm.warp(dueAt + fees.PAYMENT_HOLD_GRACE() + 1);
        fees.markOverdue(id, 1); // idempotent on the instalment, applies the hold
        assertTrue(licence.inPaymentHold(id));
        assertEq(uint8(stateOf(id)), uint8(LicenceState.PAYMENT_HOLD));
        assertFalse(licence.canDeclare(id));
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.LicenceCannotDeclare.selector, id));
        ledger.declareSync(declarationInput(id, TRACK2, PRODUCTION2));
        assertTrue(ledger.verifyClearance(d, "GB", Media.ONLINE_SHORT_FORM_VOD)); // cl. 9.2

        vm.prank(attestor);
        fees.attestFiatSettlement(id, 1, keccak256("bank"));
        assertFalse(licence.inPaymentHold(id));
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ACTIVE));
        assertTrue(licence.canDeclare(id));
        assertFalse(fees.anyOverdue(id));
    }

    function test_anyOverdue_countsInvoicedPastDue() public {
        uint256 id = mintActive();
        vm.prank(licensor);
        fees.markInvoiced(id, 1, keccak256("inv"));
        assertFalse(fees.anyOverdue(id));
        vm.warp(fees.instalment(id, 1).dueAt + 1);
        assertTrue(fees.anyOverdue(id)); // even before anyone calls markOverdue
    }

    // cl. 6.3 — payment binds an ISSUED licence
    function test_paymentBindsIssuedLicence() public {
        uint256 pid = proposeAndAccept();
        vm.prank(licensor);
        uint256 id = licence.issue(pid);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ISSUED));
        assertFalse(licence.canDeclare(id));
        invoiceAndAttest(id, 1);
        Licence memory l = licence.licenceOf(id);
        assertEq(uint8(l.state), uint8(LicenceState.ACTIVE));
        assertEq(uint8(l.boundBy), uint8(BindingTrigger.PAYMENT));
        assertEq(l.boundAt, vm.getBlockTimestamp());
    }

    function test_settleOnChain_native() public {
        uint256 id = mintActive();
        vm.deal(licensee, 10 ether);
        vm.prank(licensor);
        fees.markInvoiced(id, 1, keccak256("inv"));

        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(FeeSchedule.AmountUndisclosed.selector, id, 1));
        fees.settleOnChain{value: YEAR1_AMOUNT}(id, 1, address(0), YEAR1_AMOUNT);

        disclose(id);
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(FeeSchedule.AmountMismatch.selector, YEAR1_AMOUNT, YEAR1_AMOUNT - 1));
        fees.settleOnChain{value: YEAR1_AMOUNT - 1}(id, 1, address(0), YEAR1_AMOUNT - 1);
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(FeeSchedule.ValueMismatch.selector, YEAR1_AMOUNT, YEAR1_AMOUNT - 1));
        fees.settleOnChain{value: YEAR1_AMOUNT - 1}(id, 1, address(0), YEAR1_AMOUNT);

        vm.prank(licensee);
        fees.settleOnChain{value: YEAR1_AMOUNT}(id, 1, address(0), YEAR1_AMOUNT);
        FeeInstalment memory f = fees.instalment(id, 1);
        assertEq(uint8(f.state), uint8(InstalmentState.PAID));
        assertTrue(f.settledOnChain);
        assertEq(f.paidAt, vm.getBlockTimestamp());
        assertEq(address(splitter).balance, YEAR1_AMOUNT);
        assertEq(address(fees).balance, 0);

        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(FeeSchedule.WrongState.selector, id, 1, InstalmentState.PAID));
        fees.settleOnChain{value: YEAR1_AMOUNT}(id, 1, address(0), YEAR1_AMOUNT);
    }

    function test_attestFiat_onlyAttestor_andAllPaid() public {
        uint256 id = mintActive();
        bytes32 role_ = fees.SETTLEMENT_ATTESTOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role_)
        );
        fees.attestFiatSettlement(id, 1, keccak256("bank"));

        invoiceAndAttest(id, 1);
        assertFalse(fees.allPaid(id));
        invoiceAndAttest(id, 2);
        assertTrue(fees.allPaid(id));
        FeeInstalment memory f = fees.instalment(id, 2);
        assertFalse(f.settledOnChain);
        assertEq(f.settlementRef, keccak256(abi.encode("bank-ref", uint8(2))));
    }

    function test_createInstalments_onlyLicenceContract() public {
        bytes32 role_ = fees.LICENCE_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role_)
        );
        fees.createInstalments(99, agreementFees());
    }
}
