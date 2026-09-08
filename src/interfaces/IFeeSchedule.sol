// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FeeInstalment} from "../Types.sol";

/// @notice §7 — instalments; invoice → due → paid; fiat attestation or on-chain settlement; overdue → hold.
interface IFeeSchedule {
    function createInstalments(uint256 licenceId, FeeInstalment[] calldata plan) external; // at mint
    function markInvoiced(uint256 licenceId, uint8 index, bytes32 invoiceHash) external; // licensor
    function settleOnChain(uint256 licenceId, uint8 index, address token, uint256 amount) external payable;
    function attestFiatSettlement(uint256 licenceId, uint8 index, bytes32 bankRef) external; // SETTLEMENT_ATTESTOR
    function markOverdue(uint256 licenceId, uint8 index) external; // anyone, after dueAt

    function instalment(uint256 licenceId, uint8 index) external view returns (FeeInstalment memory);
    function allPaid(uint256 licenceId) external view returns (bool);
    function anyOverdue(uint256 licenceId) external view returns (bool);

    event Invoiced(uint256 indexed licenceId, uint8 index, bytes32 invoiceHash, uint64 dueAt);
    event Settled(uint256 indexed licenceId, uint8 index, uint256 amountMinor, bool onChain, bytes32 ref);
    event Overdue(uint256 indexed licenceId, uint8 index, uint64 at);
}
