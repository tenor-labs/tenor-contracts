// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ITakeClamp} from "../interfaces/ITakeClamp.sol";
import {IMidnight, Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {TakeMathLib} from "../../libraries/TakeMathLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";

/// @title LendMidnightRenewalClamp
/// @notice Clamp that bounds takeUnits for Midnight to Midnight lend renewals via the withdrawable path (cross-market).
/// @dev Bounds units by the lender's source withdrawable position and withdrawal budget.
/// @dev Assumes the source and target markets are identical except for maturity (target maturity > source maturity):
/// same loanToken, same collaterals (tokens, oracles, LLTVs), same rcfThreshold.
/// @dev Assumes positionOwner, the lender, has credit on the source market.
/// @dev Source and target must be different markets; self-renewal is blocked.
/// @dev The offer's callback is a LendMidnightRenewalCallback that withdraws buyerAssets + fee from the source market.
/// @dev feeRate in the clamp data must match the feeRate in the callback data.
/// @dev `positionOwner` is passed in clampData; for a ratified migration offer it equals `offer.maker`.
/// @dev Offer consumption is checked structurally by TenorRouter.
/// @dev This clamp does not check health: under the same-collateral assumption health is binary, so if the renewal
/// fails for any amount it fails for all amounts.
/// @dev The router's try/catch (fail-safe mode) handles this; the offchain router filters offers that can't renew.
contract LendMidnightRenewalClamp is ITakeClamp {
    using UtilsLib for uint256;

    /// @notice The Morpho Midnight protocol contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    /// @notice Data decoded from clampData.
    struct LendMidnightRenewalClampData {
        bytes32 sourceMarketId; // Source lend market ID
        bytes32 targetMarketId; // Target lend market ID
        address positionOwner; // Lender whose position is migrated (= offer.maker)
        uint256 feeRate; // Fee rate from callback data, in WAD (0 = no fee).
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
        LendMidnightRenewalClampData memory data = abi.decode(clampData, (LendMidnightRenewalClampData));

        Market memory sourceMarket = MORPHO_MIDNIGHT.toMarket(data.sourceMarketId);
        (uint128 sourceCredit,,) =
            MORPHO_MIDNIGHT.updatePositionView(sourceMarket, data.sourceMarketId, data.positionOwner);
        if (sourceCredit == 0) return 0;

        // Self-renewal guard: source == target makes accounting circular.
        if (data.sourceMarketId == data.targetMarketId) return 0;

        // Cap by pool liquidity: lenders can only withdraw tokens that borrowers have repaid.
        // Without this cap, the clamp may return nonzero maxUnits even when the pool has
        // no available tokens, causing the callback's withdraw to panic (underflow on withdrawable).
        // In the units model, credit is the lender's position in units.
        uint256 poolWithdrawable = MORPHO_MIDNIGHT.withdrawable(data.sourceMarketId);
        uint256 withdrawableAssets = UtilsLib.min(sourceCredit, poolWithdrawable);

        uint256 maxUnitsFromSource = TakeMathLib.maxUnitsForBuyerBudget(
            MORPHO_MIDNIGHT, data.targetMarketId, offer, data.feeRate, withdrawableAssets
        );

        maxUnits = TakeMathLib.capReduceOnly(MORPHO_MIDNIGHT, data.targetMarketId, offer, maxUnitsFromSource);

        // Forward check: with extreme ticks (very low offerPrice) and tiny offer capacities,
        // buyerAssets can be 0 due to floor rounding even when offerPrice > 0. The callback
        // rejects this with ZeroAmount(), so the clamp must return 0 to avoid that revert.
        if (maxUnits == 0) return 0;
        {
            uint256 buyerPrice = TickLib.tickToPrice(offer.tick);
            if (maxUnits.mulDivDown(buyerPrice, WAD) == 0) return 0;
        }
        return maxUnits;
    }
}
