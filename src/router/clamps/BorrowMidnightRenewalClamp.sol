// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ITakeClamp} from "../interfaces/ITakeClamp.sol";
import {IMidnight, Offer} from "@midnight/interfaces/IMidnight.sol";
import {TakeMathLib} from "../../libraries/TakeMathLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {MAX_COLLATERALS_PER_BORROWER} from "@midnight/libraries/ConstantsLib.sol";

/// @title BorrowMidnightRenewalClamp
/// @notice Clamp that bounds takeUnits for Midnight to Midnight borrow renewals (cross-market).
/// @dev Bounds units by the borrower's source debt position and repayment budget.
/// @dev Assumes the source and target markets are identical except for maturity (target maturity > source maturity):
/// same loanToken, same collaterals (tokens, oracles, LLTVs), same rcfThreshold. This is a keeper precondition.
/// @dev Assumes positionOwner, the borrower, has debt on the source market.
/// @dev Source and target must be different markets; self-renewal is blocked.
/// @dev The offer's callback is a BorrowMidnightRenewalCallback that pulls sellerAssets, deducts the fee on interest,
/// repays source debt, and transfers collateral pro-rata.
/// @dev feeRate in the clamp data must match the feeRate in the callback data.
/// @dev `positionOwner` is passed in clampData; for a ratified migration offer it equals `offer.maker`.
/// @dev Offer consumption is checked structurally by TenorRouter.
/// @dev Only loanToken is checked onchain; mismatched collaterals are silently skipped and left on the source market.
contract BorrowMidnightRenewalClamp is ITakeClamp {
    /// @notice The Morpho Midnight protocol contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    /// @notice Data decoded from clampData.
    struct BorrowMidnightRenewalClampData {
        bytes32 sourceMarketId; // Source debt market ID
        bytes32 targetMarketId; // Target debt market ID
        address positionOwner; // Borrower whose position is migrated (= offer.maker)
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
        BorrowMidnightRenewalClampData memory data = abi.decode(clampData, (BorrowMidnightRenewalClampData));

        uint256 sourceDebt = MORPHO_MIDNIGHT.debt(data.sourceMarketId, data.positionOwner);
        if (sourceDebt == 0) return 0;

        // Self-renewal guard: source == target makes debt accounting circular.
        if (data.sourceMarketId == data.targetMarketId) return 0;

        // Activation cap: the union of source and target bitmaps must fit on target post-migration.
        uint128 sourceBitmap = MORPHO_MIDNIGHT.collateralBitmap(data.sourceMarketId, data.positionOwner);
        uint128 targetBitmap = MORPHO_MIDNIGHT.collateralBitmap(data.targetMarketId, data.positionOwner);
        if (UtilsLib.countBits(sourceBitmap | targetBitmap) > MAX_COLLATERALS_PER_BORROWER) return 0;

        // Position owner is always the seller (repaying debt), regardless of offer direction.
        uint256 maxUnitsFromSource =
            TakeMathLib.maxUnitsForSellerBudget(MORPHO_MIDNIGHT, data.targetMarketId, offer, data.feeRate, sourceDebt);

        return TakeMathLib.capReduceOnly(MORPHO_MIDNIGHT, data.targetMarketId, offer, maxUnitsFromSource);
    }
}
