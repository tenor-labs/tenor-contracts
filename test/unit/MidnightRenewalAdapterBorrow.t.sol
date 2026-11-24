// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {stdError} from "forge-std/StdError.sol";
import {MidnightRenewalAdapterTestBase, BorrowRoll} from "../helpers/MidnightRenewalAdapterTestBase.sol";
import {MidnightRenewalAdapterBase} from "../../src/bundler/MidnightRenewalAdapterBase.sol";
import {FillAxis, Action} from "../../src/router/TenorRouter.sol";
import {ITenorRouter} from "../../src/router/interfaces/ITenorRouter.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {TakeMathLib} from "../../src/libraries/TakeMathLib.sol";
import {CallbackFeeAdjuster} from "../../src/router/CallbackFeeAdjuster.sol";
import {IMidnight, Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";

/// @title MidnightRenewalAdapterBorrowTest
/// @notice `midnightRenew`: full and partial rolls through offers, at par and mixed; the repay-units sentinel;
///         pro-rata collateral; the forward-rate bound with the par fallback inside it; validation and health.
contract MidnightRenewalAdapterBorrowTest is MidnightRenewalAdapterTestBase {
    using UtilsLib for uint256;

    uint256 internal PS;
    uint256 internal PT;

    function setUp() public override {
        super.setUp();
        PS = TickLib.tickToPrice(SOURCE_TICK);
        PT = TickLib.tickToPrice(TARGET_TICK);
    }

    /* ═══════ Expected amounts ═══════ */

    /// @dev Loan tokens the exit costs: `viaOffers` units at the SELL offer's buyer price (rounded up), the rest at
    /// par.
    function _expectedSpent(uint256 repayUnits, uint256 viaOffers) internal view returns (uint256) {
        return viaOffers.mulDivUp(PS, WAD) + (repayUnits - viaOffers);
    }

    /// @dev Units the borrow leg sells for exactly `spent` seller assets.
    function _expectedNewDebt(uint256 spent) internal view returns (uint256) {
        return TakeMathLib.mulDivDownInverse(spent, WAD, PT);
    }

    struct Snapshot {
        uint256 debt;
        uint256 c0;
        uint256 c1;
        uint256 srcLenderCredit;
        uint256 withdrawable;
        uint256 tgtLenderBalance;
        uint256 tgtDebt;
        uint256 tgtC0;
        uint256 tgtC1;
    }

    function _snap(Market memory src, Market memory tgt) internal view returns (Snapshot memory s) {
        s.debt = midnight.debt(IdLib.toId(src), borrower);
        s.c0 = _collateral(src, borrower, 0);
        s.c1 = src.collateralParams.length > 1 ? _collateral(src, borrower, 1) : 0;
        s.srcLenderCredit = _credit(src, srcLender);
        s.withdrawable = midnight.withdrawable(IdLib.toId(src));
        s.tgtLenderBalance = loanToken.balanceOf(tgtLender);
        s.tgtDebt = midnight.debt(IdLib.toId(tgt), borrower);
        s.tgtC0 = _collateral(tgt, borrower, 0);
        s.tgtC1 = tgt.collateralParams.length > 1 ? _collateral(tgt, borrower, 1) : 0;
    }

    /// @dev Checks every balance a roll of `repayUnits` (`viaOffers` of it through offers) moves, on both markets.
    function _assertRolled(
        Market memory src,
        Market memory tgt,
        Snapshot memory b,
        uint256 repayUnits,
        uint256 viaOffers
    ) internal view {
        Snapshot memory a = _snap(src, tgt);
        uint256 spent = _expectedSpent(repayUnits, viaOffers);

        assertEq(a.debt, b.debt - repayUnits, "source debt closed by repayUnits");
        assertEq(b.srcLenderCredit - a.srcLenderCredit, viaOffers, "units bought through offers");
        assertEq(a.withdrawable - b.withdrawable, repayUnits - viaOffers, "rest repaid at par");
        assertEq(b.tgtLenderBalance - a.tgtLenderBalance, spent, "borrow leg raised exactly the exit cost");
        assertEq(a.tgtDebt - b.tgtDebt, _expectedNewDebt(spent), "new target debt");

        uint256 moved0 = repayUnits == b.debt ? b.c0 : b.c0.mulDivDown(repayUnits, b.debt);
        assertEq(a.c0, b.c0 - moved0, "col0 left on source");
        assertEq(a.tgtC0 - b.tgtC0, moved0, "col0 moved to target");
        if (src.collateralParams.length > 1 && tgt.collateralParams.length > 1) {
            uint256 moved1 = repayUnits == b.debt ? b.c1 : b.c1.mulDivDown(repayUnits, b.debt);
            assertEq(a.c1, b.c1 - moved1, "col1 left on source");
            assertEq(a.tgtC1 - b.tgtC1, moved1, "col1 moved to target");
        }

        assertTrue(midnight.isHealthy(src, IdLib.toId(src), borrower), "source healthy");
        assertTrue(midnight.isHealthy(tgt, IdLib.toId(tgt), borrower), "target healthy");
        _assertAdaptersEmpty(src, tgt);
    }

    /* ═══════ Full roll ═══════ */

    function test_fullRoll_allThroughOffers() public {
        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(type(uint256).max, BORROW_DEBT));
        _assertRolled(source, target, b, BORROW_DEBT, BORROW_DEBT);
        assertEq(_collateral(source, borrower, 0) + _collateral(source, borrower, 1), 0, "no collateral left");
    }

    function test_fullRoll_allAtPar() public {
        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(type(uint256).max, 0));
        _assertRolled(source, target, b, BORROW_DEBT, 0);
    }

    function test_fullRoll_mixed() public {
        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(type(uint256).max, 200e18));
        _assertRolled(source, target, b, BORROW_DEBT, 200e18);
    }

    /// @dev Offers available above the roll size: the exit leg stops at `repayUnits`.
    function test_fullRoll_offersAboveDebt_capAtRepayUnits() public {
        Snapshot memory b = _snap(source, target);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, BORROW_DEBT);
        r.exitActions = _two(_srcSellAction(BORROW_DEBT / 2), _srcSellAction(BORROW_DEBT));
        _renew(r);
        _assertRolled(source, target, b, BORROW_DEBT, BORROW_DEBT);
    }

    /* ═══════ Partial roll ═══════ */

    function test_partialRoll_allThroughOffers() public {
        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(200e18, BORROW_DEBT));
        _assertRolled(source, target, b, 200e18, 200e18);
    }

    function test_partialRoll_allAtPar() public {
        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(200e18, 0));
        _assertRolled(source, target, b, 200e18, 0);
    }

    function test_partialRoll_mixed() public {
        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(200e18, 80e18));
        _assertRolled(source, target, b, 200e18, 80e18);
    }

    /// @dev Two partial rolls into the same target add up; the second reads live source state.
    function test_partialRoll_twice_thenRest() public {
        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(100e18, 50e18));
        _renew(_borrowRoll(150e18, 0));
        _renew(_borrowRoll(type(uint256).max, 0));
        Snapshot memory a = _snap(source, target);
        assertEq(a.debt, 0, "all debt rolled");
        assertEq(a.c0 + a.c1, 0, "all collateral moved");
        assertEq(a.tgtC0, b.c0, "col0 conserved");
        assertEq(a.tgtC1, b.c1, "col1 conserved");
        _assertAdaptersEmpty(source, target);
    }

    /* ═══════ repayUnits ═══════ */

    function test_repayUnits_maxSentinel_rollsAllDebt() public {
        _renew(_borrowRoll(type(uint256).max, 0));
        assertEq(midnight.debt(sourceId, borrower), 0);
    }

    function test_repayUnits_exactDebt_equivalentToSentinel() public {
        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(BORROW_DEBT, 100e18));
        _assertRolled(source, target, b, BORROW_DEBT, 100e18);
    }

    function test_revert_repayUnits_zero() public {
        _renewExpectRevert(
            _borrowRoll(0, 0), abi.encodeWithSelector(MidnightRenewalAdapterBase.InvalidRepayUnits.selector)
        );
    }

    function test_revert_repayUnits_aboveDebt() public {
        _renewExpectRevert(
            _borrowRoll(BORROW_DEBT + 1, 0),
            abi.encodeWithSelector(MidnightRenewalAdapterBase.InvalidRepayUnits.selector)
        );
    }

    /// @dev No debt on the source: the sentinel resolves to zero.
    function test_revert_repayUnits_maxSentinel_noDebt() public {
        _renew(_borrowRoll(type(uint256).max, 0));
        _renewExpectRevert(
            _borrowRoll(type(uint256).max, 0),
            abi.encodeWithSelector(MidnightRenewalAdapterBase.InvalidRepayUnits.selector)
        );
    }

    /* ═══════ Collateral ═══════ */

    /// @dev Odd sizes so the pro-rata transfer rounds: it rounds down, leaving the remainder on the source.
    function test_collateral_partialRoll_roundsDownTowardSource() public {
        uint256 repayUnits = 333e18 + 7;
        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(repayUnits, 0));
        _assertRolled(source, target, b, repayUnits, 0);

        uint256 moved0 = _collateral(target, borrower, 0);
        uint256 moved1 = _collateral(target, borrower, 1);
        assertLe(moved0 * BORROW_DEBT, BORROWER_COL0 * repayUnits, "col0 never over-moved");
        assertLe(moved1 * BORROW_DEBT, BORROWER_COL1 * repayUnits, "col1 never over-moved");
        assertGt((moved0 + 1) * BORROW_DEBT, BORROWER_COL0 * repayUnits, "col0 short by less than a wei");
        assertGt((moved1 + 1) * BORROW_DEBT, BORROWER_COL1 * repayUnits, "col1 short by less than a wei");
        assertTrue(moved1 * BORROW_DEBT != BORROWER_COL1 * repayUnits, "precondition: col1 transfer rounded");
    }

    /// @dev A tiny roll moves the pro-rata floor of each collateral.
    function test_collateral_tinyRoll() public {
        uint256 repayUnits = 1e6 + 3;
        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(repayUnits, 0));
        _assertRolled(source, target, b, repayUnits, 0);
        assertEq(_collateral(target, borrower, 0), BORROWER_COL0.mulDivDown(repayUnits, BORROW_DEBT));
        assertEq(_collateral(target, borrower, 1), BORROWER_COL1.mulDivDown(repayUnits, BORROW_DEBT));
    }

    /// @dev A one-wei roll moves at most a wei of collateral, too little to back even the one wei of new debt:
    ///      the target take refuses it rather than leaving an unbacked position.
    function test_revert_collateral_oneWeiRoll_targetUnhealthy() public {
        _renewExpectRevert(
            _borrowRoll(1, 0),
            abi.encodeWithSelector(
                ITenorRouter.ActionFailed.selector, 0, abi.encodeWithSelector(IMidnight.SellerIsLiquidatable.selector)
            )
        );
    }

    /// @dev Pro-rata reads the live collateral, not a quote: collateral added before the roll moves with it.
    function test_collateral_readsLiveState() public {
        col1.mint(borrower, 99e18);
        vm.prank(borrower);
        midnight.supplyCollateral(source, 1, 99e18, borrower);

        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(250e18, 0));
        _assertRolled(source, target, b, 250e18, 0);
        assertEq(_collateral(target, borrower, 1), (BORROWER_COL1 + 99e18) / 2);
    }

    /// @dev Partial roll keeps the source LTV (rounding only lowers it); the target LTV scales by newDebt/repayUnits.
    function test_collateral_ltvBeforeAfter() public {
        uint256 ltvBefore = _ltv(source, borrower);
        uint256 repayUnits = 200e18;
        _renew(_borrowRoll(repayUnits, 0));

        assertLe(_ltv(source, borrower), ltvBefore, "source LTV not worse");
        assertApproxEqAbs(_ltv(source, borrower), ltvBefore, 1, "source LTV unchanged");
        uint256 newDebt = midnight.debt(targetId, borrower);
        assertApproxEqRel(_ltv(target, borrower), ltvBefore.mulDivDown(newDebt, repayUnits), 1e9, "target LTV");
        assertGt(_ltv(target, borrower), ltvBefore, "target LTV carries the roll's interest");
    }

    /// @dev Single-collateral source and target.
    function test_collateral_singleCollateralMarkets() public {
        Market memory src = _market(source.maturity, 1, 0.945e18);
        Market memory tgt = _market(target.maturity, 1, 0.945e18);
        _openBorrowerPosition(src, 300e18, 450e18, 0);

        BorrowRoll memory r = _borrowRoll(120e18, 0);
        r.source = src;
        r.exitActions = _one(_action(_offer(src, false, srcLender, SOURCE_TICK, 50e18), srcLenderSK));
        r.borrowActions = _one(_tgtBuyAction(tgt, type(uint128).max, TARGET_TICK));

        Snapshot memory b = _snap(src, tgt);
        _renew(r);
        _assertRolled(src, tgt, b, 120e18, 50e18);
        assertEq(_collateral(tgt, borrower, 0), 450e18 * 120 / 300);
    }

    /// @dev Target lists the collaterals in a different index order is impossible (sorted), but a target that lists
    ///      only one of them maps it to its own index. Source col1 is not accepted by the target and stays behind,
    ///      in full, even on a full roll.
    function test_collateral_tokenNotAcceptedByTarget_staysOnSource() public {
        Market memory tgt = _market(target.maturity, 1, 0.945e18);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 100e18);
        r.borrowActions = _one(_tgtBuyAction(tgt, type(uint128).max, TARGET_TICK));

        _renew(r);

        assertEq(midnight.debt(sourceId, borrower), 0, "debt rolled");
        assertEq(_collateral(source, borrower, 0), 0, "accepted collateral moved in full");
        assertEq(_collateral(source, borrower, 1), BORROWER_COL1, "unaccepted collateral left on source");
        assertEq(_collateral(tgt, borrower, 0), BORROWER_COL0, "target got col0");
        assertTrue(midnight.isHealthy(tgt, IdLib.toId(tgt), borrower));
        _assertAdaptersEmpty(source, tgt);

        // With no debt left, the borrower can take the stranded collateral back.
        vm.prank(borrower);
        midnight.withdrawCollateral(source, 1, BORROWER_COL1, borrower, borrower);
    }

    /// @dev Same as above, but the accepted collateral alone does not cover the new debt: the target take fails.
    function test_revert_collateral_tokenNotAcceptedByTarget_targetUnhealthy() public {
        Market memory tgt = _market(target.maturity, 1, 0.945e18);
        oracle0.setPrice(0.8e36);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions = _one(_tgtBuyAction(tgt, type(uint128).max, TARGET_TICK));
        _renewExpectRevert(
            r,
            abi.encodeWithSelector(
                ITenorRouter.ActionFailed.selector, 0, abi.encodeWithSelector(IMidnight.SellerIsLiquidatable.selector)
            )
        );
    }

    /// @dev Pre-existing target collateral and debt are kept; the roll adds to them.
    function test_collateral_targetAlreadyHasPosition() public {
        _openBorrowerPosition(target, 50e18, 100e18, 0);
        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(200e18, 0));
        _assertRolled(source, target, b, 200e18, 0);
    }

    /* ═══════ Forward rate ═══════ */

    function _assertBoundIsTight(BorrowRoll memory r, uint256 repayUnits) internal {
        uint256 newDebt = _dryRunNewDebt(r);
        int256 rate = _tightestMaxRate(repayUnits, newDebt, DELTA);
        assertGt(rate, 0, "precondition: roll pays interest");

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
        assertEq(midnight.debt(targetId, borrower), newDebt);
    }

    function test_forwardRate_tight_allThroughOffers() public {
        _assertBoundIsTight(_borrowRoll(type(uint256).max, BORROW_DEBT), BORROW_DEBT);
    }

    function test_forwardRate_tight_allAtPar() public {
        _assertBoundIsTight(_borrowRoll(type(uint256).max, 0), BORROW_DEBT);
    }

    function test_forwardRate_tight_mixed() public {
        _assertBoundIsTight(_borrowRoll(type(uint256).max, 200e18), BORROW_DEBT);
    }

    function test_forwardRate_tight_partialMixed() public {
        _assertBoundIsTight(_borrowRoll(300e18, 120e18), 300e18);
    }

    /// @dev The bound is on repayUnits, the whole exit: a rate that only fits the cheap offer-priced part of the
    ///      roll rejects the same roll once the par fallback carries the rest.
    function test_forwardRate_includesParFallback() public {
        int256 offersOnlyRate =
            _tightestMaxRate(BORROW_DEBT, _dryRunNewDebt(_borrowRoll(type(uint256).max, BORROW_DEBT)), DELTA);

        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.maxForwardRate = offersOnlyRate;
        uint256 parDebt = _dryRunNewDebt(r);
        assertGt(parDebt, _maxNewDebt(BORROW_DEBT, offersOnlyRate, DELTA), "precondition: par is dearer");
        _renewExpectRevert(
            r,
            abi.encodeWithSelector(
                MidnightRenewalAdapterBase.ForwardRateAboveMax.selector,
                parDebt,
                _maxNewDebt(BORROW_DEBT, offersOnlyRate, DELTA)
            )
        );
    }

    /// @dev The interval is maturity to maturity, so the bound does not drift with the inclusion time.
    function test_forwardRate_independentOfInclusionTime() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        int256 rate = _tightestMaxRate(BORROW_DEBT, _dryRunNewDebt(r), DELTA);
        vm.warp(block.timestamp + 3 days);
        r = _borrowRoll(type(uint256).max, 0);
        r.maxForwardRate = rate;
        _renew(r);
    }

    function test_forwardRate_maxSentinelDisablesBound() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions = _one(_tgtBuyAction(target, type(uint128).max, TickLib.priceToTick(0.6e18, 4)));
        r.maxForwardRate = type(int256).max;
        _renew(r);
        assertGt(midnight.debt(targetId, borrower), 800e18, "awful price accepted");
    }

    function test_revert_forwardRate_zero_requiresNoInterest() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.maxForwardRate = 0;
        uint256 newDebt = _dryRunNewDebt(r);
        _renewExpectRevert(
            r, abi.encodeWithSelector(MidnightRenewalAdapterBase.ForwardRateAboveMax.selector, newDebt, BORROW_DEBT)
        );
    }

    /// @dev A finite rate whose product with the maturity gap overflows reverts rather than wrapping into a
    ///      tighter or looser bound.
    function test_revert_forwardRate_overflow() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.maxForwardRate = type(int256).max - 1;
        _renewExpectRevert(r, stdError.arithmeticError);
    }

    /* ═══════ Bound bypass attempts ═══════ */

    /// @dev Exit batch on the source's buy side (the borrower would sell, growing source debt): the closed-debt
    ///      delta underflows.
    function test_revert_exitOnSourceBuySide_underflows() public {
        BorrowRoll memory r = _borrowRoll(100e18, 0);
        r.exitActions = _one(_action(_offer(source, true, srcBuyer, SOURCE_TICK, 100e18), srcBuyerSK));
        _renewExpectRevert(r, stdError.arithmeticError);
    }

    /// @dev Borrow leg on the target's sell side (the borrower would buy credit): the adapter pays and ends short.
    function test_revert_borrowLegWrongSide_loanBalanceDecreased() public {
        // Leftover funds in the adapter so the wrong-side leg can be paid and reach the balance check.
        loanToken.mint(address(adapter), 1_000e18);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions = _one(_tgtSellAction(target, type(uint128).max, TARGET_TICK));
        _renewExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.LoanBalanceDecreased.selector));
    }

    /// @dev Borrow-leg proceeds sent anywhere but the adapter: the adapter ends short.
    function test_revert_borrowLegProceedsElsewhere_loanBalanceDecreased() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions =
            _one(_action(_offer(target, true, tgtLender, TARGET_TICK, type(uint128).max), tgtLenderSK, attacker));
        _renewExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.LoanBalanceDecreased.selector));
    }

    /// @dev BUG (fixed in the worktree): an exit batch on a market other than the source passed every check. The
    ///      borrower could be made to sell into BUY offers on another market, taking on debt there that the
    ///      forward-rate bound never sees: closed is zero, the whole roll is repaid at par, and the other market's
    ///      proceeds shrink the target borrow, so the bound passes while total new debt exceeds it.
    function test_revert_exitOnOtherMarket_sellingCreatesHiddenDebt() public {
        Market memory other = _market(source.maturity + 1 days, 2, 0.945e18);
        col0.mint(borrower, 1_000e18);
        vm.prank(borrower);
        midnight.supplyCollateral(other, 0, 1_000e18, borrower);

        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.maxForwardRate = _tightestMaxRate(BORROW_DEBT, _dryRunNewDebt(r), DELTA);
        // The attacker buys the borrower's new other-market debt at 0.6 and keeps the proceeds.
        Offer memory o = _offer(other, true, attacker, TickLib.priceToTick(0.6e18, DEFAULT_TICK_SPACING), BORROW_DEBT);
        r.exitActions = _one(_action(o, attackerSK, attacker));

        _renewExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.WrongMarket.selector));
    }

    /// @dev Same bypass in the other direction: buying credit on another market, funded by the target borrow.
    function test_revert_exitOnOtherMarket_buyingCredit() public {
        Market memory other = _market(source.maturity + 1 days, 2, 0.945e18);
        col0.mint(attacker, 10_000e18);
        vm.prank(attacker);
        midnight.supplyCollateral(other, 0, 10_000e18, attacker);

        // Enough in the adapter to pay for both the other-market credit and the par repay.
        loanToken.mint(address(adapter), 1_000e18);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.exitActions = _one(_action(_offer(other, false, attacker, SOURCE_TICK, 100e18), attackerSK));
        _renewExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.WrongMarket.selector));
    }

    /* ═══════ Validation ═══════ */

    function test_revert_tokenMismatch() public {
        Market memory tgt = _market(target.maturity, 2, 0.945e18);
        tgt.loanToken = address(otherLoanToken);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions = _one(_action(_offer(tgt, true, tgtLender, TARGET_TICK, 1e18), tgtLenderSK));
        _renewExpectRevert(r, abi.encodeWithSelector(CallbackLib.TokenMismatch.selector));
    }

    function test_revert_invalidMaturities_sameMaturity() public {
        Market memory tgt = _market(source.maturity, 1, 0.945e18);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions = _one(_tgtBuyAction(tgt, type(uint128).max, TARGET_TICK));
        _renewExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.InvalidMaturities.selector));
    }

    function test_revert_invalidMaturities_targetBeforeSource() public {
        Market memory tgt = _market(source.maturity - 1, 2, 0.945e18);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions = _one(_tgtBuyAction(tgt, type(uint128).max, TARGET_TICK));
        _renewExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.InvalidMaturities.selector));
    }

    function test_revert_exitFillAxisAssets() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 100e18);
        r.exitParams.fillAxis = FillAxis.ASSETS;
        _renewExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.WrongFillAxis.selector));
    }

    /// @dev With no exit batch the exit params are not read at all.
    function test_exitParamsIgnoredWithoutExitBatch() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.exitParams.fillAxis = FillAxis.ASSETS;
        r.exitParams.deadline = 1;
        _renew(r);
        assertEq(midnight.debt(sourceId, borrower), 0);
    }

    function test_revert_borrowFillAxisUnits() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowParams.fillAxis = FillAxis.UNITS;
        _renewExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.WrongFillAxis.selector));
    }

    /// @dev borrowParams.maxFill / minFill are overridden by the exit cost.
    function test_borrowFillBoundsIgnored() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowParams.maxFill = 1;
        r.borrowParams.minFill = type(uint128).max;
        Snapshot memory b = _snap(source, target);
        _renew(r);
        _assertRolled(source, target, b, BORROW_DEBT, 0);
    }

    function test_revert_borrowActionsEmpty() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions = new Action[](0);
        _renewExpectRevert(r, abi.encodeWithSelector(ITenorRouter.EmptyActions.selector));
    }

    /// @dev The legs' own price bounds still apply on top of the forward rate.
    function test_revert_exitPriceAboveMax() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, BORROW_DEBT);
        r.exitParams.maxPrice = PS - 1;
        _renewExpectRevert(
            r, abi.encodeWithSelector(ITenorRouter.PriceSlippageExceeded.selector, PS, uint256(0), PS - 1)
        );
    }

    function test_revert_borrowPriceBelowMin() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowParams.minPrice = PT + 1;
        _renewExpectPartialRevert(r, ITenorRouter.PriceSlippageExceeded.selector);
    }

    function test_revert_exitDeadlineExpired() public {
        vm.warp(block.timestamp + 1 hours);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 100e18);
        r.exitParams.deadline = block.timestamp - 1;
        _renewExpectRevert(
            r, abi.encodeWithSelector(ITenorRouter.DeadlineExpired.selector, block.timestamp - 1, block.timestamp)
        );
    }

    /* ═══════ Health ═══════ */

    /// @dev Target accepts the same collateral at a lower LLTV: the rolled debt is not covered there.
    function test_revert_targetUnhealthy() public {
        Market memory tgt = _market(target.maturity, 2, 0.385e18);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions = _one(_tgtBuyAction(tgt, type(uint128).max, TARGET_TICK));
        _renewExpectRevert(
            r,
            abi.encodeWithSelector(
                ITenorRouter.ActionFailed.selector, 0, abi.encodeWithSelector(IMidnight.SellerIsLiquidatable.selector)
            )
        );
    }

    /// @dev Source already unhealthy: moving collateral out of it on a partial roll is refused.
    function test_revert_sourceUnhealthy_partialRoll() public {
        oracle0.setPrice(0.3e36);
        oracle1.setPrice(0.3e36);
        assertFalse(midnight.isHealthy(source, sourceId, borrower), "precondition");
        _renewExpectRevert(_borrowRoll(100e18, 0), abi.encodeWithSelector(IMidnight.UnhealthyBorrower.selector));
    }

    /// @dev A partial roll keeps the source LTV, so a healthy source stays healthy right up to the LLTV.
    function test_partialRoll_sourceAtLltvStaysHealthy() public {
        // Debt 500 against 1001 collateral at 0.945 LLTV: price 0.5286 puts maxDebt just above the debt.
        uint256 price = uint256(0.5286e36);
        oracle0.setPrice(price);
        oracle1.setPrice(price);
        assertTrue(midnight.isHealthy(source, sourceId, borrower), "precondition healthy");
        // The target takes the same collateral at a higher LLTV, so the rolled interest still fits there.
        Market memory tgt = _market(target.maturity, 2, 0.98e18);
        BorrowRoll memory r = _borrowRoll(200e18, 0);
        r.borrowActions = _one(_tgtBuyAction(tgt, type(uint128).max, TickLib.priceToTick(0.999e18, 4)));
        _renew(r);
        assertTrue(midnight.isHealthy(source, sourceId, borrower), "source still healthy");
        assertTrue(midnight.isHealthy(tgt, IdLib.toId(tgt), borrower), "target healthy");
    }

    /* ═══════ Third-party griefing ═══════ */

    /// @dev The exit offers are taken by someone else first: the par fallback covers the roll, and the bound
    ///      sized on the offer quote rejects the dearer result instead of filling worse than quoted.
    function test_griefing_exitOffersConsumed_boundRejects() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, BORROW_DEBT);
        r.maxForwardRate = _tightestMaxRate(BORROW_DEBT, _dryRunNewDebt(r), DELTA);

        _consumeSrcSellOffer(r.exitActions[0]);

        _renewExpectPartialRevert(r, MidnightRenewalAdapterBase.ForwardRateAboveMax.selector);
    }

    /// @dev Same, with slack in the bound: the roll completes, all at par, and stays within the bound.
    function test_griefing_exitOffersConsumed_parFallbackWithinBound() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, BORROW_DEBT);
        r.maxForwardRate = _tightestMaxRate(BORROW_DEBT, _dryRunNewDebt(_borrowRoll(type(uint256).max, 0)), DELTA);

        _consumeSrcSellOffer(r.exitActions[0]);
        Snapshot memory b = _snap(source, target);
        _renew(r);
        _assertRolled(source, target, b, BORROW_DEBT, 0);
        assertLe(midnight.debt(targetId, borrower), _maxNewDebt(BORROW_DEBT, r.maxForwardRate, DELTA));
    }

    /// @dev Target liquidity taken first: the borrow leg cannot raise the exit cost and the roll reverts.
    function test_revert_griefing_targetLiquidityConsumed() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        Offer memory o = _offer(target, true, tgtLender, TARGET_TICK, 600e18);
        r.borrowActions = _one(_action(o, tgtLenderSK));

        vm.prank(tgtBorrower);
        midnight.take(o, _ratifierData(o, tgtLenderSK), 300e18, tgtBorrower, tgtBorrower, address(0), "");

        _renewExpectPartialRevert(r, ITenorRouter.InsufficientFill.selector);
    }

    /// @dev The borrower's debt shrinks between quote and execution (here a direct repay): an explicit repayUnits
    ///      above the live debt reverts, the sentinel adapts.
    function test_debtShrinksBeforeExecution() public {
        vm.prank(borrower);
        midnight.repay(source, 100e18, borrower, address(0), "");

        _renewExpectRevert(
            _borrowRoll(BORROW_DEBT, 0), abi.encodeWithSelector(MidnightRenewalAdapterBase.InvalidRepayUnits.selector)
        );
        Snapshot memory b = _snap(source, target);
        _renew(_borrowRoll(type(uint256).max, 0));
        _assertRolled(source, target, b, BORROW_DEBT - 100e18, 0);
    }

    function _consumeSrcSellOffer(Action memory a) internal {
        // A third party buys the offer out first.
        vm.prank(otherLender);
        midnight.take(a.offer, a.take.ratifierData, a.offer.maxUnits, otherLender, address(0), address(0), "");
    }

    /* ═══════ Settlement fees ═══════ */

    function _setSettlementFees() internal {
        midnight.setFeeSetter(address(this));
        for (uint256 i; i < 7; i++) {
            midnight.setMarketSettlementFee(sourceId, i, 0.00001e18);
        }
        midnight.touchMarket(target);
        for (uint256 i; i < 7; i++) {
            midnight.setMarketSettlementFee(targetId, i, i < 2 ? 0.00001e18 : 0.00009e18);
        }
    }

    /// @dev With Midnight settlement fees on both markets the legs and the bound still close exactly.
    function test_forwardRate_tight_withSettlementFees() public {
        _setSettlementFees();
        _assertBoundIsTight(_borrowRoll(type(uint256).max, 200e18), BORROW_DEBT);
        _assertAdaptersEmpty(source, target);
    }

    /// @dev Flash-funded full roll with settlement fees: the borrow leg settles the exit cost to the wei, so the
    ///      exact-balance check passes and the sweep returns exactly the flash loan.
    function test_settlementFees_fullRoll_flashFunded() public {
        _setSettlementFees();
        _renew(_borrowRoll(type(uint256).max, 200e18));
        assertEq(midnight.debt(sourceId, borrower), 0, "rolled");
        assertEq(_collateral(target, borrower, 0), BORROWER_COL0, "col0 moved");
        assertEq(_collateral(target, borrower, 1), BORROWER_COL1, "col1 moved");
        assertTrue(midnight.isHealthy(target, targetId, borrower));
        _assertAdaptersEmpty(source, target);
    }

    function test_settlementFees_partialRoll_flashFunded() public {
        _setSettlementFees();
        _renew(_borrowRoll(200e18, 80e18));
        assertEq(midnight.debt(sourceId, borrower), BORROW_DEBT - 200e18, "partly rolled");
        assertEq(_collateral(target, borrower, 0), BORROWER_COL0.mulDivDown(200e18, BORROW_DEBT), "col0 pro-rata");
        assertEq(_collateral(target, borrower, 1), BORROWER_COL1.mulDivDown(200e18, BORROW_DEBT), "col1 pro-rata");
        assertTrue(midnight.isHealthy(source, sourceId, borrower));
        assertTrue(midnight.isHealthy(target, targetId, borrower));
        _assertAdaptersEmpty(source, target);
    }

    /* ═══════ Exact balance ═══════ */

    /// @dev A fee adjuster on the borrow leg with nothing to collect the fee: the leg raises the exit cost plus the
    ///      reported fee, and the surplus would stay in the adapter for the bundle's sweep. Now it reverts.
    function test_revert_borrowLegFeeAdjuster_loanBalanceIncreased() public {
        CallbackFeeAdjuster adjuster = new CallbackFeeAdjuster(address(midnight));
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.borrowActions[0].feeAdjuster = address(adjuster);
        r.borrowActions[0].feeAdjusterData = abi.encode(uint256(0.01e18), CallbackFeeAdjuster.FeeFormula.INTEREST);
        _renewExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.LoanBalanceIncreased.selector));
    }

    /// @dev Same on a partial, mixed roll.
    function test_revert_borrowLegFeeAdjuster_partialRoll() public {
        CallbackFeeAdjuster adjuster = new CallbackFeeAdjuster(address(midnight));
        BorrowRoll memory r = _borrowRoll(200e18, 80e18);
        r.borrowActions[0].feeAdjuster = address(adjuster);
        r.borrowActions[0].feeAdjusterData = abi.encode(uint256(0.01e18), CallbackFeeAdjuster.FeeFormula.INTEREST);
        _renewExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.LoanBalanceIncreased.selector));
    }
}
