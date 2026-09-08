// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {LicenceNegotiation} from "../src/LicenceNegotiation.sol";
import {SubscriptionLicence721} from "../src/SubscriptionLicence721.sol";
import {ILicenceNegotiation} from "../src/interfaces/ILicenceNegotiation.sol";
import "../src/Types.sol";

/// @notice §11 step 4 — the §8.1 proposal machine and I19.
contract LicenceNegotiationTest is BaseTest {
    function test_propose_storesOutcomeAndEmitsHcsTopic() public {
        vm.prank(licensee);
        vm.expectEmit(true, true, true, true);
        emit ILicenceNegotiation.Proposed(1, licensee, CATALOGUE, TERMS_HASH, HCS_TOPIC);
        uint256 pid = negotiation.propose(agreementTerms(), agreementFees());
        LicenceNegotiation.Proposal memory p = negotiation.getProposal(pid);
        assertEq(p.licensor, licensor);
        assertEq(p.licensee, licensee);
        assertEq(p.lastOfferor, licensee);
        assertEq(uint8(p.state), uint8(ProposalState.PROPOSED));
        assertEq(p.fees.length, 2);
        assertEq(p.terms.termsHash, TERMS_HASH);
        assertTrue(p.terms.syncTerritory.worldwide);
    }

    function test_counter_alternatesBetweenParties() public {
        vm.prank(licensee);
        uint256 pid = negotiation.propose(agreementTerms(), agreementFees());

        vm.prank(licensee); // cannot counter your own standing offer
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.NotYourTurn.selector, pid, licensee));
        negotiation.counter(pid, agreementTerms(), agreementFees());

        LicenceTerms memory revised = agreementTerms();
        revised.termsHash = keccak256("v2");
        revised.dueDaysAfterInvoice = 45;
        vm.prank(licensor);
        vm.expectEmit(true, true, false, true);
        emit ILicenceNegotiation.Countered(pid, licensor, keccak256("v2"));
        negotiation.counter(pid, revised, agreementFees());
        LicenceNegotiation.Proposal memory p = negotiation.getProposal(pid);
        assertEq(uint8(p.state), uint8(ProposalState.COUNTERED));
        assertEq(p.lastOfferor, licensor);
        assertEq(p.terms.dueDaysAfterInvoice, 45);

        vm.prank(licensor); // now it is the licensee's turn
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.NotYourTurn.selector, pid, licensor));
        negotiation.accept(pid);

        vm.prank(licensee);
        vm.expectEmit(true, false, false, true);
        emit ILicenceNegotiation.Accepted(pid, keccak256("v2"));
        negotiation.accept(pid);
        assertEq(uint8(negotiation.stateOf(pid)), uint8(ProposalState.ACCEPTED));
    }

    function test_counter_cannotChangeLicensor() public {
        vm.prank(licensee);
        uint256 pid = negotiation.propose(agreementTerms(), agreementFees());
        bytes32 other = keccak256("other-catalogue");
        vm.prank(admin);
        registry.createCatalogue(other, composerA);
        LicenceTerms memory revised = agreementTerms();
        revised.catalogueId = other;
        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.LicensorMismatch.selector, licensor, composerA));
        negotiation.counter(pid, revised, agreementFees());
    }

    function test_reject_withdraw_andStrangers() public {
        vm.prank(licensee);
        uint256 pid = negotiation.propose(agreementTerms(), agreementFees());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.NotAParty.selector, pid, stranger));
        negotiation.accept(pid);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.NotAParty.selector, pid, stranger));
        negotiation.reject(pid);
        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.NotOfferor.selector, pid, licensor));
        negotiation.withdraw(pid);

        vm.prank(licensee);
        negotiation.withdraw(pid);
        assertEq(uint8(negotiation.stateOf(pid)), uint8(ProposalState.WITHDRAWN));
        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.NotOpen.selector, pid, ProposalState.WITHDRAWN));
        negotiation.accept(pid);

        vm.prank(licensee);
        uint256 pid2 = negotiation.propose(agreementTerms(), agreementFees());
        vm.prank(licensor);
        negotiation.reject(pid2);
        assertEq(uint8(negotiation.stateOf(pid2)), uint8(ProposalState.REJECTED));
    }

    function test_lapse_isComputedThenPersisted() public {
        vm.prank(licensee);
        uint256 pid = negotiation.propose(agreementTerms(), agreementFees());
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.NotYetLapsed.selector, pid));
        negotiation.lapse(pid);

        vm.warp(vm.getBlockTimestamp() + 30 days + 1);
        assertEq(uint8(negotiation.stateOf(pid)), uint8(ProposalState.LAPSED));
        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.NotOpen.selector, pid, ProposalState.LAPSED));
        negotiation.accept(pid);
        negotiation.lapse(pid);
        assertEq(uint8(negotiation.getProposal(pid).state), uint8(ProposalState.LAPSED));
    }

    // I19 — effectiveFrom ≤ executedAt is permitted; syncTermStart == effectiveFrom
    function test_I19_retrospectiveEffectPermitted_syncStartEqualsEffectiveFrom() public {
        LicenceTerms memory t = agreementTerms();
        assertLt(t.effectiveFrom, t.executedAt); // 12 Apr 2024 < 4 Jun 2024
        uint256 pid = proposeAndAccept(t, agreementFees()); // accepted as-is
        assertEq(negotiation.getProposal(pid).terms.syncTermStart, EFFECTIVE_FROM);

        t = agreementTerms();
        t.syncTermStart = EXECUTED_AT;
        vm.prank(licensee);
        vm.expectRevert(
            abi.encodeWithSelector(LicenceNegotiation.InvalidTerms.selector, "syncTermStart != effectiveFrom")
        );
        negotiation.propose(t, agreementFees());

        t = agreementTerms();
        t.executedAt = EFFECTIVE_FROM - 1;
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.InvalidTerms.selector, "executedAt < effectiveFrom"));
        negotiation.propose(t, agreementFees());
    }

    function test_structuralValidation() public {
        LicenceTerms memory t = agreementTerms();
        t.mediaMask = 0;
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.InvalidTerms.selector, "mediaMask"));
        negotiation.propose(t, agreementFees());

        t = agreementTerms();
        t.distributionPerpetual = false;
        t.distributionTermEnd = SYNC_TERM_END - 1;
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.InvalidTerms.selector, "distributionTermEnd"));
        negotiation.propose(t, agreementFees());

        t = agreementTerms();
        t.proposalExpiry = uint64(vm.getBlockTimestamp());
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.InvalidTerms.selector, "proposalExpiry"));
        negotiation.propose(t, agreementFees());

        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.InvalidTerms.selector, "fees"));
        negotiation.propose(agreementTerms(), new FeeInstalment[](0));

        vm.prank(licensor); // a licensor cannot propose to itself
        vm.expectRevert(LicenceNegotiation.SelfDealing.selector);
        negotiation.propose(agreementTerms(), agreementFees());
    }

    function test_trackScope_derivesLicensorFromTrackOwner() public {
        LicenceTerms memory t = agreementTerms();
        t.scope = LicenceScope.TRACK;
        t.catalogueId = 0;
        t.trackId = TRACK1;
        uint256 pid = proposeAndAccept(t, agreementFees());
        assertEq(negotiation.getProposal(pid).licensor, licensor);

        t.trackId = keccak256("no-such-track");
        vm.prank(licensee);
        vm.expectRevert(LicenceNegotiation.LicensorUnknown.selector);
        negotiation.propose(t, agreementFees());
    }

    function test_acceptedProposalMintsExactlyOnce() public {
        uint256 pid = proposeAndAccept();
        vm.prank(licensee);
        uint256 id = licence.mintFromProposal(pid, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
        assertEq(negotiation.getProposal(pid).tokenId, id);
        assertEq(licence.tokenOfProposal(pid), id);
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.ProposalAlreadyMinted.selector, pid, id));
        licence.mintFromProposal(pid, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LicenceNegotiation.NotLicenceContract.selector, stranger));
        negotiation.markMinted(pid, 42);
    }

    function test_unacceptedProposalCannotMint() public {
        vm.prank(licensee);
        uint256 pid = negotiation.propose(agreementTerms(), agreementFees());
        vm.prank(licensee);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionLicence721.ProposalNotAccepted.selector, pid));
        licence.mintFromProposal(pid, uint8(BindingTrigger.WRITTEN_ACCEPTANCE));
    }
}
