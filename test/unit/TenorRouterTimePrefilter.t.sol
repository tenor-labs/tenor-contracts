// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {BoundaryTestBase} from "./boundary/BoundaryTestBase.sol";
import {TenorRouter, ExecuteParams, FillAxis, Action, MidnightTakeData} from "../../src/router/TenorRouter.sol";
import {ITenorRouter} from "../../src/router/interfaces/ITenorRouter.sol";
import {IMidnight, Offer, Market} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {MockTenorRouter} from "../helpers/mocks/MockTenorRouter.sol";

/// @title TenorRouterTimePrefilter
/// @notice Behavioral coverage for the `[start, expiry]` prefilter in TenorRouter._execute. Asserts selector parity
///         with `Midnight.take`'s own entry reverts, the allowRevert gating, the no-op on in-window offers, and the
///         documented relaxation of `InconsistentMarket` for skipped actions. Exercised through `MIDNIGHT_TAKE`
///         actions (the only action type); the prefilter runs before dispatch and is action-shape-agnostic.
contract TenorRouterTimePrefilter is BoundaryTestBase {
    TenorRouter internal router;

    uint16 internal constant DEFAULT_TICK = 2940;
    uint128 internal constant DEFAULT_BORROW_AMOUNT = 1000e18;

    function setUp() public override {
        super.setUp();
        vm.warp(1 days); // headroom for negative window offsets

        router = new MockTenorRouter(address(midnight));

        vm.prank(borrower);
        midnight.setIsAuthorized(address(router), true, borrower);
        vm.prank(lender);
        midnight.setIsAuthorized(address(router), true, lender);

        loanToken.mint(address(router), type(uint128).max);
        loanToken.mint(borrower, type(uint128).max);
        vm.prank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);

        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, targetMarket, targetMarketId);
    }

    /* ═══════════════════════════════════════════════════════════════
       Helpers
       ═══════════════════════════════════════════════════════════════ */

    function _defaultExecuteParams() internal pure returns (ExecuteParams memory) {
        return ExecuteParams({
            deadline: 0,
            fillAxis: FillAxis.UNITS,
            maxFill: type(uint256).max,
            minFill: 0,
            minPrice: 0,
            maxPrice: type(uint256).max,
            reduceOnly: false
        });
    }

    function _freshGroup() internal view returns (bytes32) {
        return keccak256(abi.encodePacked("prefilter", block.timestamp, gasleft()));
    }

    /// @dev Borrower-signed SELL offer on a configurable market with `[start, expiry]` from `block.timestamp + offset`.
    function _sellAction(
        Market memory market,
        int256 startOffset,
        int256 expiryOffset,
        uint256 takeUnits,
        bool allowRevert
    ) internal view returns (Action memory) {
        Offer memory offer = Offer({
            market: market,
            buy: false,
            maker: borrower,
            maxUnits: type(uint128).max,
            start: uint256(int256(block.timestamp) + startOffset),
            expiry: uint256(int256(block.timestamp) + expiryOffset),
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
        Signature memory sig = _signOffer(offer, borrowerSK);
        MidnightTakeData memory d = MidnightTakeData({
            takeUnits: takeUnits,
            takerCallback: address(0),
            takerCallbackData: "",
            receiverIfTakerIsSeller: address(0),
            ratifierData: abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0))
        });
        return Action({
            take: d,
            allowRevert: allowRevert,
            offer: offer,
            clamp: address(0),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });
    }

    function _onTarget(int256 startOffset, int256 expiryOffset, uint256 takeUnits, bool allowRevert)
        internal
        view
        returns (Action memory)
    {
        return _sellAction(targetMarket, startOffset, expiryOffset, takeUnits, allowRevert);
    }

    /// @dev BUY-side MIDNIGHT_TAKE action — exercises the `_initiatorIsBuyer` mismatch path.
    function _buyActionOnTarget(int256 startOffset, int256 expiryOffset, uint256 takeUnits, bool allowRevert)
        internal
        view
        returns (Action memory)
    {
        Offer memory offer = Offer({
            market: targetMarket,
            buy: true,
            maker: borrower,
            maxUnits: type(uint128).max,
            start: uint256(int256(block.timestamp) + startOffset),
            expiry: uint256(int256(block.timestamp) + expiryOffset),
            tick: DEFAULT_TICK,
            group: _freshGroup(),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory sig = _signOffer(offer, borrowerSK);
        MidnightTakeData memory d = MidnightTakeData({
            takeUnits: takeUnits,
            takerCallback: address(0),
            takerCallbackData: "",
            receiverIfTakerIsSeller: address(0),
            ratifierData: abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0))
        });
        return Action({
            take: d,
            allowRevert: allowRevert,
            offer: offer,
            clamp: address(0),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });
    }

    function _execAsLender(Action[] memory actions) internal {
        vm.prank(lender);
        router.execute(_defaultExecuteParams(), actions);
    }

    /* ═══════════════════════════════════════════════════════════════
       Prefilter emits the same selector Midnight.take would
       ═══════════════════════════════════════════════════════════════ */

    function test_prefilter_notStarted_emitsMidnightSelector() public {
        Action[] memory actions = new Action[](1);
        actions[0] = _onTarget(int256(1 hours), int256(2 hours), 10e18, true);

        vm.expectEmit(true, false, false, true, address(router));
        emit ITenorRouter.ActionReverted(0, abi.encodeWithSelector(IMidnight.OfferNotStarted.selector));
        _execAsLender(actions);
    }

    function test_prefilter_expired_emitsMidnightSelector() public {
        vm.warp(block.timestamp + 10 hours);
        Action[] memory actions = new Action[](1);
        actions[0] = _onTarget(-int256(2 hours), -int256(1 hours), 10e18, true);

        vm.expectEmit(true, false, false, true, address(router));
        emit ITenorRouter.ActionReverted(0, abi.encodeWithSelector(IMidnight.OfferExpired.selector));
        _execAsLender(actions);
    }

    /* ═══════════════════════════════════════════════════════════════
       allowRevert=false is unchanged: out-of-window aborts
       ═══════════════════════════════════════════════════════════════ */

    function test_noPrefilter_whenAllowRevertFalse_expired_revertsBatch() public {
        vm.warp(block.timestamp + 10 hours);
        Action[] memory actions = new Action[](1);
        actions[0] = _onTarget(-int256(2 hours), -int256(1 hours), 10e18, false);

        vm.prank(lender);
        vm.expectRevert();
        router.execute(_defaultExecuteParams(), actions);
    }

    function test_noPrefilter_whenAllowRevertFalse_notStarted_revertsBatch() public {
        Action[] memory actions = new Action[](1);
        actions[0] = _onTarget(int256(1 hours), int256(2 hours), 10e18, false);

        vm.prank(lender);
        vm.expectRevert();
        router.execute(_defaultExecuteParams(), actions);
    }

    /* ═══════════════════════════════════════════════════════════════
       Prefilter is inert when the offer is in-window
       ═══════════════════════════════════════════════════════════════ */

    function test_prefilter_inWindow_noSkip_filled() public {
        Action[] memory actions = new Action[](1);
        actions[0] = _onTarget(int256(0), int256(1 hours), 10e18, true);

        vm.prank(lender);
        (uint256 buyerAssets,, uint256 units) = router.execute(_defaultExecuteParams(), actions);
        assertGt(buyerAssets, 0, "in-window: dispatched, buyerAssets > 0");
        assertGt(units, 0, "in-window: dispatched, units > 0");
    }

    /* ═══════════════════════════════════════════════════════════════
       Documented relaxation: skipped action on wrong market
       ═══════════════════════════════════════════════════════════════ */

    function test_prefilter_skipsOnWrongMarket_noInconsistentMarketRevert() public {
        Action[] memory actions = new Action[](2);
        actions[0] = _onTarget(int256(0), int256(1 hours), 10e18, false);
        actions[1] = _sellAction(sourceMarket, int256(1 hours), int256(2 hours), 10e18, true);

        vm.prank(lender);
        (uint256 buyerAssets,, uint256 units) = router.execute(_defaultExecuteParams(), actions);
        assertGt(buyerAssets, 0, "live action[0] filled");
        assertGt(units, 0, "live action[0] units");
    }

    /* ═══════════════════════════════════════════════════════════════
       Boundary endpoints (== start / == expiry / off-by-one)
       ═══════════════════════════════════════════════════════════════ */

    function test_prefilter_atExpiry_inclusiveBoundary_filled() public {
        vm.warp(block.timestamp + 1 days);
        Action[] memory actions = new Action[](1);
        actions[0] = _onTarget(-int256(1 hours), int256(0), 10e18, true);

        vm.prank(lender);
        (uint256 buyerAssets,, uint256 units) = router.execute(_defaultExecuteParams(), actions);
        assertGt(buyerAssets, 0, "atExpiry: dispatched, buyerAssets > 0");
        assertGt(units, 0, "atExpiry: dispatched, units > 0");
    }

    function test_prefilter_atExpiryPlusOne_skips() public {
        vm.warp(block.timestamp + 1 days);
        Action[] memory actions = new Action[](1);
        actions[0] = _onTarget(-int256(1 hours), -int256(1), 10e18, true);

        vm.expectEmit(true, false, false, true, address(router));
        emit ITenorRouter.ActionReverted(0, abi.encodeWithSelector(IMidnight.OfferExpired.selector));
        _execAsLender(actions);
    }

    function test_prefilter_atStartMinusOne_skips() public {
        Action[] memory actions = new Action[](1);
        actions[0] = _onTarget(int256(1), int256(1 hours), 10e18, true);

        vm.expectEmit(true, false, false, true, address(router));
        emit ITenorRouter.ActionReverted(0, abi.encodeWithSelector(IMidnight.OfferNotStarted.selector));
        _execAsLender(actions);
    }

    /* ═══════════════════════════════════════════════════════════════
       Pathological offer: start > expiry (not-started checked first)
       ═══════════════════════════════════════════════════════════════ */

    function test_prefilter_startGtExpiry_emitsNotStartedFirst() public {
        Action[] memory actions = new Action[](1);
        actions[0] = _onTarget(int256(1 hours), -int256(1 hours), 10e18, true);

        vm.expectEmit(true, false, false, true, address(router));
        emit ITenorRouter.ActionReverted(0, abi.encodeWithSelector(IMidnight.OfferNotStarted.selector));
        _execAsLender(actions);
    }

    /* ═══════════════════════════════════════════════════════════════
       Side check runs before the prefilter (ROUTER-5 still fires)
       ═══════════════════════════════════════════════════════════════ */

    function test_prefilter_doesNotMaskInconsistentSide() public {
        Action[] memory actions = new Action[](2);
        actions[0] = _onTarget(int256(0), int256(1 hours), 10e18, false);
        actions[1] = _buyActionOnTarget(int256(1 hours), int256(2 hours), 10e18, true);

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ITenorRouter.InconsistentSide.selector, 1, true));
        router.execute(_defaultExecuteParams(), actions);
    }

    /* ═══════════════════════════════════════════════════════════════
       Event ordering across multiple skips
       ═══════════════════════════════════════════════════════════════ */

    function test_prefilter_multiSkip_eventOrder() public {
        vm.warp(block.timestamp + 1 days);
        Action[] memory actions = new Action[](3);
        actions[0] = _onTarget(-int256(2 hours), -int256(1 hours), 10e18, true);
        actions[1] = _onTarget(int256(1 hours), int256(2 hours), 10e18, true);
        actions[2] = _onTarget(int256(0), int256(30 minutes), 10e18, true);

        vm.expectEmit(true, false, false, true, address(router));
        emit ITenorRouter.ActionReverted(0, abi.encodeWithSelector(IMidnight.OfferExpired.selector));
        vm.expectEmit(true, false, false, true, address(router));
        emit ITenorRouter.ActionReverted(1, abi.encodeWithSelector(IMidnight.OfferNotStarted.selector));

        vm.prank(lender);
        (uint256 buyerAssets,, uint256 units) = router.execute(_defaultExecuteParams(), actions);
        assertGt(buyerAssets, 0, "live action[2] still filled");
        assertGt(units, 0, "live action[2] units");
    }

    /* ═══════════════════════════════════════════════════════════════
       reduceOnly with all actions prefiltered
       ═══════════════════════════════════════════════════════════════ */

    function test_prefilter_allPrefiltered_reduceOnlyPasses() public {
        Action[] memory actions = new Action[](2);
        actions[0] = _onTarget(int256(1 hours), int256(2 hours), 10e18, true);
        actions[1] = _onTarget(int256(1 hours), int256(2 hours), 10e18, true);

        ExecuteParams memory p = _defaultExecuteParams();
        p.reduceOnly = true;

        vm.prank(lender);
        (uint256 buyerAssets, uint256 sellerAssets, uint256 units) = router.execute(p, actions);
        assertEq(buyerAssets, 0, "all prefiltered: buyerAssets == 0");
        assertEq(sellerAssets, 0, "all prefiltered: sellerAssets == 0");
        assertEq(units, 0, "all prefiltered: units == 0");
    }

    /* ═══════════════════════════════════════════════════════════════
       CI-pin: prefilter encoding matches Midnight.take's revert bytes
       ═══════════════════════════════════════════════════════════════ */

    function test_pinSelector_directMidnight_notStartedMatchesPrefilterEncoding() public {
        Action memory a = _onTarget(int256(1 hours), int256(2 hours), 10e18, true);
        bytes memory ratifierData = a.take.ratifierData;

        vm.prank(lender);
        (bool ok, bytes memory reason) = address(midnight)
            .call(abi.encodeCall(midnight.take, (a.offer, ratifierData, 10e18, lender, address(0), address(0), "")));
        assertFalse(ok, "Midnight.take must revert for not-started offer");
        assertEq(reason, abi.encodeWithSelector(IMidnight.OfferNotStarted.selector), "selector parity");
    }

    function test_pinSelector_directMidnight_expiredMatchesPrefilterEncoding() public {
        vm.warp(block.timestamp + 10 hours);
        Action memory a = _onTarget(-int256(2 hours), -int256(1 hours), 10e18, true);
        bytes memory ratifierData = a.take.ratifierData;

        vm.prank(lender);
        (bool ok, bytes memory reason) = address(midnight)
            .call(abi.encodeCall(midnight.take, (a.offer, ratifierData, 10e18, lender, address(0), address(0), "")));
        assertFalse(ok, "Midnight.take must revert for expired offer");
        assertEq(reason, abi.encodeWithSelector(IMidnight.OfferExpired.selector), "selector parity");
    }
}
