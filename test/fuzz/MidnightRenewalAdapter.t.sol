// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {MidnightRenewalAdapterTestBase, BorrowRoll, LendRoll} from "../helpers/MidnightRenewalAdapterTestBase.sol";
import {MidnightRenewalAdapterBase} from "../../src/bundler/MidnightRenewalAdapterBase.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {Call} from "@bundler3/interfaces/IBundler3.sol";
import {Market} from "@midnight/interfaces/IMidnight.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";

/// @title MidnightRenewalAdapterFuzzTest
/// @notice Over roll size, offer/par split, offer prices, inclusion time and the rate bound: a successful roll
///         always meets its forward-rate bound, moves collateral exactly pro-rata, closes exactly what it claims and
///         leaves nothing in the adapter; a failed one fails only on the bound (or on nothing to close).
contract MidnightRenewalAdapterFuzzTest is MidnightRenewalAdapterTestBase {
    using UtilsLib for uint256;

    function _tick(uint256 seed, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return TickLib.priceToTick(bound(seed, lo, hi), DEFAULT_TICK_SPACING);
    }

    /* ═══════ Borrow ═══════ */

    struct BorrowCase {
        uint256 repayUnits;
        uint256 exitCapacity;
        uint256 debtBefore;
        uint256 c0;
        uint256 c1;
        uint256 tgtDebtBefore;
        uint256 srcLenderCredit;
    }

    function testFuzz_borrowRoll(
        uint256 repaySeed,
        uint256 exitSeed,
        uint256 srcPriceSeed,
        uint256 tgtPriceSeed,
        uint256 warpSeed,
        uint256 rateSeed
    ) public {
        vm.warp(block.timestamp + bound(warpSeed, 0, SOURCE_TTM + 10 days));

        BorrowCase memory c;
        c.repayUnits = repaySeed % 8 == 0 ? BORROW_DEBT : bound(repaySeed, 1e15, BORROW_DEBT);
        c.exitCapacity = exitSeed % 4 == 0 ? 0 : bound(exitSeed, 1, BORROW_DEBT);
        c.debtBefore = midnight.debt(sourceId, borrower);
        c.c0 = _collateral(source, borrower, 0);
        c.c1 = _collateral(source, borrower, 1);
        c.srcLenderCredit = _credit(source, srcLender);

        BorrowRoll memory r = _borrowRoll(repaySeed % 8 == 0 ? type(uint256).max : c.repayUnits, 0);
        if (c.exitCapacity != 0) {
            r.exitActions = _one(_srcSellAction(c.exitCapacity, _tick(srcPriceSeed, 0.9e18, 0.9999e18)));
        }
        r.borrowActions = _one(_tgtBuyAction(target, type(uint128).max, _tick(tgtPriceSeed, 0.9e18, 0.999e18)));
        r.maxForwardRate = rateSeed % 5 == 0 ? type(int256).max : bound(int256(rateSeed), -3e10, 5e10);

        Call[] memory calls = _borrowBundle(r);
        vm.prank(borrower);
        try bundler3.multicall(calls) {
            _checkBorrowSuccess(r, c);
        } catch (bytes memory err) {
            _checkBorrowFailure(r, c, err);
        }
    }

    function _checkBorrowSuccess(BorrowRoll memory r, BorrowCase memory c) internal view {
        uint256 newDebt = midnight.debt(targetId, borrower) - c.tgtDebtBefore;
        if (r.maxForwardRate != type(int256).max) {
            assertLe(newDebt, _maxNewDebt(c.repayUnits, r.maxForwardRate, DELTA), "bound held");
        }
        assertEq(midnight.debt(sourceId, borrower), c.debtBefore - c.repayUnits, "closed exactly repayUnits");
        assertEq(
            c.srcLenderCredit - _credit(source, srcLender),
            UtilsLib.min(c.exitCapacity, c.repayUnits),
            "offers filled first, up to repayUnits"
        );

        uint256 moved0 = c.repayUnits == c.debtBefore ? c.c0 : c.c0.mulDivDown(c.repayUnits, c.debtBefore);
        uint256 moved1 = c.repayUnits == c.debtBefore ? c.c1 : c.c1.mulDivDown(c.repayUnits, c.debtBefore);
        assertEq(_collateral(target, borrower, 0), moved0, "col0 pro-rata");
        assertEq(_collateral(target, borrower, 1), moved1, "col1 pro-rata");
        assertEq(_collateral(source, borrower, 0), c.c0 - moved0, "col0 rest on source");
        assertEq(_collateral(source, borrower, 1), c.c1 - moved1, "col1 rest on source");

        assertTrue(midnight.isHealthy(source, sourceId, borrower), "source healthy");
        assertTrue(midnight.isHealthy(target, targetId, borrower), "target healthy");
        _assertAdaptersEmpty(source, target);
    }

    function _checkBorrowFailure(BorrowRoll memory r, BorrowCase memory c, bytes memory err) internal pure {
        assertEq(bytes4(err), MidnightRenewalAdapterBase.ForwardRateAboveMax.selector, "only the bound may fail");
        assertTrue(r.maxForwardRate != type(int256).max, "disabled bound never fails");
        (uint256 newDebt, uint256 maxNewDebt) = abi.decode(_args(err), (uint256, uint256));
        assertGt(newDebt, maxNewDebt, "failure is a real breach");
        assertEq(maxNewDebt, _maxNewDebt(c.repayUnits, r.maxForwardRate, DELTA), "bound on the whole roll");
    }

    /* ═══════ Lend ═══════ */

    struct LendCase {
        uint256 drained;
        uint256 withdrawable;
        uint256 credit;
        uint256 withdrawn;
        uint256 exitCapacity;
        uint256 srcBuyerCredit;
        uint256 tgtCreditBefore;
    }

    function testFuzz_lendRoll(
        uint256 withdrawSeed,
        uint256 drainSeed,
        uint256 exitSeed,
        uint256 srcPriceSeed,
        uint256 tgtPriceSeed,
        uint256 warpSeed,
        uint256 rateSeed
    ) public {
        vm.warp(block.timestamp + bound(warpSeed, 0, SOURCE_TTM + 10 days));

        LendCase memory c;
        // Another lender withdraws first: the pool the roll was quoted against shrinks.
        c.drained = bound(drainSeed, 0, INITIAL_WITHDRAWABLE);
        if (c.drained != 0) {
            vm.prank(otherLender);
            midnight.withdraw(source, c.drained, otherLender, otherLender);
        }
        c.withdrawable = midnight.withdrawable(sourceId);
        c.credit = _credit(source, lender);
        uint256 withdrawUnits = withdrawSeed % 6 == 0 ? type(uint256).max : bound(withdrawSeed, 0, 700e18);
        c.withdrawn = UtilsLib.min(withdrawUnits, UtilsLib.min(c.withdrawable, c.credit));
        c.exitCapacity = exitSeed % 4 == 0 ? 0 : bound(exitSeed, 1, 700e18);
        c.srcBuyerCredit = _credit(source, srcBuyer);

        LendRoll memory r = _lendRoll(withdrawUnits, 0);
        if (c.exitCapacity != 0) {
            r.exitActions = _one(_srcBuyAction(c.exitCapacity, _tick(srcPriceSeed, 0.9e18, 0.9999e18)));
        }
        r.lendActions = _one(_tgtSellAction(target, type(uint128).max, _tick(tgtPriceSeed, 0.9e18, 0.999e18)));
        r.minForwardRate = rateSeed % 5 == 0 ? type(int256).min : bound(int256(rateSeed), -3e10, 5e10);

        Call[] memory calls = _lendBundle(r);
        vm.prank(lender);
        try bundler3.multicall(calls) {
            _checkLendSuccess(r, c);
        } catch (bytes memory err) {
            _checkLendFailure(r, c, err);
        }
    }

    function _checkLendSuccess(LendRoll memory r, LendCase memory c) internal view {
        uint256 sold = _credit(source, srcBuyer) - c.srcBuyerCredit;
        uint256 closed = c.credit - _credit(source, lender);
        assertEq(closed, c.withdrawn + sold, "closed = par withdrawal + resale");
        assertEq(c.withdrawable - midnight.withdrawable(sourceId), c.withdrawn, "withdrawal capped onchain");
        assertLe(sold, UtilsLib.min(c.exitCapacity, c.credit - c.withdrawn), "resale within credit and capacity");
        uint256 newCredit = _credit(target, lender) - c.tgtCreditBefore;
        if (r.minForwardRate != type(int256).min) {
            assertGe(newCredit, _minNewCredit(closed, r.minForwardRate, DELTA), "floor held on the whole roll");
        }
        if (r.minForwardRate >= 0 && r.minForwardRate != type(int256).min) {
            assertGe(newCredit, closed, "non-negative floor: one unit per unit closed");
        }
        _assertAdaptersEmpty(source, target);
    }

    function _checkLendFailure(LendRoll memory r, LendCase memory c, bytes memory err) internal pure {
        if (bytes4(err) == CallbackLib.ZeroAmount.selector) {
            assertTrue(c.withdrawn == 0, "ZeroAmount only when nothing was withdrawn");
            return;
        }
        assertEq(bytes4(err), MidnightRenewalAdapterBase.ForwardRateBelowMin.selector, "only the floor may fail");
        assertTrue(r.minForwardRate != type(int256).min, "disabled floor never fails");
        (uint256 newCredit, uint256 minNewCredit) = abi.decode(_args(err), (uint256, uint256));
        assertLt(newCredit, minNewCredit, "failure is a real breach");
        assertGe(minNewCredit, c.withdrawn, "floor counts the par withdrawal");
        assertGe(minNewCredit, _minNewCredit(c.withdrawn, r.minForwardRate, DELTA), "floor on at least the par part");
    }

    function _args(bytes memory err) internal pure returns (bytes memory args) {
        args = new bytes(err.length - 4);
        for (uint256 i; i < args.length; i++) {
            args[i] = err[i + 4];
        }
    }

    /* ═══════ Collateral rounding, isolated ═══════ */

    /// @dev Pro-rata transfer over arbitrary collateral sizes: never over-moves, short by less than one wei.
    function testFuzz_collateralProRata(uint256 c0Seed, uint256 c1Seed, uint256 repaySeed) public {
        uint256 c0 = bound(c0Seed, 1, 1e24);
        uint256 c1 = bound(c1Seed, 1, 1e24);
        // Large enough collateral that the roll is healthy regardless of the split.
        Market_ memory m;
        m.src = _market(source.maturity + 2 days, 2, 0.945e18);
        m.tgt = _market(target.maturity, 2, 0.945e18);
        uint256 debt = 300e18;
        _openBorrowerPosition(m.src, debt, 1_000e18 + c0, 1_000e18 + c1);

        uint256 repayUnits = bound(repaySeed, 1e15, debt);
        BorrowRoll memory r = _borrowRoll(repayUnits, 0);
        r.source = m.src;
        r.borrowActions = _one(_tgtBuyAction(m.tgt, type(uint128).max, TARGET_TICK));
        _renew(r);

        uint256[2] memory before = [1_000e18 + c0, 1_000e18 + c1];
        for (uint256 i; i < 2; i++) {
            uint256 moved = _collateral(m.tgt, borrower, i);
            assertEq(moved + _collateral(m.src, borrower, i), before[i], "conserved");
            if (repayUnits == debt) {
                assertEq(moved, before[i], "full roll moves all");
            } else {
                assertLe(moved * debt, before[i] * repayUnits, "never over-moved");
                assertGt((moved + 1) * debt, before[i] * repayUnits, "floor");
            }
        }
        _assertAdaptersEmpty(m.src, m.tgt);
    }

    struct Market_ {
        Market src;
        Market tgt;
    }
}
