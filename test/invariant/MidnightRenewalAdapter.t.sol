// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MidnightRenewalAdapterTestBase, BorrowRoll, LendRoll} from "../helpers/MidnightRenewalAdapterTestBase.sol";
import {MidnightRenewalAdapterBase} from "../../src/bundler/MidnightRenewalAdapterBase.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {Call} from "@bundler3/interfaces/IBundler3.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";

/// @dev Interleaves borrow rolls, lend rolls and third-party moves (other lenders draining the pool, borrowers
///      refilling it, time passing), latching any property violation into a flag rather than reverting, so the
///      campaign reports the sequence that produced it.
/// @dev The handler is the fixture: it inherits the shared base and runs its `setUp` in the constructor.
contract RenewalHandler is MidnightRenewalAdapterTestBase {
    using UtilsLib for uint256;

    bool public boundViolated;
    bool public proRataViolated;
    bool public closedMismatch;
    bool public unexpectedRevert;
    bytes4 public unexpectedSelector;

    uint256 public borrowRolls;
    uint256 public lendRolls;
    uint256 public rejected;

    constructor() {
        setUp();
    }

    function _tickIn(uint256 seed, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return TickLib.priceToTick(bound(seed, lo, hi), DEFAULT_TICK_SPACING);
    }

    function borrowRoll(uint256 repaySeed, uint256 exitSeed, uint256 priceSeed, uint256 rateSeed) external {
        uint256 debt = midnight.debt(sourceId, borrower);
        if (debt == 0) {
            if (block.timestamp >= source.maturity) return;
            _openBorrowerPosition(source, 300e18, 400e18, 300e18);
            debt = midnight.debt(sourceId, borrower);
        }
        uint256 repayUnits = bound(repaySeed, UtilsLib.min(1e15, debt), debt);
        uint256 exitCap = UtilsLib.min(bound(exitSeed, 0, debt), _credit(source, srcLender));

        BorrowRoll memory r = _borrowRoll(repayUnits, 0);
        if (exitCap != 0) r.exitActions = _one(_srcSellAction(exitCap, _tickIn(exitSeed, 0.9e18, 0.9999e18)));
        r.borrowActions = _one(_tgtBuyAction(target, type(uint128).max, _tickIn(priceSeed, 0.9e18, 0.999e18)));
        r.maxForwardRate = rateSeed % 4 == 0 ? type(int256).max : bound(int256(rateSeed), -3e10, 5e10);

        uint256[2] memory c = [_collateral(source, borrower, 0), _collateral(source, borrower, 1)];
        uint256[2] memory t = [_collateral(target, borrower, 0), _collateral(target, borrower, 1)];
        uint256 tgtDebt = midnight.debt(targetId, borrower);

        Call[] memory calls = _borrowBundle(r);
        vm.prank(borrower);
        try bundler3.multicall(calls) {
            borrowRolls++;
            uint256 newDebt = midnight.debt(targetId, borrower) - tgtDebt;
            if (r.maxForwardRate != type(int256).max && newDebt > _maxNewDebt(repayUnits, r.maxForwardRate, DELTA)) {
                boundViolated = true;
            }
            if (midnight.debt(sourceId, borrower) != debt - repayUnits) closedMismatch = true;
            for (uint256 i; i < 2; i++) {
                uint256 moved = repayUnits == debt ? c[i] : c[i].mulDivDown(repayUnits, debt);
                if (
                    _collateral(target, borrower, i) - t[i] != moved || _collateral(source, borrower, i) != c[i] - moved
                ) {
                    proRataViolated = true;
                }
            }
        } catch (bytes memory err) {
            _onRevert(err, MidnightRenewalAdapterBase.ForwardRateAboveMax.selector);
        }
    }

    function lendRoll(uint256 withdrawSeed, uint256 exitSeed, uint256 priceSeed, uint256 rateSeed) external {
        if (_credit(source, lender) == 0) {
            if (block.timestamp >= source.maturity) return;
            _lendTo(source, lender, srcBorrower, srcBorrowerSK, 300e18);
        }
        uint256 credit = _credit(source, lender);
        uint256 withdrawUnits = withdrawSeed % 5 == 0 ? type(uint256).max : bound(withdrawSeed, 0, credit + 100e18);
        uint256 withdrawn = UtilsLib.min(withdrawUnits, UtilsLib.min(midnight.withdrawable(sourceId), credit));

        LendRoll memory r = _lendRoll(withdrawUnits, 0);
        uint256 exitCap = bound(exitSeed, 0, credit + 100e18);
        if (exitCap != 0) r.exitActions = _one(_srcBuyAction(exitCap, _tickIn(exitSeed, 0.9e18, 0.9999e18)));
        r.lendActions = _one(_tgtSellAction(target, type(uint128).max, _tickIn(priceSeed, 0.9e18, 0.999e18)));
        r.minForwardRate = rateSeed % 4 == 0 ? type(int256).min : bound(int256(rateSeed), -3e10, 5e10);

        uint256 buyerCredit = _credit(source, srcBuyer);
        uint256 tgtCredit = _credit(target, lender);

        Call[] memory calls = _lendBundle(r);
        vm.prank(lender);
        try bundler3.multicall(calls) {
            lendRolls++;
            uint256 closed = credit - _credit(source, lender);
            if (closed != withdrawn + (_credit(source, srcBuyer) - buyerCredit)) closedMismatch = true;
            if (
                r.minForwardRate != type(int256).min
                    && _credit(target, lender) - tgtCredit < _minNewCredit(closed, r.minForwardRate, DELTA)
            ) {
                boundViolated = true;
            }
        } catch (bytes memory err) {
            if (bytes4(err) == CallbackLib.ZeroAmount.selector && withdrawn == 0) {
                rejected++;
                return;
            }
            _onRevert(err, MidnightRenewalAdapterBase.ForwardRateBelowMin.selector);
        }
    }

    /// @dev Another lender withdraws ahead of the next roll.
    function drainPool(uint256 seed) external {
        uint256 units = UtilsLib.min(midnight.withdrawable(sourceId), _credit(source, otherLender));
        units = bound(seed, 0, units);
        if (units == 0) return;
        vm.prank(otherLender);
        midnight.withdraw(source, units, otherLender, otherLender);
    }

    /// @dev A source borrower repays at par, refilling the pool.
    function refillPool(uint256 seed) external {
        uint256 units = bound(seed, 0, midnight.debt(sourceId, srcBorrower));
        if (units == 0) return;
        vm.prank(srcBorrower);
        midnight.repay(source, units, srcBorrower, address(0), "");
    }

    function elapse(uint256 seed) external {
        uint256 to = UtilsLib.min(block.timestamp + bound(seed, 1, 1 days), target.maturity - 1 days);
        if (to > block.timestamp) vm.warp(to);
    }

    function _onRevert(bytes memory err, bytes4 boundSelector) internal {
        if (bytes4(err) == boundSelector) {
            rejected++;
            return;
        }
        unexpectedRevert = true;
        unexpectedSelector = bytes4(err);
    }

    /* ═══════ Views for the invariants ═══════ */

    function adapterAddr() external view returns (address) {
        return address(adapter);
    }

    function adapterEmpty() external view returns (bool) {
        address[2] memory holders = [address(adapter), address(tenorAdapter)];
        for (uint256 h; h < 2; h++) {
            if (loanToken.balanceOf(holders[h]) != 0) return false;
            if (col0.balanceOf(holders[h]) != 0 || col1.balanceOf(holders[h]) != 0) return false;
        }
        bytes32[2] memory ids = [sourceId, targetId];
        for (uint256 i; i < 2; i++) {
            if (midnight.debt(ids[i], address(adapter)) != 0 || midnight.credit(ids[i], address(adapter)) != 0) {
                return false;
            }
            if (midnight.collateral(ids[i], address(adapter), 0) != 0) return false;
            if (midnight.collateral(ids[i], address(adapter), 1) != 0) return false;
        }
        return true;
    }

    function borrowerHealthy() external view returns (bool) {
        return midnight.isHealthy(source, sourceId, borrower) && midnight.isHealthy(target, targetId, borrower);
    }
}

