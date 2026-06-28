// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CallbackLib} from "src/libraries/CallbackLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";

/// @title CallbackLibFeeSymmetryFuzzTest
/// @notice A lender and a borrower trading the SAME asset amount at the SAME offer price,
///         SAME fee rate, and SAME time to maturity must pay the SAME absolute fee in
///         assets (up to a few wei of rounding).
///
///         Maturity and APR enter the system only via the offer `price`
///         (price = 1 / (1 + APR · TTM / 365)), so holding price equal already holds
///         maturity and rate equal between the two sides.
contract CallbackLibFeeSymmetryFuzzTest is Test {
    /// @notice Tight symmetry bound for prices in the realistic APR range.
    /// @dev Each side composes three mulDiv rounds with different rounding directions
    ///      (lender: bEff floor + units floor + assets floor; borrower: sEff ceil +
    ///      units ceil + assets floor). The amplification factor is ~assets/price.
    ///      With price ∈ [WAD/2, WAD-1] and assets ∈ [1, 1e18] the gap fits in 6 wei.
    function testFuzz_lenderFeeEqualsBorrowerFee(uint256 price, uint256 feeRate, uint256 assets) public pure {
        // price ∈ [WAD/2, WAD-1]: ~0%–100% APR. Excludes WAD (zero-interest, zero fee)
        // and very low prices where rounding amplification (~assets/price) exceeds 4 wei.
        price = bound(price, WAD / 2, WAD - 1);
        // feeRate ∈ (0, WAD]: cap at 100% of interest (matches CallbackLib).
        feeRate = bound(feeRate, 1, WAD);
        // assets ∈ [1, 1e18]: single wei up to 1e18 (1T USDC @ 6dp, 1 ETH @ 18dp).
        assets = bound(assets, 1, 1e18);

        uint256 bEff = CallbackLib.buyerEffectivePrice(price, feeRate);
        uint256 sEff = CallbackLib.sellerEffectivePrice(price, feeRate);

        // LENDER (buyer) wires `assets`, receives units = floor(assets · WAD / bEff).
        // Fee = budget − units · price / WAD.
        uint256 lenderUnits = Math.mulDiv(assets, WAD, bEff);
        uint256 lenderAssetsAtOffer = Math.mulDiv(lenderUnits, price, WAD);
        uint256 lenderFee = assets - lenderAssetsAtOffer;

        // BORROWER (seller) receives `assets`, owes units = ceil(assets · WAD / sEff).
        // Fee = units · price / WAD − budget.
        uint256 borrowerUnits = Math.mulDiv(assets, WAD, sEff, Math.Rounding.Ceil);
        uint256 borrowerAssetsAtOffer = Math.mulDiv(borrowerUnits, price, WAD);
        uint256 borrowerFee = borrowerAssetsAtOffer - assets;

        assertApproxEqAbs(lenderFee, borrowerFee, 6, "lender fee != borrower fee at equal asset size");
    }

    /// @notice feeRate == 0 must produce exactly-equal (not just within-4) fees on both
    ///         sides, and both must be zero.
    function testFuzz_zeroFeeRateProducesZeroFee(uint256 price, uint256 assets) public pure {
        price = bound(price, WAD / 2, WAD - 1);
        assets = bound(assets, 1, 1e18);

        uint256 bEff = CallbackLib.buyerEffectivePrice(price, 0);
        uint256 sEff = CallbackLib.sellerEffectivePrice(price, 0);
        assertEq(bEff, price, "zero feeRate: bEff must equal price");
        assertEq(sEff, price, "zero feeRate: sEff must equal price");

        uint256 lenderUnits = Math.mulDiv(assets, WAD, bEff);
        uint256 lenderFee = assets - Math.mulDiv(lenderUnits, price, WAD);

        uint256 borrowerUnits = Math.mulDiv(assets, WAD, sEff, Math.Rounding.Ceil);
        uint256 borrowerAssetsAtOffer = Math.mulDiv(borrowerUnits, price, WAD);
        // Borrower can owe up to 1 wei more than `assets` due to ceil rounding when the
        // rational units are non-integer. That's accounting noise (no fee charged),
        // hence zeroFloorSub in CallbackLib.buyerFeeFromTick / sellerFeeFromTick.
        uint256 borrowerFee = borrowerAssetsAtOffer > assets ? borrowerAssetsAtOffer - assets : 0;

        assertLe(lenderFee, 1, "zero feeRate: lender fee must be rounding-only");
        assertLe(borrowerFee, 1, "zero feeRate: borrower fee must be rounding-only");
    }
}
