// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {SplitSet} from "../Types.sol";

/// @notice §7 — RightsRegistry interface. Catalogues, tracks, ownership, split sets, derivatives.
interface IRightsRegistry {
    function isInCatalogue(bytes32 catalogueId, bytes32 trackId) external view returns (bool);

    /// @dev cl. 5.1 — the warranty, made checkable per track.
    function isFullyRegistered(bytes32 trackId) external view returns (bool);

    function allSplitsConfirmed(bytes32 trackId, uint8 incomeType) external view returns (bool);

    function splitSet(bytes32 trackId, uint8 incomeType) external view returns (SplitSet memory);

    function ownerOfTrack(bytes32 trackId) external view returns (address);

    /// @dev cl. 3.1(iii) — keccak256 of the normalised track title, for the declaration-time check.
    function titleHash(bytes32 trackId) external view returns (bytes32);

    /// @dev cl. 2.3 — Edited Material vests in the Licensor.
    function registerDerivative(bytes32 parentTrackId, bytes32 editId, address assignee, bytes32 contentHash)
        external
        returns (bytes32 derivativeTrackId);
}
