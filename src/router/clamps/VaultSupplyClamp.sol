// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ITakeClamp} from "../interfaces/ITakeClamp.sol";
import {IMidnight, Offer} from "@midnight/interfaces/IMidnight.sol";
import {TakeMathLib} from "../../libraries/TakeMathLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IMidnightSupplyVaultSharesCallback} from "@callbacks/interfaces/IMidnightSupplyVaultSharesCallback.sol";

/// @title VaultSupplyClamp
/// @notice Clamp that bounds takeUnits for SELL offers using MidnightSupplyVaultSharesCallback.
/// @dev Bounds units by the seller's loan token balance and allowance, and by the reduce-only cap.
/// @dev The callback pulls ceil(sellerAssets * additionalDepositPercent / WAD) from the seller, where
/// sellerAssets = ceil(units * tickToPrice(offer.tick) / WAD); maxUnits inverts both ceilings against available.
/// @dev Offer consumption is checked structurally by TenorRouter.
/// @dev Solvency is not enforced. A take can still revert on Midnight's post-callback health check if the
/// vault share oracle price drops (e.g. underlying vault bad debt) between offer signing and take, or if
/// additionalDepositPercent is set below the LLTV-derived minimum (WAD^3 / (price * lltv) - WAD, where
/// price = tickToPrice(offer.tick), assuming the oracle prices shares at their loan-token redemption value).
/// @dev Routers/keepers must set Action.allowRevert = true so an unhealthy fill skips instead of reverting the batch.
contract VaultSupplyClamp is ITakeClamp {
    IMidnight public immutable MORPHO_MIDNIGHT;

    struct VaultSupplyClampData {
        address loanToken;
        address vault;
        address callback;
        bytes32 marketId;
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
        VaultSupplyClampData memory data = abi.decode(clampData, (VaultSupplyClampData));

        // Guard malformed callbackData: length must fit the static 3-word struct.
        if (offer.callbackData.length < 96) return 0;
        IMidnightSupplyVaultSharesCallback.CallbackData memory cb =
            abi.decode(offer.callbackData, (IMidnightSupplyVaultSharesCallback.CallbackData));

        uint256 available = TakeMathLib.available(data.loanToken, offer.maker, data.callback);

        // The callback pulls amountFromSeller = ceil(sellerAssets * additionalDepositPercent / WAD); invert that
        // ceiling to the largest sellerAssets the seller's balance/allowance can cover, then convert assets to units
        // via the shared SELL-side inverse (which saturates zero percent and zero-price offers to uint128.max).
        uint256 maxSellerAssets = TakeMathLib.mulDivUpInverse(available, WAD, cb.additionalDepositPercent);
        maxUnits = TakeMathLib.assetsToSellerUnits(MORPHO_MIDNIGHT, data.marketId, offer, maxSellerAssets);

        return TakeMathLib.capReduceOnly(MORPHO_MIDNIGHT, data.marketId, offer, maxUnits);
    }
}
