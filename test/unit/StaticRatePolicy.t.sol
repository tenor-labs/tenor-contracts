// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {StaticRatePolicy} from "../../src/ratifiers/policies/StaticRatePolicy.sol";

/// @dev Interpolation correctness lives in `LinearInterpolationLib.t.sol`; this suite covers the
///      contract-specific glue (`_loadCurve` materialization, the `block.timestamp` → elapsed math).
contract StaticRatePolicyTest is Test {
    /// @dev End-to-end smoke: a 3-point curve queried at first knot, exact mid knot, mid-segment,
    ///      and last knot. Proves `_loadCurve` materializes immutables correctly and feeds them to
    ///      the lib in the right order.
    function test_getRate_endToEndSmoke() public {
        uint128[] memory rates = new uint128[](3);
        uint128[] memory durations = new uint128[](3);
        rates[0] = 100;
        rates[1] = 200;
        rates[2] = 500;
        durations[0] = 0;
        durations[1] = 1000;
        durations[2] = 3000;
        StaticRatePolicy policy = new StaticRatePolicy(rates, durations);

        // At first knot (elapsed=0)
        vm.warp(1000);
        assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), address(0), 0, 0, false), 100);

        // At interior knot (elapsed=1000)
        vm.warp(2000);
        assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), address(0), 0, 0, false), 200);

        // Mid-segment [1]->[2]: elapsed=2000 → 200 + (500-200) * (2000-1000) / (3000-1000) = 350
        vm.warp(3000);
        assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), address(0), 0, 0, false), 350);

        // At last knot (elapsed=3000)
        vm.warp(4000);
        assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), address(0), 0, 0, false), 500);
    }

    function test_numPoints() public {
        uint128[] memory rates = new uint128[](2);
        uint128[] memory durations = new uint128[](2);
        rates[0] = 100;
        rates[1] = 200;
        durations[0] = 0;
        durations[1] = 1000;
        assertEq(new StaticRatePolicy(rates, durations).numPoints(), 2);

        rates = new uint128[](8);
        durations = new uint128[](8);
        for (uint128 i = 0; i < 8; i++) {
            rates[i] = 100 * (i + 1);
            durations[i] = 1000 * i;
        }
        assertEq(new StaticRatePolicy(rates, durations).numPoints(), 8);
    }

    function test_getRate_fivePointCurve() public {
        uint128[] memory rates = new uint128[](5);
        uint128[] memory durations = new uint128[](5);
        rates[0] = 50;
        rates[1] = 150;
        rates[2] = 100;
        rates[3] = 300;
        rates[4] = 700;
        durations[0] = 500;
        durations[1] = 1000;
        durations[2] = 2000;
        durations[3] = 4000;
        durations[4] = 8000;
        StaticRatePolicy policy = new StaticRatePolicy(rates, durations);

        assertEq(policy.numPoints(), 5);

        // At each knot
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(1000 + durations[i]);
            assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), address(0), 0, 0, false), rates[i]);
        }

        // Mid-segment [0]->[1]: elapsed=750 → 50 + (150-50) * (750-500) / (1000-500) = 100
        vm.warp(1750);
        assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), address(0), 0, 0, false), 100);
    }

    function test_getRate_eightPointCurve() public {
        uint128[] memory rates = new uint128[](8);
        uint128[] memory durations = new uint128[](8);
        rates[0] = 100;
        rates[1] = 200;
        rates[2] = 180;
        rates[3] = 400;
        rates[4] = 400;
        rates[5] = 900;
        rates[6] = 300;
        rates[7] = 1000;
        durations[0] = 0;
        durations[1] = 100;
        durations[2] = 300;
        durations[3] = 600;
        durations[4] = 1000;
        durations[5] = 1500;
        durations[6] = 2100;
        durations[7] = 2800;
        StaticRatePolicy policy = new StaticRatePolicy(rates, durations);

        assertEq(policy.numPoints(), 8);

        // At each knot
        for (uint256 i = 0; i < 8; i++) {
            vm.warp(1000 + durations[i]);
            assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), address(0), 0, 0, false), rates[i]);
        }

        // Mid-segment [6]->[7]: elapsed=2500 → 300 + (1000-300) * (2500-2100) / (2800-2100) = 700
        vm.warp(3500);
        assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), address(0), 0, 0, false), 700);
    }

    /// @dev `block.timestamp < renewalPeriodStart` is contract-specific glue (the
    ///      `block.timestamp > renewalPeriodStart ? ... : 0` ternary). Elapsed clamps to 0,
    ///      yielding the first point's rate.
    function test_elapsedBeforeStart() public {
        uint128[] memory rates = new uint128[](2);
        uint128[] memory durations = new uint128[](2);
        rates[0] = 100;
        rates[1] = 200;
        durations[0] = 0;
        durations[1] = 1000;
        StaticRatePolicy policy = new StaticRatePolicy(rates, durations);

        vm.warp(500);
        assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), address(0), 0, 0, false), 100);
    }
}
