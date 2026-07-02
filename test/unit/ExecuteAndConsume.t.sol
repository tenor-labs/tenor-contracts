// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TenorAdapter} from "../../src/bundler/TenorAdapter.sol";
import {TenorRouter, ExecuteParams, FillAxis, Action, MidnightTakeData} from "../../src/router/TenorRouter.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {IBundler3, Call} from "@bundler3/interfaces/IBundler3.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {DEFAULT_TICK_SPACING, CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Fixtures} from "../helpers/Fixtures.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {creditAfterSlashing} from "../helpers/CreditHelper.sol";
import {CallbackFeeAdjuster} from "../../src/router/CallbackFeeAdjuster.sol";
import {ITenorRouterAdapter} from "../../src/bundler/interfaces/ITenorRouterAdapter.sol";
import {ITenorRouter} from "../../src/router/interfaces/ITenorRouter.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

contract MockOracleForConsume {
    function price() external pure returns (uint256) {
        return 1e36;
    }
}

/// @notice Malicious maker-side callback: when Midnight fires it during the outer take, it reenters
///         `Midnight.take` to fill the initiator's resting offer in the same consumeGroup, bumping
///         `consumed[initiator][group]` before the adapter writes it.
contract ReentrantMakerCallback {
    Midnight internal immutable MIDNIGHT;

    Offer internal restingOffer;
    bytes internal ratifierData;
    uint256 internal nestedUnits;
    bool internal fired;

    constructor(Midnight m, MockERC20 loanToken) {
        MIDNIGHT = m;
        loanToken.approve(address(m), type(uint256).max);
    }

    function arm(Offer calldata o, bytes calldata rd, uint256 u) external {
        restingOffer = o;
        ratifierData = rd;
        nestedUnits = u;
    }

    function onBuy(bytes32, Market memory, uint256, uint256, uint256, address, bytes memory)
        external
        returns (bytes32)
    {
        if (!fired && nestedUnits != 0) {
            fired = true;
            MIDNIGHT.take(restingOffer, ratifierData, nestedUnits, address(this), address(0), address(0), "");
        }
        return CALLBACK_SUCCESS;
    }
}

