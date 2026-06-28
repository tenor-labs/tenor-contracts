// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ValidatePriceHarness} from "../helpers/ValidatePriceHarness.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";

/// @title ValidatePriceFuzzTest
/// @notice Fuzz tests for PriceLib.satisfiesRateLimit via the price-check harness.
contract ValidatePriceFuzzTest is Test {
    using UtilsLib for uint256;

    ValidatePriceHarness internal harness;

    /* ═══════ Bounds ═══════ */

    uint256 constant MAX_RATE = type(uint40).max; // ~1.1e12
    uint256 constant MAX_DURATION = 365 days * 10;
    uint256 constant MAX_UNITS = type(uint128).max;
    uint256 constant MAX_ASSETS = type(uint128).max;
    uint256 constant MAX_RATE_WIDE = type(uint128).max;

    function setUp() public {
        harness = new ValidatePriceHarness();
    }

    /* ═══════ Test-only helpers ═══════ */

    function _computePrice(bool isBuy, uint256 ratePerSecond, uint256 durationSeconds) internal pure returns (uint256) {
        uint256 denominator = WAD + ratePerSecond * durationSeconds;
        return isBuy ? WAD.mulDivDown(WAD, denominator) : WAD.mulDivUp(WAD, denominator);
    }

    function _computeEffectiveRate(bool isBuy, uint256 policyRate, uint256 limitRate) internal pure returns (uint256) {
        return
            isBuy
                ? (policyRate > limitRate ? policyRate : limitRate)
                : (policyRate < limitRate ? policyRate : limitRate);
    }

    /// @dev Largest duration keeping the computePrice denominator within mulDivUp's numerator
    ///      headroom (`WAD * WAD + denominator - 1` must fit in uint256) — see PRICE-1.
    function _maxSafeDuration(uint256 rate) internal pure returns (uint256) {
        return (type(uint256).max - WAD * WAD - WAD) / rate;
    }

    function _satisfies(
        bool isBuy,
        uint256 units,
        uint256 assets,
        uint256 limitRate,
        uint256 policyRate,
        uint256 duration
    ) internal view returns (bool) {
        try harness.validatePrice(isBuy, units, assets, limitRate, policyRate, duration) {
            return true;
        } catch {
            return false;
        }
    }

    /* ═══════════════════════════════════════════════════════════════
       computePrice — Price Properties
       ═══════════════════════════════════════════════════════════════ */

    function testFuzz_computePrice_monotoneDecreasingInRate(bool isBuy, uint256 rate1, uint256 rate2, uint256 duration)
        public
        pure
    {
        rate1 = bound(rate1, 0, MAX_RATE - 1);
        rate2 = bound(rate2, rate1 + 1, MAX_RATE);
        duration = bound(duration, 1, MAX_DURATION);

        uint256 price1 = _computePrice(isBuy, rate1, duration);
        uint256 price2 = _computePrice(isBuy, rate2, duration);

        assertGe(price1, price2, "rate2 > rate1 => price2 <= price1");
    }

    function testFuzz_computePrice_monotoneDecreasingInDuration(bool isBuy, uint256 rate, uint256 d1, uint256 d2)
        public
        pure
    {
        rate = bound(rate, 1, MAX_RATE);
        d1 = bound(d1, 0, MAX_DURATION - 1);
        d2 = bound(d2, d1 + 1, MAX_DURATION);

        uint256 price1 = _computePrice(isBuy, rate, d1);
        uint256 price2 = _computePrice(isBuy, rate, d2);

        assertGe(price1, price2, "d2 > d1 => price2 <= price1");
    }

    function testFuzz_computePrice_sellSideWithinOneWeiAbove(uint256 rate, uint256 duration) public pure {
        rate = bound(rate, 0, MAX_RATE);
        duration = bound(duration, 0, MAX_DURATION);

        uint256 down = _computePrice(true, rate, duration);
        uint256 up = _computePrice(false, rate, duration);

        assertGe(up, down, "sell-side >= buy-side");
        assertLe(up - down, 1, "sides differ by at most one wei");
        assertGe(up, 1, "sell-side price never zero");
        assertLe(up, WAD, "sell-side price never above par");
    }

    /* ═══════════════════════════════════════════════════════════════
       computeEffectiveRate — Rate Selection
       ═══════════════════════════════════════════════════════════════ */

    function testFuzz_computeEffectiveRate_divergentPaths(uint256 policy, uint256 limit) public pure {
        policy = bound(policy, 0, MAX_RATE);
        limit = bound(limit, 0, MAX_RATE);

        uint256 borrowerRate = _computeEffectiveRate(false, policy, limit);
        uint256 lenderRate = _computeEffectiveRate(true, policy, limit);

        assertTrue(borrowerRate == policy || borrowerRate == limit, "borrower returns an input");
        assertTrue(lenderRate == policy || lenderRate == limit, "lender returns an input");

        assertLe(borrowerRate, policy, "borrower <= policy");
        assertLe(borrowerRate, limit, "borrower <= limit");
        assertGe(lenderRate, policy, "lender >= policy");
        assertGe(lenderRate, limit, "lender >= limit");

        if (policy != limit) {
            assertTrue(borrowerRate != lenderRate, "divergent when policy != limit");
        }
    }

    /* ═══════════════════════════════════════════════════════════════
       _validatePrice — Borrower Ceiling (isBuy=false)
       ═══════════════════════════════════════════════════════════════ */

    function testFuzz_validatePrice_divergentRates(uint256 units, uint256 assets, uint256 duration) public view {
        units = bound(units, 1, 1e24);
        assets = bound(assets, 1, 1e24);
        duration = bound(duration, 1, MAX_DURATION);

        // policyRate=0, limitRate=MAX_RATE → borrower effectiveRate = min(0, MAX_RATE) = 0 → price = WAD
        // Check: assets * WAD >= units * WAD → assets >= units
        bool withMinRate = _satisfies(false, units, assets, MAX_RATE, 0, duration);
        bool atPar = assets >= units;
        assertEq(withMinRate, atPar, "borrower uses min -> policyRate=0 gives par pricing");

        // Lender: effectiveRate = max(0, MAX_RATE) = MAX_RATE → price ≈ 0
        uint256 price = _computePrice(true, MAX_RATE, duration);
        bool lenderResult = _satisfies(true, units, assets, MAX_RATE, 0, duration);
        if (assets * WAD <= units * price) {
            assertTrue(lenderResult, "lender passes when assets*WAD <= units*price");
        } else {
            assertFalse(lenderResult, "lender fails when assets*WAD > units*price");
        }
    }

    function testFuzz_validatePrice_borrower_exactBoundary(uint256 units, uint256 rate, uint256 duration) public view {
        units = bound(units, 1, 1e30);
        rate = bound(rate, 0, MAX_RATE);
        duration = bound(duration, 0, MAX_DURATION);

        uint256 price = _computePrice(false, rate, duration);
        uint256 netAssets = (units * price + WAD - 1) / WAD; // ceil

        vm.assume(netAssets > 0 && netAssets <= MAX_ASSETS);

        harness.validatePrice(false, units, netAssets, rate, rate, duration);
    }

    /* ═══════════════════════════════════════════════════════════════
       _validatePrice — Lender Floor (isBuy=true)
       ═══════════════════════════════════════════════════════════════ */

    function testFuzz_validatePrice_lender_parPriceRequiresAssetsLeUnits(uint256 units, uint256 assets) public view {
        units = bound(units, 1, MAX_UNITS);
        assets = bound(assets, 1, MAX_ASSETS);

        bool result = _satisfies(true, units, assets, 0, 0, 365 days);

        if (assets <= units) {
            assertTrue(result, "assets <= units => lender passes at par");
        } else {
            assertFalse(result, "assets > units => lender fails at par");
        }
    }

    function testFuzz_validatePrice_borrower_boundaryMinusOneFails(uint256 units, uint256 rate, uint256 duration)
        public
    {
        units = bound(units, 1, 1e24);
        rate = bound(rate, 1, MAX_RATE);
        duration = bound(duration, 1, MAX_DURATION);

        uint256 price = _computePrice(false, rate, duration);
        vm.assume(price > 0 && price < WAD);

        uint256 netAssets = (units * price + WAD - 1) / WAD;
        vm.assume(netAssets > 1);

        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(false, units, netAssets - 1, rate, rate, duration);
    }

    /* ═══════════════════════════════════════════════════════════════
       Borrower sell-side coverage: >= direction, isBuy branching
       ═══════════════════════════════════════════════════════════════ */

    function testFuzz_validatePrice_borrower_matchesFormula(
        uint256 units,
        uint256 assets,
        uint256 rate,
        uint256 duration
    ) public view {
        units = bound(units, 1, 1e18);
        assets = bound(assets, 1, 2e18);
        rate = bound(rate, 1, MAX_RATE);
        duration = bound(duration, 1, MAX_DURATION);

        uint256 price = _computePrice(false, rate, duration);
        vm.assume(price > 0);

        bool expected = assets * WAD >= units * price;
        bool actual = _satisfies(false, units, assets, rate, rate, duration);

        assertEq(actual, expected, "borrower result matches independent computation");
    }

    function testFuzz_validatePrice_isBuyBranchDiverges(uint256 units, uint256 rate, uint256 duration) public {
        units = bound(units, 2, 1e18);
        rate = bound(rate, 1, MAX_RATE);
        duration = bound(duration, 1, MAX_DURATION);

        uint256 price = _computePrice(false, rate, duration);
        vm.assume(price > 0 && price < WAD);

        uint256 netNeeded = (units * price + WAD - 1) / WAD;
        vm.assume(netNeeded > 0);
        uint256 assets = netNeeded + 1;
        vm.assume(assets <= MAX_ASSETS);

        // Borrower passes by construction: assets * WAD > netNeeded * WAD >= units * price
        harness.validatePrice(false, units, assets, rate, rate, duration);

        // Lender must fail: assets * WAD = (netNeeded + 1) * WAD > units * price
        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(true, units, assets, rate, rate, duration);
    }

    /* ═══════════════════════════════════════════════════════════════
       Monotonicity — higher rate more permissive for borrower
       ═══════════════════════════════════════════════════════════════ */

    function testFuzz_validatePrice_borrower_higherRateMorePermissive(
        uint256 units,
        uint256 assets,
        uint256 rate1,
        uint256 rate2,
        uint256 duration
    ) public view {
        units = bound(units, 1, 1e24);
        assets = bound(assets, 1, 1e24);
        rate1 = bound(rate1, 0, MAX_RATE - 1);
        rate2 = bound(rate2, rate1 + 1, MAX_RATE);
        duration = bound(duration, 1, MAX_DURATION);

        bool result1 = _satisfies(false, units, assets, rate1, rate1, duration);

        if (result1) {
            // rate2 > rate1 → lower price → must also pass
            harness.validatePrice(false, units, assets, rate2, rate2, duration);
        }
    }

    /* ═══════════════════════════════════════════════════════════════
       assets == 0 reverts
       ═══════════════════════════════════════════════════════════════ */

    function testFuzz_validatePrice_revertsOnZeroAssets(bool isBuy, uint256 units, uint256 rate, uint256 duration)
        public
    {
        units = bound(units, 1, MAX_UNITS);
        rate = bound(rate, 0, MAX_RATE);
        duration = bound(duration, 0, MAX_DURATION);

        vm.expectRevert(ValidatePriceHarness.InvalidOfferRate.selector);
        harness.validatePrice(isBuy, units, 0, rate, rate, duration);
    }

    /* ═══════════════════════════════════════════════════════════════
       Wide-rate fuzz tests (rates up to uint128)
       ═══════════════════════════════════════════════════════════════ */

    function testFuzz_computePrice_bounded_wideRate(bool isBuy, uint256 rate, uint256 duration) public pure {
        rate = bound(rate, 0, MAX_RATE_WIDE);
        if (rate > 0) {
            uint256 maxSafeDuration = _maxSafeDuration(rate);
            duration = bound(duration, 0, maxSafeDuration);
        } else {
            duration = bound(duration, 0, MAX_DURATION);
        }

        uint256 price = _computePrice(isBuy, rate, duration);
        assertLe(price, WAD, "price <= WAD");
    }

    function testFuzz_computePrice_monotoneDecreasingInRate_wideRate(
        bool isBuy,
        uint256 rate1,
        uint256 rate2,
        uint256 duration
    ) public pure {
        rate1 = bound(rate1, 0, MAX_RATE_WIDE - 1);
        rate2 = bound(rate2, rate1 + 1, MAX_RATE_WIDE);
        if (rate2 > 0) {
            uint256 maxSafeDuration = _maxSafeDuration(rate2);
            duration = bound(duration, 1, maxSafeDuration);
        } else {
            duration = bound(duration, 1, MAX_DURATION);
        }

        uint256 price1 = _computePrice(isBuy, rate1, duration);
        uint256 price2 = _computePrice(isBuy, rate2, duration);

        assertGe(price1, price2, "wide: rate2 > rate1 => price2 <= price1");
    }

    function testFuzz_computePrice_monotoneDecreasingInDuration_wideRate(
        bool isBuy,
        uint256 rate,
        uint256 d1,
        uint256 d2
    ) public pure {
        rate = bound(rate, 1, MAX_RATE_WIDE);
        uint256 maxSafeDuration = _maxSafeDuration(rate);
        d1 = bound(d1, 0, maxSafeDuration - 1);
        d2 = bound(d2, d1 + 1, maxSafeDuration);

        uint256 price1 = _computePrice(isBuy, rate, d1);
        uint256 price2 = _computePrice(isBuy, rate, d2);

        assertGe(price1, price2, "wide: d2 > d1 => price2 <= price1");
    }

    function testFuzz_validatePrice_borrower_exactBoundary_wideRate(uint256 units, uint256 rate, uint256 duration)
        public
        view
    {
        units = bound(units, 1, 1e24);
        rate = bound(rate, 0, MAX_RATE_WIDE);

        if (rate > 0) {
            uint256 maxSafeDuration = _maxSafeDuration(rate);
            duration = bound(duration, 0, maxSafeDuration);
        } else {
            duration = bound(duration, 0, MAX_DURATION);
        }

        uint256 price = _computePrice(false, rate, duration);
        uint256 netAssets = (units * price + WAD - 1) / WAD;

        vm.assume(netAssets > 0 && netAssets <= MAX_ASSETS);

        harness.validatePrice(false, units, netAssets, rate, rate, duration);
    }

    function testFuzz_computeEffectiveRate_wideRate(uint256 policy, uint256 limit) public pure {
        policy = bound(policy, 0, MAX_RATE_WIDE);
        limit = bound(limit, 0, MAX_RATE_WIDE);

        uint256 borrowerRate = _computeEffectiveRate(false, policy, limit);
        uint256 lenderRate = _computeEffectiveRate(true, policy, limit);

        assertLe(borrowerRate, policy, "wide: borrower <= policy");
        assertLe(borrowerRate, limit, "wide: borrower <= limit");
        assertGe(lenderRate, policy, "wide: lender >= policy");
        assertGe(lenderRate, limit, "wide: lender >= limit");

        if (policy != limit) {
            assertTrue(borrowerRate != lenderRate, "wide: divergent when policy != limit");
        }
    }
}
