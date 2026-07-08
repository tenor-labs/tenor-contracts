// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ITakeClamp} from "../interfaces/ITakeClamp.sol";
import {IMidnight, Offer} from "@midnight/interfaces/IMidnight.sol";
import {TakeMathLib} from "../../libraries/TakeMathLib.sol";
import {IMorpho, Id, MarketParams} from "@morphoBlue/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morphoBlue/libraries/periphery/MorphoBalancesLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";

/// @title BorrowMidnightToBlueClamp
/// @notice Clamp that bounds takeUnits for Midnight to Morpho Blue borrow exits.
/// @dev Bounds units by the borrower's source debt and the Blue market's borrow capacity (fee-aware).
/// @dev The callback borrows (buyerAssets + percentageFee) from Blue, so Blue liquidity must cover both.
/// @dev Assumes the source and target markets have the same loan token, collateral token, LLTV, and oracle. Only
/// the loan and collateral tokens are checked onchain by the callback; LLTV and oracle compatibility are not enforced.
/// @dev feeRate in the clamp data must match the feeRate in the callback data.
/// @dev `positionOwner` is passed in clampData; for a ratified migration offer it equals `offer.maker`.
/// @dev This clamp does not check health: under the same-collateral assumption health is binary, and if the borrower is
/// healthy in source they will be healthy in target since collateral migrates pro-rata.
/// @dev The router's try/catch (fail-safe mode) handles edge cases.
/// @dev Offer consumption is checked structurally by TenorRouter.
contract BorrowMidnightToBlueClamp is ITakeClamp {
    using MorphoBalancesLib for IMorpho;
    using UtilsLib for uint256;

    /// @notice The Morpho Midnight protocol contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    /// @notice The Morpho Blue contract.
    IMorpho public immutable MORPHO_BLUE;

    /// @notice Data decoded from clampData.
    struct BorrowMidnightToBlueClampData {
        bytes32 sourceMarketId; // Source Midnight market ID
        bytes32 targetBlueMarketId; // Blue market ID
        address positionOwner; // Borrower whose position is migrated (= offer.maker)
        uint256 feeRate; // Fee rate from callback data, in WAD (0 = no fee).
    }

    constructor(IMidnight morphoMidnight, IMorpho morphoBlue) {
        MORPHO_MIDNIGHT = morphoMidnight;
        MORPHO_BLUE = morphoBlue;
    }

    /// @inheritdoc ITakeClamp
    function maxUnits(Offer calldata offer, bytes calldata clampData)
        external
        view
        override
        returns (uint256 maxUnits)
    {
        BorrowMidnightToBlueClampData memory data = abi.decode(clampData, (BorrowMidnightToBlueClampData));

        uint256 sourceDebt = MORPHO_MIDNIGHT.debt(data.sourceMarketId, data.positionOwner);
        if (sourceDebt == 0) return 0;

        MarketParams memory params = MORPHO_BLUE.idToMarketParams(Id.wrap(data.targetBlueMarketId));
        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = MORPHO_BLUE.expectedMarketBalances(params);

        uint256 availableLiquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
        if (availableLiquidity == 0) return 0;

        // The callback borrows (buyerAssets + fee) from Blue, where fee = floor(buyerAssets * feeRate / WAD).
        // Combined: floor(buyerAssets * (WAD + feeRate) / WAD) <= availableLiquidity.
        // Tight inverse: largest buyerAssets such that the above holds.
        uint256 effectiveBudget = TakeMathLib.mulDivDownInverse(availableLiquidity, WAD, WAD + data.feeRate);

        uint256 maxUnitsFromDebt = sourceDebt;

        // Direction-aware buyerPrice and rounding for the market constraint.
        uint256 bp = TakeMathLib.buyerPrice(MORPHO_MIDNIGHT, data.sourceMarketId, offer);
        uint256 maxUnitsFromMarket;
        if (offer.buy) {
            // BUY: buyerAssets = mulDivDown(units, bp, WAD).
            maxUnitsFromMarket = bp > 0 ? TakeMathLib.mulDivDownInverse(effectiveBudget, WAD, bp) : type(uint128).max;
        } else {
            // SELL: buyerAssets = mulDivUp(units, bp, WAD).
            maxUnitsFromMarket = bp > 0 ? effectiveBudget.mulDivDown(WAD, bp) : type(uint128).max;
        }

        maxUnits = UtilsLib.min(maxUnitsFromDebt, maxUnitsFromMarket);

        // reduceOnly is already implicitly capped by sourceDebt above, but made explicit for safety.
        return TakeMathLib.capReduceOnly(MORPHO_MIDNIGHT, data.sourceMarketId, offer, maxUnits);
    }
}
