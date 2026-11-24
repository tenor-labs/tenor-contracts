// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {MidnightRenewalAdapterTestBase, LendRoll} from "../helpers/MidnightRenewalAdapterTestBase.sol";
import {MidnightRenewalAdapterBase} from "../../src/bundler/MidnightRenewalAdapterBase.sol";
import {FillAxis, Action} from "../../src/router/TenorRouter.sol";
import {ITenorRouter} from "../../src/router/interfaces/ITenorRouter.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {TakeMathLib} from "../../src/libraries/TakeMathLib.sol";
import {Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Call} from "@bundler3/interfaces/IBundler3.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";

/// @dev A buyer callback that pays for the take itself, as any real taker-side buy callback does.
contract PayingBuyCallback {
    constructor(address midnight, MockERC20 token) {
        token.approve(midnight, type(uint256).max);
    }

    function onBuy(bytes32, Market memory, uint256, uint256, uint256, address, bytes memory)
        external
        pure
        returns (bytes32)
    {
        return CALLBACK_SUCCESS;
    }
}

/// @title MidnightRenewalAdapterLendTest
/// @notice `midnightRenewLend`: withdraw-only, resale-only and mixed rolls; the onchain withdrawal cap against
///         withdrawable liquidity and credit, including liquidity drained between quote and execution; the
///         forward-rate floor with the par withdrawal inside `closed`; validation.
contract MidnightRenewalAdapterLendTest is MidnightRenewalAdapterTestBase {
    using UtilsLib for uint256;

    uint256 internal PS;
    uint256 internal PT;

    function setUp() public override {
        super.setUp();
        PS = TickLib.tickToPrice(SOURCE_TICK);
        PT = TickLib.tickToPrice(TARGET_TICK);
    }

    struct Snapshot {
        uint256 credit;
        uint256 withdrawable;
        uint256 srcBuyerCredit;
        uint256 tgtCredit;
        uint256 tgtBorrowerBalance;
    }

    function _snap() internal view returns (Snapshot memory s) {
        s.credit = _credit(source, lender);
        s.withdrawable = midnight.withdrawable(sourceId);
        s.srcBuyerCredit = _credit(source, srcBuyer);
        s.tgtCredit = _credit(target, lender);
        s.tgtBorrowerBalance = loanToken.balanceOf(tgtBorrower);
    }

    /// @dev Checks a roll that withdrew `withdrawn` at par and sold `sold` at `price`.
    function _assertRolled(Snapshot memory b, uint256 withdrawn, uint256 sold, uint256 price) internal view {
        Snapshot memory a = _snap();
        uint256 proceeds = withdrawn + sold.mulDivDown(price, WAD);

        assertEq(b.credit - a.credit, withdrawn + sold, "source credit closed");
        assertEq(b.withdrawable - a.withdrawable, withdrawn, "withdrawn at par");
        assertEq(a.srcBuyerCredit - b.srcBuyerCredit, sold, "sold into buy offers");
        assertEq(a.tgtBorrowerBalance - b.tgtBorrowerBalance, proceeds, "lend leg spent exactly the proceeds");
        assertEq(a.tgtCredit - b.tgtCredit, TakeMathLib.mulDivUpInverse(proceeds, WAD, PT), "new target credit");
        _assertAdaptersEmpty(source, target);
    }

    function _expectedNewCredit(uint256 withdrawn, uint256 sold, uint256 price) internal view returns (uint256) {
        return TakeMathLib.mulDivUpInverse(withdrawn + sold.mulDivDown(price, WAD), WAD, PT);
    }

    /* ═══════ Withdraw only ═══════ */

    function test_withdrawOnly() public {
        Snapshot memory b = _snap();
        _renewLend(_lendRoll(150e18, 0));
        _assertRolled(b, 150e18, 0, PS);
    }

    function test_withdrawOnly_cappedAtWithdrawable() public {
        Snapshot memory b = _snap();
        _renewLend(_lendRoll(400e18, 0));
        _assertRolled(b, INITIAL_WITHDRAWABLE, 0, PS);
        assertEq(midnight.withdrawable(sourceId), 0, "pool drained");
    }

    function test_withdrawOnly_cappedAtCredit() public {
        vm.prank(srcBorrower);
        midnight.repay(source, 500e18, srcBorrower, address(0), "");
        assertGt(midnight.withdrawable(sourceId), LEND_CREDIT, "precondition: pool deeper than the credit");

        Snapshot memory b = _snap();
        _renewLend(_lendRoll(type(uint256).max, 0));
        _assertRolled(b, LEND_CREDIT, 0, PS);
        assertEq(_credit(source, lender), 0, "fully rolled");
    }

    /// @dev Credit with a pending continuous fee: the cap uses the updated credit, not the stored one, so a
    ///      max-withdrawal does not underflow inside Midnight.
    function test_withdrawOnly_cappedAtUpdatedCredit_withContinuousFee() public {
        midnight.setFeeSetter(address(this));
        midnight.setMarketContinuousFee(sourceId, 0.01e18 / uint256(365 days));
        _lendTo(source, lender, srcBorrower, srcBorrowerSK, 100e18);
        vm.prank(srcBorrower);
        midnight.repay(source, 600e18, srcBorrower, address(0), "");
        vm.warp(block.timestamp + 3 days);
        assertLt(_credit(source, lender), midnight.credit(sourceId, lender), "precondition: fee accrued");

        _renewLend(_lendRoll(type(uint256).max, 0));
        assertEq(_credit(source, lender), 0, "all updated credit rolled");
        _assertAdaptersEmpty(source, target);
    }

    /// @dev After the source matures the par withdrawal still works and the roll goes ahead.
    function test_withdrawOnly_afterSourceMaturity() public {
        vm.warp(source.maturity + 1);
        Snapshot memory b = _snap();
        _renewLend(_lendRoll(type(uint256).max, 0));
        _assertRolled(b, INITIAL_WITHDRAWABLE, 0, PS);
    }

    /* ═══════ Resale only ═══════ */

    function test_resaleOnly() public {
        Snapshot memory b = _snap();
        _renewLend(_lendRoll(0, 250e18));
        _assertRolled(b, 0, 250e18, PS);
    }

    function test_resaleOnly_noWithdrawableLiquidity() public {
        vm.prank(otherLender);
        midnight.withdraw(source, INITIAL_WITHDRAWABLE, otherLender, otherLender);

        Snapshot memory b = _snap();
        _renewLend(_lendRoll(type(uint256).max, LEND_CREDIT));
        _assertRolled(b, 0, LEND_CREDIT, PS);
    }

    /* ═══════ Mixed ═══════ */

    /// @dev Pool first at par, then the rest of the credit through offers: a full exit.
    function test_mixed_fullExit() public {
        Snapshot memory b = _snap();
        _renewLend(_lendRoll(type(uint256).max, 1_000e18));
        _assertRolled(b, INITIAL_WITHDRAWABLE, LEND_CREDIT - INITIAL_WITHDRAWABLE, PS);
        assertEq(_credit(source, lender), 0, "nothing left on source");
    }

    function test_mixed_explicitExitMaxFill() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 1_000e18);
        r.exitParams.maxFill = 100e18;
        Snapshot memory b = _snap();
        _renewLend(r);
        _assertRolled(b, INITIAL_WITHDRAWABLE, 100e18, PS);
    }

    function test_mixed_minFillSentinel_sellsAllRemainingCredit() public {
        LendRoll memory r = _lendRoll(100e18, 1_000e18);
        r.exitParams.minFill = type(uint256).max;
        Snapshot memory b = _snap();
        _renewLend(r);
        _assertRolled(b, 100e18, LEND_CREDIT - 100e18, PS);
    }

    /* ═══════ Liquidity shrinking between quote and execution ═══════ */

    /// @dev Another lender drains most of the pool first: the withdrawal shrinks to what is left and the exit
    ///      batch, sized by the sentinel, sells the difference.
    function test_withdrawableShrinks_exitAbsorbsTheRest() public {
        vm.prank(otherLender);
        midnight.withdraw(source, 150e18, otherLender, otherLender);

        Snapshot memory b = _snap();
        _renewLend(_lendRoll(INITIAL_WITHDRAWABLE, 1_000e18));
        _assertRolled(b, 50e18, LEND_CREDIT - 50e18, PS);
    }

    /// @dev Same, with an exit sized at quote time: less is rolled, the rest stays on the source.
    function test_withdrawableShrinks_explicitExit_lessRolled() public {
        LendRoll memory r = _lendRoll(INITIAL_WITHDRAWABLE, 1_000e18);
        r.exitParams.maxFill = LEND_CREDIT - INITIAL_WITHDRAWABLE;
        r.minForwardRate = 1;

        vm.prank(otherLender);
        midnight.withdraw(source, 150e18, otherLender, otherLender);

        Snapshot memory b = _snap();
        _renewLend(r);
        _assertRolled(b, 50e18, LEND_CREDIT - INITIAL_WITHDRAWABLE, PS);
        assertEq(_credit(source, lender), 150e18, "unrolled credit stays on source");
    }

    /// @dev A roll requiring the whole credit to close reverts instead when the offers cannot absorb the shortfall.
    function test_revert_withdrawableShrinks_minFillSentinelUnmet() public {
        LendRoll memory r = _lendRoll(INITIAL_WITHDRAWABLE, LEND_CREDIT - INITIAL_WITHDRAWABLE);
        r.exitParams.minFill = type(uint256).max;

        vm.prank(otherLender);
        midnight.withdraw(source, 150e18, otherLender, otherLender);

        _renewLendExpectRevert(
            r,
            abi.encodeWithSelector(
                ITenorRouter.InsufficientFill.selector, LEND_CREDIT - INITIAL_WITHDRAWABLE, LEND_CREDIT - 50e18
            )
        );
    }

    /// @dev The exit offer is taken by someone else first: with no fill floor the roll is just the withdrawal.
    function test_griefing_exitOfferConsumed_rollsLess() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 300e18);
        Action memory a = r.exitActions[0];
        vm.prank(otherLender);
        midnight.take(a.offer, a.take.ratifierData, 300e18, otherLender, otherLender, address(0), "");

        Snapshot memory b = _snap();
        _renewLend(r);
        _assertRolled(b, INITIAL_WITHDRAWABLE, 0, PS);
    }

    function test_revert_griefing_targetLiquidityConsumed() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 0);
        r.lendActions = _one(_tgtSellAction(target, 100e18, TARGET_TICK));
        _renewLendExpectPartialRevert(r, ITenorRouter.InsufficientFill.selector);
    }

    /* ═══════ Forward rate ═══════ */

    function _assertFloorIsTight(LendRoll memory r) internal {
        (uint256 newCredit, uint256 closed) = _dryRunLend(r);
        int256 rate = _tightestMinRate(closed, newCredit, DELTA);
        assertGt(rate, 0, "precondition: roll earns interest");

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
    }

    function test_forwardRate_tight_withdrawOnly() public {
        _assertFloorIsTight(_lendRoll(150e18, 0));
    }

    function test_forwardRate_tight_resaleOnly() public {
        _assertFloorIsTight(_lendRoll(0, 250e18));
    }

    function test_forwardRate_tight_mixed() public {
        _assertFloorIsTight(_lendRoll(type(uint256).max, 1_000e18));
    }

    /// @dev Zero floor: at least one unit of new credit per unit closed. A resale far below par fails it.
    function test_revert_forwardRate_zeroFloor_resaleBelowPar() public {
        LendRoll memory r = _lendRoll(0, 0);
        uint256 tick = TickLib.priceToTick(0.9e18, DEFAULT_TICK_SPACING);
        r.exitActions = _one(_srcBuyAction(250e18, tick));
        uint256 newCredit = _expectedNewCredit(0, 250e18, TickLib.tickToPrice(tick));
        assertLt(newCredit, 250e18, "precondition");
        _renewLendExpectRevert(
            r, abi.encodeWithSelector(MidnightRenewalAdapterBase.ForwardRateBelowMin.selector, newCredit, 250e18)
        );
    }

    /// @dev `closed` counts the par withdrawal: the revert reports a floor on withdrawn + sold.
    function test_revert_forwardRate_closedIncludesParWithdrawal() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 0);
        uint256 tick = TickLib.priceToTick(0.9e18, DEFAULT_TICK_SPACING);
        r.exitActions = _one(_srcBuyAction(1_000e18, tick));
        uint256 sold = LEND_CREDIT - INITIAL_WITHDRAWABLE;
        uint256 newCredit = _expectedNewCredit(INITIAL_WITHDRAWABLE, sold, TickLib.tickToPrice(tick));
        _renewLendExpectRevert(
            r, abi.encodeWithSelector(MidnightRenewalAdapterBase.ForwardRateBelowMin.selector, newCredit, LEND_CREDIT)
        );
    }

    /// @dev The par part lifts the whole roll: the same below-par resale passes once enough is withdrawn at par.
    function test_forwardRate_parWithdrawalLiftsBelowParResale() public {
        uint256 tick = TickLib.priceToTick(0.9e18, DEFAULT_TICK_SPACING);
        LendRoll memory resaleOnly = _lendRoll(0, 0);
        resaleOnly.exitActions = _one(_srcBuyAction(20e18, tick));
        _renewLendExpectPartialRevert(resaleOnly, MidnightRenewalAdapterBase.ForwardRateBelowMin.selector);

        LendRoll memory mixed = _lendRoll(type(uint256).max, 0);
        mixed.exitActions = _one(_srcBuyAction(20e18, tick));
        mixed.exitParams.maxFill = 20e18;
        _renewLend(mixed);
        assertEq(LEND_CREDIT - _credit(source, lender), INITIAL_WITHDRAWABLE + 20e18);
    }

    function test_forwardRate_independentOfInclusionTime() public {
        LendRoll memory r = _lendRoll(150e18, 0);
        (uint256 newCredit, uint256 closed) = _dryRunLend(r);
        int256 rate = _tightestMinRate(closed, newCredit, DELTA);
        vm.warp(block.timestamp + 3 days);
        r = _lendRoll(150e18, 0);
        r.minForwardRate = rate;
        _renewLend(r);
    }

    /* ═══════ Validation ═══════ */

    function test_revert_exitOnWrongMarket() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 0);
        r.exitActions = _one(_action(_offer(target, true, srcBuyer, SOURCE_TICK, 100e18), srcBuyerSK));
        _renewLendExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.WrongMarket.selector));
    }

    function test_revert_exitFillAxisAssets() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 100e18);
        r.exitParams.fillAxis = FillAxis.ASSETS;
        _renewLendExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.WrongFillAxis.selector));
    }

    function test_revert_lendFillAxisUnits() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 0);
        r.lendParams.fillAxis = FillAxis.UNITS;
        _renewLendExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.WrongFillAxis.selector));
    }

    function test_revert_exitNotReduceOnly() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 100e18);
        r.exitParams.reduceOnly = false;
        _renewLendExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.ExitNotReduceOnly.selector));
    }

    /// @dev Exit on the source's sell side (the lender would buy more source credit with the withdrawn funds):
    ///      the forced reduce-only check catches the credit growth.
    function test_revert_exitOnSourceSellSide_reduceOnly() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 0);
        r.exitActions = _one(_action(_offer(source, false, srcBorrower, SOURCE_TICK, 100e18), srcBorrowerSK));
        _renewLendExpectPartialRevert(r, ITenorRouter.ReduceOnlyViolated.selector);
    }

    function test_revert_zeroAmount_nothingToWithdrawNoExit() public {
        _renewLendExpectRevert(_lendRoll(0, 0), abi.encodeWithSelector(CallbackLib.ZeroAmount.selector));
    }

    function test_revert_zeroAmount_poolEmptyNoExit() public {
        vm.prank(otherLender);
        midnight.withdraw(source, INITIAL_WITHDRAWABLE, otherLender, otherLender);
        _renewLendExpectRevert(_lendRoll(type(uint256).max, 0), abi.encodeWithSelector(CallbackLib.ZeroAmount.selector));
    }

    function test_revert_zeroAmount_exitFillsNothing() public {
        LendRoll memory r = _lendRoll(0, 300e18);
        Action memory a = r.exitActions[0];
        vm.prank(otherLender);
        midnight.take(a.offer, a.take.ratifierData, 300e18, otherLender, otherLender, address(0), "");
        _renewLendExpectRevert(r, abi.encodeWithSelector(CallbackLib.ZeroAmount.selector));
    }

    /// @dev An initiator with no source credit closes nothing, even with the pool full.
    function test_revert_zeroAmount_noCredit() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 0);
        vm.prank(attacker);
        midnight.setIsAuthorized(address(adapter), true, attacker);
        Call[] memory calls = _lendBundle(r);
        vm.prank(attacker);
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        bundler3.multicall(calls);
    }

    function test_revert_tokenMismatch() public {
        Market memory tgt = _market(target.maturity, 2, 0.945e18);
        tgt.loanToken = address(otherLoanToken);
        LendRoll memory r = _lendRoll(type(uint256).max, 0);
        r.lendActions = _one(_action(_offer(tgt, false, tgtBorrower, TARGET_TICK, 1e18), tgtBorrowerSK));
        _renewLendExpectRevert(r, abi.encodeWithSelector(CallbackLib.TokenMismatch.selector));
    }

    function test_revert_invalidMaturities() public {
        Market memory tgt = _market(source.maturity, 1, 0.945e18);
        LendRoll memory r = _lendRoll(type(uint256).max, 0);
        r.lendActions = _one(_tgtSellAction(tgt, type(uint128).max, TARGET_TICK));
        _renewLendExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.InvalidMaturities.selector));
    }

    /// @dev lendParams.maxFill / minFill are overridden by the exit proceeds.
    function test_lendFillBoundsIgnored() public {
        LendRoll memory r = _lendRoll(150e18, 0);
        r.lendParams.maxFill = 1;
        r.lendParams.minFill = type(uint128).max;
        Snapshot memory b = _snap();
        _renewLend(r);
        _assertRolled(b, 150e18, 0, PS);
    }

    function test_revert_lendActionsEmpty() public {
        LendRoll memory r = _lendRoll(150e18, 0);
        r.lendActions = new Action[](0);
        _renewLendExpectRevert(r, abi.encodeWithSelector(ITenorRouter.EmptyActions.selector));
    }

    function test_revert_exitPriceBelowMin() public {
        LendRoll memory r = _lendRoll(0, 250e18);
        r.exitParams.minPrice = PS + 1;
        _renewLendExpectPartialRevert(r, ITenorRouter.PriceSlippageExceeded.selector);
    }

    /* ═══════ The lend leg must spend the proceeds ═══════ */

    /// @dev Lend leg on the target's BUY side: the lender would sell target credit it already holds, and the floor
    ///      would read those sold units as new credit. Before the balance check this passed at the honest roll's
    ///      tightest rate: 200e18 source credit closed, 400e18 target credit lost to the bidder, 200e18 stranded in
    ///      the adapter. The unspent proceeds now revert it.
    function test_revert_lendLegOnBuySide_proceedsUnspent() public {
        _lendTo(target, lender, tgtBorrower, tgtBorrowerSK, 1_000e18);

        (uint256 honestCredit, uint256 honestClosed) = _dryRunLend(_lendRoll(INITIAL_WITHDRAWABLE, 0));
        LendRoll memory r = _lendRoll(INITIAL_WITHDRAWABLE, 0);
        r.minForwardRate = _tightestMinRate(honestClosed, honestCredit, DELTA);
        Offer memory bid = _offer(target, true, attacker, TickLib.priceToTick(0.5e18, DEFAULT_TICK_SPACING), 10_000e18);
        r.lendActions = _one(_action(bid, attackerSK, attacker));

        uint256 targetCredit = _credit(target, lender);
        _renewLendExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.LoanBalanceIncreased.selector));
        assertEq(_credit(target, lender), targetCredit, "target credit untouched");
    }

    /// @dev Same with the proceeds of the wrong-side leg routed back to the adapter: the balance grows further.
    function test_revert_lendLegOnBuySide_proceedsToAdapter() public {
        _lendTo(target, lender, tgtBorrower, tgtBorrowerSK, 1_000e18);
        LendRoll memory r = _lendRoll(INITIAL_WITHDRAWABLE, 0);
        Offer memory bid = _offer(target, true, attacker, TickLib.priceToTick(0.5e18, DEFAULT_TICK_SPACING), 10_000e18);
        r.lendActions = _one(_action(bid, attackerSK, address(adapter)));
        _renewLendExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.LoanBalanceIncreased.selector));
    }

    /// @dev A lender with no target position cannot be made to sell there at all: the take leaves it unhealthy.
    function test_revert_lendLegOnBuySide_noTargetPosition() public {
        LendRoll memory r = _lendRoll(INITIAL_WITHDRAWABLE, 0);
        Offer memory bid = _offer(target, true, attacker, TickLib.priceToTick(0.5e18, DEFAULT_TICK_SPACING), 10_000e18);
        r.lendActions = _one(_action(bid, attackerSK, attacker));
        _renewLendExpectPartialRevert(r, ITenorRouter.ActionFailed.selector);
    }

    /// @dev Lend leg with a taker callback: the callback pays the leg and the proceeds would stay in the adapter.
    function test_revert_lendLegWithTakerCallback() public {
        PayingBuyCallback cb = new PayingBuyCallback(address(midnight), loanToken);
        loanToken.mint(address(cb), 1_000e18);
        LendRoll memory r = _lendRoll(INITIAL_WITHDRAWABLE, 0);
        r.lendActions[0].take.takerCallback = address(cb);
        _renewLendExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.LoanBalanceIncreased.selector));
    }

    /// @dev Pre-existing funds in the adapter are not counted as proceeds and not flagged: only growth reverts.
    function test_lendRoll_preExistingAdapterBalanceAllowed() public {
        loanToken.mint(address(adapter), 1e18);
        Snapshot memory b = _snap();
        _renewLend(_lendRoll(150e18, 0));
        assertEq(b.credit - _credit(source, lender), 150e18);
        assertEq(loanToken.balanceOf(address(adapter)), 1e18, "balance back to its start");
    }

    /// @dev Lending into a target where the lender already has credit adds to it.
    function test_targetAlreadyHasCredit() public {
        _lendTo(target, lender, tgtBorrower, tgtBorrowerSK, 40e18);
        Snapshot memory b = _snap();
        _renewLend(_lendRoll(150e18, 0));
        _assertRolled(b, 150e18, 0, PS);
    }

    /// @dev Exit liquidity spread over two offers, the second only partly used.
    function test_mixed_twoExitOffers() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 0);
        r.exitActions = _two(_srcBuyAction(100e18), _srcBuyAction(1_000e18));
        Snapshot memory b = _snap();
        _renewLend(r);
        _assertRolled(b, INITIAL_WITHDRAWABLE, LEND_CREDIT - INITIAL_WITHDRAWABLE, PS);
    }
}
