// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BaseTest} from "./BaseTest.sol";
import {ClearanceLedger} from "../src/ClearanceLedger.sol";
import {SubscriptionLicence721} from "../src/SubscriptionLicence721.sol";
import {IClearanceLedger} from "../src/interfaces/IClearanceLedger.sol";
import "../src/Types.sol";

/// @notice §11 step 6 — I2, I3, I8–I10f, I12, I13, I14 and the cl. 2.3 / cl. 4 flows.
contract ClearanceLedgerTest is BaseTest {
    uint32 constant VOD = Media.ONLINE_SHORT_FORM_VOD;

    // I2 — declareSync reverts if !isFullyRegistered(trackId) (cl. 5.1)
    function test_I2_unregisteredTrackReverts() public {
        uint256 id = mintActive();
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.TrackNotFullyRegistered.selector, TRACK_UNCONFIRMED));
        ledger.declareSync(declarationInput(id, TRACK_UNCONFIRMED, PRODUCTION1));

        // the collaborators confirm → the warranty becomes checkable → the same declaration passes
        vm.prank(composerA);
        registry.confirmSplit(TRACK_UNCONFIRMED, uint8(IncomeType.SYNC));
        vm.prank(composerB);
        registry.confirmSplit(TRACK_UNCONFIRMED, uint8(IncomeType.SYNC));
        declare(id, TRACK_UNCONFIRMED, PRODUCTION1);
    }

    // I3 — declareSync reverts if !isInCatalogue (CATALOGUE scope)
    function test_I3_trackOutsideCatalogueReverts() public {
        uint256 id = mintActive();
        assertTrue(registry.isFullyRegistered(TRACK_OUTSIDE));
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.TrackNotInCatalogue.selector, CATALOGUE, TRACK_OUTSIDE));
        ledger.declareSync(declarationInput(id, TRACK_OUTSIDE, PRODUCTION1));
    }

    function test_trackScope_onlyThatTrack() public {
        LicenceTerms memory t = agreementTerms();
        t.scope = LicenceScope.TRACK;
        t.catalogueId = 0;
        t.trackId = TRACK1;
        uint256 id = mintActive(t);
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.TrackNotLicensed.selector, TRACK2));
        ledger.declareSync(declarationInput(id, TRACK2, PRODUCTION1));
        declare(id, TRACK1, PRODUCTION1);
    }

    // I8 — EditedMaterial.owner == licence.licensor; no setter
    function test_I8_editVestsInLicensor() public {
        uint256 id = mintActive();
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        bytes32 editId = keccak256("30s-cutdown");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.NotAuthorisedDeclarer.selector, id, stranger));
        ledger.registerEdit(d, editId, keccak256("edit-audio"));

        vm.prank(licensee);
        vm.expectEmit(true, true, false, true);
        emit IClearanceLedger.EditRegistered(d, editId, keccak256(abi.encode(TRACK1, editId)), licensor);
        bytes32 derived = ledger.registerEdit(d, editId, keccak256("edit-audio"));
        EditedMaterial memory e = ledger.editedMaterial(editId);
        assertEq(e.owner, licensor);
        assertEq(e.parentTrackId, TRACK1);
        assertEq(e.declarationId, d);
        assertEq(registry.ownerOfTrack(derived), licensor);

        (bool ok,) = address(ledger).call(abi.encodeWithSignature("setEditOwner(bytes32,address)", editId, licensee));
        assertFalse(ok);
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.EditExists.selector, editId));
        ledger.registerEdit(d, editId, keccak256("edit-audio-2"));
    }

    // I9 — registerEdit reverts if !editingPermitted
    function test_I9_editingNotPermitted() public {
        LicenceTerms memory t = agreementTerms();
        t.editingPermitted = false;
        uint256 id = mintActive(t);
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.EditingNotPermitted.selector, id));
        ledger.registerEdit(d, keccak256("edit"), keccak256("content"));
    }

    function test_editsOnlyDuringTheTerm() public {
        uint256 id = mintActive();
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        vm.warp(SYNC_TERM_END + 1);
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.LicenceCannotDeclare.selector, id));
        ledger.registerEdit(d, keccak256("edit"), keccak256("content"));
    }

    // I10 — content / media ⊆ terms
    function test_I10_scopeMasksAreDefaultDeny() public {
        LicenceTerms memory t = agreementTerms();
        t.contentMask = Content.ADVERTISING_PAID | Content.ADVERTISING_UNPAID;
        uint256 id = mintActive(t);
        DeclarationInput memory d = declarationInput(id, TRACK1, PRODUCTION1);
        d.contentMask = Content.ADVERTISING_PAID | Content.CORPORATE;
        vm.prank(licensee);
        vm.expectRevert(
            abi.encodeWithSelector(ClearanceLedger.ContentOutOfScope.selector, d.contentMask, t.contentMask)
        );
        ledger.declareSync(d);

        d = declarationInput(id, TRACK1, PRODUCTION1);
        d.mediaMask = VOD | Media.OUT_OF_HOME;
        vm.prank(licensee);
        vm.expectRevert(
            abi.encodeWithSelector(ClearanceLedger.MediaOutOfScope.selector, d.mediaMask, Media.THIS_AGREEMENT)
        );
        ledger.declareSync(d);

        d = declarationInput(id, TRACK1, PRODUCTION1);
        d.mediaMask = 0;
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.MediaOutOfScope.selector, 0, Media.THIS_AGREEMENT));
        ledger.declareSync(d);
    }

    // I10b — every excluded / not-granted medium reverts under this agreement
    function test_I10b_excludedMediaRevert() public {
        uint256 id = mintActive();
        uint32[6] memory excluded =
            [Media.LONG_FORM_VOD, Media.OTT, Media.IPTV, Media.DIGITAL_TV, Media.BROADCAST_TV, Media.CINEMA];
        for (uint256 i = 0; i < excluded.length; i++) {
            DeclarationInput memory d = declarationInput(id, TRACK1, PRODUCTION1);
            d.mediaMask = excluded[i];
            vm.prank(licensee);
            vm.expectRevert(
                abi.encodeWithSelector(ClearanceLedger.MediaOutOfScope.selector, excluded[i], Media.THIS_AGREEMENT)
            );
            ledger.declareSync(d);
        }
        // and every granted medium passes
        uint32[12] memory granted = [
            Media.ONLINE_SHORT_FORM_VOD,
            Media.ONLINE_SOCIAL_PAID,
            Media.ONLINE_SOCIAL_ORGANIC,
            Media.ONLINE_OWNED_OPERATED,
            Media.ONLINE_DISPLAY_VIDEO,
            Media.ONLINE_OTHER_AV,
            Media.FILM_FESTIVAL,
            Media.INDUSTRIAL,
            Media.INTERNAL,
            Media.EVENTS,
            Media.AWARDS_SHOWS,
            Media.PRESENTATIONS
        ];
        for (uint256 i = 0; i < granted.length; i++) {
            DeclarationInput memory d = declarationInput(id, TRACK1, keccak256(abi.encode("prod", i)));
            d.mediaMask = granted[i];
            vm.prank(licensee);
            ledger.declareSync(d);
        }
    }

    // I10c — derivedFromProductionId != 0 reverts unless outOfContextPermitted (cl. 3.1(iv))
    function test_I10c_declaredOutOfContextUseReverts() public {
        uint256 id = mintActive();
        DeclarationInput memory d = declarationInput(id, TRACK1, keccak256("showreel"));
        d.derivedFromProductionId = PRODUCTION1;
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.OutOfContextUse.selector, PRODUCTION1));
        ledger.declareSync(d);

        LicenceTerms memory t = agreementTerms();
        t.outOfContextPermitted = true; // a different licence may permit it (OPEN-Q5 / Q12)
        uint256 id2 = mintActive(t);
        d.licenceId = id2;
        vm.prank(licensee);
        bytes32 did = ledger.declareSync(d);
        assertEq(ledger.declaration(did).derivedFromProductionId, PRODUCTION1);
    }

    // I10d — attestations ⊇ REQUIRED_BASE
    function test_I10d_missingAnyBaseAttestationReverts() public {
        uint256 id = mintActive();
        uint8[4] memory bits = [
            Attestation.NOT_TITLE_OR_STORYLINE,
            Attestation.IN_CONTEXT_ONLY,
            Attestation.NOT_AUDIO_ONLY,
            Attestation.CHARACTER_UNALTERED
        ];
        for (uint256 i = 0; i < bits.length; i++) {
            DeclarationInput memory d = declarationInput(id, TRACK1, PRODUCTION1);
            d.attestations = Attestation.REQUIRED_BASE & ~bits[i];
            vm.prank(licensee);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ClearanceLedger.MissingAttestations.selector, d.attestations, Attestation.REQUIRED_BASE
                )
            );
            ledger.declareSync(d);
        }
    }

    // I10e — title match: flagged + stored, reverts ONLY if TITLE_USE_CONFIRMED is absent
    function test_I10e_titleMatchIsFlaggedNotBlocked() public {
        uint256 id = mintActive();
        DeclarationInput memory d = declarationInput(id, TRACK1, PRODUCTION1);
        d.productionTitleHash = TITLE1; // the campaign is called "Home", like the track
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.TitleUseUnconfirmed.selector, TRACK1));
        ledger.declareSync(d);

        d.attestations = Attestation.REQUIRED_BASE | Attestation.TITLE_USE_CONFIRMED;
        bytes32 expectedId = keccak256(abi.encode(id, TRACK1, PRODUCTION1));
        vm.prank(licensee);
        vm.expectEmit(true, true, false, true);
        emit IClearanceLedger.TitleUseFlagged(expectedId, TRACK1, TITLE1);
        bytes32 did = ledger.declareSync(d);
        assertEq(did, expectedId);
        assertTrue(ledger.declaration(did).titleUseFlagged);
        assertTrue(ledger.verifyClearance(did, "GB", VOD));

        // an innocent, non-matching title is never flagged
        bytes32 did2 = declare(id, TRACK1, PRODUCTION2);
        assertFalse(ledger.declaration(did2).titleUseFlagged);

        // a licence where title use is permitted (OPEN-Q5) still flags but does not require the bit
        LicenceTerms memory t = agreementTerms();
        t.titleUsePermitted = true;
        uint256 id2 = mintActive(t);
        d = declarationInput(id2, TRACK1, PRODUCTION1);
        d.productionTitleHash = TITLE1;
        vm.prank(licensee);
        bytes32 did3 = ledger.declareSync(d);
        assertTrue(ledger.declaration(did3).titleUseFlagged);
    }

    // I10f — reportUndeclaredUse changes no licence or declaration state
    function test_I10f_oracleReportIsEvidenceOnly() public {
        uint256 id = mintActive();
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        bytes32 before = keccak256(abi.encode(licence.licenceOf(id), ledger.declaration(d)));

        bytes32 role_ = ledger.ORACLE_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role_)
        );
        ledger.reportUndeclaredUse(TRACK1, keccak256("sizzle-reel.mp4"), id, keccak256("match"));

        vm.prank(oracle);
        vm.expectEmit(true, false, true, true);
        emit IClearanceLedger.UndeclaredUseDetected(
            TRACK1, keccak256("sizzle-reel.mp4"), id, keccak256("match"), uint64(vm.getBlockTimestamp())
        );
        ledger.reportUndeclaredUse(TRACK1, keccak256("sizzle-reel.mp4"), id, keccak256("match"));

        assertEq(ledger.undeclaredUseCount(), 1);
        assertEq(ledger.undeclaredUse(0).assetFingerprint, keccak256("sizzle-reel.mp4"));
        assertEq(keccak256(abi.encode(licence.licenceOf(id), ledger.declaration(d))), before);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ACTIVE));
        assertTrue(licence.canDeclare(id));
        assertTrue(ledger.verifyClearance(d, "GB", VOD));
    }

    // I12 — verifyClearance(d) is true regardless of licence state, incl. TERMINATED and EXPIRED
    function test_I12_clearanceSurvivesTermination() public {
        uint256 id = mintActive();
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        vm.prank(licensee);
        licence.giveNotice(id);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        licence.finaliseTermination(id);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.TERMINATED));
        assertTrue(ledger.verifyClearance(d, "GB", VOD));
        assertTrue(ledger.verifyClearance(d, "US", Media.ONLINE_SOCIAL_PAID));
    }

    function test_I12_clearanceSurvivesExpiry() public {
        uint256 id = mintActive();
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        vm.warp(SYNC_TERM_END + 1);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.EXPIRED));
        assertTrue(ledger.verifyClearance(d, "GB", VOD));
        licence.touch(id);
        assertTrue(ledger.verifyClearance(d, "GB", VOD));
    }

    function test_I12_clearanceSurvivesRescission_prospectiveOnly() public {
        uint256 id = mintActive();
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        vm.prank(resolver);
        licence.rescind(id, uint8(RescissionGround.BREACH_CL_2_3), keccak256("evidence")); // OPEN-Q9
        assertTrue(ledger.verifyClearance(d, "GB", VOD)); // existing Production keeps its clearance
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.LicenceCannotDeclare.selector, id));
        ledger.declareSync(declarationInput(id, TRACK2, PRODUCTION2)); // no NEW syncs
    }

    // I13 — declareSync reverts when !canDeclare()
    function test_I13_cannotDeclareOutsideTermOrInTerminalState() public {
        uint256 id = mintActive();
        vm.warp(SYNC_TERM_END + 1);
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.LicenceCannotDeclare.selector, id));
        ledger.declareSync(declarationInput(id, TRACK1, PRODUCTION1));
    }

    function test_I13_cannotDeclareBeforeSyncTermStart() public {
        LicenceTerms memory t = agreementTerms();
        t.effectiveFrom = uint64(vm.getBlockTimestamp() + 10 days);
        t.syncTermStart = t.effectiveFrom;
        t.executedAt = t.effectiveFrom;
        uint256 id = mintActive(t);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ACTIVE));
        assertFalse(licence.canDeclare(id));
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.LicenceCannotDeclare.selector, id));
        ledger.declareSync(declarationInput(id, TRACK1, PRODUCTION1));
        vm.warp(t.syncTermStart);
        declare(id, TRACK1, PRODUCTION1);
    }

    function test_I13_cannotDeclareAfterTermination() public {
        uint256 id = mintActive();
        vm.prank(licensee);
        licence.giveNotice(id);
        declare(id, TRACK1, PRODUCTION1); // allowed during notice
        vm.warp(vm.getBlockTimestamp() + 30 days);
        licence.finaliseTermination(id);
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.LicenceCannotDeclare.selector, id));
        ledger.declareSync(declarationInput(id, TRACK1, PRODUCTION2));
    }

    // I14 — allegeBreach changes no licence or declaration state
    function test_I14_allegeBreachIsEvidenceOnly() public {
        uint256 id = mintActive();
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        bytes32 before = keccak256(abi.encode(licence.licenceOf(id), ledger.declaration(d)));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.NotLicensor.selector, id, stranger));
        ledger.allegeBreach(id, d, 6, keccak256("re-recorded"));
        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.InvalidCovenant.selector, 9));
        ledger.allegeBreach(id, d, 9, keccak256("x"));

        vm.prank(licensor);
        vm.expectEmit(true, false, false, true);
        emit IClearanceLedger.BreachAlleged(id, d, 6, keccak256("re-recorded"));
        ledger.allegeBreach(id, d, 6, keccak256("re-recorded"));
        vm.prank(licensor);
        ledger.allegeBreach(id, bytes32(0), 5, keccak256("licence-level"));

        assertEq(ledger.allegationCount(), 2);
        assertEq(ledger.allegation(0).covenant, 6);
        assertEq(keccak256(abi.encode(licence.licenceOf(id), ledger.declaration(d))), before);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ACTIVE));
        assertTrue(licence.canDeclare(id));
    }

    // cl. 6.3 — the first declareSync binds an ISSUED licence
    function test_firstSyncBindsIssuedLicence() public {
        uint256 pid = proposeAndAccept();
        vm.prank(licensor);
        uint256 id = licence.issue(pid);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ISSUED));
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        Licence memory l = licence.licenceOf(id);
        assertEq(uint8(l.state), uint8(LicenceState.ACTIVE));
        assertEq(uint8(l.boundBy), uint8(BindingTrigger.FIRST_SYNC));
        assertTrue(ledger.verifyClearance(d, "GB", VOD));
    }

    // cl. 2.5 / 2.6 — who may declare and who may own the Production
    function test_declarerAndProductionOwnerRules() public {
        uint256 id = mintActive();
        DeclarationInput memory d = declarationInput(id, TRACK1, PRODUCTION1);
        vm.prank(agency);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.NotAuthorisedDeclarer.selector, id, agency));
        ledger.declareSync(d);

        vm.startPrank(licensee);
        licence.setAuthorisedParty(id, agency, 1, true);
        licence.setAuthorisedParty(id, client, 2, true);
        licence.setAuthorisedParty(id, groupCo, 3, true);
        vm.stopPrank();

        vm.prank(agency); // agency declares on behalf of the brand — Production owned by the brand
        bytes32 did = ledger.declareSync(d);
        assertEq(ledger.declaration(did).declaredBy, agency);

        d = declarationInput(id, TRACK1, PRODUCTION2);
        d.productionOwner = agency; // an agency may not own the commissioned Production
        vm.prank(agency);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.InvalidProductionOwner.selector, id, agency));
        ledger.declareSync(d);

        d.productionOwner = client; // an advertising client may
        vm.prank(agency);
        ledger.declareSync(d);
        d = declarationInput(id, TRACK2, PRODUCTION2);
        d.productionOwner = groupCo; // so may a group company
        vm.prank(licensee);
        ledger.declareSync(d);
    }

    function test_duplicateDeclarationReverts() public {
        uint256 id = mintActive();
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.AlreadyDeclared.selector, d));
        ledger.declareSync(declarationInput(id, TRACK1, PRODUCTION1));
        assertEq(ledger.declarationCount(id), 1);
        assertEq(ledger.declarationIdsOf(id)[0], d);
    }

    function test_verifyClearance_territoryMediaAndUnknown() public {
        LicenceTerms memory t = agreementTerms();
        t.distributionTerritory.excluded = new bytes2[](1);
        t.distributionTerritory.excluded[0] = "RU";
        uint256 id = mintActive(t);
        bytes32 d = declare(id, TRACK1, PRODUCTION1); // media: VOD | SOCIAL_PAID
        assertTrue(ledger.verifyClearance(d, "GB", VOD));
        assertTrue(ledger.verifyClearance(d, bytes2(0), VOD)); // territory not asked
        assertFalse(ledger.verifyClearance(d, "RU", VOD)); // carved out of worldwide
        assertFalse(ledger.verifyClearance(d, "GB", Media.PRESENTATIONS)); // not in this declaration
        assertFalse(ledger.verifyClearance(d, "GB", 0));
        assertFalse(ledger.verifyClearance(keccak256("nope"), "GB", VOD));

        LicenceTerms memory t2 = agreementTerms();
        t2.distributionTerritory.worldwide = false;
        t2.distributionTerritory.included = new bytes2[](2);
        t2.distributionTerritory.included[0] = "FR";
        t2.distributionTerritory.included[1] = "GB";
        uint256 id2 = mintActive(t2);
        bytes32 d2 = declare(id2, TRACK1, PRODUCTION1);
        assertTrue(ledger.verifyClearance(d2, "FR", VOD));
        assertFalse(ledger.verifyClearance(d2, "US", VOD));
    }

    function test_verifyClearance_finiteDistributionTerm() public {
        LicenceTerms memory t = agreementTerms();
        t.distributionPerpetual = false;
        t.distributionTermEnd = SYNC_TERM_END + 365 days;
        uint256 id = mintActive(t);
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        assertFalse(ledger.declaration(d).distributionPerpetual);
        vm.warp(SYNC_TERM_END + 365 days);
        assertTrue(ledger.verifyClearance(d, "GB", VOD));
        vm.warp(SYNC_TERM_END + 365 days + 1);
        assertFalse(ledger.verifyClearance(d, "GB", VOD));
    }

    // cl. 2.3 — challenge / resolve are attestations, never auto-decided
    function test_editChallengeFlow() public {
        uint256 id = mintActive();
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        bytes32 editId = keccak256("edit");
        vm.prank(licensee);
        ledger.registerEdit(d, editId, keccak256("content"));
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.NotLicensor.selector, id, licensee));
        ledger.challengeEdit(editId, keccak256("new melody"));
        vm.prank(licensor);
        vm.expectEmit(true, false, false, true);
        emit IClearanceLedger.EditChallenged(editId, keccak256("new melody"));
        ledger.challengeEdit(editId, keccak256("new melody"));
        assertTrue(ledger.editedMaterial(editId).challenged);
        vm.prank(resolver);
        ledger.resolveEditChallenge(editId, true);
        assertFalse(ledger.editedMaterial(editId).challenged);
        assertTrue(ledger.editChallengeUpheld(editId));
        assertEq(ledger.editedMaterial(editId).owner, licensor); // ownership unaffected either way (I8)
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ACTIVE)); // a 2.3 breach is enforced via rescind, not here
    }

    // cl. 4 — reporting
    function test_usageReports() public {
        uint256 id = mintActive();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ClearanceLedger.NotLicensor.selector, id, stranger));
        ledger.requestUsageReport(id);
        vm.prank(licensor);
        ledger.requestUsageReport(id);
        vm.prank(licensor);
        ledger.requestUsageReport(id);
        assertEq(ledger.outstandingReports(id), 2);
        vm.prank(licensee);
        ledger.submitUsageReport(id, keccak256("q1"), "ipfs://q1");
        assertEq(ledger.outstandingReports(id), 1);
        assertEq(ledger.usageReport(id, 0).reportHash, keccak256("q1"));
        assertEq(ledger.usageReport(id, 1).submittedAt, 0);
        vm.prank(licensee);
        ledger.submitUsageReport(id, keccak256("q2"), "ipfs://q2");
        vm.prank(licensee);
        ledger.submitUsageReport(id, keccak256("voluntary"), "ipfs://v"); // voluntary
        assertEq(ledger.outstandingReports(id), 0);
        assertEq(ledger.usageReportCount(id), 3);
        assertEq(ledger.usageReport(id, 2).requestedAt, 0);
    }
}
