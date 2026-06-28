// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ITakeClamp} from "../interfaces/ITakeClamp.sol";
import {IMidnight, Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {TakeMathLib} from "../../libraries/TakeMathLib.sol";
import {MidnightLib} from "../../libraries/MidnightLib.sol";

/// @title SellOfferClamp
/// @notice Clamp that bounds takeUnits for SELL offers (buy == false, the maker is the seller/borrower).
/// @dev Bounds units by the seller's credit balance (resell path) and the seller's health (borrow path).
/// @dev The offer must have no callback (offer.callback == address(0)); the seller either resells existing credit or
/// borrows directly from Morpho Midnight.
/// @dev The seller must already have collateral deposited onchain for the borrow path; for callback-based collateral
/// supply, use SupplyCollateralCallbackClamp instead.
/// @dev Units are capped to the seller's credit balance plus their health headroom (maxDebt - currentDebt); for
/// reduceOnly offers, to the credit balance only.
/// @dev Assumes the taker (buyer/lender) has no existing debt on this market (buyerIsLender == true); it is the
/// caller's responsibility to ensure this or to constrain separately.
/// @dev Offer consumption is checked structurally by TenorRouter.
contract SellOfferClamp is ITakeClamp {
    using MidnightLib for IMidnight;

    /// @notice The Morpho Midnight protocol contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    /// @notice Data decoded from clampData.
    struct SellOfferClampData {
        bytes32 marketId; // Pre-computed market ID
        address taker; // The taker address (unused by this clamp)
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
        SellOfferClampData memory data = abi.decode(clampData, (SellOfferClampData));

        if (offer.reduceOnly) {
            return TakeMathLib.capReduceOnly(MORPHO_MIDNIGHT, data.marketId, offer, type(uint256).max);
        }

        // Credit and debt are mutually exclusive, so available = credit + (maxDebt - currentDebt).
        Market memory sellerMarket = MORPHO_MIDNIGHT.toMarket(data.marketId);
        (uint128 sellerCredit,,) = MORPHO_MIDNIGHT.updatePositionView(sellerMarket, data.marketId, offer.maker);
        uint256 maxDebt = MORPHO_MIDNIGHT.computeMaxDebt(data.marketId, offer.maker, offer.market.collateralParams);
        uint256 currentDebt = MORPHO_MIDNIGHT.debt(data.marketId, offer.maker);
        uint256 debtHeadroom = maxDebt > currentDebt ? maxDebt - currentDebt : 0;
        uint256 maxUnitsFromPosition = sellerCredit + debtHeadroom;

        return maxUnitsFromPosition;
    }
}
