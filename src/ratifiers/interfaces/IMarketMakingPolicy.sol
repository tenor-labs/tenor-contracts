// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {IInterestRatePolicy} from "./IInterestRatePolicy.sol";

/// @title IMarketMakingPolicy
/// @notice Interface of the market making policy where users quote per-market yield curves.
interface IMarketMakingPolicy is IInterestRatePolicy {
    /// @notice One point on a yield curve.
    /// @param ttm The time to maturity in seconds, the curve's x-axis.
    /// @param sellRate Per-second rate in WAD quoted by the lender to sell credit on Midnight (exit a position).
    /// @param buyRate Per-second rate in WAD quoted by the lender to buy credit on Midnight (enter a position).
    struct CurvePoint {
        uint32 ttm;
        uint112 sellRate;
        uint112 buyRate;
    }

    event CurveSet(address indexed user, bytes32 indexed tenorMarketId, CurvePoint[] points);
    event CurveCleared(address indexed user, bytes32 indexed tenorMarketId);

    error EmptyCurve();
    error TooManyPoints();
    error NonStrictlyIncreasingTtm();
    error CrossedCurve();
    error NoCurveForUserMarket();
    error Unauthorized();
    error UnsupportedMigrationRoute();

    /// @notice The Morpho Midnight protocol used for authorization checks.
    function MORPHO_MIDNIGHT() external view returns (IMidnight);

    /// @notice Returns the i-th point of the curve of `user` on `tenorMarketId`.
    function curves(address user, bytes32 tenorMarketId, uint256 i)
        external
        view
        returns (uint32 ttm, uint112 sellRate, uint112 buyRate);

    /// @notice Overwrites the curve of `onBehalf` for `tenorMarketId`.
    /// @dev Enforces 1 to MAX_POINTS points, strictly increasing ttm, and sellRate <= buyRate at every point.
    function setCurve(address onBehalf, bytes32 tenorMarketId, CurvePoint[] calldata points) external;

    /// @notice Deletes the curve of `onBehalf` for `tenorMarketId`.
    function clearCurve(address onBehalf, bytes32 tenorMarketId) external;
}
