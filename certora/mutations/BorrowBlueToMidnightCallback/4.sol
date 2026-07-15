/* ── MUTATION BorrowBlueToMidnightCallback #4 ──────────────────────────────
 * @desc:   onSell Midnight supply amount collateralMigrated -1 : mnIn = blueOut-1, breaks 1:1 conservation
 * @rules:  migrationConservesMigratedCollateral
 * @conf:   certora/confs/callbacks/BorrowBlueToMidnightCallback/perf/migrationConservesMigratedCollateral.conf
 * @status: killed
 * @target: src/callbacks/BorrowBlueToMidnightCallback.sol
 * Was:     MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated, seller);
 * Now:     MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated - 1, seller);
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {IMorpho, MarketParams, Id, Position} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@morphoBlue/libraries/periphery/MorphoBalancesLib.sol";
import {IBorrowBlueToMidnightCallback} from "./interfaces/IBorrowBlueToMidnightCallback.sol";
import {SafeTransferLib} from "@midnight/libraries/SafeTransferLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BorrowBlueToMidnightCallback
/// @notice Callback that migrates a borrower position from Morpho Blue to the target Midnight market when that
/// market's SELL offer is taken.
/// @dev The offer's receiverIfMakerIsSeller (or receiverIfTakerIsSeller when the taker sells) must be this contract
/// so that sellerAssets are transferred here before onSell is called; onSell reverts with InvalidReceiver otherwise.
/// @dev Repays the Morpho Blue debt with the sale proceeds (minus fee) and migrates collateral to Midnight pro-rata
/// to the repaid debt, all of it on the final fill.
/// @dev The borrower must authorize this contract on Morpho Blue (collateral withdrawal) and Morpho Midnight
/// (collateral supply).
/// @dev Pre-existing Midnight positions are netted: the borrower can end up with collateral but no debt on Midnight.
/// @dev Partial fills migrate collateral pro-rata to the repaid debt, rounded down, so a small fill can migrate
/// less collateral than the repaid debt implies (down to zero on tiny fills), temporarily increasing the target
/// position's LTV until the final fill migrates all remaining collateral. Zero-amount collateral operations
/// are skipped.
contract BorrowBlueToMidnightCallback is IBorrowBlueToMidnightCallback {
    using UtilsLib for uint256;
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using CallbackLib for Market;

    IMidnight public immutable MORPHO_MIDNIGHT;
    IMorpho public immutable MORPHO_BLUE;

    constructor(address morphoMidnight, address morphoBlue) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
        MORPHO_BLUE = IMorpho(morphoBlue);
    }

    function onSell(
        bytes32 marketId,
        Market memory market,
        uint256 sellerAssets,
        uint256 units,
        uint256, /* pendingFeeDecrease */
        address seller,
        address receiver,
        bytes memory data
    ) external override returns (bytes32) {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
        if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();

        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        MarketParams memory sourceMarketParams = callbackData.sourceMarketParams;
        address loanToken = market.loanToken;
        if (sourceMarketParams.loanToken != loanToken) revert CallbackLib.TokenMismatch();
        (bool found, uint256 collateralIndex) = market.findCollateral(sourceMarketParams.collateralToken);
        if (!found) revert CallbackLib.TokenMismatch();

        Id sourceBlueMarketId = sourceMarketParams.id();
        Position memory bluePosition = MORPHO_BLUE.position(sourceBlueMarketId, seller);
        uint256 blueCollateral = bluePosition.collateral;
        uint256 blueDebt = MORPHO_BLUE.expectedBorrowAssets(sourceMarketParams, seller);

        uint256 fee = CallbackLib.sellerFeeFromTick(callbackData.tick, callbackData.feeRate, units, sellerAssets);
        if (fee > 0) {
            SafeTransferLib.safeTransfer(loanToken, callbackData.feeRecipient, fee);
        }
        uint256 repayBudget = sellerAssets - fee;

        if (repayBudget > blueDebt) revert CallbackLib.ExcessRepayment();
        IERC20(loanToken).forceApprove(address(MORPHO_BLUE), repayBudget);

        bool isFinalFill = repayBudget == blueDebt;
        if (isFinalFill) {
            MORPHO_BLUE.repay(sourceMarketParams, 0, bluePosition.borrowShares, seller, "");
        } else {
            MORPHO_BLUE.repay(sourceMarketParams, repayBudget, 0, seller, "");
        }

        uint256 collateralMigrated = isFinalFill ? blueCollateral : blueCollateral.mulDivDown(repayBudget, blueDebt);

        if (collateralMigrated > 0) {
            MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
            IERC20(sourceMarketParams.collateralToken).forceApprove(address(MORPHO_MIDNIGHT), collateralMigrated);
            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated - 1, seller);  // MUTATION: rebased
        }

        emit BorrowMigratedBlueToMidnight(
            seller,
            Id.unwrap(sourceBlueMarketId),
            marketId,
            repayBudget,
            units,
            sourceMarketParams.collateralToken,
            collateralMigrated,
            fee
        );

        return CALLBACK_SUCCESS;
    }
}
