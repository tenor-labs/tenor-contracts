// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {IBuyCallback} from "@midnight/interfaces/ICallbacks.sol";

/// @title IMidnightWithdrawVaultSharesCallback
/// @notice Interface of the callback that withdraws vault share collateral and redeems it to fund buy offers.
/// @dev Enables borrowers to repay debt using vault share collateral.
interface IMidnightWithdrawVaultSharesCallback is IBuyCallback {
    /// @notice Data encoded in the offer's callbackData.
    /// @param vault The ERC-4626 vault to redeem from (must be the collateral token).
    /// @param collateralIndex The index of the vault in the market's collateralParams array.
    struct CallbackData {
        address vault;
        uint256 collateralIndex;
    }

    event VaultSharesWithdrawn(
        address indexed borrower,
        bytes32 indexed marketId,
        address indexed vault,
        uint256 buyerAssets,
        uint256 sharesWithdrawn
    );
}
