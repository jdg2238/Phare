// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {LicenceTerms, FeeInstalment} from "../Types.sol";

/// @notice §7 — propose / counter / accept. The contract stores the outcome only; the
///         negotiation trail lives on HCS and is NOT part of the agreement (cl. 6.1).
interface ILicenceNegotiation {
    function propose(LicenceTerms calldata terms, FeeInstalment[] calldata fees) external returns (uint256 proposalId);
    function counter(uint256 proposalId, LicenceTerms calldata revised, FeeInstalment[] calldata fees) external;
    function accept(uint256 proposalId) external;
    function reject(uint256 proposalId) external;
    function withdraw(uint256 proposalId) external;

    event Proposed(
        uint256 indexed proposalId,
        address indexed licensee,
        bytes32 indexed catalogueOrTrack,
        bytes32 termsHash,
        bytes32 hcsTopicId
    );
    event Countered(uint256 indexed proposalId, address indexed by, bytes32 termsHash);
    event Accepted(uint256 indexed proposalId, bytes32 termsHash);
}
