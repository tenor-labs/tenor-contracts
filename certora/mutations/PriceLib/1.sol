/* ── MUTATION PriceLib #1 ──────────────────────────────
 * @desc:   swapped buyer/seller rounding (mulDivDown<->mulDivUp)
 * @rules:  priceFollowsZeroCouponFormula, priceRoundsInProtectedUserFavor
 * @conf:   certora/confs/ratifier/unit.conf
 * @status: killed
 * @target: src/libraries/PriceLib.sol
 * Was:     return isBuy ? WAD.mulDivDown(WAD, denominator) : WAD.mulDivUp(WAD, denominator);
 * Now:     return isBuy ? WAD.mulDivUp(WAD, denominator) : WAD.mulDivDown(WAD, denominator);
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";

/// @title PriceLib
/// @notice Pure arithmetic for unit price computation and rate limit checking.
library PriceLib {
    using UtilsLib for uint256;

    /// @dev Returns the unit price WAD^2 / (WAD + ratePerSecond * durationSeconds).
    /// @dev Returns WAD (par, 0% discount) when ratePerSecond == 0 or durationSeconds == 0.
    /// @dev The price lies in [0, WAD]: the buy branch (mulDivDown) can floor to 0 for very large
    /// ratePerSecond * durationSeconds, while the sell branch (mulDivUp) stays >= 1.
    /// @dev Rounds in the protected user's favor: down when the user buys (lower ceiling on what they pay), up when the
    /// user sells (higher floor on what they receive).
    /// @dev Input bound (ceil-branch mulDivUp headroom): with the seller-side rate capped by the uint40 limit rate,
    /// overflow would need durations exceeding ~1e65 seconds.
    /// @param isBuy True when the protected user is the buyer (lend-side), false when the seller.
    /// @param ratePerSecond The interest rate per second, in WAD (1e18 = 100% per second).
    /// @param durationSeconds The duration in seconds.
    /// @return price The unit price (assets per unit), in WAD.
    function computePrice(bool isBuy, uint256 ratePerSecond, uint256 durationSeconds) internal pure returns (uint256) {
        uint256 denominator = WAD + ratePerSecond * durationSeconds;
        return isBuy ? WAD.mulDivUp(WAD, denominator) : WAD.mulDivDown(WAD, denominator);  // MUTATION: rebased
    }

    /// @dev Returns the effective rate for the position side: max(policyRate, limitRate) for lenders (isBuy == true,
    /// floor protection) and min(policyRate, limitRate) for borrowers (isBuy == false, ceiling protection).
    /// @param isBuy True for lend-side, false for borrow-side.
    /// @param policyRate The rate from the interest rate policy.
    /// @param limitRate The user's configured limit rate.
    function computeEffectiveRate(bool isBuy, uint256 policyRate, uint256 limitRate) internal pure returns (uint256) {
        return
            isBuy
                ? (policyRate > limitRate ? policyRate : limitRate)
                : (policyRate < limitRate ? policyRate : limitRate);
    }

    /// @dev Returns true if the executed price satisfies the user's rate limit constraint.
    /// @dev For lenders (isBuy == true): assets * WAD <= units * price (floor).
    /// @dev For borrowers (isBuy == false): assets * WAD >= units * price (ceiling).
    /// @dev Any fee must be folded into assets by the caller (e.g. via RouterLib.netBuyerPrice /
    /// netSellerPrice in BaseMigrationRatifier._ratifyRate).
    /// @dev Overflow safety: units and assets are uint128 from Midnight and price <= WAD (1e18),
    /// so both sides of the comparison fit in uint256.
    /// @param isBuy True for lend-side (floor protection), false for borrow-side (ceiling protection).
    /// @param units The number of market units in the take.
    /// @param assets The post-fee assets (sellerAssets for borrow, buyerAssets for lend).
    /// @param limitRate The user's configured limit rate per second.
    /// @param policyRate The rate from the interest rate policy.
    /// @param duration The duration in seconds used for price computation.
    function satisfiesRateLimit(
        bool isBuy,
        uint256 units,
        uint256 assets,
        uint256 limitRate,
        uint256 policyRate,
        uint256 duration
    ) internal pure returns (bool) {
        uint256 effectiveRate = computeEffectiveRate(isBuy, policyRate, limitRate);
        uint256 price = computePrice(isBuy, effectiveRate, duration);
        if (isBuy) {
            return assets * WAD <= units * price;
        } else {
            return assets * WAD >= units * price;
        }
    }
}
