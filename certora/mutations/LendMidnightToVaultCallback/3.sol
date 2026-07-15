/* ── MUTATION LendMidnightToVaultCallback #3 ──────────────────────────────
 * @desc:   The vault-asset check is inverted so a vault whose asset differs from the market loan token is accepted instead of rejected, and the rule that requires such a mismatch to revert finds no revert, flipping its assertion to a counterexample.
 * @rules:  vaultAssetMismatchReverts
 * @conf:   certora/confs/callbacks/LendMidnightToVaultCallback/vaultAssetMismatchReverts.conf
 * @status: killed
 * @target: src/callbacks/LendMidnightToVaultCallback.sol
 * Was:     if (IERC4626(callbackData.vault).asset() != market.loanToken) revert CallbackLib.TokenMismatch();
 * Now:     if (IERC4626(callbackData.vault).asset() == market.loanToken) revert CallbackLib.TokenMismatch();
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {ILendMidnightToVaultCallback} from "./interfaces/ILendMidnightToVaultCallback.sol";
import {SafeTransferLib} from "@midnight/libraries/SafeTransferLib.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LendMidnightToVaultCallback
/// @notice Callback that deposits a lender's exit proceeds into an ERC-4626 vault when a Midnight SELL offer is taken.
/// @dev The offer's receiverIfMakerIsSeller (or receiverIfTakerIsSeller when the taker sells) must be this contract
/// so that sellerAssets are transferred here before onSell is called; onSell reverts with InvalidReceiver otherwise.
/// @dev Deposits sellerAssets minus a percentage fee into the vault on behalf of the lender.
/// @dev Reverts if the seller has debt on the market.
/// @dev On Morpho Vault-v2, deposits can revert if a liquidity-adapter cap is reached, blocking otherwise valid fills.
///
/// VAULT SAFETY REQUIREMENTS
/// @dev List of assumptions on the destination vault that guarantee this callback behaves as expected:
/// - Its share price must not move adversely between offer creation and fill: the deposit accepts whatever rate the
/// vault reports at fill time, with no minimum-shares bound. The vault must be resistant to atomic share-price
/// manipulation (e.g. via donation).
/// - Its shares should carry high decimals (e.g. 18 via a virtual-shares offset) so per-fill rounding is negligible;
/// shares that match a low-decimal underlying let dust-sized fills socialize per-fill rounding loss to other depositors
/// over many takes (`takeUnits` has no minimum).
/// - It must not re-enter Midnight nor this callback on `deposit`.
contract LendMidnightToVaultCallback is ILendMidnightToVaultCallback {
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
        uint256, /* pendingFeeDecrease */
        address seller,
        address receiver,
        bytes memory data
    ) external override returns (bytes32) {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
        if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();

        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        if (IERC4626(callbackData.vault).asset() == market.loanToken) revert CallbackLib.TokenMismatch();  // MUTATION: Flip token mismatch check from != to ==, accepting only

        if (MORPHO_MIDNIGHT.debt(marketId, seller) != 0) revert CallbackLib.PositionCrossing();

        uint256 fee;
        if (callbackData.feeRate > 0) {
            fee = CallbackLib.percentageFee(sellerAssets, callbackData.feeRate);
        }
        if (fee > 0) {
            SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
        }

        uint256 depositAmount = sellerAssets - fee;
        IERC20(market.loanToken).forceApprove(callbackData.vault, depositAmount);
        uint256 shares = IERC4626(callbackData.vault).deposit(depositAmount, seller);

        emit VaultDeposited(seller, marketId, callbackData.vault, depositAmount, shares, fee);

        return CALLBACK_SUCCESS;
    }
}
