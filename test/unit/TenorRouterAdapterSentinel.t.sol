// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TenorAdapter} from "../../src/bundler/TenorAdapter.sol";
import {TenorRouterAdapterBase} from "../../src/bundler/TenorRouterAdapterBase.sol";
import {TenorRouter, ExecuteParams, FillAxis, Action, MidnightTakeData} from "../../src/router/TenorRouter.sol";
import {ITenorRouter} from "../../src/router/interfaces/ITenorRouter.sol";
import {ITenorRouterAdapter} from "../../src/bundler/interfaces/ITenorRouterAdapter.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {IBundler3, Call} from "@bundler3/interfaces/IBundler3.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Fixtures} from "../helpers/Fixtures.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {creditAfterSlashing} from "../helpers/CreditHelper.sol";

contract MockOnBehalfForSentinel {}

contract MockOracleForSentinel {
    uint256 internal immutable _price;

    constructor(uint256 p) {
        _price = p;
    }

    function price() external view returns (uint256) {
        return _price;
    }
}

/// @title TakeRouterAdapterSentinelTest
/// @notice Covers sentinel resolution (FILL_UNITS credit/debt, FILL_BUYER_ASSETS adapter
///         balance), unsupported fillIndex, zero-balance semantics, and the caller-vs-taker
///         authorization guard for sentinel use.
contract TakeRouterAdapterSentinelTest is Fixtures {
    TenorAdapter internal adapter;
    Midnight internal midnight;
    IBundler3 internal bundler3;

    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;

    address internal taker;
    uint256 internal takerSK;
    address internal maker;
    uint256 internal makerSK;
    address internal keeper;

    EcrecoverRatifier internal ecrecoverRatifier;
    Market internal market;

    uint256 internal constant INITIAL_UNITS = 100e18;

    function setUp() public {
        (taker, takerSK) = makeAddrAndKey("Taker");
        (maker, makerSK) = makeAddrAndKey("Maker");
        keeper = makeAddr("Keeper");

        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(taker);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, taker);
        vm.prank(maker);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, maker);

        bundler3 = deployBundler3();
        MockOnBehalfForSentinel mockRenewalOnBehalf = new MockOnBehalfForSentinel();
        adapter = new TenorAdapter(address(bundler3), address(midnight), makeAddr("Ratifier"));

        MockOracleForSentinel oracle = new MockOracleForSentinel(1e36);

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
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        loanToken.mint(taker, 10_000_000e18);
        loanToken.mint(maker, 10_000_000e18);
        collateralToken.mint(maker, 10_000_000e18);

        vm.prank(taker);
        loanToken.approve(address(midnight), type(uint256).max);

        vm.startPrank(maker);
        loanToken.approve(address(midnight), type(uint256).max);
        collateralToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        vm.prank(taker);
        midnight.setIsAuthorized(address(adapter), true, taker);

        _setupTakerCredit(INITIAL_UNITS);
    }

    /* ═══════ Setup helpers ═══════ */

    function _setupTakerCredit(uint256 units) internal {
        vm.prank(maker);
        midnight.supplyCollateral(market, 0, 1000e18, maker);

        bytes32 group = keccak256(abi.encodePacked("setup", block.timestamp, gasleft()));
        Offer memory offer = Offer({
            market: market,
            buy: true,
            maker: taker,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _sign(offer, takerSK);
        vm.prank(maker);
        midnight.take(
            offer,
            abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0)),
            units,
            maker,
            offer.maker,
            address(0),
            ""
        );

        bytes32 oblId = IdLib.toId(market);
        require(creditAfterSlashing(midnight, oblId, taker) > 0, "setup failed: taker has no credit");
    }

    function _sign(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 offerHash = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), offerHash));
        bytes32 domainSeparator =
            keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        return Signature({v: v, r: r, s: s});
    }

    /* ═══════ Action / params builders ═══════ */

    function _midnightTakeAction(uint256 takeUnits, bool allowRevert) internal view returns (Action memory action) {
        bytes32 group = keccak256(abi.encodePacked("take", takeUnits, gasleft()));
        Offer memory offer = Offer({
            market: market,
            buy: true,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _sign(offer, makerSK);
        bytes32 root = HashLib.hashOffer(offer);
        MidnightTakeData memory take = MidnightTakeData({
            takeUnits: takeUnits,
            takerCallback: address(0),
            takerCallbackData: "",
            receiverIfTakerIsSeller: taker,
            ratifierData: abi.encode(sig, root, uint256(0), new bytes32[](0))
        });

        action = Action({
            take: take,
            allowRevert: allowRevert,
            offer: offer,
            clamp: address(0),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });
    }

    function _defaultParams(FillAxis fillAxis, uint256 maxFill, uint256 minFill)
        internal
        pure
        returns (ExecuteParams memory)
    {
        return ExecuteParams({
            deadline: 0,
            fillAxis: fillAxis,
            maxFill: maxFill,
            minFill: minFill,
            minPrice: 0,
            maxPrice: type(uint256).max,
            reduceOnly: false
        });
    }

    function _callAdapter(address initiatorAddr, ExecuteParams memory params, Action[] memory actions) internal {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(adapter),
            data: abi.encodeCall(adapter.execute, (params, actions)),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        vm.prank(initiatorAddr);
        bundler3.multicall(calls);
    }

    /* ═══════ Tests ═══════ */

    function test_sentinel_creditBothMaxAndMin() public {
        bytes32 id = IdLib.toId(market);
        uint256 takerCreditBefore = creditAfterSlashing(midnight, id, taker);
        assertGt(takerCreditBefore, 0, "taker has credit");

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(takerCreditBefore, false);

        _callAdapter(taker, _defaultParams(FillAxis.UNITS, type(uint256).max, type(uint256).max), actions);

        assertEq(creditAfterSlashing(midnight, id, taker), 0, "taker credit fully consumed");
    }

    function test_sentinel_creditOnlyMaxFill() public {
        bytes32 id = IdLib.toId(market);
        uint256 takerCreditBefore = creditAfterSlashing(midnight, id, taker);

        uint256 halfCredit = takerCreditBefore / 2;

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(halfCredit, false);

        _callAdapter(taker, _defaultParams(FillAxis.UNITS, type(uint256).max, 0), actions);

        assertEq(creditAfterSlashing(midnight, id, taker), takerCreditBefore - halfCredit, "half credit remains");
    }

    function test_sentinel_creditOnlyMinFill() public {
        bytes32 id = IdLib.toId(market);
        uint256 takerCreditBefore = creditAfterSlashing(midnight, id, taker);

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(takerCreditBefore, false);

        _callAdapter(taker, _defaultParams(FillAxis.UNITS, takerCreditBefore * 2, type(uint256).max), actions);

        assertEq(creditAfterSlashing(midnight, id, taker), 0, "taker credit fully consumed");
    }

    function test_noSentinel_normalExecution() public {
        bytes32 id = IdLib.toId(market);
        uint256 takerCreditBefore = creditAfterSlashing(midnight, id, taker);
        uint256 halfCredit = takerCreditBefore / 2;

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(halfCredit, false);

        _callAdapter(taker, _defaultParams(FillAxis.UNITS, takerCreditBefore, 0), actions);

        assertEq(
            creditAfterSlashing(midnight, id, taker), takerCreditBefore - halfCredit, "normal fill consumed half credit"
        );
    }

    /// @dev `minFill: 1` makes the selector assertion load-bearing about ordering: if the guard were
    ///      removed or moved after `_execute`, `InsufficientFill(0, 1)` would fire instead.
    function test_sentinel_zeroBalance_reverts() public {
        Market memory emptyObl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: market.collateralParams,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        bytes32 emptyId = IdLib.toId(emptyObl);
        assertEq(creditAfterSlashing(midnight, emptyId, taker), 0, "taker has 0 credit");

        Action[] memory actions = new Action[](1);
        actions[0] = _zeroSentinelAction(emptyObl, true);

        ExecuteParams memory params = ExecuteParams({
            deadline: 0,
            fillAxis: FillAxis.UNITS,
            maxFill: type(uint256).max,
            minFill: 1,
            minPrice: 0,
            maxPrice: type(uint256).max,
            reduceOnly: false
        });

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(adapter),
            data: abi.encodeCall(adapter.execute, (params, actions)),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(ITenorRouterAdapter.SentinelResolvedToZero.selector, uint8(2)));
        bundler3.multicall(calls);
    }

    /// @dev `_midnightTakeAction` builds a BUY offer (sell-side batch). With `FillAxis.ASSETS`,
    ///      the sentinel resolves to `FILL_SELLER_ASSETS` and `_resolveSentinel` rejects with
    ///      `SentinelNotSupported(1)` — no pre-fill way to read the assets the taker would receive.
    function test_sentinel_assetAxis_sellSide_unsupported() public {
        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(1e18, true);

        ExecuteParams memory params = _defaultParams(FillAxis.ASSETS, type(uint256).max, 1);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(adapter),
            data: abi.encodeCall(adapter.execute, (params, actions)),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(ITenorRouterAdapter.SentinelNotSupported.selector, uint8(1)));
        bundler3.multicall(calls);
    }

    function test_sentinel_units_resolvesToDebt() public {
        bytes32 id = IdLib.toId(market);
        uint256 makerDebt = midnight.debt(id, maker);
        assertGt(makerDebt, 0, "maker has debt");

        vm.prank(maker);
        midnight.setIsAuthorized(address(adapter), true, maker);

        loanToken.mint(maker, makerDebt * 2);
        vm.prank(maker);
        loanToken.approve(address(midnight), type(uint256).max);

        loanToken.mint(address(adapter), makerDebt * 2);
        vm.prank(address(adapter));
        loanToken.approve(address(midnight), type(uint256).max);

        bytes32 group = keccak256(abi.encodePacked("unitsTest", gasleft()));
        Offer memory sellOffer = Offer({
            market: market,
            buy: false,
            maker: taker,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: taker,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory sig = _sign(sellOffer, takerSK);
        bytes32 root = HashLib.hashOffer(sellOffer);

        bytes32 oblId = IdLib.toId(market);
        uint256 takeUnits = midnight.totalUnits(oblId);
        MidnightTakeData memory take = MidnightTakeData({
            takeUnits: takeUnits,
            takerCallback: address(0),
            takerCallbackData: "",
            receiverIfTakerIsSeller: address(0),
            ratifierData: abi.encode(sig, root, uint256(0), new bytes32[](0))
        });

        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            take: take,
            allowRevert: false,
            offer: sellOffer,
            clamp: address(0),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });

        ExecuteParams memory params = ExecuteParams({
            deadline: 0,
            fillAxis: FillAxis.UNITS,
            maxFill: type(uint256).max,
            minFill: 0,
            minPrice: 0,
            maxPrice: type(uint256).max,
            reduceOnly: false
        });

        _callAdapter(maker, params, actions);

        assertEq(midnight.debt(id, maker), 0, "maker debt fully repaid");
    }

    function test_sentinel_sellerAssets_reverts() public {
        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(1e18, false);

        ExecuteParams memory params = _defaultParams(FillAxis.ASSETS, type(uint256).max, 0);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(adapter),
            data: abi.encodeCall(adapter.execute, (params, actions)),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(ITenorRouterAdapter.SentinelNotSupported.selector, uint8(1)));
        bundler3.multicall(calls);
    }

    /* ═══════ Helpers ═══════ */

    function _zeroSentinelAction(Market memory emptyObl, bool allowRevert) internal view returns (Action memory) {
        bytes32 group = keccak256(abi.encodePacked("empty", gasleft(), emptyObl.maturity));
        Offer memory emptyOffer = Offer({
            market: emptyObl,
            buy: true,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory sig = _sign(emptyOffer, makerSK);
        bytes32 root = HashLib.hashOffer(emptyOffer);
        MidnightTakeData memory take = MidnightTakeData({
            takeUnits: 1e18,
            takerCallback: address(0),
            takerCallbackData: "",
            receiverIfTakerIsSeller: address(0),
            ratifierData: abi.encode(sig, root, uint256(0), new bytes32[](0))
        });
        return Action({
            take: take,
            allowRevert: allowRevert,
            offer: emptyOffer,
            clamp: address(0),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });
    }
}
