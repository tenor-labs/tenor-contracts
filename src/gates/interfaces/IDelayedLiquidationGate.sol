// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";

/// @title IDelayedLiquidationGate
/// @notice Interface of the combined ILiquidatorGate and liquidation router enforcing a grace period before
/// liquidations.
interface IDelayedLiquidationGate {
    /// @dev Packed into a single storage slot: uint56 (7 bytes) + address (20 bytes) = 27 bytes.
    struct GracePeriodInfo {
        uint56 timestamp;
        address priorityLiquidator;
    }

    event GracePeriodStarted(
        address indexed borrower, bytes32 indexed marketId, uint256 timestamp, address priorityLiquidator
    );

    error GracePeriodAlreadyActive();
    error PositionIsHealthy();
    error PositionLocked();
    error NotMorpho();
    error LiquidationNotAllowed();
    error InvalidCallback();

    /// @notice The Morpho Midnight protocol this gate is bound to.
    function MORPHO_MIDNIGHT() external view returns (IMidnight);

    /// @notice The seconds between startGracePeriod and the earliest liquidation.
    function GRACE_PERIOD() external view returns (uint256);

    /// @notice The seconds during which liquidation is permitted, starting GRACE_PERIOD after the window opened.
    /// After this period elapses without liquidation, the window expires.
    function LIQUIDATION_PERIOD() external view returns (uint256);

    /// @notice The seconds at the start of the liquidation window during which only the priorityLiquidator recorded
    /// at startGracePeriod time may liquidate. Once elapsed, or if it is address(0), any address may liquidate.
    function PRIORITY_PERIOD() external view returns (uint256);

    /// @notice Returns the last recorded grace period entry of (borrower, marketId). Entries are never cleared, so
    /// expired or consumed windows return stale data.
    function gracePeriodInfo(address borrower, bytes32 marketId)
        external
        view
        returns (uint56 timestamp, address priorityLiquidator);

    /// @notice Opens the grace window on an unhealthy position.
    /// @dev Reverts if a window is already open.
    /// @dev Reverts if the position is still healthy at call time.
    /// @dev Reverts if the position's liquidation is locked on Midnight.
    /// @param marketId The market in distress.
    /// @param borrower The borrower being liquidated.
    /// @param _priorityLiquidator The address with exclusive liquidation rights during the priority sub-window.
    function startGracePeriod(bytes32 marketId, address borrower, address _priorityLiquidator) external;

    /// @notice Liquidates a position whose grace window has elapsed.
    /// @dev Pre-maturity, reverts if no grace window has been opened, before GRACE_PERIOD elapses, after the window
    /// expires, or during the priority sub-window when called by a non-priority address.
    /// @dev Past market.maturity, the window checks are skipped and liquidation via this gate is permissionless.
    /// @param postMaturityMode Selects the Midnight liquidation mode: true = post-maturity mode (requires
    /// block.timestamp > market.maturity; LIF ramps from 1 to maxLif over TIME_TO_MAX_LIF; RCF disabled), false =
    /// normal mode (requires originalDebt > maxDebt; LIF = maxLif; RCF applies). See IMidnight.liquidate.
    /// @param receiver The address receiving the seized collateral, forwarded to Midnight.
    /// @param callback Optional flash-liquidation callback. Must be zero or the caller; when nonzero, must
    /// implement ILiquidateCallback.onLiquidate.
    /// @param data Arbitrary data forwarded to the callback's onLiquidate.
    function liquidate(
        Market calldata market,
        uint256 collateralIndex,
        uint256 seizedAssets,
        uint256 repaidUnits,
        address borrower,
        bool postMaturityMode,
        address receiver,
        address callback,
        bytes calldata data
    ) external returns (uint256, uint256);
}
