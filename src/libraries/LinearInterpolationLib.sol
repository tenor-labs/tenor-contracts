// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";

/// @title LinearInterpolationLib
/// @notice Piecewise-linear interpolation with edge clamping over a sorted (x, y) curve.
library LinearInterpolationLib {
    using UtilsLib for uint256;

    error EmptyCurve();
    error LengthMismatch();

    /// @dev The caller must ensure knots is strictly increasing; unsorted input is undefined behavior and may revert.
    /// @dev Reverts if knots is empty or knots.length != values.length.
    /// @dev Rounds towards the left knot's value (down when the segment slopes upward, up when it slopes downward).
    /// @dev The error is < 1 and the result stays within the segment's two knot values.
    function interpolate(uint256[] memory knots, uint256[] memory values, uint256 x) internal pure returns (uint256 y) {
        uint256 n = knots.length;
        if (n == 0) revert EmptyCurve();
        if (values.length != n) revert LengthMismatch();

        if (x <= knots[0]) return values[0];
        uint256 lastIndex = n - 1;
        if (x >= knots[lastIndex]) return values[lastIndex];

        y = values[lastIndex];

        for (uint256 i = 0; i < lastIndex;) {
            if (x < knots[i + 1]) {
                uint256 segDuration = knots[i + 1] - knots[i];
                uint256 segElapsed = x - knots[i];
                if (values[i + 1] >= values[i]) {
                    return values[i] + (values[i + 1] - values[i]).mulDivDown(segElapsed, segDuration);
                }
                return values[i] - (values[i] - values[i + 1]).mulDivDown(segElapsed, segDuration);
            }
            unchecked {
                ++i;
            }
        }
    }
}
