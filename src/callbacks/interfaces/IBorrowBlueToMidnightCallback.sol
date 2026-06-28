// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {MarketParams} from "@morphoBlue/interfaces/IMorpho.sol";
import {ISellCallback} from "@midnight/interfaces/ICallbacks.sol";

/// @title IBorrowBlueToMidnightCallback
/// @notice Interface of the callback that migrates borrower positions from Morpho Blue to Morpho Midnight.
interface IBorrowBlueToMidnightCallback is ISellCallback {
    /// @notice Data encoded in the offer's callbackData.
    /// @param sourceMarketParams The Morpho Blue market to exit.
    /// @param feeRate Fee rate on the interest, in WAD.
    /// @param feeRecipient The address receiving the fee; address(0) does not disable the fee, only feeRate == 0 does.
    /// @param tick Must be set exactly equal to offer.tick; the callback does not enforce this equality. A mismatch
    /// mis-scales the fill and may revert or settle on unintended terms.
    struct CallbackData {
        MarketParams sourceMarketParams;
        uint256 feeRate;
        address feeRecipient;
        uint256 tick;
    }

    event BorrowMigratedBlueToMidnight(
        address indexed borrower,
        bytes32 indexed sourceBlueMarketId,
        bytes32 indexed targetMarketId,
        uint256 debtRepaid,
        uint256 debtUnits,
        address collateralToken,
        uint256 collateralMigrated,
        uint256 fee
    );
}
