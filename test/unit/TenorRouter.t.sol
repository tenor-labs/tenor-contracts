// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {BoundaryTestBase} from "./boundary/BoundaryTestBase.sol";
import {TenorRouter, ExecuteParams, Action, FillAxis, MidnightTakeData} from "../../src/router/TenorRouter.sol";
import {ITenorRouter} from "../../src/router/interfaces/ITenorRouter.sol";
import {Offer, Market} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {MAX_CONTINUOUS_FEE} from "@midnight/libraries/ConstantsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";
import {MockTakeClamp} from "../helpers/mocks/MockTakeClamp.sol";
import {MockTenorRouter} from "../helpers/mocks/MockTenorRouter.sol";
import {CallbackFeeAdjuster} from "../../src/router/CallbackFeeAdjuster.sol";

/// @title TakeRouterTest
/// @notice TenorRouter batch-execution mechanics, exercised through `MIDNIGHT_TAKE` actions (the only action type).
///         The initiator is always the Midnight taker. Buyer-side batches take a counterparty SELL offer (router is
///         payer); seller-side batches take a counterparty BUY offer (taker takes on debt against its collateral).
contract TakeRouterTest is BoundaryTestBase {
    using TenorMarketIdLib for Market;

    TenorRouter internal router;

    uint16 internal constant DEFAULT_TICK = 2940;
    uint128 internal constant DEFAULT_BORROW_AMOUNT = 1000e18;
    uint128 internal constant DEFAULT_COLLATERAL_AMOUNT = 5000e18;

    function setUp() public override {
        super.setUp();

        // Move off genesis so offers with `expiry == 1` are genuinely expired.
        vm.warp(1000);

        router = new MockTenorRouter(address(midnight));

        vm.prank(borrower);
        midnight.setIsAuthorized(address(router), true, borrower);
        vm.prank(lender);
        midnight.setIsAuthorized(address(router), true, lender);

        // Fund the router for SELL-offer paths: when takerCallback == address(0) and offer.buy == false, Midnight
        // resolves the payer to msg.sender (the router), which forceApproves but needs a balance.
        loanToken.mint(address(router), type(uint128).max);

        // Fund + approve the borrower and lender so either can be the loan-paying party (BUY-offer maker, or a
        // seller's settlement) on Midnight.
        loanToken.mint(lender, type(uint128).max);
        loanToken.mint(borrower, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.prank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ═══════════════════════════════════════════════════════════════
       Shared helpers
       ═══════════════════════════════════════════════════════════════ */

    function _defaultExecuteParams(address) internal pure returns (ExecuteParams memory) {
        return ExecuteParams({
            deadline: 0,
            fillAxis: FillAxis.UNITS,
            maxFill: type(uint256).max,
            minFill: 0,
            minPrice: 0,
            maxPrice: type(uint256).max,
            maxContinuousFee: type(uint256).max,
            reduceOnly: false
        });
    }

    function _freshGroup() internal view returns (bytes32) {
        return keccak256(abi.encodePacked("router-test", block.timestamp, gasleft()));
    }

    /// @dev SELL offer on target (maker sells bonds, taker buys paying loan tokens). Buyer-side batch.
    function _sellOfferOnTarget(uint16 tick, address maker, uint256 makerSK)
        internal
        view
        returns (Offer memory, Signature memory, bytes32)
    {
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: maker,
            maxUnits: type(uint128).max,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: _freshGroup(),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: maker,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory sig = _signOffer(offer, makerSK);
        return (offer, sig, HashLib.hashOffer(offer));
    }

    /// @dev BUY offer on target (maker buys bonds, taker sells taking on debt). Seller-side batch.
    function _buyOfferOnTarget(uint16 tick, address maker, uint256 makerSK)
        internal
        view
        returns (Offer memory, Signature memory, bytes32)
    {
        Offer memory offer = Offer({
            market: targetMarket,
            buy: true,
            maker: maker,
            maxUnits: type(uint128).max,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: _freshGroup(),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory sig = _signOffer(offer, makerSK);
        return (offer, sig, HashLib.hashOffer(offer));
    }

    function _action(Offer memory offer, Signature memory sig, bytes32 root, uint256 units, address receiverIfSeller)
        internal
        pure
        returns (Action memory)
    {
        MidnightTakeData memory d = MidnightTakeData({
            takeUnits: units,
            takerCallback: address(0),
            takerCallbackData: "",
            receiverIfTakerIsSeller: receiverIfSeller,
            ratifierData: abi.encode(sig, root, uint256(0), new bytes32[](0))
        });
        return Action({
            take: d,
            allowRevert: false,
            offer: offer,
            clamp: address(0),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });
    }

    /// @dev Buyer-side action: lender (taker) buys a SELL offer from `borrower`; the router pays. Both sides fill.
    function _buyerSideAction(uint256 units, uint16 tick, bool allowRevert) internal view returns (Action memory) {
        (Offer memory offer, Signature memory sig, bytes32 root) = _sellOfferOnTarget(tick, borrower, borrowerSK);
        Action memory a = _action(offer, sig, root, units, address(0));
        a.allowRevert = allowRevert;
        return a;
    }

    /// @dev Seller-side action: borrower (taker) sells into a BUY offer from `lender`, taking on debt.
    function _sellerSideAction(uint256 units, uint16 tick, bool allowRevert) internal view returns (Action memory) {
        (Offer memory offer, Signature memory sig, bytes32 root) = _buyOfferOnTarget(tick, lender, lenderSK);
        Action memory a = _action(offer, sig, root, units, borrower);
        a.allowRevert = allowRevert;
        return a;
    }

    /// @dev Gives `borrower` a redeemable SELL-side position on target so it can be the maker of SELL offers.
    function _primeBuyerSide() internal {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, targetMarket, targetMarketId);
    }

    /// @dev Gives `borrower` collateral on target so it can be the taker-seller of BUY offers.
    function _primeSellerSide() internal {
        _depositCollateral(borrower, DEFAULT_COLLATERAL_AMOUNT, targetMarket);
    }

    /* ═══════════════════════════════════════════════════════════════
       Section 1 — Direct MIDNIGHT_TAKE happy paths
       ═══════════════════════════════════════════════════════════════ */

    function test_midnightTake() public {
        _primeBuyerSide();
        (Offer memory offer, Signature memory sig, bytes32 root) =
            _sellOfferOnTarget(DEFAULT_TICK, borrower, borrowerSK);

        Action[] memory actions = new Action[](1);
        actions[0] = _action(offer, sig, root, 50e18, address(0));

        vm.prank(lender);
        (uint256 buyerAssets, uint256 sellerAssets, uint256 units) =
            router.execute(_defaultExecuteParams(lender), actions);
        assertGt(buyerAssets, 0, "MIDNIGHT: buyerAssets > 0");
        assertGt(sellerAssets, 0, "MIDNIGHT: sellerAssets > 0");
        assertGt(units, 0, "MIDNIGHT: units > 0");
    }

    function test_midnightTake_buyOffer() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, targetMarket, targetMarketId);
        (Offer memory offer, Signature memory sig, bytes32 root) = _buyOfferOnTarget(DEFAULT_TICK, lender, lenderSK);

        Action[] memory actions = new Action[](1);
        actions[0] = _action(offer, sig, root, 50e18, borrower);

        vm.prank(borrower);
        (uint256 buyerAssets, uint256 sellerAssets, uint256 units) =
            router.execute(_defaultExecuteParams(borrower), actions);
        assertGt(buyerAssets, 0, "MIDNIGHT_BUY: buyerAssets > 0");
        assertGt(sellerAssets, 0, "MIDNIGHT_BUY: sellerAssets > 0");
        assertGt(units, 0, "MIDNIGHT_BUY: units > 0");
    }

    /* ═══════════════════════════════════════════════════════════════
       Section 2 — Execute + fill tracking
       ═══════════════════════════════════════════════════════════════ */

    function test_execute_singleAction() public {
        _primeBuyerSide();
        Action[] memory actions = new Action[](1);
        actions[0] = _buyerSideAction(50e18, DEFAULT_TICK, false);

        vm.prank(lender);
        (uint256 buyerAssets, uint256 sellerAssets, uint256 units) =
            router.execute(_defaultExecuteParams(lender), actions);
        assertGt(buyerAssets, 0, "SINGLE: buyerAssets > 0");
        assertGt(sellerAssets, 0, "SINGLE: sellerAssets > 0");
        assertGt(units, 0, "SINGLE: units > 0");
    }

    function test_execute_multiAction() public {
        _primeBuyerSide();
        Action[] memory actions = new Action[](2);
        actions[0] = _buyerSideAction(25e18, DEFAULT_TICK, false);
        actions[1] = _buyerSideAction(25e18, DEFAULT_TICK, false);

        vm.prank(lender);
        (uint256 buyerAssets,, uint256 units) = router.execute(_defaultExecuteParams(lender), actions);
        assertGt(buyerAssets, 0, "MULTI: buyerAssets > 0");
        assertGt(units, 0, "MULTI: units > 0");
    }

    function test_execute_fillTracking_stopsAtTarget() public {
        _primeBuyerSide();
        Action[] memory soloArr = new Action[](1);
        soloArr[0] = _buyerSideAction(25e18, DEFAULT_TICK, false);
        vm.prank(lender);
        (,, uint256 soloFill) = router.execute(_defaultExecuteParams(lender), soloArr);
        assertGt(soloFill, 0, "baseline fill > 0");

        setUp();
        _primeBuyerSide();
        Action[] memory actions = new Action[](2);
        actions[0] = _buyerSideAction(25e18, DEFAULT_TICK, false);
        actions[1] = _buyerSideAction(25e18, DEFAULT_TICK, false);
        ExecuteParams memory params = _defaultExecuteParams(lender);
        params.maxFill = soloFill;

        vm.prank(lender);
        (,, uint256 totalFill) = router.execute(params, actions);
        assertEq(totalFill, soloFill, "STOPS_AT_TARGET: multi-action fill == soloFill cap");
    }

    function test_revert_insufficientFill() public {
        _primeBuyerSide();
        Action[] memory actions = new Action[](1);
        actions[0] = _buyerSideAction(10e18, DEFAULT_TICK, false);

        ExecuteParams memory params = _defaultExecuteParams(lender);
        params.minFill = type(uint256).max;

        vm.prank(lender);
        vm.expectRevert();
        router.execute(params, actions);
    }

    function test_minFill_exactlyMet() public {
        _primeBuyerSide();
        Action[] memory soloArr = new Action[](1);
        soloArr[0] = _buyerSideAction(30e18, DEFAULT_TICK, false);
        vm.prank(lender);
        (,, uint256 fill) = router.execute(_defaultExecuteParams(lender), soloArr);
        assertGt(fill, 0, "baseline > 0");

        setUp();
        _primeBuyerSide();
        Action[] memory actions = new Action[](1);
        actions[0] = _buyerSideAction(30e18, DEFAULT_TICK, false);
        ExecuteParams memory params = _defaultExecuteParams(lender);
        params.minFill = fill;

        vm.prank(lender);
        (,, uint256 actualFill) = router.execute(params, actions);
        assertEq(actualFill, fill, "MIN_EXACT: min fill exactly met");
    }

    /* ═══════════════════════════════════════════════════════════════
       Section 3 — Fill axis
       ═══════════════════════════════════════════════════════════════ */

    function test_fillAxis_assets_sellSide() public {
        _primeSellerSide();
        Action[] memory actions = new Action[](1);
        actions[0] = _sellerSideAction(50e18, DEFAULT_TICK, false);

        ExecuteParams memory params = _defaultExecuteParams(borrower);
        params.fillAxis = FillAxis.ASSETS;
        params.maxFill = 10e18;

        vm.prank(borrower);
        (, uint256 sellerAssets,) = router.execute(params, actions);
        assertGt(sellerAssets, 0, "ASSETS_SELL: > 0");
        assertLe(sellerAssets, params.maxFill, "ASSETS_SELL: capped");
    }

    function test_fillAxis_units() public {
        _primeBuyerSide();
        Action[] memory actions = new Action[](1);
        actions[0] = _buyerSideAction(50e18, DEFAULT_TICK, false);

        ExecuteParams memory params = _defaultExecuteParams(lender);
        params.fillAxis = FillAxis.UNITS;
        params.maxFill = 10e18;

        vm.prank(lender);
        (,, uint256 units) = router.execute(params, actions);
        assertGt(units, 0, "UNITS: > 0");
        assertLe(units, params.maxFill, "UNITS: capped");
    }

    /* ═══════════════════════════════════════════════════════════════
       Section 4 — Price slippage (band always available)
       ═══════════════════════════════════════════════════════════════ */

    function test_priceSlippage_withinBounds() public {
        _primeBuyerSide();
        Action[] memory actions = new Action[](1);
        actions[0] = _buyerSideAction(50e18, DEFAULT_TICK, false);

        uint256 tickPrice = TickLib.tickToPrice(DEFAULT_TICK);
        ExecuteParams memory params = _defaultExecuteParams(lender);
        params.minPrice = tickPrice * 8 / 10;
        params.maxPrice = tickPrice * 12 / 10;

        vm.prank(lender);
        (uint256 buyerAssets,, uint256 units) = router.execute(params, actions);
        uint256 effectivePrice = buyerAssets * 1e18 / units;
        assertGe(effectivePrice, params.minPrice, "PRICE: >= min");
        assertLe(effectivePrice, params.maxPrice, "PRICE: <= max");
    }

    function test_revert_priceSlippage_aboveMaxPrice() public {
        _primeBuyerSide();
        Action[] memory actions = new Action[](1);
        actions[0] = _buyerSideAction(50e18, DEFAULT_TICK, false);

        ExecuteParams memory params = _defaultExecuteParams(lender);
        params.maxPrice = TickLib.tickToPrice(DEFAULT_TICK) * 8 / 10;

        vm.prank(lender);
        vm.expectRevert();
        router.execute(params, actions);
    }

    /* ═══════════════════════════════════════════════════════════════
       Section 5 — Deadline
       ═══════════════════════════════════════════════════════════════ */

    function test_revert_deadlineExpired() public {
        _primeBuyerSide();
        Action[] memory actions = new Action[](1);
        actions[0] = _buyerSideAction(10e18, DEFAULT_TICK, false);

        ExecuteParams memory params = _defaultExecuteParams(lender);
        params.deadline = block.timestamp;
        vm.warp(block.timestamp + 10);

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ITenorRouter.DeadlineExpired.selector, params.deadline, block.timestamp));
        router.execute(params, actions);
    }

    function test_deadline_zero_noCheck() public {
        _primeBuyerSide();
        Action[] memory actions = new Action[](1);
        actions[0] = _buyerSideAction(10e18, DEFAULT_TICK, false);

        ExecuteParams memory params = _defaultExecuteParams(lender);
        params.deadline = 0;

        vm.prank(lender);
        (uint256 buyerAssets,,) = router.execute(params, actions);
        assertGt(buyerAssets, 0, "DEADLINE_ZERO: take still happens");
    }

    /* ═══════════════════════════════════════════════════════════════
       Section 6 — allowRevert / action failure
       ═══════════════════════════════════════════════════════════════ */

    function test_revert_actionFailed() public {
        _primeBuyerSide();

        // Expired offer — Midnight rejects it; allowRevert=false aborts the batch.
        Offer memory badOffer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            maxUnits: type(uint128).max,
            start: block.timestamp,
            expiry: 1,
            tick: DEFAULT_TICK,
            group: _freshGroup(),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: borrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory badSig = _signOffer(badOffer, borrowerSK);
        Action[] memory actions = new Action[](1);
        actions[0] = _action(badOffer, badSig, HashLib.hashOffer(badOffer), 10e18, address(0));

        vm.prank(lender);
        vm.expectRevert();
        router.execute(_defaultExecuteParams(lender), actions);
    }

    function test_allowRevert_skipsAndContinues() public {
        _primeBuyerSide();

        Offer memory badOffer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            maxUnits: type(uint128).max,
            start: block.timestamp,
            expiry: 1,
            tick: DEFAULT_TICK,
            group: _freshGroup(),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: borrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory badSig = _signOffer(badOffer, borrowerSK);
        Action memory badAction = _action(badOffer, badSig, HashLib.hashOffer(badOffer), 10e18, address(0));
        badAction.allowRevert = true;

        Action[] memory actions = new Action[](2);
        actions[0] = badAction;
        actions[1] = _buyerSideAction(30e18, DEFAULT_TICK, false);

        vm.prank(lender);
        (uint256 buyerAssets,, uint256 units) = router.execute(_defaultExecuteParams(lender), actions);
        assertGt(buyerAssets, 0, "ALLOW_REVERT: good action filled");
        assertGt(units, 0, "ALLOW_REVERT: good action units");
    }

    /* ═══════════════════════════════════════════════════════════════
       Section 7 — Clamps
       ═══════════════════════════════════════════════════════════════ */

    function test_clamp_reducesTakeShares() public {
        _primeBuyerSide();
        Action[] memory soloArr = new Action[](1);
        soloArr[0] = _buyerSideAction(50e18, DEFAULT_TICK, false);
        vm.prank(lender);
        (,, uint256 unclamped) = router.execute(_defaultExecuteParams(lender), soloArr);
        assertGt(unclamped, 0, "baseline > 0");

        setUp();
        _primeBuyerSide();
        uint256 clampMax = unclamped / 2;
        MockTakeClamp mockClamp = new MockTakeClamp(clampMax);

        Action memory clampedAction = _buyerSideAction(type(uint128).max, DEFAULT_TICK, false);
        clampedAction.clamp = address(mockClamp);
        Action[] memory actions = new Action[](1);
        actions[0] = clampedAction;

        vm.prank(lender);
        (,, uint256 clampedFill) = router.execute(_defaultExecuteParams(lender), actions);
        assertLe(clampedFill, clampMax, "CLAMP: <= clamp max");
        assertLt(clampedFill, unclamped, "CLAMP: < unclamped");
    }

    function test_clamp_addressZero_noClamping() public {
        _primeBuyerSide();
        Action[] memory actions = new Action[](1);
        actions[0] = _buyerSideAction(30e18, DEFAULT_TICK, false);

        vm.prank(lender);
        (uint256 buyerAssets,,) = router.execute(_defaultExecuteParams(lender), actions);
        assertGt(buyerAssets, 0, "CLAMP_ZERO: full fill");
    }

    /* ═══════════════════════════════════════════════════════════════
       Section 8 — Empty + events + consistency
       ═══════════════════════════════════════════════════════════════ */

    function test_emitsBatchExecuted() public {
        _primeBuyerSide();
        Action[] memory actions = new Action[](1);
        actions[0] = _buyerSideAction(30e18, DEFAULT_TICK, false);

        ExecuteParams memory params = _defaultExecuteParams(lender);

        vm.prank(lender);
        vm.expectEmit(true, true, false, false);
        emit ITenorRouter.BatchExecuted(lender, lender, params, 1, 0, 0, 0);
        router.execute(params, actions);
    }

    function test_emptyActionsArray() public {
        Action[] memory actions = new Action[](0);
        vm.prank(lender);
        vm.expectRevert(ITenorRouter.EmptyActions.selector);
        router.execute(_defaultExecuteParams(lender), actions);
    }

    /// @dev action[0] seller-side (BUY offer → batch side seller), action[1] buyer-side (SELL offer) trips
    ///      `InconsistentSide(1, false)` before dispatch.
    function test_revert_inconsistentSide() public {
        _primeSellerSide();

        Action memory sellAction = _sellerSideAction(10e18, DEFAULT_TICK, false);

        (Offer memory sellOffer, Signature memory sig, bytes32 root) =
            _sellOfferOnTarget(DEFAULT_TICK, lender, lenderSK);
        Action memory buyAction = _action(sellOffer, sig, root, 10e18, address(0));

        Action[] memory actions = new Action[](2);
        actions[0] = sellAction;
        actions[1] = buyAction;

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ITenorRouter.InconsistentSide.selector, uint256(1), false));
        router.execute(_defaultExecuteParams(borrower), actions);
    }

    /// @dev action[1] targets `sourceMarket`; `touchMarket` returns the wrong id → `InconsistentMarket(1)` (fires
    ///      before the per-action success check, regardless of whether the take would have settled).
    function test_revert_inconsistentMarket() public {
        _primeBuyerSide();

        Action memory a0 = _buyerSideAction(10e18, DEFAULT_TICK, false);
        Action memory a1 = _buyerSideAction(10e18, DEFAULT_TICK, false);
        a1.offer.market = sourceMarket;

        Action[] memory actions = new Action[](2);
        actions[0] = a0;
        actions[1] = a1;

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ITenorRouter.InconsistentMarket.selector, uint256(1)));
        router.execute(_defaultExecuteParams(lender), actions);
    }

    /* ═══════════════════════════════════════════════════════════════
       Section 9 — M-02 fee-adjuster regressions (taker side)
       ═══════════════════════════════════════════════════════════════ */

    function test_m02_fix_midnightTake_feeOvershoot_buyerAssets() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, targetMarket, targetMarketId);
        (Offer memory offer, Signature memory sig, bytes32 root) =
            _sellOfferOnTarget(DEFAULT_TICK, borrower, borrowerSK);

        CallbackFeeAdjuster feeAdjuster = new CallbackFeeAdjuster(address(midnight));
        bytes memory adjusterData = abi.encode(uint256(0.1e18), CallbackFeeAdjuster.FeeFormula.INTEREST);

        Action memory action = _action(offer, sig, root, type(uint128).max, address(0));
        action.feeAdjuster = address(feeAdjuster);
        action.feeAdjusterData = adjusterData;
        Action[] memory actions = new Action[](1);
        actions[0] = action;

        ExecuteParams memory params = _defaultExecuteParams(lender);
        params.fillAxis = FillAxis.ASSETS;
        params.maxFill = 10e18;

        vm.prank(lender);
        (uint256 buyerAssets,,) = router.execute(params, actions);
        assertGt(buyerAssets, 0, "M-02: > 0");
        assertLe(buyerAssets, params.maxFill, "M-02: <= maxFill (no overshoot)");
    }

    function test_m02_fix_midnightTake_feeUnderfill_sellerAssets() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, targetMarket, targetMarketId);
        (Offer memory offer, Signature memory sig, bytes32 root) = _buyOfferOnTarget(DEFAULT_TICK, lender, lenderSK);

        CallbackFeeAdjuster feeAdjuster = new CallbackFeeAdjuster(address(midnight));
        bytes memory adjusterData = abi.encode(uint256(0.1e18), CallbackFeeAdjuster.FeeFormula.INTEREST);

        Action memory action = _action(offer, sig, root, type(uint128).max, borrower);
        action.feeAdjuster = address(feeAdjuster);
        action.feeAdjusterData = adjusterData;
        Action[] memory actions = new Action[](1);
        actions[0] = action;

        ExecuteParams memory params = _defaultExecuteParams(borrower);
        params.fillAxis = FillAxis.ASSETS;
        params.maxFill = 10e18;

        vm.prank(borrower);
        (, uint256 sellerAssets,) = router.execute(params, actions);
        assertGt(sellerAssets, 0, "M-02 underfill: > 0");
        assertLe(sellerAssets, params.maxFill, "M-02 underfill: <= maxFill");
        assertGe(sellerAssets, params.maxFill * 95 / 100, "M-02 underfill: >= 95% of maxFill");
    }

    function test_m02_fix_zeroFeeRate_matchesPlainInversion() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, targetMarket, targetMarketId);
        (Offer memory offer, Signature memory sig, bytes32 root) =
            _sellOfferOnTarget(DEFAULT_TICK, borrower, borrowerSK);

        CallbackFeeAdjuster feeAdjuster = new CallbackFeeAdjuster(address(midnight));
        bytes memory adjusterData = abi.encode(uint256(0), CallbackFeeAdjuster.FeeFormula.INTEREST);

        Action memory action = _action(offer, sig, root, type(uint128).max, address(0));
        action.feeAdjuster = address(feeAdjuster);
        action.feeAdjusterData = adjusterData;
        Action[] memory actions = new Action[](1);
        actions[0] = action;

        ExecuteParams memory params = _defaultExecuteParams(lender);
        params.fillAxis = FillAxis.ASSETS;
        params.maxFill = 10e18;

        vm.prank(lender);
        (uint256 buyerAssets,,) = router.execute(params, actions);
        assertEq(buyerAssets, params.maxFill, "M-02 zeroFee: == maxFill (plain inversion)");
    }

    /* ═══════════════════════════════════════════════════════════════
       Section 10 — reduceOnly (crossing protection)
       ═══════════════════════════════════════════════════════════════ */

    function _reduceOnlyParams(address account) internal pure returns (ExecuteParams memory params) {
        params = _defaultExecuteParams(account);
        params.reduceOnly = true;
    }

    function test_reduceOnly_overResell_reverts() public {
        _setupLenderWithCredit(lender, 50e18, targetMarket, targetMarketId);
        _depositCollateral(lender, 1000e18, targetMarket);

        (address tempBuyer, uint256 tempBuyerSK) = makeAddrAndKey("tempBuyer-crossing");
        loanToken.mint(tempBuyer, type(uint128).max);
        vm.startPrank(tempBuyer);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, tempBuyer);
        vm.stopPrank();

        (Offer memory offer, Signature memory sig, bytes32 root) =
            _buyOfferOnTarget(DEFAULT_TICK, tempBuyer, tempBuyerSK);
        Action[] memory actions = new Action[](1);
        actions[0] = _action(offer, sig, root, 100e18, lender);

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ITenorRouter.ReduceOnlyViolated.selector, uint256(0), uint256(50e18)));
        router.execute(_reduceOnlyParams(lender), actions);
    }

    function test_reduceOnly_overRepay_reverts() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, 1000e18, targetMarket, targetMarketId);
        _setupLenderWithCredit(lender, 1100e18, targetMarket, targetMarketId);

        (Offer memory offer, Signature memory sig, bytes32 root) = _sellOfferOnTarget(DEFAULT_TICK, lender, lenderSK);
        Action[] memory actions = new Action[](1);
        actions[0] = _action(offer, sig, root, 1100e18, address(0));

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ITenorRouter.ReduceOnlyViolated.selector, uint256(0), uint256(100e18)));
        router.execute(_reduceOnlyParams(borrower), actions);
    }

    function test_reduceOnly_partialResell_belowCredit_passes() public {
        _setupLenderWithCredit(lender, 100e18, targetMarket, targetMarketId);

        (address tempBuyer, uint256 tempBuyerSK) = makeAddrAndKey("tempBuyer-partial");
        loanToken.mint(tempBuyer, type(uint128).max);
        vm.startPrank(tempBuyer);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, tempBuyer);
        vm.stopPrank();

        (Offer memory offer, Signature memory sig, bytes32 root) =
            _buyOfferOnTarget(DEFAULT_TICK, tempBuyer, tempBuyerSK);
        Action[] memory actions = new Action[](1);
        actions[0] = _action(offer, sig, root, 30e18, lender);

        vm.prank(lender);
        router.execute(_reduceOnlyParams(lender), actions);
        assertEq(midnight.debt(targetMarketId, lender), 0, "partial resell: no debt added");
    }

    function test_reduceOnly_partialRepay_belowDebt_passes() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, 1000e18, targetMarket, targetMarketId);
        _setupLenderWithCredit(lender, 200e18, targetMarket, targetMarketId);

        (Offer memory offer, Signature memory sig, bytes32 root) = _sellOfferOnTarget(DEFAULT_TICK, lender, lenderSK);
        Action[] memory actions = new Action[](1);
        actions[0] = _action(offer, sig, root, 200e18, address(0));

        vm.prank(borrower);
        router.execute(_reduceOnlyParams(borrower), actions);
        assertEq(midnight.credit(targetMarketId, borrower), 0, "partial repay: no credit added");
    }

    function test_reduceOnly_allowRevert_multiAction_passes() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, 1000e18, targetMarket, targetMarketId);
        _setupLenderWithCredit(lender, 500e18, targetMarket, targetMarketId);

        Offer memory badOffer = Offer({
            market: targetMarket,
            buy: false,
            maker: lender,
            maxUnits: type(uint128).max,
            start: block.timestamp,
            expiry: 1,
            tick: DEFAULT_TICK,
            group: _freshGroup(),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: lender,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory badSig = _signOffer(badOffer, lenderSK);
        Action memory badAction = _action(badOffer, badSig, HashLib.hashOffer(badOffer), 100e18, address(0));
        badAction.allowRevert = true;

        (Offer memory goodOffer, Signature memory goodSig, bytes32 goodRoot) =
            _sellOfferOnTarget(DEFAULT_TICK, lender, lenderSK);
        Action memory goodAction = _action(goodOffer, goodSig, goodRoot, 200e18, address(0));

        Action[] memory actions = new Action[](2);
        actions[0] = badAction;
        actions[1] = goodAction;

        vm.prank(borrower);
        router.execute(_reduceOnlyParams(borrower), actions);
        assertEq(midnight.credit(targetMarketId, borrower), 0, "allowRevert mix: no credit added");
    }

    /* ═══════════════════════════════════════════════════════════════
       Section 11 — maxContinuousFee (taker fee protection)
       ═══════════════════════════════════════════════════════════════ */

    /// @dev Sets the market fee to MAX_CONTINUOUS_FEE and returns a one-action buyer-side batch capped at `cap`.
    function _feeCapCase(uint256 cap, bool allowRevert)
        internal
        returns (ExecuteParams memory params, Action[] memory actions)
    {
        _primeBuyerSide();
        midnight.setFeeSetter(address(this));
        midnight.setMarketContinuousFee(targetMarketId, MAX_CONTINUOUS_FEE);

        actions = new Action[](1);
        actions[0] = _buyerSideAction(50e18, DEFAULT_TICK, allowRevert);

        params = _defaultExecuteParams(lender);
        params.maxContinuousFee = cap;
    }

    function test_revert_continuousFeeAboveMax() public {
        (ExecuteParams memory params, Action[] memory actions) = _feeCapCase(MAX_CONTINUOUS_FEE - 1, false);

        vm.prank(lender);
        vm.expectRevert(ITenorRouter.ContinuousFeeAboveMax.selector);
        router.execute(params, actions);
    }

    function test_revert_continuousFeeAboveMax_allowRevert_stillReverts() public {
        (ExecuteParams memory params, Action[] memory actions) = _feeCapCase(MAX_CONTINUOUS_FEE - 1, true);

        vm.prank(lender);
        vm.expectRevert(ITenorRouter.ContinuousFeeAboveMax.selector);
        router.execute(params, actions);
    }

    function test_continuousFee_atMax_passes() public {
        (ExecuteParams memory params, Action[] memory actions) = _feeCapCase(MAX_CONTINUOUS_FEE, false);

        vm.prank(lender);
        (uint256 buyerAssets,, uint256 units) = router.execute(params, actions);
        assertGt(buyerAssets, 0, "FEE_AT_MAX: buyerAssets > 0");
        assertGt(units, 0, "FEE_AT_MAX: units > 0");
    }
}
