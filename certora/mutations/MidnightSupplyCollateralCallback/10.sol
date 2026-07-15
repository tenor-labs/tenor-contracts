/* ── MUTATION MidnightSupplyCollateralCallback #10 ──────────────────────────────
 * @desc:   onSell receiver guard flipped (routing check inverted)
 * @rules:  receiverIsCallbackReverts
 * @conf:   certora/confs/callbacks/MidnightSupplyCollateralCallback/receiverIsCallbackReverts.conf
 * @status: killed
 * @target: src/callbacks/MidnightSupplyCollateralCallback.sol
 * Was:     if (receiver == address(this)) revert CallbackLib.InvalidReceiver();
 * Now:     if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {IMidnightSupplyCollateralCallback} from "./interfaces/IMidnightSupplyCollateralCallback.sol";
import {IOracle} from "@midnight/interfaces/IOracle.sol";
import {SafeTransferLib} from "@midnight/libraries/SafeTransferLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD, ORACLE_PRICE_SCALE, CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";

/// @title MidnightSupplyCollateralCallback
/// @notice Supplies a borrower's collateral just in time when a SELL offer is taken on Midnight.
/// @dev The borrower must approve this contract per collateral token and authorize it on Midnight.
/// @dev Collateral is scaled to the fill and rounded down; slots that round to zero are skipped, so many small fills
/// can supply less collateral than one full fill. `maxBorrowCapacityUsage` guards the resulting position health.
/// @dev The offer's receiver must not be this contract; onSell reverts InvalidReceiver otherwise.
contract MidnightSupplyCollateralCallback is IMidnightSupplyCollateralCallback {
    using UtilsLib for uint256;
    using SafeERC20 for IERC20;

    IMidnight public immutable MORPHO_MIDNIGHT;

    constructor(address morphoMidnight) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
    }

    function onSell(
        bytes32 marketId,
        Market memory market,
        uint256 sellerAssets,
        uint256 units,
        uint256,
        address seller,
        address receiver,
        bytes memory data
    ) external override returns (bytes32) {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();  // MUTATION: onSell receiver guard flipped (routing check inverted)
        if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();

        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        if (callbackData.offerSellerAssets == 0) revert CallbackLib.ZeroAmount();

        uint256 collateralsLength = market.collateralParams.length;
        if (callbackData.amounts.length != collateralsLength) revert CallbackLib.InvalidCollateral();

        uint256[] memory collateralAmounts = new uint256[](collateralsLength);

        for (uint256 i = 0; i < collateralsLength;) {
            uint256 configAmount = callbackData.amounts[i];

            if (configAmount > 0) {
                uint256 supplyAmount = configAmount.mulDivDown(sellerAssets, callbackData.offerSellerAssets);
                if (supplyAmount > 0) {
                    address token = market.collateralParams[i].token;
                    SafeTransferLib.safeTransferFrom(token, seller, address(this), supplyAmount);
                    IERC20(token).forceApprove(address(MORPHO_MIDNIGHT), supplyAmount);
                    MORPHO_MIDNIGHT.supplyCollateral(market, i, supplyAmount, seller);
                }
                collateralAmounts[i] = supplyAmount;
            }
            unchecked {
                ++i;
            }
        }

        if (callbackData.maxBorrowCapacityUsage > 0) {
            uint256 borrowCapacityUsage = _borrowCapacityUsage(market, seller, marketId);
            if (borrowCapacityUsage > callbackData.maxBorrowCapacityUsage) {
                revert CallbackLib.InvalidBorrowCapacityUsage();
            }
        }

        emit CollateralSupplied(seller, marketId, collateralAmounts);

        return CALLBACK_SUCCESS;
    }

    /// @dev Returns `borrower`'s debt as a fraction of borrowing capacity, rounded up; Midnight's isHealthy() ratio,
    /// where WAD is the liquidation threshold.
    function _borrowCapacityUsage(Market memory market, address borrower, bytes32 marketId)
        internal
        view
        returns (uint256)
    {
        uint256 debt = MORPHO_MIDNIGHT.debt(marketId, borrower);

        if (debt == 0) return 0;

        uint256 maxDebt;
        uint256 collateralsLength = market.collateralParams.length;

        for (uint256 i = 0; i < collateralsLength;) {
            uint256 collateralAmount = MORPHO_MIDNIGHT.collateral(marketId, borrower, i);
            if (collateralAmount > 0) {
                uint256 price = IOracle(market.collateralParams[i].oracle).price();
                maxDebt += collateralAmount.mulDivDown(price, ORACLE_PRICE_SCALE)
                    .mulDivDown(market.collateralParams[i].lltv, WAD);
            }
            unchecked {
                ++i;
            }
        }

        if (maxDebt == 0) revert CallbackLib.InvalidBorrowCapacityUsage();

        return debt.mulDivUp(WAD, maxDebt);
    }
}
