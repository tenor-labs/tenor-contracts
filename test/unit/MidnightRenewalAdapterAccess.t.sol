// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {MidnightRenewalAdapterTestBase, BorrowRoll, LendRoll} from "../helpers/MidnightRenewalAdapterTestBase.sol";
import {MidnightRenewalAdapterBase} from "../../src/bundler/MidnightRenewalAdapterBase.sol";
import {ITenorRouterAdapter} from "../../src/bundler/interfaces/ITenorRouterAdapter.sol";
import {ErrorsLib} from "@bundler3/libraries/ErrorsLib.sol";
import {Call} from "@bundler3/interfaces/IBundler3.sol";
import {IMidnight, Offer} from "@midnight/interfaces/IMidnight.sol";
import {ITenorRouter} from "../../src/router/interfaces/ITenorRouter.sol";
import {PayingBuyCallback} from "./MidnightRenewalAdapterLend.t.sol";

/// @title MidnightRenewalAdapterAccessTest
/// @notice Entry points reachable only through Bundler3, `execute` disabled, the initiator as the only position
///         touched, the user's Midnight authorization required, no way to make the adapter a payer, consume-group
///         accounting for mixed execution, and the deployed size budget.
contract MidnightRenewalAdapterAccessTest is MidnightRenewalAdapterTestBase {
    /* ═══════ Bundler3 only ═══════ */

    function test_revert_midnightRenew_directCall() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        vm.prank(borrower);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        adapter.midnightRenew(
            r.source,
            r.repayUnits,
            r.exitParams,
            r.exitActions,
            r.borrowParams,
            r.borrowActions,
            r.maxForwardRate,
            r.consumeGroup,
            r.maxConsumed
        );
    }

    function test_revert_midnightRenewLend_directCall() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 0);
        vm.prank(lender);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        adapter.midnightRenewLend(
            r.source,
            r.withdrawUnits,
            r.exitParams,
            r.exitActions,
            r.lendParams,
            r.lendActions,
            r.minForwardRate,
            r.consumeGroup,
            r.maxConsumed
        );
    }

    function test_revert_execute_direct() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, BORROW_DEBT);
        vm.prank(borrower);
        vm.expectRevert(MidnightRenewalAdapterBase.ExecuteDisabled.selector);
        adapter.execute(r.exitParams, r.exitActions);
    }

    function test_revert_execute_throughBundler3() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, BORROW_DEBT);
        Call[] memory calls = new Call[](1);
        calls[0] = _call(address(adapter), abi.encodeCall(adapter.execute, (r.exitParams, r.exitActions)));
        vm.prank(borrower);
        vm.expectRevert(MidnightRenewalAdapterBase.ExecuteDisabled.selector);
        bundler3.multicall(calls);
    }

    /* ═══════ Only the initiator's position ═══════ */

    /// @dev Another initiator naming the borrower's source market rolls only its own (empty) position.
    function test_revert_otherInitiator_cannotRollBorrowersDebt() public {
        vm.prank(attacker);
        midnight.setIsAuthorized(address(adapter), true, attacker);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        Call[] memory calls = _borrowBundle(r);
        vm.prank(attacker);
        vm.expectRevert(MidnightRenewalAdapterBase.InvalidRepayUnits.selector);
        bundler3.multicall(calls);
        assertEq(midnight.debt(sourceId, borrower), BORROW_DEBT);
    }

    /// @dev Another borrower on the same source market rolls its own debt; the borrower's is untouched.
    function test_otherInitiator_rollsOnlyOwnPosition() public {
        address other = attacker;
        vm.prank(other);
        midnight.setIsAuthorized(address(adapter), true, other);
        col0.mint(other, 1_000e18);
        vm.prank(other);
        midnight.supplyCollateral(source, 0, 1_000e18, other);
        Offer memory o = _offer(source, true, srcLender, SOURCE_TICK, 200e18);
        vm.prank(other);
        midnight.take(o, _ratifierData(o, srcLenderSK), 200e18, other, other, address(0), "");

        uint256 c0 = _collateral(source, borrower, 0);
        uint256 c1 = _collateral(source, borrower, 1);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 100e18);
        _renewAs(other, r);

        assertEq(midnight.debt(sourceId, other), 0, "other rolled");
        assertGt(midnight.debt(targetId, other), 200e18, "other borrowed on target");
        assertEq(midnight.debt(sourceId, borrower), BORROW_DEBT, "borrower debt untouched");
        assertEq(_collateral(source, borrower, 0), c0, "borrower col0 untouched");
        assertEq(_collateral(source, borrower, 1), c1, "borrower col1 untouched");
        assertEq(midnight.debt(targetId, borrower), 0, "no target debt for borrower");
        _assertAdaptersEmpty(source, target);
    }

    function test_otherInitiator_lendRollsOnlyOwnCredit() public {
        vm.prank(otherLender);
        midnight.setIsAuthorized(address(adapter), true, otherLender);
        _renewLendAs(otherLender, _lendRoll(type(uint256).max, 0));
        assertEq(_credit(source, lender), LEND_CREDIT, "lender untouched");
        assertEq(_credit(source, otherLender), OTHER_CREDIT - INITIAL_WITHDRAWABLE, "other withdrew the pool");
        assertEq(_credit(target, lender), 0, "nothing lent for lender");
        assertGt(_credit(target, otherLender), INITIAL_WITHDRAWABLE, "other lent on target");
    }

    /* ═══════ Midnight authorization ═══════ */

    function test_revert_borrowerRevokedAdapter_parPath() public {
        vm.prank(borrower);
        midnight.setIsAuthorized(address(adapter), false, borrower);
        _renewExpectRevert(_borrowRoll(type(uint256).max, 0), abi.encodeWithSelector(IMidnight.Unauthorized.selector));
    }

    function test_revert_borrowerRevokedAdapter_offerPath() public {
        vm.prank(borrower);
        midnight.setIsAuthorized(address(adapter), false, borrower);
        _renewExpectRevert(
            _borrowRoll(type(uint256).max, BORROW_DEBT),
            abi.encodeWithSelector(
                ITenorRouter.ActionFailed.selector, 0, abi.encodeWithSelector(IMidnight.TakerUnauthorized.selector)
            )
        );
    }

    function test_revert_lenderRevokedAdapter() public {
        vm.prank(lender);
        midnight.setIsAuthorized(address(adapter), false, lender);
        _renewLendExpectRevert(_lendRoll(type(uint256).max, 0), abi.encodeWithSelector(IMidnight.Unauthorized.selector));
    }

    /// @dev Exit-only through offers, no withdrawal: the first Midnight call needing authorization is the take.
    function test_revert_lenderRevokedAdapter_offerPath() public {
        vm.prank(lender);
        midnight.setIsAuthorized(address(adapter), false, lender);
        _renewLendExpectRevert(
            _lendRoll(0, 100e18),
            abi.encodeWithSelector(
                ITenorRouter.ActionFailed.selector, 0, abi.encodeWithSelector(IMidnight.TakerUnauthorized.selector)
            )
        );
    }

    /* ═══════ The adapter is never a payer for a third party ═══════ */

    /// @dev After a roll the adapter keeps a standing max loan-token allowance to Midnight. Seed it with funds (as
    ///      if left by a broken bundle) and try every Midnight path that pulls from a callback or `msg.sender`.
    function test_adapterCannotBeMadePayer() public {
        _renew(_borrowRoll(type(uint256).max, 0));
        assertEq(loanToken.allowance(address(adapter), address(midnight)), type(uint256).max, "precondition");
        loanToken.mint(address(adapter), 1_000e18);

        // Repay someone's debt with the adapter as repay callback.
        vm.prank(borrower);
        vm.expectRevert();
        midnight.repay(target, 1e18, borrower, address(adapter), "");

        // Flash loan with the adapter as callback.
        address[] memory tokens = new address[](1);
        tokens[0] = address(loanToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        vm.prank(attacker);
        vm.expectRevert();
        midnight.flashLoan(tokens, amounts, address(adapter), "");

        // Buy credit with the adapter as the buyer (taker) callback.
        Offer memory sell = _offer(target, false, tgtBorrower, 4000, 1e18);
        bytes memory sellData = _ratifierData(sell, tgtBorrowerSK);
        vm.prank(attacker);
        vm.expectRevert();
        midnight.take(sell, sellData, 1e18, attacker, address(0), address(adapter), "");

        // An offer made in the adapter's name: the adapter never authorizes a ratifier.
        Offer memory fake = _offer(target, true, address(adapter), 4000, 1e18);
        bytes memory fakeData = _ratifierData(fake, attackerSK);
        vm.prank(tgtBorrower);
        vm.expectRevert(IMidnight.RatifierUnauthorized.selector);
        midnight.take(fake, fakeData, 1e18, tgtBorrower, tgtBorrower, address(0), "");

        assertEq(loanToken.balanceOf(address(adapter)), 1_000e18, "adapter funds untouched");
    }

    /// @dev Pre-existing funds in the adapter are neither spent nor topped up by a roll: run without the flash-loan
    ///      wrapper, the adapter ends with exactly what it started with.
    function test_borrowRoll_endsWithExactStartingBalance() public {
        uint256 seed = BORROW_DEBT + 12345;
        loanToken.mint(address(adapter), seed);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 200e18);
        Call[] memory calls = new Call[](1);
        calls[0] = _call(address(adapter), _renewCall(r));
        vm.prank(borrower);
        bundler3.multicall(calls);
        assertEq(loanToken.balanceOf(address(adapter)), seed, "no excess, no shortfall");
    }

    function test_lendRoll_endsWithExactStartingBalance() public {
        loanToken.mint(address(adapter), 777);
        _renewLend(_lendRoll(type(uint256).max, 1_000e18));
        assertEq(loanToken.balanceOf(address(adapter)), 777, "no excess, no shortfall");
    }

    /// @dev Proceeds can no longer be stranded for the next initiator: a lend roll whose leg does not spend them
    ///      reverts, and a sweep right after finds nothing.
    function test_strandedProceedsUnreachable() public {
        LendRoll memory r = _lendRoll(INITIAL_WITHDRAWABLE, 0);
        r.lendActions[0].take.takerCallback = address(new PayingBuyCallback(address(midnight), loanToken));
        loanToken.mint(r.lendActions[0].take.takerCallback, 1_000e18);
        _renewLendExpectRevert(r, abi.encodeWithSelector(MidnightRenewalAdapterBase.LoanBalanceIncreased.selector));

        _renewLend(_lendRoll(INITIAL_WITHDRAWABLE, 0));
        assertEq(loanToken.balanceOf(address(adapter)), 0, "nothing left after a roll");

        Call[] memory sweep = new Call[](1);
        sweep[0] = _call(
            address(adapter), abi.encodeCall(adapter.erc20Transfer, (address(loanToken), attacker, type(uint256).max))
        );
        uint256 before = loanToken.balanceOf(attacker);
        vm.prank(attacker);
        bundler3.multicall(sweep);
        assertEq(loanToken.balanceOf(attacker), before, "nothing to sweep");
    }

    /// @dev Without the flash loan the adapter has nothing to pay the exit with.
    function test_revert_borrowRoll_unfunded() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        Call[] memory calls = new Call[](1);
        calls[0] = _call(address(adapter), _renewCall(r));
        vm.prank(borrower);
        vm.expectRevert();
        bundler3.multicall(calls);
    }

    /* ═══════ Mixed execution: consume groups ═══════ */

    bytes32 internal constant GROUP = keccak256("roll-offer");

    function test_consume_borrow_countsSellerAssetsRaised() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 200e18);
        r.consumeGroup = GROUP;
        uint256 balanceBefore = loanToken.balanceOf(tgtLender);
        _renew(r);
        assertEq(midnight.consumed(borrower, GROUP), balanceBefore - loanToken.balanceOf(tgtLender));
    }

    function test_consume_borrow_additiveToExisting() public {
        vm.prank(borrower);
        midnight.setConsumed(GROUP, 100e18, borrower);
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.consumeGroup = GROUP;
        _renew(r);
        assertEq(midnight.consumed(borrower, GROUP), 100e18 + BORROW_DEBT, "par roll raises exactly the debt");
    }

    function test_consume_borrow_capExact() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.consumeGroup = GROUP;
        r.maxConsumed = uint128(BORROW_DEBT);
        _renew(r);
        assertEq(midnight.consumed(borrower, GROUP), BORROW_DEBT);
    }

    function test_revert_consume_borrow_capExceeded() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.consumeGroup = GROUP;
        r.maxConsumed = uint128(BORROW_DEBT - 1);
        _renewExpectRevert(
            r, abi.encodeWithSelector(ITenorRouterAdapter.ConsumedCapExceeded.selector, BORROW_DEBT, BORROW_DEBT - 1)
        );
    }

    /// @dev Group zero skips the write, whatever the cap.
    function test_consume_zeroGroupSkipped() public {
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.maxConsumed = 0;
        _renew(r);
        assertEq(midnight.consumed(borrower, bytes32(0)), 0);

        LendRoll memory l = _lendRoll(type(uint256).max, 0);
        l.maxConsumed = 0;
        _renewLend(l);
        assertEq(midnight.consumed(lender, bytes32(0)), 0);
    }

    /// @dev The borrower's resting roll offer (asset-capped) was partly taken before the market roll. The two share
    ///      one size: the market leg fits in what is left, and the resting offer is then exhausted.
    function test_consume_borrow_mixedWithRestingOffer() public {
        col0.mint(borrower, 500e18);
        vm.prank(borrower);
        midnight.supplyCollateral(target, 0, 500e18, borrower);

        uint128 size = 300e18;
        Offer memory resting = _offer(target, false, borrower, TARGET_TICK, 0);
        resting.maxUnits = 0;
        resting.maxAssets = size;
        resting.group = GROUP;
        bytes memory restingData = _ratifierData(resting, borrowerSK);

        vm.prank(tgtLender);
        midnight.take(resting, restingData, 100e18, tgtLender, address(0), address(0), "");
        uint256 makerFilled = midnight.consumed(borrower, GROUP);
        assertGt(makerFilled, 0, "maker-side fill counted by Midnight");

        // Too big: the market leg would push the group past the size.
        BorrowRoll memory r = _borrowRoll(type(uint256).max, 0);
        r.consumeGroup = GROUP;
        r.maxConsumed = size;
        _renewExpectRevert(
            r, abi.encodeWithSelector(ITenorRouterAdapter.ConsumedCapExceeded.selector, makerFilled + BORROW_DEBT, size)
        );

        // Sized to what is left: passes, and the resting offer is exhausted.
        r = _borrowRoll(size - makerFilled, 0);
        r.consumeGroup = GROUP;
        r.maxConsumed = size;
        _renew(r);
        assertEq(midnight.consumed(borrower, GROUP), size, "group filled exactly");

        vm.prank(tgtLender);
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        midnight.take(resting, restingData, 1e18, tgtLender, address(0), address(0), "");
    }

    /// @dev Group fill landing between quote and execution (front-run of the resting offer) trips the cap.
    function test_revert_consume_borrow_frontRunFill() public {
        BorrowRoll memory r = _borrowRoll(200e18, 0);
        r.consumeGroup = GROUP;
        r.maxConsumed = 250e18;
        vm.prank(borrower);
        midnight.setConsumed(GROUP, 60e18, borrower);
        _renewExpectRevert(
            r, abi.encodeWithSelector(ITenorRouterAdapter.ConsumedCapExceeded.selector, 260e18, uint256(250e18))
        );
    }

    function test_consume_lend_countsBuyerAssetsLent() public {
        LendRoll memory r = _lendRoll(type(uint256).max, 100e18);
        r.consumeGroup = GROUP;
        uint256 balanceBefore = loanToken.balanceOf(tgtBorrower);
        _renewLend(r);
        assertEq(midnight.consumed(lender, GROUP), loanToken.balanceOf(tgtBorrower) - balanceBefore);
    }

    function test_revert_consume_lend_capExceeded() public {
        LendRoll memory r = _lendRoll(150e18, 0);
        r.consumeGroup = GROUP;
        r.maxConsumed = 150e18 - 1;
        _renewLendExpectRevert(
            r, abi.encodeWithSelector(ITenorRouterAdapter.ConsumedCapExceeded.selector, 150e18, 150e18 - 1)
        );
    }

    /* ═══════ Size ═══════ */

    function test_deployedSize_underEip170() public view {
        uint256 size = address(adapter).code.length;
        console.log("MidnightRenewalAdapter runtime size", size);
        assertLe(size, 24_576, "EIP-170");
    }
}
