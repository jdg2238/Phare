// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {ClearanceLedger} from "../src/ClearanceLedger.sol";
import "../src/Types.sol";

/// @notice §11 step 7 — the 2031 broadcaster check, plus the whole lifecycle end to end.
contract IntegrationTest is BaseTest {
    /// @dev A declaration made in 2025 under a licence that expired on 11 April 2026 must verify
    ///      true in 2031. If this test does not exist, clause 9.2 has not been implemented.
    function test_2031BroadcasterCheck() public {
        uint256 id = mintActive();

        vm.warp(T_2025_03_01);
        bytes32 d = declare(id, TRACK1, PRODUCTION1);

        vm.warp(T_2031_01_01);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.EXPIRED));
        assertFalse(licence.canDeclare(id));
        assertTrue(ledger.verifyClearance(d, "GB", Media.ONLINE_SHORT_FORM_VOD), "2031: still cleared");
        assertTrue(ledger.verifyClearance(d, "JP", Media.ONLINE_SOCIAL_PAID), "2031: worldwide");

        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.LicenceCannotDeclare.selector, id));
        ledger.declareSync(declarationInput(id, TRACK2, PRODUCTION2));

        licence.touch(id);
        assertTrue(ledger.verifyClearance(d, "GB", Media.ONLINE_SHORT_FORM_VOD), "persisted expiry changes nothing");
        SyncDeclaration memory rec = ledger.declaration(d);
        assertEq(rec.declaredAt, T_2025_03_01);
        assertTrue(rec.distributionPerpetual);
    }

    function test_fullLifecycle() public {
        // LEVEL 2 — negotiation with one counter
        vm.prank(licensee);
        uint256 pid = negotiation.propose(agreementTerms(), agreementFees());
        LicenceTerms memory revised = agreementTerms();
        revised.termsHash = keccak256("executed-agreement-final.docx");
        vm.prank(licensor);
        negotiation.counter(pid, revised, agreementFees());
        vm.prank(licensee);
        negotiation.accept(pid);

        // LEVEL 3 — binding by download (cl. 6.3), observed by PHARE
        vm.prank(platform);
        uint256 id = licence.mintFromProposal(pid, uint8(BindingTrigger.DOWNLOAD));
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ACTIVE));
        assertEq(fees.instalmentCount(id), 2);

        // LEVEL 4 — fee: invoice → fiat settlement attested by PHARE
        invoiceAndAttest(id, 1);

        // LEVEL 4 — use: brand and its agency declare Productions
        vm.prank(licensee);
        licence.setAuthorisedParty(id, agency, 1, true);
        bytes32 d1 = declare(id, TRACK1, PRODUCTION1);
        vm.warp(T_2025_03_01);
        vm.prank(agency);
        bytes32 d2 = ledger.declareSync(declarationInput(id, TRACK2, PRODUCTION2));

        // LEVEL 4 — edits vest in the licensor
        vm.prank(licensee);
        ledger.registerEdit(d1, keccak256("cutdown"), keccak256("cutdown-audio"));
        assertEq(ledger.editedMaterial(keccak256("cutdown")).owner, licensor);

        // LEVEL 4 — money: amounts disclosed, Year-1 fee apportioned per declaration
        disclose(id);
        vm.prank(licensor);
        splitter.distributeInstalment(id, 1, uint8(ApportionmentPolicy.EQUAL_PER_DECLARATION));
        uint256 total = splitter.fiatOwed("GBP", licensor) + splitter.fiatOwed("GBP", composerA)
            + splitter.fiatOwed("GBP", composerB);
        assertEq(total, YEAR1_AMOUNT);

        // LEVEL 4 — exit: brand gives notice in Year 1
        vm.prank(licensee);
        licence.giveNotice(id);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        licence.finaliseTermination(id);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.TERMINATED));

        // OPEN-Q4 — Year-2 instalment survives termination and is still collectable
        vm.warp(YEAR2_SCHEDULED);
        invoiceAndAttest(id, 2);
        assertTrue(fees.allPaid(id));

        // LEVEL 5 — survival: both Productions stay cleared, forever
        vm.warp(T_2031_01_01);
        assertTrue(ledger.verifyClearance(d1, "GB", Media.ONLINE_SHORT_FORM_VOD));
        assertTrue(ledger.verifyClearance(d2, "DE", Media.ONLINE_SOCIAL_PAID));
    }
}
