// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LastWeekdayOfMonthCadence} from "../../src/ratifiers/policies/LastWeekdayOfMonthCadence.sol";
import {SECONDS_PER_DAY, isWeekdayAt} from "../helpers/CadenceTestConstants.sol";

/// @dev Exercises the configurable weekday and boundary time of day. The last-weekday logic is unchanged and
/// covered against the hardcoded fixture in LastWeekdayOfMonthCadence.t.sol (Friday at 15:00); this only checks
/// that an arbitrary configuration is honoured and that the constructor rejects out-of-range values.
contract LastWeekdayOfMonthCadenceConfigTest is Test {
    uint256 constant MONDAY = 0;
    uint256 constant FRIDAY = 4;

    function test_constructorRejectsInvalidDay() public {
        vm.expectRevert(LastWeekdayOfMonthCadence.InvalidBoundaryDay.selector);
        new LastWeekdayOfMonthCadence(7, 15 hours);
    }

    function test_constructorRejectsFullDay() public {
        vm.expectRevert(LastWeekdayOfMonthCadence.InvalidBoundaryTime.selector);
        new LastWeekdayOfMonthCadence(FRIDAY, 1 days);
    }

    function test_honoursArbitraryHour() public {
        // 20:00 UTC (e.g. US options close) instead of 15:00.
        LastWeekdayOfMonthCadence cadence = new LastWeekdayOfMonthCadence(FRIDAY, 20 hours);
        // 2026-01-30 20:00:00 UTC, last Friday of January 2026 at the configured time.
        uint256 boundary = 1769731200 + 20 hours;
        assertEq(cadence.cadencePeriodStart(boundary), boundary);
        assertEq(cadence.cadencePeriodStart(boundary + 1), boundary);
        assertEq(cadence.cadencePeriodStart(boundary + 1 days), boundary);
        assertEq(cadence.cadencePeriodStart(boundary + 40 days) % SECONDS_PER_DAY, 20 hours);
    }

    function test_honoursArbitraryDay() public {
        LastWeekdayOfMonthCadence cadence = new LastWeekdayOfMonthCadence(MONDAY, 9 hours);
        // 2026-01-26 09:00:00 UTC, last Monday of January 2026 (Jan 31 is a Saturday) at the configured time.
        uint256 boundary = 1769385600 + 9 hours;
        assertEq(cadence.cadencePeriodStart(boundary), boundary);
        assertEq(cadence.cadencePeriodStart(boundary + 1), boundary);
        assertEq(cadence.cadencePeriodStart(boundary + 1 days), boundary);
        assertTrue(isWeekdayAt(cadence.cadencePeriodStart(boundary + 40 days), MONDAY, 9 hours));
    }

    /// @dev For any configured weekday and time of day, every boundary is that weekday at exactly that time, at
    /// or before the input, and a fixed point - the invariants BaseMigrationRatifier relies on, for any config.
    function testFuzz_invariantsHoldForAnyConfig(uint256 dayOfWeek, uint256 hour, uint256 t) public {
        dayOfWeek = bound(dayOfWeek, 0, 6);
        hour = bound(hour, 0, 1 days - 1);
        LastWeekdayOfMonthCadence cadence = new LastWeekdayOfMonthCadence(dayOfWeek, hour);
        // 1970-02-27 (day 57) is a safe floor for any configuration.
        t = bound(t, 57 * SECONDS_PER_DAY + hour, 4954057200);
        uint256 boundary = cadence.cadencePeriodStart(t);
        assertTrue(isWeekdayAt(boundary, dayOfWeek, hour)); // configured weekday at the configured time
        assertLe(boundary, t); // never in the future
        assertEq(cadence.cadencePeriodStart(boundary), boundary); // fixed point
    }
}
