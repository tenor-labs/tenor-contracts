// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {stdError} from "forge-std/StdError.sol";
import {MidnightRenewalAdapterTestBase, BorrowRoll, LendRoll} from "../helpers/MidnightRenewalAdapterTestBase.sol";
import {MidnightRenewalAdapterBase} from "../../src/bundler/MidnightRenewalAdapterBase.sol";
import {Market} from "@midnight/interfaces/IMidnight.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";

/// @title MidnightRenewalAdapterNegativeRateTest
/// @notice Signed forward-rate bounds. A borrower exiting through discounted offers can end with less target debt
///         than the source debt closed, and a lender reselling below the target's price with less new credit than
///         the credit closed. Both bounds must express those negative rates, disable cleanly, and refuse a rate
///         whose factor `1 + rate * Δ` is not positive.
contract MidnightRenewalAdapterNegativeRateTest is MidnightRenewalAdapterTestBase {
    uint256 internal DISCOUNT_TICK;

    function setUp() public override {
        super.setUp();
        DISCOUNT_TICK = TickLib.priceToTick(0.9e18, DEFAULT_TICK_SPACING);
    }

    /* ═══════ Borrow: negative ceiling ═══════ */

    function _assertNegativeCeilingIsTight(BorrowRoll memory r, uint256 repayUnits) internal {
        uint256 newDebt = _dryRunNewDebt(r);
        int256 rate = _tightestMaxRate(repayUnits, newDebt, DELTA);
        assertLt(rate, 0, "precondition: negative realised forward rate");

        r.maxForwardRate = rate - 1;
        _renewExpectRevert(
            r,
            abi.encodeWithSelector(
                MidnightRenewalAdapterBase.ForwardRateAboveMax.selector,
                newDebt,
                _maxNewDebt(repayUnits, rate - 1, DELTA)
            )
        );

        r.maxForwardRate = rate;
        _renew(r);
        assertLe(newDebt, _maxNewDebt(repayUnits, rate, DELTA));
        assertLt(newDebt, repayUnits, "less new debt than closed");
        _assertAdaptersEmpty(source, target);
    }

    function test_negativeCeiling_tight_allThroughOffers() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.exitActions = _one(_srcSellAction(BORROW_DEBT, DISCOUNT_TICK));
        _assertNegativeCeilingIsTight(r, BORROW_DEBT);
    }

    function test_negativeCeiling_tight_mixed() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.exitActions = _one(_srcSellAction(300e18, DISCOUNT_TICK));
        _assertNegativeCeilingIsTight(r, BORROW_DEBT);
    }

    function test_negativeCeiling_tight_partialMixed() public {
        BorrowRoll memory r = _borrowRoll(200e18, 0);
        r.exitActions = _one(_srcSellAction(150e18, DISCOUNT_TICK));
        _assertNegativeCeilingIsTight(r, 200e18);
    }

    /// @dev An all-par exit costs one per unit and the target lends below par, so its forward rate is never
    ///      negative: any negative ceiling rejects it.
    function test_revert_negativeCeiling_allAtPar() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.maxForwardRate = -1;
        uint256 newDebt = _dryRunNewDebt(r);
        assertGe(newDebt, BORROW_DEBT, "precondition: par roll is not negative");
        _renewExpectRevert(
            r,
            abi.encodeWithSelector(
                MidnightRenewalAdapterBase.ForwardRateAboveMax.selector, newDebt, _maxNewDebt(BORROW_DEBT, -1, DELTA)
            )
        );
    }

    /// @dev The case the unsigned ceiling could not protect: quoted at a negative rate, filled at a worse target
    ///      price. A zero ceiling still accepts the worse fill (459.80e18 quoted, 495.33e18 filled); the quoted
    ///      negative ceiling rejects it.
    function test_negativeCeiling_rejectsWorseFillThatZeroAccepts() public {
        BorrowRoll memory quote = _borrowRoll(type(uint256).max, 0);
        quote.exitActions = _one(_srcSellAction(BORROW_DEBT, DISCOUNT_TICK));
        int256 quotedRate = _tightestMaxRate(BORROW_DEBT, _dryRunNewDebt(quote), DELTA);
        assertLt(quotedRate, 0, "precondition");

        BorrowRoll memory worse = _borrowRoll(type(uint256).max, 0);
        worse.exitActions = _one(_srcSellAction(BORROW_DEBT, DISCOUNT_TICK));
        worse.borrowActions = _one(_tgtBuyAction(target, type(uint128).max, TickLib.priceToTick(0.91e18, 4)));
        worse.maxForwardRate = quotedRate;
        _renewExpectPartialRevert(worse, MidnightRenewalAdapterBase.ForwardRateAboveMax.selector);

        worse.maxForwardRate = 0;
        _renew(worse);
        assertLe(midnight.debt(targetId, borrower), BORROW_DEBT, "zero ceiling let it through");
    }

    /* ═══════ Lend: negative floor ═══════ */

    function _assertNegativeFloorIsTight(LendRoll memory r) internal {
        (uint256 newCredit, uint256 closed) = _dryRunLend(r);
        int256 rate = _tightestMinRate(closed, newCredit, DELTA);
        assertLt(rate, 0, "precondition: negative realised forward rate");

        r.minForwardRate = rate + 1;
        _renewLendExpectRevert(
            r,
            abi.encodeWithSelector(
                MidnightRenewalAdapterBase.ForwardRateBelowMin.selector,
                newCredit,
                _minNewCredit(closed, rate + 1, DELTA)
            )
        );

        r.minForwardRate = rate;
        _renewLend(r);
        assertGe(newCredit, _minNewCredit(closed, rate, DELTA));
        assertLt(newCredit, closed, "less new credit than closed");
        _assertAdaptersEmpty(source, target);
    }

    function test_negativeFloor_tight_resaleOnly() public {
        LendRoll memory r = _lendRoll(0, 0);
        r.exitActions = _one(_srcBuyAction(250e18, DISCOUNT_TICK));
        _assertNegativeFloorIsTight(r);
    }

    function test_negativeFloor_tight_mixed() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 0);
        r.exitActions = _one(_srcBuyAction(1_000e18, DISCOUNT_TICK));
        _assertNegativeFloorIsTight(r);
    }

    /// @dev Zero keeps its meaning: at least one unit of new credit per unit closed, so a negative roll reverts.
    function test_revert_zeroFloor_negativeRoll() public {
        LendRoll memory r = _lendRoll(0, 0);
        r.exitActions = _one(_srcBuyAction(250e18, DISCOUNT_TICK));
        r.minForwardRate = 0;
        _renewLendExpectRevert(
            r,
            abi.encodeWithSelector(
                MidnightRenewalAdapterBase.ForwardRateBelowMin.selector, _dryRunNewCredit(r), uint256(250e18)
            )
        );
    }

    function _dryRunNewCredit(LendRoll memory r) internal returns (uint256 newCredit) {
        (newCredit,) = _dryRunLend(r);
    }

    /* ═══════ Sentinels ═══════ */

    function test_borrowSentinel_int256Max_disables() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions = _one(_tgtBuyAction(target, type(uint128).max, TickLib.priceToTick(0.6e18, 4)));
        r.maxForwardRate = type(int256).max;
        _renew(r);
        assertGt(midnight.debt(targetId, borrower), 800e18, "awful roll accepted");
    }

    function test_lendSentinel_int256Min_disables() public {
        LendRoll memory r = _lendRoll(0, 0);
        r.exitActions = _one(_srcBuyAction(250e18, TickLib.priceToTick(0.5e18, DEFAULT_TICK_SPACING)));
        r.minForwardRate = type(int256).min;
        _renewLend(r);
        assertLt(_credit(target, lender), 150e18, "awful roll accepted");
        _assertAdaptersEmpty(source, target);
    }

    /* ═══════ Factor at or below zero ═══════ */

    /// @dev Target whose maturity gap divides WAD, so `1 + rate * Δ` can be exactly zero.
    function _targetWithGap(uint256 gap) internal view returns (Market memory) {
        return _market(source.maturity + gap, 2, 0.945e18);
    }

    function test_revert_borrow_factorZero() public {
        uint256 gap = 1e6;
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions = _one(_tgtBuyAction(_targetWithGap(gap), type(uint128).max, TARGET_TICK));
        r.maxForwardRate = -int256(WAD / gap);
        _renewExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.InvalidForwardRate.selector));
    }

    /// @dev One wei above: the smallest positive factor is an ordinary (unmeetable) ceiling.
    function test_revert_borrow_smallestPositiveFactor_isABound() public {
        uint256 gap = 1e6;
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions = _one(_tgtBuyAction(_targetWithGap(gap), type(uint128).max, TARGET_TICK));
        r.maxForwardRate = -int256(WAD / gap) + 1;
        _renewExpectPartialRevert(r, MidnightRenewalAdapterBase.ForwardRateAboveMax.selector);
    }

    function test_revert_borrow_factorNegative() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.maxForwardRate = -int256(WAD / DELTA) - 1;
        _renewExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.InvalidForwardRate.selector));
    }

    function test_revert_lend_factorZero() public {
        uint256 gap = 1e6;
        Market memory tgt = _targetWithGap(gap);
        col0.mint(tgtBorrower, 1_000e18);
        vm.prank(tgtBorrower);
        midnight.supplyCollateral(tgt, 0, 1_000e18, tgtBorrower);
        LendRoll memory r = _lendRoll(150e18, 0);
        r.lendActions = _one(_tgtSellAction(tgt, type(uint128).max, TARGET_TICK));
        r.minForwardRate = -int256(WAD / gap);
        _renewLendExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.InvalidForwardRate.selector));
    }

    function test_revert_lend_factorNegative() public {
        LendRoll memory r = _lendRoll(150e18, 0);
        r.minForwardRate = -int256(WAD / DELTA) - 1;
        _renewLendExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.InvalidForwardRate.selector));
    }

    /// @dev Just above the zero factor the floor is ordinary and nearly vacuous: the roll passes.
    function test_lend_smallestPositiveFactor_passes() public {
        LendRoll memory r = _lendRoll(150e18, 0);
        r.minForwardRate = -int256(WAD / DELTA);
        _renewLend(r);
        assertEq(LEND_CREDIT - _credit(source, lender), 150e18);
    }

    /* ═══════ Overflow ═══════ */

    function test_revert_borrow_rateTimesDeltaOverflows_negative() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.maxForwardRate = type(int256).min;
        _renewExpectRevert(r, stdError.arithmeticError);
    }

    function test_revert_lend_rateTimesDeltaOverflows_positive() public {
        LendRoll memory r = _lendRoll(150e18, 0);
        r.minForwardRate = type(int256).max;
        _renewLendExpectRevert(r, stdError.arithmeticError);
    }

    function test_revert_lend_rateTimesDeltaOverflows_negative() public {
        LendRoll memory r = _lendRoll(150e18, 0);
        r.minForwardRate = type(int256).min + 1;
        _renewLendExpectRevert(r, stdError.arithmeticError);
    }
}
