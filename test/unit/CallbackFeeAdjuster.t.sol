// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {CallbackFeeAdjuster} from "../../src/router/CallbackFeeAdjuster.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";

/// @title CallbackFeeAdjusterTest
/// @notice Comprehensive unit tests for CallbackFeeAdjuster with independent fee math.
/// @dev Every expected value is computed from raw math — CallbackLib is never used for assertions.
///      Tests cover multi-decimal tokens, edge cases, and adversarial inputs.
contract CallbackFeeAdjusterTest is Test {
    CallbackFeeAdjuster internal adjuster;
    EcrecoverRatifier internal ecrecoverRatifier;

    // Decimal constants
    uint256 constant USDC_DECIMALS = 6;
    uint256 constant WETH_DECIMALS = 18;
    uint256 constant WBTC_DECIMALS = 8;

    // Realistic fee rates
    uint256 constant FEE_10BPS = 0.001e18; // 0.1%
    uint256 constant FEE_50BPS = 0.005e18; // 0.5%
    uint256 constant FEE_1PCT = 0.01e18; // 1% (max percentage fee)
    uint256 constant FEE_10PCT = 0.1e18; // 10% of interest
    uint256 constant FEE_50PCT = 0.5e18; // 50% of interest
    uint256 constant FEE_100PCT = 1e18; // 100% of interest

    // Max percentage fee as defined in CallbackLib
    uint256 constant MAX_PERCENTAGE_FEE_RATE = 0.01e18;

    function setUp() public {
        Midnight morphoMidnight = new Midnight();
        enableDefaultLltvs(morphoMidnight);
        adjuster = new CallbackFeeAdjuster(address(morphoMidnight));
        ecrecoverRatifier = new EcrecoverRatifier(address(morphoMidnight));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Helpers — independent math (NO CallbackLib)
    // ═══════════════════════════════════════════════════════════════

    /// @dev mulDivDown: (x * y) / d, rounded down
    function _mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    /// @dev mulDivUp: (x * y + d - 1) / d, rounded up
    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }

    /// @dev zeroFloorSub: max(x - y, 0)
    function _zeroFloorSub(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x - y : 0;
    }

    /// @dev Independent seller fee computation from tick (matches CallbackLib.sellerFeeFromTick).
    ///      sellerEffPrice = price * WAD / (WAD + x)  with x = (WAD - price) * feeRate / WAD.
    ///      budget = mulDivUp(units, effPrice, WAD).  fee = zeroFloorSub(assets, budget).
    function _sellerFeeIndependent(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal
        pure
        returns (uint256)
    {
        if (feeRate == 0) return 0;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 x = _mulDivDown(WAD - price, feeRate, WAD);
        uint256 effPrice = _mulDivUp(price, WAD, WAD + x);
        uint256 budget = _mulDivUp(units, effPrice, WAD);
        return _zeroFloorSub(assets, budget);
    }

    /// @dev Independent buyer fee computation from tick (matches CallbackLib.buyerFeeFromTick).
    ///      buyerEffPrice = price * WAD / (WAD - x)  with x = (WAD - price) * feeRate / WAD.
    ///      required = mulDivDown(units, effPrice, WAD).  fee = zeroFloorSub(required, assets).
    function _buyerFeeIndependent(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal
        pure
        returns (uint256)
    {
        if (feeRate == 0) return 0;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 x = _mulDivDown(WAD - price, feeRate, WAD);
        uint256 effPrice = _mulDivDown(price, WAD, WAD - x);
        uint256 required = _mulDivDown(units, effPrice, WAD);
        return _zeroFloorSub(required, assets);
    }

    /// @dev Independent percentage fee computation
    function _percentageFeeIndependent(uint256 assets, uint256 feeRate) internal pure returns (uint256) {
        return _mulDivDown(assets, feeRate, WAD);
    }

    /// @dev Build a minimal Offer with only tick and buy flag populated.
    function _makeOffer(uint256 tick, bool buy) internal view returns (Offer memory) {
        CollateralParams[] memory collaterals = new CollateralParams[](0);
        Market memory obl = Market({
            chainId: block.chainid,
            midnight: address(0),
            loanToken: address(0),
            collateralParams: collaterals,
            maturity: 0,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        return Offer({
            market: obl,
            buy: buy,
            maker: address(0),
            start: 0,
            expiry: 0,
            tick: tick,
            group: bytes32(0),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    /// @dev Encode adjuster data for INTEREST formula
    function _encodeInterest(uint256 feeRate) internal pure returns (bytes memory) {
        return abi.encode(feeRate, CallbackFeeAdjuster.FeeFormula.INTEREST);
    }

    /// @dev Encode adjuster data for PERCENTAGE formula
    function _encodePercentage(uint256 feeRate) internal pure returns (bytes memory) {
        return abi.encode(feeRate, CallbackFeeAdjuster.FeeFormula.PERCENTAGE);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTEREST formula — seller side (buy offer)
    // ═══════════════════════════════════════════════════════════════

    function test_interestSeller_18dec_moderateTick() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "seller fee 18dec moderate tick");
        assertGt(actual, 0, "fee must be nonzero for nonzero feeRate and discount");
    }

    function test_interestSeller_6dec_1000USDC() public view {
        uint256 tick = 2308;
        uint256 feeRate = FEE_50PCT;
        uint256 units = 1000e6;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "seller fee 6dec 1000 USDC");
    }

    function test_interestSeller_8dec_halfWBTC() public view {
        uint256 tick = 1812;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 5e7;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "seller fee 8dec 0.5 WBTC");
    }

    function test_interestSeller_extremeLowTick() public view {
        uint256 tick = 8;
        uint256 feeRate = FEE_50PCT;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "seller fee extreme low tick");
        assertGt(actual, 0, "fee nonzero at deep discount");
    }

    function test_interestSeller_maxTick() public view {
        uint256 tick = MAX_TICK;
        uint256 feeRate = FEE_100PCT;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "seller fee at max tick");
    }

    function test_interestSeller_zeroFeeRate() public view {
        uint256 tick = 2776;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 actual = adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(0));

        assertEq(actual, 0, "zero fee rate => zero fee");
    }

    function test_interestSeller_dustUnits_18dec() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 1;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "seller fee dust units 18dec");
    }

    function test_interestSeller_dustUnits_6dec() public view {
        uint256 tick = 2308;
        uint256 feeRate = FEE_50PCT;
        uint256 units = 1;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "seller fee dust units 6dec");
    }

    function test_interestSeller_fullInterestFee() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_100PCT;
        uint256 units = 10e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "seller fee 100% interest");
        assertGt(actual, 0, "100% fee is nonzero");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTEREST formula — buyer side (sell offer)
    // ═══════════════════════════════════════════════════════════════

    function test_interestBuyer_18dec_moderateTick() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "buyer fee 18dec moderate tick");
        assertGt(actual, 0, "fee must be nonzero");
    }

    function test_interestBuyer_6dec_1000USDC() public view {
        uint256 tick = 2308;
        uint256 feeRate = FEE_50PCT;
        uint256 units = 1000e6;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "buyer fee 6dec 1000 USDC");
    }

    function test_interestBuyer_8dec_halfWBTC() public view {
        uint256 tick = 1812;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 5e7;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "buyer fee 8dec 0.5 WBTC");
    }

    function test_interestBuyer_extremeLowTick() public view {
        uint256 tick = 1;
        uint256 feeRate = FEE_50PCT;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "buyer fee extreme low tick");
    }

    function test_interestBuyer_maxTick() public view {
        uint256 tick = MAX_TICK;
        uint256 feeRate = FEE_100PCT;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "buyer fee at max tick");
    }

    function test_interestBuyer_zeroFeeRate() public view {
        uint256 tick = 2776;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 actual = adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(0));

        assertEq(actual, 0, "zero fee rate => zero buyer fee");
    }

    function test_interestBuyer_dustUnits() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 1;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "buyer fee dust units");
    }

    /// @notice Buyer fee with 100% interest fee rate (note: price=0 + feeRate=WAD reverts per
    ///         CallbackLib invariant `feeShareOfInterest < WAD`, so we use a non-zero price).
    function test_interestBuyer_fullInterestFee() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_100PCT;
        uint256 units = 10e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "buyer fee 100% interest");
        assertGt(actual, 0, "100% fee is nonzero for buyer");
    }

    // ═══════════════════════════════════════════════════════════════
    //  PERCENTAGE formula
    // ═══════════════════════════════════════════════════════════════

    function test_percentage_sellOffer_buyerAssets_18dec() public view {
        uint256 feeRate = FEE_10BPS;
        uint256 buyerAssets = 1e18;

        uint256 expected = _percentageFeeIndependent(buyerAssets, feeRate);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(495, false), true, buyerAssets, 0, 0, _encodePercentage(feeRate));

        assertEq(actual, expected, "percentage fee sell offer 18dec");
        assertEq(actual, _mulDivDown(1e18, FEE_10BPS, WAD), "percentage cross-check");
    }

    function test_percentage_buyOffer_sellerAssets_18dec() public view {
        uint256 feeRate = FEE_10BPS;
        uint256 sellerAssets = 1e18;

        uint256 expected = _percentageFeeIndependent(sellerAssets, feeRate);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(495, true), false, 0, sellerAssets, 0, _encodePercentage(feeRate));

        assertEq(actual, expected, "percentage fee buy offer 18dec");
    }

    function test_percentage_6dec_1000USDC() public view {
        uint256 feeRate = FEE_1PCT;
        uint256 takerAssets = 1000e6;

        uint256 expected = _percentageFeeIndependent(takerAssets, feeRate);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(495, false), true, takerAssets, 0, 0, _encodePercentage(feeRate));

        assertEq(actual, expected, "percentage fee 6dec USDC");
        assertEq(actual, 10e6, "1% of 1000 USDC = 10 USDC");
    }

    function test_percentage_8dec_halfWBTC() public view {
        uint256 feeRate = FEE_50BPS;
        uint256 takerAssets = 5e7;

        uint256 expected = _percentageFeeIndependent(takerAssets, feeRate);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(300, false), true, takerAssets, 0, 0, _encodePercentage(feeRate));

        assertEq(actual, expected, "percentage fee 8dec WBTC");
    }

    function test_percentage_zeroFeeRate() public view {
        uint256 actual = adjuster.afterDispatch(_makeOffer(495, false), true, 1e18, 0, 0, _encodePercentage(0));

        assertEq(actual, 0, "zero percentage fee rate => zero fee");
    }

    function test_percentage_dustAssets() public view {
        uint256 feeRate = FEE_1PCT;
        uint256 assets = 1;

        uint256 expected = _percentageFeeIndependent(assets, feeRate);
        uint256 actual = adjuster.afterDispatch(_makeOffer(495, false), true, assets, 0, 0, _encodePercentage(feeRate));

        assertEq(actual, expected, "percentage fee on dust");
        assertEq(actual, 0, "dust rounds to zero fee");
    }

    function test_percentage_maxRate() public view {
        uint256 feeRate = MAX_PERCENTAGE_FEE_RATE;
        uint256 assets = 100e18;

        uint256 expected = _percentageFeeIndependent(assets, feeRate);
        uint256 actual = adjuster.afterDispatch(_makeOffer(495, false), true, assets, 0, 0, _encodePercentage(feeRate));

        assertEq(actual, expected, "percentage fee at max rate");
        assertEq(actual, 1e18, "1% of 100 tokens");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Offer direction routing — verify buy/sell selects correct side
    // ═══════════════════════════════════════════════════════════════

    function test_direction_buyOffer_interest_usesSeller() public view {
        uint256 tick = 2308;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 1000e6;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 sellerAssets = _mulDivDown(units, price, WAD);
        uint256 buyerAssets = 999e6;

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, sellerAssets);
        uint256 actual = adjuster.afterDispatch(
            _makeOffer(tick, true), false, buyerAssets, sellerAssets, units, _encodeInterest(feeRate)
        );

        assertEq(actual, expected, "buy offer routes to seller fee");
    }

    function test_direction_sellOffer_interest_usesBuyer() public view {
        uint256 tick = 2308;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 1000e6;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 buyerAssets = _mulDivDown(units, price, WAD);
        uint256 sellerAssets = 999e6;

        uint256 expected = _buyerFeeIndependent(tick, feeRate, units, buyerAssets);
        uint256 actual = adjuster.afterDispatch(
            _makeOffer(tick, false), true, buyerAssets, sellerAssets, units, _encodeInterest(feeRate)
        );

        assertEq(actual, expected, "sell offer routes to buyer fee");
    }

    function test_direction_buyOffer_percentage_usesSellerAssets() public view {
        uint256 feeRate = FEE_10BPS;
        uint256 sellerAssets = 500e18;
        uint256 buyerAssets = 123e18;

        uint256 expected = _percentageFeeIndependent(sellerAssets, feeRate);
        uint256 actual = adjuster.afterDispatch(
            _makeOffer(400, true), false, buyerAssets, sellerAssets, 0, _encodePercentage(feeRate)
        );

        assertEq(actual, expected, "buy offer percentage uses sellerAssets");
    }

    function test_direction_sellOffer_percentage_usesBuyerAssets() public view {
        uint256 feeRate = FEE_10BPS;
        uint256 buyerAssets = 500e18;
        uint256 sellerAssets = 123e18;

        uint256 expected = _percentageFeeIndependent(buyerAssets, feeRate);
        uint256 actual = adjuster.afterDispatch(
            _makeOffer(400, false), true, buyerAssets, sellerAssets, 0, _encodePercentage(feeRate)
        );

        assertEq(actual, expected, "sell offer percentage uses buyerAssets");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Invariants — fee is never negative / zero-floor sub
    // ═══════════════════════════════════════════════════════════════

    function test_sellerFee_zeroFloorSub_assetsBelowBudget() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 1e18;
        uint256 assets = units;

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "seller fee zeroFloorSub");
        assertGt(actual, 0, "seller fee with extra assets");
    }

    function test_buyerFee_zeroFloorSub_excessAssets() public view {
        uint256 tick = MAX_TICK;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 1e18;
        uint256 assets = units * 2;

        uint256 expected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "buyer fee zeroFloorSub");
        assertEq(actual, 0, "buyer fee zero when overpaid");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Adversarial — revert conditions
    // ═══════════════════════════════════════════════════════════════

    /// @notice feeRate > WAD should revert for INTEREST formula (InvalidFeeConfig)
    function test_revert_interestFeeRateExceedsWAD() public {
        uint256 feeRate = WAD + 1;
        vm.expectRevert();
        adjuster.afterDispatch(_makeOffer(495, true), false, 0, 1e18, 1e18, _encodeInterest(feeRate));
    }

    /// @notice Percentage fee reverts when rate exceeds MAX_PERCENTAGE_FEE_RATE
    function test_revert_percentageFeeRateExceedsMax() public {
        uint256 feeRate = MAX_PERCENTAGE_FEE_RATE + 1;
        vm.expectRevert();
        adjuster.afterDispatch(_makeOffer(495, false), true, 1e18, 0, 0, _encodePercentage(feeRate));
    }

    function test_revert_tickExceedsMax_seller() public {
        vm.expectRevert();
        adjuster.afterDispatch(_makeOffer(MAX_TICK + 1, true), false, 0, 1e18, 1e18, _encodeInterest(FEE_10PCT));
    }

    function test_revert_tickExceedsMax_buyer() public {
        vm.expectRevert();
        adjuster.afterDispatch(_makeOffer(MAX_TICK + 1, false), true, 1e18, 0, 1e18, _encodeInterest(FEE_10PCT));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Adversarial — zero / extreme inputs
    // ═══════════════════════════════════════════════════════════════

    function test_zeroUnits_interestSeller() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_10PCT;
        uint256 assets = 100e18;

        uint256 expected = _sellerFeeIndependent(tick, feeRate, 0, assets);
        uint256 actual = adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, 0, _encodeInterest(feeRate));

        assertEq(actual, expected, "zero units seller");
        assertEq(actual, assets, "zero units: fee equals full assets");
    }

    function test_zeroUnits_interestBuyer() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_10PCT;
        uint256 assets = 100e18;

        uint256 expected = _buyerFeeIndependent(tick, feeRate, 0, assets);
        uint256 actual = adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, 0, _encodeInterest(feeRate));

        assertEq(actual, expected, "zero units buyer");
        assertEq(actual, 0, "zero units buyer: fee is zero");
    }

    function test_zeroAssets_interestSeller() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 1e18;

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, 0);
        uint256 actual = adjuster.afterDispatch(_makeOffer(tick, true), false, 0, 0, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "zero assets seller");
        assertEq(actual, 0, "zero seller assets: fee is zero");
    }

    function test_zeroAssets_interestBuyer() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 1e18;

        uint256 expected = _buyerFeeIndependent(tick, feeRate, units, 0);
        uint256 actual = adjuster.afterDispatch(_makeOffer(tick, false), true, 0, 0, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "zero assets buyer");
        assertGt(actual, 0, "zero buyer assets: fee equals full required");
    }

    function test_zeroAssets_percentage() public view {
        uint256 actual = adjuster.afterDispatch(_makeOffer(495, false), true, 0, 0, 0, _encodePercentage(FEE_10BPS));

        assertEq(actual, 0, "zero assets percentage fee");
    }

    function test_largeAssets_percentage() public view {
        uint256 assets = 1e58;
        uint256 feeRate = FEE_10BPS;

        uint256 expected = _percentageFeeIndependent(assets, feeRate);
        uint256 actual = adjuster.afterDispatch(_makeOffer(495, false), true, assets, 0, 0, _encodePercentage(feeRate));

        assertEq(actual, expected, "large assets percentage fee");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Symmetry / determinism
    // ═══════════════════════════════════════════════════════════════

    function test_afterDispatch_deterministic() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_50PCT;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);
        Offer memory offer = _makeOffer(tick, true);
        bytes memory data = _encodeInterest(feeRate);

        uint256 result1 = adjuster.afterDispatch(offer, false, 0, assets, units, data);
        uint256 result2 = adjuster.afterDispatch(offer, false, 0, assets, units, data);

        assertEq(result1, result2, "afterDispatch is deterministic (pure)");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Monotonicity
    // ═══════════════════════════════════════════════════════════════

    function test_sellerFee_monotonic_in_feeRate() public view {
        uint256 tick = 2308;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 fee10 =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(FEE_10PCT));
        uint256 fee50 =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(FEE_50PCT));
        uint256 fee100 =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(FEE_100PCT));

        assertLe(fee10, fee50, "10% <= 50% seller fee");
        assertLe(fee50, fee100, "50% <= 100% seller fee");
    }

    function test_buyerFee_monotonic_in_feeRate() public view {
        uint256 tick = 2308;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 fee10 =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(FEE_10PCT));
        uint256 fee50 =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(FEE_50PCT));
        uint256 fee100 =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(FEE_100PCT));

        assertLe(fee10, fee50, "10% <= 50% buyer fee");
        assertLe(fee50, fee100, "50% <= 100% buyer fee");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Tick 0 — highest discount (price near zero)
    // ═══════════════════════════════════════════════════════════════

    function test_interestSeller_tickZero() public view {
        uint256 tick = 0;
        uint256 feeRate = FEE_50PCT;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "seller fee tick=0");
    }

    function test_interestBuyer_tickZero() public view {
        uint256 tick = 0;
        uint256 feeRate = FEE_50PCT;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "buyer fee tick=0");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Multi-decimal exhaustive
    // ═══════════════════════════════════════════════════════════════

    function test_multiDec_18dec_10WETH_both_sides() public view {
        uint256 tick = 3296;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 10e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 sellerExpected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 sellerActual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));
        assertEq(sellerActual, sellerExpected, "18dec seller 10 WETH");

        uint256 buyerExpected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 buyerActual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));
        assertEq(buyerActual, buyerExpected, "18dec buyer 10 WETH");
    }

    function test_multiDec_6dec_50000USDC_both_sides() public view {
        uint256 tick = 3792;
        uint256 feeRate = FEE_50PCT;
        uint256 units = 50_000e6;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 sellerExpected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 sellerActual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));
        assertEq(sellerActual, sellerExpected, "6dec seller 50000 USDC");

        uint256 buyerExpected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 buyerActual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));
        assertEq(buyerActual, buyerExpected, "6dec buyer 50000 USDC");
    }

    function test_multiDec_8dec_2WBTC_both_sides() public view {
        uint256 tick = 2800;
        uint256 feeRate = FEE_100PCT;
        uint256 units = 2e8;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 sellerExpected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 sellerActual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));
        assertEq(sellerActual, sellerExpected, "8dec seller 2 WBTC");

        uint256 buyerExpected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 buyerActual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));
        assertEq(buyerActual, buyerExpected, "8dec buyer 2 WBTC");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Concrete percentage calculations
    // ═══════════════════════════════════════════════════════════════

    function test_percentage_concrete_calculation() public view {
        uint256 assets = 10_000e6;
        uint256 feeRate = FEE_50BPS;

        uint256 actual = adjuster.afterDispatch(_makeOffer(400, false), true, assets, 0, 0, _encodePercentage(feeRate));

        assertEq(actual, 50e6, "0.5% of 10000 USDC = 50 USDC");
    }

    function test_percentage_concrete_18dec() public view {
        uint256 assets = 1e18;
        uint256 feeRate = FEE_10BPS;

        uint256 actual = adjuster.afterDispatch(_makeOffer(400, false), true, assets, 0, 0, _encodePercentage(feeRate));

        assertEq(actual, 1e15, "0.1% of 1 WETH = 0.001 WETH");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Fuzz — independent math matches adjuster
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_sellerFee_matches_independent(uint256 tick, uint256 feeRate, uint256 units) public view {
        tick = bound(tick, 0, MAX_TICK);
        feeRate = bound(feeRate, 1, WAD);
        units = bound(units, 1, 1e30);

        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _sellerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, true), false, 0, assets, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "fuzz seller fee");
    }

    /// @dev Skips the (tick == 0, feeRate == WAD) corner where buyerEffectivePrice reverts.
    function testFuzz_buyerFee_matches_independent(uint256 tick, uint256 feeRate, uint256 units) public view {
        tick = bound(tick, 0, MAX_TICK);
        feeRate = bound(feeRate, 1, WAD);
        units = bound(units, 1, 1e30);

        uint256 price = TickLib.tickToPrice(tick);
        // Skip unreachable corner: price == 0 AND feeRate == WAD triggers InvalidFeeConfig.
        if (price == 0 && feeRate == WAD) return;
        uint256 assets = _mulDivDown(units, price, WAD);

        uint256 expected = _buyerFeeIndependent(tick, feeRate, units, assets);
        uint256 actual =
            adjuster.afterDispatch(_makeOffer(tick, false), true, assets, 0, units, _encodeInterest(feeRate));

        assertEq(actual, expected, "fuzz buyer fee");
    }

    function testFuzz_percentageFee_matches_independent(uint256 assets, uint256 feeRate) public view {
        feeRate = bound(feeRate, 0, MAX_PERCENTAGE_FEE_RATE);
        assets = bound(assets, 0, 1e60);

        uint256 expected = _percentageFeeIndependent(assets, feeRate);
        uint256 actual = adjuster.afterDispatch(_makeOffer(400, false), true, assets, 0, 0, _encodePercentage(feeRate));

        assertEq(actual, expected, "fuzz percentage fee");
    }

    // ═══════════════════════════════════════════════════════════════
    //  afterDispatch — fee side driven by the initiatorIsBuyer arg
    //  (a pure function of that flag; the router always passes the taker
    //   side, !offer.buy, but the adjuster unit is exercised both ways).
    // ═══════════════════════════════════════════════════════════════

    /// @notice BUY offer, initiator is the maker (initiatorIsBuyer = true): the INTEREST fee is computed
    ///         on the buyer (maker) side, not the seller (taker) side.
    function test_afterDispatch_interest_buyOffer_makerInitiator_usesBuyerSide() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 buyerAssets = _mulDivDown(units, price, WAD);
        uint256 sellerAssets = buyerAssets - 1; // settlement-fee gap; must not be used here

        uint256 expectedBuyerFee = _buyerFeeIndependent(tick, feeRate, units, buyerAssets);
        uint256 actual = adjuster.afterDispatch(
            _makeOffer(tick, true), true, buyerAssets, sellerAssets, units, _encodeInterest(feeRate)
        );

        assertEq(actual, expectedBuyerFee, "maker-initiator buy offer charges buyer-side fee");

        // And it differs from the taker case (initiatorIsBuyer = false) on the same offer/amounts.
        uint256 takerCase = adjuster.afterDispatch(
            _makeOffer(tick, true), false, buyerAssets, sellerAssets, units, _encodeInterest(feeRate)
        );
        assertEq(
            takerCase, _sellerFeeIndependent(tick, feeRate, units, sellerAssets), "taker case charges seller-side fee"
        );
        assertTrue(actual != takerCase, "initiatorIsBuyer flips the charged side");
    }

    /// @notice SELL offer, initiator is the maker (initiatorIsBuyer = false): the INTEREST fee is
    ///         computed on the seller (maker) side, not the buyer (taker) side.
    function test_afterDispatch_interest_sellOffer_makerInitiator_usesSellerSide() public view {
        uint256 tick = 2776;
        uint256 feeRate = FEE_10PCT;
        uint256 units = 1e18;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 sellerAssets = _mulDivDown(units, price, WAD);
        uint256 buyerAssets = sellerAssets + 1; // settlement-fee gap; must not be used here

        uint256 expectedSellerFee = _sellerFeeIndependent(tick, feeRate, units, sellerAssets);
        uint256 actual = adjuster.afterDispatch(
            _makeOffer(tick, false), false, buyerAssets, sellerAssets, units, _encodeInterest(feeRate)
        );

        assertEq(actual, expectedSellerFee, "maker-initiator sell offer charges seller-side fee");

        uint256 takerCase = adjuster.afterDispatch(
            _makeOffer(tick, false), true, buyerAssets, sellerAssets, units, _encodeInterest(feeRate)
        );
        assertEq(
            takerCase, _buyerFeeIndependent(tick, feeRate, units, buyerAssets), "taker case charges buyer-side fee"
        );
        assertTrue(actual != takerCase, "initiatorIsBuyer flips the charged side");
    }

    /// @notice PERCENTAGE fee also follows initiatorIsBuyer: maker-initiator picks its own side's assets.
    function test_afterDispatch_percentage_makerInitiator_usesInitiatorSide() public view {
        uint256 feeRate = FEE_50BPS;
        uint256 buyerAssets = 1_000e18;
        uint256 sellerAssets = 990e18;

        // BUY offer, maker initiator → buyer side.
        uint256 buyOfferFee = adjuster.afterDispatch(
            _makeOffer(400, true), true, buyerAssets, sellerAssets, 0, _encodePercentage(feeRate)
        );
        assertEq(buyOfferFee, _percentageFeeIndependent(buyerAssets, feeRate), "maker-initiator buy uses buyer assets");

        // SELL offer, maker initiator → seller side.
        uint256 sellOfferFee = adjuster.afterDispatch(
            _makeOffer(400, false), false, buyerAssets, sellerAssets, 0, _encodePercentage(feeRate)
        );
        assertEq(
            sellOfferFee, _percentageFeeIndependent(sellerAssets, feeRate), "maker-initiator sell uses seller assets"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  beforeDispatch — cap sizing behaviour
    // ═══════════════════════════════════════════════════════════════

    /// @notice beforeDispatch on FILL_UNITS passes remainingBudget through unchanged.
    function test_beforeDispatch_units_passthrough() public view {
        uint256 remaining = 777e18;
        uint256 result = adjuster.beforeDispatch(_makeOffer(495, false), 2, remaining, _encodeInterest(FEE_10PCT));
        assertEq(result, remaining, "market units passthrough");
    }

    /// @notice Zero remainingBudget always returns zero.
    function test_beforeDispatch_zeroRemaining_returnsZero() public view {
        uint256 result = adjuster.beforeDispatch(_makeOffer(495, false), 0, 0, _encodeInterest(FEE_10PCT));
        assertEq(result, 0, "zero remaining => zero units");
    }

    /// @dev Stub Midnight.settlementFee() to return 0 so beforeDispatch can run without a touched
    ///      market. The dominant-price math is price-level, independent of Midnight state.
    function _stubSettlementFeeZero() internal {
        _stubSettlementFee(0);
    }

    /// @dev Stub Midnight.settlementFee() to return an arbitrary value (for fuzzing the
    ///      `B = offerPrice + settlementFee` axis the tick scale alone can't reach).
    function _stubSettlementFee(uint256 value) internal {
        vm.mockCall(
            address(adjuster.MORPHO_MIDNIGHT()),
            abi.encodeWithSelector(Midnight.settlementFee.selector),
            abi.encode(value)
        );
    }

    /// @notice Sell offer + FILL_SELLER_ASSETS: adjuster does not touch seller side → plain inversion.
    /// @dev The adjuster branches to `_plainInversion` which calls into `TakeAmountsLib`, which
    ///      requires a created market; skip by checking only the "affects fill" branch through
    ///      the zero-feeRate path on the *affected* dimension (covered separately below).
    function test_beforeDispatch_units_passthrough_percentage() public view {
        uint256 remaining = 123e18;
        uint256 result = adjuster.beforeDispatch(_makeOffer(495, false), 2, remaining, _encodePercentage(FEE_50BPS));
        assertEq(result, remaining, "market units passthrough (pct)");
    }

    /// @notice INTEREST + sell offer + FILL_BUYER_ASSETS: net-price inversion, no Midnight state.
    ///         With settlementFee stubbed to 0, netBuyerPrice = max(offerPrice, buyerEffPrice) = buyerEffPrice.
    function test_beforeDispatch_interest_sellOffer_buyerAssets_netPrice() public {
        _stubSettlementFeeZero();
        uint256 tick = 2776;
        uint256 remaining = 1e18;
        uint256 feeRate = FEE_10PCT;

        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, false), 0, remaining, _encodeInterest(feeRate));

        // Reconstruct net price: max(offerPrice + 0, buyerEffPrice).
        uint256 price = TickLib.tickToPrice(tick);
        uint256 x = _mulDivDown(WAD - price, feeRate, WAD);
        uint256 buyerEffPrice = _mulDivDown(price, WAD, WAD - x);
        uint256 netPrice = buyerEffPrice > price ? buyerEffPrice : price;
        assertEq(units, _mulDivDown(remaining, WAD, netPrice), "units = remaining * WAD / netBuyerPrice");

        // The effective buyerAssets (raw + fee) must not overshoot remaining.
        uint256 rawBuyerAssets = _mulDivUp(units, price, WAD);
        uint256 buyerFee = _buyerFeeIndependent(tick, feeRate, units, rawBuyerAssets);
        assertLe(rawBuyerAssets + buyerFee, remaining, "effective buyerAssets <= remaining");
    }

    /// @notice INTEREST + buy offer + FILL_SELLER_ASSETS: net-price inversion, no Midnight state.
    ///         With settlementFee stubbed to 0, netSellerPrice = min(offerPrice, sellerEffPrice) = sellerEffPrice.
    function test_beforeDispatch_interest_buyOffer_sellerAssets_netPrice() public {
        _stubSettlementFeeZero();
        uint256 tick = 2776;
        uint256 remaining = 1e18;
        uint256 feeRate = FEE_10PCT;

        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, true), 1, remaining, _encodeInterest(feeRate));

        uint256 price = TickLib.tickToPrice(tick);
        uint256 x = _mulDivDown(WAD - price, feeRate, WAD);
        uint256 sellerEffPrice = _mulDivUp(price, WAD, WAD + x);
        uint256 netPrice = sellerEffPrice < price ? sellerEffPrice : price;
        assertEq(units, _mulDivDown(remaining, WAD, netPrice), "units = remaining * WAD / netSellerPrice");

        // The effective sellerAssets (raw - fee, conservative) must not overshoot remaining.
        uint256 rawSellerAssets = _mulDivDown(units, price, WAD);
        uint256 effective = _mulDivDown(units, sellerEffPrice, WAD);
        assertLe(effective, remaining, "effective sellerAssets <= remaining");
        assertLe(rawSellerAssets, remaining + _mulDivDown(remaining, feeRate, WAD), "raw bounded");
    }

    /// @notice INTEREST + buy offer + FILL_BUYER_ASSETS (maker-initiator buyer side): the fee-aware
    ///         net-price inversion runs on the maker's own side.
    function test_beforeDispatch_interest_buyOffer_buyerAssets_makerSide_netPrice() public {
        _stubSettlementFeeZero();
        uint256 tick = 2776;
        uint256 remaining = 1e18;
        uint256 feeRate = FEE_10PCT;

        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, true), 0, remaining, _encodeInterest(feeRate));

        // netBuyerPrice = max(offerPrice + 0, buyerEffPrice) = buyerEffPrice.
        uint256 price = TickLib.tickToPrice(tick);
        uint256 x = _mulDivDown(WAD - price, feeRate, WAD);
        uint256 buyerEffPrice = _mulDivDown(price, WAD, WAD - x);
        uint256 netPrice = buyerEffPrice > price ? buyerEffPrice : price;
        assertEq(units, _mulDivDown(remaining, WAD, netPrice), "units = remaining * WAD / netBuyerPrice");

        // Fee-aware sizing is strictly tighter than the raw midnight-price inversion.
        assertLt(units, _mulDivDown(remaining, WAD, price), "maker buyer-side sizing tighter than raw");
    }

    /// @notice INTEREST + sell offer + FILL_SELLER_ASSETS (maker-initiator seller side): fee-aware
    ///         net-price inversion runs on the maker's own side.
    function test_beforeDispatch_interest_sellOffer_sellerAssets_makerSide_netPrice() public {
        _stubSettlementFeeZero();
        uint256 tick = 2776;
        uint256 remaining = 1e18;
        uint256 feeRate = FEE_10PCT;

        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, false), 1, remaining, _encodeInterest(feeRate));

        // netSellerPrice = min(offerPrice - 0, sellerEffPrice) = sellerEffPrice.
        uint256 price = TickLib.tickToPrice(tick);
        uint256 x = _mulDivDown(WAD - price, feeRate, WAD);
        uint256 sellerEffPrice = _mulDivUp(price, WAD, WAD + x);
        uint256 netPrice = sellerEffPrice < price ? sellerEffPrice : price;
        assertEq(units, _mulDivDown(remaining, WAD, netPrice), "units = remaining * WAD / netSellerPrice");

        // sellerEffPrice < offerPrice, so fee-aware sizing yields MORE units than the raw inversion.
        assertGt(units, _mulDivDown(remaining, WAD, price), "maker seller-side sizing looser than raw");
    }

    /// @notice PERCENTAGE + sell offer + FILL_BUYER_ASSETS: closed-form inversion, no Midnight state.
    function test_beforeDispatch_percentage_sellOffer_buyerAssets_inversion() public {
        _stubSettlementFeeZero();
        uint256 tick = 2776;
        uint256 remaining = 1e18;
        uint256 feeRate = FEE_50BPS;

        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, false), 0, remaining, _encodePercentage(feeRate));

        uint256 price = TickLib.tickToPrice(tick);
        uint256 rawMax = _mulDivUp(remaining + 1, WAD, WAD + feeRate) - 1;
        assertEq(units, _mulDivDown(rawMax, WAD, price), "units = floor(rawMax * WAD / price)");

        // Effective buyerAssets bounded by remaining.
        uint256 rawBuyerAssets = _mulDivUp(units, price, WAD);
        uint256 effective = rawBuyerAssets + _mulDivDown(rawBuyerAssets, feeRate, WAD);
        assertLe(effective, remaining, "effective buyerAssets <= remaining (percentage)");
    }

    /// @notice Fuzz: beforeDispatch on the SELL + FILL_BUYER_ASSETS percentage path must return
    ///         the global-max units satisfying `raw + fee ≤ remaining`. Fuzzes tick, feeRate,
    ///         settlementFee, and remaining — `settlementFee` shifts `B = offerPrice + settlementFee`
    ///         continuously, exercising rounding boundaries the discrete tick scale can't reach.
    function testFuzz_beforeDispatch_percentage_sellOffer_buyerAssets_neverOvershoots(
        uint256 tick,
        uint256 feeRate,
        uint256 settlementFee,
        uint256 remaining
    ) public {
        tick = bound(tick, 0, MAX_TICK);
        feeRate = bound(feeRate, 1, MAX_PERCENTAGE_FEE_RATE);
        remaining = bound(remaining, 1, 1e36);
        uint256 price = TickLib.tickToPrice(tick);
        // Bond price + settlementFee ≤ WAD is Midnight's invariant on the buyer side.
        settlementFee = bound(settlementFee, 0, WAD - price);
        _stubSettlementFee(settlementFee);

        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, false), 0, remaining, _encodePercentage(feeRate));

        uint256 buyerPriceMidnight = price + settlementFee;
        if (buyerPriceMidnight == 0) {
            assertEq(units, type(uint128).max, "B==0 => uint128.max (take all)");
            return;
        }
        uint256 raw = _mulDivUp(units, buyerPriceMidnight, WAD);
        uint256 fee = _percentageFeeIndependent(raw, feeRate);
        assertLe(raw + fee, remaining, "effective buyerAssets must not overshoot remaining");

        uint256 rawNext = _mulDivUp(units + 1, buyerPriceMidnight, WAD);
        uint256 feeNext = _percentageFeeIndependent(rawNext, feeRate);
        assertGt(rawNext + feeNext, remaining, "units+1 must overshoot remaining (global max)");
    }

    /// @notice White-box fuzz of the closed-form math over the *continuous* `B` range
    ///         `[1, WAD]`, independent of Midnight state. Proves the global-max property over
    ///         input regions the discrete tick scale skips.
    function testFuzz_percentageInverse_pureMath_globalMax(uint256 B, uint256 feeRate, uint256 R) public pure {
        B = bound(B, 1, WAD);
        feeRate = bound(feeRate, 1, MAX_PERCENTAGE_FEE_RATE);
        R = bound(R, 1, 1e36);

        uint256 rawMax = _mulDivUp(R + 1, WAD, WAD + feeRate) - 1;
        uint256 units = _mulDivDown(rawMax, WAD, B);

        uint256 raw = _mulDivUp(units, B, WAD);
        uint256 fee = _percentageFeeIndependent(raw, feeRate);
        assertLe(raw + fee, R, "effective <= R");

        uint256 rawNext = _mulDivUp(units + 1, B, WAD);
        uint256 feeNext = _percentageFeeIndependent(rawNext, feeRate);
        assertGt(rawNext + feeNext, R, "units+1 overshoots (global max)");
    }

    /// @notice The *prior* closed-form (`floor(R*WAD / ceil(B*(WAD+F)/WAD))`) overshoots
    ///         `remaining` by 1 wei for at least one parameter triple in a small search space;
    ///         the current `beforeDispatch` must return a safe cap on that exact triple.
    function test_beforeDispatch_percentage_sellOffer_buyerAssets_priorClosedFormOvershoots() public {
        _stubSettlementFeeZero();

        uint256 foundTick;
        uint256 foundFeeRate;
        uint256 foundRemaining;
        bool found;
        for (uint256 t = 1; t <= 100 && !found; t++) {
            uint256 price = TickLib.tickToPrice(t);
            for (
                uint256 f = MAX_PERCENTAGE_FEE_RATE / 100;
                f <= MAX_PERCENTAGE_FEE_RATE && !found;
                f += MAX_PERCENTAGE_FEE_RATE / 100
            ) {
                uint256 inflatedPrice = _mulDivUp(price, WAD + f, WAD);
                if (inflatedPrice == 0) continue;
                for (uint256 r = 1e18 - 100; r <= 1e18 + 100 && !found; r++) {
                    uint256 u = _mulDivDown(r, WAD, inflatedPrice);
                    uint256 raw = _mulDivUp(u, price, WAD);
                    uint256 fee = _percentageFeeIndependent(raw, f);
                    if (raw + fee > r) {
                        foundTick = t;
                        foundFeeRate = f;
                        foundRemaining = r;
                        found = true;
                    }
                }
            }
        }
        assertTrue(found, "search should find a prior-closed-form overshoot triple");

        uint256 units =
            adjuster.beforeDispatch(_makeOffer(foundTick, false), 0, foundRemaining, _encodePercentage(foundFeeRate));
        uint256 priceFound = TickLib.tickToPrice(foundTick);
        uint256 rawFix = _mulDivUp(units, priceFound, WAD);
        uint256 feeFix = _percentageFeeIndependent(rawFix, foundFeeRate);
        assertLe(rawFix + feeFix, foundRemaining, "current effective <= remaining");
    }

    /// @notice PERCENTAGE + buy offer + FILL_SELLER_ASSETS: closed-form inversion, no Midnight state.
    function test_beforeDispatch_percentage_buyOffer_sellerAssets_inversion() public {
        _stubSettlementFeeZero();
        uint256 tick = 2776;
        uint256 remaining = 1e18;
        uint256 feeRate = FEE_50BPS;

        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, true), 1, remaining, _encodePercentage(feeRate));

        uint256 price = TickLib.tickToPrice(tick);
        uint256 rawMax = _mulDivDown(remaining, WAD, WAD - feeRate);
        assertEq(units, _mulDivUp(rawMax + 1, WAD, price) - 1, "units = mulDivUp(rawMax+1, WAD, price) - 1");

        uint256 rawSellerAssets = _mulDivDown(units, price, WAD);
        uint256 effective = rawSellerAssets - _mulDivDown(rawSellerAssets, feeRate, WAD);
        assertLe(effective, remaining, "effective sellerAssets <= remaining (percentage)");
    }

    /// @notice Fuzz: beforeDispatch on the BUY + FILL_SELLER_ASSETS percentage path must return
    ///         the global-max units satisfying `effective ≤ remaining`. Mirrors the buyer-side
    ///         fuzz across the full `(tick, feeRate, settlementFee, remaining)` space.
    function testFuzz_beforeDispatch_percentage_buyOffer_sellerAssets_neverOvershoots(
        uint256 tick,
        uint256 feeRate,
        uint256 settlementFee,
        uint256 remaining
    ) public {
        tick = bound(tick, 0, MAX_TICK);
        feeRate = bound(feeRate, 1, MAX_PERCENTAGE_FEE_RATE);
        remaining = bound(remaining, 1, 1e36);
        uint256 price = TickLib.tickToPrice(tick);
        // For buy offers, sellerPriceMidnight = zeroFloorSub(offerPrice, settlementFee).
        settlementFee = bound(settlementFee, 0, price);
        _stubSettlementFee(settlementFee);

        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, true), 1, remaining, _encodePercentage(feeRate));

        uint256 sellerPriceMidnight = price - settlementFee;
        if (sellerPriceMidnight == 0) {
            assertEq(units, 0, "P==0 => 0 (take none)");
            return;
        }
        uint256 raw = _mulDivDown(units, sellerPriceMidnight, WAD);
        uint256 fee = _percentageFeeIndependent(raw, feeRate);
        uint256 effective = raw - fee;
        assertLe(effective, remaining, "effective sellerAssets must not overshoot remaining");

        uint256 rawNext = _mulDivDown(units + 1, sellerPriceMidnight, WAD);
        uint256 feeNext = _percentageFeeIndependent(rawNext, feeRate);
        assertGt(rawNext - feeNext, remaining, "units+1 must overshoot remaining (global max)");
    }

    /// @notice White-box fuzz of the seller-side closed-form math over the *continuous* `P`
    ///         range, independent of Midnight state.
    function testFuzz_percentageInverseSeller_pureMath_globalMax(uint256 P, uint256 feeRate, uint256 R) public pure {
        P = bound(P, 1, WAD);
        feeRate = bound(feeRate, 1, MAX_PERCENTAGE_FEE_RATE);
        R = bound(R, 1, 1e36);

        uint256 rawMax = _mulDivDown(R, WAD, WAD - feeRate);
        uint256 units = _mulDivUp(rawMax + 1, WAD, P) - 1;

        uint256 raw = _mulDivDown(units, P, WAD);
        uint256 fee = _percentageFeeIndependent(raw, feeRate);
        assertLe(raw - fee, R, "effective <= R");

        uint256 rawNext = _mulDivDown(units + 1, P, WAD);
        uint256 feeNext = _percentageFeeIndependent(rawNext, feeRate);
        assertGt(rawNext - feeNext, R, "units+1 overshoots (global max)");
    }

    /// @dev Asserts beforeDispatch returns the global-max units on the SELL+FILL_BUYER_ASSETS
    ///      percentage path for a given (tick, feeRate, remaining). Caller is responsible for
    ///      stubbing settlementFee via `_stubSettlementFee` (or `_stubSettlementFeeZero`).
    function _assertBuyerSideGlobalMax(uint256 tick, uint256 feeRate, uint256 remaining, uint256 settlementFee)
        internal
    {
        _stubSettlementFee(settlementFee);
        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, false), 0, remaining, _encodePercentage(feeRate));
        uint256 B = TickLib.tickToPrice(tick) + settlementFee;
        if (B == 0) {
            // Free bonds (buyer pays 0/unit): take all capacity, not the asset-denominated budget value.
            assertEq(units, type(uint128).max, "B==0 => uint128.max (take all)");
            return;
        }
        uint256 raw = _mulDivUp(units, B, WAD);
        uint256 fee = _percentageFeeIndependent(raw, feeRate);
        assertLe(raw + fee, remaining, "effective <= remaining");
        uint256 rawNext = _mulDivUp(units + 1, B, WAD);
        uint256 feeNext = _percentageFeeIndependent(rawNext, feeRate);
        assertGt(rawNext + feeNext, remaining, "units+1 overshoots (global max)");
    }

    /// @dev Mirror of `_assertBuyerSideGlobalMax` for the BUY+FILL_SELLER_ASSETS path.
    function _assertSellerSideGlobalMax(uint256 tick, uint256 feeRate, uint256 remaining, uint256 settlementFee)
        internal
    {
        _stubSettlementFee(settlementFee);
        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, true), 1, remaining, _encodePercentage(feeRate));
        uint256 price = TickLib.tickToPrice(tick);
        uint256 P = settlementFee >= price ? 0 : price - settlementFee;
        if (P == 0) {
            // Seller receives 0/unit: pointless fill, take none.
            assertEq(units, 0, "P==0 => 0 (take none)");
            return;
        }
        uint256 raw = _mulDivDown(units, P, WAD);
        uint256 fee = _percentageFeeIndependent(raw, feeRate);
        assertLe(raw - fee, remaining, "effective <= remaining");
        uint256 rawNext = _mulDivDown(units + 1, P, WAD);
        uint256 feeNext = _percentageFeeIndependent(rawNext, feeRate);
        assertGt(rawNext - feeNext, remaining, "units+1 overshoots (global max)");
    }

    /// @notice Directed boundary: SELL+FILL_BUYER_ASSETS at `remaining ∈ {1, WAD-1, WAD, WAD+1}`,
    ///         tick=1 (near par — the loop-iteration worst case the prior fix-attempt found),
    ///         feeRate at the production cap.
    function test_beforeDispatch_percentage_sellOffer_buyerAssets_boundaries() public {
        uint256 tick = 1;
        uint256 feeRate = MAX_PERCENTAGE_FEE_RATE;
        _assertBuyerSideGlobalMax(tick, feeRate, 1, 0);
        _assertBuyerSideGlobalMax(tick, feeRate, WAD - 1, 0);
        _assertBuyerSideGlobalMax(tick, feeRate, WAD, 0);
        _assertBuyerSideGlobalMax(tick, feeRate, WAD + 1, 0);
    }

    /// @notice Directed boundary mirror for BUY+FILL_SELLER_ASSETS.
    function test_beforeDispatch_percentage_buyOffer_sellerAssets_boundaries() public {
        uint256 tick = 1;
        uint256 feeRate = MAX_PERCENTAGE_FEE_RATE;
        _assertSellerSideGlobalMax(tick, feeRate, 1, 0);
        _assertSellerSideGlobalMax(tick, feeRate, WAD - 1, 0);
        _assertSellerSideGlobalMax(tick, feeRate, WAD, 0);
        _assertSellerSideGlobalMax(tick, feeRate, WAD + 1, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Zero net price sentinels (degenerate fills)
    //  buyer-taker pays 0/unit  → take all capacity  → type(uint128).max
    //  seller-taker gets 0/unit → pointless fill     → 0
    //  An asset-denominated budget fallback would be dimensionally wrong as a unit cap.
    // ═══════════════════════════════════════════════════════════════

    /// @notice INTEREST + buy offer + FILL_SELLER_ASSETS, settlementFee == offerPrice (the only
    ///         executable point: Midnight's `take` underflows when settlementFee > offerPrice).
    ///         netSellerPrice == 0 ⇒ cap is "take none".
    function test_beforeDispatch_interest_buyOffer_sellerAssets_zeroNetPrice_returnsZero() public {
        uint256 tick = 2776;
        uint256 price = TickLib.tickToPrice(tick);
        _stubSettlementFee(price); // settlementFee == offerPrice ⇒ netSellerPrice == 0
        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, true), 1, 1e18, _encodeInterest(FEE_10PCT));
        assertEq(units, 0, "seller netSellerPrice==0 => take none");
    }

    /// @notice INTEREST + sell offer + FILL_BUYER_ASSETS, offerPrice == 0 (tick 0/1) and zero
    ///         settlementFee ⇒ netBuyerPrice == 0 (free bonds) ⇒ cap is "take all capacity".
    function test_beforeDispatch_interest_sellOffer_buyerAssets_zeroNetPrice_returnsMax() public {
        _stubSettlementFeeZero();
        assertEq(TickLib.tickToPrice(0), 0, "precondition: tick 0 prices at 0");
        uint256 units = adjuster.beforeDispatch(_makeOffer(0, false), 0, 1e18, _encodeInterest(FEE_10PCT));
        assertEq(units, type(uint128).max, "buyer netBuyerPrice==0 => take all");
    }

    /// @notice PERCENTAGE mirror: seller side, sellerPriceMidnight == 0 ⇒ 0.
    function test_beforeDispatch_percentage_buyOffer_sellerAssets_zeroPrice_returnsZero() public {
        uint256 tick = 2776;
        uint256 price = TickLib.tickToPrice(tick);
        _stubSettlementFee(price); // zeroFloorSub(offerPrice, settlementFee) == 0
        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, true), 1, 1e18, _encodePercentage(FEE_50BPS));
        assertEq(units, 0, "seller sellerPriceMidnight==0 => take none");
    }

    /// @notice PERCENTAGE mirror: buyer side, buyerPriceMidnight == 0 ⇒ type(uint128).max.
    function test_beforeDispatch_percentage_sellOffer_buyerAssets_zeroPrice_returnsMax() public {
        _stubSettlementFeeZero();
        uint256 units = adjuster.beforeDispatch(_makeOffer(0, false), 0, 1e18, _encodePercentage(FEE_50BPS));
        assertEq(units, type(uint128).max, "buyer buyerPriceMidnight==0 => take all");
    }

    // ═══════════════════════════════════════════════════════════════
    //  First-party maker-seller (SELL offer + FILL_SELLER_ASSETS)
    //  Midnight's seller-receipt forward rounds UP for SELL offers and the maker pays no settlement
    //  fee, so the cap must invert offerPrice with a floor inverse, not (offerPrice - settlementFee)
    //  with the ceil-forward inverse used for BUY (taker-seller) fills.
    // ═══════════════════════════════════════════════════════════════

    /// @notice The prior seller closed-form (ceil-forward inverse of offerPrice) overshoots `remaining`
    ///         on the SELL maker-seller path for at least one (tick, feeRate, remaining) triple; the
    ///         fixed `beforeDispatch` must return a safe cap on that exact triple (settlementFee == 0).
    function test_beforeDispatch_percentage_sellOffer_sellerAssets_priorClosedFormOvershoots() public {
        _stubSettlementFeeZero();

        uint256 foundTick;
        uint256 foundFeeRate;
        uint256 foundRemaining;
        bool found;
        for (uint256 t = 1; t <= 100 && !found; t++) {
            uint256 price = TickLib.tickToPrice(t);
            if (price == 0) continue;
            for (
                uint256 f = MAX_PERCENTAGE_FEE_RATE / 100;
                f <= MAX_PERCENTAGE_FEE_RATE && !found;
                f += MAX_PERCENTAGE_FEE_RATE / 100
            ) {
                for (uint256 r = 1e18 - 100; r <= 1e18 + 100 && !found; r++) {
                    // Prior formula: u = mulDivUp(rawMax + 1, WAD, price) - 1 (ceil-forward inverse).
                    uint256 rawMax = _mulDivDown(r, WAD, WAD - f);
                    uint256 u = _mulDivUp(rawMax + 1, WAD, price) - 1;
                    uint256 raw = _mulDivUp(u, price, WAD); // SELL seller forward rounds up
                    uint256 fee = _percentageFeeIndependent(raw, f);
                    if (raw - fee > r) {
                        foundTick = t;
                        foundFeeRate = f;
                        foundRemaining = r;
                        found = true;
                    }
                }
            }
        }
        assertTrue(found, "search should find a prior-closed-form overshoot triple");

        uint256 units =
            adjuster.beforeDispatch(_makeOffer(foundTick, false), 1, foundRemaining, _encodePercentage(foundFeeRate));
        uint256 priceFound = TickLib.tickToPrice(foundTick);
        uint256 rawFix = _mulDivUp(units, priceFound, WAD);
        uint256 feeFix = _percentageFeeIndependent(rawFix, foundFeeRate);
        assertLe(rawFix - feeFix, foundRemaining, "current effective <= remaining");
    }

    /// @notice Fuzz: SELL maker-seller percentage path is the global max satisfying `effective <= remaining`,
    ///         where the maker receives offerPrice/unit (no settlement fee) with up-rounding.
    function testFuzz_beforeDispatch_percentage_sellOffer_sellerAssets_neverOvershoots(
        uint256 tick,
        uint256 feeRate,
        uint256 settlementFee,
        uint256 remaining
    ) public {
        tick = bound(tick, 0, MAX_TICK);
        feeRate = bound(feeRate, 1, MAX_PERCENTAGE_FEE_RATE);
        remaining = bound(remaining, 1, 1e36);
        uint256 price = TickLib.tickToPrice(tick);
        settlementFee = bound(settlementFee, 0, price);
        _stubSettlementFee(settlementFee);

        // Maker-seller pays no settlement fee: the binding price is offerPrice, not offerPrice - settlementFee.
        uint256 units = adjuster.beforeDispatch(_makeOffer(tick, false), 1, remaining, _encodePercentage(feeRate));

        if (price == 0) {
            assertEq(units, type(uint128).max, "offerPrice==0 => take all");
            return;
        }
        uint256 raw = _mulDivUp(units, price, WAD);
        uint256 fee = _percentageFeeIndependent(raw, feeRate);
        assertLe(raw - fee, remaining, "effective sellerAssets must not overshoot remaining");

        uint256 rawNext = _mulDivUp(units + 1, price, WAD);
        uint256 feeNext = _percentageFeeIndependent(rawNext, feeRate);
        assertGt(rawNext - feeNext, remaining, "units+1 must overshoot remaining (global max)");
    }

    /// @notice PERCENTAGE: SELL maker-seller cap ignores settlementFee (only taker-seller, BUY offers, pays it).
    function test_beforeDispatch_percentage_sellOffer_sellerAssets_ignoresSettlementFee() public {
        uint256 tick = 2776;
        uint256 remaining = 1e18;
        uint256 feeRate = FEE_50BPS;

        _stubSettlementFee(TickLib.tickToPrice(tick) / 4);
        uint256 withFee = adjuster.beforeDispatch(_makeOffer(tick, false), 1, remaining, _encodePercentage(feeRate));
        _stubSettlementFeeZero();
        uint256 withoutFee = adjuster.beforeDispatch(_makeOffer(tick, false), 1, remaining, _encodePercentage(feeRate));

        assertEq(withFee, withoutFee, "maker-seller cap independent of settlementFee");
    }

    /// @notice INTEREST: SELL maker-seller cap ignores settlementFee (settlement fee is taker-only).
    function test_beforeDispatch_interest_sellOffer_sellerAssets_ignoresSettlementFee() public {
        uint256 tick = 2776;
        uint256 remaining = 1e18;
        uint256 feeRate = FEE_10PCT;

        _stubSettlementFee(TickLib.tickToPrice(tick) / 4);
        uint256 withFee = adjuster.beforeDispatch(_makeOffer(tick, false), 1, remaining, _encodeInterest(feeRate));
        _stubSettlementFeeZero();
        uint256 withoutFee = adjuster.beforeDispatch(_makeOffer(tick, false), 1, remaining, _encodeInterest(feeRate));

        assertEq(withFee, withoutFee, "maker-seller cap independent of settlementFee");
    }

    /// @notice INTEREST: BUY taker-seller still includes settlementFee (orientation preserved for taker fills).
    function test_beforeDispatch_interest_buyOffer_sellerAssets_includesSettlementFee() public {
        uint256 tick = 2776;
        uint256 remaining = 1e18;
        uint256 feeRate = FEE_10PCT;

        _stubSettlementFee(TickLib.tickToPrice(tick) / 4);
        uint256 withFee = adjuster.beforeDispatch(_makeOffer(tick, true), 1, remaining, _encodeInterest(feeRate));
        _stubSettlementFeeZero();
        uint256 withoutFee = adjuster.beforeDispatch(_makeOffer(tick, true), 1, remaining, _encodeInterest(feeRate));

        assertGt(withFee, withoutFee, "taker-seller settlementFee lowers receipt => more units fit");
    }

    /// @notice PERCENTAGE: SELL maker-seller with offerPrice == 0 (free bonds) ⇒ budget not binding ⇒ take all.
    function test_beforeDispatch_percentage_sellOffer_sellerAssets_zeroPrice_returnsMax() public {
        _stubSettlementFeeZero();
        assertEq(TickLib.tickToPrice(0), 0, "precondition: tick 0 prices at 0");
        uint256 units = adjuster.beforeDispatch(_makeOffer(0, false), 1, 1e18, _encodePercentage(FEE_50BPS));
        assertEq(units, type(uint128).max, "maker-seller offerPrice==0 => take all");
    }

    /// @notice INTEREST mirror: SELL maker-seller with offerPrice == 0 ⇒ budget not binding ⇒ take all
    ///         (the maker receives nothing per unit; the seller-assets budget never binds).
    function test_beforeDispatch_interest_sellOffer_sellerAssets_zeroPrice_returnsMax() public {
        _stubSettlementFeeZero();
        uint256 units = adjuster.beforeDispatch(_makeOffer(0, false), 1, 1e18, _encodeInterest(FEE_10PCT));
        assertEq(units, type(uint128).max, "maker-seller offerPrice==0 => take all");
    }
}
