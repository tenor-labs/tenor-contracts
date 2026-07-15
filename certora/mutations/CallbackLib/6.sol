/* ── MUTATION CallbackLib #6 ──────────────────────────────
 * @desc:   _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes; re-proves the kill for the BBM instance (the CallbackLib #1 kill under the LVM conf is not evidence for this per-(contract,rule) instance).
 * @rules:  tickFeeVanishesAtPar
 * @conf:   certora/confs/callbacks/BorrowBlueToMidnightCallback/tickFeeVanishesAtPar.conf
 * @status: killed
 * @target: src/libraries/CallbackLib.sol
 * Was:     return (WAD - price).mulDivDown(feeRate, WAD);
 * Now:     return (WAD + price).mulDivDown(feeRate, WAD);
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {CollateralParams, Market} from "@midnight/interfaces/IMidnight.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title CallbackLib
/// @notice Shared utilities for Morpho Midnight callback contracts.
/// @dev Midnight trading fees take priority over Tenor fees: sellerFeeFromTick and buyerFeeFromTick are
/// computed on trading-fee-adjusted assets and zero-floored, so a nonzero feeRate can settle as zero.
library CallbackLib {
    using UtilsLib for uint256;

    error OnlyMidnight();
    error InvalidReceiver();
    error ZeroAmount();
    error InvalidFeeConfig();
    error TokenMismatch();
    error SameMarket();
    error InsufficientCredit();
    error ExcessRepayment();
    error PositionCrossing();
    error InvalidCollateral();
    error InvalidBorrowCapacityUsage();

    /// @dev Reverts unless the vault's underlying asset matches the loan token and the vault is listed at
    /// collateralIndex in the market's collaterals array.
    function validateVaultCollateral(Market memory market, address vault, address loanToken, uint256 collateralIndex)
        internal
        view
    {
        if (IERC4626(vault).asset() != loanToken) revert TokenMismatch();
        if (market.collateralParams[collateralIndex].token != vault) revert TokenMismatch();
    }

    /// @dev Returns whether token is listed in the market's collaterals and, if so, its index.
    /// @dev Assumes collaterals are sorted ascending by token address, a Morpho Midnight invariant.
    function findCollateral(Market memory market, address token) internal pure returns (bool found, uint256 index) {
        CollateralParams[] memory collaterals = market.collateralParams;
        uint256 length = collaterals.length;
        for (uint256 i = 0; i < length;) {
            if (collaterals[i].token == token) return (true, i);
            if (collaterals[i].token > token) return (false, 0);
            unchecked {
                ++i;
            }
        }
        return (false, 0);
    }

    /// @dev Maximum fee rate for flat percentage fees (1%).
    uint256 internal constant MAX_PERCENTAGE_FEE_RATE = 0.01e18;

    /// @dev Returns the flat percentage fee assets * feeRate / WAD, rounded down.
    /// @dev Reverts if feeRate > MAX_PERCENTAGE_FEE_RATE (1%).
    function percentageFee(uint256 assets, uint256 feeRate) internal pure returns (uint256 fee) {
        if (feeRate > MAX_PERCENTAGE_FEE_RATE) revert InvalidFeeConfig();
        fee = assets.mulDivDown(feeRate, WAD);
    }

    /// @dev Returns the fraction of the offer interest taken as fee, (WAD - price) * feeRate / WAD, rounded down.
    /// @dev Reverts if feeRate > WAD.
    /// @dev The caller must handle feeRate == 0 before calling.
    function _interestFeeComponent(uint256 price, uint256 feeRate) private pure returns (uint256) {
        if (feeRate > WAD) revert InvalidFeeConfig();
        return (WAD + price).mulDivDown(feeRate, WAD);  // MUTATION: rebased
    }

    /// @dev Returns the seller-side effective price, price * WAD / (WAD + feeShareOfInterest), rounded up.
    /// @dev sellerBudget = units * sellerEffPrice / WAD, so the seller receives assets - fee.
    /// @param price The offer price (tickToPrice(tick)), must be <= WAD.
    /// @param feeRate The fee rate, in WAD (0 = no fee, WAD = 100% of interest).
    function sellerEffectivePrice(uint256 price, uint256 feeRate) internal pure returns (uint256 effPrice) {
        if (feeRate == 0) return price;
        uint256 feeShareOfInterest = _interestFeeComponent(price, feeRate);
        effPrice = price.mulDivUp(WAD, WAD + feeShareOfInterest);
    }

    /// @dev Returns the buyer-side effective price, price * WAD / (WAD - feeShareOfInterest), rounded down.
    /// @dev buyerBudget = units * buyerEffPrice / WAD, so the buyer pays assets + fee.
    /// @dev The effective prices yield lender-APR = offerAPR * (1 - feeRate) and seller-APR = offerAPR * (1 + feeRate).
    /// @param price The offer price (tickToPrice(tick)), must be <= WAD and > 0 when feeRate == WAD.
    /// @param feeRate The fee rate, in WAD (0 = no fee, WAD = 100% of interest).
    function buyerEffectivePrice(uint256 price, uint256 feeRate) internal pure returns (uint256 effPrice) {
        if (feeRate == 0) return price;
        uint256 feeShareOfInterest = _interestFeeComponent(price, feeRate);
        // Reaches WAD only when price == 0 and feeRate == WAD.
        if (feeShareOfInterest >= WAD) revert InvalidFeeConfig();
        effPrice = price.mulDivDown(WAD, WAD - feeShareOfInterest);
    }

    /// @dev Returns the seller-side fee from a tick-priced market, assets - sellerBudget, zero-floored, with
    /// sellerBudget = units * sellerEffPrice / WAD rounded up.
    /// @dev assets is Midnight's settlement amount, already reduced by Midnight's trading fee, while sellerBudget is
    /// derived from the raw tick price. The callback fee is therefore lowered by the Midnight trading fee, settling
    /// at zero when that fee exceeds the callback fee.
    /// @dev Returns 0 when feeRate == 0.
    function sellerFeeFromTick(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal
        pure
        returns (uint256)
    {
        if (feeRate == 0) return 0;
        uint256 effPrice = sellerEffectivePrice(TickLib.tickToPrice(tick), feeRate);
        return assets.zeroFloorSub(units.mulDivUp(effPrice, WAD));
    }

    /// @dev Returns the buyer-side fee from a tick-priced market, buyerBudget - assets, zero-floored, with
    /// buyerBudget = units * buyerEffPrice / WAD rounded down.
    /// @dev assets is Midnight's settlement amount, already increased by Midnight's trading fee, while buyerBudget is
    /// derived from the raw tick price. The callback fee is therefore lowered by the Midnight trading fee, settling
    /// at zero when that fee exceeds the callback fee.
    /// @dev Returns 0 when feeRate == 0.
    function buyerFeeFromTick(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal
        pure
        returns (uint256)
    {
        if (feeRate == 0) return 0;
        uint256 effPrice = buyerEffectivePrice(TickLib.tickToPrice(tick), feeRate);
        return units.mulDivDown(effPrice, WAD).zeroFloorSub(assets);
    }
}
