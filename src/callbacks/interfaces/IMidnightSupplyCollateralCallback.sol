// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {ISellCallback} from "@midnight/interfaces/ICallbacks.sol";

/// @title IMidnightSupplyCollateralCallback
/// @notice Interface of the callback that supplies collateral just in time when sell offers are filled.
interface IMidnightSupplyCollateralCallback is ISellCallback {
    /// @notice Data encoded in the offer's callbackData.
    /// @param amounts The collateral amounts to supply on a full fill, indexed by market collateral slot. Must match
    /// the market's collateralParams length; use 0 for slots with no deposit.
    /// @param offerSellerAssets Must be set exactly equal to offer.maxAssets; the callback does not enforce this
    /// equality. A mismatch mis-scales the fill and may revert or settle on unintended terms.
    /// @param maxBorrowCapacityUsage Cap on the borrower's debt as a fraction of its borrowing capacity after the
    /// supply, in WAD. Only meaningful in (0, WAD): 0 skips the check, and any value >= WAD never binds because
    /// Midnight itself enforces debt <= capacity at settlement.
    struct CallbackData {
        uint256[] amounts;
        uint256 offerSellerAssets;
        uint256 maxBorrowCapacityUsage;
    }

    event CollateralSupplied(address indexed borrower, bytes32 indexed marketId, uint256[] collateralAmounts);
}
