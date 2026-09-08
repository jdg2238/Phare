// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BaseTest} from "./BaseTest.sol";
import {RoyaltySplitter} from "../src/RoyaltySplitter.sol";
import {FeeSchedule} from "../src/FeeSchedule.sol";
import "../src/Types.sol";

/// @notice §11 step 2 — I5, I6 and all four ApportionmentPolicy paths (OPEN-Q7).
contract RoyaltySplitterTest is BaseTest {
    uint8 constant SYNC = uint8(IncomeType.SYNC);
    uint8 constant PERF = uint8(IncomeType.PUBLISHING_PERFORMANCE);
    address constant NATIVE = address(0);
    bytes3 constant GBP = "GBP";

    function setUp() public override {
        super.setUp();
        vm.deal(stranger, 100 ether);
        vm.deal(licensee, 100 ether);
    }

    // I5 — distributeTrack never reads a split set of a different IncomeType
    function test_I5_distributeTrackReadsOnlyTheSelectedPot() public {
        // PUBLISHING_PERFORMANCE table on TRACK1 pays composerA 100%; SYNC table pays 50/33.33/16.67
        vm.prank(stranger);
        splitter.distributeTrack{value: 1000}(TRACK1, PERF, NATIVE, 1000);
        assertEq(splitter.claimable(NATIVE, composerA), 1000);
        assertEq(splitter.claimable(NATIVE, composerB), 0);
        assertEq(splitter.claimable(NATIVE, licensor), 0);

        vm.prank(stranger);
        splitter.distributeTrack{value: 1000}(TRACK1, SYNC, NATIVE, 1000);
        assertEq(splitter.claimable(NATIVE, composerA), 1000 + 333);
        assertEq(splitter.claimable(NATIVE, composerB), 166);
        assertEq(splitter.claimable(NATIVE, licensor), 500 + 1); // 500 share + 1 dust as residualPayee (I6)
    }

    function test_I5_potWithoutSplitSetReverts() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(RoyaltySplitter.NoSplitSet.selector, TRACK1, uint8(IncomeType.MECHANICAL))
        );
        splitter.distributeTrack{value: 1000}(TRACK1, uint8(IncomeType.MECHANICAL), NATIVE, 1000);
    }

    // I6 — Distributed sum == settled amount exactly; dust → residualPayee
    function testFuzz_I6_onChainDistributionSumsExactly(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1, 1e12);
        FeeInstalment[] memory plan = agreementFees();
        plan[0].amountCommitment = commitment(1, amount, SALT1);
        uint256 id = proposeAndAccept(agreementTerms(), plan);
        vm.prank(licensee);
        id = licence.mintFromProposal(id, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));

        vm.prank(licensor);
        fees.discloseAmount(id, 1, amount, SALT1);
        declare(id, TRACK1, PRODUCTION1);
        declare(id, TRACK2, PRODUCTION2);
        declare(id, TRACK1, keccak256("production-3"));

        vm.prank(licensor);
        fees.markInvoiced(id, 1, keccak256("inv"));
        vm.deal(licensee, amount);
        vm.prank(licensee);
        fees.settleOnChain{value: amount}(id, 1, NATIVE, amount);

        vm.prank(licensor);
        splitter.distributeInstalment(id, 1, uint8(ApportionmentPolicy.EQUAL_PER_DECLARATION));

        uint256 total = splitter.claimable(NATIVE, licensor) + splitter.claimable(NATIVE, composerA)
            + splitter.claimable(NATIVE, composerB);
        assertEq(total, amount, "every unit accounted for");
        assertEq(address(splitter).balance, amount, "funds held for withdrawal");
    }

    function test_I6_fiatEntitlementsSumExactly() public {
        uint256 id = mintActive();
        disclose(id);
        declare(id, TRACK1, PRODUCTION1);
        declare(id, TRACK3, PRODUCTION2);
        invoiceAndAttest(id, 2); // YEAR2_AMOUNT = 1_234_567 → odd division
        vm.prank(licensor);
        splitter.distributeInstalment(id, 2, uint8(ApportionmentPolicy.EQUAL_PER_DECLARATION));
        uint256 total =
            splitter.fiatOwed(GBP, licensor) + splitter.fiatOwed(GBP, composerA) + splitter.fiatOwed(GBP, composerB);
        assertEq(total, YEAR2_AMOUNT);
    }

    // OPEN-Q7 — LIBRARY_RETAINS (default for this Licensor)
    function test_policy_libraryRetains_fiatPath() public {
        uint256 id = mintActive();
        disclose(id);
        invoiceAndAttest(id, 1);

        vm.prank(licensor);
        splitter.distributeInstalment(id, 1, uint8(ApportionmentPolicy.LIBRARY_RETAINS));
        assertEq(splitter.fiatOwed(GBP, licensor), YEAR1_AMOUNT);
        assertTrue(splitter.distributed(id, 1));

        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(RoyaltySplitter.AlreadyDistributed.selector, id, 1));
        splitter.distributeInstalment(id, 1, uint8(ApportionmentPolicy.LIBRARY_RETAINS));

        // PHARE settles the fiat entitlement off-chain and attests it down
        vm.prank(attestor);
        splitter.attestFiatPayout(GBP, licensor, 400_000, keccak256("payout-1"));
        assertEq(splitter.fiatOwed(GBP, licensor), 600_000);
        vm.prank(attestor);
        vm.expectRevert(
            abi.encodeWithSelector(RoyaltySplitter.InsufficientFiatOwed.selector, GBP, licensor, 600_000, 600_001)
        );
        splitter.attestFiatPayout(GBP, licensor, 600_001, keccak256("payout-2"));
    }

    function test_policy_requiresPaidAndDisclosed() public {
        uint256 id = mintActive();
        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(RoyaltySplitter.InstalmentNotPaid.selector, id, 1));
        splitter.distributeInstalment(id, 1, uint8(ApportionmentPolicy.LIBRARY_RETAINS));

        invoiceAndAttest(id, 1); // paid, but amount still hash-committed (OPEN-Q10)
        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(RoyaltySplitter.AmountUndisclosed.selector, id, 1));
        splitter.distributeInstalment(id, 1, uint8(ApportionmentPolicy.LIBRARY_RETAINS));
    }

    function test_policy_equalPerDeclaration_revertsWithNoDeclarations() public {
        uint256 id = mintActive();
        disclose(id);
        invoiceAndAttest(id, 1);
        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(RoyaltySplitter.NoDeclarations.selector, id));
        splitter.distributeInstalment(id, 1, uint8(ApportionmentPolicy.EQUAL_PER_DECLARATION));
    }

    function test_policy_weightedByDuration() public {
        uint256 id = mintActive();
        disclose(id);
        bytes32 d1 = declare(id, TRACK1, PRODUCTION1); // weight 30s
        bytes32 d2 = declare(id, TRACK2, PRODUCTION2); // weight 10s
        invoiceAndAttest(id, 1);

        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(RoyaltySplitter.NoWeights.selector, id));
        splitter.distributeInstalment(id, 1, uint8(ApportionmentPolicy.WEIGHTED_BY_DURATION));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = d1;
        ids[1] = d2;
        uint64[] memory w = new uint64[](2);
        w[0] = 30;
        w[1] = 10;
        vm.prank(attestor);
        splitter.setDeclarationWeights(id, ids, w);

        vm.prank(licensor);
        splitter.distributeInstalment(id, 1, uint8(ApportionmentPolicy.WEIGHTED_BY_DURATION));
        // TRACK1 gets 750_000 (50/33.33/16.67), TRACK2 gets 250_000 (50/25/25)
        assertEq(splitter.fiatOwed(GBP, composerB), 750_000 * 1667 / 10_000 + 250_000 * 2500 / 10_000);
        assertEq(splitter.fiatOwed(GBP, composerA), 750_000 * 3333 / 10_000 + 250_000 * 2500 / 10_000);
        uint256 total =
            splitter.fiatOwed(GBP, licensor) + splitter.fiatOwed(GBP, composerA) + splitter.fiatOwed(GBP, composerB);
        assertEq(total, YEAR1_AMOUNT);
    }

    function test_policy_proRataCatalogue() public {
        uint256 id = mintActive();
        disclose(id);
        invoiceAndAttest(id, 1);
        vm.prank(attestor); // PHARE's settlement role may also trigger distribution
        splitter.distributeInstalment(id, 1, uint8(ApportionmentPolicy.PRO_RATA_CATALOGUE));
        // four catalogue tracks × 250_000, split per each track's SYNC table (used or not)
        assertEq(splitter.fiatOwed(GBP, licensor), 550_000);
        assertEq(splitter.fiatOwed(GBP, composerA), 245_825);
        assertEq(splitter.fiatOwed(GBP, composerB), 204_175);
    }

    function test_distributeInstalment_authorisationAndPolicyRange() public {
        uint256 id = mintActive();
        disclose(id);
        invoiceAndAttest(id, 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RoyaltySplitter.NotLicensorOrAttestor.selector, id, stranger));
        splitter.distributeInstalment(id, 1, uint8(ApportionmentPolicy.LIBRARY_RETAINS));
        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(RoyaltySplitter.InvalidPolicy.selector, 4));
        splitter.distributeInstalment(id, 1, 4);
    }

    function test_onChainERC20SettlementAndWithdraw() public {
        uint256 id = mintActive();
        disclose(id);
        vm.prank(licensor);
        fees.markInvoiced(id, 1, keccak256("inv"));

        gbp.mint(licensee, YEAR1_AMOUNT);
        vm.startPrank(licensee);
        gbp.approve(address(fees), YEAR1_AMOUNT);
        fees.settleOnChain(id, 1, address(gbp), YEAR1_AMOUNT);
        vm.stopPrank();
        assertEq(gbp.balanceOf(address(splitter)), YEAR1_AMOUNT);

        vm.prank(licensor);
        splitter.distributeInstalment(id, 1, uint8(ApportionmentPolicy.PRO_RATA_CATALOGUE));
        uint256 owedA = splitter.claimable(address(gbp), composerA);
        assertEq(owedA, 245_825);
        vm.prank(composerA);
        splitter.withdraw(address(gbp));
        assertEq(gbp.balanceOf(composerA), owedA);
        assertEq(splitter.claimable(address(gbp), composerA), 0);
        vm.prank(composerA);
        vm.expectRevert(RoyaltySplitter.ZeroAmount.selector);
        splitter.withdraw(address(gbp));
    }

    function test_nativeWithdraw() public {
        vm.prank(stranger);
        splitter.distributeTrack{value: 1 ether}(TRACK2, SYNC, NATIVE, 1 ether);
        uint256 before = composerB.balance;
        vm.prank(composerB);
        splitter.withdraw(NATIVE);
        assertEq(composerB.balance - before, 0.25 ether);
    }

    function test_receiveInstalment_onlyFeeSchedule() public {
        bytes32 role_ = splitter.FEE_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role_)
        );
        splitter.receiveInstalment{value: 1}(1, 1, NATIVE, 1);
    }
}
