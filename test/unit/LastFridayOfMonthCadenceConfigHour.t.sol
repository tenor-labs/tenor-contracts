// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LastFridayOfMonthCadence} from "../../src/ratifiers/policies/LastFridayOfMonthCadence.sol";
import {SECONDS_PER_DAY, isFridayAt} from "../helpers/CadenceTestConstants.sol";

/// @dev Exercises the configurable boundary time of day. The last-Friday logic is unchanged and covered against
/// the hardcoded fixture in LastFridayOfMonthCadence.t.sol (at 15:00); this only checks that an arbitrary time of
/// day is honoured and that the constructor rejects out-of-range values.
contract LastFridayOfMonthCadenceConfigHourTest is Test {
    function test_constructorRejectsFullDay() public {
        vm.expectRevert(LastFridayOfMonthCadence.InvalidBoundaryTime.selector);
        new LastFridayOfMonthCadence(1 days);
    }

    function test_honoursArbitraryHour() public {
        // 08:00 UTC (the Deribit monthly expiry time) instead of 15:00.
        LastFridayOfMonthCadence cadence = new LastFridayOfMonthCadence(8 hours);
        // 2026-01-30 08:00:00 UTC, last Friday of January 2026 at the configured time.
        uint256 boundary = 1769731200 + 8 hours;
        assertEq(cadence.cadencePeriodStart(boundary), boundary);
        assertEq(cadence.cadencePeriodStart(boundary + 1), boundary);
        assertEq(cadence.cadencePeriodStart(boundary + 1 days), boundary);
        assertTrue(isFridayAt(cadence.cadencePeriodStart(boundary + 40 days), 8 hours));
    }

    /// @dev For any configured time of day, every boundary is a Friday at exactly that time, at or before the
    /// input, and a fixed point - the invariants BaseMigrationRatifier relies on, for any hour.
    function testFuzz_invariantsHoldForAnyHour(uint256 hour, uint256 t) public {
        hour = bound(hour, 0, 1 days - 1);
        LastFridayOfMonthCadence cadence = new LastFridayOfMonthCadence(hour);
        t = bound(t, cadence.FIRST_BOUNDARY(), 4954057200);
        uint256 boundary = cadence.cadencePeriodStart(t);
        assertTrue(isFridayAt(boundary, hour)); // a Friday at the configured time
        assertLe(boundary, t); // never in the future
        assertEq(cadence.cadencePeriodStart(boundary), boundary); // fixed point
    }
}
