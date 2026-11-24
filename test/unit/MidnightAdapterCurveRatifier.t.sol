// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Market, Offer, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS, WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";
import {IMarketMakingPolicy} from "../../src/ratifiers/interfaces/IMarketMakingPolicy.sol";
import {MidnightAdapterCurveRatifier} from "../../src/ratifiers/vault-v2/MidnightAdapterCurveRatifier.sol";
import {IMidnightAdapterCurveRatifier} from "../../src/ratifiers/vault-v2/interfaces/IMidnightAdapterCurveRatifier.sol";
import {AdapterMarketData} from "../../src/ratifiers/vault-v2/interfaces/IMidnightAdapterMinimal.sol";
import {FourWeekCadence} from "../../src/ratifiers/policies/FourWeekCadence.sol";
import {MockRenewalCadence} from "../helpers/MockRenewalCadence.sol";

contract MockCurveMidnight {
    mapping(address => mapping(address => bool)) public isAuthorized;
    mapping(bytes32 => uint128) public lossFactor;
    mapping(bytes32 => uint32) public continuousFee;

    function setIsAuthorized(address authorizer, address authorized, bool value) external {
        isAuthorized[authorizer][authorized] = value;
    }

    function setLossFactor(bytes32 id, uint128 value) external {
        lossFactor[id] = value;
    }

    function setContinuousFee(bytes32 id, uint32 value) external {
        continuousFee[id] = value;
    }
}

contract MockCurveVault {
    mapping(address => bool) public isAllocator;
    mapping(address => bool) public isSentinel;

    function setIsAllocator(address account, bool value) external {
        isAllocator[account] = value;
    }

    function setIsSentinel(address account, bool value) external {
        isSentinel[account] = value;
    }
}

/// @dev Stands in for vault-v2's MidnightAdapter: exposes the read surface and forwards ratification as the maker.
contract MockCurveAdapter {
    address public parentVault;
    address public midnight;
    mapping(bytes32 => AdapterMarketData) internal _marketData;

    constructor(address _parentVault, address _midnight) {
        parentVault = _parentVault;
        midnight = _midnight;
    }

    function setMarketData(bytes32 id, AdapterMarketData memory data) external {
        _marketData[id] = data;
    }

    function marketData(bytes32 id) external view returns (AdapterMarketData memory) {
        return _marketData[id];
    }

    function forward(address subRatifier, Offer memory offer, bytes memory data) external view returns (bytes32) {
        return IMidnightAdapterCurveRatifier(subRatifier).isRatified(offer, data, address(0xBEEF));
    }
}