contract MidnightRenewalAdapterInvariantTest is Test {
    RenewalHandler internal handler;

    function setUp() public {
        handler = new RenewalHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RenewalHandler.borrowRoll.selector;
        selectors[1] = RenewalHandler.lendRoll.selector;
        selectors[2] = RenewalHandler.drainPool.selector;
        selectors[3] = RenewalHandler.refillPool.selector;
        selectors[4] = RenewalHandler.elapse.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Guards against a vacuous campaign: each run must actually roll something.
    function afterInvariant() public view {
        console.log("borrow rolls", handler.borrowRolls(), "lend rolls", handler.lendRolls());
        console.log("bound rejections", handler.rejected());
        assertGt(handler.borrowRolls() + handler.lendRolls(), 0, "no roll executed");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_adapterHoldsNothing() public view {
        assertTrue(handler.adapterEmpty(), "adapter holds funds, collateral or a position");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_forwardRateBoundHolds() public view {
        assertFalse(handler.boundViolated(), "a successful roll breached its bound");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_collateralProRata() public view {
        assertFalse(handler.proRataViolated(), "collateral moved off pro-rata");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_closedAsClaimed() public view {
        assertFalse(handler.closedMismatch(), "position closed differs from what the roll reports");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_onlyBoundRejections() public view {
        assertFalse(handler.unexpectedRevert(), "roll failed for a reason other than its bound");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_borrowerHealthy() public view {
        assertTrue(handler.borrowerHealthy(), "borrower left unhealthy");
    }
}
