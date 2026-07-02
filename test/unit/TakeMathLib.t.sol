// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {Market, CollateralParams, Offer, IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {WAD, maxSettlementFee} from "@midnight/libraries/ConstantsLib.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {TakeMathLib} from "../../src/libraries/TakeMathLib.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {ClampFuzzFixtures} from "../helpers/ClampFuzzFixtures.sol";

/// @dev Harness exposing every TakeMathLib internal function for direct unit testing.
contract TakeMathLibFullHarness {
    function getOfferRemaining(Midnight midnight, Offer calldata offer, bytes32 marketId)
        external
        view
        returns (uint256)
    {
        return TakeMathLib.getOfferRemaining(midnight, offer, marketId);
    }

    function assetsToSellerUnits(Midnight midnight, bytes32 marketId, Offer calldata offer, uint256 assets)
        external
        view
        returns (uint256)
    {
        return TakeMathLib.assetsToSellerUnits(midnight, marketId, offer, assets);
    }

    function sellerPrice(Midnight midnight, bytes32 marketId, Offer calldata offer) external view returns (uint256) {
        return TakeMathLib.sellerPrice(midnight, marketId, offer);
    }

    function maxUnitsForSellerBudget(
        Midnight midnight,
        bytes32 marketId,
        Offer calldata offer,
        uint256 feeRate,
        uint256 maxBudget
    ) external view returns (uint256) {
        return TakeMathLib.maxUnitsForSellerBudget(midnight, marketId, offer, feeRate, maxBudget);
    }

    function maxUnitsForBuyerBudget(
        Midnight midnight,
        bytes32 marketId,
        Offer calldata offer,
        uint256 feeRate,
        uint256 maxBudget
    ) external view returns (uint256) {
        return TakeMathLib.maxUnitsForBuyerBudget(midnight, marketId, offer, feeRate, maxBudget);
    }

    function buyerPrice(Midnight midnight, bytes32 marketId, Offer calldata offer) external view returns (uint256) {
        return TakeMathLib.buyerPrice(midnight, marketId, offer);
    }

    function mulDivDownInverse(uint256 target, uint256 den, uint256 num) external pure returns (uint256) {
        return TakeMathLib.mulDivDownInverse(target, den, num);
    }

    function mulDivUpInverse(uint256 target, uint256 den, uint256 num) external pure returns (uint256) {
        return TakeMathLib.mulDivUpInverse(target, den, num);
    }

    function available(address token, address owner, address spender) external view returns (uint256) {
        return TakeMathLib.available(token, owner, spender);
    }

    function capReduceOnly(Midnight midnight, bytes32 marketId, Offer calldata offer, uint256 maxUnits)
        external
        view
        returns (uint256)
    {
        return TakeMathLib.capReduceOnly(midnight, marketId, offer, maxUnits);
    }

    function min3(uint256 a, uint256 b, uint256 c) external pure returns (uint256) {
        return TakeMathLib.min(a, b, c);
    }
}