/// @title ExecuteAndConsumeTest
/// @notice Verifies `executeAndConsume` mirrors `execute` and adds a Midnight `setConsumed` call
///         for the chosen fillIndex dimension. Covers partial/full/zero spot fills, additivity,
///         multi-action sums, sentinel resolution, and atomicity on revert.
contract ExecuteAndConsumeTest is Fixtures {
    TenorAdapter internal adapter;
    Midnight internal midnight;
    IBundler3 internal bundler3;

    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;

    address internal taker;
    uint256 internal takerSK;
    address internal maker;
    uint256 internal makerSK;

    EcrecoverRatifier internal ecrecoverRatifier;
    Market internal market;

    uint256 internal constant INITIAL_UNITS = 100e18;

    function setUp() public {
        (taker, takerSK) = makeAddrAndKey("Taker");
        (maker, makerSK) = makeAddrAndKey("Maker");

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
        adapter = new TenorAdapter(address(bundler3), address(midnight), makeAddr("Ratifier"));

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(new MockOracleForConsume())
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
            tick: 5820,
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

    function _midnightTakeAction(uint256 takeUnits) internal view returns (Action memory) {
        return _midnightTakeActionWithCallback(takeUnits, address(0));
    }

    /// @dev SELL offer variant: maker is the seller/borrower, taker is the buyer/lender. Mirrors
    ///      `_midnightTakeAction` so the two directions of the fee tilt can be exercised.
    function _midnightTakeSellAction(uint256 takeUnits) internal view returns (Action memory) {
        bytes32 group = keccak256(abi.encodePacked("takeSell", takeUnits, gasleft()));
        Offer memory offer = Offer({
            market: market,
            buy: false,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: maker,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _sign(offer, makerSK);
        MidnightTakeData memory take = MidnightTakeData({
            takeUnits: takeUnits,
            takerCallback: address(0),
            takerCallbackData: "",
            receiverIfTakerIsSeller: address(0),
            ratifierData: abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0))
        });

        return Action({
            take: take,
            allowRevert: false,
            offer: offer,
            clamp: address(0),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });
    }

    function _callExecuteAndConsume(
        address initiatorAddr,
        ExecuteParams memory params,
        Action[] memory actions,
        bytes32 consumeGroup
    ) internal {
        _callExecuteAndConsume(initiatorAddr, params, actions, consumeGroup, type(uint256).max);
    }

    function _callExecuteAndConsume(
        address initiatorAddr,
        ExecuteParams memory params,
        Action[] memory actions,
        bytes32 consumeGroup,
        uint256 maxConsumed
    ) internal {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(adapter),
            data: abi.encodeCall(adapter.executeAndConsume, (params, actions, consumeGroup, maxConsumed)),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        vm.prank(initiatorAddr);
        bundler3.multicall(calls);
    }

    function _params(FillAxis fillAxis, uint256 maxFill, uint256 minFill) internal pure returns (ExecuteParams memory) {
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

    /* ═══════ Tests ═══════ */

    function test_partialSpotFill_consumedSetCorrectly() public {
        bytes32 consumeGroup = keccak256("limitOrder1");
        uint256 spotUnits = INITIAL_UNITS / 2;

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(spotUnits);

        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, INITIAL_UNITS, 0), actions, consumeGroup);
        assertEq(midnight.consumed(taker, consumeGroup), spotUnits, "consumed == spot-filled units");
    }

    function test_fullSpotFill_offerFullyConsumed() public {
        bytes32 consumeGroup = keccak256("limitOrder2");

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(INITIAL_UNITS);

        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, INITIAL_UNITS, 0), actions, consumeGroup);
        assertEq(midnight.consumed(taker, consumeGroup), INITIAL_UNITS, "consumed == maxFill when fully filled");
    }

    /// @dev Adapter rejects empty `actions` at the entry — sentinel resolution and the consume
    ///      counter both dereference `actions[0]`, so an empty batch is malformed input rather
    ///      than a silent no-op.
    function test_revert_emptyActions() public {
        bytes32 consumeGroup = keccak256("limitOrder3");
        Action[] memory actions = new Action[](0);
        ExecuteParams memory params = _params(FillAxis.UNITS, INITIAL_UNITS, 0);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(adapter),
            data: abi.encodeCall(adapter.executeAndConsume, (params, actions, consumeGroup, type(uint256).max)),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });

        vm.prank(taker);
        vm.expectRevert(ITenorRouter.EmptyActions.selector);
        bundler3.multicall(calls);
    }

    function test_preExistingConsumed_additive() public {
        bytes32 consumeGroup = keccak256("limitOrder4");
        uint128 preExisting = 20e18;

        vm.prank(taker);
        midnight.setConsumed(consumeGroup, preExisting, taker);

        uint256 spotUnits = 30e18;
        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(spotUnits);

        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, INITIAL_UNITS, 0), actions, consumeGroup);
        assertEq(midnight.consumed(taker, consumeGroup), preExisting + spotUnits, "consumed is additive");
    }

    function test_exactSpendGuarantee_unitsMode() public {
        bytes32 consumeGroup = keccak256("limitOrder5");
        uint256 spotUnits = 40e18;

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(spotUnits);

        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, INITIAL_UNITS, 0), actions, consumeGroup);

        uint256 consumed = midnight.consumed(taker, consumeGroup);
        uint256 remaining = INITIAL_UNITS - consumed;
        assertEq(consumed + remaining, INITIAL_UNITS, "consumed + remaining == totalOrder");
    }

    function test_multiAction_consumedIsSumOfFills() public {
        _setupTakerCredit(100e18);

        bytes32 consumeGroup = keccak256("limitOrder6");
        uint256 take1 = 30e18;
        uint256 take2 = 50e18;

        Action[] memory actions = new Action[](2);
        actions[0] = _midnightTakeAction(take1);
        actions[1] = _midnightTakeAction(take2);

        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, 200e18, 0), actions, consumeGroup);
        assertEq(midnight.consumed(taker, consumeGroup), take1 + take2, "consumed == sum of both fills");
    }

    function test_sentinel_maxFillResolvesToCredit() public {
        bytes32 consumeGroup = keccak256("limitOrder7");
        bytes32 oblId = IdLib.toId(market);
        uint256 credit = creditAfterSlashing(midnight, oblId, taker);

        uint256 spotUnits = credit / 2;
        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(spotUnits);

        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, type(uint256).max, 0), actions, consumeGroup);
        assertEq(midnight.consumed(taker, consumeGroup), spotUnits, "consumed == spot units with sentinel maxFill");
    }

    function test_fullExit_positionFullyExited() public {
        bytes32 consumeGroup = keccak256("limitOrder8");
        bytes32 oblId = IdLib.toId(market);
        uint256 credit = creditAfterSlashing(midnight, oblId, taker);

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(credit);

        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, credit, 0), actions, consumeGroup);
        assertEq(midnight.consumed(taker, consumeGroup), credit, "consumed == full credit");
        assertEq(creditAfterSlashing(midnight, oblId, taker), 0, "position fully exited");
    }

    function test_fillIndex_buyerAssets() public {
        // SELL offer → taker is buyer → BUYER_ASSETS axis is the taker's side (valid). Fund the
        // adapter so it can pay buyerAssets on behalf of the buyer when there's no taker callback.
        vm.prank(maker);
        midnight.supplyCollateral(market, 0, 10_000e18, maker);
        loanToken.mint(address(adapter), 1_000e18);

        bytes32 consumeGroup = keccak256("limitOrderBA");
        uint256 spotUnits = 50e18;

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeSellAction(spotUnits);

        _callExecuteAndConsume(taker, _params(FillAxis.ASSETS, 100e18, 0), actions, consumeGroup);

        uint256 consumed = midnight.consumed(taker, consumeGroup);
        assertGt(consumed, 0);
        assertLt(consumed, spotUnits, "buyer assets discounted by price");
    }

    function test_fillIndex_sellerAssets() public {
        bytes32 consumeGroup = keccak256("limitOrderSA");
        uint256 spotUnits = 50e18;

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(spotUnits);

        _callExecuteAndConsume(taker, _params(FillAxis.ASSETS, 100e18, 0), actions, consumeGroup);

        uint256 consumed = midnight.consumed(taker, consumeGroup);
        assertGt(consumed, 0);
        assertLt(consumed, spotUnits, "seller assets discounted by price + fee");
    }

    /// @dev Audit regression (Cantina `2e076d3f`): when a spot action carries a `feeAdjuster`,
    ///      the router tilts `totals[sellerAssets]` down by the callback fee. Midnight's own
    ///      `consumed[maker][group]` tracks the RAW fill, so `executeAndConsume` must advance
    ///      the initiator's counter by the raw amount — otherwise a fee-bearing BUY fill leaves
    ///      a fee-sized phantom capacity on a `maxSellerAssets`-denominated limit order.
    function test_feeAdjuster_consumedUsesRawSellerAssets() public {
        _setupTakerCredit(100e18); // top up so both fills have credit to sell against

        uint256 spotUnits = 50e18;
        uint256 feeRate = 0.5e18;
        CallbackFeeAdjuster feeAdjuster = new CallbackFeeAdjuster(address(midnight));
        bytes memory adjusterData = abi.encode(feeRate, CallbackFeeAdjuster.FeeFormula.INTEREST);

        // Baseline: same spot action, no fee adjuster — consumed is the raw Midnight fill.
        bytes32 plainGroup = keccak256("plainConsume");
        Action[] memory plainActions = new Action[](1);
        plainActions[0] = _midnightTakeAction(spotUnits);
        _callExecuteAndConsume(taker, _params(FillAxis.ASSETS, 100e18, 0), plainActions, plainGroup);
        uint256 rawConsumed = midnight.consumed(taker, plainGroup);
        assertGt(rawConsumed, 0, "precondition: baseline consumed > 0");

        // Fee-bearing: same units, but the adjuster reports a positive seller-side fee.
        bytes32 feeGroup = keccak256("feeConsume");
        Action[] memory feeActions = new Action[](1);
        feeActions[0] = _midnightTakeAction(spotUnits);
        feeActions[0].feeAdjuster = address(feeAdjuster);
        feeActions[0].feeAdjusterData = adjusterData;
        _callExecuteAndConsume(taker, _params(FillAxis.ASSETS, 100e18, 0), feeActions, feeGroup);
        uint256 feeConsumed = midnight.consumed(taker, feeGroup);

        assertEq(feeConsumed, rawConsumed, "consumed must equal the raw Midnight fill, not raw - fee");
    }

    /// @dev Mirror of the seller-side regression: SELL offer with `fillIndex = FILL_BUYER_ASSETS`.
    ///      For `!offer.buy` the router tilts `buyerAssets += fee`, so pre-fix `consumed` would be
    ///      inflated by the fee. The fix writes the raw Midnight fill either way.
    function test_feeAdjuster_consumedUsesRawBuyerAssets() public {
        vm.prank(maker);
        midnight.supplyCollateral(market, 0, 10_000e18, maker);
        // For SELL actions with no takerCallback the adapter is the payer; fund it.
        loanToken.mint(address(adapter), 1_000e18);

        uint256 spotUnits = 50e18;
        uint256 feeRate = 0.5e18;
        CallbackFeeAdjuster feeAdjuster = new CallbackFeeAdjuster(address(midnight));
        bytes memory adjusterData = abi.encode(feeRate, CallbackFeeAdjuster.FeeFormula.INTEREST);

        // Baseline: SELL offer, no fee adjuster.
        bytes32 plainGroup = keccak256("plainConsumeBuy");
        Action[] memory plainActions = new Action[](1);
        plainActions[0] = _midnightTakeSellAction(spotUnits);
        _callExecuteAndConsume(taker, _params(FillAxis.ASSETS, 100e18, 0), plainActions, plainGroup);
        uint256 rawConsumed = midnight.consumed(taker, plainGroup);
        assertGt(rawConsumed, 0, "precondition: baseline consumed > 0");

        // Fee-bearing: same SELL fill, adjuster attached. Pre-fix would write raw + fee.
        bytes32 feeGroup = keccak256("feeConsumeBuy");
        Action[] memory feeActions = new Action[](1);
        feeActions[0] = _midnightTakeSellAction(spotUnits);
        feeActions[0].feeAdjuster = address(feeAdjuster);
        feeActions[0].feeAdjusterData = adjusterData;
        _callExecuteAndConsume(taker, _params(FillAxis.ASSETS, 100e18, 0), feeActions, feeGroup);
        uint256 feeConsumed = midnight.consumed(taker, feeGroup);

        assertEq(feeConsumed, rawConsumed, "consumed must equal the raw Midnight fill, not raw + fee");
    }

    function test_revert_directCallWithoutBundler3() public {
        Action[] memory actions = new Action[](0);
        ExecuteParams memory params = _params(FillAxis.UNITS, INITIAL_UNITS, 0);

        vm.prank(taker);
        vm.expectRevert();
        adapter.executeAndConsume(params, actions, keccak256("group"), type(uint256).max);
    }

    function test_revert_routeFails_consumedUnchanged() public {
        bytes32 consumeGroup = keccak256("limitOrderRevert");
        uint256 spotUnits = 50e18;

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(spotUnits);

        ExecuteParams memory params = _params(FillAxis.UNITS, INITIAL_UNITS, INITIAL_UNITS + 1);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(adapter),
            data: abi.encodeCall(adapter.executeAndConsume, (params, actions, consumeGroup, type(uint256).max)),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });

        vm.prank(taker);
        vm.expectRevert();
        bundler3.multicall(calls);

        assertEq(midnight.consumed(taker, consumeGroup), 0, "consumed unchanged after revert");
    }

    function test_reduceOnly_propagatesThroughExecuteAndConsume_reverts() public {
        collateralToken.mint(taker, 1_000_000e18);
        vm.startPrank(taker);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, 1000e18, taker);
        vm.stopPrank();

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(INITIAL_UNITS * 2);

        ExecuteParams memory params = _params(FillAxis.UNITS, INITIAL_UNITS * 2, 0);
        params.reduceOnly = true;

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(adapter),
            data: abi.encodeCall(adapter.executeAndConsume, (params, actions, keccak256("ro"), type(uint256).max)),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(ITenorRouter.ReduceOnlyViolated.selector, uint256(0), uint256(INITIAL_UNITS))
        );
        bundler3.multicall(calls);
    }

    /* ═══════════════════════════════════════════════════════════════
       Tests — TenorRouter time-validity prefilter under executeAndConsume
       ═══════════════════════════════════════════════════════════════ */

    /// @dev Mixed batch: live BUY action + prefiltered (not-started) BUY action. The prefiltered
    ///      action skips `_dispatch` and contributes 0 to `rawTotals`, so `setConsumed` advances
    ///      only by the live fill — the Midnight `consumed[maker][group]` counter must NOT
    ///      double-count the skipped slot.
    function test_executeAndConsume_prefilteredAction_consumesOnlyLiveFill() public {
        _setupTakerCredit(100e18); // top up so two BUY fills have credit to absorb
        bytes32 consumeGroup = keccak256("prefilteredMix");

        Action[] memory actions = new Action[](2);
        // action[0]: live
        actions[0] = _midnightTakeAction(30e18);
        // action[1]: not-started, allowRevert=true → prefiltered out
        actions[1] = _midnightTakeActionWindow(30e18, int256(1 hours), int256(2 hours), true);

        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, 200e18, 0), actions, consumeGroup);
        assertEq(midnight.consumed(taker, consumeGroup), 30e18, "consumed advances only by live fill");
    }

    /// @dev Every action prefiltered — `setConsumed` advances by 0 and the sentinel for `maxFill`
    ///      still resolves against `actions[0].offer.market` without reverting.
    function test_executeAndConsume_allPrefiltered_consumedUnchanged() public {
        bytes32 consumeGroup = keccak256("allPrefiltered");

        Action[] memory actions = new Action[](2);
        actions[0] = _midnightTakeActionWindow(10e18, int256(1 hours), int256(2 hours), true);
        actions[1] = _midnightTakeActionWindow(10e18, int256(1 hours), int256(2 hours), true);

        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, type(uint256).max, 0), actions, consumeGroup);
        assertEq(midnight.consumed(taker, consumeGroup), 0, "consumed unchanged when all prefiltered");
    }

    /// @dev Variant of `_midnightTakeAction` parameterized over the offer's `[start, expiry]`
    ///      window so prefilter-targeting tests can build out-of-window actions.
    function _midnightTakeActionWindow(uint256 takeUnits, int256 startOffset, int256 expiryOffset, bool allowRevert)
        internal
        view
        returns (Action memory)
    {
        bytes32 group = keccak256(abi.encodePacked("takeWindow", takeUnits, gasleft()));
        Offer memory offer = Offer({
            market: market,
            buy: true,
            maker: maker,
            start: uint256(int256(block.timestamp) + startOffset),
            expiry: uint256(int256(block.timestamp) + expiryOffset),
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
        MidnightTakeData memory take = MidnightTakeData({
            takeUnits: takeUnits,
            takerCallback: address(0),
            takerCallbackData: "",
            receiverIfTakerIsSeller: taker,
            ratifierData: abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0))
        });

        return Action({
            take: take,
            allowRevert: allowRevert,
            offer: offer,
            clamp: address(0),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });
    }

    /// @dev BUY-offer take-as-seller (like `_midnightTakeAction`) but with a maker-side `offer.callback`.
    ///      Midnight invokes `onBuy` on the callback (which is also the buyer/payer) mid-take.
    function _midnightTakeActionWithCallback(uint256 takeUnits, address callbackContract)
        internal
        view
        returns (Action memory)
    {
        bytes32 group = keccak256(abi.encodePacked("takeCb", takeUnits, gasleft()));
        Offer memory offer = Offer({
            market: market,
            buy: true,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: group,
            callback: callbackContract,
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _sign(offer, makerSK);
        MidnightTakeData memory take = MidnightTakeData({
            takeUnits: takeUnits,
            takerCallback: address(0),
            takerCallbackData: "",
            receiverIfTakerIsSeller: taker,
            ratifierData: abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0))
        });

        return Action({
            take: take,
            allowRevert: false,
            offer: offer,
            clamp: address(0),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });
    }

    /// @dev Reentrancy scenario shared by the counting and cap tests: the victim (initiator) posts
    ///      a resting SELL offer in `consumeGroup` (maker == victim); the attacker's maker callback
    ///      reenters mid-take to fill it for `nestedUnits`. Returns the outer-leg action that takes
    ///      the attacker's BUY offer (offer.callback == the armed callback) for `outerUnits`.
    function _armReentrantScenario(bytes32 consumeGroup, uint256 nestedUnits, uint256 outerUnits)
        internal
        returns (Action[] memory actions)
    {
        Offer memory resting = Offer({
            market: market,
            buy: false,
            maker: taker,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: consumeGroup,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: taker,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory sig = _sign(resting, takerSK);
        bytes memory restingRatifierData = abi.encode(sig, HashLib.hashOffer(resting), uint256(0), new bytes32[](0));

        // Attacker's malicious maker callback, funded + approved to pay buyerAssets and reenter.
        ReentrantMakerCallback cb = new ReentrantMakerCallback(midnight, loanToken);
        loanToken.mint(address(cb), 10_000_000e18);
        cb.arm(resting, restingRatifierData, nestedUnits);

        actions = new Action[](1);
        actions[0] = _midnightTakeActionWithCallback(outerUnits, address(cb));
    }

    /// @notice Sherlock #6 scenario under full Option 1 accounting (Cantina #51): a reentrant
    ///         maker callback fills the initiator's resting offer in `consumeGroup` mid-execution.
    ///         Midnight counts the nested fill natively; the adapter reads the counter after
    ///         execution and adds only its own taker-side raw fills — each fill counted exactly
    ///         once. The former before/after snapshot guard is dropped: the counter is exact
    ///         accounting, not an atomic in-tx aggregate cap.
    function test_reentrantMakerCallback_nestedFillCountedOnce() public {
        bytes32 consumeGroup = keccak256("sharedCap");
        Action[] memory actions = _armReentrantScenario(consumeGroup, 10e18, 20e18);

        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, 100e18, 0), actions, consumeGroup);

        // 10e18 nested fill counted by Midnight (taker is the resting offer's maker) +
        // 20e18 outer taker fill added by the adapter.
        assertEq(midnight.consumed(taker, consumeGroup), 30e18, "nested + outer fills each counted once");
    }

    /// @dev Cantina #50: a fill lands in the group between the user sizing their tx and the write
    ///      executing (front-run of a resting offer). With `maxConsumed` the batch reverts
    ///      instead of silently ending above the intended aggregate.
    function test_revert_capExceeded_frontRunFill() public {
        bytes32 consumeGroup = keccak256("capFrontRun");
        uint256 cap = 100e18;

        // Front-run: 70e18 lands in the group before the batch executes.
        vm.prank(taker);
        midnight.setConsumed(consumeGroup, 70e18, taker);

        // Batch sized for the original headroom: 70 + 40 = 110 > 100.
        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(40e18);

        vm.expectRevert(abi.encodeWithSelector(ITenorRouterAdapter.ConsumedCapExceeded.selector, 110e18, cap));
        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, INITIAL_UNITS, 0), actions, consumeGroup, cap);

        assertEq(midnight.consumed(taker, consumeGroup), 70e18, "counter unchanged after revert");
    }

    function test_capExact_passes() public {
        bytes32 consumeGroup = keccak256("capExact");
        uint256 cap = 100e18;

        vm.prank(taker);
        midnight.setConsumed(consumeGroup, 70e18, taker);

        Action[] memory actions = new Action[](1);
        actions[0] = _midnightTakeAction(30e18); // 70 + 30 == cap

        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, INITIAL_UNITS, 0), actions, consumeGroup, cap);
        assertEq(midnight.consumed(taker, consumeGroup), cap, "counter lands exactly on the cap");
    }

    /// @dev Cantina #50, reentrant ordering: same setup as
    ///      `test_reentrantMakerCallback_nestedFillCountedOnce` (nested 10e18 + outer 20e18 = 30e18)
    ///      but capped at 25e18 — the cap reverts the whole tx, unwinding the attacker's nested
    ///      fill along with the outer one.
    function test_revert_capExceeded_reentrantNestedFill() public {
        bytes32 consumeGroup = keccak256("sharedCapBounded");
        Action[] memory actions = _armReentrantScenario(consumeGroup, 10e18, 20e18);

        vm.expectRevert(abi.encodeWithSelector(ITenorRouterAdapter.ConsumedCapExceeded.selector, 30e18, 25e18));
        _callExecuteAndConsume(taker, _params(FillAxis.UNITS, 100e18, 0), actions, consumeGroup, 25e18);

        assertEq(midnight.consumed(taker, consumeGroup), 0, "nested fill unwound with the revert");
    }
}
