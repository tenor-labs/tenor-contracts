// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LinearInterpolationLib} from "../../src/libraries/LinearInterpolationLib.sol";

contract LinearInterpolationLibTest is Test {
    /* Edge clamping */

    function test_singlePoint_alwaysReturnsThatY() public pure {
        (uint256[] memory xs, uint256[] memory ys) = _onePoint(1_000, 7e18);
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 0), 7e18);
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 500), 7e18);
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 1_000), 7e18);
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 10_000), 7e18);
    }

    function test_twoPoint_boundaries() public pure {
        (uint256[] memory xs, uint256[] memory ys) = _twoPoint(100, 1e18, 200, 2e18);
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 100), 1e18); // at first
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 200), 2e18); // at last
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 50), 1e18); // below first
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 999), 2e18); // above last
    }

    /* Linear interpolation */

    function test_twoPoint_monotoneUp() public pure {
        (uint256[] memory xs, uint256[] memory ys) = _twoPoint(100, 1e18, 200, 3e18);
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 150), 2e18);
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 125), 1.5e18);
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 175), 2.5e18);
    }

    function test_twoPoint_monotoneDown() public pure {
        (uint256[] memory xs, uint256[] memory ys) = _twoPoint(100, 3e18, 200, 1e18);
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 150), 2e18);
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 175), 1.5e18);
    }

    function test_multiSegment_picksCorrectSegment() public pure {
        uint256[] memory xs = new uint256[](3);
        uint256[] memory ys = new uint256[](3);
        xs[0] = 100;
        xs[1] = 200;
        xs[2] = 400;
        ys[0] = 1e18;
        ys[1] = 3e18;
        ys[2] = 4e18;

        // Segment 1 midpoint
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 150), 2e18);
        // Interior knot exact
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 200), 3e18);
        // Segment 2 midpoint
        assertEq(LinearInterpolationLib.interpolate(xs, ys, 300), 3.5e18);
    }

    /* Input validation */

    function test_revertsOnEmptyCurve() public {
        uint256[] memory xs = new uint256[](0);
        uint256[] memory ys = new uint256[](0);
        vm.expectRevert(LinearInterpolationLib.EmptyCurve.selector);
        this.callInterpolate(xs, ys, 0);
    }

    function test_revertsOnLengthMismatch() public {
        uint256[] memory xs = new uint256[](2);
        uint256[] memory ys = new uint256[](1);
        xs[0] = 100;
        xs[1] = 200;
        ys[0] = 1e18;
        vm.expectRevert(LinearInterpolationLib.LengthMismatch.selector);
        this.callInterpolate(xs, ys, 150);
    }

    function callInterpolate(uint256[] calldata xs, uint256[] calldata ys, uint256 x) external pure returns (uint256) {
        uint256[] memory xsMem = xs;
        uint256[] memory ysMem = ys;
        return LinearInterpolationLib.interpolate(xsMem, ysMem, x);
    }

    /* Bounded-output property */

    function testFuzz_resultBoundedBySegment(uint256 query) public pure {
        (uint256[] memory xs, uint256[] memory ys) = _twoPoint(100, 1e18, 200, 3e18);
        query = bound(query, 100, 200);
        uint256 result = LinearInterpolationLib.interpolate(xs, ys, query);
        assertGe(result, 1e18);
        assertLe(result, 3e18);
    }

    function testFuzz_resultBoundedBySegment_decreasing(uint256 query) public pure {
        (uint256[] memory xs, uint256[] memory ys) = _twoPoint(100, 3e18, 200, 1e18);
        query = bound(query, 100, 200);
        uint256 result = LinearInterpolationLib.interpolate(xs, ys, query);
        assertGe(result, 1e18);
        assertLe(result, 3e18);
    }

    function testFuzz_clampingOutsideRange(uint256 query) public pure {
        (uint256[] memory xs, uint256[] memory ys) = _twoPoint(100, 1e18, 200, 3e18);
        // Below first
        if (query <= 100) {
            assertEq(LinearInterpolationLib.interpolate(xs, ys, query), 1e18);
        }
        // Above last
        if (query >= 200) {
            assertEq(LinearInterpolationLib.interpolate(xs, ys, query), 3e18);
        }
    }

    /* Identity at knots */

    function test_identityAtEveryKnot() public pure {
        // 5-point curve; query at each knot must return that knot's exact value.
        uint256[] memory xs = new uint256[](5);
        uint256[] memory ys = new uint256[](5);
        xs[0] = 0;
        ys[0] = 1e18;
        xs[1] = 100;
        ys[1] = 2e18;
        xs[2] = 250;
        ys[2] = 4e18;
        xs[3] = 500;
        ys[3] = 3e18;
        xs[4] = 1000;
        ys[4] = 5e18;

        for (uint256 i = 0; i < 5; i++) {
            assertEq(LinearInterpolationLib.interpolate(xs, ys, xs[i]), ys[i]);
        }
    }

    /* Linearity preservation: collinear input → output stays on the line */

    function testFuzz_linearityPreserved(uint256 query) public pure {
        // Three points on the line y = 2x + 5 (in WAD-scaled terms).
        uint256[] memory xs = new uint256[](3);
        uint256[] memory ys = new uint256[](3);
        xs[0] = 0;
        ys[0] = 5e18;
        xs[1] = 100;
        ys[1] = 205e18;
        xs[2] = 200;
        ys[2] = 405e18;

        query = bound(query, 0, 200);
        uint256 expected = 2 * query * 1e18 + 5e18;
        uint256 result = LinearInterpolationLib.interpolate(xs, ys, query);
        assertEq(result, expected);
    }

    /* Monotonicity preservation: monotone-up curve → result is monotone in x */

    function testFuzz_monotonicityPreserved(uint256 q1, uint256 q2) public pure {
        uint256[] memory xs = new uint256[](4);
        uint256[] memory ys = new uint256[](4);
        xs[0] = 100;
        ys[0] = 1e18;
        xs[1] = 200;
        ys[1] = 2e18;
        xs[2] = 400;
        ys[2] = 5e18;
        xs[3] = 800;
        ys[3] = 7e18;

        q1 = bound(q1, 0, 1000);
        q2 = bound(q2, q1, 1000);
        uint256 r1 = LinearInterpolationLib.interpolate(xs, ys, q1);
        uint256 r2 = LinearInterpolationLib.interpolate(xs, ys, q2);
        assertLe(r1, r2);
    }

    /* MAX_POINTS stress: 8-knot curve, every knot exact, mid-segment fuzz */

    function test_maxPoints_identityAtEveryKnot() public pure {
        uint256[] memory xs = new uint256[](8);
        uint256[] memory ys = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) {
            xs[i] = 100 * (i + 1); // 100, 200, ..., 800
            ys[i] = (i + 1) * 1e17; // 0.1e18, 0.2e18, ..., 0.8e18
        }
        for (uint256 i = 0; i < 8; i++) {
            assertEq(LinearInterpolationLib.interpolate(xs, ys, xs[i]), ys[i]);
        }
    }

    /* Helpers */

    function _onePoint(uint256 x0, uint256 y0) internal pure returns (uint256[] memory xs, uint256[] memory ys) {
        xs = new uint256[](1);
        ys = new uint256[](1);
        xs[0] = x0;
        ys[0] = y0;
    }

    function _twoPoint(uint256 x0, uint256 y0, uint256 x1, uint256 y1)
        internal
        pure
        returns (uint256[] memory xs, uint256[] memory ys)
    {
        xs = new uint256[](2);
        ys = new uint256[](2);
        xs[0] = x0;
        ys[0] = y0;
        xs[1] = x1;
        ys[1] = y1;
    }
}
