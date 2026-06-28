// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ITakeClamp} from "../interfaces/ITakeClamp.sol";
import {IMidnight, Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {ILendMidnightToVaultCallback} from "../../callbacks/interfaces/ILendMidnightToVaultCallback.sol";
import {TakeMathLib} from "../../libraries/TakeMathLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title LendMidnightToVaultClamp
/// @notice Clamp that bounds takeUnits for Midnight to vault lend exits.
/// @dev Bounds units by the lender's withdrawable position and the target vault's deposit capacity.
/// @dev The callback withdraws from the source Midnight market and deposits into the target vault.
/// @dev Assumes positionOwner has credit (a lender position) on the source market with sufficient withdrawable
/// liquidity available (works for both pre- and post-maturity positions).
/// @dev `positionOwner` is passed in clampData; for a ratified migration offer it equals `offer.maker`.
/// @dev Offer consumption is checked structurally by TenorRouter.
contract LendMidnightToVaultClamp is ITakeClamp {
    /// @notice The vault type determines how the target vault's deposit capacity is computed.
    /// @dev ERC4626: standard ERC-4626 vault, uses maxDeposit(owner).
    /// @dev VAULT_V2: Morpho Vault V2, maxDeposit always returns 0, so the check is skipped (unconstrained).
    /// @dev TENOR_VAULT_V2: Tenor's Vault V2, maxDeposit always returns 0, so the check is skipped (unconstrained).
    enum VaultType {
        ERC4626,
        VAULT_V2,
        TENOR_VAULT_V2
    }

    /// @notice The Morpho Midnight protocol contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    /// @notice Data decoded from clampData.
    struct LendMidnightToVaultClampData {
        bytes32 sourceMarketId; // Source Midnight market ID
        address targetVault; // Target ERC-4626 vault
        address positionOwner; // Lender whose position is migrated (= offer.maker)
        VaultType vaultType; // Vault type (determines deposit capacity check strategy)
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
        LendMidnightToVaultClampData memory data = abi.decode(clampData, (LendMidnightToVaultClampData));

        Market memory sourceMarket = MORPHO_MIDNIGHT.toMarket(data.sourceMarketId);
        (uint128 userCredit,,) =
            MORPHO_MIDNIGHT.updatePositionView(sourceMarket, data.sourceMarketId, data.positionOwner);
        if (userCredit == 0) return 0;

        uint256 maxAssets = _targetVaultCapacity(data);

        // Callback deposits sellerAssets net of fee, so the real cap is (sellerAssets - fee) <= maxDeposit: gross up
        // the budget to invert the fee and fill the cap exactly. (96 = CallbackData abi size: vault, feeRate,
        // feeRecipient.)
        if (
            data.vaultType == VaultType.ERC4626 && maxAssets <= type(uint256).max / WAD
                && offer.callbackData.length == 96
        ) {
            ILendMidnightToVaultCallback.CallbackData memory cb =
                abi.decode(offer.callbackData, (ILendMidnightToVaultCallback.CallbackData));
            if (cb.vault == data.targetVault && cb.feeRate > 0 && cb.feeRate < WAD) {
                maxAssets = UtilsLib.mulDivDown(maxAssets, WAD, WAD - cb.feeRate);
            }
        }

        uint256 maxUnitsFromVault =
            TakeMathLib.assetsToSellerUnits(MORPHO_MIDNIGHT, data.sourceMarketId, offer, maxAssets);

        // Cap by actual source credit (asset-to-unit conversion can overshoot at low prices).
        maxUnits = UtilsLib.min(maxUnitsFromVault, userCredit);

        // reduceOnly is already implicitly capped by userCredit above, but made explicit for safety.
        return TakeMathLib.capReduceOnly(MORPHO_MIDNIGHT, data.sourceMarketId, offer, maxUnits);
    }

    /// @dev Computes the effective deposit capacity of the target vault based on vault type.
    function _targetVaultCapacity(LendMidnightToVaultClampData memory data) internal view returns (uint256) {
        // Unconstrained by deposit caps; maxUnits caps the result by userCredit.
        if (data.vaultType == VaultType.VAULT_V2 || data.vaultType == VaultType.TENOR_VAULT_V2) {
            return type(uint256).max;
        }

        // ERC-4626: maxDeposit accounts for vault-level deposit caps.
        return IERC4626(data.targetVault).maxDeposit(data.positionOwner);
    }
}
