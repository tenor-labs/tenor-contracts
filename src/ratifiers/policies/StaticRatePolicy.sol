// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IInterestRatePolicy} from "../interfaces/IInterestRatePolicy.sol";
import {LinearInterpolationLib} from "../../libraries/LinearInterpolationLib.sol";
import {PackedRatePoint, RatePointLib} from "../../libraries/RatePointLib.sol";

/// @title StaticRatePolicy
/// @notice A configurable N-point rate policy.
/// @dev Stores the rate curve as immutable packed rate points embedded in the bytecode.
/// @dev The constructor does not validate its inputs: rates and durations must have the same length
/// (1 to 8) and durations must be strictly increasing.
contract StaticRatePolicy is IInterestRatePolicy {
    uint256 internal immutable lastIndex;
    PackedRatePoint public immutable rp0;
    PackedRatePoint public immutable rp1;
    PackedRatePoint public immutable rp2;
    PackedRatePoint public immutable rp3;
    PackedRatePoint public immutable rp4;
    PackedRatePoint public immutable rp5;
    PackedRatePoint public immutable rp6;
    PackedRatePoint public immutable rp7;

    /// @param rates The rates per second, in WAD.
    /// @param durations The durations in seconds (must be strictly increasing).
    constructor(uint128[] memory rates, uint128[] memory durations) {
        PackedRatePoint[8] memory packed;
        for (uint256 i = 0; i < rates.length; i++) {
            packed[i] = RatePointLib.pack(rates[i], durations[i]);
        }

        lastIndex = rates.length - 1;
        rp0 = packed[0];
        rp1 = packed[1];
        rp2 = packed[2];
        rp3 = packed[3];
        rp4 = packed[4];
        rp5 = packed[5];
        rp6 = packed[6];
        rp7 = packed[7];
    }

    /// @notice Returns the number of rate points in the policy.
    function numPoints() external view returns (uint256) {
        return lastIndex + 1;
    }

    /// @inheritdoc IInterestRatePolicy
    function getRate(bytes32, bytes32, uint256 renewalPeriodStart, address, address, uint256, uint256, bool)
        public
        view
        virtual
        override
        returns (uint256)
    {
        uint256 elapsed = block.timestamp > renewalPeriodStart ? block.timestamp - renewalPeriodStart : 0;
        (uint256[] memory knots, uint256[] memory values) = _loadCurve();
        return LinearInterpolationLib.interpolate(knots, values, elapsed);
    }

    /// @dev Materializes the bytecode-immutable rate points into parallel `(knots, values)` arrays.
    function _loadCurve() internal view returns (uint256[] memory knots, uint256[] memory values) {
        uint256 n = lastIndex + 1;
        knots = new uint256[](n);
        values = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            PackedRatePoint p = _getPoint(i);
            knots[i] = p.duration();
            values[i] = p.rate();
        }
    }

    function _getPoint(uint256 i) private view returns (PackedRatePoint) {
        if (i == 0) return rp0;
        if (i == 1) return rp1;
        if (i == 2) return rp2;
        if (i == 3) return rp3;
        if (i == 4) return rp4;
        if (i == 5) return rp5;
        if (i == 6) return rp6;
        return rp7;
    }
}
