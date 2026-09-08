// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice §7 — distributes each settled instalment per ApportionmentPolicy and SplitSet[SYNC].
interface IRoyaltySplitter {
    /// @dev cl. 3.2 — scoped to one income type; never reusable across pots.
    function distributeInstalment(uint256 licenceId, uint8 index, uint8 policy) external;
    function distributeTrack(bytes32 trackId, uint8 incomeType, address token, uint256 amountMinor) external payable;

    event Apportioned(uint256 indexed licenceId, uint8 index, uint8 policy, uint256 declarations, uint256 amountMinor);
    event Distributed(
        bytes32 indexed trackId, uint8 indexed incomeType, address payee, uint256 amountMinor, uint256 licenceId
    );
}
