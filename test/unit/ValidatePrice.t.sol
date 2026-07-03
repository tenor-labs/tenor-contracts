// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ValidatePriceHarness} from "../helpers/ValidatePriceHarness.sol";
import {PriceLib} from "../../src/libraries/PriceLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";

/// @title ValidatePriceUnitTest
/// @notice Unit tests for PriceLib.satisfiesRateLimit via the price-check harness.
contract ValidatePriceUnitTest is Test {
    using UtilsLib for uint256;

    ValidatePriceHarness internal harness;

    // Rates: floor(APR * WAD / 31536000)
    uint256 constant RATE_2_PCT = 634195839;
    uint256 constant RATE_5_PCT = 1585489599;
    uint256 constant RATE_6_PCT = 1902587519;
    uint256 constant RATE_8_PCT = 2536783358;
    uint256 constant RATE_10_PCT = 3170979198;
    uint256 constant RATE_12_PCT = 3805175038;
    uint256 constant RATE_15_PCT = 4756174877;
    uint256 constant DUR_90D = 7776000;
    uint256 constant DUR_365D = 31536000;

    function setUp() public {
        harness = new ValidatePriceHarness();
    }

    /* ═══════ Test-only helper ═══════ */

    function _computePrice(bool isBuy, uint256 ratePerSecond, uint256 durationSeconds) internal pure returns (uint256) {
        uint256 denominator = WAD + ratePerSecond * durationSeconds;
        return isBuy ? WAD.mulDivDown(WAD, denominator) : WAD.mulDivUp(WAD, denominator);
    }

    /* ═══════════════════════════════════════════════════════════════
       Unit pricing at various APRs
       ═══════════════════════════════════════════════════════════════ */

    function test_computePrice_knownValues() public pure {
        assertEq(_computePrice(true, 0, 365 days), WAD, "rate=0 gives par");

        uint256 p1 = _computePrice(true, 1e12, 1);
        uint256 expected1 = uint256(1e36) / (uint256(1e18) + uint256(1e12));
        assertEq(p1, expected1, "rate=1e12, dur=1s");

        uint256 denom = 1e18 + uint256(1e9) * DUR_365D;
        assertEq(_computePrice(true, 1e9, 365 days), 1e36 / denom, "rate=1e9, dur=365d");
    }

    function test_computePrice_8pct_90days() public pure {
        assertEq(_computePrice(true, RATE_8_PCT, DUR_90D), 980655561531304629);
    }

    function test_computePrice_5pct_90days() public pure {
        assertEq(_computePrice(true, RATE_5_PCT, DUR_90D), 987821380245000632);
    }

    function test_computePrice_10pct_90days() public pure {
        assertEq(_computePrice(true, RATE_10_PCT, DUR_90D), 975935828879793497);
    }

    function test_computePrice_5pct_365days() public pure {
        uint256 price = _computePrice(true, RATE_5_PCT, DUR_365D);
        assertGt(price, 0.9523e18);
        assertLt(price, 0.9524e18);
    }

    /// @notice Spearbit #17: the sell-side price rounds UP so the seller's receipt floor is
    ///         never lowered by a rounding wei.
    function test_computePrice_sellSideRoundsUp() public pure {
        // Non-exact division: sell-side sits exactly one wei above buy-side.
        assertEq(
            PriceLib.computePrice(false, RATE_8_PCT, DUR_90D), PriceLib.computePrice(true, RATE_8_PCT, DUR_90D) + 1
        );
        // Exact division (rate=0 -> par): both directions agree.
        assertEq(PriceLib.computePrice(false, 0, DUR_90D), WAD);
        // Floor division returns 0 at extreme rates; ceil keeps the seller floor at 1 wei.
        assertEq(PriceLib.computePrice(false, type(uint128).max, 1), 1);
    }

    /// @notice Spearbit #17: seller assets derived from the rounded-DOWN price fall one wei
    ///         short of the rounded-up floor and are rejected.
    function test_borrowerCeiling_floorPriceAssetsRejected() public {
        uint256 units = 1000e18;

        uint256 assetsAtFloorPrice = (units * _computePrice(true, RATE_8_PCT, DUR_90D)) / WAD;
        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(false, units, assetsAtFloorPrice, RATE_8_PCT, RATE_8_PCT, DUR_90D);

        uint256 assetsAtCeilPrice = (units * _computePrice(false, RATE_8_PCT, DUR_90D)) / WAD;
        harness.validatePrice(false, units, assetsAtCeilPrice, RATE_8_PCT, RATE_8_PCT, DUR_90D);
    }

    /* ═══════════════════════════════════════════════════════════════
       Rate limit scenarios via harness
       ═══════════════════════════════════════════════════════════════ */

    /// @dev Fee is folded into assets by the caller (production folds it into effPrice
    ///      via RouterLib.netSellerPrice): the borrower's post-fee receipt is assets - fee.
    function test_borrowerCeiling_feeExceedsLimit() public {
        uint256 units = 1000e18;
        uint256 price8 = _computePrice(false, RATE_8_PCT, DUR_90D);
        uint256 assets = (units * price8) / WAD;
        uint256 fee = (assets * 0.01e18) / WAD;
        uint256 netAssets = assets - fee;

        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(false, units, netAssets, RATE_8_PCT, RATE_8_PCT, DUR_90D);

        // Passes at 15%
        harness.validatePrice(false, units, netAssets, RATE_15_PCT, RATE_15_PCT, DUR_90D);
    }

    /// @dev Fee is folded into assets by the caller (production folds it into effPrice
    ///      via RouterLib.netBuyerPrice): the lender's post-fee cost is assets + fee.
    function test_lenderFloor_feeRejectsHighFloor() public {
        uint256 units = 1000e18;
        uint256 price8 = _computePrice(true, RATE_8_PCT, DUR_90D);
        uint256 assets = (units * price8) / WAD;
        uint256 fee = (assets * 0.01e18) / WAD;
        uint256 grossAssets = assets + fee;

        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(true, units, grossAssets, RATE_5_PCT, RATE_5_PCT, DUR_90D);

        // Passes at 2%
        harness.validatePrice(true, units, grossAssets, RATE_2_PCT, RATE_2_PCT, DUR_90D);
    }

    /// @dev Borrower picks min(policy, limit), lender picks max(policy, limit).
    function test_effectiveRateSelection() public {
        uint256 units = 1000e18;
        uint256 assets = (units * _computePrice(false, RATE_8_PCT, DUR_90D)) / WAD;

        harness.validatePrice(false, units, assets, RATE_12_PCT, RATE_8_PCT, DUR_90D);

        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(true, units, assets, RATE_12_PCT, RATE_8_PCT, DUR_90D);
    }

    /* ═══════════════════════════════════════════════════════════════
       Inverse roundtrip (pure math — no harness needed)
       ═══════════════════════════════════════════════════════════════ */

    function test_getOfferRemaining_roundtrip() public pure {
        uint256 remaining = 3000e18;
        uint256 sellerPrice = 980655561531304629;
        uint256 maxUnits = ((remaining + 1) * WAD - 1) / sellerPrice;

        assertEq(maxUnits, 3059178082175424000890);
        assertEq((maxUnits * sellerPrice) / WAD, remaining);
        assertGt(((maxUnits + 1) * sellerPrice) / WAD, remaining);
    }

    /* ═══════════════════════════════════════════════════════════════
       Full renewal walkthrough via harness
       ═══════════════════════════════════════════════════════════════ */

    function test_renewalWalkthrough() public {
        uint256 renewUnits = 5000e18;
        uint256 price = _computePrice(false, RATE_6_PCT, DUR_90D);
        uint256 sellerAssets = (renewUnits * price) / WAD;
        uint256 fee = (sellerAssets * 0.005e18) / WAD;
        uint256 netSellerAssets = sellerAssets - fee;

        // 0.5% fee on a 6% offer exceeds 6% AND 8% ceilings
        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(false, renewUnits, netSellerAssets, RATE_6_PCT, RATE_6_PCT, DUR_90D);

        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(false, renewUnits, netSellerAssets, RATE_8_PCT, RATE_8_PCT, DUR_90D);

        // Passes at 10%
        harness.validatePrice(false, renewUnits, netSellerAssets, RATE_10_PCT, RATE_10_PCT, DUR_90D);

        assertGt(sellerAssets, 4926e18);
        assertLt(sellerAssets, 4928e18);
    }

    /* ═══════════════════════════════════════════════════════════════
       Edge cases — computePrice boundary conditions
       ═══════════════════════════════════════════════════════════════ */

    function test_computePrice_zeroRateZeroDuration() public pure {
        assertEq(_computePrice(true, 0, 0), WAD, "rate=0, duration=0 gives par");
    }

    function test_computePrice_zeroRate() public pure {
        assertEq(_computePrice(true, 0, 365 days), WAD, "rate=0 gives par regardless of duration");
        assertEq(_computePrice(true, 0, 1), WAD, "rate=0, dur=1s gives par");
        assertEq(_computePrice(true, 0, 10 * 365 days), WAD, "rate=0, dur=10y gives par");
    }

    function test_computePrice_zeroDuration() public pure {
        assertEq(_computePrice(true, 1e18, 0), WAD, "any rate with dur=0 gives par");
        assertEq(_computePrice(true, type(uint128).max, 0), WAD, "large rate with dur=0 gives par");
    }

    function test_computePrice_largeRate() public pure {
        uint256 rate = type(uint128).max;
        uint256 price = _computePrice(true, rate, 1);
        assertEq(price, 0, "rate=uint128.max with dur=1 yields zero price via floor division");
    }

    function test_computePrice_largeRateNonZero() public pure {
        uint256 rate = 1e17;
        uint256 price = _computePrice(true, rate, 1);
        assertEq(price, 909090909090909090, "rate=1e17, dur=1 gives ~90.9% of par");
        assertGt(price, 0, "price is positive");
        assertLt(price, WAD, "price is below par");
    }

    function test_computePrice_maxProduct() public pure {
        uint256 maxProduct = type(uint256).max - WAD;
        uint256 price = _computePrice(true, maxProduct, 1);
        assertEq(price, 0, "extreme product yields zero price via floor division");
    }

    /* ═══════════════════════════════════════════════════════════════
       assets == 0 edge case
       ═══════════════════════════════════════════════════════════════ */

    function test_validatePrice_revertsOnZeroAssets() public {
        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(false, 1000e18, 0, 0, 0, DUR_90D);

        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(true, 1000e18, 0, 0, 0, DUR_90D);
    }

    /* ═══════════════════════════════════════════════════════════════
       Continuous fee gap — proves _validatePrice ignores pendingFee
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Midnight's MAX_CONTINUOUS_FEE = 0.01e18 / 365 days ≈ 317097919 (per second).
    ///         At max fee over 365 days: pendingFee = credit * 1% of face value.
    uint256 constant MAX_CONTINUOUS_FEE = uint256(0.01e18) / uint256(365 days);

    /// @notice Proves that _validatePrice ignores Midnight's continuous fee.
    /// @dev In Midnight, a lender's face value at maturity is `credit - pendingFee`,
    ///      where pendingFee = credit * continuousFee * timeToMaturity / WAD.
    ///      But _validatePrice checks against the full `units` (= credit),
    ///      so a lender can be renewed into a position whose effective yield (after
    ///      continuous fee) is below their configured floor rate.
    function test_lenderRateCheck_ignoresContinuousFee_exactLimit() public {
        uint256 units = 1000e18;
        uint256 limitRate = RATE_2_PCT; // 2% APR floor
        uint256 duration = DUR_365D;

        // Price the units at exactly the lender's limit rate
        uint256 price = _computePrice(true, RATE_2_PCT, DUR_365D);
        uint256 buyerAssets = (units * price) / WAD;

        // Current validation passes — it sees ~2% APR yield
        harness.validatePrice(true, units, buyerAssets, limitRate, limitRate, duration);

        // Midnight charges a continuous fee that reduces actual face value.
        // At max continuous fee over 365 days: pendingFee = credit * 1%.
        uint256 pendingFee = (units * MAX_CONTINUOUS_FEE * duration) / WAD;
        assertGt(pendingFee, 0, "continuous fee should be non-zero");

        // Lender's actual face value at maturity is units - pendingFee.
        // With the reduced face value, the check correctly rejects — but this
        // path is never taken in production, proving the gap.
        uint256 effectiveUnits = units - pendingFee;
        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(true, effectiveUnits, buyerAssets, limitRate, limitRate, duration);
    }

    /// @notice Realistic scenario: offer rate (6%) exceeds lender's limit (5%), so validation
    ///         passes. But Midnight's continuous fee eats ~1% of face value, bringing the
    ///         effective yield below 5% — yet the current check cannot detect this.
    function test_lenderRateCheck_passesAboveLimitButContinuousFeeDropsBelowLimit() public {
        uint256 units = 1000e18;
        uint256 limitRate = RATE_5_PCT; // 5% APR floor
        uint256 duration = DUR_365D;

        // Offer at 6% APR — above the 5% limit
        uint256 offerPrice = _computePrice(true, RATE_6_PCT, DUR_365D);
        uint256 buyerAssets = (units * offerPrice) / WAD;

        // Validation passes with full units (6% > 5%)
        harness.validatePrice(true, units, buyerAssets, limitRate, limitRate, duration);

        // Compute pendingFee at max continuous fee (~1% of face value per year)
        uint256 pendingFee = (units * MAX_CONTINUOUS_FEE * duration) / WAD;
        uint256 effectiveUnits = units - pendingFee;

        // BUG: validation still passes with the original units, even though
        // the lender will only receive effectiveUnits at maturity.
        harness.validatePrice(true, units, buyerAssets, limitRate, limitRate, duration);

        // With the correct effective face value, the check rejects — the lender is
        // paying 6% APR price but only getting ~5% worth of units back.
        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(true, effectiveUnits, buyerAssets, limitRate, limitRate, duration);
    }
}
