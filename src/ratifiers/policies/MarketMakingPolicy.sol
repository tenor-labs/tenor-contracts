// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {LinearInterpolationLib} from "../../libraries/LinearInterpolationLib.sol";
import {IInterestRatePolicy} from "../interfaces/IInterestRatePolicy.sol";
import {IMarketMakingPolicy} from "../interfaces/IMarketMakingPolicy.sol";

/// @title MarketMakingPolicy
/// @notice Singleton IInterestRatePolicy where each user writes one curve per Tenor market.
/// @dev Each point carries (ttm, sellRate, buyRate) on a shared TTM grid with sellRate <= buyRate enforced point-wise.
/// getRate returns the side selected by userIsBuyer (true when buying credit on Midnight); the rate gap is the spread.
/// @dev Rates are capped at type(uint112).max: within 192 seconds of maturity, even the max rate gives
/// price = WAD^2 / (WAD + rate * ttm) >= 1 after flooring, so a quote of exactly 0 is not expressible there.
/// @dev The policy does not verify which callback is in use; it trusts the userIsBuyer
/// flag and the maturities provided by the ratifier.
/// @dev getRate reverts on Midnight to Midnight renewals (both source and target maturities nonzero); not supported.
/// @dev Lend-only: only lend entry and exit flows are supported (vault -> Midnight and Midnight -> vault).
/// @dev `setCurve`/`clearCurve` use the Midnight contract as authorization authority (caller must be `onBehalf` or
/// authorized by it on Midnight); each maker's curve is stored per `(onBehalf, tenorMarketId)`.
contract MarketMakingPolicy is IMarketMakingPolicy {
    using UtilsLib for uint256;

    /// @inheritdoc IMarketMakingPolicy
    IMidnight public immutable MORPHO_MIDNIGHT;

    uint256 internal constant MAX_POINTS = 8;

    mapping(address user => mapping(bytes32 tenorMarketId => CurvePoint[])) public curves;

    constructor(address morphoMidnight) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
    }

    /// @inheritdoc IMarketMakingPolicy
    function setCurve(address onBehalf, bytes32 tenorMarketId, CurvePoint[] calldata points) external {
        if (msg.sender != onBehalf && !MORPHO_MIDNIGHT.isAuthorized(onBehalf, msg.sender)) revert Unauthorized();
        uint256 n = points.length;
        if (n == 0) revert EmptyCurve();
        if (n > MAX_POINTS) revert TooManyPoints();

        if (points[0].sellRate > points[0].buyRate) revert CrossedCurve();
        for (uint256 i = 1; i < n; i++) {
            if (points[i].ttm <= points[i - 1].ttm) revert NonStrictlyIncreasingTtm();
            if (points[i].sellRate > points[i].buyRate) revert CrossedCurve();
        }

        curves[onBehalf][tenorMarketId] = points;
        emit CurveSet(onBehalf, tenorMarketId, points);
    }

    /// @inheritdoc IMarketMakingPolicy
    function clearCurve(address onBehalf, bytes32 tenorMarketId) external {
        if (msg.sender != onBehalf && !MORPHO_MIDNIGHT.isAuthorized(onBehalf, msg.sender)) revert Unauthorized();
        delete curves[onBehalf][tenorMarketId];
        emit CurveCleared(onBehalf, tenorMarketId);
    }

    /// @inheritdoc IInterestRatePolicy
    /// @dev Midnight to Midnight renewals are rejected. A buy quotes the target market's buyRate, a sell the source
    /// market's sellRate. The ttm is floored at zero so past-maturity markets clamp instead of underflowing.
    /// @dev Quotes are taker-agnostic: the same curve serves every counterparty.
    function getRate(
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        uint256, /* renewalPeriodStart */
        address user,
        address, /* taker */
        uint256 sourceMaturity,
        uint256 targetMaturity,
        bool userIsBuyer
    ) public view virtual returns (uint256) {
        if (sourceMaturity != 0 && targetMaturity != 0) revert UnsupportedMigrationRoute();

        (bytes32 marketId, uint256 maturity) =
            userIsBuyer ? (targetTenorMarketId, targetMaturity) : (sourceTenorMarketId, sourceMaturity);

        // Lend-only: borrow flows select the zero-maturity variable leg, so reject them here.
        if (maturity == 0) revert UnsupportedMigrationRoute();

        CurvePoint[] storage curve = curves[user][marketId];
        if (curve.length == 0) revert NoCurveForUserMarket();

        (uint256[] memory knots, uint256[] memory values) = _loadCurve(curve, userIsBuyer);
        return LinearInterpolationLib.interpolate(knots, values, maturity.zeroFloorSub(block.timestamp));
    }

    /// @dev Materializes the requested side of `curve` into parallel `(knots, values)` arrays.
    function _loadCurve(CurvePoint[] storage curve, bool buySide)
        private
        view
        returns (uint256[] memory knots, uint256[] memory values)
    {
        uint256 n = curve.length;
        knots = new uint256[](n);
        values = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            CurvePoint memory p = curve[i];
            knots[i] = p.ttm;
            values[i] = buySide ? p.buyRate : p.sellRate;
        }
    }
}
