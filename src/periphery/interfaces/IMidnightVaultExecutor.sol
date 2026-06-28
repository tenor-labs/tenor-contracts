// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {Market} from "@midnight/interfaces/IMidnight.sol";

/// @title IMidnightVaultExecutor
/// @notice Interface of the executor that routes ERC-4626-vault-share collateral operations on Morpho Midnight.
/// @dev No per-share-price/slippage protection is enforced: operations settle at the vault's reported
/// share price. The caller is responsible for using a vault that protects against share price manipulation.
/// @dev Repay/liquidate go through Midnight directly with `callback = executor` (and `receiver = executor` for
/// liquidate); the `onRepay`/`onLiquidate` callbacks handle the collateral.
/// @dev Repay callback data is `abi.encode(collateralIndex, sharesToWithdraw)`; the liquidate data is unused (empty).
/// @dev The caller must be authorized to act for `onBehalf` on Midnight.
/// @dev `onLiquidate` reverts unless the liquidation's seized-collateral receiver is this executor; the redeem would
/// otherwise burn the executor's own resting vault shares.
interface IMidnightVaultExecutor {
    error Unauthorized();
    error InvalidInput();
    error LiquidationReceiverMismatch();
    error RepayExceedsRedeemed();

    /// @notice Deposits into the market's vault-share collateral and supplies the resulting shares for `onBehalf`.
    /// @dev Provide either `assets` (and `shares == 0`) or `shares` (and `assets == 0`), not both.
    /// @param market The target market.
    /// @param collateralIndex The index in `market.collateralParams` whose token is the ERC-4626 vault deposited into.
    /// @param assets The deposit amount in vault assets. Set to 0 if supplying `shares`.
    /// @param shares The target share output. Set to 0 if supplying `assets`.
    /// @param onBehalf The account credited with the collateral on Midnight.
    /// @return depositedShares The vault shares supplied as collateral.
    /// @return usedAssets The vault assets consumed by the deposit.
    function depositAndAddCollateral(
        Market calldata market,
        uint256 collateralIndex,
        uint256 assets,
        uint256 shares,
        address onBehalf
    ) external returns (uint256 depositedShares, uint256 usedAssets);

    /// @notice Withdraws vault-share collateral from Midnight and redeems it into vault assets for `receiver`.
    /// @param market The source market.
    /// @param collateralIndex The index in `market.collateralParams` whose token is the ERC-4626 vault redeemed from.
    /// @param shares The vault shares to withdraw and redeem.
    /// @param onBehalf The account whose collateral is withdrawn.
    /// @param receiver The address that receives the redeemed assets.
    /// @return assets The vault assets transferred to `receiver`.
    function withdrawCollateralAndRedeem(
        Market calldata market,
        uint256 collateralIndex,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assets);
}
