// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test, stdError} from "forge-std/Test.sol";
import {Market, Offer, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";
import {IMarketMakingPolicy} from "../../src/ratifiers/interfaces/IMarketMakingPolicy.sol";
import {MidnightAdapterCurveRatifier} from "../../src/ratifiers/vault-v2/MidnightAdapterCurveRatifier.sol";
import {IMidnightAdapterCurveRatifier} from "../../src/ratifiers/vault-v2/interfaces/IMidnightAdapterCurveRatifier.sol";
import {
    AdapterMarketData,
    IMidnightAdapterMinimal
} from "../../src/ratifiers/vault-v2/interfaces/IMidnightAdapterMinimal.sol";
import {FourWeekCadence} from "../../src/ratifiers/policies/FourWeekCadence.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";

/// @dev Signatures of Midnight at vault-v2's pin (4e2570e5). Market and Offer are ABI-identical to this repo's.
interface IMidnightV2Pin {
    function enableLltv(uint256 lltv) external;
    function enableLiquidationCursor(uint256 liquidationCursor) external;
    function supplyCollateral(Market memory market, uint256 collateralIndex, uint256 assets, address onBehalf) external;
    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory takerCallbackData
    ) external returns (uint256 buyerAssets, uint256 sellerAssets);
    function consumed(address user, bytes32 group) external view returns (uint128);
    function credit(bytes32 id, address user) external view returns (uint128);
    function continuousFee(bytes32 id) external view returns (uint32);
    function tickSpacing(bytes32 id) external view returns (uint8);
    function setFeeSetter(address newFeeSetter) external;
    function setMarketContinuousFee(bytes32 id, uint256 newContinuousFee) external;
    function setMarketSettlementFee(bytes32 id, uint256 index, uint256 newSettlementFee) external;
    function lossFactor(bytes32 id) external view returns (uint128);
    function repay(Market memory market, uint256 units, address onBehalf, address callback, bytes calldata data)
        external;
    function liquidate(
        Market calldata market,
        uint256 collateralIndex,
        uint256 seizedAssets,
        uint256 repaidUnits,
        address borrower,
        bool postMaturityMode,
        address receiver,
        address callback,
        bytes calldata data
    ) external returns (uint256, uint256);
}

interface IVaultV2FactoryLike {
    function createVaultV2(address owner, address asset, bytes32 salt) external returns (address);
}

interface IVaultV2Like {
    function setCurator(address newCurator) external;
    function setIsSentinel(address account, bool newIsSentinel) external;
    function submit(bytes memory data) external;
    function setIsAllocator(address account, bool newIsAllocator) external;
    function addAdapter(address account) external;
    function increaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external;
    function decreaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external;
    function increaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external;
    function setMaxRate(uint256 newMaxRate) external;
    function deposit(uint256 assets, address onBehalf) external returns (uint256);
    function allocation(bytes32 id) external view returns (uint256);
    function totalAssets() external view returns (uint256);
}

interface IMidnightAdapterFactoryLike {
    function createMidnightAdapter(
        address parentVault,
        uint256[] memory durations,
        address enterGateFactory,
        bytes32 preSalt
    ) external returns (address);
}

interface IMidnightAdapterLike is IMidnightAdapterMinimal {
    function submit(bytes calldata data) external;
    function increaseMaxTtm(uint256 newMaxTtm) external;
    function increaseMaxNetSellRate(uint256 newMaxNetSellRate) external;
    function setIsSubRatifier(address subRatifier, bool newIsSubRatifier) external;
    function setConsumed(bytes32 group, uint128 amount) external;
    function shortfallAllowance() external view returns (uint128);
    function increaseShortfallAllowance(uint256 allowanceIncrease) external;
    function increaseMinNetBuyRate(uint256 newMinNetBuyRate) external;
    function decreaseMaxTtm(uint256 newMaxTtm) external;
    function decreaseMaxNetSellRate(uint256 newMaxNetSellRate) external;
    function setForceSellable(bytes32 marketId) external;
    function forceRemove(bytes32 marketId) external;
    function marketIdsLength() external view returns (uint256);
    function realAssets() external view returns (uint256);
}

/// @dev A taker of the adapter's sell offer that realizes `borrower`'s bad debt from its buy callback, while the
/// adapter is mid-sale.
contract LiquidatingBuyer {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");
    IMidnightV2Pin internal immutable MIDNIGHT;
    address internal immutable BORROWER;

    constructor(IMidnightV2Pin midnight, address loanToken, address borrower) {
        MIDNIGHT = midnight;
        BORROWER = borrower;
        MockERC20(loanToken).approve(address(midnight), type(uint256).max);
    }

    function take(Offer memory offer, bytes memory ratifierData, uint256 units) external {
        MIDNIGHT.take(offer, ratifierData, units, address(this), address(0), address(this), "");
    }

    function onBuy(bytes32, Market calldata market, uint256, uint256, uint256, address, bytes calldata)
        external
        returns (bytes32)
    {
        MIDNIGHT.liquidate(market, 0, 0, 0, BORROWER, false, address(this), address(0), "");
        return CALLBACK_SUCCESS;
    }
}

