// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {MarketMakingPolicy} from "../../src/ratifiers/policies/MarketMakingPolicy.sol";
import {IMarketMakingPolicy} from "../../src/ratifiers/interfaces/IMarketMakingPolicy.sol";

contract MarketMakingPolicyTest is Test {
    MarketMakingPolicy internal policy;
    address internal midnight = makeAddr("midnight");
    address internal mm = makeAddr("mm");
    address internal otherMm = makeAddr("otherMm");
    address internal delegate = makeAddr("delegate");

    bytes32 internal constant SRC = bytes32(uint256(0x5e1));
    bytes32 internal constant TGT = bytes32(uint256(0x6e1));

    function setUp() public {
        policy = new MarketMakingPolicy(midnight);
        vm.mockCall(midnight, abi.encodeWithSelector(IMidnight.isAuthorized.selector), abi.encode(false));
    }

    /* Authorization */

    function test_setCurve_onBehalfOfSelf_works() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 3e18, 200, 1e18, 3e18);
        vm.prank(mm);
        policy.setCurve(mm, TGT, pts);
        vm.warp(1_000_000);
        assertEq(policy.getRate(SRC, TGT, 0, mm, address(0), 0, 1_000_100, true), 3e18);
    }

    function test_setCurve_unauthorizedCaller_reverts() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 3e18, 200, 1e18, 3e18);
        vm.prank(delegate);
        vm.expectRevert(IMarketMakingPolicy.Unauthorized.selector);
        policy.setCurve(mm, TGT, pts);
    }

    function test_setCurve_midnightAuthorizedDelegate_works() public {
        vm.mockCall(midnight, abi.encodeWithSelector(IMidnight.isAuthorized.selector, mm, delegate), abi.encode(true));
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 3e18, 200, 1e18, 3e18);
        vm.prank(delegate);
        policy.setCurve(mm, TGT, pts);

        vm.warp(1_000_000);
        assertEq(policy.getRate(SRC, TGT, 0, mm, address(0), 0, 1_000_100, true), 3e18);
        vm.expectRevert(IMarketMakingPolicy.NoCurveForUserMarket.selector);
        policy.getRate(SRC, TGT, 0, delegate, address(0), 0, 1_000_100, true);
    }

    function test_clearCurve_unauthorizedCaller_reverts() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 3e18, 200, 1e18, 3e18);
        vm.prank(mm);
        policy.setCurve(mm, TGT, pts);

        vm.prank(delegate);
        vm.expectRevert(IMarketMakingPolicy.Unauthorized.selector);
        policy.clearCurve(mm, TGT);
    }

    function test_clearCurve_midnightAuthorizedDelegate_works() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 3e18, 200, 1e18, 3e18);
        vm.prank(mm);
        policy.setCurve(mm, TGT, pts);

        vm.mockCall(midnight, abi.encodeWithSelector(IMidnight.isAuthorized.selector, mm, delegate), abi.encode(true));
        vm.prank(delegate);
        policy.clearCurve(mm, TGT);

        vm.warp(1_000_000);
        vm.expectRevert(IMarketMakingPolicy.NoCurveForUserMarket.selector);
        policy.getRate(SRC, TGT, 0, mm, address(0), 0, 1_000_100, true);
    }

    /* Curve admin */

    function test_setCurve_rejectsEmpty() public {
        IMarketMakingPolicy.CurvePoint[] memory empty = new IMarketMakingPolicy.CurvePoint[](0);
        vm.prank(mm);
        vm.expectRevert(IMarketMakingPolicy.EmptyCurve.selector);
        policy.setCurve(mm, TGT, empty);
    }

    function test_setCurve_rejectsMoreThanMax() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = new IMarketMakingPolicy.CurvePoint[](9);
        for (uint32 i = 0; i < 9; i++) {
            pts[i] = IMarketMakingPolicy.CurvePoint({ttm: i + 1, sellRate: 1e18, buyRate: 2e18});
        }
        vm.prank(mm);
        vm.expectRevert(IMarketMakingPolicy.TooManyPoints.selector);
        policy.setCurve(mm, TGT, pts);
    }

    function test_setCurve_rejectsNonStrictlyIncreasingTtm() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = new IMarketMakingPolicy.CurvePoint[](3);
        pts[0] = IMarketMakingPolicy.CurvePoint({ttm: 100, sellRate: 1e18, buyRate: 2e18});
        pts[1] = IMarketMakingPolicy.CurvePoint({ttm: 100, sellRate: 1e18, buyRate: 2e18}); // dup ttm
        pts[2] = IMarketMakingPolicy.CurvePoint({ttm: 200, sellRate: 1e18, buyRate: 2e18});
        vm.prank(mm);
        vm.expectRevert(IMarketMakingPolicy.NonStrictlyIncreasingTtm.selector);
        policy.setCurve(mm, TGT, pts);
    }

    function test_setCurve_rejectsCrossedCurve_atFirstPoint() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 5e18, 4e18, 200, 1e18, 3e18);
        vm.prank(mm);
        vm.expectRevert(IMarketMakingPolicy.CrossedCurve.selector);
        policy.setCurve(mm, TGT, pts);
    }

    function test_setCurve_rejectsCrossedCurve_atLaterPoint() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 3e18, 200, 5e18, 2e18);
        vm.prank(mm);
        vm.expectRevert(IMarketMakingPolicy.CrossedCurve.selector);
        policy.setCurve(mm, TGT, pts);
    }

    function test_setCurve_acceptsEqualSellAndBuy() public {
        // sell == buy is a zero-spread quote — pointless for the MM but not harmful, so allowed.
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 2e18, 2e18, 200, 1e18, 3e18);
        vm.prank(mm);
        policy.setCurve(mm, TGT, pts);
    }

    function test_setCurve_acceptsMaxPoints() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = new IMarketMakingPolicy.CurvePoint[](8);
        for (uint32 i = 0; i < 8; i++) {
            pts[i] = IMarketMakingPolicy.CurvePoint({ttm: (i + 1) * 100, sellRate: 1e18, buyRate: 2e18});
        }
        vm.prank(mm);
        policy.setCurve(mm, TGT, pts);
        policy.curves(mm, TGT, 7);
        vm.expectRevert();
        policy.curves(mm, TGT, 8);
    }

    function test_setCurve_overwritesExisting() public {
        IMarketMakingPolicy.CurvePoint[] memory pts1 = _twoPoint(100, 1e18, 3e18, 200, 1e18, 3e18);
        IMarketMakingPolicy.CurvePoint[] memory pts2 = _twoPoint(50, 4e18, 5e18, 150, 4e18, 5e18);
        vm.startPrank(mm);
        policy.setCurve(mm, TGT, pts1);
        policy.setCurve(mm, TGT, pts2);
        vm.stopPrank();

        vm.warp(1_000_000);
        // Second curve overrode first: buy side flat at 5e18.
        assertEq(policy.getRate(SRC, TGT, 0, mm, address(0), 0, 1_000_050, true), 5e18);
        assertEq(policy.getRate(SRC, TGT, 0, mm, address(0), 0, 1_000_150, true), 5e18);
    }

    function test_clearCurve_makesGetRateRevert() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 3e18, 200, 1e18, 3e18);
        vm.startPrank(mm);
        policy.setCurve(mm, TGT, pts);
        policy.clearCurve(mm, TGT);
        vm.stopPrank();

        vm.warp(1_000_000);
        vm.expectRevert(IMarketMakingPolicy.NoCurveForUserMarket.selector);
        policy.getRate(SRC, TGT, 0, mm, address(0), 0, 1_000_150, true);
    }

    /* Per-user isolation */

    function test_isolation_otherUserCannotOverwrite() public {
        IMarketMakingPolicy.CurvePoint[] memory pts1 = _twoPoint(100, 1e18, 3e18, 200, 1e18, 3e18);
        IMarketMakingPolicy.CurvePoint[] memory pts2 = _twoPoint(100, 5e18, 9e18, 200, 5e18, 9e18);

        vm.prank(mm);
        policy.setCurve(mm, TGT, pts1);
        vm.prank(otherMm);
        policy.setCurve(otherMm, TGT, pts2);

        vm.warp(1_000_000);
        assertEq(policy.getRate(SRC, TGT, 0, mm, address(0), 0, 1_000_100, true), 3e18);
        assertEq(policy.getRate(SRC, TGT, 0, otherMm, address(0), 0, 1_000_100, true), 9e18);
    }

    /* Side dispatch within a single curve */

    function test_dispatch_sellVsBuy_pickedByOfferIsBuy() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 3e18, 200, 1e18, 3e18);
        vm.startPrank(mm);
        policy.setCurve(mm, TGT, pts);
        policy.setCurve(mm, SRC, pts);
        vm.stopPrank();

        vm.warp(1_000_000);
        // userIsBuyer=false → Midnight→Vault exit (sourceMaturity > 0, targetMaturity == 0) → SRC curve, sell
        // side. The Midnight (priced) leg is the source.
        assertEq(policy.getRate(SRC, TGT, 0, mm, address(0), 1_000_150, 0, false), 1e18);
        // userIsBuyer=true → Vault→Midnight entry (sourceMaturity == 0, targetMaturity > 0) → TGT curve, buy
        // side. The Midnight (priced) leg is the target.
        assertEq(policy.getRate(SRC, TGT, 0, mm, address(0), 0, 1_000_150, true), 3e18);
    }

    /* Borrow (Blue<->Midnight) flows are unsupported — they must ALWAYS revert */

    // Borrow entry (BORROW_BLUE_TO_MIDNIGHT): user sells (userIsBuyer=false), source is the Blue leg
    // (maturity 0), target is Midnight (maturity > 0). The sell side selects the zero-maturity source.
    function test_borrowEntry_sell_reverts_noCurve() public {
        vm.warp(1_000_000);
        vm.expectRevert(IMarketMakingPolicy.UnsupportedMigrationRoute.selector);
        policy.getRate(SRC, TGT, 0, mm, address(0), 0, 1_000_150, false);
    }

    // Even if a curve is stored under the Blue leg id (setCurve does not validate the key), the borrow entry
    // must still revert — it must never silently price the wrong market at TTM 0.
    function test_borrowEntry_sell_reverts_evenWithBlueCurve() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 3e18, 200, 1e18, 3e18);
        vm.prank(mm);
        policy.setCurve(mm, SRC, pts); // SRC plays the Blue leg (the side the sell flow selects)
        vm.warp(1_000_000);
        vm.expectRevert(IMarketMakingPolicy.UnsupportedMigrationRoute.selector);
        policy.getRate(SRC, TGT, 0, mm, address(0), 0, 1_000_150, false);
    }

    // Borrow exit (BORROW_MIDNIGHT_TO_BLUE): user buys (userIsBuyer=true), source is Midnight (maturity > 0),
    // target is the Blue leg (maturity 0). The buy side selects the zero-maturity target.
    function test_borrowExit_buy_reverts_noCurve() public {
        vm.warp(1_000_000);
        vm.expectRevert(IMarketMakingPolicy.UnsupportedMigrationRoute.selector);
        policy.getRate(SRC, TGT, 0, mm, address(0), 1_000_150, 0, true);
    }

    function test_borrowExit_buy_reverts_evenWithBlueCurve() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 3e18, 200, 1e18, 3e18);
        vm.prank(mm);
        policy.setCurve(mm, TGT, pts); // TGT plays the Blue leg (the side the buy flow selects)
        vm.warp(1_000_000);
        vm.expectRevert(IMarketMakingPolicy.UnsupportedMigrationRoute.selector);
        policy.getRate(SRC, TGT, 0, mm, address(0), 1_000_150, 0, true);
    }

    /* Midnight→Midnight rolls are unsupported */

    function test_getRate_revertsOnMidnightToMidnight() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 3e18, 200, 1e18, 3e18);
        vm.startPrank(mm);
        policy.setCurve(mm, TGT, pts);
        policy.setCurve(mm, SRC, pts);
        vm.stopPrank();

        vm.warp(1_000_000);
        // Both maturities non-zero → Midnight→Midnight roll → revert regardless of userIsBuyer.
        vm.expectRevert(IMarketMakingPolicy.UnsupportedMigrationRoute.selector);
        policy.getRate(SRC, TGT, 0, mm, address(0), 1_000_100, 1_000_200, true);
        vm.expectRevert(IMarketMakingPolicy.UnsupportedMigrationRoute.selector);
        policy.getRate(SRC, TGT, 0, mm, address(0), 1_000_100, 1_000_200, false);
    }

    /* Past-maturity clamp (probed via sell side which uses sourceMaturity) */

    function test_pastMaturity_clampsToFirstPoint_noUnderflow() public {
        IMarketMakingPolicy.CurvePoint[] memory pts = _twoPoint(100, 1e18, 2e18, 200, 1e18, 2e18);
        vm.prank(mm);
        policy.setCurve(mm, SRC, pts);

        vm.warp(1_000_000);
        uint256 result = policy.getRate(SRC, TGT, 0, mm, address(0), 999_900, 0, false);
        assertEq(result, 1e18);
    }

    /* Helpers */

    function _twoPoint(uint32 ttm0, uint112 sell0, uint112 buy0, uint32 ttm1, uint112 sell1, uint112 buy1)
        internal
        pure
        returns (IMarketMakingPolicy.CurvePoint[] memory pts)
    {
        pts = new IMarketMakingPolicy.CurvePoint[](2);
        pts[0] = IMarketMakingPolicy.CurvePoint({ttm: ttm0, sellRate: sell0, buyRate: buy0});
        pts[1] = IMarketMakingPolicy.CurvePoint({ttm: ttm1, sellRate: sell1, buyRate: buy1});
    }
}
