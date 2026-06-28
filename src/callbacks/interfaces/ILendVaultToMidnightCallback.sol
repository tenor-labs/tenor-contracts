// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {IBuyCallback} from "@midnight/interfaces/ICallbacks.sol";

/// @title ILendVaultToMidnightCallback
/// @notice Interface of the callback that redeems ERC-4626 vault shares to fund lender BUY offers.
/// @dev Withdraws from the vault to fund a lender's BUY offer on Midnight when the offer is filled.
interface ILendVaultToMidnightCallback is IBuyCallback {
    /// @notice Data encoded in the offer's callbackData.
    /// @param vault The ERC-4626 vault to withdraw from.
    /// @param feeRate The share of the interest taken as fee, in WAD (e.g. 0.01e18 = 1% of the interest; WAD = 100%).
    /// @param feeRecipient The address receiving the fee; address(0) does not disable the fee, only feeRate == 0 does.
    /// @param tick Must be set exactly equal to offer.tick; the callback does not enforce this equality. A mismatch
    /// mis-scales the fill and may revert or settle on unintended terms.
    /// @param morphoBlueMarketId The Morpho Blue market id, used for indexing only.
    struct CallbackData {
        address vault;
        uint256 feeRate;
        address feeRecipient;
        uint256 tick;
        bytes32 morphoBlueMarketId;
    }

    event VaultWithdrawn(
        address indexed lender,
        bytes32 indexed targetMarketId,
        address indexed vault,
        uint256 assets,
        uint256 sharesBurned,
        uint256 fee
    );
}
