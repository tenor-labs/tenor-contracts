// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {MidnightWithdrawableTestBase} from "../helpers/MidnightWithdrawableTestBase.sol";
import {ITenorRouter} from "../../src/router/interfaces/ITenorRouter.sol";
import {Action} from "../../src/router/TenorRouter.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";

contract MidnightWithdrawableClampTest is MidnightWithdrawableTestBase {
    /* ========== MAX UNITS ========== */

    function test_maxUnitsReturnsWithdrawable() public {
        assertEq(clamp.maxUnits(_offer(market), ""), LENDER_CREDIT);

        _take(_offer(market), 100e18, borrower);

        assertEq(clamp.maxUnits(_offer(market), ""), LENDER_CREDIT - 100e18);
    }

    function test_maxUnitsSellOfferIsZero() public view {
        Offer memory offer = _offer(market);
        offer.buy = false;

        assertEq(clamp.maxUnits(offer, ""), 0);
    }

    function testFuzz_maxUnitsIsExecutable(uint256 drained) public {
        // Leaves withdrawable nonzero: a zero clamp is skipped by the router (test_routerSkipsEmptyWithdrawable).
        drained = bound(drained, 0, LENDER_CREDIT - 1);
        if (drained > 0) _take(_offer(market), drained, borrower);

        uint256 maxUnits = clamp.maxUnits(_offer(market), "");
        assertEq(maxUnits, LENDER_CREDIT - drained, "maxUnits");

        // The clamped amount always fills.
        _take(_offer(market), maxUnits, lender);
        assertEq(midnight.withdrawable(marketId), 0, "withdrawable");
        _assertCallbackHoldsNothing(marketId);
    }

    /* ========== ROUTER ========== */

    function test_routerClampsToWithdrawable() public {
        vm.prank(borrower);
        midnight.setIsAuthorized(address(router), true, borrower);

        Action[] memory actions = new Action[](1);
        actions[0] = _routerAction(2 * LENDER_CREDIT, borrower);

        vm.prank(borrower);
        (,, uint256 units) = router.execute(_routerParams(false), actions);

        assertEq(units, LENDER_CREDIT, "filled units");
        assertEq(midnight.debt(marketId, borrower), LENDER_CREDIT, "borrower debt");
        assertEq(midnight.withdrawable(marketId), 0, "withdrawable");
        _assertCallbackHoldsNothing(marketId);
    }

    function test_routerSkipsEmptyWithdrawable() public {
        // The clamp returns 0 and the router skips the take, which would otherwise revert with ZeroAmount.
        _take(_offer(market), LENDER_CREDIT, borrower);
        vm.prank(lender);
        midnight.setIsAuthorized(address(router), true, lender);

        Action[] memory actions = new Action[](1);
        actions[0] = _routerAction(LENDER_CREDIT, lender);

        vm.prank(lender);
        (,, uint256 units) = router.execute(_routerParams(true), actions);

        assertEq(units, 0, "filled units");
        assertEq(midnight.credit(marketId, lender), LENDER_CREDIT, "lender credit");
    }

    function test_routerReduceOnlyBlocksLenderCrossing() public {
        // Extra withdrawable so the clamp does not stop the lender at its credit.
        _setupLenderWithCredit(market, makeAddr("OtherLender"), LENDER_CREDIT);
        _supplyCollateral(market, lender, COLLATERAL);
        vm.prank(lender);
        midnight.setIsAuthorized(address(router), true, lender);

        Action[] memory actions = new Action[](1);
        actions[0] = _routerAction(LENDER_CREDIT + 1, lender);

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ITenorRouter.ReduceOnlyViolated.selector, 0, 1));
        router.execute(_routerParams(true), actions);

        // Without reduceOnly, the excess becomes debt.
        vm.prank(lender);
        router.execute(_routerParams(false), actions);
        assertEq(midnight.credit(marketId, lender), 0, "lender credit");
        assertEq(midnight.debt(marketId, lender), 1, "lender debt");
    }
}
