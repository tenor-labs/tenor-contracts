// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {WAD, maxSettlementFee, CBP} from "@midnight/libraries/ConstantsLib.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {RouterLib} from "../../src/libraries/RouterLib.sol";
import {TakeMathLib} from "../../src/libraries/TakeMathLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

/// @title Harness exposing RouterLib.budgetToUnits (the router's no-adjuster fill-sizing cap)
contract RouterLibHarness {
    function budgetToUnits(
        Midnight morphoMidnight,
        bytes32 marketId,
        Offer calldata offer,
        uint8 fillIndex,
        uint256 remainingBudget
    ) external view returns (uint256) {
        return RouterLib.budgetToUnits(morphoMidnight, marketId, offer, fillIndex, remainingBudget);
    }

    function assetsToSellerUnits(Midnight morphoMidnight, bytes32 marketId, Offer calldata offer, uint256 assets)
        external
        view
        returns (uint256)
    {
        return TakeMathLib.assetsToSellerUnits(IMidnight(address(morphoMidnight)), marketId, offer, assets);
    }
}

/// @title RouterLib.budgetToUnits returns the exact tight cap
/// @notice A tight cap u for budget R satisfies:  forward(u) <= R  AND  forward(u+1) > R — i.e. it
///         fits the budget (never overshoots) and is the LARGEST such units count (never under-fills).
///         budgetToUnits previously delegated to TakeAmountsLib, which PR morpho-org/midnight#952
///         documents as returning "not necessarily the biggest" units: for BUY offers its `mulDivUp`
///         inverse of Midnight's `mulDivDown` forward returned the SMALLEST preimage, so the router
///         under-filled (e.g. 9 units where 17 fit at tick=2500, R=1). It is now computed with the
///         same exact floor/ceil inverses as TakeMathLib.getOfferRemaining (`mulDiv{Down,Up}Inverse`).
///         These tests assert tightness in both directions for BUY and SELL offers.
contract RouterLibBudgetTightnessTest is Test {
    using UtilsLib for uint256;

    Midnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    RouterLibHarness internal harness;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    Market internal market;
    bytes32 internal marketId;

    function setUp() public {
        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Col", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(10e36);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        midnight.setFeeSetter(address(this)); // lets the fee-regime fuzz set a settlement fee
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        harness = new RouterLibHarness();

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        marketId = IdLib.toId(market);

        _seedMarket(100e18);
    }

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        return Signature({v: v, r: r, s: s});
    }

    function _seedMarket(uint256 seedAmount) internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey("seedBorrower");
        address seedLender = makeAddr("seedLender");

        loanToken.mint(seedLender, type(uint128).max);
        collateralToken.mint(seedBorrower, type(uint128).max);

        MidnightSupplyCollateralCallback setupCb = new MidnightSupplyCollateralCallback(address(midnight));

        vm.startPrank(seedBorrower);
        collateralToken.approve(address(setupCb), type(uint256).max);
        midnight.setIsAuthorized(address(setupCb), true, seedBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedBorrower);
        vm.stopPrank();

        vm.prank(seedLender);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = seedAmount * 10;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: seedAmount, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory seedOffer = Offer({
            market: market,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256("seed"),
            callback: address(setupCb),
            callbackData: cbData,
            receiverIfMakerIsSeller: seedBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(seedOffer, seedBorrowerSK);
        bytes32 root = HashLib.hashOffer(seedOffer);

        vm.prank(seedLender);
        midnight.take(
            seedOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            seedAmount,
            seedLender,
            address(0),
            address(0),
            ""
        );
    }

    function _buyOffer(uint16 tick) internal returns (Offer memory) {
        return Offer({
            market: market,
            buy: true,
            maker: makeAddr("buyMaker"),
            start: 0,
            expiry: type(uint256).max,
            tick: tick,
            group: keccak256("buy"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _sellOffer(uint16 tick) internal returns (Offer memory) {
        return Offer({
            market: market,
            buy: false,
            maker: makeAddr("sellMaker"),
            start: 0,
            expiry: type(uint256).max,
            tick: tick,
            group: keccak256("sell"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: makeAddr("sellMaker"),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    /// @notice REGRESSION: budgetToUnits returns the exact TIGHT cap — the largest units count whose
    ///         forward image still fits the budget: forward(units) <= R AND forward(units+1) > R, for
    ///         every budget R. Before the fix, BUY offers UNDER-FILLED: the `mulDivUp` inverse returned
    ///         the smallest preimage instead of the largest (e.g. 9 units where 17 fit at tick=2500,
    ///         R=1). See morpho-org/midnight#952. SELL offers were already tight. `forward(units) <= R`
    ///         also certifies the cap never overshoots the budget.
    function test_buyOffer_budgetToUnits_isTight() public {
        uint16[5] memory ticks = [uint16(100), 1000, 2500, 4000, 5028];
        uint256 checked;
        for (uint256 t = 0; t < ticks.length; t++) {
            checked += _assertTight(ticks[t], true);
        }
        console2.log("BUY tight (maximal, no-overshoot) checks passed:", checked);
    }

    function test_sellOffer_budgetToUnits_isTight() public {
        uint16[5] memory ticks = [uint16(100), 1000, 2500, 4000, 5028];
        uint256 checked;
        for (uint256 t = 0; t < ticks.length; t++) {
            checked += _assertTight(ticks[t], false);
        }
        console2.log("SELL tight (maximal, no-overshoot) checks passed:", checked);
    }

    /// @notice price == 0 (very low tick rounds to 0 at the 1e-6 WAD step) makes the fill cost nothing
    ///         in that dimension, so the budget is not binding. budgetToUnits must return uint128.max
    ///         (capped, non-binding) rather than reverting — the old TakeAmountsLib delegation divided
    ///         by the zero price and reverted.
    function test_budgetToUnits_priceZero_returnsUnboundedNotRevert() public {
        uint16 tick = 1;
        assertEq(TickLib.tickToPrice(tick), 0, "precondition: price rounds to 0 at this tick");

        // BUY offer, buyer-asset budget: buyerPrice == offerPrice == 0
        uint256 capBuy = harness.budgetToUnits(midnight, marketId, _buyOffer(tick), RouterLib.FILL_BUYER_ASSETS, 1000);
        assertEq(capBuy, type(uint128).max, "BUY price 0 => non-binding cap, no revert");

        // SELL offer, seller-asset budget: sellerPrice == offerPrice == 0
        uint256 capSell =
            harness.budgetToUnits(midnight, marketId, _sellOffer(tick), RouterLib.FILL_SELLER_ASSETS, 1000);
        assertEq(capSell, type(uint128).max, "SELL price 0 => non-binding cap, no revert");
    }

    /* FUZZ */

    /// @notice Fuzz the tight-cap invariant for budgetToUnits over arbitrary tick, budget, offer
    ///         direction, fill dimension, AND settlement-fee regime. The settlement fee shifts the
    ///         fee-inclusive price the cap divides by (Midnight.sol:360-362) — tightness must hold
    ///         either way. Forward rounding is mulDivDown for buy offers, mulDivUp for sell.
    function testFuzz_budgetToUnits_tight(uint256 tickRaw, uint256 budget, bool isBuy, uint256 dimSel, uint256 feeSeed)
        public
    {
        uint256 fee = _setSettlementFee(feeSeed);
        uint16 tick = uint16(bound(tickRaw, 0, MAX_TICK)); // [0, MAX_TICK]
        // Router budgets are <= type(uint128).max (MaxFillTooLarge in TenorRouter._execute), but the shared
        // library stays robust beyond it; the upper end exercises uint128 saturation + the mulDivDownInverse guard.
        budget = bound(budget, 1, type(uint256).max / WAD - 1);
        uint8 fillIndex = uint8(bound(dimSel, 0, 2)); // BUYER_ASSETS | SELLER_ASSETS | UNITS

        Offer memory offer = isBuy ? _buyOffer(tick) : _sellOffer(tick);
        uint256 units = harness.budgetToUnits(midnight, marketId, offer, fillIndex, budget);

        if (fillIndex == RouterLib.FILL_UNITS) {
            assertEq(units, budget, "FILL_UNITS returns the budget unchanged");
            return;
        }
        bool buyerDim = fillIndex == RouterLib.FILL_BUYER_ASSETS;
        _assertTightCap(units, _dimensionPrice(tick, fee, isBuy, buyerDim), budget, isBuy);
    }

    /// @notice Same invariant for TakeMathLib.assetsToSellerUnits (seller-receipt cap), across fee regimes.
    function testFuzz_assetsToSellerUnits_tight(uint256 tickRaw, uint256 assets, bool isBuy, uint256 feeSeed) public {
        uint256 fee = _setSettlementFee(feeSeed);
        uint16 tick = uint16(bound(tickRaw, 0, MAX_TICK));
        assets = bound(assets, 1, type(uint256).max / WAD - 1); // same precondition: assets*WAD must not overflow

        Offer memory offer = isBuy ? _buyOffer(tick) : _sellOffer(tick);
        uint256 units = harness.assetsToSellerUnits(midnight, marketId, offer, assets);
        _assertTightCap(units, _dimensionPrice(tick, fee, isBuy, false), assets, isBuy);
    }

    /// @notice Zero budget/assets is a documented early-return (0), NOT a strict-maximal cap: at low
    ///         prices a unit can round to 0 cost, but the sizer intentionally fills nothing when the
    ///         budget is exhausted. Covers all fill dimensions and fee regimes.
    function testFuzz_budgetToUnits_zero_returnsZero(uint256 tickRaw, bool isBuy, uint256 dimSel, uint256 feeSeed)
        public
    {
        _setSettlementFee(feeSeed);
        uint16 tick = uint16(bound(tickRaw, 0, MAX_TICK));
        uint8 fillIndex = uint8(bound(dimSel, 0, 2));
        Offer memory offer = isBuy ? _buyOffer(tick) : _sellOffer(tick);
        assertEq(harness.budgetToUnits(midnight, marketId, offer, fillIndex, 0), 0, "budgetToUnits(0) == 0");
        assertEq(harness.assetsToSellerUnits(midnight, marketId, offer, 0), 0, "assetsToSellerUnits(0) == 0");
    }

    /// @dev Sets a fuzzed settlement fee (multiple of CBP, within per-bucket bounds) on every maturity
    ///      bucket and returns the fee for the offers' 365-day time-to-maturity. feeSeed == 0 clears it.
    function _setSettlementFee(uint256 feeSeed) internal returns (uint256) {
        for (uint256 i = 0; i < 7; i++) {
            uint256 f = (bound(feeSeed, 0, maxSettlementFee(i)) / CBP) * CBP; // <= max, multiple of CBP
            midnight.setMarketSettlementFee(marketId, i, f);
        }
        return midnight.settlementFee(marketId, 365 days);
    }

    /// @dev Midnight's fee-inclusive per-unit price for a fill dimension (independent recomputation of
    ///      Midnight.sol:360-362 / TakeMathLib.{buyer,seller}Price — not routed through TakeMathLib).
    function _dimensionPrice(uint16 tick, uint256 fee, bool isBuy, bool buyerDim) internal pure returns (uint256) {
        uint256 op = TickLib.tickToPrice(tick);
        if (buyerDim) return isBuy ? op : op + fee; // buyerPrice
        return isBuy ? (op > fee ? op - fee : 0) : op; // sellerPrice (zero-floored)
    }

    /// @dev Assert `units` is the tight cap for `budget` at `price`. Forward rounding is mulDivDown
    ///      when `isBuy`, else mulDivUp. price == 0 ⇒ cost is 0 for any units ⇒ non-binding cap
    ///      (uint128.max). The "fits" bound holds even when the cap saturates at uint128.max (forward
    ///      is monotone, and the saturated value is <= the true maximal); maximality is asserted only
    ///      when the cap is not saturated.
    function _assertTightCap(uint256 units, uint256 price, uint256 budget, bool isBuy) internal {
        if (price == 0) {
            assertEq(units, type(uint128).max, "price 0 => non-binding cap");
            return;
        }
        if (units > 0) assertLe(_forward(units, price, isBuy), budget, "forward(units) must fit budget");
        if (units < type(uint128).max) {
            assertGt(_forward(units + 1, price, isBuy), budget, "units+1 must overshoot => maximal");
        }
    }

    /// @dev For every budget R in [1,1000], assert budgetToUnits is exactly maximal in the matching
    ///      asset dimension. Midnight's forward rounding follows offer direction: buy => mulDivDown,
    ///      sell => mulDivUp. With settlementFee == 0 the buyer-price of a buy offer and the
    ///      seller-price of a sell offer both equal offerPrice == tickToPrice(tick).
    function _assertTight(uint16 tick, bool isBuy) internal returns (uint256 checked) {
        uint256 price = TickLib.tickToPrice(tick);
        Offer memory offer = isBuy ? _buyOffer(tick) : _sellOffer(tick);
        uint8 fillIndex = isBuy ? RouterLib.FILL_BUYER_ASSETS : RouterLib.FILL_SELLER_ASSETS;
        for (uint256 R = 1; R <= 1000; R++) {
            uint256 units = harness.budgetToUnits(midnight, marketId, offer, fillIndex, R);
            // (1) the returned cap fits the budget => never overshoots
            if (units > 0) assertLe(_forward(units, price, isBuy), R, "forward(units) must fit budget");
            // (2) the cap is maximal => one more unit overshoots
            assertGt(_forward(units + 1, price, isBuy), R, "units+1 must overshoot => cap is tight/maximal");
            checked++;
        }
    }

    /// @dev Midnight forward map units -> assets in the relevant dimension.
    function _forward(uint256 units, uint256 price, bool isBuy) internal pure returns (uint256) {
        return isBuy ? units.mulDivDown(price, WAD) : units.mulDivUp(price, WAD);
    }
}
