// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

type PackedRatePoint is uint256;

using RatePointLib for PackedRatePoint global;

/// @title RatePointLib
/// @notice Library for packing and unpacking rate curve points (rate, duration).
library RatePointLib {
    /// @dev Returns the PackedRatePoint with the rate in the high 128 bits and the duration in the low 128 bits.
    function pack(uint128 _rate, uint128 _duration) internal pure returns (PackedRatePoint) {
        return PackedRatePoint.wrap((uint256(_rate) << 128) | uint256(_duration));
    }

    /// @dev Returns the rate of a packed rate point.
    function rate(PackedRatePoint p) internal pure returns (uint256) {
        return PackedRatePoint.unwrap(p) >> 128;
    }

    /// @dev Returns the duration of a packed rate point.
    function duration(PackedRatePoint p) internal pure returns (uint256) {
        return PackedRatePoint.unwrap(p) & type(uint128).max;
    }
}
