// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {IMidnightVaultExecutor} from "./interfaces/IMidnightVaultExecutor.sol";
import {IRepayCallback, ILiquidateCallback} from "@midnight/interfaces/ICallbacks.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title MidnightVaultExecutor
/// @notice Facilitates deposit, withdraw and liquidation of ERC-4626 vault shares used as Midnight collateral.
/// @dev Supports multiple vaults: the vault is derived from `market.collateralParams[collateralIndex]`.
/// @dev The executor is pass-through, not custody.
/// @dev Funds must be supplied within the same call; a balance parked across calls is neither usable nor recoverable.
/// @dev VaultV2 deposits can revert if a liquidity-adapter cap of the vault is reached, blocking otherwise valid
/// deposit-and-add-collateral flows.
/// @dev Uses the Midnight contract as authorization authority (caller must be `onBehalf` or authorized by it on
/// Midnight).
///
/// VAULT SAFETY REQUIREMENTS
/// @dev List of assumptions on the vault that guarantee this executor behaves as expected:
/// - `deposit`, `mint` and `redeem` move exactly the assets/shares they report. The executor pulls
/// `previewMint(shares)` on the mint path, which equals what `mint` consumes in the same transaction, so no dust is
/// left behind.
/// - It must be resistant to atomic share-price manipulation (donation/sandwich): no per-share-price/slippage bound is
/// enforced by the executor, so deposit/mint/redeem settle at whatever rate the vault reports at execution time.
/// - It must not re-enter Midnight nor this executor on `deposit`, `mint`, `previewMint` nor `redeem`.
contract MidnightVaultExecutor is IMidnightVaultExecutor, IRepayCallback, ILiquidateCallback {
    using SafeERC20 for IERC20;

    IMidnight public immutable MORPHO_MIDNIGHT;

    /* CONSTRUCTOR */

    constructor(address morphoMidnight) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
    }

    /* COLLATERAL FUNCTIONS */

    /// @inheritdoc IMidnightVaultExecutor
    function depositAndAddCollateral(
        Market memory market,
        uint256 collateralIndex,
        uint256 assets,
        uint256 shares,
        address onBehalf
    ) external returns (uint256 depositedShares, uint256 usedAssets) {
        _checkAuthorized(onBehalf);
        if ((assets == 0) == (shares == 0)) revert InvalidInput();
        address vault = market.collateralParams[collateralIndex].token;
        if (IERC4626(vault).asset() != market.loanToken) revert CallbackLib.TokenMismatch();

        IERC4626 vaultContract = IERC4626(vault);
        IERC20 asset = IERC20(vaultContract.asset());

        if (assets > 0) {
            asset.safeTransferFrom(msg.sender, address(this), assets);
            asset.forceApprove(vault, assets);
            depositedShares = vaultContract.deposit(assets, address(this));
            usedAssets = assets;
        } else {
            usedAssets = vaultContract.previewMint(shares);
            asset.safeTransferFrom(msg.sender, address(this), usedAssets);
            asset.forceApprove(vault, usedAssets);
            vaultContract.mint(shares, address(this));
            depositedShares = shares;
        }

        IERC20(vault).forceApprove(address(MORPHO_MIDNIGHT), depositedShares);
        MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, depositedShares, onBehalf);
    }

    /// @inheritdoc IMidnightVaultExecutor
    function withdrawCollateralAndRedeem(
        Market memory market,
        uint256 collateralIndex,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assets) {
        _checkAuthorized(onBehalf);
        assets = _withdrawAndRedeem(market, collateralIndex, shares, onBehalf, receiver);
    }

    /* REPAY FUNCTIONS */

    function onRepay(bytes32, Market memory market, uint256 units, address onBehalf, bytes memory data)
        external
        override
        returns (bytes32)
    {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
        (uint256 collateralIndex, uint256 sharesToWithdraw) = abi.decode(data, (uint256, uint256));

        uint256 redeemed = _withdrawAndRedeem(market, collateralIndex, sharesToWithdraw, onBehalf, address(this));

        _fundRepay(market.loanToken, redeemed, units, onBehalf);

        return CALLBACK_SUCCESS;
    }

    /* LIQUIDATOR FUNCTIONS */

    function onLiquidate(
        address liquidator,
        bytes32,
        Market memory market,
        uint256 collateralIndex,
        uint256 seizedShares,
        uint256 repaidUnits,
        address,
        address receiver,
        bytes memory,
        uint256
    ) external override returns (bytes32) {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
        if (receiver != address(this)) revert LiquidationReceiverMismatch();
        address vault = market.collateralParams[collateralIndex].token;
        if (IERC4626(vault).asset() != market.loanToken) revert CallbackLib.TokenMismatch();

        uint256 redeemed = IERC4626(vault).redeem(seizedShares, address(this), address(this));

        _fundRepay(market.loanToken, redeemed, repaidUnits, liquidator);

        return CALLBACK_SUCCESS;
    }

    /* INTERNAL */

    /// @dev Shared by `withdrawCollateralAndRedeem` and `onRepay`: derives the vault from the market's collateral
    /// and checks its asset matches the loan token, withdraws `shares` of vault-share collateral from `onBehalf` on
    /// Midnight, and redeems them to `redeemReceiver`.
    /// @dev `withdrawCollateralAndRedeem` redeems to the external receiver;
    /// `onRepay` redeems to the executor, which then funds the repay.
    function _withdrawAndRedeem(
        Market memory market,
        uint256 collateralIndex,
        uint256 shares,
        address onBehalf,
        address redeemReceiver
    ) internal returns (uint256 assets) {
        address vault = market.collateralParams[collateralIndex].token;
        if (IERC4626(vault).asset() != market.loanToken) revert CallbackLib.TokenMismatch();

        MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, shares, onBehalf, address(this));

        assets = IERC4626(vault).redeem(shares, redeemReceiver, address(this));
    }

    function _fundRepay(address loanToken, uint256 redeemed, uint256 repaidUnits, address surplusReceiver) internal {
        if (repaidUnits > redeemed) revert RepayExceedsRedeemed();
        if (redeemed > repaidUnits) {
            IERC20(loanToken).safeTransfer(surplusReceiver, redeemed - repaidUnits);
        }
        IERC20(loanToken).forceApprove(address(MORPHO_MIDNIGHT), repaidUnits);
    }

    function _checkAuthorized(address onBehalf) internal view {
        if (msg.sender != onBehalf && !MORPHO_MIDNIGHT.isAuthorized(onBehalf, msg.sender)) revert Unauthorized();
    }
}
