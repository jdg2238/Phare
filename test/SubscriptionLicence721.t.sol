// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BaseTest} from "./BaseTest.sol";
import {SubscriptionLicence721} from "../src/SubscriptionLicence721.sol";
import {ISubscriptionLicence721} from "../src/interfaces/ISubscriptionLicence721.sol";
import "../src/Types.sol";

/// @notice §11 step 5 — I7, I11, I13, I15–I19 and the §8.2 licence machine.
contract SubscriptionLicence721Test is BaseTest {
    // I7 — transfer to a non-affiliate without unexpired licensor consent reverts
    function test_I7_transferWithoutConsentIsNullAndVoid() public {
        uint256 id = mintActive();
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.TransferNotPermitted.selector, id, stranger));
        licence.transferFrom(licensee, stranger, id);

        // consent granted but expired
        vm.prank(licensor);
        licence.consentToTransfer(id, stranger, uint64(vm.getBlockTimestamp() + 1 days));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.TransferNotPermitted.selector, id, stranger));
        licence.transferFrom(licensee, stranger, id);

        // consent for a different address does not help
        vm.prank(licensor);
        licence.consentToTransfer(id, composerA, uint64(vm.getBlockTimestamp() + 1 days));
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.TransferNotPermitted.selector, id, stranger));
        licence.transferFrom(licensee, stranger, id);
        assertEq(licence.ownerOf(id), licensee);
    }

    function test_I7_consentedTransferSucceedsAndConsumesConsent() public {
        uint256 id = mintActive();
        vm.prank(licensor);
        vm.expectEmit(true, false, false, true);
        emit ISubscriptionLicence721.TransferConsented(id, stranger, uint64(vm.getBlockTimestamp() + 7 days));
        licence.consentToTransfer(id, stranger, uint64(vm.getBlockTimestamp() + 7 days));
        vm.prank(licensee);
        licence.transferFrom(licensee, stranger, id);
        assertEq(licence.ownerOf(id), stranger);
        assertEq(licence.licenseeOf(id), stranger);
        assertTrue(licence.isAuthorised(id, stranger));
        assertFalse(licence.isAuthorised(id, licensee));
        (address to,) = licence.transferConsent(id);
        assertEq(to, address(0)); // consumed
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.TransferNotPermitted.selector, id, licensee));
        licence.transferFrom(stranger, licensee, id);
    }

    // I7b — transfer to an affiliate never requires consent
    function test_I7b_affiliateTransferIsFree() public {
        uint256 id = mintActive();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.NotLicensee.selector, id, stranger));
        licence.setAffiliate(id, affiliate, true);
        vm.prank(licensee);
        licence.setAffiliate(id, affiliate, true);
        vm.prank(licensee);
        licence.transferFrom(licensee, affiliate, id);
        assertEq(licence.ownerOf(id), affiliate);
        assertEq(licence.licenseeOf(id), affiliate);
        assertTrue(licence.canDeclare(id));
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ACTIVE));
    }

    // I11 — LicenceTerms immutable after mint; variation creates a new token
    function test_I11_termsImmutable_variationIsNewToken() public {
        uint256 id = mintActive();
        string[3] memory sigs =
            ["setTerms(uint256,bytes)", "updateTerms(uint256,bytes)", "setSyncTermEnd(uint256,uint64)"];
        for (uint256 i = 0; i < sigs.length; i++) {
            vm.prank(admin);
            (bool ok,) = address(licence).call(abi.encodeWithSignature(sigs[i], id, uint64(0)));
            assertFalse(ok, sigs[i]);
        }

        LicenceTerms memory v2 = agreementTerms();
        v2.termsHash = keccak256("variation-v2");
        v2.mediaMask = Media.THIS_AGREEMENT | Media.OUT_OF_HOME;
        uint256 pid2 = proposeAndAccept(v2, agreementFees());

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.NotAParty.selector, id, stranger));
        licence.supersede(id, pid2);

        vm.prank(licensee);
        vm.expectEmit(true, true, false, true);
        emit ISubscriptionLicence721.Superseded(id, id + 1);
        uint256 newId = licence.supersede(id, pid2);

        Licence memory old = licence.licenceOf(id);
        assertEq(old.terms.termsHash, TERMS_HASH); // untouched
        assertEq(old.terms.mediaMask, Media.THIS_AGREEMENT);
        assertEq(uint8(old.state), uint8(LicenceState.TERMINATED));
        assertEq(old.supersededBy, newId);

        Licence memory fresh = licence.licenceOf(newId);
        assertEq(fresh.terms.termsHash, keccak256("variation-v2"));
        assertEq(uint8(fresh.state), uint8(LicenceState.ACTIVE));
        assertEq(uint8(fresh.boundBy), uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
        assertEq(licence.ownerOf(newId), licensee);
        assertEq(fees.instalmentCount(id), 2); // old obligations remain (cl. 2.4 / 6.2)
        assertEq(fees.instalmentCount(newId), 2);
    }

    function test_supersede_partiesMustMatch() public {
        uint256 id = mintActive();
        LicenceTerms memory t = agreementTerms();
        vm.prank(stranger);
        uint256 pid = negotiation.propose(t, agreementFees());
        vm.prank(licensor);
        negotiation.accept(pid);
        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.PartiesMismatch.selector, pid));
        licence.supersede(id, pid);
    }

    // I15 — rescind reverts for any ground outside RescissionGround (and OPEN-Q6 for cl. 8)
    function test_I15_rescindRejectsUnknownGrounds() public {
        uint256 id = mintActive();
        vm.startPrank(resolver);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.InvalidRescissionGround.selector, 4));
        licence.rescind(id, 4, keccak256("evidence"));
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.InvalidRescissionGround.selector, 255));
        licence.rescind(id, 255, keccak256("evidence"));
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.RescissionGroundUnresolved.selector, 3));
        licence.rescind(id, uint8(RescissionGround.BREACH_CL_8_SIC), keccak256("evidence")); // OPEN-Q6
        vm.expectEmit(true, false, false, true);
        emit ISubscriptionLicence721.Rescinded(id, uint8(RescissionGround.NON_PAYMENT), keccak256("evidence"));
        licence.rescind(id, uint8(RescissionGround.NON_PAYMENT), keccak256("evidence"));
        vm.stopPrank();
        assertEq(uint8(stateOf(id)), uint8(LicenceState.RESCINDED));
        assertFalse(licence.canDeclare(id));
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.WrongState.selector, id, LicenceState.RESCINDED));
        licence.rescind(id, uint8(RescissionGround.BREACH_CL_7), keccak256("evidence"));
    }

    // I16 — no function callable by the licensor moves the licence out of ACTIVE except rescind
    function test_I16_licensorCannotLeaveActive() public {
        uint256 id = mintActive();
        bytes32 d = declare(id, TRACK1, PRODUCTION1);
        vm.startPrank(licensor);
        licence.consentToTransfer(id, stranger, uint64(vm.getBlockTimestamp() + 1 days));
        fees.markInvoiced(id, 1, keccak256("inv"));
        ledger.requestUsageReport(id);
        ledger.allegeBreach(id, d, 6, keccak256("evidence"));
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.NotLicensee.selector, id, licensor));
        licence.giveNotice(id);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.WrongState.selector, id, LicenceState.ACTIVE));
        licence.finaliseTermination(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, licensor, licence.RESOLVER_ROLE()
            )
        );
        licence.rescind(id, uint8(RescissionGround.NON_PAYMENT), keccak256("evidence"));
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.NotLicensee.selector, id, licensor));
        licence.setAuthorisedParty(id, stranger, 1, true);
        // there is no suspend / pause / terminate entrypoint for the licensor at all
        string[4] memory sigs = ["suspend(uint256)", "pause(uint256)", "terminate(uint256)", "revoke(uint256)"];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(licence).call(abi.encodeWithSignature(sigs[i], id));
            assertFalse(ok, sigs[i]);
        }
        vm.stopPrank();
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ACTIVE));
        assertTrue(licence.canDeclare(id));
    }

    // I17 — finaliseTermination reverts before noticeGivenAt + licenseeNoticeDays
    function test_I17_noticePeriodMustElapse() public {
        uint256 id = mintActive();
        vm.prank(licensee);
        vm.expectEmit(true, false, false, true);
        emit ISubscriptionLicence721.NoticeGiven(
            id, uint64(vm.getBlockTimestamp()), uint64(vm.getBlockTimestamp() + 30 days)
        );
        licence.giveNotice(id);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.NOTICE_GIVEN));
        assertTrue(licence.canDeclare(id)); // still licensed during the notice period
        uint64 effectiveAt = uint64(vm.getBlockTimestamp() + 30 days);

        vm.warp(effectiveAt - 1);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.NoticePeriodRunning.selector, id, effectiveAt));
        licence.finaliseTermination(id);

        vm.warp(effectiveAt);
        vm.prank(stranger); // anyone
        licence.finaliseTermination(id);
        Licence memory l = licence.licenceOf(id);
        assertEq(uint8(l.state), uint8(LicenceState.TERMINATED));
        assertEq(l.terminatedAt, effectiveAt);
        assertFalse(licence.canDeclare(id));

        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.WrongState.selector, id, LicenceState.TERMINATED));
        licence.giveNotice(id);
    }

    function test_giveNotice_allowedFromPaymentHold() public {
        uint256 id = mintActive();
        vm.prank(address(fees));
        licence.setPaymentHold(id);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.PAYMENT_HOLD));
        vm.prank(licensee);
        licence.giveNotice(id);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.NOTICE_GIVEN));
        assertFalse(licence.canDeclare(id)); // hold still applies while in notice
    }

    // I18 — mintFromProposal records exactly one BindingTrigger and boundAt
    function test_I18_exactlyOneBindingEvent() public {
        uint256 pid = proposeAndAccept();
        vm.prank(licensee);
        vm.expectEmit(true, true, true, true);
        emit ISubscriptionLicence721.LicenceMinted(
            1, licensor, licensee, TERMS_HASH, uint8(BindingTrigger.WRITTEN_ACCEPTANCE), EFFECTIVE_FROM, SYNC_TERM_END
        );
        uint256 id = licence.mintFromProposal(pid, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
        Licence memory l = licence.licenceOf(id);
        assertEq(uint8(l.boundBy), uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
        assertEq(l.boundAt, vm.getBlockTimestamp());
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.WrongState.selector, id, LicenceState.ACTIVE));
        licence.bind(id, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.WrongState.selector, id, LicenceState.ACTIVE));
        licence.bind(id, uint8(BindingTrigger.DOWNLOAD));
        assertEq(uint8(licence.licenceOf(id).boundBy), uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
    }

    // cl. 6.3 — who may assert which binding event
    function test_bindingTriggerAuthorisation() public {
        uint256 pid = proposeAndAccept();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                SubscriptionLicence721.TriggerNotAuthorised.selector, uint8(BindingTrigger.WRITTEN_ACCEPTANCE), stranger
            )
        );
        licence.mintFromProposal(pid, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
        vm.prank(licensee);
        vm.expectRevert(
            abi.encodeWithSelector(
                SubscriptionLicence721.TriggerNotAuthorised.selector, uint8(BindingTrigger.DOWNLOAD), licensee
            )
        );
        licence.mintFromProposal(pid, uint8(BindingTrigger.DOWNLOAD));
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.InvalidTrigger.selector, 7));
        licence.mintFromProposal(pid, 7);

        vm.prank(platform); // PHARE observes a download
        uint256 id = licence.mintFromProposal(pid, uint8(BindingTrigger.DOWNLOAD));
        assertEq(uint8(licence.licenceOf(id).boundBy), uint8(BindingTrigger.DOWNLOAD));
        assertEq(licence.ownerOf(id), licensee);

        uint256 pid2 = proposeAndAccept();
        vm.prank(licensor);
        uint256 id2 = licence.mintFromProposal(pid2, uint8(BindingTrigger.COUNTERSIGNATURE));
        assertEq(uint8(licence.licenceOf(id2).boundBy), uint8(BindingTrigger.COUNTERSIGNATURE));
    }

    function test_issueThenBind() public {
        uint256 pid = proposeAndAccept();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.NotAParty.selector, 0, stranger));
        licence.issue(pid);
        vm.prank(platform);
        uint256 id = licence.issue(pid);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ISSUED));
        assertEq(licence.ownerOf(id), licensee);
        assertFalse(licence.canDeclare(id));
        vm.prank(licensee);
        licence.bind(id, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ACTIVE));
    }

    // §8.2 — expiry is computed; persisted lazily on touch
    function test_expiryIsComputedWithoutATransaction() public {
        uint256 id = mintActive();
        vm.warp(SYNC_TERM_END);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.ACTIVE));
        assertTrue(licence.canDeclare(id));
        vm.warp(SYNC_TERM_END + 1);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.EXPIRED));
        assertFalse(licence.canDeclare(id));
        vm.expectEmit(true, false, false, true);
        emit ISubscriptionLicence721.LicenceStateChanged(id, uint8(LicenceState.ACTIVE), uint8(LicenceState.EXPIRED));
        licence.touch(id);
        assertEq(uint8(licence.licenceOf(id).state), uint8(LicenceState.EXPIRED));
        assertEq(licence.ownerOf(id), licensee); // expired tokens are not burned — the record is the receipt
    }

    function test_issuedLicenceLapsesAndIsBurned() public {
        uint256 pid = proposeAndAccept();
        vm.prank(licensor);
        uint256 id = licence.issue(pid);
        vm.warp(vm.getBlockTimestamp() + 30 days + 1);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.LAPSED));
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.WrongState.selector, id, LicenceState.LAPSED));
        licence.bind(id, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
        licence.touch(id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        licence.ownerOf(id);
        assertEq(uint8(licence.licenceOf(id).state), uint8(LicenceState.LAPSED)); // record survives
    }

    function test_noticeOvertakenByExpiryIsEquivalent() public {
        uint256 id = mintActive();
        vm.warp(SYNC_TERM_END - 10 days);
        vm.prank(licensee);
        licence.giveNotice(id);
        vm.warp(SYNC_TERM_END + 1);
        assertEq(uint8(stateOf(id)), uint8(LicenceState.EXPIRED));
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.WrongState.selector, id, LicenceState.EXPIRED));
        licence.finaliseTermination(id);
    }

    function test_authorisedParties() public {
        uint256 id = mintActive();
        vm.startPrank(licensee);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.InvalidRole.selector, 0));
        licence.setAuthorisedParty(id, agency, 0, true);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.InvalidRole.selector, 4));
        licence.setAuthorisedParty(id, agency, 4, true);
        vm.expectEmit(true, false, false, true);
        emit ISubscriptionLicence721.AuthorisedPartySet(id, agency, 1, true);
        licence.setAuthorisedParty(id, agency, 1, true);
        licence.setAuthorisedPartyWithId(id, client, 2, keccak256("client-co"), true);
        vm.stopPrank();
        assertTrue(licence.isAuthorised(id, agency));
        assertTrue(licence.isAuthorised(id, client));
        assertTrue(licence.isAuthorised(id, licensee));
        assertFalse(licence.isAuthorised(id, stranger));
        assertEq(licence.authorisedParty(id, client).partyId, keccak256("client-co"));
        vm.prank(licensee);
        licence.setAuthorisedParty(id, agency, 1, false);
        assertFalse(licence.isAuthorised(id, agency));
    }

    function test_consentToTransfer_validation() public {
        uint256 id = mintActive();
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.NotLicensor.selector, id, licensee));
        licence.consentToTransfer(id, stranger, uint64(vm.getBlockTimestamp() + 1));
        vm.prank(licensor);
        vm.expectRevert(
            abi.encodeWithSelector(SubscriptionLicence721.ConsentExpiry.selector, uint64(vm.getBlockTimestamp()))
        );
        licence.consentToTransfer(id, stranger, uint64(vm.getBlockTimestamp()));
    }

    function test_mintRenewalLinksTokens() public {
        uint256 id = mintActive();
        vm.warp(SYNC_TERM_END + 1);
        LicenceTerms memory t = agreementTerms();
        t.effectiveFrom = SYNC_TERM_END + 1;
        t.syncTermStart = SYNC_TERM_END + 1;
        t.executedAt = SYNC_TERM_END + 1;
        t.syncTermEnd = SYNC_TERM_END + 730 days;
        t.termsHash = keccak256("renewal");
        uint256 pid = proposeAndAccept(t, agreementFees());
        vm.prank(licensee);
        uint256 newId = licence.mintRenewal(id, pid, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
        assertEq(licence.licenceOf(newId).renewalOf, id);
        assertEq(uint8(stateOf(newId)), uint8(LicenceState.ACTIVE));
        assertEq(uint8(stateOf(id)), uint8(LicenceState.EXPIRED));
    }

    function test_tokenURI_andPaymentTerms() public {
        uint256 id = mintActive();
        assertEq(licence.tokenURI(id), "ipfs://encrypted-terms");
        (PaymentRule rule, uint32 dueDays, bytes3 currency) = licence.paymentTermsOf(id);
        assertEq(uint8(rule), uint8(PaymentRule.DAYS_AFTER_INVOICE));
        assertEq(dueDays, 60);
        assertEq(currency, bytes3("GBP"));
    }

    function test_holdHooksRestrictedToFeeSchedule() public {
        uint256 id = mintActive();
        bytes32 role_ = licence.FEE_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role_)
        );
        licence.setPaymentHold(id);
    }

    function test_upgradeRestrictedToUpgrader() public {
        uint256 id = mintActive();
        SubscriptionLicence721 impl = new SubscriptionLicence721();
        bytes32 role_ = licence.UPGRADER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role_)
        );
        licence.upgradeToAndCall(address(impl), "");
        vm.prank(admin);
        licence.upgradeToAndCall(address(impl), "");
        assertEq(licence.licenceOf(id).terms.termsHash, TERMS_HASH);
        assertEq(licence.ownerOf(id), licensee);
    }
}
