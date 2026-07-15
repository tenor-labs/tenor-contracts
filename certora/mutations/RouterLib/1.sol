/* ── MUTATION RouterLib #1 ──────────────────────────────
 * @desc:   net-seller min -> max : breaks fee-monotone-decreasing
 * @rules:  netSellerPriceMonotoneInFee
 * @conf:   certora/confs/ratifier/unit.conf
 * @status: killed
 * @target: src/libraries/RouterLib.sol
 * Was:     return midnightPrice < tenorPrice ? midnightPrice : tenorPrice;
 * Now:     return midnightPrice > tenorPrice ? midnightPrice : tenorPrice;
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {IMidnight, Offer} from "@midnight/interfaces/IMidnight.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {CallbackLib} from "./CallbackLib.sol";
import {TakeMathLib} from "./TakeMathLib.sol";

/// @title RouterLib
/// @notice Fill-sizing helpers shared by TenorRouter and ICallbackFeeAdjuster implementations.
/// @dev budgetToUnits inverts a remaining fill budget in a given dimension to the maximum market units.
/// @dev netBuyerPrice and netSellerPrice compose Midnight's forward price with Tenor's effective price to get the
/// per-unit price the taker actually pays (buyer) or receives (seller) after both onchain fees.
library RouterLib {
    uint8 internal constant FILL_BUYER_ASSETS = 0;
    uint8 internal constant FILL_SELLER_ASSETS = 1;
    uint8 internal constant FILL_UNITS = 2;

    /// @dev Returns the maximum market units for a remaining fill budget in a given dimension such that the budget
    /// is not overshot when run through Midnight's forward rounding.
    function budgetToUnits(
        IMidnight morphoMidnight,
        bytes32 marketId,
        Offer calldata offer,
        uint8 fillIndex,
        uint256 remainingBudget
    ) internal view returns (uint256) {
        if (remainingBudget == 0) return 0;
        if (fillIndex == FILL_UNITS) return remainingBudget;

        // Per-unit price mapping units to the budget's asset dimension (buyer or seller assets).
        uint256 price = fillIndex == FILL_BUYER_ASSETS
            ? TakeMathLib.buyerPrice(morphoMidnight, marketId, offer)
            : TakeMathLib.sellerPrice(morphoMidnight, marketId, offer);
        // price == 0 ⇒ the fill costs nothing in this dimension ⇒ budget is not binding; cap downstream.
        if (price == 0) return type(uint128).max;

        uint256 units = offer.buy
            ? TakeMathLib.mulDivDownInverse(remainingBudget, WAD, price)
            : TakeMathLib.mulDivUpInverse(remainingBudget, WAD, price);
        return UtilsLib.min(units, type(uint128).max);
    }

    /// @dev Returns the net per-unit price the buyer-as-taker pays onchain, used to invert remainingBudget to
    /// maxUnits under the interest fee formula.
    /// @dev Returns the max of Midnight's price (offerPrice + settlementFee) and buyerEffectivePrice. The callback
    /// fee is zero-floored against Midnight's fee in CallbackLib, so the max is the price the buyer actually pays
    /// and dividing remainingBudget by it cannot overshoot the budget.
    /// @param offerPrice The offer price (TickLib.tickToPrice(offer.tick)).
    /// @param settlementFee Midnight's per-market settlement fee for the time-to-maturity.
    /// @param feeRate The callback fee rate, in WAD (0 = no fee, returns Midnight's price alone).
    function netBuyerPrice(uint256 offerPrice, uint256 settlementFee, uint256 feeRate) internal pure returns (uint256) {
        uint256 midnightPrice = offerPrice + settlementFee;
        if (feeRate == 0) return midnightPrice;
        uint256 tenorPrice = CallbackLib.buyerEffectivePrice(offerPrice, feeRate);
        return midnightPrice > tenorPrice ? midnightPrice : tenorPrice;
    }

    /// @dev Returns the net per-unit price the seller-as-taker receives onchain, used to invert remainingBudget to
    /// maxUnits under the interest fee formula.
    /// @dev Returns the min of Midnight's price (offerPrice - settlementFee, zero-floored) and sellerEffectivePrice.
    /// The callback fee is zero-floored against Midnight's fee in CallbackLib, so the min is the price the seller
    /// actually receives and any larger units count would push the receipt past remainingBudget.
    /// @param offerPrice The offer price (TickLib.tickToPrice(offer.tick)).
    /// @param settlementFee Midnight's per-market settlement fee for the time-to-maturity.
    /// @param feeRate The callback fee rate, in WAD (0 = no fee, returns Midnight's price alone).
    function netSellerPrice(uint256 offerPrice, uint256 settlementFee, uint256 feeRate)
        internal
        pure
        returns (uint256)
    {
        uint256 midnightPrice = offerPrice > settlementFee ? offerPrice - settlementFee : 0;
        if (feeRate == 0) return midnightPrice;
        uint256 tenorPrice = CallbackLib.sellerEffectivePrice(offerPrice, feeRate);
        return midnightPrice > tenorPrice ? midnightPrice : tenorPrice;  // MUTATION: rebased
    }
}
