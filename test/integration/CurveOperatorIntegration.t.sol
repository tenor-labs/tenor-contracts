// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {MarketMakingPolicy} from "../../src/ratifiers/policies/MarketMakingPolicy.sol";
import {CurveOperator} from "../../src/ratifiers/policies/CurveOperator.sol";
import {IMarketMakingPolicy} from "../../src/ratifiers/interfaces/IMarketMakingPolicy.sol";

/// @title CurveOperatorIntegrationTest
/// @notice End-to-end coverage of the scoped-delegation model against a real Midnight deployment:
///         `MAKER -> Midnight.setIsAuthorized(curveOperator)` -> `OPERATOR -> CurveOperator.setCurve` ->
///         `MarketMakingPolicy.setCurve(MAKER, ...)` -> `MarketMakingPolicy.getRate`.
///         The point of the delegate is that the Midnight grant it receives is unscoped, while the authority it
///         re-exposes is not. These tests assert both halves: the curve writes land, and nothing else does.
contract CurveOperatorIntegrationTest is Test {
    Midnight internal midnight;
    MarketMakingPolicy internal policy;
    CurveOperator internal curveOperator;

    address internal maker = makeAddr("maker");
    address internal operator = makeAddr("operator");
    address internal otherMaker = makeAddr("otherMaker");
    address internal attacker = makeAddr("attacker");

    bytes32 internal constant SRC = bytes32(uint256(0x5e1));
    bytes32 internal constant TGT = bytes32(uint256(0x6e1));

    uint256 internal constant NOW = 1_000_000;
    uint256 internal constant MATURITY = 1_000_100;

    function setUp() public {
        midnight = new Midnight();
        policy = new MarketMakingPolicy(address(midnight));
        curveOperator = new CurveOperator(address(policy), maker, operator);

        // The only grant the maker ever makes. It is unscoped on Midnight by construction.
        vm.prank(maker);
        midnight.setIsAuthorized(address(curveOperator), true, maker);

        vm.warp(NOW);
    }

    /* ═══════ Happy path ═══════ */

    function test_operatorWritesMakerCurveThroughDelegate() public {
        vm.prank(operator);
        curveOperator.setCurve(TGT, _twoPoint(100, 1e18, 3e18, 200, 2e18, 4e18));

        // The curve is stored against the MAKER, not against the delegate or the operator key.
        (uint32 ttm, uint112 sellRate, uint112 buyRate) = policy.curves(maker, TGT, 0);
        assertEq(ttm, 100);
        assertEq(sellRate, 1e18);
        assertEq(buyRate, 3e18);

        assertEq(policy.getRate(SRC, TGT, 0, maker, address(0), 0, MATURITY, true), 3e18, "buy side");
        assertEq(policy.getRate(TGT, SRC, 0, maker, address(0), MATURITY, 0, false), 1e18, "sell side");

        // Nothing is quotable for the delegate or the operator themselves.
        vm.expectRevert(IMarketMakingPolicy.NoCurveForUserMarket.selector);
        policy.getRate(SRC, TGT, 0, address(curveOperator), address(0), 0, MATURITY, true);
        vm.expectRevert(IMarketMakingPolicy.NoCurveForUserMarket.selector);
        policy.getRate(SRC, TGT, 0, operator, address(0), 0, MATURITY, true);
    }

    function test_operatorClearsMakerCurveThroughDelegate() public {
        vm.startPrank(operator);
        curveOperator.setCurve(TGT, _twoPoint(100, 1e18, 3e18, 200, 2e18, 4e18));
        curveOperator.clearCurve(TGT);
        vm.stopPrank();

        vm.expectRevert(IMarketMakingPolicy.NoCurveForUserMarket.selector);
        policy.getRate(SRC, TGT, 0, maker, address(0), 0, MATURITY, true);
    }

    function test_onlyOperatorKeyCanDriveTheDelegate() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 3e18, 200, 2e18, 4e18);

        vm.prank(attacker);
        vm.expectRevert(CurveOperator.Unauthorized.selector);
        curveOperator.setCurve(TGT, pts);

        // Even the maker is not the operator: the delegate is a one-key instrument, the maker writes directly.
        vm.prank(maker);
        vm.expectRevert(CurveOperator.Unauthorized.selector);
        curveOperator.setCurve(TGT, pts);

        vm.prank(attacker);
        vm.expectRevert(CurveOperator.Unauthorized.selector);
        curveOperator.clearCurve(TGT);
    }

    /* ═══════ The scoping property ═══════ */

    /// @dev The core claim. The delegate holds an unscoped Midnight grant, so the operator's reachable action set is
    ///      whatever the delegate's bytecode exposes. Assert the escalating Midnight entry points are not reachable
    ///      through it: no matching selector, no fallback, no arbitrary-call path.
    function test_operatorCannotReachMidnightThroughTheDelegate() public {
        assertTrue(midnight.isAuthorized(maker, address(curveOperator)), "delegate is fully authorized on Midnight");

        // Transitive re-grant: the escalation that would make an operator compromise permanent.
        _expectDelegateRejects(abi.encodeCall(IMidnight.setIsAuthorized, (attacker, true, maker)));
        // Fund extraction to an arbitrary receiver.
        _expectDelegateRejects(abi.encodeWithSelector(IMidnight.withdraw.selector));
        // Liveness: cancelling every offer the maker has outstanding.
        _expectDelegateRejects(abi.encodeCall(IMidnight.setConsumed, (bytes32(0), type(uint128).max, maker)));
        // No fallback and no receive.
        _expectDelegateRejects(hex"");
        _expectDelegateRejects(hex"deadbeef");

        assertFalse(midnight.isAuthorized(maker, attacker), "no third party was authorized");
        assertEq(midnight.consumed(maker, bytes32(0)), 0, "no offers were cancelled");
    }

    /// @dev Contrast case, and the reason the delegate exists. Granting the operator key directly on Midnight hands it
    ///      the same authority the delegate holds, but with nothing in front of it. Same grant, unbounded reach.
    function test_directGrantToTheOperatorKeyIsUnscoped() public {
        vm.prank(otherMaker);
        midnight.setIsAuthorized(operator, true, otherMaker);

        vm.startPrank(operator);
        // A compromised key installs a backdoor that outlives the revocation of the key itself.
        midnight.setIsAuthorized(attacker, true, otherMaker);
        // And can brick the maker's offer flow on the way out.
        midnight.setConsumed(bytes32(0), type(uint128).max, otherMaker);
        vm.stopPrank();

        assertTrue(midnight.isAuthorized(otherMaker, attacker), "backdoor installed");
        assertEq(midnight.consumed(otherMaker, bytes32(0)), type(uint128).max, "offers cancelled");

        // Revoking the operator does not undo the backdoor: the maker must find and revoke it separately.
        vm.prank(otherMaker);
        midnight.setIsAuthorized(operator, false, otherMaker);
        assertTrue(midnight.isAuthorized(otherMaker, attacker), "backdoor survives revocation");

        // Neither escalation is reachable through the delegate under the same starting grant.
        assertFalse(midnight.isAuthorized(maker, attacker));
        assertEq(midnight.consumed(maker, bytes32(0)), 0);
    }

    /// @dev The delegate hardcodes MAKER, so authorizing it from a second maker grants that maker nothing. This is what
    ///      keeps the blast radius readable off the three immutables rather than off Midnight's authorization graph.
    function test_delegateWritesOnlyForItsHardcodedMaker() public {
        vm.prank(otherMaker);
        midnight.setIsAuthorized(address(curveOperator), true, otherMaker);

        vm.prank(operator);
        curveOperator.setCurve(TGT, _twoPoint(100, 1e18, 3e18, 200, 2e18, 4e18));

        assertEq(policy.getRate(SRC, TGT, 0, maker, address(0), 0, MATURITY, true), 3e18);
        vm.expectRevert(IMarketMakingPolicy.NoCurveForUserMarket.selector);
        policy.getRate(SRC, TGT, 0, otherMaker, address(0), 0, MATURITY, true);
    }

    /// @dev Revocation authority never leaves the maker, and it is the kill switch for a compromised operator key.
    function test_makerRevocationDisablesTheDelegate() public {
        vm.prank(operator);
        curveOperator.setCurve(TGT, _twoPoint(100, 1e18, 3e18, 200, 2e18, 4e18));

        vm.prank(maker);
        midnight.setIsAuthorized(address(curveOperator), false, maker);

        vm.prank(operator);
        vm.expectRevert(IMarketMakingPolicy.Unauthorized.selector);
        curveOperator.setCurve(TGT, _twoPoint(100, 5e18, 6e18, 200, 5e18, 6e18));

        vm.prank(operator);
        vm.expectRevert(IMarketMakingPolicy.Unauthorized.selector);
        curveOperator.clearCurve(TGT);

        // The curve written before revocation is untouched: revoking stops writes, it does not roll them back.
        assertEq(policy.getRate(SRC, TGT, 0, maker, address(0), 0, MATURITY, true), 3e18);
    }

    /// @dev The delegate forwards raw points, so the policy's own validation is what bounds a malformed write.
    function test_policyValidationStillAppliesThroughTheDelegate() public {
        vm.startPrank(operator);

        vm.expectRevert(IMarketMakingPolicy.EmptyCurve.selector);
        curveOperator.setCurve(TGT, new IMarketMakingPolicy.CurvePoint[](0));

        vm.expectRevert(IMarketMakingPolicy.NonStrictlyIncreasingTtm.selector);
        curveOperator.setCurve(TGT, _twoPoint(200, 1e18, 3e18, 100, 1e18, 3e18));

        vm.expectRevert(IMarketMakingPolicy.CrossedCurve.selector);
        curveOperator.setCurve(TGT, _twoPoint(100, 3e18, 1e18, 200, 3e18, 4e18));

        vm.stopPrank();
    }

    /* ═══════ Helpers ═══════ */

    /// @dev Asserts the delegate has no code path for `data`, and that the call reverts without touching Midnight.
    function _expectDelegateRejects(bytes memory data) internal {
        vm.prank(operator);
        (bool success,) = address(curveOperator).call(data);
        assertFalse(success, "delegate exposed an unexpected code path");
    }

    function _twoPoint(uint32 t0, uint112 s0, uint112 b0, uint32 t1, uint112 s1, uint112 b1)
        internal
        pure
        returns (IMarketMakingPolicy.CurvePoint[] memory pts)
    {
        pts = new IMarketMakingPolicy.CurvePoint[](2);
        pts[0] = IMarketMakingPolicy.CurvePoint({ttm: t0, sellRate: s0, buyRate: b0});
        pts[1] = IMarketMakingPolicy.CurvePoint({ttm: t1, sellRate: s1, buyRate: b1});
    }
}
