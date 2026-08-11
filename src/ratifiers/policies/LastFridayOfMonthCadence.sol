// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IRenewalCadence} from "../interfaces/IRenewalCadence.sol";

/// @title LastFridayOfMonthCadence
/// @notice Cadence with boundaries at a fixed time of day on the last Friday of each month.
/// @dev Periods span 28 or 35 days depending on the month.
contract LastFridayOfMonthCadence is IRenewalCadence {
    error InvalidBoundaryTime();
    error TimestampBeforeFirstBoundary();

    /// @dev Time of day at which boundaries fall in seconds past 00:00:00 UTC.
    uint256 public immutable BOUNDARY_TIME_OF_DAY;

    /// @dev First returnable boundary (1970-01-30, the last Friday of January 1970, at
    /// BOUNDARY_TIME_OF_DAY); earlier inputs revert.
    uint256 public immutable FIRST_BOUNDARY;

    constructor(uint256 boundaryTimeOfDay) {
        if (boundaryTimeOfDay >= 1 days) revert InvalidBoundaryTime();
        BOUNDARY_TIME_OF_DAY = boundaryTimeOfDay;
        FIRST_BOUNDARY = 29 days + boundaryTimeOfDay;
    }

    /// @inheritdoc IRenewalCadence
    function cadencePeriodStart(uint256 timestamp) external view returns (uint256) {
        if (timestamp < FIRST_BOUNDARY) revert TimestampBeforeFirstBoundary();
        // The guard puts every subtraction below in-domain; the fully-checked twin's differential fuzz proves
        // value and revert parity over the entire uint256 input space.
        unchecked {
            uint256 day = (timestamp - BOUNDARY_TIME_OF_DAY) / 1 days;

            (uint256 year, uint256 month, uint256 dayOfMonth) = _civilFromDays(day);

            // `daysInMonth >= dayOfMonth` always, so adding the month length before subtracting cannot
            // underflow
            uint256 lastDayOfMonth = day + _daysInMonth(year, month) - dayOfMonth;
            uint256 boundary = _fridayOnOrBefore(lastDayOfMonth);
            if (boundary > day) {
                // This month's last Friday is still in the future: use the previous month's, whose last day is
                // `dayOfMonth` days before `day` and, `day` being past January 1970's last Friday, no earlier
                // than epoch day 30.
                boundary = _fridayOnOrBefore(day - dayOfMonth);
            }
            return boundary * 1 days + BOUNDARY_TIME_OF_DAY;
        }
    }

    /// @dev Rolls `epochDay` (days since epoch) back to the Friday on or before it.
    function _fridayOnOrBefore(uint256 epochDay) private pure returns (uint256) {
        // Epoch day 1 (1970-01-02) was a Friday, so (epochDay + 6) % 7 is days since the last Friday.
        unchecked {
            return epochDay - ((epochDay + 6) % 7);
        }
    }

    /// @dev Returns year/month/day triple in civil calendar. Port of Hinnant's civil_from_days, standardized
    /// in C++20 std::chrono.
    /// @param epochDay number of days since 1970-01-01
    function _civilFromDays(uint256 epochDay) private pure returns (uint256 year, uint256 month, uint256 dayOfMonth) {
        unchecked {
            uint256 z = epochDay + 719468;
            uint256 era = z / 146097;
            uint256 dayOfEra = z - era * 146097;
            uint256 yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365;
            year = yearOfEra + era * 400;
            uint256 dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
            uint256 monthPrime = (5 * dayOfYear + 2) / 153;
            dayOfMonth = dayOfYear - (153 * monthPrime + 2) / 5 + 1;
            month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9;
            if (month <= 2) year += 1;
        }
    }

    /// @dev Number of days in the given civil month.
    function _daysInMonth(uint256 year, uint256 month) private pure returns (uint256) {
        if (month == 2) {
            bool leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
            return leap ? 29 : 28;
        }
        return (month == 4 || month == 6 || month == 9 || month == 11) ? 30 : 31;
    }
}