contract MidnightAdapterCurveRatifierTest is Test {
    uint256 internal constant YEAR = 365 days;
    // "tenor" + version byte 0xF0, with any low 208 bits.
    bytes32 internal constant BUY_GROUP = bytes32(hex"74656e6f72f0") | bytes32(uint256(1));
    bytes32 internal constant SELL_GROUP = bytes32(hex"74656e6f72f0") | bytes32(uint256(2));

    MidnightAdapterCurveRatifier internal ratifier;
    MockCurveMidnight internal midnight;
    MockCurveVault internal vault;
    MockCurveAdapter internal adapter;

    address internal allocator = makeAddr("allocator");
    address internal sentinel = makeAddr("sentinel");
    address internal stranger = makeAddr("stranger");
    address internal delegate = makeAddr("delegate");
    address internal loanToken = makeAddr("loanToken");

    bytes internal idleFunding = abi.encode(address(0), bytes(""));

    function setUp() public {
        vm.warp(1_800_000_000);
        ratifier = new MidnightAdapterCurveRatifier();
        midnight = new MockCurveMidnight();
        vault = new MockCurveVault();
        adapter = new MockCurveAdapter(address(vault), address(midnight));
        vault.setIsAllocator(allocator, true);
        vault.setIsSentinel(sentinel, true);

        vm.startPrank(allocator);
        ratifier.setCurve(address(adapter), _tenorId(), _defaultCurve(), allocator);
        ratifier.setIsFundingSource(address(adapter), idleFunding, true, allocator);
        // Identity cadence: every maturity is on it. Cadence tests below use FourWeekCadence.
        ratifier.setCadence(address(adapter), address(new MockRenewalCadence()), allocator);
        vm.stopPrank();

        adapter.setMarketData(IdLib.toId(_market(90 days)), _md(_apr(6)));
    }

    /* HELPERS */

    function _apr(uint256 percent) internal pure returns (uint112) {
        return uint112(percent * 1e16 / YEAR);
    }

    function _defaultCurve() internal pure returns (IMarketMakingPolicy.CurvePoint[] memory points) {
        points = new IMarketMakingPolicy.CurvePoint[](2);
        points[0] = IMarketMakingPolicy.CurvePoint({ttm: 7 days, sellRate: _apr(3), buyRate: _apr(5)});
        points[1] = IMarketMakingPolicy.CurvePoint({ttm: 180 days, sellRate: _apr(4), buyRate: _apr(7)});
    }

    function _md(uint256 netRate) internal pure returns (AdapterMarketData memory md) {
        md.netCredit = 1e24;
        md.netRate = uint64(netRate);
    }

    function _market(uint256 ttm) internal view returns (Market memory market) {
        CollateralParams[] memory collateralParams = new CollateralParams[](1);
        collateralParams[0] = CollateralParams({
            token: address(0xC011), lltv: 0.86e18, liquidationCursor: 0.3e18, oracle: address(0x0AC1E)
        });
        market.chainId = block.chainid;
        market.midnight = address(midnight);
        market.loanToken = loanToken;
        market.collateralParams = collateralParams;
        market.maturity = block.timestamp + ttm;
    }

    function _tenorId() internal view returns (bytes32) {
        return TenorMarketIdLib.toTenorMarketId(_market(1));
    }

    function _buyOffer(uint256 ttm, uint256 tick) internal view returns (Offer memory offer) {
        offer.market = _market(ttm);
        offer.buy = true;
        offer.maker = address(adapter);
        offer.tick = tick;
        offer.group = BUY_GROUP;
        offer.callback = address(adapter);
        offer.callbackData = idleFunding;
        offer.ratifier = address(adapter);
        offer.maxAssets = type(uint128).max;
    }

    function _sellOffer(uint256 ttm, uint256 tick) internal view returns (Offer memory offer) {
        offer.market = _market(ttm);
        offer.buy = false;
        offer.maker = address(adapter);
        offer.tick = tick;
        offer.group = SELL_GROUP;
        offer.callback = address(adapter);
        offer.receiverIfMakerIsSeller = address(adapter);
        offer.ratifier = address(adapter);
        offer.reduceOnly = true;
        offer.maxAssets = type(uint128).max;
    }

    /// @dev Highest tick whose price is at most `maxPrice`.
    function _highestTickAtMost(uint256 maxPrice) internal pure returns (uint256 tick) {
        tick = TickLib.priceToTick(maxPrice > WAD ? WAD : maxPrice, 1);
        while (tick < MAX_TICK && TickLib.tickToPrice(tick + 1) <= maxPrice) tick++;
        while (tick > 0 && TickLib.tickToPrice(tick) > maxPrice) tick--;
    }

    /// @dev Lowest tick whose price is at least `minPrice`.
    function _lowestTickAtLeast(uint256 minPrice) internal pure returns (uint256 tick) {
        tick = TickLib.priceToTick(minPrice > WAD ? WAD : minPrice, 1);
        while (tick > 0 && TickLib.tickToPrice(tick - 1) >= minPrice) tick--;
        while (tick < MAX_TICK && TickLib.tickToPrice(tick) < minPrice) tick++;
    }

    function _maxBuyPrice(uint256 rate, uint256 ttm, uint256 netUnitsPerWad) internal pure returns (uint256) {
        return UtilsLib.mulDivDown(netUnitsPerWad, UtilsLib.mulDivDown(WAD, WAD, WAD + rate * ttm), WAD);
    }

    function _minSellPrice(uint256 rate, uint256 ttm) internal pure returns (uint256) {
        return UtilsLib.mulDivUp(WAD, WAD, WAD + rate * ttm);
    }

    function _ratify(Offer memory offer) internal view returns (bytes32) {
        return adapter.forward(address(ratifier), offer, "");
    }

    /* SETTERS */

    function testSetCurveByAllocator() public view {
        assertEq(ratifier.curveLength(address(adapter), _tenorId()), 2);
        (uint32 ttm, uint112 sellRate, uint112 buyRate) = ratifier.curves(address(adapter), _tenorId(), 1);
        assertEq(ttm, 180 days);
        assertEq(sellRate, _apr(4));
        assertEq(buyRate, _apr(7));
    }

    function testSetCurveByDelegate() public {
        midnight.setIsAuthorized(allocator, delegate, true);
        vm.prank(delegate);
        ratifier.setCurve(address(adapter), bytes32(uint256(7)), _defaultCurve(), allocator);
        assertEq(ratifier.curveLength(address(adapter), bytes32(uint256(7))), 2);
    }

    function testSetCurveUnauthorized() public {
        IMarketMakingPolicy.CurvePoint[] memory points = _defaultCurve();
        vm.prank(sentinel);
        vm.expectRevert(IMidnightAdapterCurveRatifier.Unauthorized.selector);
        ratifier.setCurve(address(adapter), _tenorId(), points, sentinel);

        vm.prank(stranger);
        vm.expectRevert(IMidnightAdapterCurveRatifier.Unauthorized.selector);
        ratifier.setCurve(address(adapter), _tenorId(), points, stranger);

        // Acting on behalf of an allocator without its Midnight authorization.
        vm.prank(stranger);
        vm.expectRevert(IMidnightAdapterCurveRatifier.Unauthorized.selector);
        ratifier.setCurve(address(adapter), _tenorId(), points, allocator);
    }

    function testSetCurveValidation() public {
        IMarketMakingPolicy.CurvePoint[] memory empty = new IMarketMakingPolicy.CurvePoint[](0);
        vm.startPrank(allocator);
        vm.expectRevert(IMidnightAdapterCurveRatifier.EmptyCurve.selector);
        ratifier.setCurve(address(adapter), _tenorId(), empty, allocator);

        IMarketMakingPolicy.CurvePoint[] memory tooMany = new IMarketMakingPolicy.CurvePoint[](9);
        for (uint256 i; i < 9; i++) {
            tooMany[i] = IMarketMakingPolicy.CurvePoint({ttm: uint32(i + 1), sellRate: 0, buyRate: 0});
        }
        vm.expectRevert(IMidnightAdapterCurveRatifier.TooManyPoints.selector);
        ratifier.setCurve(address(adapter), _tenorId(), tooMany, allocator);

        IMarketMakingPolicy.CurvePoint[] memory unsorted = _defaultCurve();
        unsorted[1].ttm = unsorted[0].ttm;
        vm.expectRevert(IMidnightAdapterCurveRatifier.NonStrictlyIncreasingTtm.selector);
        ratifier.setCurve(address(adapter), _tenorId(), unsorted, allocator);

        IMarketMakingPolicy.CurvePoint[] memory crossed = _defaultCurve();
        crossed[1].sellRate = crossed[1].buyRate + 1;
        vm.expectRevert(IMidnightAdapterCurveRatifier.CrossedCurve.selector);
        ratifier.setCurve(address(adapter), _tenorId(), crossed, allocator);
        vm.stopPrank();
    }

    function testClearCurveBySentinel() public {
        vm.prank(sentinel);
        ratifier.clearCurve(address(adapter), _tenorId(), sentinel);
        assertEq(ratifier.curveLength(address(adapter), _tenorId()), 0);

        vm.prank(stranger);
        vm.expectRevert(IMidnightAdapterCurveRatifier.Unauthorized.selector);
        ratifier.clearCurve(address(adapter), _tenorId(), stranger);
    }

    function testGroupHeader() public view {
        assertEq(ratifier.CURVE_GROUP_HEADER(), bytes32(hex"74656e6f72f0"));
        assertEq(ratifier.CURVE_GROUP_HEADER_MASK(), bytes32(hex"ffffffffffff"));
        // The header has no low bits, and its version byte is outside MigrationRatifier's 0xE0 to 0xEF.
        assertEq(ratifier.CURVE_GROUP_HEADER() & ~ratifier.CURVE_GROUP_HEADER_MASK(), bytes32(0));
        assertEq(uint8(ratifier.CURVE_GROUP_HEADER()[5]) & 0xF0, 0xF0);
    }

    function testFuzzGroupLowBitsAreFree(uint256 low, bool buy) public view {
        bytes32 group = (bytes32(low) & ~ratifier.CURVE_GROUP_HEADER_MASK()) | ratifier.CURVE_GROUP_HEADER();
        uint256 ttm = 90 days;
        Offer memory offer;
        if (buy) {
            uint256 rate = ratifier.buyRateBound(address(adapter), _market(ttm));
            offer = _buyOffer(ttm, _highestTickAtMost(_maxBuyPrice(rate, ttm, WAD)));
        } else {
            offer = _sellOffer(ttm, MAX_TICK);
        }
        offer.group = group;
        assertEq(_ratify(offer), CALLBACK_SUCCESS);
    }

    function testGroupOutsideHeaderRejected() public {
        bytes32 low = bytes32(uint256(1));
        bytes32[4] memory groups = [
            bytes32(0),
            bytes32(hex"74656e6f72e0") | low, // MigrationRatifier's header
            bytes32(hex"74656e6f72f1") | low, // another version in the reserved range
            bytes32(hex"75656e6f72f0") | low // another domain prefix
        ];
        for (uint256 i; i < groups.length; i++) {
            Offer memory offer = _buyOffer(90 days, 0);
            offer.group = groups[i];
            vm.expectRevert(IMidnightAdapterCurveRatifier.InvalidGroup.selector);
            _ratify(offer);
            offer = _sellOffer(90 days, MAX_TICK);
            offer.group = groups[i];
            vm.expectRevert(IMidnightAdapterCurveRatifier.InvalidGroup.selector);
            _ratify(offer);
        }
    }

    function testSetIsFundingSource() public {
        bytes memory other = abi.encode(address(0x1234), bytes("data"));
        vm.prank(sentinel);
        vm.expectRevert(IMidnightAdapterCurveRatifier.Unauthorized.selector);
        ratifier.setIsFundingSource(address(adapter), other, true, sentinel);

        vm.prank(allocator);
        ratifier.setIsFundingSource(address(adapter), other, true, allocator);
        assertTrue(ratifier.isFundingSource(address(adapter), keccak256(other)));

        vm.prank(sentinel);
        ratifier.setIsFundingSource(address(adapter), other, false, sentinel);
        assertFalse(ratifier.isFundingSource(address(adapter), keccak256(other)));
    }

    function testSetAllowsRolling() public {
        vm.prank(sentinel);
        vm.expectRevert(IMidnightAdapterCurveRatifier.Unauthorized.selector);
        ratifier.setAllowsRolling(address(adapter), true, sentinel);

        vm.prank(stranger);
        vm.expectRevert(IMidnightAdapterCurveRatifier.Unauthorized.selector);
        ratifier.setAllowsRolling(address(adapter), true, stranger);

        vm.expectEmit(address(ratifier));
        emit IMidnightAdapterCurveRatifier.AllowsRollingSet(address(adapter), allocator, true);
        vm.prank(allocator);
        ratifier.setAllowsRolling(address(adapter), true, allocator);
        assertTrue(ratifier.allowsRolling(address(adapter)));

        vm.prank(sentinel);
        ratifier.setAllowsRolling(address(adapter), false, sentinel);
        assertFalse(ratifier.allowsRolling(address(adapter)));
    }

    /* FUNDING */

    function _maturedMarket(uint256 age) internal view returns (Market memory market) {
        market = _market(1);
        market.maturity = block.timestamp - age;
    }

    function _rollFunding(address fundingAdapter, Market memory from) internal pure returns (bytes memory) {
        return abi.encode(fundingAdapter, abi.encode(from));
    }

    function _buyAtBound(bytes memory callbackData) internal view returns (Offer memory offer) {
        uint256 ttm = 90 days;
        uint256 rate = ratifier.buyRateBound(address(adapter), _market(ttm));
        offer = _buyOffer(ttm, _highestTickAtMost(_maxBuyPrice(rate, ttm, WAD)));
        offer.callbackData = callbackData;
    }

    function testRollingRequiresTheFlag() public {
        Offer memory offer = _buyAtBound(_rollFunding(address(adapter), _maturedMarket(1 days)));
        vm.expectRevert(IMidnightAdapterCurveRatifier.UnauthorizedFundingSource.selector);
        _ratify(offer);

        vm.prank(allocator);
        ratifier.setAllowsRolling(address(adapter), true, allocator);
        assertEq(_ratify(offer), CALLBACK_SUCCESS);
    }

    function testRollingFromAnyMaturedMarket() public {
        vm.prank(allocator);
        ratifier.setAllowsRolling(address(adapter), true, allocator);

        // Matured exactly now, as Midnight counts it.
        assertEq(_ratify(_buyAtBound(_rollFunding(address(adapter), _maturedMarket(0)))), CALLBACK_SUCCESS);

        // A market of another Tenor market, which has no curve: matured credit is cash.
        Market memory otherCollateral = _maturedMarket(30 days);
        otherCollateral.collateralParams[0].lltv = 0.915e18;
        assertTrue(TenorMarketIdLib.toTenorMarketId(otherCollateral) != _tenorId());
        assertEq(_ratify(_buyAtBound(_rollFunding(address(adapter), otherCollateral))), CALLBACK_SUCCESS);
    }

    function testRollingRejections() public {
        vm.prank(allocator);
        ratifier.setAllowsRolling(address(adapter), true, allocator);

        // Not matured: early repayments are valued below par until maturity.
        Offer memory offer = _buyAtBound(_rollFunding(address(adapter), _market(1)));
        vm.expectRevert(IMidnightAdapterCurveRatifier.FundingMarketNotMatured.selector);
        _ratify(offer);

        // Another adapter's markets are not the adapter's own credit.
        offer = _buyAtBound(_rollFunding(address(0x1234), _maturedMarket(1 days)));
        vm.expectRevert(IMidnightAdapterCurveRatifier.UnauthorizedFundingSource.selector);
        _ratify(offer);

        // Idle funding that is not allowed stays rejected.
        offer = _buyAtBound(abi.encode(address(0), bytes("x")));
        vm.expectRevert(IMidnightAdapterCurveRatifier.UnauthorizedFundingSource.selector);
        _ratify(offer);

        // Malformed callback data does not decode.
        offer = _buyAtBound(hex"01");
        vm.expectRevert();
        _ratify(offer);
        offer = _buyAtBound(abi.encode(address(adapter), hex"01"));
        vm.expectRevert();
        _ratify(offer);
    }

    function testRollingDoesNotAffectAllowedSources() public {
        vm.prank(allocator);
        ratifier.setAllowsRolling(address(adapter), true, allocator);
        assertEq(_ratify(_buyAtBound(idleFunding)), CALLBACK_SUCCESS);

        // An exact allowed entry for an unmatured market works regardless of the flag.
        bytes memory pinned = _rollFunding(address(adapter), _market(1));
        vm.prank(allocator);
        ratifier.setIsFundingSource(address(adapter), pinned, true, allocator);
        vm.prank(sentinel);
        ratifier.setAllowsRolling(address(adapter), false, sentinel);
        assertEq(_ratify(_buyAtBound(pinned)), CALLBACK_SUCCESS);
        assertEq(_ratify(_buyAtBound(idleFunding)), CALLBACK_SUCCESS);
    }

    /* BUY */

    function testBuyAtBound() public view {
        uint256 ttm = 90 days;
        uint256 rate = ratifier.buyRateBound(address(adapter), _market(ttm));
        // Interpolated between 5% at 7 days and 7% at 180 days.
        assertGt(rate, _apr(5));
        assertLt(rate, _apr(7));

        uint256 tick = _highestTickAtMost(_maxBuyPrice(rate, ttm, WAD));
        assertEq(_ratify(_buyOffer(ttm, tick)), CALLBACK_SUCCESS);
    }

    function testBuyWorsePrice() public {
        uint256 ttm = 90 days;
        uint256 rate = ratifier.buyRateBound(address(adapter), _market(ttm));
        uint256 tick = _highestTickAtMost(_maxBuyPrice(rate, ttm, WAD));
        Offer memory offer = _buyOffer(ttm, tick + 1);
        vm.expectRevert(IMidnightAdapterCurveRatifier.WorsePrice.selector);
        _ratify(offer);
    }

    function testBuyNetsContinuousFee() public {
        uint256 ttm = 90 days;
        Market memory market = _market(ttm);
        uint32 fee = uint32(uint256(0.01e18) / YEAR); // 1% per year
        midnight.setContinuousFee(IdLib.toId(market), fee);
        uint256 rate = ratifier.buyRateBound(address(adapter), market);

        uint256 grossTick = _highestTickAtMost(_maxBuyPrice(rate, ttm, WAD));
        uint256 netTick = _highestTickAtMost(_maxBuyPrice(rate, ttm, WAD - uint256(fee) * ttm));
        assertLt(netTick, grossTick);

        assertEq(_ratify(_buyOffer(ttm, netTick)), CALLBACK_SUCCESS);
        Offer memory offer = _buyOffer(ttm, netTick + 1);
        vm.expectRevert(IMidnightAdapterCurveRatifier.WorsePrice.selector);
        _ratify(offer);
    }

    function testBuyTtmOutOfRange() public {
        vm.expectRevert(IMidnightAdapterCurveRatifier.TtmOutOfRange.selector);
        ratifier.buyRateBound(address(adapter), _market(181 days));

        vm.expectRevert(IMidnightAdapterCurveRatifier.TtmOutOfRange.selector);
        ratifier.buyRateBound(address(adapter), _market(6 days));

        // The knots themselves are in range.
        assertEq(ratifier.buyRateBound(address(adapter), _market(7 days)), _apr(5));
        assertEq(ratifier.buyRateBound(address(adapter), _market(180 days)), _apr(7));
    }

    function testBuyOfferShape() public {
        uint256 ttm = 90 days;
        Offer memory offer = _buyOffer(ttm, 0);

        offer.callbackData = abi.encode(address(0x1234), bytes(""));
        vm.expectRevert(IMidnightAdapterCurveRatifier.UnauthorizedFundingSource.selector);
        _ratify(offer);

        offer = _buyOffer(ttm, 0);
        offer.group = bytes32(0);
        vm.expectRevert(IMidnightAdapterCurveRatifier.InvalidGroup.selector);
        _ratify(offer);

        offer = _buyOffer(ttm, 0);
        vm.expectRevert(IMidnightAdapterCurveRatifier.NonEmptyRatifierData.selector);
        adapter.forward(address(ratifier), offer, hex"01");

        vm.expectRevert(IMidnightAdapterCurveRatifier.NotMaker.selector);
        ratifier.isRatified(offer, "", address(this));
    }

    function testAnyFillCapRatified() public view {
        uint256 ttm = 90 days;
        uint256 rate = ratifier.buyRateBound(address(adapter), _market(ttm));
        Offer memory offer = _buyOffer(ttm, _highestTickAtMost(_maxBuyPrice(rate, ttm, WAD)));
        offer.maxAssets = 1;
        assertEq(_ratify(offer), CALLBACK_SUCCESS);
        offer.maxAssets = 0;
        offer.maxUnits = 1e18;
        assertEq(_ratify(offer), CALLBACK_SUCCESS);

        offer = _sellOffer(ttm, MAX_TICK);
        offer.maxAssets = 1;
        assertEq(_ratify(offer), CALLBACK_SUCCESS);
    }

    /* MARKET STATE */

    function testMarketStateRejections() public {
        uint256 ttm = 90 days;
        Market memory market = _market(ttm);
        bytes32 id = IdLib.toId(market);

        // Force-sellable: sells are rejected here, buys are left to the adapter.
        AdapterMarketData memory md = _md(_apr(6));
        md.forceSellable = true;
        adapter.setMarketData(id, md);
        vm.expectRevert(IMidnightAdapterCurveRatifier.ForceSellable.selector);
        ratifier.sellRateBound(address(adapter), market);
        assertGt(ratifier.buyRateBound(address(adapter), market), 0);

        // A loss rejects buys, and leaves the exit open.
        adapter.setMarketData(id, _md(_apr(6)));
        midnight.setLossFactor(id, 1);
        vm.expectRevert(IMidnightAdapterCurveRatifier.MarketHasLoss.selector);
        ratifier.buyRateBound(address(adapter), market);
        assertGt(ratifier.sellRateBound(address(adapter), market), 0);
        midnight.setLossFactor(id, 0);

        market.collateralParams[0].lltv = 0.77e18;
        vm.expectRevert(IMidnightAdapterCurveRatifier.NoCurve.selector);
        ratifier.buyRateBound(address(adapter), market);
        vm.expectRevert(IMidnightAdapterCurveRatifier.NoCurve.selector);
        ratifier.sellRateBound(address(adapter), market);
    }

    function testPostMaturity() public {
        Market memory market = _market(7 days);
        adapter.setMarketData(IdLib.toId(market), _md(_apr(6)));
        vm.warp(market.maturity - 1);
        assertEq(ratifier.sellRateBound(address(adapter), market), _apr(3));

        vm.warp(market.maturity);
        vm.expectRevert(IMidnightAdapterCurveRatifier.PostMaturity.selector);
        ratifier.sellRateBound(address(adapter), market);
        vm.expectRevert(IMidnightAdapterCurveRatifier.PostMaturity.selector);
        ratifier.buyRateBound(address(adapter), market);
    }

    /* SELL */

    function testSellAtBound() public view {
        uint256 ttm = 90 days;
        uint256 rate = ratifier.sellRateBound(address(adapter), _market(ttm));
        assertGt(rate, _apr(3));
        assertLt(rate, _apr(4));

        uint256 tick = _lowestTickAtLeast(_minSellPrice(rate, ttm));
        assertEq(_ratify(_sellOffer(ttm, tick)), CALLBACK_SUCCESS);
    }

    function testSellWorsePrice() public {
        uint256 ttm = 90 days;
        uint256 rate = ratifier.sellRateBound(address(adapter), _market(ttm));
        uint256 tick = _lowestTickAtLeast(_minSellPrice(rate, ttm));
        Offer memory offer = _sellOffer(ttm, tick - 1);
        vm.expectRevert(IMidnightAdapterCurveRatifier.WorsePrice.selector);
        _ratify(offer);
    }

    function testSellClampsToNetRate() public {
        uint256 ttm = 90 days;
        Market memory market = _market(ttm);
        adapter.setMarketData(IdLib.toId(market), _md(_apr(2)));
        assertEq(ratifier.sellRateBound(address(adapter), market), _apr(2));

        // Without a position the net rate is 0: only par is ratified.
        adapter.setMarketData(IdLib.toId(market), _md(0));
        assertEq(ratifier.sellRateBound(address(adapter), market), 0);
        Offer memory offer = _sellOffer(ttm, _lowestTickAtLeast(WAD) - 1);
        vm.expectRevert(IMidnightAdapterCurveRatifier.WorsePrice.selector);
        _ratify(offer);
        assertEq(_ratify(_sellOffer(ttm, _lowestTickAtLeast(WAD))), CALLBACK_SUCCESS);
    }

    function testSellClampsTtmToCurveEnds() public {
        Market memory market = _market(365 days);
        adapter.setMarketData(IdLib.toId(market), _md(_apr(10)));
        assertEq(ratifier.sellRateBound(address(adapter), market), _apr(4));

        market = _market(1);
        adapter.setMarketData(IdLib.toId(market), _md(_apr(10)));
        assertEq(ratifier.sellRateBound(address(adapter), market), _apr(3));
    }

    function testSellOfferShape() public {
        Offer memory offer = _sellOffer(90 days, MAX_TICK);
        offer.reduceOnly = false;
        vm.expectRevert(IMidnightAdapterCurveRatifier.NotReduceOnly.selector);
        _ratify(offer);

        offer = _sellOffer(90 days, MAX_TICK);
        offer.group = bytes32(0);
        vm.expectRevert(IMidnightAdapterCurveRatifier.InvalidGroup.selector);
        _ratify(offer);
    }

    /* FUZZ: ticks around the bound, with Midnight's take arithmetic */

    /// @dev Picks a tick within 200 ticks of `boundTick`, on either side.
    function _tickAround(uint256 boundTick, uint256 seed) internal pure returns (uint256) {
        uint256 low = boundTick > 200 ? boundTick - 200 : 0;
        uint256 high = boundTick + 200 > MAX_TICK ? MAX_TICK : boundTick + 200;
        return bound(seed, low, high);
    }

    /// @dev A buy is ratified exactly up to the bound tick, and every ratified buy earns the adapter at least the
    /// curve rate on its net credit, for any size.
    function testFuzzBuyBound(uint256 ttm, uint256 tickSeed, uint256 units, uint256 feeBps) public {
        ttm = bound(ttm, 7 days, 180 days);
        units = bound(units, 1, 1e30);
        uint32 fee = uint32(bound(feeBps, 0, 100) * 1e14 / YEAR); // up to Midnight's 1% per year cap

        Market memory market = _market(ttm);
        midnight.setContinuousFee(IdLib.toId(market), fee);
        uint256 rate = ratifier.buyRateBound(address(adapter), market);
        uint256 boundTick = _highestTickAtMost(_maxBuyPrice(rate, ttm, WAD - uint256(fee) * ttm));
        uint256 tick = _tickAround(boundTick, tickSeed);

        Offer memory offer = _buyOffer(ttm, tick);
        if (TickLib.tickToPrice(tick) > TickLib.tickToPrice(boundTick)) {
            vm.expectRevert(IMidnightAdapterCurveRatifier.WorsePrice.selector);
            _ratify(offer);
            return;
        }
        assertEq(_ratify(offer), CALLBACK_SUCCESS);

        uint256 buyerAssets = UtilsLib.mulDivDown(units, TickLib.tickToPrice(tick), WAD);
        uint256 boughtNetCredit = units - UtilsLib.mulDivDown(units, uint256(fee) * ttm, WAD);
        assertGe(boughtNetCredit, buyerAssets, "BuyAtLoss");
        assertGe((boughtNetCredit - buyerAssets) * WAD, rate * ttm * buyerAssets, "below curve");
    }

    /// @dev A sell is ratified exactly from the bound tick up, and no ratified sell has a shortfall in
    /// MidnightAdapter.onSell, for any size and remaining position.
    function testFuzzSellBound(
        uint256 ttm,
        uint256 tickSeed,
        uint256 units,
        uint256 remainingNetCredit,
        uint256 pendingFeeBps,
        uint256 netApr
    ) public {
        ttm = bound(ttm, 1, 365 days);
        units = bound(units, 1, 1e30);
        remainingNetCredit = bound(remainingNetCredit, 0, 1e30);
        uint64 netRate = uint64(bound(netApr, 0, 2000) * 1e14 / YEAR); // 0% to 20%, around the 3% to 4% sell curve

        Market memory market = _market(ttm);
        adapter.setMarketData(IdLib.toId(market), _md(netRate));
        uint256 rate = ratifier.sellRateBound(address(adapter), market);
        assertLe(rate, netRate);
        uint256 boundTick = _lowestTickAtLeast(_minSellPrice(rate, ttm));
        uint256 tick = _tickAround(boundTick, tickSeed);

        Offer memory offer = _sellOffer(ttm, tick);
        if (TickLib.tickToPrice(tick) < TickLib.tickToPrice(boundTick)) {
            vm.expectRevert(IMidnightAdapterCurveRatifier.WorsePrice.selector);
            _ratify(offer);
            return;
        }
        assertEq(_ratify(offer), CALLBACK_SUCCESS);

        uint256 sellerAssets = UtilsLib.mulDivUp(units, TickLib.tickToPrice(tick), WAD);
        // The seller's pending fee decrease only lowers the sold net credit.
        uint256 soldNetCredit = units - UtilsLib.mulDivUp(units, bound(pendingFeeBps, 0, 500), 10_000);
        uint256 soldAmortizedValue = UtilsLib.mulDivDown(remainingNetCredit + soldNetCredit, WAD, WAD + netRate * ttm)
            - UtilsLib.mulDivDown(remainingNetCredit, WAD, WAD + netRate * ttm);
        assertEq(UtilsLib.zeroFloorSub(soldAmortizedValue, sellerAssets), 0, "shortfall");
    }

    /// @dev LOOP SAFETY for any valid curve: the sell rate exceeds the buy rate by at most the interpolation's
    /// rounding, 1 wei of rate, which is far below one tick.
    function testFuzzSellRateAtMostBuyRate(uint256 seed, uint256 ttm) public {
        uint256 n = bound(seed, 1, 8);
        IMarketMakingPolicy.CurvePoint[] memory points = new IMarketMakingPolicy.CurvePoint[](n);
        uint32 knot;
        for (uint256 i; i < n; i++) {
            seed = uint256(keccak256(abi.encode(seed)));
            knot += uint32(bound(seed, 1, 60 days));
            uint112 buyRate = uint112(bound(seed >> 32, 0, _apr(100)));
            points[i] = IMarketMakingPolicy.CurvePoint({
                ttm: knot, sellRate: uint112(bound(seed >> 144, 0, buyRate)), buyRate: buyRate
            });
        }
        vm.prank(allocator);
        ratifier.setCurve(address(adapter), _tenorId(), points, allocator);

        ttm = bound(ttm, points[0].ttm, knot);
        Market memory market = _market(ttm);
        AdapterMarketData memory md = _md(0);
        md.netRate = type(uint64).max;
        adapter.setMarketData(IdLib.toId(market), md);
        assertLe(ratifier.sellRateBound(address(adapter), market), ratifier.buyRateBound(address(adapter), market) + 1);
    }

    /* CADENCE */

    function testSetCadence() public {
        address fourWeek = address(new FourWeekCadence());
        vm.prank(sentinel);
        vm.expectRevert(IMidnightAdapterCurveRatifier.Unauthorized.selector);
        ratifier.setCadence(address(adapter), fourWeek, sentinel);

        vm.prank(allocator);
        ratifier.setCadence(address(adapter), fourWeek, allocator);
        assertEq(ratifier.cadence(address(adapter)), fourWeek);

        // A sentinel can only unset it, which stops buys.
        vm.prank(stranger);
        vm.expectRevert(IMidnightAdapterCurveRatifier.Unauthorized.selector);
        ratifier.setCadence(address(adapter), address(0), stranger);

        vm.prank(sentinel);
        ratifier.setCadence(address(adapter), address(0), sentinel);
        assertEq(ratifier.cadence(address(adapter)), address(0));
        vm.expectRevert(IMidnightAdapterCurveRatifier.NoCadence.selector);
        ratifier.buyRateBound(address(adapter), _market(90 days));
    }

    function testBuyRequiresCadence() public {
        vm.prank(allocator);
        ratifier.setCadence(address(adapter), address(0), allocator);
        vm.expectRevert(IMidnightAdapterCurveRatifier.NoCadence.selector);
        ratifier.buyRateBound(address(adapter), _market(90 days));
    }

    function testBuyOnlyOnCadence() public {
        address fourWeek = address(new FourWeekCadence());
        vm.prank(allocator);
        ratifier.setCadence(address(adapter), fourWeek, allocator);

        Market memory market = _market(90 days);
        uint256 onCadence = (market.maturity / 28 days) * 28 days;
        market.maturity = onCadence + 1;
        vm.expectRevert(IMidnightAdapterCurveRatifier.MaturityOffCadence.selector);
        ratifier.buyRateBound(address(adapter), market);

        market.maturity = onCadence;
        assertGt(ratifier.buyRateBound(address(adapter), market), 0);
    }

    function testSellIgnoresCadence() public {
        vm.prank(allocator);
        ratifier.setCadence(address(adapter), address(0), allocator);
        Market memory market = _market(90 days);
        assertGt(ratifier.sellRateBound(address(adapter), market), 0);
    }

    /// @dev Over a curve's ttm range, a four-week cadence leaves at most ceil(range / 28 days) + 1 buyable maturities.
    function testFuzzCadenceBoundsBuyableMaturities(uint256 start) public {
        vm.warp(bound(start, 1_700_000_000, 2_000_000_000));
        address fourWeek = address(new FourWeekCadence());
        vm.prank(allocator);
        ratifier.setCadence(address(adapter), fourWeek, allocator);

        uint256 buyable;
        uint256 first = ((block.timestamp + 7 days) / 28 days) * 28 days;
        for (uint256 m = first; m <= block.timestamp + 180 days + 28 days; m += 1 days) {
            Market memory market = _market(1);
            market.maturity = m;
            adapter.setMarketData(IdLib.toId(market), _md(_apr(6)));
            try ratifier.buyRateBound(address(adapter), market) returns (uint256) {
                buyable++;
            } catch {}
        }
        // The curve spans 173 days (7 to 180): ceil(173 / 28) + 1 = 8 cadence points at most.
        assertLe(buyable, uint256(8));
        assertGe(buyable, uint256(6));
    }
}
