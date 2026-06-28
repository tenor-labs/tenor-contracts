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
        assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), 0, 0, false), 100);

        // At interior knot (elapsed=1000)
        vm.warp(2000);
        assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), 0, 0, false), 200);

        // Mid-segment [1]->[2]: elapsed=2000 → 200 + (500-200) * (2000-1000) / (3000-1000) = 350
        vm.warp(3000);
        assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), 0, 0, false), 350);

        // At last knot (elapsed=3000)
        vm.warp(4000);
        assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), 0, 0, false), 500);
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
        assertEq(policy.getRate(bytes32(0), bytes32(0), 1000, address(0), 0, 0, false), 100);
    }
}
