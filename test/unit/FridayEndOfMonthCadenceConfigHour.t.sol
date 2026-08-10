// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {FridayEndOfMonthCadence} from "../../src/ratifiers/policies/FridayEndOfMonthCadence.sol";

/// @dev Exercises the configurable boundary time of day. The last-Friday logic is unchanged and covered against
/// the hardcoded fixture in FridayEndOfMonthCadence.t.sol (at 15:00); this only checks that an arbitrary time of
/// day is honoured and that the constructor rejects out-of-range values.
contract FridayEndOfMonthCadenceConfigHourTest is Test {
    uint256 constant SECONDS_PER_DAY = 86400;

    function test_constructorRejectsFullDay() public {
        vm.expectRevert(FridayEndOfMonthCadence.InvalidBoundaryTime.selector);
        new FridayEndOfMonthCadence(1 days);
    }

    function test_honoursArbitraryHour() public {
        // 20:00 UTC (e.g. US options close) instead of 15:00.
        FridayEndOfMonthCadence cadence = new FridayEndOfMonthCadence(20 hours);
        // 2026-01-30 20:00:00 UTC, last Friday of January 2026 at the configured time.
        uint256 boundary = 1769731200 + 20 hours;
        assertEq(cadence.cadencePeriodStart(boundary), boundary);
        assertEq(cadence.cadencePeriodStart(boundary + 1), boundary);
        assertEq(cadence.cadencePeriodStart(boundary + 1 days), boundary);
        assertEq(cadence.cadencePeriodStart(boundary + 40 days) % SECONDS_PER_DAY, 20 hours);
    }

    /// @dev For any configured time of day, every boundary is a Friday at exactly that time, at or before the
    /// input, and a fixed point - the invariants BaseMigrationRatifier relies on, for any hour.
    function testFuzz_invariantsHoldForAnyHour(uint256 hour, uint256 t) public {
        hour = bound(hour, 0, 1 days - 1);
        FridayEndOfMonthCadence cadence = new FridayEndOfMonthCadence(hour);
        // 1970-02-27 (day 57) is a safe floor for any hour.
        t = bound(t, 57 * SECONDS_PER_DAY + hour, 4954057200);
        uint256 boundary = cadence.cadencePeriodStart(t);
        assertEq(boundary % SECONDS_PER_DAY, hour); // configured time of day
        assertEq((boundary / SECONDS_PER_DAY + 3) % 7, 4); // Monday-indexed Friday
        assertLe(boundary, t); // never in the future
        assertEq(cadence.cadencePeriodStart(boundary), boundary); // fixed point
    }
}
