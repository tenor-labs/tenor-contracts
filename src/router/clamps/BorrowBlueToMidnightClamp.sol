// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ITakeClamp} from "../interfaces/ITakeClamp.sol";
import {IMidnight, Offer} from "@midnight/interfaces/IMidnight.sol";
import {TakeMathLib} from "../../libraries/TakeMathLib.sol";
import {IMorpho, Id, MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "../../../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

/// @title BorrowBlueToMidnightClamp
/// @notice Clamp that bounds takeUnits for Morpho Blue to Midnight borrow migrations (cadence-based, SELL offers).
/// @dev Bounds units by the borrower's Blue debt budget (fee-aware) using live position data.
/// @dev The callback repays Blue debt with repayBudget = sellerAssets - fee(interest).
/// @dev Assumes the source Blue and target Midnight markets have the same loan token, collateral, LLTV, and oracle.
/// @dev feeRate in the clamp data must match the feeRate in the callback data.
/// @dev `positionOwner` is passed in clampData; for a ratified migration offer it equals `offer.maker`.
/// @dev This clamp does not check health: under the same-collateral assumption health is binary, and if the borrower is
/// healthy in source they will be healthy in target (collateral migrates pro-rata).
/// @dev The router's try/catch (fail-safe mode) handles edge cases.
/// @dev Offer consumption is checked structurally by TenorRouter.
contract BorrowBlueToMidnightClamp is ITakeClamp {
    using MorphoBalancesLib for IMorpho;

    /// @notice The Morpho Midnight protocol contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    /// @notice The Morpho Blue contract.
    IMorpho public immutable MORPHO_BLUE;

    /// @notice Data decoded from clampData.
    struct BorrowBlueToMidnightClampData {
        bytes32 sourceBlueMarketId; // Morpho Blue market ID
        bytes32 marketId; // Target Midnight market ID
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
        BorrowBlueToMidnightClampData memory data = abi.decode(clampData, (BorrowBlueToMidnightClampData));

        MarketParams memory params = MORPHO_BLUE.idToMarketParams(Id.wrap(data.sourceBlueMarketId));
        uint256 blueDebt = MORPHO_BLUE.expectedBorrowAssets(params, data.positionOwner);
        if (blueDebt == 0) return 0;

        // repayBudget = sellerAssets - fee(interest) must not exceed blueDebt.
        uint256 maxUnitsFromDebt =
            TakeMathLib.maxUnitsForSellerBudget(MORPHO_MIDNIGHT, data.marketId, offer, data.feeRate, blueDebt);

        return TakeMathLib.capReduceOnly(MORPHO_MIDNIGHT, data.marketId, offer, maxUnitsFromDebt);
    }
}
