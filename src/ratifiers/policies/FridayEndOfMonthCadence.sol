// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {DateTimeLib} from "solady/utils/DateTimeLib.sol";

import {IRenewalCadence} from "../interfaces/IRenewalCadence.sol";

/// @title FridayEndOfMonthCadence
/// @notice Cadence with boundaries at 15:00:00 UTC on the last Friday of each month.
/// @dev Derives the civil date with Solady's DateTimeLib, then rolls the last day of the month back to a Friday.
/// @dev Reverts (arithmetic underflow) on timestamps before 1970-01-30 15:00:00 UTC, the earliest boundary it can
/// return; never returns a boundary in the future of the input.
contract FridayEndOfMonthCadence is IRenewalCadence {
    /// @dev 15:00:00 UTC, the maturity time used across Tenor markets.
    uint256 private constant BOUNDARY_TIME_OF_DAY = 15 hours;

    /// @inheritdoc IRenewalCadence
    function cadencePeriodStart(uint256 timestamp) external pure returns (uint256) {
        // Shift by the boundary time so `day` is the last civil day whose 15:00:00 UTC has passed.
        uint256 day = (timestamp - BOUNDARY_TIME_OF_DAY) / 1 days;

        (uint256 year, uint256 month, uint256 dayOfMonth) = DateTimeLib.epochDayToDate(day);

        // Adding the month length before subtracting keeps late-January 1970 inputs from underflowing.
        uint256 lastDayOfMonth = day + DateTimeLib.daysInMonth(year, month) - dayOfMonth;
        uint256 boundary = _fridayOnOrBefore(lastDayOfMonth);
        if (boundary > day) {
            // This month's last Friday is still in the future: use the previous month's, whose last day is
            // `dayOfMonth` days before `day`.
            boundary = _fridayOnOrBefore(day - dayOfMonth);
        }
        return boundary * 1 days + BOUNDARY_TIME_OF_DAY;
    }

    /// @dev Rolls `epochDay` (days since epoch) back to the Friday on or before it.
    function _fridayOnOrBefore(uint256 epochDay) private pure returns (uint256) {
        // Epoch day 1 (1970-01-02) was a Friday, so (epochDay + 6) % 7 is days since the last Friday.
        return epochDay - ((epochDay + 6) % 7);
    }
}
