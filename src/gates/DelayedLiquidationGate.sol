// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {ILiquidateCallback} from "@midnight/interfaces/ICallbacks.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {SafeTransferLib} from "@midnight/libraries/SafeTransferLib.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiquidatorGate} from "@midnight/interfaces/IGate.sol";
import {IDelayedLiquidationGate} from "./interfaces/IDelayedLiquidationGate.sol";

/// @title DelayedLiquidationGate
/// @notice Combined ILiquidatorGate and liquidation router enforcing a grace period before liquidations.
/// @dev Set as the market's liquidatorGate. Liquidators call liquidate here instead of Midnight directly.
/// @dev Token flows are handled through Midnight's onLiquidate callback.
/// @dev Incompatible with markets whose collateral is gated VaultV2 shares routed through
/// MidnightVaultExecutor: both call paths revert and the position becomes unliquidatable.
/// @dev startGracePeriod is permissionless and callable whenever the position is unhealthy, including
/// mid-transaction; the caller freely picks the priority liquidator, who has exclusive rights for PRIORITY_PERIOD.
/// @dev The grace timer is not reset if the borrower recovers to healthy; a position that later becomes
/// unhealthy again inherits the old timer and may be liquidatable without a fresh grace period.
contract DelayedLiquidationGate is IDelayedLiquidationGate, ILiquidatorGate {
    using SafeERC20 for IERC20;

    IMidnight public immutable MORPHO_MIDNIGHT;
    uint256 public immutable GRACE_PERIOD;
    uint256 public immutable LIQUIDATION_PERIOD;
    uint256 public immutable PRIORITY_PERIOD;

    /// @dev Maps borrower => marketId => grace period info: timestamp and priority liquidator packed in one slot.
    mapping(address borrower => mapping(bytes32 marketId => GracePeriodInfo)) public gracePeriodInfo;

    constructor(address morphoMidnight, uint256 _gracePeriod, uint256 _liquidationPeriod, uint256 _priorityPeriod) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
        GRACE_PERIOD = _gracePeriod;
        LIQUIDATION_PERIOD = _liquidationPeriod;
        PRIORITY_PERIOD = _priorityPeriod;
    }

    /// @inheritdoc IDelayedLiquidationGate
    function startGracePeriod(bytes32 marketId, address borrower, address _priorityLiquidator) external {
        uint256 startTime = gracePeriodInfo[borrower][marketId].timestamp;
        if (startTime != 0) {
            uint256 elapsed = block.timestamp - startTime;
            uint256 totalPeriod = GRACE_PERIOD + LIQUIDATION_PERIOD;

            if (elapsed < totalPeriod) {
                revert GracePeriodAlreadyActive();
            }
        }

        Market memory market = MORPHO_MIDNIGHT.toMarket(marketId);

        if (MORPHO_MIDNIGHT.liquidationLocked(marketId, borrower)) {
            revert PositionLocked();
        }

        if (MORPHO_MIDNIGHT.isHealthy(market, marketId, borrower)) {
            revert PositionIsHealthy();
        }

        gracePeriodInfo[borrower][marketId] =
            GracePeriodInfo({timestamp: uint56(block.timestamp), priorityLiquidator: _priorityLiquidator});

        emit GracePeriodStarted(borrower, marketId, block.timestamp, _priorityLiquidator);
    }

    /// @inheritdoc ILiquidatorGate
    function canLiquidate(address account) external view returns (bool) {
        return account == address(this);
    }

    /// @inheritdoc IDelayedLiquidationGate
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
    ) external returns (uint256, uint256) {
        if (callback != address(0) && callback != msg.sender) revert InvalidCallback();
        _requireLiquidationAllowed(market, borrower);

        return MORPHO_MIDNIGHT.liquidate(
            market,
            collateralIndex,
            seizedAssets,
            repaidUnits,
            borrower,
            postMaturityMode,
            receiver,
            address(this),
            abi.encode(msg.sender, callback, data)
        );
    }

    function onLiquidate(
        address callerFromMidnight,
        bytes32 marketId,
        Market memory market,
        uint256 collateralIndex,
        uint256 seizedAssets,
        uint256 repaidUnits,
        address borrower,
        address receiver,
        bytes memory data,
        uint256 badDebt
    ) external returns (bytes32) {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert NotMorpho();
        if (callerFromMidnight != address(this)) revert LiquidationNotAllowed();

        (address sender, address callback, bytes memory innerData) = abi.decode(data, (address, address, bytes));

        if (callback != address(0)) {
            require(
                ILiquidateCallback(callback)
                    .onLiquidate(
                        sender,
                        marketId,
                        market,
                        collateralIndex,
                        seizedAssets,
                        repaidUnits,
                        borrower,
                        receiver,
                        innerData,
                        badDebt
                    ) == CALLBACK_SUCCESS,
                IMidnight.WrongLiquidateCallbackReturnValue()
            );
        }

        if (repaidUnits > 0) {
            SafeTransferLib.safeTransferFrom(market.loanToken, sender, address(this), repaidUnits);
            IERC20(market.loanToken).forceApprove(address(MORPHO_MIDNIGHT), repaidUnits);
        }

        return CALLBACK_SUCCESS;
    }

    /// @dev Pre-maturity only: once `market.maturity` is crossed, gate checks are skipped and liquidation is
    /// permissionless by design.
    function _requireLiquidationAllowed(Market calldata market, address borrower) internal view {
        if (block.timestamp <= market.maturity) {
            bytes32 marketId = IdLib.toId(market);

            GracePeriodInfo memory info = gracePeriodInfo[borrower][marketId];
            if (info.timestamp == 0) revert LiquidationNotAllowed();

            uint256 elapsed = block.timestamp - info.timestamp;
            if (elapsed < GRACE_PERIOD || elapsed >= GRACE_PERIOD + LIQUIDATION_PERIOD) {
                revert LiquidationNotAllowed();
            }

            uint256 liquidationElapsed = elapsed - GRACE_PERIOD;
            if (
                liquidationElapsed < PRIORITY_PERIOD && info.priorityLiquidator != address(0)
                    && msg.sender != info.priorityLiquidator
            ) {
                revert LiquidationNotAllowed();
            }
        }
    }
}