/// @dev Runs the curve sub-ratifier against genuine VaultV2, MidnightAdapter and Midnight bytecode from vault-v2
/// 6d815210 (see test/bin/vault-v2-midnight/README.md).
contract MidnightAdapterCurveRatifierIntegrationTest is Test {
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant TTM = 90 days;
    // "tenor" + version byte 0xF0, with any low 208 bits.
    bytes32 internal constant BUY_GROUP = bytes32(hex"74656e6f72f0") | bytes32(uint256(1));
    bytes32 internal constant SELL_GROUP = bytes32(hex"74656e6f72f0") | bytes32(uint256(2));
    uint256 internal constant DEPOSIT = 1_000_000e18;

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal sentinel = makeAddr("sentinel");
    address internal depositor = makeAddr("depositor");
    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");

    IMidnightV2Pin internal midnight;
    IVaultV2Like internal vault;
    IMidnightAdapterLike internal adapter;
    MidnightAdapterCurveRatifier internal ratifier;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    bytes internal idleFunding = abi.encode(address(0), bytes(""));

    function setUp() public {
        vm.setEvmVersion("osaka");
        vm.warp(1_800_000_000);

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COLL", 18);
        oracle = new Oracle();

        midnight = IMidnightV2Pin(deployCode("test/bin/vault-v2-midnight/Midnight.json"));
        midnight.enableLltv(1e18);
        midnight.enableLiquidationCursor(0.25e18);

        IVaultV2FactoryLike vaultFactory =
            IVaultV2FactoryLike(deployCode("test/bin/vault-v2-midnight/VaultV2Factory.json"));
        vault = IVaultV2Like(vaultFactory.createVaultV2(owner, address(loanToken), bytes32(0)));
        vm.startPrank(owner);
        vault.setCurator(curator);
        vault.setIsSentinel(sentinel, true);
        vm.stopPrank();
        _submitAndSet(address(vault), abi.encodeCall(IVaultV2Like.setIsAllocator, (allocator, true)));

        uint256[] memory durations = new uint256[](1);
        durations[0] = 7 days;
        IMidnightAdapterFactoryLike adapterFactory = IMidnightAdapterFactoryLike(
            deployCode("test/bin/vault-v2-midnight/MidnightAdapterFactory.json", abi.encode(address(midnight)))
        );
        adapter = IMidnightAdapterLike(
            adapterFactory.createMidnightAdapter(address(vault), durations, address(0), bytes32(0))
        );

        _submitAndSet(address(adapter), abi.encodeCall(IMidnightAdapterLike.increaseMaxTtm, (180 days)));
        _submitAndSet(
            address(adapter), abi.encodeCall(IMidnightAdapterLike.increaseMaxNetSellRate, (uint256(1e18) / YEAR))
        );
        _submitAndSet(address(vault), abi.encodeCall(IVaultV2Like.addAdapter, (address(adapter))));
        _submitAndSet(address(vault), abi.encodeCall(IVaultV2Like.setIsAllocator, (address(adapter), true)));
        vm.prank(allocator);
        vault.setMaxRate(uint256(1e18) / YEAR);

        Market memory market = _market();
        _increaseCaps(abi.encode("this", address(adapter)));
        _increaseCaps(abi.encode("collateralToken", address(collateralToken)));
        _increaseCaps(
            abi.encode(
                "collateralParams/rcfThreshold/liquidatorGate/enterGate",
                market.collateralParams,
                market.rcfThreshold,
                market.liquidatorGate,
                market.enterGate
            )
        );
        _increaseCaps(abi.encode("this/duration", address(adapter), 7 days));

        // Create the market, which sets its tick spacing.
        collateralToken.mint(address(this), 1);
        collateralToken.approve(address(midnight), 1);
        midnight.supplyCollateral(market, 0, 1, address(this));

        loanToken.mint(depositor, DEPOSIT);
        vm.startPrank(depositor);
        loanToken.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, depositor);
        vm.stopPrank();

        // Tenor curve sub-ratifier, configured by the vault's allocator.
        ratifier = new MidnightAdapterCurveRatifier();
        vm.startPrank(allocator);
        adapter.setIsSubRatifier(address(ratifier), true);
        ratifier.setCurve(address(adapter), TenorMarketIdLib.toTenorMarketId(market), _curve(3, 5, 4, 7), allocator);
        ratifier.setIsFundingSource(address(adapter), idleFunding, true, allocator);
        ratifier.setCadence(address(adapter), address(new FourWeekCadence()), allocator);
        vm.stopPrank();
    }

    /* HELPERS */

    function _submitAndSet(address target, bytes memory data) internal {
        vm.prank(curator);
        IVaultV2Like(target).submit(data);
        (bool success, bytes memory returnData) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    function _increaseCaps(bytes memory idData) internal {
        _submitAndSet(address(vault), abi.encodeCall(IVaultV2Like.increaseAbsoluteCap, (idData, type(uint128).max)));
        _submitAndSet(address(vault), abi.encodeCall(IVaultV2Like.increaseRelativeCap, (idData, 1e18)));
    }

    function _apr(uint256 percent) internal pure returns (uint112) {
        return uint112(percent * 1e16 / YEAR);
    }

    function _curve(uint256 sellShort, uint256 buyShort, uint256 sellLong, uint256 buyLong)
        internal
        pure
        returns (IMarketMakingPolicy.CurvePoint[] memory points)
    {
        points = new IMarketMakingPolicy.CurvePoint[](2);
        points[0] = IMarketMakingPolicy.CurvePoint({ttm: 7 days, sellRate: _apr(sellShort), buyRate: _apr(buyShort)});
        points[1] = IMarketMakingPolicy.CurvePoint({ttm: 180 days, sellRate: _apr(sellLong), buyRate: _apr(buyLong)});
    }

    /// @dev The market's maturity is fixed at setUp time, on the four-week cadence about TTM out; warps shorten its
    /// ttm.
    function _market() internal view returns (Market memory) {
        return _marketAt(((1_800_000_000 + TTM) / 28 days) * 28 days);
    }

    function _marketAt(uint256 maturity) internal view returns (Market memory market) {
        CollateralParams[] memory collateralParams = new CollateralParams[](1);
        collateralParams[0] = CollateralParams({
            token: address(collateralToken), lltv: 1e18, liquidationCursor: 0.25e18, oracle: address(oracle)
        });
        market.chainId = block.chainid;
        market.midnight = address(midnight);
        market.loanToken = address(loanToken);
        market.collateralParams = collateralParams;
        market.maturity = maturity;
    }

    function _ratifierData() internal view returns (bytes memory) {
        return abi.encode(address(ratifier), bytes(""));
    }

    function _buyOffer(uint256 tick) internal view returns (Offer memory) {
        return _buyOffer(_market(), tick);
    }

    function _buyOffer(Market memory market, uint256 tick) internal view returns (Offer memory offer) {
        offer.market = market;
        offer.buy = true;
        offer.maker = address(adapter);
        offer.start = block.timestamp;
        offer.expiry = offer.market.maturity;
        offer.tick = tick;
        offer.group = BUY_GROUP;
        offer.callback = address(adapter);
        offer.callbackData = idleFunding;
        offer.ratifier = address(adapter);
        offer.maxAssets = type(uint128).max;
        offer.continuousFeeCap = type(uint256).max;
    }

    function _sellOffer(uint256 tick) internal view returns (Offer memory) {
        return _sellOffer(_market(), tick);
    }

    function _sellOffer(Market memory market, uint256 tick) internal view returns (Offer memory offer) {
        offer.market = market;
        offer.buy = false;
        offer.maker = address(adapter);
        offer.start = block.timestamp;
        offer.expiry = offer.market.maturity;
        offer.tick = tick;
        offer.group = SELL_GROUP;
        offer.callback = address(adapter);
        offer.receiverIfMakerIsSeller = address(adapter);
        offer.ratifier = address(adapter);
        offer.reduceOnly = true;
        offer.maxAssets = type(uint128).max;
        offer.continuousFeeCap = type(uint256).max;
    }

    /// @dev Highest tick the curve ratifies for a buy now.
    function _buyTick() internal view returns (uint256) {
        return _buyTick(_market());
    }

    function _buyTick(Market memory market) internal view returns (uint256 tick) {
        uint256 ttm = market.maturity - block.timestamp;
        uint256 rate = ratifier.buyRateBound(address(adapter), market);
        uint256 netUnitsPerWad = WAD - uint256(midnight.continuousFee(IdLib.toId(market))) * ttm;
        uint256 maxPrice = UtilsLib.mulDivDown(netUnitsPerWad, UtilsLib.mulDivDown(WAD, WAD, WAD + rate * ttm), WAD);
        uint256 spacing = _spacing();
        tick = TickLib.priceToTick(maxPrice, spacing);
        while (tick + spacing <= MAX_TICK && TickLib.tickToPrice(tick + spacing) <= maxPrice) tick += spacing;
        while (tick >= spacing && TickLib.tickToPrice(tick) > maxPrice) tick -= spacing;
    }

    /// @dev Lowest tick the curve ratifies for a sell now.
    function _sellTick() internal view returns (uint256) {
        return _sellTick(_market());
    }

    function _sellTick(Market memory market) internal view returns (uint256 tick) {
        uint256 ttm = market.maturity - block.timestamp;
        uint256 rate = ratifier.sellRateBound(address(adapter), market);
        uint256 minPrice = UtilsLib.mulDivUp(WAD, WAD, WAD + rate * ttm);
        uint256 spacing = _spacing();
        tick = TickLib.priceToTick(minPrice, spacing);
        while (tick >= spacing && TickLib.tickToPrice(tick - spacing) >= minPrice) tick -= spacing;
        while (tick + spacing <= MAX_TICK && TickLib.tickToPrice(tick) < minPrice) tick += spacing;
    }

    function _spacing() internal view returns (uint256) {
        return midnight.tickSpacing(IdLib.toId(_market()));
    }

    /// @dev The borrower sells `units` to the adapter's buy offer.
    function _borrowerTakesBuy(uint256 tick, uint256 units) internal returns (uint256) {
        return _takesBuy(borrower, _market(), tick, units);
    }

    /// @dev `seller` posts twice the units in collateral and sells `units` to the adapter's buy offer in `market`.
    function _takesBuy(address seller, Market memory market, uint256 tick, uint256 units)
        internal
        returns (uint256 buyerAssets)
    {
        _supplyCollateral(seller, market, units * 2);
        vm.prank(seller);
        (buyerAssets,) = midnight.take(_buyOffer(market, tick), _ratifierData(), units, seller, seller, address(0), "");
    }

    function _supplyCollateral(address account, Market memory market, uint256 collateral) internal {
        collateralToken.mint(account, collateral);
        vm.startPrank(account);
        collateralToken.approve(address(midnight), collateral);
        midnight.supplyCollateral(market, 0, collateral, account);
        vm.stopPrank();
    }

    /// @dev Expects `seller`'s take of the adapter's buy offer at `offer` to revert with `err`.
    function _expectBuyRevert(Offer memory offer, uint256 units, bytes memory err) internal {
        _supplyCollateral(borrower, offer.market, units * 2);
        bytes memory data = _ratifierData();
        vm.prank(borrower);
        vm.expectRevert(err);
        midnight.take(offer, data, units, borrower, borrower, address(0), "");
    }

    /// @dev Expects the lender's take of the adapter's sell offer at `offer` to revert with `err`.
    function _expectSellRevert(Offer memory offer, uint256 units, bytes memory err) internal {
        loanToken.mint(lender, units);
        bytes memory data = _ratifierData();
        vm.startPrank(lender);
        loanToken.approve(address(midnight), units);
        vm.expectRevert(err);
        midnight.take(offer, data, units, lender, address(0), address(0), "");
        vm.stopPrank();
    }

    function _err(string memory signature) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(bytes4(keccak256(bytes(signature))));
    }

    /// @dev Drops the collateral price so that the borrower's debt is half covered, then realizes the bad debt.
    function _realizeBadDebt(Market memory market) internal {
        oracle.setPrice(0.25e36);
        midnight.liquidate(market, 0, 0, 0, borrower, false, address(this), address(0), "");
    }

    /// @dev The lender buys `units` from the adapter's sell offer.
    function _lenderTakesSell(uint256 tick, uint256 units) internal returns (uint256 sellerAssets) {
        loanToken.mint(lender, units);
        vm.startPrank(lender);
        loanToken.approve(address(midnight), units);
        (, sellerAssets) = midnight.take(_sellOffer(tick), _ratifierData(), units, lender, address(0), address(0), "");
        vm.stopPrank();
    }

    /* TESTS */

    function testMakerBuyFromIdleAtCurve() public {
        bytes32 id = IdLib.toId(_market());
        uint256 curveRate = ratifier.buyRateBound(address(adapter), _market());
        uint256 buyerAssets = _borrowerTakesBuy(_buyTick(), 100_000e18);

        AdapterMarketData memory md = adapter.marketData(id);
        assertGe(md.netRate, curveRate, "net rate below curve");
        assertEq(midnight.credit(id, address(adapter)), 100_000e18);
        assertEq(midnight.consumed(address(adapter), BUY_GROUP), buyerAssets);
        assertEq(vault.allocation(keccak256(abi.encode("this", address(adapter)))), md.netCredit);
    }

    function testMakerBuyWorseTickReverts() public {
        uint256 tick = _buyTick() + _spacing();
        collateralToken.mint(borrower, 200_000e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), 200_000e18);
        midnight.supplyCollateral(_market(), 0, 200_000e18, borrower);
        Offer memory offer = _buyOffer(tick);
        bytes memory data = _ratifierData();
        vm.expectRevert(IMidnightAdapterCurveRatifier.WorsePrice.selector);
        midnight.take(offer, data, 100_000e18, borrower, borrower, address(0), "");
        vm.stopPrank();
    }

    function testMakerSellHasNoShortfall() public {
        bytes32 id = IdLib.toId(_market());
        _borrowerTakesBuy(_buyTick(), 100_000e18);
        vm.warp(block.timestamp + 30 days);

        uint64 netRateBefore = adapter.marketData(id).netRate;
        _lenderTakesSell(_sellTick(), 40_000e18);

        // shortfallAllowance is 0, so any shortfall would have reverted the take; the rate is untouched.
        assertEq(adapter.shortfallAllowance(), 0);
        assertEq(adapter.marketData(id).netRate, netRateBefore);
        assertEq(midnight.credit(id, address(adapter)), 60_000e18);
    }

    /// @dev A sell curve raised above the rate the vault bought at is capped at the market's net rate.
    function testRaisedSellCurveIsCappedAtNetRate() public {
        Market memory market = _market();
        bytes32 id = IdLib.toId(market);
        _borrowerTakesBuy(_buyTick(), 100_000e18);

        vm.prank(allocator);
        ratifier.setCurve(address(adapter), TenorMarketIdLib.toTenorMarketId(market), _curve(20, 20, 20, 20), allocator);
        uint256 netRate = adapter.marketData(id).netRate;
        assertEq(ratifier.sellRateBound(address(adapter), market), netRate);

        uint256 tick = _sellTick();
        loanToken.mint(lender, 40_000e18);
        vm.startPrank(lender);
        loanToken.approve(address(midnight), 40_000e18);
        Offer memory worse = _sellOffer(tick - _spacing());
        bytes memory data = _ratifierData();
        vm.expectRevert(IMidnightAdapterCurveRatifier.WorsePrice.selector);
        midnight.take(worse, data, 40_000e18, lender, address(0), address(0), "");
        midnight.take(_sellOffer(tick), data, 40_000e18, lender, address(0), address(0), "");
        vm.stopPrank();
        assertEq(adapter.marketData(id).netRate, netRate);
    }

    function testSentinelRemovesSubRatifier() public {
        uint256 tick = _buyTick();
        vm.prank(sentinel);
        adapter.setIsSubRatifier(address(ratifier), false);

        collateralToken.mint(borrower, 200_000e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), 200_000e18);
        midnight.supplyCollateral(_market(), 0, 200_000e18, borrower);
        Offer memory offer = _buyOffer(tick);
        bytes memory data = _ratifierData();
        vm.expectRevert(bytes4(keccak256("SubRatifierFailed()")));
        midnight.take(offer, data, 100_000e18, borrower, borrower, address(0), "");
        vm.stopPrank();
    }

    function testSentinelClearsCurve() public {
        uint256 tick = _buyTick();
        vm.prank(sentinel);
        ratifier.clearCurve(address(adapter), TenorMarketIdLib.toTenorMarketId(_market()), sentinel);

        collateralToken.mint(borrower, 200_000e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), 200_000e18);
        midnight.supplyCollateral(_market(), 0, 200_000e18, borrower);
        Offer memory offer = _buyOffer(tick);
        bytes memory data = _ratifierData();
        vm.expectRevert(IMidnightAdapterCurveRatifier.NoCurve.selector);
        midnight.take(offer, data, 100_000e18, borrower, borrower, address(0), "");
        vm.stopPrank();
    }

    /// @dev `consumed` bounds nothing: a group used up in Midnight only stops offers in that group, and a taker
    /// picks another one under the header.
    function testConsumedDoesNotBindAcrossGroups() public {
        uint256 tick = _buyTick();
        vm.prank(sentinel);
        adapter.setConsumed(BUY_GROUP, type(uint128).max);
        _expectBuyRevert(_buyOffer(tick), 1e18, _err("ConsumedAssets()"));

        Offer memory offer = _buyOffer(tick);
        offer.group = BUY_GROUP ^ bytes32(uint256(0xff));
        vm.prank(borrower);
        midnight.take(offer, _ratifierData(), 1e18, borrower, borrower, address(0), "");
        assertEq(midnight.credit(IdLib.toId(_market()), address(adapter)), 1e18);
    }

    function testFuzzFillsAtBoundsPassAdapter(uint256 feeFraction, uint256 units, uint256 elapsed, uint256 soldBps)
        public
    {
        Market memory market = _market();
        bytes32 id = IdLib.toId(market);
        uint256 fee = bound(feeFraction, 0, 1e4) * (uint256(0.01e18) / YEAR) / 1e4;
        units = bound(units, 1e18, 400_000e18);
        elapsed = bound(elapsed, 0, 80 days);
        // Accrued continuous fees lower credit below the bought units, so a full reduce-only sale would be rejected.
        uint256 soldUnits = units * bound(soldBps, 1, 9_000) / 10_000;
        vm.assume(soldUnits > 0);

        midnight.setFeeSetter(address(this));
        midnight.setMarketContinuousFee(id, fee);

        uint256 buyBound = ratifier.buyRateBound(address(adapter), market);
        _borrowerTakesBuy(_buyTick(), units);
        assertGe(adapter.marketData(id).netRate, buyBound, "net rate below curve");

        vm.warp(block.timestamp + elapsed);
        uint64 netRateBefore = adapter.marketData(id).netRate;
        _lenderTakesSell(_sellTick(), soldUnits);
        assertEq(adapter.marketData(id).netRate, netRateBefore, "shortfall reduced rates");
        assertEq(adapter.shortfallAllowance(), 0);
    }

    /* ADAPTER GUARDRAILS: not checked by the ratifier, the adapter reverts the take itself */

    function testBuyBelowMinNetBuyRateRevertsInAdapter() public {
        uint256 tick = _buyTick();
        vm.prank(curator);
        adapter.increaseMinNetBuyRate(_apr(50));
        _expectBuyRevert(_buyOffer(tick), 100_000e18, _err("NetBuyRateTooLow()"));
    }

    function testBuyAboveMaxTtmRevertsInAdapter() public {
        uint256 tick = _buyTick();
        vm.prank(curator);
        adapter.decreaseMaxTtm(30 days);
        _expectBuyRevert(_buyOffer(tick), 100_000e18, _err("BuyTtmTooHigh()"));
    }

    function testSellAboveMaxNetSellRateRevertsInAdapter() public {
        _borrowerTakesBuy(_buyTick(), 100_000e18);
        uint256 tick = _sellTick();
        vm.prank(curator);
        adapter.decreaseMaxNetSellRate(_apr(1));
        _expectSellRevert(_sellOffer(tick), 40_000e18, _err("NetSellRateTooHigh()"));
    }

    /// @dev In a force-sellable market the adapter stops buys, and the ratifier stops sells.
    function testForceSellableMarket() public {
        _borrowerTakesBuy(_buyTick(), 100_000e18);
        uint256 buyTick = _buyTick();
        uint256 sellTick = _sellTick();
        _submitAndSet(address(adapter), abi.encodeCall(IMidnightAdapterLike.setForceSellable, (IdLib.toId(_market()))));

        _expectBuyRevert(_buyOffer(buyTick), 1_000e18, _err("UnauthorizedBuy()"));
        _expectSellRevert(
            _sellOffer(sellTick), 1_000e18, abi.encodeWithSelector(IMidnightAdapterCurveRatifier.ForceSellable.selector)
        );
    }

    function testForceRemovedMarket() public {
        _borrowerTakesBuy(_buyTick(), 100_000e18);
        uint256 buyTick = _buyTick();
        _submitAndSet(address(adapter), abi.encodeCall(IMidnightAdapterLike.forceRemove, (IdLib.toId(_market()))));

        _expectBuyRevert(_buyOffer(buyTick), 1_000e18, _err("ForceRemoved()"));
        // The removed market has no net rate left, so only par passes the ratifier. The adapter then rejects it.
        _expectSellRevert(_sellOffer(MAX_TICK), 1_000e18, _err("ForceRemoved()"));
    }

    /* LOOP */

    /// @dev Selling to the adapter and buying back in the same block costs the taker, with a settlement fee on.
    function testLoopCostsTheTaker() public {
        bytes32 id = IdLib.toId(_market());
        midnight.setFeeSetter(address(this));
        for (uint256 i; i < 7; i++) {
            midnight.setMarketSettlementFee(id, i, 1e13);
        }

        uint256 units = 100_000e18;
        loanToken.mint(borrower, units);
        vm.prank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);
        uint256 takerBefore = loanToken.balanceOf(borrower);

        _borrowerTakesBuy(_buyTick(), units);
        // The borrower buys its units back from the adapter, which closes its debt.
        uint256 tick = _sellTick();
        vm.prank(borrower);
        midnight.take(_sellOffer(tick), _ratifierData(), units, borrower, address(0), address(0), "");

        assertEq(midnight.credit(id, address(adapter)), 0);
        assertEq(adapter.marketIdsLength(), 0);
        assertLt(loanToken.balanceOf(borrower), takerBefore, "taker gained");
        assertGt(loanToken.balanceOf(address(vault)), DEPOSIT, "vault did not gain");
    }

    /* NO SHORTFALL, WITH OTHER MARKETS AND AN ALLOWANCE TO CONSUME */

    /// @dev A sell at the tightest ratified price, the net rate cap, consumes no shortfall allowance and leaves the
    /// rate of the adapter's other market untouched.
    function testSellAtNetRateCapLeavesOtherMarketUntouched() public {
        Market memory market = _market();
        Market memory other = _marketAt(market.maturity + 28 days);
        bytes32 id = IdLib.toId(market);
        bytes32 otherId = IdLib.toId(other);
        _submitAndSet(address(adapter), abi.encodeCall(IMidnightAdapterLike.increaseShortfallAllowance, (1_000e18)));

        _borrowerTakesBuy(_buyTick(), 100_000e18);
        _takesBuy(borrower, other, _buyTick(other), 100_000e18);
        assertEq(adapter.marketIdsLength(), 2);
        vm.warp(block.timestamp + 30 days);

        vm.prank(allocator);
        ratifier.setCurve(address(adapter), TenorMarketIdLib.toTenorMarketId(market), _curve(20, 20, 20, 20), allocator);
        uint64 netRate = adapter.marketData(id).netRate;
        uint64 otherNetRate = adapter.marketData(otherId).netRate;
        assertEq(ratifier.sellRateBound(address(adapter), market), netRate);

        _lenderTakesSell(_sellTick(), 40_000e18);

        assertEq(adapter.shortfallAllowance(), 1_000e18, "shortfall consumed");
        assertEq(adapter.marketData(id).netRate, netRate);
        assertEq(adapter.marketData(otherId).netRate, otherNetRate, "other market's rate reduced");
    }

    /* BAD DEBT */

    /// @dev A realized loss stops buys in the market and leaves the exit open, still without a shortfall.
    function testLossRejectsBuysNotSells() public {
        Market memory market = _market();
        bytes32 id = IdLib.toId(market);
        _borrowerTakesBuy(_buyTick(), 100_000e18);
        uint256 buyTick = _buyTick();
        uint64 netRate = adapter.marketData(id).netRate;

        _realizeBadDebt(market);
        assertGt(midnight.lossFactor(id), 0);

        _expectBuyRevert(
            _buyOffer(buyTick), 1_000e18, abi.encodeWithSelector(IMidnightAdapterCurveRatifier.MarketHasLoss.selector)
        );

        // Half of the adapter's credit is gone. It sells 20,000 of the 50,000 left.
        _lenderTakesSell(_sellTick(), 20_000e18);
        assertEq(adapter.shortfallAllowance(), 0);
        assertEq(adapter.marketData(id).netRate, netRate);
        assertApproxEqAbs(adapter.marketData(id).netCredit, 30_000e18, 1e3);
    }

    /// @dev The loss factor is zero at ratification and the bad debt is realized in the taker's buy callback, mid-sale.
    /// The buyer bears it on the units it bought, and the adapter's sale still has no shortfall.
    function testBadDebtRealizedInsideASell() public {
        bytes32 id = IdLib.toId(_market());
        _borrowerTakesBuy(_buyTick(), 100_000e18);
        vm.warp(block.timestamp + 30 days);
        uint64 netRate = adapter.marketData(id).netRate;
        uint256 tick = _sellTick();

        oracle.setPrice(0.25e36);
        LiquidatingBuyer buyer = new LiquidatingBuyer(midnight, address(loanToken), borrower);
        loanToken.mint(address(buyer), 40_000e18);
        buyer.take(_sellOffer(tick), _ratifierData(), 40_000e18);

        assertGt(midnight.lossFactor(id), 0);
        assertEq(adapter.shortfallAllowance(), 0);
        assertEq(adapter.marketData(id).netRate, netRate);
        // 60,000 units were left to the adapter, then halved by the loss.
        assertApproxEqAbs(adapter.marketData(id).netCredit, 30_000e18, 1e3);
    }

    /// @dev Accepted risk, see STANDING CONSENT: bad debt that is not realized yet is invisible to the ratifier. A
    /// lender exits to the adapter at the curve price, and the vault bears the loss alone once it is realized.
    function testPendingBadDebtCanBeSoldToTheAdapter() public {
        Market memory market = _market();
        bytes32 id = IdLib.toId(market);
        _borrowerTakesBuy(_buyTick(), 100_000e18);
        _lenderTakesSell(_sellTick(), 50_000e18);

        // The borrower's collateral now covers half of its debt, and nobody has liquidated it yet.
        oracle.setPrice(0.25e36);
        uint256 tick = _buyTick();
        uint256 lenderBefore = loanToken.balanceOf(lender);
        vm.prank(lender);
        midnight.take(_buyOffer(tick), _ratifierData(), 50_000e18, lender, lender, address(0), "");
        assertEq(midnight.credit(id, lender), 0);
        assertGt(loanToken.balanceOf(lender), lenderBefore);

        uint256 realAssetsBefore = adapter.realAssets();
        midnight.liquidate(market, 0, 0, 0, borrower, false, address(this), address(0), "");
        assertApproxEqAbs(adapter.realAssets(), realAssetsBefore / 2, 1e3);
    }

    /* DUST */

    function testDustBuys() public {
        bytes32 id = IdLib.toId(_market());
        uint256 tick = _buyTick();

        // A first buy that pays nothing cannot open a market: the adapter divides by its zero cost.
        _expectBuyRevert(_buyOffer(tick), 1, stdError.divisionError);
        assertEq(adapter.marketIdsLength(), 0);

        // In a market the adapter already holds, it is free credit and it consumes nothing.
        uint256 consumed = _borrowerTakesBuy(tick, 100_000e18);
        assertEq(_borrowerTakesBuy(tick, 1), 0);
        assertEq(midnight.consumed(address(adapter), BUY_GROUP), consumed);
        assertEq(midnight.credit(id, address(adapter)), 100_000e18 + 1);
    }

    /* SIZE */

    /// @dev There is no fill budget: cumulative buys go past any fixed amount, and the vault's caps bound them.
    function testBuysBoundedByCapsOnly() public {
        uint256 tick = _buyTick();
        uint256 first = _borrowerTakesBuy(tick, 400_000e18);
        uint256 second = _borrowerTakesBuy(tick, 400_000e18);
        assertEq(midnight.consumed(address(adapter), BUY_GROUP), first + second);

        // A sentinel lowers the adapter's cap to its allocation: nothing more fills.
        bytes memory adapterIdData = abi.encode("this", address(adapter));
        uint256 allocation = vault.allocation(keccak256(adapterIdData));
        vm.prank(sentinel);
        vault.decreaseAbsoluteCap(adapterIdData, allocation);
        _expectBuyRevert(_buyOffer(tick), 1_000e18, _err("AbsoluteCapExceeded()"));
    }

    function testBuyFundedFromAnotherMarket() public {
        Market memory market = _market();
        Market memory other = _marketAt(market.maturity + 28 days);
        _borrowerTakesBuy(_buyTick(), 100_000e18);

        // The borrower repays early, which leaves withdrawable assets in the first market.
        loanToken.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        loanToken.approve(address(midnight), 100_000e18);
        midnight.repay(market, 100_000e18, borrower, address(0), "");
        vm.stopPrank();

        bytes memory selfFunding = abi.encode(address(adapter), abi.encode(market));
        Offer memory offer = _buyOffer(other, _buyTick(other));
        offer.callbackData = selfFunding;
        _expectBuyRevert(
            offer, 50_000e18, abi.encodeWithSelector(IMidnightAdapterCurveRatifier.UnauthorizedFundingSource.selector)
        );

        // Rolling only covers matured markets: early repayments need an exact allowed entry.
        vm.prank(allocator);
        ratifier.setAllowsRolling(address(adapter), true, allocator);
        _expectBuyRevert(
            offer, 50_000e18, abi.encodeWithSelector(IMidnightAdapterCurveRatifier.FundingMarketNotMatured.selector)
        );

        vm.prank(allocator);
        ratifier.setIsFundingSource(address(adapter), selfFunding, true, allocator);
        uint256 idle = loanToken.balanceOf(address(vault));
        vm.prank(borrower);
        (uint256 buyerAssets,) = midnight.take(offer, _ratifierData(), 50_000e18, borrower, borrower, address(0), "");

        assertEq(loanToken.balanceOf(address(vault)), idle);
        assertEq(midnight.credit(IdLib.toId(market), address(adapter)), 100_000e18 - buyerAssets);
        assertEq(midnight.credit(IdLib.toId(other), address(adapter)), 50_000e18);
    }

    /// @dev The vault lends at one cadence maturity, the borrower repays at maturity, and the next maturity is funded
    /// from the matured credit, then from the matured credit and idle together, with no allocator action.
    function testRollMaturedCreditIntoNextMaturity() public {
        Market memory matured = _market();
        Market memory next = _marketAt(matured.maturity + 28 days);
        bytes32 maturedId = IdLib.toId(matured);
        bytes32 nextId = IdLib.toId(next);
        _borrowerTakesBuy(_buyTick(), 100_000e18);

        vm.warp(matured.maturity);
        loanToken.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        loanToken.approve(address(midnight), 100_000e18);
        midnight.repay(matured, 100_000e18, borrower, address(0), "");
        vm.stopPrank();

        Offer memory roll = _buyOffer(next, _buyTick(next));
        roll.callbackData = abi.encode(address(adapter), abi.encode(matured));
        _expectBuyRevert(
            roll, 50_000e18, abi.encodeWithSelector(IMidnightAdapterCurveRatifier.UnauthorizedFundingSource.selector)
        );

        // Set once. No entry names the matured market.
        vm.prank(allocator);
        ratifier.setAllowsRolling(address(adapter), true, allocator);

        // 1. A buy funded entirely from the matured market.
        uint256 idle = loanToken.balanceOf(address(vault));
        uint256 consumedBefore = midnight.consumed(address(adapter), BUY_GROUP);
        _supplyCollateral(borrower, next, 100_000e18);
        vm.prank(borrower);
        (uint256 rolled,) = midnight.take(roll, _ratifierData(), 50_000e18, borrower, borrower, address(0), "");
        assertEq(loanToken.balanceOf(address(vault)), idle, "idle moved");
        assertEq(midnight.credit(maturedId, address(adapter)), 100_000e18 - rolled, "matured credit");
        assertEq(midnight.credit(nextId, address(adapter)), 50_000e18, "next credit");
        assertEq(midnight.consumed(address(adapter), BUY_GROUP), consumedBefore + rolled, "consumed");

        // 2. More than the matured market holds reverts in Midnight's withdraw.
        uint256 left = 100_000e18 - rolled;
        _supplyCollateral(borrower, next, 200_000e18);
        vm.prank(borrower);
        vm.expectRevert();
        midnight.take(roll, _ratifierData(), left * 2, borrower, borrower, address(0), "");

        // 3. A route over two sources: the rest of the matured credit, then idle. Same offer but the callback data.
        vm.startPrank(borrower);
        (uint256 rolledAgain,) =
            midnight.take(roll, _ratifierData(), left * 99 / 100, borrower, borrower, address(0), "");
        (uint256 fromIdle,) =
            midnight.take(_buyOffer(next, roll.tick), _ratifierData(), 20_000e18, borrower, borrower, address(0), "");
        vm.stopPrank();
        assertEq(midnight.credit(maturedId, address(adapter)), left - rolledAgain, "matured credit after route");
        assertEq(loanToken.balanceOf(address(vault)), idle - fromIdle, "only the idle leg used idle");
        assertEq(
            midnight.consumed(address(adapter), BUY_GROUP), consumedBefore + rolled + rolledAgain + fromIdle, "consumed"
        );
    }
}
