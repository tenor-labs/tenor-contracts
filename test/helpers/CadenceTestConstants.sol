// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @dev Domain constants and weekday math shared by the LastFridayOfMonthCadence suites (unit,
/// unchecked-equivalence, config, invariant), so the campaigns cannot silently drift onto different domains.

uint256 constant SECONDS_PER_DAY = 86400;

/// @dev Time of day at which every suite deploys the cadence under test.
uint256 constant BOUNDARY_TIME_OF_DAY = 15 hours;

/// @dev 1970-01-30 15:00:00 UTC, the first boundary; earlier inputs revert.
uint256 constant DOMAIN_START = 29 * SECONDS_PER_DAY + BOUNDARY_TIME_OF_DAY;

/// @dev ~year 9000; the inline math has no artificial ceiling, so this is a chosen test horizon, not a limit.
uint256 constant DOMAIN_END = 221846400000;

/// @dev Exact line count emitted by generate_last_friday_boundaries.py: (2125 - 2025 + 1) * 12 months.
uint256 constant FIXTURE_ENTRY_COUNT = 1212;

/// @dev True iff `timestamp` falls on a Friday at exactly `timeOfDay`. Plain epoch-day parity — epoch day 0
/// (1970-01-01) was a Thursday (Monday-indexed 3) — sharing no code with the contract's month arithmetic.
function isFridayAt(uint256 timestamp, uint256 timeOfDay) pure returns (bool) {
    return timestamp % SECONDS_PER_DAY == timeOfDay && (timestamp / SECONDS_PER_DAY + 3) % 7 == 4;
}

/// @dev Days and months in a 400-year Gregorian cycle, and the epoch day of 2000-01-01, which begins one
/// (2000 is divisible by 400). The calendar repeats exactly every cycle, so subtracting whole cycles reduces
/// any date, however far out, to a walk of at most 400 years from that day.
uint256 constant DAYS_PER_GREGORIAN_CYCLE = 146097;
uint256 constant MONTHS_PER_GREGORIAN_CYCLE = 4800;
uint256 constant Y2K_EPOCH_DAY = 10957;

function isLeapYear(uint256 year) pure returns (bool) {
    return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
}

function daysInMonth(uint256 year, uint256 month) pure returns (uint256) {
    if (month == 2) return isLeapYear(year) ? 29 : 28;
    return (month == 4 || month == 6 || month == 9 || month == 11) ? 30 : 31;
}

/// @dev Strictly increasing month number for `epochDay`: 0 for January 2000, +1 per calendar month, defined
/// for every day from 2000-01-01 on (the whole range the cadence suites exercise, which starts in 2025).
/// Computed by subtracting whole 400-year cycles, then whole years, then whole months, so it shares no code
/// and no algorithm with the contract's closed-form Hinnant civil-date math. Only the leap-year rule is
/// common, and that is the calendar's definition rather than an implementation of it.
function monthOrdinal(uint256 epochDay) pure returns (uint256) {
    uint256 remainingDays = epochDay - Y2K_EPOCH_DAY;
    uint256 ordinal = (remainingDays / DAYS_PER_GREGORIAN_CYCLE) * MONTHS_PER_GREGORIAN_CYCLE;
    remainingDays %= DAYS_PER_GREGORIAN_CYCLE;

    uint256 year = 2000;
    uint256 yearLength = isLeapYear(year) ? 366 : 365;
    while (remainingDays >= yearLength) {
        remainingDays -= yearLength;
        ordinal += 12;
        yearLength = isLeapYear(++year) ? 366 : 365;
    }

    uint256 month = 1;
    uint256 monthLength = daysInMonth(year, month);
    while (remainingDays >= monthLength) {
        remainingDays -= monthLength;
        ordinal += 1;
        monthLength = daysInMonth(year, ++month);
    }
    return ordinal;
}

/// @dev True iff `timestamp` falls on the LAST Friday of its calendar month, i.e. the Friday seven days later
/// is already in the next month. This is the one property that separates the last Friday from the
/// second-to-last: a cadence returning the second-to-last still satisfies every other structural check (a
/// Friday, at or before the input, a fixed point, no gap over five weeks), because those hold for any monthly
/// series of Fridays.
function isLastFridayOfMonth(uint256 timestamp) pure returns (bool) {
    uint256 epochDay = timestamp / SECONDS_PER_DAY;
    return monthOrdinal(epochDay + 7) == monthOrdinal(epochDay) + 1;
}
