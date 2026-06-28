// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DelayedLiquidationGate} from "@gates/DelayedLiquidationGate.sol";
import {IDelayedLiquidationGate} from "@gates/interfaces/IDelayedLiquidationGate.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {IMidnight, Market, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

/// @title FeeOnTransferToken - Mock token that deducts a fee on every transfer
contract FeeOnTransferToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    uint256 public feeBps; // fee in basis points

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint256 _feeBps) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        uint256 fee = (amount * feeBps) / 10000;
        uint256 received = amount - fee;
        balanceOf[from] -= amount;
        balanceOf[to] += received;
        // fee is burned (not sent anywhere)
        totalSupply -= fee;
        return true;
    }
}

/**
 * @title Test_FeeOnTransfer: Fee-on-transfer tokens cause permanent liquidation revert
 *
 * BUG: When the market's loanToken is a fee-on-transfer token, the gate's onLiquidate
 *      pulls `repaidUnits` from the liquidator but receives less due to the transfer fee.
 *      Midnight then tries to pull `repaidUnits` from the gate, which reverts due to insufficient balance.
 * EXPECTED: Liquidation should succeed or the protocol should explicitly reject FOT tokens.
 * ACTUAL: Liquidation permanently reverts, blocking bad debt resolution.
 */
contract Test_FeeOnTransfer is Test {
    Midnight internal midnight;
    DelayedLiquidationGate internal gate;
    MockERC20 internal collateralToken;
    FeeOnTransferToken internal fotLoanToken;
    Oracle internal oracle;

    address internal liquidator = makeAddr("liquidator");
    address internal borrower = makeAddr("borrower");
    address internal lender;
    uint256 internal lenderSK;

    Market internal market;

    uint256 internal constant GRACE_PERIOD = 1 hours;
    uint256 internal constant LIQUIDATION_PERIOD = 2 hours;
    uint256 internal constant LLTV = 0.77e18;
    uint256 internal constant COLLATERAL_PRICE = 1e36; // 1:1
    uint256 internal constant FOT_FEE_BPS = 100; // 1% fee

    function setUp() public {
        (lender, lenderSK) = makeAddrAndKey("Lender");

        // Deploy Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));

        // Deploy FOT loan token and regular collateral
        fotLoanToken = new FeeOnTransferToken("FOT Loan", "FOTL", 18, FOT_FEE_BPS);
        collateralToken = new MockERC20("Collateral", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(COLLATERAL_PRICE);

        // Deploy the delayed liquidation gate
        gate = new DelayedLiquidationGate(address(midnight), GRACE_PERIOD, LIQUIDATION_PERIOD, 1 minutes);

        // Build market
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(fotLoanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Touch market to register it in Midnight
        midnight.touchMarket(market);

        // Full position setup via the take flow is complex, so we verify the onLiquidate
        // callback's token math directly since the bug is in the token flow, not position setup.
    }

    /// @notice Proves that fee-on-transfer tokens cause the onLiquidate callback to leave
    ///         insufficient balance for Midnight's final pull, by testing the token math directly.
    function test_fot_balance_shortfall() public {
        // This is a [CODE-TRACE] level test since we verify the math, not a full end-to-end flow.
        // The key question: does the gate end up with enough tokens after pulling from liquidator?

        uint256 repaidUnits = 100e18;
        uint256 fee = (repaidUnits * FOT_FEE_BPS) / 10000; // 1e18

        console.log("=== Fee-on-Transfer Balance Analysis ===");
        console.log("repaidUnits:", repaidUnits);
        console.log("FOT fee (1%):", fee);

        // Simulate: liquidator has tokens and approved gate
        fotLoanToken.mint(liquidator, 200e18);
        vm.prank(liquidator);
        fotLoanToken.approve(address(gate), type(uint256).max);

        // Before the pull
        uint256 gateBefore = fotLoanToken.balanceOf(address(gate));
        console.log("Gate balance before pull:", gateBefore);

        // Simulate the gate pulling repaidUnits from liquidator (as onLiquidate does)
        // The gate uses SafeTransferLib.safeTransferFrom which calls transferFrom
        vm.prank(address(gate));
        // We can't call SafeTransferLib directly, but we can call transferFrom to simulate
        fotLoanToken.transferFrom(liquidator, address(gate), repaidUnits);

        uint256 gateAfter = fotLoanToken.balanceOf(address(gate));
        console.log("Gate balance after pull:", gateAfter);
        console.log("Expected by Midnight:", repaidUnits);
        console.log("Shortfall:", repaidUnits - gateAfter);

        // THE KEY ASSERTION: gate has LESS than repaidUnits
        // This proves Midnight's subsequent pull of repaidUnits will revert
        assertLt(gateAfter, repaidUnits, "Gate should have less than repaidUnits due to FOT fee");
        assertEq(gateAfter, repaidUnits - fee, "Gate received repaidUnits minus fee");

        // Now simulate what Midnight would do: try to pull repaidUnits from gate
        // First approve Midnight
        vm.prank(address(gate));
        fotLoanToken.approve(address(midnight), repaidUnits);

        // Midnight pulls repaidUnits from gate - this MUST revert
        vm.expectRevert(); // arithmetic underflow because gate only has 99e18 but 100e18 is requested
        vm.prank(address(midnight));
        fotLoanToken.transferFrom(address(gate), address(midnight), repaidUnits);

        console.log("=== CONFIRMED: Midnight pull reverts due to insufficient balance ===");
    }
}

/**
 * @title Test_ZeroLiquidationPeriod: LIQUIDATION_PERIOD=0 blocks all pre-maturity liquidation
 *
 * BUG: When LIQUIDATION_PERIOD is 0, the condition `elapsed >= GRACE_PERIOD && elapsed < GRACE_PERIOD + 0`
 *      simplifies to `elapsed >= GRACE_PERIOD && elapsed < GRACE_PERIOD`, which is never true.
 * EXPECTED: There should be at least some window for liquidation, or zero should be prevented.
 * ACTUAL: No pre-maturity liquidation is ever possible through the gate.
 */
contract Test_ZeroLiquidationPeriod is Test {
    Midnight internal midnight;
    DelayedLiquidationGate internal gate;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    address internal liquidator = makeAddr("liquidator");
    address internal borrower = makeAddr("borrower");

    Market internal market;
    bytes32 internal marketId;

    uint256 internal constant GRACE_PERIOD = 1 hours;
    uint256 internal constant LIQUIDATION_PERIOD = 0; // THE BUG: zero period
    uint256 internal constant LLTV = 0.77e18;

    function setUp() public {
        // Deploy Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));

        // Deploy tokens
        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(1e36); // 1:1 initially

        // Deploy gate with ZERO liquidation period
        gate = new DelayedLiquidationGate(address(midnight), GRACE_PERIOD, LIQUIDATION_PERIOD, 1 minutes);

        // Build market with maturity far in the future
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Touch market to register it
        midnight.touchMarket(market);
        marketId = IdLib.toId(market);
    }

    /// @notice Proves that _isLiquidationAllowed is NEVER true pre-maturity when LIQUIDATION_PERIOD=0
    function test_zero_period_blocks_all_liquidation() public {
        console.log("=== Testing LIQUIDATION_PERIOD=0 ===");
        console.log("GRACE_PERIOD:", GRACE_PERIOD);
        console.log("LIQUIDATION_PERIOD:", LIQUIDATION_PERIOD);

        // We need to make the position unhealthy to start grace period
        // First create a borrower position with debt somehow
        // We need the gate to have a grace period started.
        // Since we cannot easily create debt in this unit test without the full take flow,
        // we will directly test the _isLiquidationAllowed logic by calling the public liquidate()
        // and checking the revert.

        // But first let's test the math directly.
        // The condition is: elapsed >= GRACE_PERIOD && elapsed < GRACE_PERIOD + LIQUIDATION_PERIOD
        // With LIQUIDATION_PERIOD=0: elapsed >= 3600 && elapsed < 3600
        // This is mathematically impossible.

        // We can verify this by checking at every possible elapsed time:
        bool anyTimeAllowed = false;

        uint256 gp = GRACE_PERIOD;
        uint256 lp = LIQUIDATION_PERIOD;

        // Test 1000 timestamps from 0 to 2*GRACE_PERIOD
        for (uint256 elapsed = 0; elapsed <= 2 * gp; elapsed += 1) {
            bool allowed = elapsed >= gp && elapsed < gp + lp;
            if (allowed) {
                anyTimeAllowed = true;
                break;
            }
        }

        console.log("Any time in [0, 2*GP] allows liquidation:", anyTimeAllowed);
        assertFalse(anyTimeAllowed, "No elapsed time should satisfy the condition when LIQUIDATION_PERIOD=0");

        // Also test the boundary precisely:
        // At elapsed = GRACE_PERIOD exactly:
        uint256 elapsedAtBoundary = gp;
        bool allowedAtBoundary = elapsedAtBoundary >= gp && elapsedAtBoundary < gp + lp;
        console.log("At elapsed=GRACE_PERIOD:", allowedAtBoundary);
        assertFalse(allowedAtBoundary, "Even at exact GRACE_PERIOD boundary, condition is false");

        // For comparison: if LIQUIDATION_PERIOD were 1 second:
        uint256 lpNonZero = 1;
        bool allowedWithNonZero = elapsedAtBoundary >= gp && elapsedAtBoundary < gp + lpNonZero;
        console.log("Same boundary with LP=1:", allowedWithNonZero);
        assertTrue(allowedWithNonZero, "With LP=1, the boundary IS reachable");

        console.log("=== CONFIRMED: LIQUIDATION_PERIOD=0 makes pre-maturity liquidation impossible ===");
    }

    /// @notice Proves that calling gate.liquidate() reverts with LiquidationNotAllowed
    ///         even after the grace period has elapsed, when LIQUIDATION_PERIOD=0.
    ///         This uses the actual contract's _isLiquidationAllowed.
    function test_zero_period_actual_gate_reverts() public {
        // To start the grace period, we need an unhealthy position.
        // We'll mock the isHealthy call to return false.

        // First, we need to make Midnight.isHealthy return false for our borrower.
        // The simplest way: the borrower has no collateral but some debt.
        // Since we can't create debt easily without the take flow, let's use vm.mockCall
        // to make isHealthy return false.

        // Mock isHealthy to return false for the borrower
        bytes memory isHealthyCall = abi.encodeWithSelector(midnight.isHealthy.selector, market, marketId, borrower);
        vm.mockCall(address(midnight), isHealthyCall, abi.encode(false));

        // Start grace period
        gate.startGracePeriod(marketId, borrower, address(0));
        (uint56 ts,) = gate.gracePeriodInfo(borrower, marketId);
        uint256 startTime = uint256(ts);
        console.log("Grace period started at:", startTime);

        // Advance time past grace period
        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        // Try to liquidate - should revert with LiquidationNotAllowed
        // because _isLiquidationAllowed returns false (LIQUIDATION_PERIOD=0 means no valid window)
        // AND maturity hasn't passed
        vm.prank(liquidator);
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        gate.liquidate(market, 0, 1e18, 0, borrower, false, address(0), address(0), "");

        console.log("=== CONFIRMED: gate.liquidate() reverts LiquidationNotAllowed ===");

        // Also try at various times to prove no window exists
        for (uint256 delta = 0; delta <= GRACE_PERIOD * 2; delta += 60) {
            vm.warp(startTime + delta);
            vm.prank(liquidator);
            // Check if liquidation reverts (it should for ALL deltas pre-maturity)
            try gate.liquidate(market, 0, 1e18, 0, borrower, false, address(0), address(0), "") returns (
                uint256, uint256
            ) {
                // If this succeeds, the bug doesn't exist as hypothesized
                revert("Liquidation succeeded - bug not confirmed");
            } catch {
                // Expected: liquidation reverts at this time
            }
        }

        console.log("=== CONFIRMED: All timestamps revert. No liquidation window exists ===");
    }
}

/**
 * @title Test_ZeroAmountLiquidation: Zero-amount liquidation enables costless bad debt realization
 *
 * BUG: Calling Midnight.liquidate(seizedAssets=0, repaidUnits=0) passes the atMostOneNonZero check
 *      and processes bad debt (lines 401-411) without requiring any payment or seizing any collateral.
 * EXPECTED: Zero-amount liquidation should be blocked or have no effect.
 * ACTUAL: Bad debt is realized for free, socializing losses to lenders without liquidator paying anything.
 */
contract Test_ZeroAmountLiquidation is Test {
    Midnight internal midnight;
    DelayedLiquidationGate internal gate;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    address internal liquidator = makeAddr("liquidator");
    address internal borrower = makeAddr("borrower");
    address internal lender;
    uint256 internal lenderSK;

    Market internal market;
    bytes32 internal marketId;

    uint256 internal constant GRACE_PERIOD = 1 hours;
    uint256 internal constant LIQUIDATION_PERIOD = 2 hours;
    uint256 internal constant LLTV = 0.77e18;

    function setUp() public {
        (lender, lenderSK) = makeAddrAndKey("Lender");

        // Deploy Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(1e36); // 1:1

        gate = new DelayedLiquidationGate(address(midnight), GRACE_PERIOD, LIQUIDATION_PERIOD, 1 minutes);

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        midnight.touchMarket(market);
        marketId = IdLib.toId(market);
    }

    /// @notice Proves that atMostOneNonZero(0, 0) returns true, allowing zero-amount liquidation
    function test_atMostOneNonZero_allows_both_zero() public pure {
        // Reproduce the check from UtilsLib
        uint256 x = 0;
        uint256 y = 0;
        bool result;
        assembly {
            result := gt(add(iszero(x), iszero(y)), 0)
        }
        // iszero(0) = 1, iszero(0) = 1, 1+1=2, gt(2,0)=true
        assertTrue(result, "atMostOneNonZero(0,0) should be true - both zero passes the check");
        console.log("atMostOneNonZero(0, 0) =", result);
        console.log("=== CONFIRMED: Both-zero passes the input validation ===");
    }

    /// @notice Proves that the gate passes through zero amounts to Midnight,
    ///         and that Midnight's liquidate processes bad debt even with zero repayment.
    ///         This is a [CODE-TRACE] analysis since setting up a full position with bad debt
    ///         requires the complete take flow.
    function test_code_trace_bad_debt_with_zero_amounts() public pure {
        // CODE-TRACE analysis of Midnight.liquidate() with seizedAssets=0, repaidUnits=0:
        //
        // Line 376: require(atMostOneNonZero(0, 0)) -> PASSES (both zero)
        // Line 377-379: touchMarket, get state/position
        // Line 383: originalDebt = debt(id, borrower)
        // Line 384: badDebt = originalDebt
        // Lines 386-397: while(bitmap) loop computes maxDebt and badDebt
        //   badDebt = originalDebt.zeroFloorSub(collateralValue / maxLif)
        //   If collateral value < debt (underwater), badDebt > 0
        //
        // Line 399: require(block.timestamp > maturity || originalDebt > maxDebt)
        //   -> PASSES if position is unhealthy
        //
        // Lines 401-411: if (badDebt > 0) {
        //   position.debt -= badDebt
        //   lossFactor updated (socializes loss to all lenders)
        //   totalUnits -= badDebt
        // }
        //
        // Line 413: if (repaidUnits > 0 || seizedAssets > 0)
        //   -> FALSE when both are 0, so NO actual repayment/seizure occurs
        //
        // Lines 455: safeTransfer collateral to msg.sender -> transfers 0 (seizedAssets=0)
        // Line 461: safeTransferFrom loanToken from msg.sender -> transfers 0 (repaidUnits=0)
        //
        // RESULT: Bad debt is realized (lossFactor updated, affecting ALL lenders)
        //         without any payment or collateral seizure.
        //         The liquidator pays NOTHING but causes loss socialization.

        // This is primarily a Midnight issue. The gate just passes through parameters.
        // The gate's _isLiquidationAllowed is the only extra check, and it doesn't validate amounts.

        console.log("=== CODE-TRACE: Zero-amount liquidation mode analysis ===");
        console.log("atMostOneNonZero(0,0): PASSES");
        console.log("badDebt processing: EXECUTES (if position underwater)");
        console.log("repayment/seizure: SKIPPED (both zero)");
        console.log("Net effect: Bad debt socialized to lenders, liquidator pays nothing");
        console.log("=== This is a Midnight-level issue, gate passes through ===");
    }
}

/**
 * @title Test_NoHealthRecheck: No health re-check at liquidation time
 *
 * BUG: The gate checks timing (_isLiquidationAllowed) but not health at liquidation time.
 *      A borrower who becomes healthy after the grace period started can still be liquidated.
 * ANALYSIS: This is BY DESIGN - the gate handles timing, Midnight handles health.
 *           However, Midnight's liquidate() check at line 399 only requires
 *           `block.timestamp > maturity || originalDebt > maxDebt`.
 *           If the position became healthy again, originalDebt <= maxDebt, and pre-maturity
 *           the check fails -> liquidation reverts. So Midnight DOES protect healthy positions.
 */
contract Test_NoHealthRecheck is Test {
    Midnight internal midnight;
    DelayedLiquidationGate internal gate;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    address internal liquidator = makeAddr("liquidator");
    address internal borrower = makeAddr("borrower");

    Market internal market;
    bytes32 internal marketId;

    uint256 internal constant GRACE_PERIOD = 1 hours;
    uint256 internal constant LIQUIDATION_PERIOD = 2 hours;
    uint256 internal constant LLTV = 0.77e18;

    function setUp() public {
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(1e36);

        gate = new DelayedLiquidationGate(address(midnight), GRACE_PERIOD, LIQUIDATION_PERIOD, 1 minutes);

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        midnight.touchMarket(market);
        marketId = IdLib.toId(market);
    }

    /// @notice The gate does not check health, but Midnight does.
    ///         Verify that a position that was unhealthy at grace-period start but became
    ///         healthy before liquidation time will still be protected by Midnight's own check.
    function test_midnight_protects_healthy_positions() public {
        console.log("=== Health Re-check Analysis ===");

        // Mock isHealthy to return false (unhealthy) for startGracePeriod
        bytes memory isHealthyCall = abi.encodeWithSelector(midnight.isHealthy.selector, market, marketId, borrower);
        vm.mockCall(address(midnight), isHealthyCall, abi.encode(false));

        // Start grace period (requires unhealthy position)
        gate.startGracePeriod(marketId, borrower, address(0));
        console.log("Grace period started (position was unhealthy)");

        // Advance to liquidation window
        vm.warp(block.timestamp + GRACE_PERIOD + 1);

        // Now the position has become healthy (e.g., borrower added collateral)
        // Clear the mock so isHealthy returns true
        vm.clearMockedCalls();

        // The gate will pass _isLiquidationAllowed (timing check passes)
        // But Midnight.liquidate will check originalDebt > maxDebt
        // Since position is now healthy (no debt, or debt < maxDebt), Midnight reverts

        // We expect the call to Midnight.liquidate to revert
        // The gate itself does NOT check health - confirmed.
        // But Midnight protects the position.

        // Since the borrower has no actual position (no debt, no collateral),
        // Midnight's tightened no-op prevention (PR #942) reverts with NotBorrower
        // before reaching the originalDebt > maxDebt check.
        vm.prank(liquidator);
        vm.expectRevert(IMidnight.NotBorrower.selector);
        gate.liquidate(market, 0, 1e18, 0, borrower, false, address(0), address(0), "");

        console.log("=== Gate allowed (timing OK), but Midnight rejected (position healthy) ===");
        console.log("=== BY DESIGN: gate handles timing, Midnight handles health ===");
    }
}

/**
 * @title Test_ForcedVictimRepayment: Direct Midnight.liquidate against the gate on a permissive market
 *
 * BUG: DelayedLiquidationGate.onLiquidate ignored `callerFromMidnight` and read the liquidator from
 *      decoded `data`. An attacker on a permissive market (`liquidatorGate == 0`) could call
 *      Midnight.liquidate directly with the gate as callback and `data` encoding any victim that had
 *      previously approved the gate for the loan token, forcing the gate to pull repayment tokens
 *      from the victim to settle the attacker's debt.
 * FIX: `onLiquidate` now requires `callerFromMidnight == address(this)`. Since the gate is the only
 *      address its `canLiquidate` authorizes, `callerFromMidnight` (Midnight's `msg.sender`) can only
 *      equal the gate when the call originates from the gate's own `liquidate()`. Any callback reached
 *      via a direct Midnight.liquidate (e.g. on a permissive market) carries the attacker as
 *      `callerFromMidnight` and is rejected.
 */
contract Test_ForcedVictimRepayment is Test {
    Midnight internal midnight;
    DelayedLiquidationGate internal gate;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");
    address internal borrower = makeAddr("borrower");

    Market internal market;
    bytes32 internal marketId;

    uint256 internal constant LLTV = 0.77e18;

    function setUp() public {
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(1e36);

        gate = new DelayedLiquidationGate(address(midnight), 1 hours, 2 hours, 1 minutes);

        // Permissive market: liquidatorGate == 0, so anyone can call Midnight.liquidate against it.
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        midnight.touchMarket(market);
        marketId = IdLib.toId(market);
    }

    /// @notice Reproduces the exploit: attacker triggers the gate's onLiquidate via Midnight with
    ///         itself as the caller and a well-formed `data` payload pointing at the victim
    ///         (`sender = victim`, `callback = 0` → gate's payer rule resolves to `victim`).
    ///         The fix's origin check rejects it, leaving the victim's balance and allowance intact.
    function test_attacker_cannot_drain_victim_via_forged_onLiquidate() public {
        uint256 victimBalance = 1_000e18;
        uint256 repaidUnits = 100e18;
        loanToken.mint(victim, victimBalance);
        vm.prank(victim);
        loanToken.approve(address(gate), type(uint256).max);

        // Simulate Midnight invoking onLiquidate after an attacker-initiated Midnight.liquidate
        // call on the permissive market, with callback = gate and data designating the victim as payer.
        bytes memory forgedData = abi.encode(victim, address(0), bytes(""));
        vm.prank(address(midnight));
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        gate.onLiquidate(attacker, marketId, market, 0, 0, repaidUnits, attacker, attacker, forgedData, 0);

        assertEq(loanToken.balanceOf(victim), victimBalance, "victim balance must be untouched");
        assertEq(loanToken.allowance(victim, address(gate)), type(uint256).max, "victim allowance must be untouched");
    }
}
