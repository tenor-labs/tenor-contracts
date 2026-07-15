/* ── MUTATION MidnightWithdrawVaultSharesCallback #2 ──────────────────────────────
 * @desc:   leave 1 wei allowance to Midnight (approve buyerAssets+1)
 * @rules:  callbackHoldsZeroAllowance
 * @conf:   certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/callbackHoldsZeroAllowance.conf
 * @status: killed
 * @target: src/callbacks/MidnightWithdrawVaultSharesCallback.sol
 * Was:     IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);
 * Now:     IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets + 1);
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {IMidnightWithdrawVaultSharesCallback} from "./interfaces/IMidnightWithdrawVaultSharesCallback.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MidnightWithdrawVaultSharesCallback
/// @notice Callback that withdraws vault share collateral and redeems it to fund a borrower's BUY offer on Midnight.
/// @dev The buyer must authorize this contract on Morpho Midnight to withdraw collateral on their behalf.
/// @dev Only the shares needed to cover buyerAssets are withdrawn; the remaining collateral stays on Midnight.
/// @dev Intended for reduceOnly offers: it does not check whether the fill crosses the buyer from debt into credit.
///
/// VAULT SAFETY REQUIREMENTS
/// @dev List of assumptions on the collateral vault that guarantee this callback behaves as expected:
/// - `withdraw(assets)` burns exactly `previewWithdraw(assets)` shares when both run in the same transaction. ERC-4626
/// only requires `withdraw` to burn no more shares than `previewWithdraw`, so a vault that accrues interest lazily
/// returns a stale, inflated preview and the surplus shares pulled from the buyer's collateral are stranded here.
/// - It must have immediate exit liquidity for `buyerAssets`, otherwise `withdraw` reverts and the fill fails.
/// - Its share price must not move adversely between offer creation and fill: the withdrawal settles at whatever
/// exchange rate the vault reports at execution time, with no maximum-shares bound. The vault must be resistant to
/// atomic share-price manipulation (e.g. via donation).
/// - Its shares should carry high decimals (e.g. 18 via a virtual-shares offset) so per-fill rounding is negligible;
/// shares that match a low-decimal underlying let dust-sized fills socialize per-fill rounding loss to other depositors
/// over many takes (`takeUnits` has no minimum).
/// - It must not re-enter Midnight nor this callback on `previewWithdraw` nor `withdraw`.
contract MidnightWithdrawVaultSharesCallback is IMidnightWithdrawVaultSharesCallback {
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
        uint256,
        address buyer,
        bytes memory data
    ) external override returns (bytes32) {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
        if (buyerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();

        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        CallbackLib.validateVaultCollateral(market, callbackData.vault, market.loanToken, callbackData.collateralIndex);

        uint256 sharesToWithdraw = IERC4626(callbackData.vault).previewWithdraw(buyerAssets);

        MORPHO_MIDNIGHT.withdrawCollateral(market, callbackData.collateralIndex, sharesToWithdraw, buyer, address(this));

        IERC4626(callbackData.vault).withdraw(buyerAssets, address(this), address(this));

        IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets + 1);  // MUTATION: leave 1 wei allowance to Midnight (approve buyerAssets+

        emit VaultSharesWithdrawn(buyer, marketId, callbackData.vault, buyerAssets, sharesToWithdraw);

        return CALLBACK_SUCCESS;
    }
}
