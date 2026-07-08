// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ICallbackFeeAdjuster} from "./interfaces/ICallbackFeeAdjuster.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";
import {RouterLib} from "../libraries/RouterLib.sol";
import {IMidnight, Offer} from "@midnight/interfaces/IMidnight.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";

/// @title CallbackFeeAdjuster
/// @notice Default `ICallbackFeeAdjuster` implementation that mirrors Tenor's callback fee math.
/// @dev Two fee formulas are supported via `FeeFormula`: INTEREST is the effective-price fee from `CallbackLib`
/// (tick + feeRate), and PERCENTAGE is the flat `CallbackLib.percentageFee(initiatorAssets, feeRate)`.
/// @dev The callback fee always lands on the initiator's (taker) asset side, so it falls on `!offer.buy`.
/// `beforeDispatch` learns that side from `fillIndex`; `afterDispatch` learns it from the `initiatorIsBuyer` flag.
/// @dev `afterDispatch` reports the fee on the initiator's side; the router books it in the initiator-worsening
/// direction (`buyerAssets += fee` or `sellerAssets -= fee`), tightening fill/slippage accounting only.
/// @dev The FeeFormula and feeRate in feeAdjusterData are caller-supplied and not checked against the offer's actual
/// callback; mislabeled metadata under-reports fees against the batch's fill limits.
contract CallbackFeeAdjuster is ICallbackFeeAdjuster {
    using UtilsLib for uint256;

    /// @notice Supported fee formulas.
    enum FeeFormula {
        INTEREST,
        PERCENTAGE
    }

    /* IMMUTABLES */

    IMidnight public immutable MORPHO_MIDNIGHT;

    /* CONSTRUCTOR */

    constructor(address morphoMidnight) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
    }

    /* EXTERNAL */

    /// @inheritdoc ICallbackFeeAdjuster
    /// @dev Always returns a units cap the router's `_capTakeUnits` uses directly, with no asset-to-unit conversion.
    /// @dev `fillIndex` already encodes the initiator's side (the router resolves `FillAxis.ASSETS` to its
    /// `BUYER_ASSETS`/`SELLER_ASSETS`), and the callback fee always lands on that side, so the fee-aware inversion runs
    /// for any asset axis.
    /// @dev On the units axis (no asset-side fee to size against) or when `feeRate == 0` this delegates to
    /// `RouterLib.budgetToUnits`' tight inversion.
    function beforeDispatch(Offer calldata offer, uint8 fillIndex, uint256 remainingBudget, bytes calldata data)
        external
        view
        override
        returns (uint256 takeUnits)
    {
        if (remainingBudget == 0) return 0;
        if (fillIndex == RouterLib.FILL_UNITS) return remainingBudget;

        (uint256 feeRate, FeeFormula formula) = abi.decode(data, (uint256, FeeFormula));

        if (feeRate == 0) {
            bytes32 marketId = IdLib.toId(offer.market);
            return RouterLib.budgetToUnits(MORPHO_MIDNIGHT, marketId, offer, fillIndex, remainingBudget);
        }

        if (formula == FeeFormula.INTEREST) {
            return _maxUnitsInterest(offer, fillIndex, remainingBudget, feeRate);
        }
        return _maxUnitsPercentage(offer, fillIndex, remainingBudget, feeRate);
    }

    /// @inheritdoc ICallbackFeeAdjuster
    function afterDispatch(
        Offer calldata offer,
        bool initiatorIsBuyer,
        uint256 buyerAssets,
        uint256 sellerAssets,
        uint256 units,
        bytes calldata data
    ) external pure override returns (uint256 feeAmount) {
        (uint256 feeRate, FeeFormula formula) = abi.decode(data, (uint256, FeeFormula));

        if (formula == FeeFormula.INTEREST) {
            if (initiatorIsBuyer) {
                return CallbackLib.buyerFeeFromTick(offer.tick, feeRate, units, buyerAssets);
            }
            return CallbackLib.sellerFeeFromTick(offer.tick, feeRate, units, sellerAssets);
        }

        uint256 initiatorAssets = initiatorIsBuyer ? buyerAssets : sellerAssets;
        return CallbackLib.percentageFee(initiatorAssets, feeRate);
    }

    /* INTERNAL */

    /// @dev Inversion for the INTEREST (effective-price) formula, delegating the net-price composition to
    /// `RouterLib.netBuyerPrice`/`netSellerPrice`.
    function _maxUnitsInterest(Offer calldata offer, uint8 fillIndex, uint256 remainingBudget, uint256 feeRate)
        internal
        view
        returns (uint256)
    {
        uint256 offerPrice = TickLib.tickToPrice(offer.tick);
        bytes32 marketId = IdLib.toId(offer.market);
        uint256 secondsToMaturity = UtilsLib.zeroFloorSub(offer.market.maturity, block.timestamp);
        uint256 settlementFee = MORPHO_MIDNIGHT.settlementFee(marketId, secondsToMaturity);

        // settlementFee falls on the taker only: applied iff the initiator's side (fillIndex) is opposite the maker's.
        uint256 settlementFeeUsed = (fillIndex == RouterLib.FILL_BUYER_ASSETS) != offer.buy ? settlementFee : 0;
        uint256 price = fillIndex == RouterLib.FILL_BUYER_ASSETS
            ? RouterLib.netBuyerPrice(offerPrice, settlementFeeUsed, feeRate)
            : RouterLib.netSellerPrice(offerPrice, settlementFeeUsed, feeRate);
        // Zero net price: budget never binds (take all), except a taker-seller receiving nothing (take none).
        if (price == 0) {
            return (fillIndex == RouterLib.FILL_SELLER_ASSETS && offer.buy) ? 0 : type(uint128).max;
        }
        return remainingBudget.mulDivDown(WAD, price);
    }

    /// @dev Inversion for the PERCENTAGE formula.
    /// @dev fee = takerAssets * feeRate / WAD (rounded down).
    /// @dev effective_takerAssets = raw_takerAssets ± floor(raw * feeRate / WAD).
    /// @dev This is composed with Midnight's forward price by using an inflated/deflated price.
    function _maxUnitsPercentage(Offer calldata offer, uint8 fillIndex, uint256 remainingBudget, uint256 feeRate)
        internal
        view
        returns (uint256)
    {
        uint256 offerPrice = TickLib.tickToPrice(offer.tick);
        bytes32 marketId = IdLib.toId(offer.market);
        uint256 secondsToMaturity = UtilsLib.zeroFloorSub(offer.market.maturity, block.timestamp);
        uint256 settlementFee = MORPHO_MIDNIGHT.settlementFee(marketId, secondsToMaturity);

        // settlementFee falls on the taker only: applied iff the initiator's side (fillIndex) is opposite the maker's.
        uint256 settlementFeeUsed = (fillIndex == RouterLib.FILL_BUYER_ASSETS) != offer.buy ? settlementFee : 0;

        if (fillIndex == RouterLib.FILL_BUYER_ASSETS) {
            // raw + floor(raw*feeRate/WAD) = floor(raw*(WAD+feeRate)/WAD) for integer raw, so the
            // tight bound is rawMax = max{r : floor(r*(WAD+feeRate)/WAD) <= R}.
            uint256 buyerPriceMidnight = offerPrice + settlementFeeUsed;
            if (buyerPriceMidnight == 0) return type(uint128).max;
            uint256 rawMax = (remainingBudget + 1).mulDivUp(WAD, WAD + feeRate) - 1;
            return rawMax.mulDivDown(WAD, buyerPriceMidnight);
        }

        // raw - floor(raw*feeRate/WAD) = ceil(raw*(WAD-feeRate)/WAD) for integer raw.
        // feeRate <= MAX_PERCENTAGE_FEE_RATE < WAD, so WAD - feeRate > 0.
        uint256 sellerPriceMidnight = UtilsLib.zeroFloorSub(offerPrice, settlementFeeUsed);
        if (sellerPriceMidnight == 0) return offer.buy ? 0 : type(uint128).max;
        uint256 rawMax = remainingBudget.mulDivDown(WAD, WAD - feeRate);
        // Seller receipt rounds down for BUY (taker), up for SELL (maker); invert each tightly so the cap can't
        // overshoot.
        if (offer.buy) {
            return (rawMax + 1).mulDivUp(WAD, sellerPriceMidnight) - 1;
        }
        return rawMax.mulDivDown(WAD, sellerPriceMidnight);
    }
}
