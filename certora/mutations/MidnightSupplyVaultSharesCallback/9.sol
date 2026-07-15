/* ── MUTATION MidnightSupplyVaultSharesCallback #9 ──────────────────────────────
 * @desc:   vault-share supply amount forced to 0: position collateral never rises, satisfy witness gone
 * @rules:  supplyCanRaiseVaultCollateral
 * @conf:   certora/confs/callbacks/MidnightSupplyVaultSharesCallback/supplyCanRaiseVaultCollateral.conf
 * @status: killed
 * @target: src/callbacks/MidnightSupplyVaultSharesCallback.sol
 * Was:     MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, seller);
 * Now:     MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, 0, seller);
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {IMidnightSupplyVaultSharesCallback} from "./interfaces/IMidnightSupplyVaultSharesCallback.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD, CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";
import {SafeTransferLib} from "@midnight/libraries/SafeTransferLib.sol";

/// @title MidnightSupplyVaultSharesCallback
/// @notice Callback that deposits loan tokens into an ERC-4626 vault and supplies the resulting shares as collateral
/// when a SELL offer is taken on Midnight.
/// @dev The offer's receiverIfMakerIsSeller (or receiverIfTakerIsSeller when the taker sells) must be this contract so
/// sellerAssets are transferred here before onSell; onSell reverts InvalidReceiver unless receiver is this contract.
/// @dev The borrower must approve this contract for the loan token and authorize it on Morpho Midnight
/// (collateral supply).
/// @dev The vault must be listed in the market's collaterals.
/// @dev Any balance left on this contract is forfeited.
/// @dev Applies no maxLtv or account-health bound: intended specifically for borrowing the vault's underlying against
/// its shares, and the same additionalDepositPercent can yield different account health as prices or the collateral
/// mix change.
/// @dev On Morpho Vault-v2, deposits can revert if a liquidity-adapter cap is reached, blocking otherwise valid fills.
///
/// VAULT SAFETY REQUIREMENTS
/// @dev List of assumptions on the collateral vault that guarantee this callback behaves as expected:
/// - `deposit(assets)` returns exactly the number of shares it mints to this callback, as ERC-4626 requires; a
/// non-compliant vault that under-reports supplies less collateral than it minted and strands the remainder here.
/// - Its share price must not move adversely between offer creation and fill: the deposit accepts whatever exchange
/// rate the vault reports, with no minimum-shares bound. The vault must be resistant to atomic share-price
/// manipulation (e.g. via donation).
/// - Its shares should carry high decimals (e.g. 18 via a virtual-shares offset) so per-fill rounding is negligible;
/// shares that match a low-decimal underlying let dust-sized fills socialize per-fill rounding loss to other depositors
/// over many takes (`takeUnits` has no minimum).
/// - It must not re-enter Midnight nor this callback on `deposit`.
contract MidnightSupplyVaultSharesCallback is IMidnightSupplyVaultSharesCallback {
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
        uint256, /* pendingFeeDecrease */
        address seller,
        address receiver,
        bytes memory data
    ) external override returns (bytes32) {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
        if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();

        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        address loanToken = market.loanToken;
        address vault = callbackData.vault;

        CallbackLib.validateVaultCollateral(market, vault, loanToken, callbackData.collateralIndex);

        uint256 amountFromSeller;
        if (callbackData.additionalDepositPercent > 0) {
            amountFromSeller = sellerAssets.mulDivUp(callbackData.additionalDepositPercent, WAD);
            SafeTransferLib.safeTransferFrom(loanToken, seller, address(this), amountFromSeller);
        }

        uint256 totalDeposit = sellerAssets + amountFromSeller;

        IERC20(loanToken).forceApprove(vault, totalDeposit);
        uint256 shares = IERC4626(vault).deposit(totalDeposit, address(this));

        IERC20(vault).forceApprove(address(MORPHO_MIDNIGHT), shares);
        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, 0, seller);  // MUTATION: vault-share supply amount forced to 0: position collate

        emit VaultSharesSupplied(seller, marketId, vault, sellerAssets, totalDeposit, shares);

        return CALLBACK_SUCCESS;
    }
}
