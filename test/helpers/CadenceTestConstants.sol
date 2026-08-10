// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @dev Domain constants and weekday math shared by the FridayEndOfMonthCadence suites (unit,
/// unchecked-equivalence, invariant), so the campaigns cannot silently drift onto different domains.

uint256 constant SECONDS_PER_DAY = 86400;

/// @dev Time of day at which every suite deploys the cadence under test.
uint256 constant BOUNDARY_TIME_OF_DAY = 15 hours;

/// @dev 1970-01-30 15:00:00 UTC, the first boundary; earlier inputs revert on arithmetic underflow.
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
