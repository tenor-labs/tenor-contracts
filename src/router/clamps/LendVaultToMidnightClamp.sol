// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ITakeClamp} from "../interfaces/ITakeClamp.sol";
import {IMidnight, Offer} from "@midnight/interfaces/IMidnight.sol";
import {TakeMathLib} from "../../libraries/TakeMathLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMorpho, Id, MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "../../../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

/// @title LendVaultToMidnightClamp
/// @notice Clamp that bounds takeUnits for vault to Midnight lend migrations (cadence-based).
/// @dev Bounds units by the lender's withdrawable balance in the source vault; the computation depends on VaultType.
/// @dev The callback redeems source vault shares for loan tokens to fund the buy.
/// @dev feeRate in the clamp data must match the feeRate in the callback data.
/// @dev `positionOwner` is passed in clampData; for a ratified migration offer it equals `offer.maker`.
/// @dev Offer consumption is checked structurally by TenorRouter.
/// @dev For VAULT_V2, liquidity is assumed always sufficient to withdraw; maxWithdraw returns 0 by design for ERC-4626
/// compliance, so convertToAssets(balanceOf) is used as the withdrawal bound.
contract LendVaultToMidnightClamp is ITakeClamp {
    using MorphoBalancesLib for IMorpho;

    /// @notice The vault type determines how the position owner's withdrawable balance is computed.
    /// @dev ERC4626: standard ERC-4626 vault, uses maxWithdraw(owner).
    /// @dev VAULT_V2: Morpho Vault V2, maxWithdraw always returns 0, so the check is skipped (unconstrained).
    /// @dev TENOR_VAULT_V2: Tenor's Vault V2 with 100% allocation to a single Morpho Blue market, so
    /// withdrawable = min(owner's vault balance in assets, market available liquidity).
    enum VaultType {
        ERC4626,
        VAULT_V2,
        TENOR_VAULT_V2
    }

    /// @notice The Morpho Midnight protocol contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    /// @notice The Morpho Blue contract, used for TENOR_VAULT_V2 liquidity checks.
    IMorpho public immutable MORPHO_BLUE;

    /// @notice Data decoded from clampData.
    struct LendVaultToMidnightClampData {
        address sourceVault; // ERC-4626 vault
        bytes32 marketId; // Target Midnight market ID
        address positionOwner; // Lender whose position is migrated (= offer.maker)
        uint256 feeRate; // Fee rate from callback data, in WAD (0 = no fee).
        VaultType vaultType; // Vault type; determines the liquidity check strategy
        bytes32 morphoBlueMarketId; // Used only when vaultType == TENOR_VAULT_V2; bytes32(0) otherwise
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
        LendVaultToMidnightClampData memory data = abi.decode(clampData, (LendVaultToMidnightClampData));

        uint256 ownerWithdrawable = _ownerWithdrawable(data);
        if (ownerWithdrawable == 0) return 0;

        uint256 cappedUnits =
            TakeMathLib.maxUnitsForBuyerBudget(MORPHO_MIDNIGHT, data.marketId, offer, data.feeRate, ownerWithdrawable);

        return TakeMathLib.capReduceOnly(MORPHO_MIDNIGHT, data.marketId, offer, cappedUnits);
    }

    /// @dev Computes the position owner's withdrawable balance based on vault type.
    function _ownerWithdrawable(LendVaultToMidnightClampData memory data) internal view returns (uint256) {
        if (data.vaultType == VaultType.TENOR_VAULT_V2) {
            uint256 ownerAssets =
                IERC4626(data.sourceVault).convertToAssets(IERC4626(data.sourceVault).balanceOf(data.positionOwner));
            if (ownerAssets == 0) return 0;
            MarketParams memory params = MORPHO_BLUE.idToMarketParams(Id.wrap(data.morphoBlueMarketId));
            (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = MORPHO_BLUE.expectedMarketBalances(params);
            return UtilsLib.min(ownerAssets, UtilsLib.zeroFloorSub(totalSupplyAssets, totalBorrowAssets));
        }

        if (data.vaultType == VaultType.VAULT_V2) {
            return IERC4626(data.sourceVault).convertToAssets(IERC4626(data.sourceVault).balanceOf(data.positionOwner));
        }

        // ERC-4626: maxWithdraw accounts for share balance and vault liquidity.
        return IERC4626(data.sourceVault).maxWithdraw(data.positionOwner);
    }
}
