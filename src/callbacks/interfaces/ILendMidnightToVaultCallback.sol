// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {ISellCallback} from "@midnight/interfaces/ICallbacks.sol";

/// @title ILendMidnightToVaultCallback
/// @notice Interface of the callback that deposits lender exit proceeds into an ERC-4626 vault.
interface ILendMidnightToVaultCallback is ISellCallback {
    /// @notice Data encoded in the offer's callbackData.
    /// @param vault The ERC-4626 vault to deposit the proceeds into.
    /// @param feeRate The fee rate on sellerAssets, in WAD (at most MAX_PERCENTAGE_FEE_RATE = 0.01e18 = 1%).
    /// @param feeRecipient The address receiving the fee; address(0) does not disable the fee, only feeRate == 0 does.
    struct CallbackData {
        address vault;
        uint256 feeRate;
        address feeRecipient;
    }

    event VaultDeposited(
        address indexed lender,
        bytes32 indexed sourceMarketId,
        address indexed vault,
        uint256 assets,
        uint256 shares,
        uint256 fee
    );
}
