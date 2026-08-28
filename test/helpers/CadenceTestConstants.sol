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

/// @dev Days and years in a 400-year Gregorian cycle, and the offset from the epoch back to 1600-01-01, which
/// begins one (1600 is divisible by 400). The calendar repeats exactly every cycle, so subtracting whole cycles
/// reduces any date, however far out, to a walk of at most 400 years from that day. The anchor sits before the
/// epoch rather than at 2000-01-01 so that the whole of the cadence's domain, which starts at DOMAIN_START
/// (1970-01-30), is covered; anchoring at 2000 left the first thirty years of that domain undefined.
uint256 constant DAYS_PER_GREGORIAN_CYCLE = 146097;
uint256 constant YEARS_PER_GREGORIAN_CYCLE = 400;
uint256 constant CYCLE_ANCHOR_YEAR = 1600;
uint256 constant EPOCH_DAYS_AFTER_CYCLE_ANCHOR = 135140;

function isLeapYear(uint256 year) pure returns (bool) {
    return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
}

function daysInMonth(uint256 year, uint256 month) pure returns (uint256) {
    if (month == 2) return isLeapYear(year) ? 29 : 28;
    return (month == 4 || month == 6 || month == 9 || month == 11) ? 30 : 31;
}

/// @dev Civil year/month/day for `epochDay`, defined for every epoch day and so for the cadence's entire domain
/// rather than only the part the fixture covers. Computed by subtracting whole 400-year cycles, then whole years,
/// then whole months, one at a time, so it shares no code and no algorithm with the contract's closed-form
/// Hinnant civil-date math. Only the leap-year rule is common, and that is the calendar's definition rather than
/// an implementation of it. Leap years stay correct past the first cycle because the rule is periodic in 400, so
/// the reported year stays congruent to its within-cycle counterpart.
function civilFromDaysByWalking(uint256 epochDay) pure returns (uint256 year, uint256 month, uint256 dayOfMonth) {
    uint256 remainingDays = epochDay + EPOCH_DAYS_AFTER_CYCLE_ANCHOR;
    year = CYCLE_ANCHOR_YEAR + (remainingDays / DAYS_PER_GREGORIAN_CYCLE) * YEARS_PER_GREGORIAN_CYCLE;
    remainingDays %= DAYS_PER_GREGORIAN_CYCLE;

    uint256 yearLength = isLeapYear(year) ? 366 : 365;
    while (remainingDays >= yearLength) {
        remainingDays -= yearLength;
        yearLength = isLeapYear(++year) ? 366 : 365;
    }

    month = 1;
    uint256 monthLength = daysInMonth(year, month);
    while (remainingDays >= monthLength) {
        remainingDays -= monthLength;
        monthLength = daysInMonth(year, ++month);
    }
    dayOfMonth = remainingDays + 1;
}

/// @dev True iff `timestamp` falls on the LAST Friday of its calendar month, i.e. the Friday seven days later is
/// already in the next month. This is the one property that separates the last Friday from the second-to-last: a
/// cadence returning the second-to-last still satisfies every other structural check (a Friday, at or before the
/// input, a fixed point, no gap over five weeks), because those hold for any monthly series of Fridays.
function isLastFridayOfMonth(uint256 timestamp) pure returns (bool) {
    (uint256 year, uint256 month, uint256 dayOfMonth) = civilFromDaysByWalking(timestamp / SECONDS_PER_DAY);
    return dayOfMonth + 7 > daysInMonth(year, month);
}
