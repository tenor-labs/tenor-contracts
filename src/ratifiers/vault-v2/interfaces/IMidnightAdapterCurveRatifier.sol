// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {Market} from "@midnight/interfaces/IMidnight.sol";
import {IRatifier} from "@midnight/interfaces/IRatifier.sol";
import {IMarketMakingPolicy} from "../../interfaces/IMarketMakingPolicy.sol";

/// @title IMidnightAdapterCurveRatifier
/// @notice Interface of the curve sub-ratifier for Morpho Vault V2 MidnightAdapters.
interface IMidnightAdapterCurveRatifier is IRatifier {
    event CurveSet(
        address indexed adapter,
        bytes32 indexed tenorMarketId,
        address indexed onBehalf,
        IMarketMakingPolicy.CurvePoint[] points
    );
    event CurveCleared(address indexed adapter, bytes32 indexed tenorMarketId, address indexed onBehalf);
    event FundingSourceSet(address indexed adapter, address indexed onBehalf, bytes callbackData, bool allowed);
    event CadenceSet(address indexed adapter, address indexed onBehalf, address cadence);
    event AllowsRollingSet(address indexed adapter, address indexed onBehalf, bool allowed);

    error Unauthorized();
    error EmptyCurve();
    error TooManyPoints();
    error NonStrictlyIncreasingTtm();
    error CrossedCurve();

    error NotMaker();
    error NonEmptyRatifierData();
    error PostMaturity();
    error ForceSellable();
    error MarketHasLoss();
    error NoCurve();
    error TtmOutOfRange();
    error NoCadence();
    error MaturityOffCadence();
    error UnauthorizedFundingSource();
    error FundingMarketNotMatured();
    error NotReduceOnly();
    error InvalidGroup();
    error WorsePrice();

    /// @notice Maximum number of points in a curve.
    function MAX_POINTS() external view returns (uint256);

    /// @notice Prefix that every ratified offer's `group` must carry in its top 6 bytes: the "tenor" domain prefix plus
    /// the reserved schema version byte, so curve fills can never consume the groups of the adapter's other offers.
    function CURVE_GROUP_HEADER() external view returns (bytes32);

    /// @notice Mask selecting the top 6 bytes of `group` that `CURVE_GROUP_HEADER` occupies.
    function CURVE_GROUP_HEADER_MASK() external view returns (bytes32);

    /// @notice Returns the i-th point of `adapter`'s curve on `tenorMarketId`.
    function curves(address adapter, bytes32 tenorMarketId, uint256 i)
        external
        view
        returns (uint32 ttm, uint112 sellRate, uint112 buyRate);

    /// @notice Returns the number of points in `adapter`'s curve on `tenorMarketId`.
    function curveLength(address adapter, bytes32 tenorMarketId) external view returns (uint256);

    /// @notice Whether BUY offers of `adapter` may use the callback data hashing to `callbackDataHash`.
    function isFundingSource(address adapter, bytes32 callbackDataHash) external view returns (bool);

    /// @notice Whether BUY offers of `adapter` may be funded by its own withdrawable credit in a matured market, with
    /// callbackData `abi.encode(adapter, abi.encode(maturedMarket))`.
    function allowsRolling(address adapter) external view returns (bool);

    /// @notice Returns the IRenewalCadence whose points are the only maturities `adapter` buys at. Zero disables buys.
    function cadence(address adapter) external view returns (address);

    /// @notice Sets `adapter`'s maturity cadence. `onBehalf` must be an allocator, or a sentinel when unsetting it.
    function setCadence(address adapter, address newCadence, address onBehalf) external;

    /// @notice Overwrites `adapter`'s curve on `tenorMarketId`. `onBehalf` must be an allocator of the adapter's
    /// parent vault, and the caller must be `onBehalf` or authorized by it on the adapter's Morpho Midnight.
    /// @dev Enforces 1 to MAX_POINTS points, strictly increasing ttm, and sellRate <= buyRate at every point.
    function setCurve(
        address adapter,
        bytes32 tenorMarketId,
        IMarketMakingPolicy.CurvePoint[] calldata points,
        address onBehalf
    ) external;

    /// @notice Deletes `adapter`'s curve on `tenorMarketId`. `onBehalf` must be an allocator or a sentinel.
    function clearCurve(address adapter, bytes32 tenorMarketId, address onBehalf) external;

    /// @notice Allows or disallows `callbackData` as a funding source of `adapter`'s BUY offers. `onBehalf` must be an
    /// allocator, or a sentinel when disallowing.
    function setIsFundingSource(address adapter, bytes calldata callbackData, bool allowed, address onBehalf) external;

    /// @notice Allows or disallows funding `adapter`'s BUY offers from its own matured markets. `onBehalf` must be an
    /// allocator, or a sentinel when disallowing.
    function setAllowsRolling(address adapter, bool allowed, address onBehalf) external;

    /// @notice Returns the minimum net rate per second at which this contract ratifies `adapter`'s buys in `market`
    /// now.
    /// @dev Reverts with the same errors as `isRatified` when no buy is ratified in `market` now.
    /// @dev The adapter's own guardrails also apply to the take and are not reflected: maxTtm, minNetBuyRate, and
    /// force-removed or force-sellable markets.
    function buyRateBound(address adapter, Market memory market) external view returns (uint256);

    /// @notice Returns the maximum rate per second at which this contract ratifies `adapter`'s sells in `market` now.
    /// @dev Reverts with the same errors as `isRatified` when no sell is ratified in `market` now.
    /// @dev The adapter's own guardrails also apply to the take and are not reflected: maxNetSellRate, and
    /// force-removed markets.
    function sellRateBound(address adapter, Market memory market) external view returns (uint256);
}
