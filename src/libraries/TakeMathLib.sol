// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {IMidnight, Offer, Market} from "@midnight/interfaces/IMidnight.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {CallbackLib} from "./CallbackLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TakeMathLib
/// @notice Shared unit/price math for sizing Midnight `take`s.
/// @dev Sizers never revert: degenerate or non-binding constraints (zero price, overflow)
///      saturate to `uint128.max`; Midnight enforces take validity at take time.
library TakeMathLib {
    using UtilsLib for uint256;

    /// @dev Returns the offer's remaining fillable capacity in market units, reading consumption from Morpho Midnight.
    /// @dev offer.maxAssets is the maker-side cap: buyerAssets for BUY offers, sellerAssets for SELL offers.
    /// @dev For asset-denominated offers, computes the tight inverse of Midnight's forward rounding: BUY uses
    /// mulDivDownInverse (forward = mulDivDown, largest u where floor(u * p / WAD) <= R) and SELL uses
    /// mulDivUpInverse (forward = mulDivUp, largest u where ceil(u * p / WAD) <= R).
    /// @dev This guarantees the returned units never cause consumed to overshoot the offer's max.
    /// @dev A zero-priced asset cap does not bound unit exposure: the returned capacity is
    /// type(uint128).max even though offer.maxAssets is finite.
    /// @param marketId The pre-computed market ID (avoids a redundant toId call for asset-denominated offers).
    function getOfferRemaining(IMidnight morphoMidnight, Offer calldata offer, bytes32 marketId)
        internal
        view
        returns (uint256 remainingUnits)
    {
        uint256 consumedAmount = morphoMidnight.consumed(offer.maker, offer.group);

        if (offer.maxAssets == 0) {
            uint256 capacity = offer.maxUnits;
            return capacity > consumedAmount ? capacity - consumedAmount : 0;
        }

        uint256 remainingAssets = offer.maxAssets > consumedAmount ? offer.maxAssets - consumedAmount : 0;
        if (remainingAssets == 0) return 0;

        // BUY: maker is buyer, cap is in buyerAssets priced by buyerPrice, forward = mulDivDown.
        // SELL: maker is seller, cap is in sellerAssets priced by sellerPrice, forward = mulDivUp.
        uint256 price =
            offer.buy ? buyerPrice(morphoMidnight, marketId, offer) : sellerPrice(morphoMidnight, marketId, offer);
        if (price == 0) return type(uint128).max;
        uint256 units =
            offer.buy ? mulDivDownInverse(remainingAssets, WAD, price) : mulDivUpInverse(remainingAssets, WAD, price);
        return UtilsLib.min(units, type(uint128).max);
    }

    /// @dev Returns the fee-inclusive seller price for an offer: offerPrice - settlementFee (zero-floored) for BUY
    /// offers (seller is taker) and offerPrice for SELL offers (seller is maker).
    function sellerPrice(IMidnight morphoMidnight, bytes32 marketId, Offer calldata offer)
        internal
        view
        returns (uint256)
    {
        uint256 offerPrice = TickLib.tickToPrice(offer.tick);
        uint256 settlementFee =
            morphoMidnight.settlementFee(marketId, UtilsLib.zeroFloorSub(offer.market.maturity, block.timestamp));
        return offer.buy ? UtilsLib.zeroFloorSub(offerPrice, settlementFee) : offerPrice;
    }

    /// @dev Returns the fee-inclusive buyer price for an offer: offerPrice for BUY offers (buyer is maker) and
    /// offerPrice + settlementFee for SELL offers (buyer is taker).
    function buyerPrice(IMidnight morphoMidnight, bytes32 marketId, Offer calldata offer)
        internal
        view
        returns (uint256)
    {
        uint256 offerPrice = TickLib.tickToPrice(offer.tick);
        uint256 settlementFee =
            morphoMidnight.settlementFee(marketId, UtilsLib.zeroFloorSub(offer.market.maturity, block.timestamp));
        return offer.buy ? offerPrice : offerPrice + settlementFee;
    }

    /// @dev Returns the maximum units whose seller receipt does not exceed `assets`.
    /// @dev Tight inverse of Midnight's seller-receipt forward (buy => mulDivDown, sell => mulDivUp).
    function assetsToSellerUnits(IMidnight morphoMidnight, bytes32 marketId, Offer calldata offer, uint256 assets)
        internal
        view
        returns (uint256 units)
    {
        if (assets == 0) return 0;
        uint256 price = sellerPrice(morphoMidnight, marketId, offer);
        if (price == 0) return type(uint128).max;
        uint256 u = offer.buy ? mulDivDownInverse(assets, WAD, price) : mulDivUpInverse(assets, WAD, price);
        return UtilsLib.min(u, type(uint128).max);
    }

    /// @dev Returns the maximum units where the seller's net budget (sellerAssets - fee) <= maxBudget.
    /// @dev SELL offers: seller is maker, no settlement fee. BUY offers: seller is taker, settlement fee deducted.
    function maxUnitsForSellerBudget(
        IMidnight morphoMidnight,
        bytes32 marketId,
        Offer calldata offer,
        uint256 feeRate,
        uint256 maxBudget
    ) internal view returns (uint256) {
        if (maxBudget == 0) return 0;
        uint256 price = TickLib.tickToPrice(offer.tick);

        if (!offer.buy) {
            // SELL: seller is maker, no settlement fee on seller.
            if (feeRate == 0) {
                if (price == 0) return type(uint128).max;
                return maxBudget.mulDivDown(WAD, price);
            }
            uint256 effPrice = CallbackLib.sellerEffectivePrice(price, feeRate);
            if (effPrice == 0) return type(uint128).max;
            return mulDivUpInverse(maxBudget, WAD, effPrice);
        } else {
            // BUY: seller is taker. Bounding by sellerPrice keeps sellerAssets <= maxBudget; the Tenor fee comes out
            // of sellerAssets (not maxBudget), so the tighter effective-price bound would only underfill the sweep.
            uint256 sp = sellerPrice(morphoMidnight, marketId, offer);
            if (sp == 0) return type(uint128).max;
            return mulDivDownInverse(maxBudget, WAD, sp);
        }
    }

    /// @dev Returns the maximum units where the buyer's net budget (buyerAssets + fee) <= maxBudget.
    /// @dev BUY offers: buyer is maker, no settlement fee. SELL offers: buyer is taker, settlement fee added.
    /// @dev For SELL offers with feeRate > 0, takes the min of settlement-fee-adjusted and Tenor-fee-adjusted bounds.
    function maxUnitsForBuyerBudget(
        IMidnight morphoMidnight,
        bytes32 marketId,
        Offer calldata offer,
        uint256 feeRate,
        uint256 maxBudget
    ) internal view returns (uint256) {
        if (maxBudget == 0) return 0;
        uint256 price = TickLib.tickToPrice(offer.tick);

        if (offer.buy) {
            // BUY: buyer is maker, no settlement fee on buyer.
            if (feeRate == 0) {
                if (price == 0) return type(uint128).max;
                return mulDivDownInverse(maxBudget, WAD, price);
            }
            // price == 0 with feeRate == WAD would revert buyerEffectivePrice (x == WAD).
            // Short-circuit: zero price means buyer pays nothing per unit, capacity is uncapped.
            if (price == 0) return type(uint128).max;
            uint256 effPrice = CallbackLib.buyerEffectivePrice(price, feeRate);
            if (effPrice == 0) return type(uint128).max;
            return maxBudget.mulDivDown(WAD, effPrice);
        } else {
            // SELL: buyer is taker, settlement fee added to buyerPrice.
            uint256 bp = buyerPrice(morphoMidnight, marketId, offer);
            if (feeRate == 0) {
                if (bp == 0) return type(uint128).max;
                return maxBudget.mulDivDown(WAD, bp);
            }
            // Same degenerate guard: price == 0 && feeRate == WAD would revert buyerEffectivePrice.
            uint256 fromEffPrice;
            if (price == 0) {
                fromEffPrice = type(uint128).max;
            } else {
                uint256 effPrice = CallbackLib.buyerEffectivePrice(price, feeRate);
                fromEffPrice = effPrice == 0 ? type(uint128).max : maxBudget.mulDivDown(WAD, effPrice);
            }
            uint256 fromBp = bp == 0 ? type(uint128).max : maxBudget.mulDivDown(WAD, bp);
            return UtilsLib.min(fromEffPrice, fromBp);
        }
    }

    /// @dev Returns the largest x with x.mulDivDown(num, den) <= target, i.e. inverts floor(x * num / den) <= target.
    /// @dev Closed-form: x <= ((target + 1) * den - 1) / num.
    /// @dev When `num` is 0 every `x` satisfies the constraint, so there is no upper bound: return
    /// type(uint256).max instead of dividing by zero.
    function mulDivDownInverse(uint256 target, uint256 den, uint256 num) internal pure returns (uint256) {
        if (num == 0) return type(uint256).max;
        if (target == type(uint256).max) return type(uint256).max;
        uint256 n = target + 1;
        if (den > type(uint256).max / n) {
            return type(uint256).max;
        }
        return (n * den - 1) / num;
    }

    /// @dev Returns the largest x with x.mulDivUp(num, den) <= target, i.e. inverts ceil(x * num / den) <= target.
    /// @dev Since ceil(x * num / den) <= target is equivalent to x * num / den <= target for integer target, the
    /// answer is floor(target * den / num).
    /// @dev When `num` is 0 every `x` satisfies the constraint, so there is no upper bound: return
    /// type(uint256).max instead of dividing by zero.
    function mulDivUpInverse(uint256 target, uint256 den, uint256 num) internal pure returns (uint256) {
        if (num == 0) return type(uint256).max;
        if (target != 0 && den > type(uint256).max / target) {
            return type(uint256).max;
        }
        return target.mulDivDown(den, num);
    }

    /// @dev Returns the maximum amount of token that spender can pull from owner: min(balance, allowance), the
    /// common constraint for any ERC-20 transfer.
    function available(address token, address owner, address spender) internal view returns (uint256) {
        return UtilsLib.min(IERC20(token).balanceOf(owner), IERC20(token).allowance(owner, spender));
    }

    /// @dev Caps maxUnits by the maker's existing position when the offer is reduceOnly; no-op otherwise.
    /// @dev BUY offers: caps by the buyer's debt (prevents crossing to credit).
    /// @dev SELL offers: caps by the seller's credit (prevents crossing to debt).
    function capReduceOnly(IMidnight morphoMidnight, bytes32 marketId, Offer calldata offer, uint256 maxUnits)
        internal
        view
        returns (uint256)
    {
        if (!offer.reduceOnly) return maxUnits;
        uint256 positionCap;
        if (offer.buy) {
            positionCap = morphoMidnight.debt(marketId, offer.maker);
        } else {
            Market memory market = morphoMidnight.toMarket(marketId);
            (uint128 sellerCredit,,) = morphoMidnight.updatePositionView(market, marketId, offer.maker);
            positionCap = sellerCredit;
        }
        return UtilsLib.min(maxUnits, positionCap);
    }

    /// @dev Returns the minimum of three uint256 values.
    function min(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return UtilsLib.min(UtilsLib.min(a, b), c);
    }
}
