// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @dev Domain constants and weekday math shared by the LastWeekdayOfMonthCadence suites (unit,
/// unchecked-equivalence, config, invariant), so the campaigns cannot silently drift onto different domains.

uint256 constant SECONDS_PER_DAY = 86400;

/// @dev Monday-indexed Friday, the historical Tenor maturity weekday used where a single config is exercised.
uint256 constant FRIDAY = 4;

/// @dev Time of day at which every suite deploys the cadence under test.
uint256 constant BOUNDARY_TIME_OF_DAY = 15 hours;

/// @dev 1970-01-30 15:00:00 UTC, the first Friday boundary; earlier inputs revert on arithmetic underflow.
uint256 constant DOMAIN_START = 29 * SECONDS_PER_DAY + BOUNDARY_TIME_OF_DAY;

/// @dev ~year 9000; the inline math has no artificial ceiling, so this is a chosen test horizon, not a limit.
uint256 constant DOMAIN_END = 221846400000;

/// @dev Exact per-weekday line count emitted by generate_last_weekday_boundaries.py:
/// (2125 - 2025 + 1) * 12 months.
uint256 constant FIXTURE_ENTRY_COUNT = 1212;

/// @dev First valid input for each Monday-indexed weekday at BOUNDARY_TIME_OF_DAY; earlier inputs revert on
/// arithmetic underflow. January 1970 ended on Saturday the 31st (epoch day 30), so the last Monday..Sunday
/// of that month fall on epoch days 25..30 and 24.
function domainStart(uint256 dayOfWeek) pure returns (uint256) {
    uint256[7] memory firstBoundaryDay = [uint256(25), 26, 27, 28, 29, 30, 24];
    return firstBoundaryDay[dayOfWeek] * SECONDS_PER_DAY + BOUNDARY_TIME_OF_DAY;
}

/// @dev True iff `timestamp` falls on the Monday-indexed `dayOfWeek` at exactly `timeOfDay`. Plain epoch-day
/// parity — epoch day 0 (1970-01-01) was a Thursday (Monday-indexed 3) — sharing no code with the contract's
/// month arithmetic.
function isWeekdayAt(uint256 timestamp, uint256 dayOfWeek, uint256 timeOfDay) pure returns (bool) {
    return timestamp % SECONDS_PER_DAY == timeOfDay && (timestamp / SECONDS_PER_DAY + 3) % 7 == dayOfWeek;
}
