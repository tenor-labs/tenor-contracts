// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ITakeClamp} from "../interfaces/ITakeClamp.sol";
import {IMidnight, Offer} from "@midnight/interfaces/IMidnight.sol";
import {TakeMathLib} from "../../libraries/TakeMathLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";

/// @title BuyOfferClamp
/// @notice Clamp that bounds takeUnits for BUY offers (buy == true, the maker is the buyer/lender).
/// @dev Bounds units by the buyer's loan token balance and allowance.
/// @dev Assumes offer.callback == address(0) (no callback); Morpho Midnight pulls the buyer's loan tokens directly.
/// @dev When the offer is reduceOnly, units are also capped to the buyer's current debt to prevent crossing to credit.
/// @dev The taker (seller/borrower) is responsible for constraining on their own health and debt.
/// @dev Offer consumption is checked structurally by TenorRouter.
contract BuyOfferClamp is ITakeClamp {
    /// @notice The Morpho Midnight protocol contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    /// @notice Data decoded from clampData.
    struct BuyOfferClampData {
        bytes32 marketId; // Pre-computed market ID
        address taker; // The taker address; unused by this clamp
    }

    constructor(IMidnight morphoMidnight) {
        MORPHO_MIDNIGHT = morphoMidnight;
    }

    /// @inheritdoc ITakeClamp
    function maxUnits(Offer calldata offer, bytes calldata clampData)
        external
        view
        override
        returns (uint256 maxUnits)
    {
        BuyOfferClampData memory data = abi.decode(clampData, (BuyOfferClampData));

        uint256 available = TakeMathLib.available(offer.market.loanToken, offer.maker, address(MORPHO_MIDNIGHT));
        if (available == 0) return 0;

        // Forward: buyerAssets = units.mulDivDown(buyerPrice, WAD).
        // Tight inverse: largest units such that forward(units) <= available.
        uint256 buyerPrice = TickLib.tickToPrice(offer.tick); // For BUY offers, buyerPrice = offerPrice.
        if (buyerPrice > 0) {
            maxUnits = TakeMathLib.mulDivDownInverse(available, WAD, buyerPrice);
        } else {
            maxUnits = type(uint128).max; // tick == 0 means free units.
        }

        maxUnits = TakeMathLib.capReduceOnly(MORPHO_MIDNIGHT, data.marketId, offer, maxUnits);
    }
}
