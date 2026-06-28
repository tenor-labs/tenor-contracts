// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {FourWeekCadence} from "../../src/ratifiers/policies/FourWeekCadence.sol";

contract FourWeekCadenceTest is Test {
    FourWeekCadence cadence;

    uint256 constant PERIOD = 28 days;

    function setUp() public {
        cadence = new FourWeekCadence();
    }

    function test_exactBoundary() public view {
        // Exact boundary should return itself
        assertEq(cadence.cadencePeriodStart(PERIOD), PERIOD);
        assertEq(cadence.cadencePeriodStart(PERIOD * 2), PERIOD * 2);
        assertEq(cadence.cadencePeriodStart(PERIOD * 100), PERIOD * 100);
    }

    function test_zero() public view {
        assertEq(cadence.cadencePeriodStart(0), 0);
    }

    function test_midPeriod() public view {
        // Midway through first period rounds down to 0
        assertEq(cadence.cadencePeriodStart(14 days), 0);
        // Midway through second period rounds down to first boundary
        assertEq(cadence.cadencePeriodStart(PERIOD + 14 days), PERIOD);
    }

    function test_oneSecondBeforeBoundary() public view {
        assertEq(cadence.cadencePeriodStart(PERIOD - 1), 0);
        assertEq(cadence.cadencePeriodStart(PERIOD * 2 - 1), PERIOD);
    }

    function test_oneSecondAfterBoundary() public view {
        assertEq(cadence.cadencePeriodStart(PERIOD + 1), PERIOD);
        assertEq(cadence.cadencePeriodStart(PERIOD * 2 + 1), PERIOD * 2);
    }

    function test_realisticTimestamp() public view {
        // ~April 2026: 1775000000
        uint256 ts = 1_775_000_000;
        uint256 boundary = cadence.cadencePeriodStart(ts);
        // Boundary must be <= timestamp and aligned to 28 days
        assertLe(boundary, ts);
        assertEq(boundary % PERIOD, 0);
        // Next boundary must be > timestamp
        assertGt(boundary + PERIOD, ts);
    }

    function testFuzz_alwaysAligned(uint256 timestamp) public view {
        timestamp = bound(timestamp, 0, type(uint256).max - PERIOD);
        uint256 boundary = cadence.cadencePeriodStart(timestamp);
        // Boundary is a multiple of PERIOD
        assertEq(boundary % PERIOD, 0);
        // Boundary <= timestamp
        assertLe(boundary, timestamp);
        // Next boundary > timestamp
        assertGt(boundary + PERIOD, timestamp);
    }

    function testFuzz_idempotent(uint256 timestamp) public view {
        // Applying cadencePeriodStart to a boundary returns itself
        uint256 boundary = cadence.cadencePeriodStart(timestamp);
        assertEq(cadence.cadencePeriodStart(boundary), boundary);
    }
}
