// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BaseTest} from "./BaseTest.sol";
import {RightsRegistry} from "../src/RightsRegistry.sol";
import "../src/Types.sol";

/// @notice §11 step 1 — I4 and the cl. 5.1 / cl. 2.3 registry behaviour.
contract RightsRegistryTest is BaseTest {
    uint8 constant SYNC = uint8(IncomeType.SYNC);

    // I4 — Σ bps == 10_000 for every (trackId, incomeType), always
    function test_I4_rejectsSplitSumNot10000() public {
        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(RightsRegistry.InvalidSplitSum.selector, 9000));
        registry.setSplitSet(TRACK1, SYNC, _split3(5000, 3000, 1000), licensor);
    }

    function testFuzz_I4_anySumOtherThan10000Reverts(uint16 a, uint16 b, uint16 c) public {
        vm.assume(a > 0 && b > 0 && c > 0);
        vm.assume(uint256(a) + b + c != 10_000);
        vm.prank(licensor);
        vm.expectRevert(abi.encodeWithSelector(RightsRegistry.InvalidSplitSum.selector, uint256(a) + b + c));
        registry.setSplitSet(TRACK1, SYNC, _split3(a, b, c), licensor);
    }

    function testFuzz_I4_storedSetAlwaysSumsTo10000(uint16 a, uint16 b) public {
        a = uint16(bound(a, 1, 9998));
        b = uint16(bound(b, 1, 9999 - a));
        uint16 c = 10_000 - a - b;
        vm.prank(licensor);
        registry.setSplitSet(TRACK2, SYNC, _split3(a, b, c), licensor);
        SplitSet memory ss = registry.splitSet(TRACK2, SYNC);
        uint256 sum;
        for (uint256 i = 0; i < ss.entries.length; i++) {
            sum += ss.entries[i].bps;
        }
        assertEq(sum, 10_000);
    }

    // cl. 5.1 — fully registered == exists + ownership confirmed + SYNC splits locked
    function test_isFullyRegistered_gates() public {
        assertTrue(registry.isFullyRegistered(TRACK1));
        assertFalse(registry.isFullyRegistered(TRACK_UNCONFIRMED));
        assertFalse(registry.isFullyRegistered(keccak256("unknown")));

        vm.prank(composerA);
        registry.confirmSplit(TRACK_UNCONFIRMED, SYNC);
        assertFalse(registry.isFullyRegistered(TRACK_UNCONFIRMED)); // composerB still outstanding
        vm.prank(composerB);
        registry.confirmSplit(TRACK_UNCONFIRMED, SYNC);
        assertTrue(registry.isFullyRegistered(TRACK_UNCONFIRMED));
    }

    function test_ownershipMustBeConfirmedByOwner() public {
        bytes32 t = keccak256("composer-owned");
        vm.prank(admin);
        registry.registerTrack(t, composerA, Rights.MASTER | Rights.COMPOSITION, 0, 0, keccak256("t"));
        SplitEntry[] memory s = new SplitEntry[](1);
        s[0] = SplitEntry({payee: composerA, bps: 10_000, partyId: 0, confirmed: false});
        vm.prank(composerA);
        registry.setSplitSet(t, SYNC, s, composerA);
        assertTrue(registry.allSplitsConfirmed(t, SYNC)); // proposer auto-confirms own line
        assertFalse(registry.isFullyRegistered(t)); // ownership not yet confirmed

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RightsRegistry.NotTrackOwner.selector, t, stranger));
        registry.confirmOwnership(t);

        vm.prank(composerA);
        registry.confirmOwnership(t);
        assertTrue(registry.isFullyRegistered(t));
    }

    function test_replacingSplitSetResetsConfirmations() public {
        vm.prank(licensor);
        registry.setSplitSet(TRACK1, SYNC, _split3(6000, 2000, 2000), licensor);
        assertFalse(registry.allSplitsConfirmed(TRACK1, SYNC));
        assertFalse(registry.isFullyRegistered(TRACK1));
        vm.prank(composerA);
        registry.confirmSplit(TRACK1, SYNC);
        vm.prank(composerB);
        registry.confirmSplit(TRACK1, SYNC);
        assertTrue(registry.isFullyRegistered(TRACK1));
    }

    function test_splitSet_rejectsInvalidEntries() public {
        vm.startPrank(licensor);
        vm.expectRevert(abi.encodeWithSelector(RightsRegistry.InvalidIncomeType.selector, 5));
        registry.setSplitSet(TRACK1, 5, _split3(5000, 3000, 2000), licensor);

        SplitEntry[] memory dup = _split3(5000, 3000, 2000);
        dup[2].payee = composerA;
        vm.expectRevert(abi.encodeWithSelector(RightsRegistry.DuplicatePayee.selector, composerA));
        registry.setSplitSet(TRACK1, SYNC, dup, licensor);

        vm.expectRevert(RightsRegistry.ZeroAddress.selector);
        registry.setSplitSet(TRACK1, SYNC, _split3(5000, 3000, 2000), address(0));
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RightsRegistry.NotAPayee.selector, TRACK1, SYNC, stranger));
        registry.confirmSplit(TRACK1, SYNC);
    }

    // cl. 2.3 — derivatives
    function test_registerDerivative_onlyLedgerRole() public {
        bytes32 role_ = registry.LEDGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role_)
        );
        registry.registerDerivative(TRACK1, keccak256("edit"), licensor, keccak256("content"));
    }

    // I8 — EditedMaterial.owner == licence.licensor; no setter
    function test_I8_derivativeOwnerIsAssigneeAndHasNoSetter() public {
        bytes32 editId = keccak256("edit-1");
        vm.prank(address(ledger));
        bytes32 derived = registry.registerDerivative(TRACK1, editId, licensor, keccak256("content"));
        assertEq(registry.ownerOfTrack(derived), licensor);
        RightsRegistry.Track memory t = registry.trackInfo(derived);
        assertEq(t.parentTrackId, TRACK1);
        assertEq(t.editId, editId);
        assertTrue(t.ownershipConfirmed);
        assertEq(t.titleHash, TITLE1);

        // no ownership setter exists on the registry at all
        string[4] memory sigs = [
            "setTrackOwner(bytes32,address)",
            "transferTrack(bytes32,address)",
            "setOwner(bytes32,address)",
            "assignDerivative(bytes32,address)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            vm.prank(licensor);
            (bool ok,) = address(registry).call(abi.encodeWithSignature(sigs[i], derived, stranger));
            assertFalse(ok, sigs[i]);
        }
        assertEq(registry.ownerOfTrack(derived), licensor);
    }

    function test_catalogueMembership() public {
        assertTrue(registry.isInCatalogue(CATALOGUE, TRACK1));
        assertFalse(registry.isInCatalogue(CATALOGUE, TRACK_OUTSIDE));
        assertEq(registry.catalogueTracks(CATALOGUE).length, 4);
        vm.prank(licensor);
        registry.removeFromCatalogue(CATALOGUE, TRACK_UNCONFIRMED);
        assertEq(registry.catalogueTracks(CATALOGUE).length, 3);
        assertFalse(registry.isInCatalogue(CATALOGUE, TRACK_UNCONFIRMED));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RightsRegistry.NotCatalogueOwner.selector, CATALOGUE, stranger));
        registry.addToCatalogue(CATALOGUE, TRACK_OUTSIDE);
    }

    function test_upgradeRestrictedToUpgrader() public {
        RightsRegistry impl = new RightsRegistry();
        bytes32 role_ = registry.UPGRADER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role_)
        );
        registry.upgradeToAndCall(address(impl), "");
        vm.prank(admin);
        registry.upgradeToAndCall(address(impl), "");
        assertTrue(registry.isFullyRegistered(TRACK1)); // state survives
    }
}
