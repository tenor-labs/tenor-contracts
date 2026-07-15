/* ── MUTATION BorrowMidnightRenewalCallback #35 ──────────────────────────────
 * @desc:   Flipping the Midnight-caller guard to == makes onSell revert immediately on every in-model take because the caller is always Midnight, so the thirdPartyBalanceUnchanged, callbackHoldsZeroAllowance, and feeRecipientNeverLosesTokens satisfy witnesses become unsatisfiable.
 * @rules:  thirdPartyBalanceUnchanged__satisfy, callbackHoldsZeroAllowance__satisfy, feeRecipientNeverLosesTokens__satisfy
 * @conf:   certora/confs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/thirdPartyBalanceUnchanged.conf
 * @status: killed
 * @target: src/callbacks/BorrowMidnightRenewalCallback.sol
 * Was:     if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
 * Now:     if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {Market, IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {IBorrowMidnightRenewalCallback} from "./interfaces/IBorrowMidnightRenewalCallback.sol";
import {SafeTransferLib} from "@midnight/libraries/SafeTransferLib.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";
import {CollateralTransferLib} from "../libraries/CollateralTransferLib.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";

/// @title BorrowMidnightRenewalCallback
/// @notice Callback that renews a borrower position from a source to the target Midnight market when that
/// market's SELL offer is taken.
/// @dev The offer's receiverIfMakerIsSeller (or receiverIfTakerIsSeller when the taker sells) must be this contract
/// so that sellerAssets are transferred here before onSell is called; onSell reverts with InvalidReceiver otherwise.
/// @dev Repays the source Midnight market debt with the sale proceeds (minus fee) and transfers collateral to the
/// target Midnight market pro-rata to the repaid debt, all of it on the final fill.
/// @dev The borrower must authorize this contract on Morpho Midnight (debt repayment and collateral transfer).
/// @dev The source and target markets must list the same collateral token set: only the loan token is checked
/// onchain, and collateral missing from the target is skipped and stays on the source, which can adversely affect
/// either LTV. Use a single collateral, or make the target collateral set a superset of the source's.
/// @dev Pre-existing positions on the target market are netted: the borrower can end up with collateral but no debt.
/// @dev On small partial fills, the pro-rata collateral transfer can round to zero even though debt is
/// migrated, temporarily increasing the target position's LTV until the position is fully migrated.
contract BorrowMidnightRenewalCallback is IBorrowMidnightRenewalCallback {
    using SafeERC20 for IERC20;
    using CollateralTransferLib for IMidnight;

    IMidnight public immutable MORPHO_MIDNIGHT;

    constructor(address morphoMidnight) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
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
        if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();  // MUTATION: rebased
        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
        if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();

        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        if (callbackData.sourceMarket.loanToken != market.loanToken) revert CallbackLib.TokenMismatch();

        uint256 fee = CallbackLib.sellerFeeFromTick(callbackData.tick, callbackData.feeRate, units, sellerAssets);

        if (fee > 0) {
            SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
        }
        uint256 repayBudget = sellerAssets - fee;
        bytes32 sourceMarketId = IdLib.toId(callbackData.sourceMarket);
        if (sourceMarketId == marketId) revert CallbackLib.SameMarket();
        uint256 sourceDebtBefore = MORPHO_MIDNIGHT.debt(sourceMarketId, seller);

        if (sourceDebtBefore == 0) revert CallbackLib.ZeroAmount();
        if (repayBudget > sourceDebtBefore) revert CallbackLib.ExcessRepayment();

        IERC20(market.loanToken).forceApprove(address(MORPHO_MIDNIGHT), repayBudget);
        MORPHO_MIDNIGHT.repay(callbackData.sourceMarket, repayBudget, seller, address(0), "");

        (address[] memory collateralTokens, uint256[] memory collateralAmounts) = MORPHO_MIDNIGHT.transferCollaterals(
            callbackData.sourceMarket, market, seller, sourceMarketId, sourceDebtBefore, repayBudget
        );

        emit BorrowRenewed(seller, sourceMarketId, marketId, repayBudget, collateralTokens, collateralAmounts, fee);

        return CALLBACK_SUCCESS;
    }
}
