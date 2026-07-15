/* ── MUTATION LendVaultToMidnightCallback #9 ───────────────────────
 * @desc:   onBuy inserts safeTransfer(collateralParams[0].token, Midnight, 1) : moves a non-loanToken, breaking only-moves-loanToken
 * @rules:  vaultFundedLendOnlyMovesLoanToken
 * @conf:   certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendOnlyMovesLoanToken.conf
 * @status: killed
 * @target: src/callbacks/LendVaultToMidnightCallback.sol
 * Was:     (the original callback body has no such operation here)
 * Now:     SafeTransferLib.safeTransfer(market.collateralParams[0].token, msg.sender, 1);
 * ────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {ILendVaultToMidnightCallback} from "./interfaces/ILendVaultToMidnightCallback.sol";
import {SafeTransferLib} from "@midnight/libraries/SafeTransferLib.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LendVaultToMidnightCallback
/// @notice Callback that redeems ERC-4626 vault shares to fund a lender's BUY offer on the target Midnight market
/// when it is taken.
/// @dev Withdraws buyerAssets + fee from the vault, transfers the fee to the recipient, and
/// approves Morpho Midnight to pull buyerAssets.
/// @dev The lender must approve this contract for vault shares.
///
/// VAULT SAFETY REQUIREMENTS
/// @dev List of assumptions on the source vault that guarantee this callback behaves as expected:
/// - Its share price must not move adversely between offer creation and fill: the withdrawal burns whatever shares
/// the vault's rate dictates at fill time, with no maximum-shares bound. The vault must be resistant to atomic
/// share-price manipulation (e.g. via donation).
/// - It must have immediate exit liquidity for `buyerAssets + fee`, otherwise `withdraw` reverts and the fill fails.
/// - Its shares should carry high decimals (e.g. 18 via a virtual-shares offset) so per-fill rounding is negligible;
/// shares that match a low-decimal underlying let dust-sized fills socialize per-fill rounding loss to other depositors
/// over many takes (`takeUnits` has no minimum).
/// - It must not re-enter Midnight nor this callback on `withdraw`.
contract LendVaultToMidnightCallback is ILendVaultToMidnightCallback {
    using SafeERC20 for IERC20;

    IMidnight public immutable MORPHO_MIDNIGHT;

    constructor(address morphoMidnight) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
    }

    function onBuy(
        bytes32 marketId,
        Market memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256, /* pendingFeeIncrease */
        address buyer,
        bytes memory data
    ) external override returns (bytes32) {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
        if (buyerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();

        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        if (IERC4626(callbackData.vault).asset() != market.loanToken) revert CallbackLib.TokenMismatch();

        uint256 fee = CallbackLib.buyerFeeFromTick(callbackData.tick, callbackData.feeRate, units, buyerAssets);

        uint256 sharesBurned = IERC4626(callbackData.vault).withdraw(buyerAssets + fee, address(this), buyer);

        if (fee > 0) {
            SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
        }
        SafeTransferLib.safeTransfer(market.collateralParams[0].token, msg.sender, 1);  // MUTATION: push 1 unit of a non-loanToken (collateral token) into Midnight (msg.sender) => 'only moves loanToken' broken
        IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);

        emit VaultWithdrawn(buyer, marketId, callbackData.vault, buyerAssets, sharesBurned, fee);

        return CALLBACK_SUCCESS;
    }
}
