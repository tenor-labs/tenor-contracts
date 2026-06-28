// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {MarketParams} from "@morphoBlue/interfaces/IMorpho.sol";
import {IBuyCallback} from "@midnight/interfaces/ICallbacks.sol";

/// @title IBorrowMidnightToBlueCallback
/// @notice Interface of the callback that migrates borrower positions from Morpho Midnight to Morpho Blue.
interface IBorrowMidnightToBlueCallback is IBuyCallback {
    /// @notice Data encoded in the offer's callbackData.
    /// @param targetMarketParams The Morpho Blue market to migrate to; its collateralToken is the collateral migrated.
    /// @param feeRate The fee rate on buyerAssets, in WAD (at most MAX_PERCENTAGE_FEE_RATE = 0.01e18 = 1%).
    /// @param feeRecipient The address receiving the fee; address(0) does not disable the fee, only feeRate == 0 does.
    struct CallbackData {
        MarketParams targetMarketParams;
        uint256 feeRate;
        address feeRecipient;
    }

    event BorrowMigratedMidnightToBlue(
        address indexed borrower,
        bytes32 indexed sourceMarketId,
        bytes32 indexed targetBlueMarketId,
        uint256 debtRepaid,
        uint256 debtBorrowed,
        address collateralToken,
        uint256 collateralMigrated,
        uint256 fee
    );
}
