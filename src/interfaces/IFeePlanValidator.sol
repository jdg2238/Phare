// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FeeInstalment} from "../Types.sol";

/// @notice Lets LicenceNegotiation reject a fee plan at propose-time using FeeSchedule's rules
///         (I20 / OPEN-Q10), instead of failing later at mint.
interface IFeePlanValidator {
    function validatePlan(FeeInstalment[] calldata plan) external view;
}
