// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice Minimal proleptic-Gregorian date arithmetic (UTC) for PaymentRule.END_OF_MONTH_FOLLOWING (cl. 2.1).
/// @dev Civil-from-days / days-from-civil per Howard Hinnant's algorithms.
library DateTime {
    uint256 private constant SECONDS_PER_DAY = 86400;

    /// @return y year, m month (1..12), d day (1..31)
    function civilFromTimestamp(uint256 ts) internal pure returns (uint256 y, uint256 m, uint256 d) {
        int256 z = int256(ts / SECONDS_PER_DAY) + 719468;
        int256 era = (z >= 0 ? z : z - 146096) / 146097;
        uint256 doe = uint256(z - era * 146097);
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        int256 yy = int256(yoe) + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        y = uint256(m <= 2 ? yy + 1 : yy);
    }

    /// @return ts Unix timestamp of 00:00:00 UTC on the given civil date.
    function timestampFromCivil(uint256 y, uint256 m, uint256 d) internal pure returns (uint256 ts) {
        int256 yy = int256(y) - (m <= 2 ? int256(1) : int256(0));
        int256 era = (yy >= 0 ? yy : yy - 399) / 400;
        uint256 yoe = uint256(yy - era * 400);
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        int256 days_ = era * 146097 + int256(doe) - 719468;
        ts = uint256(days_) * SECONDS_PER_DAY;
    }

    /// @notice Last second of the calendar month after the month containing `ts`.
    ///         e.g. an invoice received 15 Jan 2025 → 28 Feb 2025 23:59:59 UTC.
    function endOfFollowingMonth(uint256 ts) internal pure returns (uint256) {
        (uint256 y, uint256 m,) = civilFromTimestamp(ts);
        // first day of the month two months ahead, minus one second
        m += 2;
        while (m > 12) {
            m -= 12;
            y += 1;
        }
        return timestampFromCivil(y, m, 1) - 1;
    }
}
