// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {Market} from "@midnight/interfaces/IMidnight.sol";
import {ISellCallback} from "@midnight/interfaces/ICallbacks.sol";

/// @title IBorrowMidnightRenewalCallback
/// @notice Interface of the callback that renews borrower positions between Morpho Midnight markets.
interface IBorrowMidnightRenewalCallback is ISellCallback {
    /// @notice Data encoded in the offer's callbackData.
    /// @param sourceMarket The Midnight market to exit.
    /// @param feeRate The share of the interest taken as fee, in WAD (e.g. 0.01e18 = 1% of the interest).
    /// @param feeRecipient The address receiving the fee; address(0) does not disable the fee, only feeRate == 0 does.
    /// @param tick Must be set exactly equal to offer.tick; the callback does not enforce this equality. A mismatch
    /// mis-scales the fill and may revert or settle on unintended terms.
    struct CallbackData {
        Market sourceMarket;
        uint256 feeRate;
        address feeRecipient;
        uint256 tick;
    }

    event BorrowRenewed(
        address indexed borrower,
        bytes32 indexed sourceMarketId,
        bytes32 indexed targetMarketId,
        uint256 repaidAmount,
        address[] collateralsTransferred,
        uint256[] collateralAmounts,
        uint256 fee
    );
}
