/* ── MUTATION BorrowMidnightToBlueCallback #25 ──────────────────────────────
 * @desc:   Migrating one unit less than the full source collateral on the final fill leaves a unit of old Midnight collateral behind after the debt is fully repaid, so the rule that the final fill drains all old collateral flips to a counterexample.
 * @rules:  migrationFinalFillTransfersAllOldMidnightCollateral
 * @conf:   certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/migrationFinalFillTransfersAllOldMidnightCollateral.conf
 * @status: killed
 * @target: src/callbacks/BorrowMidnightToBlueCallback.sol
 * Was:     sourceDebtAfter == 0 ? sourceCollateral : sourceCollateral.mulDivDown(units, sourceDebtBefore);
 * Now:     sourceDebtAfter == 0 ? sourceCollateral - 1 : sourceCollateral.mulDivDown(units, sourceDebtBefore);
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {IMorpho, MarketParams, Id} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";
import {IBorrowMidnightToBlueCallback} from "./interfaces/IBorrowMidnightToBlueCallback.sol";
import {SafeTransferLib} from "@midnight/libraries/SafeTransferLib.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BorrowMidnightToBlueCallback
/// @notice Callback that migrates a borrower position from Midnight to Morpho Blue when a Midnight BUY offer is taken.
/// @dev Withdraws collateral from Midnight pro-rata to the repaid debt (all of it on the final fill), supplies it to
/// Morpho Blue, and borrows buyerAssets + fee on Morpho Blue on behalf of the borrower to settle the offer.
/// @dev Only the target Blue market's single collateral token migrates; other source collaterals stay on Midnight,
/// which can adversely affect the source or target LTV. Use only the target's collateral on the source position.
/// @dev On small partial fills, the pro-rata collateral withdrawal can round to zero even though debt is migrated,
/// temporarily increasing the target Blue position's LTV until the position is fully migrated. Zero-amount
/// collateral operations are skipped.
/// @dev The fee is borrowed in addition to buyerAssets so any feeRate > 0 raises the post-migration Blue LTV.
/// @dev The borrower must authorize this contract on Morpho Midnight (collateral withdrawal) and Morpho Blue (borrow).
/// @dev Reverts if the fill would leave the borrower with credit on the Midnight market.
/// @dev Relies on available Morpho Blue liquidity for the borrow; fills revert if it is insufficient at fill time.
contract BorrowMidnightToBlueCallback is IBorrowMidnightToBlueCallback {
    using UtilsLib for uint256;
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using CallbackLib for Market;

    IMidnight public immutable MORPHO_MIDNIGHT;
    IMorpho public immutable MORPHO_BLUE;

    constructor(address morphoMidnight, address morphoBlue) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
        MORPHO_BLUE = IMorpho(morphoBlue);
    }

    function onBuy(
        bytes32 marketId,
        Market memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256,
        address buyer,
        bytes memory data
    ) external override returns (bytes32) {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
        if (buyerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();

        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        if (callbackData.targetMarketParams.loanToken != market.loanToken) revert CallbackLib.TokenMismatch();
        (bool found, uint256 collateralIndex) = market.findCollateral(callbackData.targetMarketParams.collateralToken);
        if (!found) revert CallbackLib.TokenMismatch();

        (uint128 buyerCredit,,) = MORPHO_MIDNIGHT.updatePositionView(market, marketId, buyer);
        if (buyerCredit != 0) revert CallbackLib.PositionCrossing();

        uint256 sourceDebtAfter = MORPHO_MIDNIGHT.debt(marketId, buyer);
        uint256 sourceCollateral = MORPHO_MIDNIGHT.collateral(marketId, buyer, collateralIndex);
        uint256 sourceDebtBefore = sourceDebtAfter + units;

        uint256 fee;
        if (callbackData.feeRate > 0) {
            fee = CallbackLib.percentageFee(buyerAssets, callbackData.feeRate);
        }

        uint256 collateralMigrated =
            sourceDebtAfter == 0 ? sourceCollateral - 1 : sourceCollateral.mulDivDown(units, sourceDebtBefore);  // MUTATION: rebased

        if (collateralMigrated > 0) {
            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));

            IERC20(callbackData.targetMarketParams.collateralToken)
                .forceApprove(address(MORPHO_BLUE), collateralMigrated);
            MORPHO_BLUE.supplyCollateral(callbackData.targetMarketParams, collateralMigrated, buyer, "");
        }

        uint256 borrowAmount = buyerAssets + fee;
        MORPHO_BLUE.borrow(callbackData.targetMarketParams, borrowAmount, 0, buyer, address(this));

        if (fee > 0) {
            SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
        }
        IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);

        emit BorrowMigratedMidnightToBlue(
            buyer,
            marketId,
            Id.unwrap(callbackData.targetMarketParams.id()),
            units,
            borrowAmount,
            callbackData.targetMarketParams.collateralToken,
            collateralMigrated,
            fee
        );

        return CALLBACK_SUCCESS;
    }
}
