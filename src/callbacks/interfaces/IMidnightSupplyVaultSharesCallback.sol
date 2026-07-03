// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {ISellCallback} from "@midnight/interfaces/ICallbacks.sol";

/// @title IMidnightSupplyVaultSharesCallback
/// @notice Interface of the callback that deposits loan tokens into a vault and supplies the shares as collateral.
/// @dev Deposits `sellerAssets` + `amountFromSeller` of loan tokens into the vault and supplies the shares as
/// collateral, where `amountFromSeller = ceil(sellerAssets * additionalDepositPercent / WAD)`.
interface IMidnightSupplyVaultSharesCallback is ISellCallback {
    /// @notice Data encoded in the offer's callbackData.
    /// @param vault The ERC-4626 vault to deposit into; must be listed in market.collateralParams.
    /// @param collateralIndex The index of the vault in the market's collateralParams array.
    /// @param additionalDepositPercent The extra share of sellerAssets the seller must provide, in WAD (e.g. 0.1e18 =
    /// 10% extra). Must be at least WAD^2 / (price * LLTV) - WAD, where price = tickToPrice(offer.tick), to keep the
    /// position healthy; the callback does not enforce this minimum.
    struct CallbackData {
        address vault;
        uint256 collateralIndex;
        uint256 additionalDepositPercent;
    }

    event VaultSharesSupplied(
        address indexed borrower,
        bytes32 indexed marketId,
        address indexed vault,
        uint256 sellerAssets,
        uint256 assetsDeposited,
        uint256 sharesSupplied
    );
}
