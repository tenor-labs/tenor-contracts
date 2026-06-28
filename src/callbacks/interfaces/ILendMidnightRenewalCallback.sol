// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {Market} from "@midnight/interfaces/IMidnight.sol";
import {IBuyCallback} from "@midnight/interfaces/ICallbacks.sol";

/// @title ILendMidnightRenewalCallback
/// @notice Interface of the callback that renews lender positions between Morpho Midnight markets.
interface ILendMidnightRenewalCallback is IBuyCallback {
    /// @notice Data encoded in the offer's callbackData.
    /// @dev The source market must not be the target market: withdrawing from and lending into the same
    /// market can lead to unexpected accounting behavior.
    /// @param sourceMarket The Midnight market to withdraw from (where the lender has credit).
    /// @param feeRate The share of interest taken as fee, in WAD (e.g. 0.01e18 = 1%), denominated in loan token assets.
    /// @param feeRecipient The address receiving the fee; address(0) does not disable the fee, only feeRate == 0 does.
    /// @param tick Must be set exactly equal to offer.tick; the callback does not enforce this equality. A mismatch
    /// mis-scales the fill and may revert or settle on unintended terms.
    struct CallbackData {
        Market sourceMarket;
        uint256 feeRate;
        address feeRecipient;
        uint256 tick;
    }

    event LendRenewed(
        address indexed lender,
        bytes32 indexed sourceMarketId,
        bytes32 indexed targetMarketId,
        uint256 assets,
        uint256 fee
    );
}
