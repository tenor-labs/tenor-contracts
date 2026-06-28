// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ITakeClamp} from "../interfaces/ITakeClamp.sol";
import {IMidnight, Offer, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {TakeMathLib} from "../../libraries/TakeMathLib.sol";
import {MidnightLib} from "../../libraries/MidnightLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {WAD, MAX_COLLATERALS_PER_BORROWER} from "@midnight/libraries/ConstantsLib.sol";

/// @title SupplyCollateralCallbackClamp
/// @notice Clamp that bounds takeUnits for SELL offers using MidnightSupplyCollateralCallback.
/// @dev Bounds units by pro-rata collateral token allowances and balances, seller health (existing plus
/// callback-supplied collateral), and the callback's maxBorrowCapacityUsage.
/// @dev Pro-rata collateral is seller-asset denominated (amounts[i] * sellerAssets / offerSellerAssets, mulDivDown).
/// The clamp decodes amounts/offerSellerAssets/maxBorrowCapacityUsage from the offer's CallbackData (what the callback
/// decodes), not from clampData.
/// @dev Assumes offer.buy == false (SELL offer); the maker is the seller/borrower.
/// @dev Returns 0 when the CallbackData fails to decode, its amounts length does not match the market collaterals,
/// or offerSellerAssets == 0, so the clamp never reverts (CLAMP-3) and never quotes a fill the callback would reject.
/// @dev The seller's existing collateral and debt are read onchain and factored into the health and
/// maxBorrowCapacityUsage headroom.
/// @dev The taker (buyer/lender) is responsible for constraining on their own health and debt.
/// @dev The debt-limit bound (health and maxBorrowCapacityUsage) is a linearized estimate, self-consistency-checked at
/// the post-take rounding; on overshoot it falls back to the monotone-safe existing-collateral headroom. Never
/// over-sizes.
/// @dev Limitation: the headroom fallback can under-quote substantially: it ignores the collateral this fill would
/// supply, down to 0 when existing collateral does not already cover the debt (e.g. a fresh seller). A tighter
/// maxBorrowCapacityUsage makes it more likely.
contract SupplyCollateralCallbackClamp is ITakeClamp {
    using UtilsLib for uint256;

    /// @notice The Morpho Midnight protocol contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    /// @notice Data decoded from clampData.
    /// @dev Assumes a SELL offer denominated in sellerAssets (offer.maxAssets > 0).
    struct ClampData {
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
        ClampData memory data = abi.decode(clampData, (ClampData));

        // sellerPrice == offerPrice for SELL offers (no settlement fee on the seller side; the fee is added to
        // buyerPrice, not subtracted from sellerPrice).
        uint256 sellerPrice = TickLib.tickToPrice(offer.tick);
        if (sellerPrice == 0) return 0; // Degenerate: sellerAssets == 0 for any units.

        CollateralParams[] memory oblCollaterals = offer.market.collateralParams;

        // Mirror the callback: decode amounts/offerSellerAssets/maxBorrowCapacityUsage from the offer's CallbackData.
        (bool ok, uint256[] memory amounts, uint256 offerSA, uint256 maxBorrowCapacityUsage) =
            _decodeCallbackData(offer.callbackData);
        if (!ok || amounts.length != oblCollaterals.length || offerSA == 0) return 0;

        // Load seller state once for the activation cap, health, and maxBorrowCapacityUsage constraints.
        uint256[] memory existingAmounts = new uint256[](oblCollaterals.length);
        uint256 bitmap = MORPHO_MIDNIGHT.collateralBitmap(data.marketId, offer.maker);
        uint256 activatedCount;
        for (uint256 i = 0; i < oblCollaterals.length; i++) {
            if (bitmap & (1 << i) != 0) {
                existingAmounts[i] = MORPHO_MIDNIGHT.collateral(data.marketId, offer.maker, i);
                activatedCount++;
            } else if (amounts[i] != 0) {
                activatedCount++;
            }
        }
        if (activatedCount > MAX_COLLATERALS_PER_BORROWER) return 0;

        uint256 maxUnitsFromCollateral = _maxUnitsFromCollateral(offer, amounts, offerSA, sellerPrice);

        uint256[] memory prices = new uint256[](oblCollaterals.length);
        uint256 currentDebt = MORPHO_MIDNIGHT.debt(data.marketId, offer.maker);

        uint256 maxUnitsFromHealth =
            _maxUnitsFromDebtLimit(offer, amounts, offerSA, prices, currentDebt, existingAmounts, sellerPrice, 0);

        uint256 maxUnitsFromBorrowCapacityUsage = maxBorrowCapacityUsage == 0
            ? type(uint256).max
            : _maxUnitsFromDebtLimit(
                offer, amounts, offerSA, prices, currentDebt, existingAmounts, sellerPrice, maxBorrowCapacityUsage
            );

        maxUnits = TakeMathLib.min(maxUnitsFromCollateral, maxUnitsFromHealth, maxUnitsFromBorrowCapacityUsage);

        return TakeMathLib.capReduceOnly(MORPHO_MIDNIGHT, data.marketId, offer, maxUnits);
    }

    /// @dev External strict decode used as a try-target so malformed bytes revert in isolation.
    function decodeCallbackData(bytes calldata callbackData)
        external
        pure
        returns (uint256[] memory amounts, uint256 offerSA, uint256 maxBorrowCapacityUsage)
    {
        IMidnightSupplyCollateralCallback.CallbackData memory cb =
            abi.decode(callbackData, (IMidnightSupplyCollateralCallback.CallbackData));
        return (cb.amounts, cb.offerSellerAssets, cb.maxBorrowCapacityUsage);
    }

    /// @dev Decodes the offer's CallbackData without reverting on malformed bytes (CLAMP-3); ok == false on failure.
    function _decodeCallbackData(bytes memory callbackData)
        internal
        view
        returns (bool ok, uint256[] memory amounts, uint256 offerSA, uint256 maxBorrowCapacityUsage)
    {
        try this.decodeCallbackData(callbackData) returns (uint256[] memory a, uint256 sa, uint256 usage) {
            return (true, a, sa, usage);
        } catch {
            return (false, amounts, 0, 0);
        }
    }

    /// @dev Finds max units from collateral balance/allowance constraints.
    function _maxUnitsFromCollateral(
        Offer calldata offer,
        uint256[] memory amounts,
        uint256 offerSA,
        uint256 sellerPrice
    ) internal view returns (uint256) {
        uint256 minUnits = type(uint256).max;
        CollateralParams[] memory oblCollaterals = offer.market.collateralParams;

        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] == 0) continue;

            uint256 available = TakeMathLib.available(oblCollaterals[i].token, offer.maker, offer.callback);

            // Max sellerAssets where floor(configAmount * sa / offerSA) <= available.
            uint256 maxSA = TakeMathLib.mulDivDownInverse(available, offerSA, amounts[i]);

            // Max units where ceil(units * sellerPrice / WAD) <= maxSA.
            uint256 maxUnitsForSlot = TakeMathLib.mulDivUpInverse(maxSA, WAD, sellerPrice);

            minUnits = UtilsLib.min(minUnits, maxUnitsForSlot);
        }

        return minUnits;
    }

    /// @dev Max units from a debt-limit constraint (health when maxBorrowCapacityUsage == 0, else the cap). The result
    /// must keep take(u) healthy for EVERY u in [0, result], since the router fills min(offerRemaining, clamp); any
    /// u <= result. limit(u) = _debtLimit(existing + callback-supplied(u)) is non-decreasing in u (the fill only adds
    /// collateral), so headroom = existingLimit - currentDebt is always safe and is the fallback when the linear
    /// estimate can't be verified.
    function _maxUnitsFromDebtLimit(
        Offer calldata offer,
        uint256[] memory amounts,
        uint256 offerSA,
        uint256[] memory prices,
        uint256 currentDebt,
        uint256[] memory existingAmounts,
        uint256 sellerPrice,
        uint256 maxBorrowCapacityUsage
    ) internal view returns (uint256) {
        CollateralParams[] memory oblCollaterals = offer.market.collateralParams;

        uint256 existingLimit = _debtLimit(oblCollaterals, existingAmounts, prices, maxBorrowCapacityUsage);
        // Already past the existing-collateral limit: a router-capped tiny fill adds negligible collateral yet still
        // raises debt, so no fill is universally safe.
        if (existingLimit < currentDebt) return 0;
        uint256 headroom = existingLimit - currentDebt;

        // equivalentOfferUnits = units at full fill = floor(offerSA * WAD / sellerPrice).
        uint256 callbackLimit = _debtLimit(oblCollaterals, amounts, prices, maxBorrowCapacityUsage);
        uint256 equivalentOfferUnits = offerSA.mulDivDown(WAD, sellerPrice);
        if (equivalentOfferUnits == 0) return type(uint128).max;
        // Callback collateral backs its own borrow at every fill size: the debt limit never binds, defer to capacity.
        if (callbackLimit >= equivalentOfferUnits) return type(uint256).max;

        // Linear estimate: the largest u where the linearized debt-limit slack is non-negative.
        uint256 maxUnits = headroom.mulDivDown(equivalentOfferUnits, equivalentOfferUnits - callbackLimit);

        // Verify the estimate at its own post-take rounding (sa = ceil(maxUnits * sellerPrice / WAD)); if it overshoots
        // its forward limit, fall back to the monotone-safe headroom.
        uint256 sa = maxUnits.mulDivUp(sellerPrice, WAD); // SELL forward.
        uint256[] memory postTakeAmounts = new uint256[](oblCollaterals.length);
        for (uint256 i = 0; i < oblCollaterals.length; i++) {
            postTakeAmounts[i] = existingAmounts[i];
            if (amounts[i] != 0) {
                postTakeAmounts[i] += amounts[i].mulDivDown(sa, offerSA);
            }
        }
        uint256 forwardLimit = _debtLimit(oblCollaterals, postTakeAmounts, prices, maxBorrowCapacityUsage);

        if (forwardLimit < currentDebt + maxUnits) {
            maxUnits = headroom;
        }

        return maxUnits;
    }

    /// @dev Computes the maximum debt that collateral amounts can support.
    function _debtLimit(
        CollateralParams[] memory collaterals,
        uint256[] memory amounts,
        uint256[] memory prices,
        uint256 maxBorrowCapacityUsage
    ) internal view returns (uint256) {
        uint256 capacity = MidnightLib.computeMaxDebtFromAmounts(collaterals, amounts, prices);
        if (maxBorrowCapacityUsage == 0) {
            return capacity;
        }
        return capacity.mulDivDown(maxBorrowCapacityUsage, WAD);
    }
}