/// @title Comprehensive TakeMathLib unit tests
/// @notice Targets the 81 real mutation gaps identified in issue #285.
contract TakeMathLibUnitTest is ClampFuzzFixtures {
    using UtilsLib for uint256;

    Midnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    TakeMathLibFullHarness internal harness;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    Market internal market;
    bytes32 internal marketId;

    address internal maker;

    /// @dev Settlement fee at TTM = 365 days (with _fees[1-6] set to max, _fees[0] = 0).
    uint256 internal settlementFee365d;

    /// @dev Auto-incrementing nonce for unique offer groups, avoids keccak("magic-string") collisions.
    uint256 private _groupNonce;

    function _uniqueGroup() private returns (bytes32) {
        return bytes32(++_groupNonce);
    }

    function setUp() public {
        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Col", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(10e36);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));
        harness = new TakeMathLibFullHarness();
        maker = makeAddr("testMaker");

        CollateralParams[] memory cols = new CollateralParams[](1);
        cols[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: cols,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        marketId = IdLib.toId(market);

        _seedMarket(SEED_AMOUNT);

        // Configure non-zero settlement fees. Leave _fees[0] = 0 so that at TTM=0
        // (vm.warp to maturity), settlementFee = 0 — needed for buyerPrice=0 tests.
        midnight.setFeeSetter(address(this));
        for (uint256 i = 1; i <= 6; i++) {
            midnight.setMarketSettlementFee(marketId, i, maxSettlementFee(i));
        }

        settlementFee365d = midnight.settlementFee(marketId, 365 days);
    }

    /* ═══════════════════════════════════════════════════════════════
       Helpers
       ═══════════════════════════════════════════════════════════════ */

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

    /// @dev Create a borrower (debt position) on the market.
    function _setupBorrowerWithDebt(address account, uint256 accountSK, uint128 debtUnits) internal {
        address tempLender = makeAddr(string(abi.encodePacked("tL", account)));

        collateralToken.mint(account, type(uint128).max);
        loanToken.mint(tempLender, type(uint128).max);

        MidnightSupplyCollateralCallback cb = new MidnightSupplyCollateralCallback(address(midnight));
        vm.startPrank(account);
        collateralToken.approve(address(cb), type(uint256).max);
        midnight.setIsAuthorized(address(cb), true, account);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, account);
        vm.stopPrank();

        vm.prank(tempLender);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = uint256(debtUnits) * 20;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: debtUnits, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory sellOffer = Offer({
            market: market,
            buy: false,
            maker: account,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("debt-setup", account)),
            callback: address(cb),
            callbackData: cbData,
            receiverIfMakerIsSeller: account,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, accountSK);
        bytes32 root = HashLib.hashOffer(sellOffer);

        vm.prank(tempLender);
        midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            debtUnits,
            tempLender,
            address(0),
            address(0),
            ""
        );
    }

    /// @dev Create a lender (credit position) on the market.
    function _setupLenderWithCredit(address account, uint128 creditAmount) internal {
        (address tempBorrower, uint256 tempBorrowerSK) = makeAddrAndKey(string(abi.encodePacked("tB", account)));

        collateralToken.mint(tempBorrower, type(uint128).max);
        vm.startPrank(tempBorrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, uint256(creditAmount) * 100, tempBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, tempBorrower);
        vm.stopPrank();

        loanToken.mint(account, type(uint128).max);
        vm.prank(account);
        loanToken.approve(address(midnight), type(uint256).max);

        Offer memory sellOffer = Offer({
            market: market,
            buy: false,
            maker: tempBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("lend-setup", account)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: tempBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, tempBorrowerSK);
        bytes32 root = HashLib.hashOffer(sellOffer);

        vm.prank(account);
        midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            creditAmount,
            account,
            address(0),
            address(0),
            ""
        );
    }

    /// @dev Build an offer with maxUnits denomination.
    function _offerUnits(address _maker, bool buy, uint16 tick, bytes32 group, uint128 maxUnits)
        internal
        view
        returns (Offer memory)
    {
        return _offerFull(_maker, buy, tick, group, false, maxUnits, 0);
    }

    /// @dev Build an offer with maxAssets denomination. The offer's `buy` flag fixes whether
    ///      `maxAssets` is interpreted as buyer- or seller-side (BUY ⇒ buyerAssets, SELL ⇒ sellerAssets).
    function _offerAssets(address _maker, bool buy, uint16 tick, bytes32 group, uint128 maxAssets)
        internal
        view
        returns (Offer memory)
    {
        return _offerFull(_maker, buy, tick, group, false, 0, maxAssets);
    }

    function _offerFull(
        address _maker,
        bool buy,
        uint16 tick,
        bytes32 group,
        bool reduceOnly,
        uint128 maxUnits,
        uint128 maxAssets
    ) internal view returns (Offer memory) {
        return Offer({
            market: market,
            buy: buy,
            maker: _maker,
            start: 0,
            expiry: type(uint256).max,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: maxUnits,
            maxAssets: maxAssets,
            continuousFeeCap: type(uint256).max
        });
    }

    /// @dev Directly set the market's lossFactor via vm.store (simulates bad debt slashing).
    ///      MarketState word 0 layout: totalUnits (lower 128) | lossFactor (upper 128).
    function _setLossFactor(uint128 lossFactor) internal {
        bytes32 oblBaseSlot = keccak256(abi.encode(marketId, uint256(1)));
        bytes32 currentWord0 = vm.load(address(midnight), oblBaseSlot);
        // Preserve lower 128 bits (totalUnits), replace upper 128 bits (lossFactor)
        uint256 lower128 = uint256(currentWord0) & uint256(type(uint128).max);
        vm.store(address(midnight), oblBaseSlot, bytes32(lower128 | (uint256(lossFactor) << 128)));
    }

    /* ═══════════════════════════════════════════════════════════════
       1. getOfferRemaining
       ═══════════════════════════════════════════════════════════════ */

    function test_getOfferRemaining_maxUnits_fresh() public {
        Offer memory offer = _offerUnits(maker, true, 5028, _uniqueGroup(), 1000);
        uint256 result = harness.getOfferRemaining(midnight, offer, marketId);
        assertEq(result, 1000);
    }

    function test_getOfferRemaining_maxUnits_partial() public {
        bytes32 group = _uniqueGroup();
        Offer memory offer = _offerUnits(maker, true, 5028, group, 1000);

        vm.prank(maker);
        midnight.setConsumed(group, 400, maker);

        uint256 result = harness.getOfferRemaining(midnight, offer, marketId);
        assertEq(result, 600);
    }

    function test_getOfferRemaining_maxUnits_fullyConsumed() public {
        bytes32 group = _uniqueGroup();
        Offer memory offer = _offerUnits(maker, true, 5028, group, 1000);

        vm.prank(maker);
        midnight.setConsumed(group, 1000, maker);

        uint256 result = harness.getOfferRemaining(midnight, offer, marketId);
        assertEq(result, 0);
    }

    function test_getOfferRemaining_maxUnits_overConsumed() public {
        bytes32 group = _uniqueGroup();
        Offer memory offer = _offerUnits(maker, true, 5028, group, 1000);

        vm.prank(maker);
        midnight.setConsumed(group, 1500, maker);

        uint256 result = harness.getOfferRemaining(midnight, offer, marketId);
        assertEq(result, 0);
    }

    /// @notice CLAMP-1 safety: for SELL offers with sellerAssets-denominated capacity, converting
    ///         the returned units back to sellerAssets via Midnight's forward formula must never
    ///         exceed the remaining capacity. (Upstream collapsed maxAssets to the maker's side,
    ///         so sellerAssets only applies to SELL offers.)
    function testFuzz_getOfferRemaining_maxSellerAssets_safety(uint16 tickSeed, uint64 capacitySeed) public {
        uint16 tick = _boundTick(tickSeed);
        uint128 capacity = uint128(bound(capacitySeed, 1, type(uint64).max));

        Offer memory offer = _offerAssets(maker, false, tick, _uniqueGroup(), capacity);

        uint256 result = harness.getOfferRemaining(midnight, offer, marketId);

        if (result == 0 || result >= type(uint128).max) return;

        uint256 sellerPrice = TickLib.tickToPrice(tick);
        // SELL: sellerAssets = ceil(units * sellerPrice / WAD)
        uint256 forward = result.mulDivUp(sellerPrice, WAD);
        assertLe(forward, capacity, "CLAMP-1: forward(result) must not exceed capacity");
    }

    /// @notice CLAMP-1 safety: same for BUY offers with buyerAssets-denominated capacity.
    function testFuzz_getOfferRemaining_maxBuyerAssets_safety(uint16 tickSeed, uint64 capacitySeed) public {
        uint16 tick = _boundTick(tickSeed);
        uint128 capacity = uint128(bound(capacitySeed, 1, type(uint64).max));

        Offer memory offer = _offerAssets(maker, true, tick, _uniqueGroup(), capacity);

        uint256 result = harness.getOfferRemaining(midnight, offer, marketId);

        if (result == 0 || result >= type(uint128).max) return;

        uint256 buyerPrice = TickLib.tickToPrice(tick);
        // BUY: buyerAssets = floor(units * buyerPrice / WAD)
        uint256 forward = result.mulDivDown(buyerPrice, WAD);
        assertLe(forward, capacity, "CLAMP-1: forward(result) must not exceed capacity");
    }

    function test_getOfferRemaining_maxSellerAssets_fullyConsumed() public {
        bytes32 group = _uniqueGroup();
        Offer memory offer = _offerAssets(maker, false, 5028, group, 100e18);

        vm.prank(maker);
        midnight.setConsumed(group, 100e18, maker);

        uint256 result = harness.getOfferRemaining(midnight, offer, marketId);
        assertEq(result, 0);
    }

    function test_getOfferRemaining_maxBuyerAssets_fullyConsumed() public {
        bytes32 group = _uniqueGroup();
        Offer memory offer = _offerAssets(maker, true, 5028, group, 100e18);

        vm.prank(maker);
        midnight.setConsumed(group, 100e18, maker);

        uint256 result = harness.getOfferRemaining(midnight, offer, marketId);
        assertEq(result, 0);
    }

    function test_getOfferRemaining_maxBuyerAssets_buyerPriceZero() public {
        Offer memory offer = _offerAssets(maker, true, 0, _uniqueGroup(), 100e18);

        uint256 result = harness.getOfferRemaining(midnight, offer, marketId);
        assertEq(result, type(uint128).max);
    }

    /// @notice BUY offer with maxAssets == type(uint128).max (the maximum representable cap) and a positive
    ///         buyer price: the resulting remainingAssets feeds mulDivDownInverse without reverting, which
    ///         would otherwise DoS the whole routing batch.
    function test_getOfferRemaining_maxBuyerAssets_maxUint_doesNotRevert() public {
        Offer memory offer = _offerAssets(maker, true, 5028, _uniqueGroup(), type(uint128).max);
        assertGt(harness.buyerPrice(midnight, marketId, offer), 0, "precondition: buyerPrice > 0");

        uint256 result = harness.getOfferRemaining(midnight, offer, marketId);
        assertEq(result, type(uint128).max);
    }

    /* ═══════════════════════════════════════════════════════════════
       2. assetsToSellerUnits
       ═══════════════════════════════════════════════════════════════ */

    function test_assetsToSellerUnits_zeroAssets() public {
        Offer memory offer = _offerUnits(maker, false, 5028, _uniqueGroup(), type(uint128).max);
        uint256 result = harness.assetsToSellerUnits(midnight, marketId, offer, 0);
        assertEq(result, 0);
    }

    function test_assetsToSellerUnits_sellOffer() public {
        Offer memory offer = _offerUnits(maker, false, 5028, _uniqueGroup(), type(uint128).max);
        uint256 offerPrice = TickLib.tickToPrice(5028);

        uint256 expected = uint256(50e18).mulDivDown(WAD, offerPrice);

        uint256 result = harness.assetsToSellerUnits(midnight, marketId, offer, 50e18);
        assertEq(result, expected);
    }

    function test_assetsToSellerUnits_buyOffer() public {
        Offer memory offer = _offerUnits(maker, true, 5028, _uniqueGroup(), type(uint128).max);
        uint256 offerPrice = TickLib.tickToPrice(5028);
        uint256 sellerPrice = offerPrice - settlementFee365d;
        assertTrue(sellerPrice > 0, "precondition: sellerPrice > 0");

        uint256 expected = uint256(50e18).mulDivUp(WAD, sellerPrice);

        uint256 result = harness.assetsToSellerUnits(midnight, marketId, offer, 50e18);
        assertEq(result, expected);
    }

    /* ═══════════════════════════════════════════════════════════════
       2b. sellerPrice (BUY underflow guard)
       ═══════════════════════════════════════════════════════════════ */

    function test_sellerPrice_buyOffer_lowTick_returnsZero() public {
        uint256 offerPrice = TickLib.tickToPrice(0);
        assertTrue(offerPrice < settlementFee365d, "precondition: offerPrice < settlementFee");

        Offer memory offer = _offerUnits(maker, true, 0, _uniqueGroup(), type(uint128).max);
        uint256 sp = harness.sellerPrice(midnight, marketId, offer);
        assertEq(sp, 0);
    }

    function test_sellerPrice_buyOffer_highTick_deductsFee() public {
        Offer memory offer = _offerUnits(maker, true, 5028, _uniqueGroup(), type(uint128).max);
        uint256 sp = harness.sellerPrice(midnight, marketId, offer);
        assertEq(sp, TickLib.tickToPrice(5028) - settlementFee365d);
    }

    function test_sellerPrice_sellOffer_ignoresFee() public {
        Offer memory offer = _offerUnits(maker, false, 5028, _uniqueGroup(), type(uint128).max);
        uint256 sp = harness.sellerPrice(midnight, marketId, offer);
        assertEq(sp, TickLib.tickToPrice(5028));
    }

    /* ═══════════════════════════════════════════════════════════════
       3b. maxUnitsForSellerBudget
       ═══════════════════════════════════════════════════════════════ */

    /// @notice BUY offer, feeRate > 0, sellerPrice rounds to 0 (settlement fee >= offer price).
    ///         No unit count consumes any seller budget — the constraint is vacuous and must not cap the fill at 0.
    function test_maxUnitsForSellerBudget_buyOffer_withFee_sellerPriceZero_returnsMax() public {
        Offer memory offer = _offerUnits(maker, true, 0, _uniqueGroup(), type(uint128).max);
        assertEq(harness.sellerPrice(midnight, marketId, offer), 0, "precondition: sellerPrice = 0 at tick 0");

        uint256 result = harness.maxUnitsForSellerBudget(midnight, marketId, offer, 0.1e18, 100e18);
        assertEq(result, type(uint128).max);
    }

    /// @notice M-01 regression: BUY offer, feeRate == 0, sellerPrice rounds to 0.
    ///         Without the zeroFloorSub guard in sellerPrice, this path underflows.
    function test_maxUnitsForSellerBudget_buyOffer_noFee_sellerPriceZero_returnsMax() public {
        Offer memory offer = _offerUnits(maker, true, 0, _uniqueGroup(), type(uint128).max);
        uint256 result = harness.maxUnitsForSellerBudget(midnight, marketId, offer, 0, 100e18);
        assertEq(result, type(uint128).max);
    }

    /// @notice SELL offer, feeRate > 0, effPrice rounds to 0 — constraint is vacuous (mulDivUp(units, 0, WAD) == 0),
    ///         must not cap the fill at 0. Mirrors the BUY counterpart.
    function test_maxUnitsForSellerBudget_sellOffer_withFee_effPriceZero_returnsMax() public {
        uint256 effPrice = CallbackLib.sellerEffectivePrice(TickLib.tickToPrice(0), 0.1e18);
        assertEq(effPrice, 0, "precondition: sellerEffectivePrice(0, 0.1e18) = 0");

        Offer memory offer = _offerUnits(maker, false, 0, _uniqueGroup(), type(uint128).max);
        uint256 result = harness.maxUnitsForSellerBudget(midnight, marketId, offer, 0.1e18, 100e18);
        assertEq(result, type(uint128).max);
    }

    /// @notice M-08: SELL+fee — repayBudget = mulDivUp(result, sellerEffPrice, WAD) must not exceed maxBudget.
    function test_maxUnitsForSellerBudget_sellWithFee_overshootsByOne() public {
        Offer memory offer = _offerUnits(maker, false, 820, _uniqueGroup(), type(uint128).max);
        uint256 feeRate = 0.01e18;
        uint256 maxBudget = 100e18;

        uint256 result = harness.maxUnitsForSellerBudget(midnight, marketId, offer, feeRate, maxBudget);
        uint256 effPrice = CallbackLib.sellerEffectivePrice(TickLib.tickToPrice(820), feeRate);

        assertLe(result.mulDivUp(effPrice, WAD), maxBudget, "repayBudget must not exceed maxBudget");
    }

    /// @notice SELL offer, feeRate == 0: inverse = mulDivDown(maxBudget, WAD, price), which is the
    ///         exact inverse of the ceil forward (Midnight's seller-side forward = mulDivUp).
    ///         Safety: ceil(result * price / WAD) <= budget. Tightness: ceil((result+1) * price / WAD) > budget.
    function testFuzz_maxUnitsForSellerBudget_sellNoFee_safetyAndTightness(uint16 tickSeed, uint128 budgetSeed) public {
        uint16 tick = _boundTick(tickSeed);
        uint256 maxBudget = bound(budgetSeed, 1, type(uint128).max);

        Offer memory offer = _offerUnits(maker, false, tick, _uniqueGroup(), type(uint128).max);
        uint256 result = harness.maxUnitsForSellerBudget(midnight, marketId, offer, 0, maxBudget);

        uint256 price = TickLib.tickToPrice(tick);
        if (price == 0) {
            assertEq(result, type(uint128).max, "price=0: constraint is vacuous, must return max");
            return;
        }

        assertLe(result.mulDivUp(price, WAD), maxBudget, "SAFETY: seller receipt exceeds budget");
        assertGt((result + 1).mulDivUp(price, WAD), maxBudget, "TIGHTNESS: inverse is not the true optimum");
    }

    /// @notice BUY offer (seller = taker, settlement fee deducted from sellerPrice).
    ///         Sized solely by the settlement-fee bound: inverse = mulDivDownInverse(budget, WAD, sp), exact floor
    ///         inverse, regardless of feeRate. The Tenor fee is carved out of sellerAssets, so it does not bound units.
    function testFuzz_maxUnitsForSellerBudget_buyOffer_safetyAndTightness(
        uint16 tickSeed,
        uint256 feeRateSeed,
        uint128 budgetSeed
    ) public {
        uint16 tick = _boundTick(tickSeed);
        uint256 feeRate = bound(feeRateSeed, 0, MAX_FEE_RATE);
        uint256 maxBudget = bound(budgetSeed, 1, type(uint128).max);

        Offer memory offer = _offerUnits(maker, true, tick, _uniqueGroup(), type(uint128).max);
        uint256 result = harness.maxUnitsForSellerBudget(midnight, marketId, offer, feeRate, maxBudget);

        uint256 sp = harness.sellerPrice(midnight, marketId, offer);
        if (sp == 0) {
            assertEq(result, type(uint128).max, "sp=0: constraint is vacuous, must return max");
            return;
        }
        assertLe(result.mulDivDown(sp, WAD), maxBudget, "SAFETY: seller receipt exceeds budget");
        assertGt((result + 1).mulDivDown(sp, WAD), maxBudget, "TIGHTNESS: inverse is not the true optimum");
    }

    /// @notice BUY renewal with feeRate > 0 and a nonzero settlement fee: sizing solely by sellerPrice lets the
    ///         fill close the source debt exactly (repayBudget == sourceDebt), enabling the final collateral sweep.
    ///         The old min-of-two sizing (also bounded by the tighter effective price) selected fewer units, so the
    ///         seller receipt fell short of the debt and the final-fill equality could never hold.
    function test_maxUnitsForSellerBudget_buyOffer_withFee_enablesExactSweep() public {
        uint256 feeRate = 0.01e18;
        Offer memory offer = _offerUnits(maker, true, 5028, _uniqueGroup(), type(uint128).max);

        uint256 sp = harness.sellerPrice(midnight, marketId, offer);
        uint256 effPrice = CallbackLib.sellerEffectivePrice(TickLib.tickToPrice(5028), feeRate);
        assertGt(effPrice, sp, "precondition: effective price exceeds settlement-fee-adjusted price");

        // Pick a source debt that is exactly closable at sp: an integer number of units maps to it with no remainder.
        uint256 sourceDebt = uint256(1234).mulDivDown(sp, WAD);

        uint256 result = harness.maxUnitsForSellerBudget(midnight, marketId, offer, feeRate, sourceDebt);

        // New behavior: seller receipt closes the debt exactly → repayBudget == sourceDebt → final sweep.
        uint256 sellerAssets = result.mulDivDown(sp, WAD);
        // Closing the debt exactly (repayBudget == sourceDebt) also proves the budget invariant holds.
        assertEq(sellerAssets, sourceDebt, "new sizing must close the source debt exactly");

        // Old min-of-two sizing would have been bounded by the tighter effective price, underfilling the sweep.
        uint256 oldResult = harness.mulDivDownInverse(sourceDebt, WAD, effPrice);
        assertLt(oldResult.mulDivDown(sp, WAD), sourceDebt, "old sizing fell short of the debt (missed sweep)");
        assertGt(result, oldResult, "new sizing allows strictly more units than the effective-price bound");
    }

    /* ═══════════════════════════════════════════════════════════════
       3c. maxUnitsForBuyerBudget
       ═══════════════════════════════════════════════════════════════ */

    function test_maxUnitsForBuyerBudget_zeroBudget() public {
        Offer memory offer = _offerUnits(maker, true, 5028, _uniqueGroup(), type(uint128).max);
        uint256 result = harness.maxUnitsForBuyerBudget(midnight, marketId, offer, 0, 0);
        assertEq(result, 0);
    }

    function test_maxUnitsForBuyerBudget_buyNoFee_priceZero_returnsMax() public {
        Offer memory offer = _offerUnits(maker, true, 0, _uniqueGroup(), type(uint128).max);
        uint256 result = harness.maxUnitsForBuyerBudget(midnight, marketId, offer, 0, 100e18);
        assertEq(result, type(uint128).max);
    }

    /// @notice Degenerate guard: price == 0 with feeRate == WAD would revert buyerEffectivePrice
    ///         (feeShareOfInterest == WAD). The short-circuit must return max without reverting.
    function test_maxUnitsForBuyerBudget_buyMaxFee_priceZero_doesNotRevert() public {
        Offer memory offer = _offerUnits(maker, true, 0, _uniqueGroup(), type(uint128).max);
        uint256 result = harness.maxUnitsForBuyerBudget(midnight, marketId, offer, WAD, 100e18);
        assertEq(result, type(uint128).max);
    }

    /// @notice SELL offer degenerate guard: price == 0 with feeRate == WAD. fromEffPrice short-circuits
    ///         to max; the result must be the settlement-fee (buyerPrice) bound.
    function test_maxUnitsForBuyerBudget_sellMaxFee_priceZero_usesBuyerPriceBound() public {
        Offer memory offer = _offerUnits(maker, false, 0, _uniqueGroup(), type(uint128).max);
        uint256 bp = harness.buyerPrice(midnight, marketId, offer);
        assertEq(bp, settlementFee365d, "precondition: buyerPrice = 0 + settlementFee");
        assertGt(bp, 0, "precondition: settlement fee non-zero at 365d TTM");

        uint256 result = harness.maxUnitsForBuyerBudget(midnight, marketId, offer, WAD, 100e18);
        assertEq(result, uint256(100e18).mulDivDown(WAD, bp));
    }

    /// @notice SELL offer, feeRate == 0, buyerPrice == 0 (at maturity TTM=0 the settlement fee is 0).
    ///         Constraint is vacuous, must return max.
    function test_maxUnitsForBuyerBudget_sellNoFee_buyerPriceZero_returnsMax() public {
        Offer memory offer = _offerUnits(maker, false, 0, _uniqueGroup(), type(uint128).max);
        vm.warp(market.maturity); // TTM = 0 → settlementFee = 0 → buyerPrice = 0 + 0
        assertEq(harness.buyerPrice(midnight, marketId, offer), 0, "precondition: buyerPrice = 0");

        uint256 result = harness.maxUnitsForBuyerBudget(midnight, marketId, offer, 0, 100e18);
        assertEq(result, type(uint128).max);
    }

    /// @notice BUY offer (buyer = maker, no settlement fee).
    ///         feeRate == 0: inverse = mulDivDownInverse(budget, WAD, price) — exact floor inverse
    ///                       (matches Midnight's buyer-side forward = mulDivDown).
    ///         feeRate > 0:  inverse = mulDivDown(budget, WAD, effPrice) — exact ceil inverse
    ///                       (buyerBudget = mulDivUp(units, buyerEffPrice, WAD)).
    function testFuzz_maxUnitsForBuyerBudget_buyOffer_safetyAndTightness(
        uint16 tickSeed,
        uint256 feeRateSeed,
        uint128 budgetSeed
    ) public {
        uint16 tick = _boundTick(tickSeed);
        uint256 feeRate = bound(feeRateSeed, 0, MAX_FEE_RATE);
        uint256 maxBudget = bound(budgetSeed, 1, type(uint128).max);

        Offer memory offer = _offerUnits(maker, true, tick, _uniqueGroup(), type(uint128).max);
        uint256 result = harness.maxUnitsForBuyerBudget(midnight, marketId, offer, feeRate, maxBudget);

        uint256 price = TickLib.tickToPrice(tick);
        uint256 effPrice = feeRate == 0 ? price : CallbackLib.buyerEffectivePrice(price, feeRate);
        if (effPrice == 0) {
            assertEq(result, type(uint128).max, "effPrice=0: constraint is vacuous, must return max");
            return;
        }

        if (feeRate == 0) {
            assertLe(result.mulDivDown(price, WAD), maxBudget, "SAFETY: buyer payment exceeds budget");
            assertGt((result + 1).mulDivDown(price, WAD), maxBudget, "TIGHTNESS: inverse is not the true optimum");
        } else {
            assertLe(result.mulDivUp(effPrice, WAD), maxBudget, "SAFETY: buyer payment exceeds budget");
            assertGt((result + 1).mulDivUp(effPrice, WAD), maxBudget, "TIGHTNESS: inverse is not the true optimum");
        }
    }

    /// @notice SELL offer (buyer = taker, settlement fee added to buyerPrice).
    ///         feeRate == 0: inverse = mulDivDown(budget, WAD, bp) — exact ceil inverse.
    ///         feeRate > 0:  min of two exact ceil inverses (Tenor-fee and settlement-fee bounds).
    function testFuzz_maxUnitsForBuyerBudget_sellOffer_safetyAndTightness(
        uint16 tickSeed,
        uint256 feeRateSeed,
        uint128 budgetSeed
    ) public {
        uint16 tick = _boundTick(tickSeed);
        uint256 feeRate = bound(feeRateSeed, 0, MAX_FEE_RATE);
        uint256 maxBudget = bound(budgetSeed, 1, type(uint128).max);

        Offer memory offer = _offerUnits(maker, false, tick, _uniqueGroup(), type(uint128).max);
        uint256 result = harness.maxUnitsForBuyerBudget(midnight, marketId, offer, feeRate, maxBudget);

        uint256 price = TickLib.tickToPrice(tick);
        uint256 bp = harness.buyerPrice(midnight, marketId, offer);

        if (feeRate == 0) {
            if (bp == 0) {
                assertEq(result, type(uint128).max, "bp=0: constraint is vacuous, must return max");
                return;
            }
            assertLe(result.mulDivUp(bp, WAD), maxBudget, "SAFETY: buyer payment exceeds budget");
            assertGt((result + 1).mulDivUp(bp, WAD), maxBudget, "TIGHTNESS: inverse is not the true optimum");
        } else {
            uint256 effPrice = price == 0 ? 0 : CallbackLib.buyerEffectivePrice(price, feeRate);
            if (effPrice == 0 && bp == 0) {
                assertEq(result, type(uint128).max, "both prices 0: constraint is vacuous, must return max");
                return;
            }
            if (effPrice != 0) {
                assertLe(result.mulDivUp(effPrice, WAD), maxBudget, "SAFETY: effPrice bound exceeded");
            }
            if (bp != 0) {
                assertLe(result.mulDivUp(bp, WAD), maxBudget, "SAFETY: buyerPrice bound exceeded");
            }
            // Sentinel cap: when one bound is vacuous (zero price → uint128.max sentinel), min() can
            // clamp the result at uint128.max even if the other bound's true inverse is larger.
            // uint128.max is the max representable fill, so tightness is vacuous there.
            if (result == type(uint128).max) return;
            // Tightness: result+1 must break the binding bound
            bool breaksEff = effPrice != 0 && (result + 1).mulDivUp(effPrice, WAD) > maxBudget;
            bool breaksBp = bp != 0 && (result + 1).mulDivUp(bp, WAD) > maxBudget;
            assertTrue(breaksEff || breaksBp, "TIGHTNESS: result+1 breaks neither bound");
        }
    }

    /* ═══════════════════════════════════════════════════════════════
       4. mulDivDownInverse
       ═══════════════════════════════════════════════════════════════ */

    function test_mulDivDownInverse_normal() public {
        // target=100, den=1e18, num=0.95e18
        // expected = (101 * 1e18 - 1) / 0.95e18 = 106_315_789_473_684_210_525
        uint256 num = 0.95e18;
        uint256 expected = (uint256(101) * 1e18 - 1) / num;
        uint256 result = harness.mulDivDownInverse(100, 1e18, num);
        assertEq(result, expected);

        // Verify the inverse property: floor(result * num / den) <= target
        uint256 forward = result.mulDivDown(num, 1e18);
        assertLe(forward, 100, "forward must not exceed target");
    }

    /// @notice target = type(uint256).max: the early-return saturates instead of overflowing target + 1.
    function test_mulDivDownInverse_targetMaxUint_saturates() public {
        assertEq(harness.mulDivDownInverse(type(uint256).max, 1e18, 0.95e18), type(uint256).max);
    }

    /// @notice (target+1) * den overflows uint256 → returns max.
    function test_mulDivDownInverse_overflowProduct() public {
        uint256 result = harness.mulDivDownInverse(type(uint256).max - 1, 2, 1);
        assertEq(result, type(uint256).max);
    }

    /// @notice num == 0 (e.g. zero price): the constraint is vacuous, so the bound saturates to max
    ///         instead of reverting on division by zero. Holds even at the target == max edge.
    function test_mulDivDownInverse_numZero_saturates() public {
        assertEq(harness.mulDivDownInverse(100, 1e18, 0), type(uint256).max);
        assertEq(harness.mulDivDownInverse(0, 1e18, 0), type(uint256).max);
        assertEq(harness.mulDivDownInverse(type(uint256).max, 1e18, 0), type(uint256).max);
    }

    function test_mulDivDownInverse_targetZero() public {
        // target=0: n=1, result = (1 * 1e18 - 1) / 0.95e18
        uint256 num = 0.95e18;
        uint256 result = harness.mulDivDownInverse(0, 1e18, num);
        uint256 expected = (1e18 - 1) / num;
        assertEq(result, expected);

        // Inverse property: floor(result * num / den) <= 0
        uint256 forward = result.mulDivDown(num, 1e18);
        assertEq(forward, 0, "target=0 inverse must map back to 0");
    }

    /* ═══════════════════════════════════════════════════════════════
       5. mulDivUpInverse
       ═══════════════════════════════════════════════════════════════ */

    function test_mulDivUpInverse_normal() public {
        uint256 num = 0.95e18;
        uint256 expected = uint256(100).mulDivDown(1e18, num);
        uint256 result = harness.mulDivUpInverse(100, 1e18, num);
        assertEq(result, expected);

        // Inverse property: ceil(result * num / den) <= target
        uint256 forward = result.mulDivUp(num, 1e18);
        assertLe(forward, 100, "ceil inverse must not exceed target");
    }

    /// @notice target * den overflows uint256 → returns max (mirrors mulDivDownInverse's graceful handling).
    function test_mulDivUpInverse_overflowProduct() public {
        uint256 bigTarget = type(uint256).max / 1e17;
        uint256 result = harness.mulDivUpInverse(bigTarget, WAD, 0.95e18);
        assertEq(result, type(uint256).max);
    }

    /// @notice target == 0 → product is 0, no overflow → returns 0 (the `target != 0` guard avoids div-by-zero).
    function test_mulDivUpInverse_targetZero() public {
        uint256 result = harness.mulDivUpInverse(0, WAD, 0.95e18);
        assertEq(result, 0);
    }

    /// @notice num == 0 (e.g. zero price): the constraint is vacuous, so the bound saturates to max
    ///         instead of reverting on division by zero (mulDivDown(_, _, 0)).
    function test_mulDivUpInverse_numZero_saturates() public {
        assertEq(harness.mulDivUpInverse(100, WAD, 0), type(uint256).max);
        assertEq(harness.mulDivUpInverse(0, WAD, 0), type(uint256).max);
        assertEq(harness.mulDivUpInverse(type(uint256).max, WAD, 0), type(uint256).max);
    }

    /// @notice Normal in-range case is unchanged: returns target.mulDivDown(den, num).
    function test_mulDivUpInverse_normalUnchanged() public {
        uint256 num = 0.95e18;
        uint256 result = harness.mulDivUpInverse(100, WAD, num);
        assertEq(result, uint256(100).mulDivDown(WAD, num));
    }

    /// @notice The two inverses must diverge on inputs where floor vs ceil rounding matters.
    ///         Kills mutations swapping mulDivDownInverse for mulDivUpInverse or vice versa.
    function test_mulDivUpInverse_differsFromDown() public {
        uint256 downResult = harness.mulDivDownInverse(7, 3, 2);
        uint256 upResult = harness.mulDivUpInverse(7, 3, 2);
        assertEq(downResult, 11);
        assertEq(upResult, 10);
        assertTrue(downResult != upResult, "inverses must differ for these inputs");
    }

    /* ═══════════════════════════════════════════════════════════════
       6. available
       ═══════════════════════════════════════════════════════════════ */

    function test_available_balanceLessThanAllowance() public {
        address owner = makeAddr("avail-owner");
        address spender = makeAddr("avail-spender");

        loanToken.mint(owner, 50e18);
        vm.prank(owner);
        loanToken.approve(spender, 100e18);

        uint256 result = harness.available(address(loanToken), owner, spender);
        assertEq(result, 50e18);
    }

    function test_available_allowanceLessThanBalance() public {
        address owner = makeAddr("avail-owner2");
        address spender = makeAddr("avail-spender2");

        loanToken.mint(owner, 100e18);
        vm.prank(owner);
        loanToken.approve(spender, 50e18);

        uint256 result = harness.available(address(loanToken), owner, spender);
        assertEq(result, 50e18);
    }

    function test_available_equal() public {
        address owner = makeAddr("avail-owner3");
        address spender = makeAddr("avail-spender3");

        loanToken.mint(owner, 75e18);
        vm.prank(owner);
        loanToken.approve(spender, 75e18);

        uint256 result = harness.available(address(loanToken), owner, spender);
        assertEq(result, 75e18);
    }

    /* ═══════════════════════════════════════════════════════════════
       7. capReduceOnly
       ═══════════════════════════════════════════════════════════════ */

    function test_capReduceOnly_reduceOnlyFalse() public {
        Offer memory offer = _offerFull(maker, true, 950, _uniqueGroup(), false, 1000, 0);
        uint256 result = harness.capReduceOnly(midnight, marketId, offer, 1000);
        assertEq(result, 1000, "reduceOnly=false must return maxUnits unchanged");
    }

    function test_capReduceOnly_buyOffer_capsToDebt() public {
        (address borrower, uint256 borrowerSK) = makeAddrAndKey("cro-borrower");
        _setupBorrowerWithDebt(borrower, borrowerSK, 50);

        uint256 debt = midnight.debt(marketId, borrower);
        assertEq(debt, 50, "precondition: borrower has 50 debt");

        Offer memory offer = _offerFull(borrower, true, 950, _uniqueGroup(), true, 1000, 0);
        uint256 result = harness.capReduceOnly(midnight, marketId, offer, 1000);
        assertEq(result, 50);
    }

    function test_capReduceOnly_buyOffer_zeroDebt() public {
        address noDebt = makeAddr("cro-no-debt");
        Offer memory offer = _offerFull(noDebt, true, 950, _uniqueGroup(), true, 1000, 0);
        uint256 result = harness.capReduceOnly(midnight, marketId, offer, 1000);
        assertEq(result, 0);
    }

    function test_capReduceOnly_sellOffer_capsToCredit() public {
        address lender = makeAddr("cro-lender");
        _setupLenderWithCredit(lender, 80);

        (uint128 lenderCredit,,) = midnight.updatePositionView(market, marketId, lender);
        assertTrue(lenderCredit > 0, "precondition: lender has credit");

        Offer memory offer = _offerFull(lender, false, 950, _uniqueGroup(), true, 1000, 0);
        uint256 result = harness.capReduceOnly(midnight, marketId, offer, 1000);
        assertEq(result, uint256(lenderCredit));
    }

    function test_capReduceOnly_sellOffer_withBadDebt() public {
        address lender = makeAddr("cro-lender-bd");
        _setupLenderWithCredit(lender, 100);

        (uint128 creditBefore,,) = midnight.updatePositionView(market, marketId, lender);
        assertTrue(creditBefore > 0, "precondition: lender has credit before bad debt");

        // Simulate bad debt: set market lossFactor to ~50% slashing
        _setLossFactor(type(uint128).max / 2);

        (uint128 creditAfter,,) = midnight.updatePositionView(market, marketId, lender);
        assertTrue(creditAfter < creditBefore, "precondition: credit slashed after bad debt");

        Offer memory offer = _offerFull(lender, false, 950, _uniqueGroup(), true, 1000, 0);
        uint256 result = harness.capReduceOnly(midnight, marketId, offer, 1000);
        assertEq(result, uint256(creditAfter));
    }

    function test_capReduceOnly_maxUnitsAlreadySmaller() public {
        (address borrower, uint256 borrowerSK) = makeAddrAndKey("cro-borrower2");
        _setupBorrowerWithDebt(borrower, borrowerSK, 1000);

        Offer memory offer = _offerFull(borrower, true, 950, _uniqueGroup(), true, 50, 0);
        uint256 result = harness.capReduceOnly(midnight, marketId, offer, 50);
        assertEq(result, 50, "min(50, 1000) = 50");
    }

    /* ═══════════════════════════════════════════════════════════════
       8. min overloads
       ═══════════════════════════════════════════════════════════════ */

    function test_min3() public {
        assertEq(harness.min3(5, 2, 8), 2);
    }

    function test_min3_cIsSmallest() public {
        assertEq(harness.min3(5, 8, 2), 2);
    }

    function test_min3_aIsSmallest() public {
        assertEq(harness.min3(1, 5, 8), 1);
    }
}
