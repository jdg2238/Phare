// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Territory} from "../Types.sol";

/// @notice §4.2 — membership test for an ISO 3166-1 alpha-2 code against a Territory.
library TerritoryLib {
    function contains(Territory memory t, bytes2 iso) internal pure returns (bool) {
        if (t.worldwide) {
            return !_has(t.excluded, iso);
        }
        return _has(t.included, iso);
    }

    function _has(bytes2[] memory list, bytes2 iso) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == iso) return true;
        }
        return false;
    }
}
