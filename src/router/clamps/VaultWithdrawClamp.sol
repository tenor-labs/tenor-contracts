// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ITakeClamp} from "../interfaces/ITakeClamp.sol";
import {IMidnight, Offer} from "@midnight/interfaces/IMidnight.sol";
import {TakeMathLib} from "../../libraries/TakeMathLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";

/// @title VaultWithdrawClamp
/// @notice Clamp that bounds takeUnits for BUY offers using MidnightWithdrawVaultSharesCallback.
/// @dev Unwinds positions created by VaultSupplyClamp/MidnightSupplyVaultSharesCallback: the buyer (borrower) repays
/// debt by redeeming vault share collateral. The callback withdraws vault shares from the buyer's collateral, redeems
/// them for loan tokens, and uses those to fund the buy (debt repayment).
/// @dev Bounds units by the buyer's vault collateral balance and, for reduceOnly offers, the buyer's debt.
/// @dev Applies a zero-amount guard because the callback reverts on zero units or zero buyerAssets.
/// @dev Offer consumption is checked structurally by TenorRouter.
/// @dev Assumes the vault-to-loan-token oracle price is monotonically increasing.
/// @dev No health check is needed: debt repaid (units) >= assets spent (buyerAssets) at any price <= WAD, and since
/// lltv <= WAD, borrowing capacity removed is always <= debt removed, so repaying via this callback improves health.
/// @dev The bound uses convertToAssets and ignores withdrawal limits or queues; quoted fills may revert at the vault.
/// @dev Assumes the vault has no entry/exit fee, so convertToAssets sizing matches the callback's previewWithdraw.
contract VaultWithdrawClamp is ITakeClamp {
    using UtilsLib for uint256;

    /// @notice The Morpho Midnight protocol contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    /// @notice Data decoded from clampData.
    struct VaultWithdrawClampData {
        address vault; // ERC-4626 vault address
        uint256 collateralIndex; // Index in market.collateralParams[]
        bytes32 marketId; // Pre-computed market ID
        address callback; // Callback address
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
        // BUY-only: the paired callback is onBuy.
        if (!offer.buy) return 0;

        VaultWithdrawClampData memory data = abi.decode(clampData, (VaultWithdrawClampData));

        uint128 userVaultShares = MORPHO_MIDNIGHT.collateral(data.marketId, offer.maker, data.collateralIndex);
        if (userVaultShares == 0) return 0;

        uint256 maxAssetsFromVault = IERC4626(data.vault).convertToAssets(uint256(userVaultShares));

        uint256 buyerPrice = TickLib.tickToPrice(offer.tick);
        // Tight inverse: largest units such that units.mulDivDown(buyerPrice, WAD) <= maxAssetsFromVault.
        maxUnits =
            buyerPrice > 0 ? TakeMathLib.mulDivDownInverse(maxAssetsFromVault, WAD, buyerPrice) : type(uint128).max;

        maxUnits = TakeMathLib.capReduceOnly(MORPHO_MIDNIGHT, data.marketId, offer, maxUnits);

        // The callback reverts with ZeroAmount() if buyerAssets is zero, so guard against
        // maxUnits producing buyerAssets == 0.
        if (maxUnits > 0) {
            uint256 buyerAssets = maxUnits.mulDivDown(buyerPrice, WAD);
            if (buyerAssets == 0) return 0;
        }
    }
}
