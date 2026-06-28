// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DelayedLiquidationGate} from "@gates/DelayedLiquidationGate.sol";
import {IDelayedLiquidationGate} from "@gates/interfaces/IDelayedLiquidationGate.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {IMidnight, Market, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

/// @dev Mock liquidator that implements onLiquidate so the gate can call back into it.
contract MockLiquidator {
    bool public callbackCalled;
    bytes public lastData;

    function onLiquidate(
        address,
        bytes32,
        Market memory,
        uint256,
        uint256,
        uint256,
        address,
        address,
        bytes memory data,
        uint256
    ) external returns (bytes32) {
        callbackCalled = true;
        lastData = data;
        return keccak256("morpho.midnight.callbackSuccess");
    }

    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }
}

/// @dev Mock liquidator that returns a wrong CALLBACK_SUCCESS magic value.
contract MockLiquidatorWrongReturn {
    function onLiquidate(
        address,
        bytes32,
        Market memory,
        uint256,
        uint256,
        uint256,
        address,
        address,
        bytes memory,
        uint256
    ) external pure returns (bytes32) {
        return bytes32(0);
    }

    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }
}

contract DelayedLiquidationGateTest is Test {
    Midnight internal morphoMidnight;
    DelayedLiquidationGate internal gate;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    MockLiquidator internal mockLiquidator;

    address internal liquidatorEOA = makeAddr("liquidatorEOA");
    address internal borrower = makeAddr("borrower");

    Market internal market;
    bytes32 internal marketId;

    uint256 internal constant GRACE_PERIOD = 1 hours;
    uint256 internal constant LIQUIDATION_PERIOD = 2 hours;
    uint256 internal constant LLTV = 0.77e18;
    uint256 internal constant MATURITY = 30 days;

    function setUp() public {
        morphoMidnight = new Midnight();
        enableDefaultLltvs(morphoMidnight);
        morphoMidnight.setFeeClaimer(address(this));

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(1e36);

        gate = new DelayedLiquidationGate(address(morphoMidnight), GRACE_PERIOD, LIQUIDATION_PERIOD, 1 minutes);
        mockLiquidator = new MockLiquidator();

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(morphoMidnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + MATURITY,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(gate)
        });

        morphoMidnight.touchMarket(market);
        marketId = IdLib.toId(market);
    }

    // ──────────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────────

    function _mockIsHealthy(bool healthy) internal {
        vm.mockCall(
            address(morphoMidnight),
            abi.encodeWithSelector(morphoMidnight.isHealthy.selector, market, marketId, borrower),
            abi.encode(healthy)
        );
    }

    function _getGracePeriodStart(address _borrower, bytes32 _marketId) internal view returns (uint256) {
        (uint56 timestamp,) = gate.gracePeriodInfo(_borrower, _marketId);
        return uint256(timestamp);
    }

    function _getPriorityLiquidator(address _borrower, bytes32 _marketId) internal view returns (address) {
        (, address _priorityLiquidator) = gate.gracePeriodInfo(_borrower, _marketId);
        return _priorityLiquidator;
    }

    function _startGracePeriod() internal {
        _mockIsHealthy(false);
        gate.startGracePeriod(marketId, borrower, address(0));
        vm.clearMockedCalls();
    }

    function _mockMidnightLiquidate() internal {
        vm.mockCall(
            address(morphoMidnight),
            abi.encodeWithSelector(morphoMidnight.liquidate.selector),
            abi.encode(uint256(1e18), uint256(1e18))
        );
    }

    function _callLiquidate() internal returns (uint256, uint256) {
        vm.prank(liquidatorEOA);
        return gate.liquidate(market, 0, 1e18, 0, borrower, false, liquidatorEOA, address(0), "");
    }

    /// @dev liquidate() seizing `seized` with no receiver/inner-callback. Caller must `vm.prank` (and
    ///      any `vm.expectRevert`) before calling, so those stay explicit at each site.
    function _liquidateNoCallback(uint256 seized) internal returns (uint256, uint256) {
        return gate.liquidate(market, 0, seized, 0, borrower, false, address(0), address(0), "");
    }

    /// @dev Mint loan tokens to the mockLiquidator, approve the gate, then invoke onLiquidate as Midnight.
    ///      Collateral delivery is handled by Midnight directly to `receiver`, so this helper mints no
    ///      collateral. Models the flash-liquidation path where the caller is itself the inner callback:
    ///      `mockLiquidator` is both the encoded `sender` (caller / loan-token payer) and `callback`
    ///      (inner-callback target), as enforced by liquidate()'s `callback == msg.sender` guard.
    function _callOnLiquidate(uint256 seized, uint256 repaid, bytes memory innerData) internal {
        if (repaid > 0) {
            loanToken.mint(address(mockLiquidator), repaid);
            mockLiquidator.approveToken(address(loanToken), address(gate), repaid);
        }

        bytes memory data = abi.encode(address(mockLiquidator), address(mockLiquidator), innerData);
        vm.prank(address(morphoMidnight));
        gate.onLiquidate(address(gate), marketId, market, 0, seized, repaid, borrower, address(mockLiquidator), data, 0);
    }

    // ──────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(address(gate.MORPHO_MIDNIGHT()), address(morphoMidnight));
        assertEq(gate.GRACE_PERIOD(), GRACE_PERIOD);
        assertEq(gate.LIQUIDATION_PERIOD(), LIQUIDATION_PERIOD);
    }

    // ──────────────────────────────────────────────────────────────
    //  canLiquidate
    // ──────────────────────────────────────────────────────────────

    function test_canLiquidate_trueForSelf() public view {
        assertTrue(gate.canLiquidate(address(gate)));
    }

    function test_canLiquidate_falseForOthers() public view {
        assertFalse(gate.canLiquidate(address(0)));
        assertFalse(gate.canLiquidate(liquidatorEOA));
        assertFalse(gate.canLiquidate(address(morphoMidnight)));
        assertFalse(gate.canLiquidate(address(this)));
    }

    // ──────────────────────────────────────────────────────────────
    //  startGracePeriod
    // ──────────────────────────────────────────────────────────────

    function test_startGracePeriod_storesTimestamp() public {
        _mockIsHealthy(false);
        gate.startGracePeriod(marketId, borrower, address(0));
        assertEq(_getGracePeriodStart(borrower, marketId), block.timestamp);
    }

    function test_startGracePeriod_emitsEvent() public {
        _mockIsHealthy(false);
        vm.expectEmit(true, true, false, true);
        emit IDelayedLiquidationGate.GracePeriodStarted(borrower, marketId, block.timestamp, address(0));
        gate.startGracePeriod(marketId, borrower, address(0));
    }

    function test_startGracePeriod_revertsIfHealthy() public {
        _mockIsHealthy(true);
        vm.expectRevert(IDelayedLiquidationGate.PositionIsHealthy.selector);
        gate.startGracePeriod(marketId, borrower, address(0));
    }

    function test_startGracePeriod_revertsIfActiveInGracePeriod() public {
        _startGracePeriod();
        vm.warp(block.timestamp + GRACE_PERIOD - 1);
        _mockIsHealthy(false);
        vm.expectRevert(IDelayedLiquidationGate.GracePeriodAlreadyActive.selector);
        gate.startGracePeriod(marketId, borrower, address(0));
    }

    function test_startGracePeriod_revertsIfActiveInLiquidationWindow() public {
        _startGracePeriod();
        vm.warp(block.timestamp + GRACE_PERIOD + LIQUIDATION_PERIOD - 1);
        _mockIsHealthy(false);
        vm.expectRevert(IDelayedLiquidationGate.GracePeriodAlreadyActive.selector);
        gate.startGracePeriod(marketId, borrower, address(0));
    }

    function test_startGracePeriod_canRestartAfterFullWindowExpires() public {
        uint256 startTime = block.timestamp;
        _startGracePeriod();
        assertEq(_getGracePeriodStart(borrower, marketId), startTime);

        vm.warp(startTime + GRACE_PERIOD + LIQUIDATION_PERIOD);

        _mockIsHealthy(false);
        gate.startGracePeriod(marketId, borrower, address(0));
        assertEq(_getGracePeriodStart(borrower, marketId), startTime + GRACE_PERIOD + LIQUIDATION_PERIOD);
    }

    function test_startGracePeriod_cannotRestartOneSecondBeforeExpiry() public {
        uint256 startTime = block.timestamp;
        _startGracePeriod();

        vm.warp(startTime + GRACE_PERIOD + LIQUIDATION_PERIOD - 1);
        _mockIsHealthy(false);
        vm.expectRevert(IDelayedLiquidationGate.GracePeriodAlreadyActive.selector);
        gate.startGracePeriod(marketId, borrower, address(0));
    }

    // ──────────────────────────────────────────────────────────────
    //  _requireLiquidationAllowed (tested via liquidate())
    // ──────────────────────────────────────────────────────────────

    function test_liquidate_revertsPreMaturity_noGracePeriod() public {
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        _callLiquidate();
    }

    function test_liquidate_revertsPreMaturity_duringGracePeriod() public {
        _startGracePeriod();
        vm.warp(block.timestamp + GRACE_PERIOD - 1);
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        _callLiquidate();
    }

    function test_liquidate_allowedPreMaturity_exactlyAtGracePeriodEnd() public {
        uint256 start = block.timestamp;
        _startGracePeriod();
        vm.warp(start + GRACE_PERIOD);
        _mockMidnightLiquidate();
        _callLiquidate();
    }

    function test_liquidate_allowedPreMaturity_midLiquidationWindow() public {
        uint256 start = block.timestamp;
        _startGracePeriod();
        vm.warp(start + GRACE_PERIOD + LIQUIDATION_PERIOD / 2);
        _mockMidnightLiquidate();
        _callLiquidate();
    }

    function test_liquidate_allowedPreMaturity_lastSecondOfWindow() public {
        uint256 start = block.timestamp;
        _startGracePeriod();
        vm.warp(start + GRACE_PERIOD + LIQUIDATION_PERIOD - 1);
        _mockMidnightLiquidate();
        _callLiquidate();
    }

    function test_liquidate_revertsPreMaturity_exactlyAtWindowClose() public {
        uint256 start = block.timestamp;
        _startGracePeriod();
        vm.warp(start + GRACE_PERIOD + LIQUIDATION_PERIOD);
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        _callLiquidate();
    }

    function test_liquidate_revertsPreMaturity_longAfterWindowClose() public {
        _startGracePeriod();
        vm.warp(block.timestamp + GRACE_PERIOD + LIQUIDATION_PERIOD + 1 days);
        assertTrue(block.timestamp <= market.maturity);
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        _callLiquidate();
    }

    function test_liquidate_revertsAtExactMaturity_noGracePeriod() public {
        vm.warp(market.maturity);
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        _callLiquidate();
    }

    /// @dev Start grace period close enough to maturity that the liquidation window
    ///      spans the exact maturity timestamp. Verifies timing is still enforced at maturity (<=).
    function test_liquidate_allowedAtExactMaturity_withValidWindow() public {
        // Warp so grace period starts GRACE_PERIOD before maturity,
        // putting maturity exactly at the start of the liquidation window.
        vm.warp(market.maturity - GRACE_PERIOD);
        _startGracePeriod();
        vm.warp(market.maturity);

        _mockMidnightLiquidate();
        _callLiquidate();
    }

    /// @dev After restart, the old window is dead and the new window is used.
    function test_liquidate_revertsPreMaturity_oldWindowAfterRestart() public {
        // Grace period 1 starts at t=1 (default Forge timestamp).
        // Window 1: [1+GP, 1+GP+LP) = [3601, 10801).
        _startGracePeriod();

        // Warp to t=10801 — window 1 expired. Restart.
        vm.warp(10801);
        _startGracePeriod();

        // Still at t=10801 — elapsed from new start = 0 < GP → revert
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        _callLiquidate();
    }

    /// @dev After restart, liquidation succeeds in the new window.
    function test_liquidate_allowedPreMaturity_newWindowAfterRestart() public {
        // Grace period 1 starts at t=1.
        _startGracePeriod();

        // Warp to t=10801 — window 1 expired. Restart.
        // Grace period 2 starts at t=10801.
        // Window 2: [10801+3600, 10801+10800) = [14401, 21601).
        vm.warp(10801);
        _startGracePeriod();

        // Warp into window 2.
        vm.warp(14401);
        _mockMidnightLiquidate();
        _callLiquidate();
    }

    function test_liquidate_allowedPostMaturity_noGracePeriod() public {
        vm.warp(market.maturity + 1);
        _mockMidnightLiquidate();
        _callLiquidate();
    }

    function test_liquidate_allowedPostMaturity_expiredWindow() public {
        _startGracePeriod();
        vm.warp(market.maturity + 1);
        _mockMidnightLiquidate();
        _callLiquidate();
    }

    // ──────────────────────────────────────────────────────────────
    //  Priority liquidator
    // ──────────────────────────────────────────────────────────────

    function _startGracePeriodWithPriority(address _priority) internal {
        _mockIsHealthy(false);
        gate.startGracePeriod(marketId, borrower, _priority);
        vm.clearMockedCalls();
    }

    function test_priorityLiquidator_storesPriorityAddress() public {
        _startGracePeriodWithPriority(liquidatorEOA);
        assertEq(_getPriorityLiquidator(borrower, marketId), liquidatorEOA);
    }

    function test_priorityLiquidator_onlyPriorityCanLiquidateDuringPriorityPeriod() public {
        _startGracePeriodWithPriority(liquidatorEOA);
        vm.warp(block.timestamp + GRACE_PERIOD);
        _mockMidnightLiquidate();

        // Priority liquidator succeeds
        vm.prank(liquidatorEOA);
        _liquidateNoCallback(1e18);
    }

    function test_priorityLiquidator_nonPriorityRevertsInPriorityPeriod() public {
        _startGracePeriodWithPriority(liquidatorEOA);
        vm.warp(block.timestamp + GRACE_PERIOD);

        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        _liquidateNoCallback(1e18);
    }

    function test_priorityLiquidator_nonPriorityRevertsAtLastSecondOfPriorityPeriod() public {
        _startGracePeriodWithPriority(liquidatorEOA);
        vm.warp(block.timestamp + GRACE_PERIOD + gate.PRIORITY_PERIOD() - 1);

        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        _liquidateNoCallback(1e18);
    }

    function test_priorityLiquidator_anyoneCanLiquidateAfterPriorityPeriod() public {
        _startGracePeriodWithPriority(liquidatorEOA);
        vm.warp(block.timestamp + GRACE_PERIOD + gate.PRIORITY_PERIOD());
        _mockMidnightLiquidate();

        address other = makeAddr("other");
        vm.prank(other);
        _liquidateNoCallback(1e18);
    }

    function test_priorityLiquidator_zeroAddressMeansNoPriority() public {
        _startGracePeriodWithPriority(address(0));
        vm.warp(block.timestamp + GRACE_PERIOD);
        _mockMidnightLiquidate();

        address other = makeAddr("other");
        vm.prank(other);
        _liquidateNoCallback(1e18);
    }

    function test_priorityLiquidator_updatedOnRestart() public {
        address first = makeAddr("first");
        address second = makeAddr("second");

        _startGracePeriodWithPriority(first);
        assertEq(_getPriorityLiquidator(borrower, marketId), first);

        vm.warp(block.timestamp + GRACE_PERIOD + LIQUIDATION_PERIOD);
        _startGracePeriodWithPriority(second);
        assertEq(_getPriorityLiquidator(borrower, marketId), second);
    }

    function test_priorityLiquidator_noPriorityEnforcedPostMaturity() public {
        _startGracePeriodWithPriority(liquidatorEOA);
        vm.warp(market.maturity + 1);
        _mockMidnightLiquidate();

        address other = makeAddr("other");
        vm.prank(other);
        _liquidateNoCallback(1e18);
    }

    function test_priorityLiquidator_canStillLiquidateAfterPriorityPeriod() public {
        _startGracePeriodWithPriority(liquidatorEOA);
        vm.warp(block.timestamp + GRACE_PERIOD + gate.PRIORITY_PERIOD());
        _mockMidnightLiquidate();

        vm.prank(liquidatorEOA);
        _liquidateNoCallback(1e18);
    }

    function test_priorityLiquidator_enforcedOnRestartNewWindow() public {
        address first = makeAddr("first");
        address second = makeAddr("second");

        _startGracePeriodWithPriority(first);

        // Warp past full window so restart is allowed
        vm.warp(block.timestamp + GRACE_PERIOD + LIQUIDATION_PERIOD);
        _startGracePeriodWithPriority(second);

        // Read the actual stored start and warp into new window's priority period
        uint256 newGraceStart = _getGracePeriodStart(borrower, marketId);
        vm.warp(newGraceStart + GRACE_PERIOD);
        _mockMidnightLiquidate();

        // Old priority liquidator blocked during new window's priority period
        vm.prank(first);
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        _liquidateNoCallback(1e18);

        // New priority liquidator succeeds
        vm.prank(second);
        _liquidateNoCallback(1e18);
    }

    function test_priorityLiquidator_gateAddressBlocksEveryone() public {
        _startGracePeriodWithPriority(address(gate));
        vm.warp(block.timestamp + GRACE_PERIOD);

        // Nobody can be msg.sender == address(gate) in liquidate(), so everyone is blocked
        vm.prank(liquidatorEOA);
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        _liquidateNoCallback(1e18);

        // After priority period, anyone can liquidate
        vm.warp(block.timestamp + gate.PRIORITY_PERIOD());
        _mockMidnightLiquidate();
        vm.prank(liquidatorEOA);
        _liquidateNoCallback(1e18);
    }

    // ──────────────────────────────────────────────────────────────
    //  Multiple partial liquidations in same window
    // ──────────────────────────────────────────────────────────────

    function test_liquidate_multiplePartialLiquidationsInSameWindow() public {
        _startGracePeriod();
        vm.warp(block.timestamp + GRACE_PERIOD + gate.PRIORITY_PERIOD());
        _mockMidnightLiquidate();

        _callLiquidate();
        _callLiquidate();
    }

    function test_liquidate_partialLiquidationsDuringAndAfterPriorityPeriod() public {
        _startGracePeriodWithPriority(liquidatorEOA);
        vm.warp(block.timestamp + GRACE_PERIOD);
        _mockMidnightLiquidate();

        // Priority liquidator does first partial liquidation
        vm.prank(liquidatorEOA);
        _liquidateNoCallback(0.5e18);

        // After priority period, anyone can do a second partial
        vm.warp(block.timestamp + gate.PRIORITY_PERIOD());
        address other = makeAddr("other");
        vm.prank(other);
        _liquidateNoCallback(0.5e18);
    }

    // ──────────────────────────────────────────────────────────────
    //  Return value passthrough
    // ──────────────────────────────────────────────────────────────

    function test_liquidate_forwardsReturnValues() public {
        _startGracePeriod();
        vm.warp(block.timestamp + GRACE_PERIOD + gate.PRIORITY_PERIOD());

        vm.mockCall(
            address(morphoMidnight),
            abi.encodeWithSelector(morphoMidnight.liquidate.selector),
            abi.encode(uint256(42e18), uint256(7e18))
        );

        vm.prank(liquidatorEOA);
        (uint256 seized, uint256 repaid) = _liquidateNoCallback(1e18);
        assertEq(seized, 42e18);
        assertEq(repaid, 7e18);
    }

    // ──────────────────────────────────────────────────────────────
    //  Mapping isolation
    // ──────────────────────────────────────────────────────────────

    function test_gracePeriod_independentPerBorrower() public {
        address borrower2 = makeAddr("borrower2");

        // Start grace period for borrower1
        _startGracePeriod();
        assertEq(_getGracePeriodStart(borrower, marketId), block.timestamp);

        // borrower2 has no grace period
        assertEq(_getGracePeriodStart(borrower2, marketId), 0);
    }

    function test_priorityLiquidator_independentPerBorrower() public {
        address borrower2 = makeAddr("borrower2");

        _startGracePeriodWithPriority(liquidatorEOA);
        assertEq(_getPriorityLiquidator(borrower, marketId), liquidatorEOA);
        assertEq(_getPriorityLiquidator(borrower2, marketId), address(0));
    }

    // ──────────────────────────────────────────────────────────────
    //  onLiquidate — access control
    // ──────────────────────────────────────────────────────────────

    function test_onLiquidate_revertsIfNotMidnight() public {
        vm.prank(liquidatorEOA);
        vm.expectRevert(IDelayedLiquidationGate.NotMorpho.selector);
        gate.onLiquidate(address(gate), marketId, market, 0, 1e18, 1e18, borrower, address(mockLiquidator), "", 0);
    }

    function test_onLiquidate_acceptsCallFromMidnight() public {
        _callOnLiquidate(5e18, 4e18, bytes(""));
    }

    function test_onLiquidate_revertsIfCallerFromMidnightNotGate() public {
        vm.prank(address(morphoMidnight));
        vm.expectRevert(IDelayedLiquidationGate.LiquidationNotAllowed.selector);
        gate.onLiquidate(liquidatorEOA, marketId, market, 0, 1e18, 1e18, borrower, address(mockLiquidator), "", 0);
    }

    // ──────────────────────────────────────────────────────────────
    //  onLiquidate — inner callback (mirrors Midnight: fires iff callback != 0)
    // ──────────────────────────────────────────────────────────────

    function test_onLiquidate_callsCallbackWithDataWhenCallbackSet() public {
        bytes memory innerData = hex"deadbeef";
        _callOnLiquidate(5e18, 4e18, innerData);
        assertTrue(mockLiquidator.callbackCalled());
        assertEq(mockLiquidator.lastData(), innerData);
    }

    function test_onLiquidate_skipsCallbackWhenCallbackIsZero() public {
        // sender = liquidatorEOA (the would-be payer), callback = 0 (no inner callback).
        loanToken.mint(liquidatorEOA, 4e18);
        vm.prank(liquidatorEOA);
        loanToken.approve(address(gate), 4e18);

        bytes memory data = abi.encode(liquidatorEOA, address(0), bytes(""));
        vm.prank(address(morphoMidnight));
        gate.onLiquidate(address(gate), marketId, market, 0, 5e18, 4e18, borrower, liquidatorEOA, data, 0);

        assertFalse(mockLiquidator.callbackCalled());
    }

    function test_onLiquidate_revertsWhenCallbackReturnsWrongBytes32() public {
        MockLiquidatorWrongReturn badLiquidator = new MockLiquidatorWrongReturn();
        loanToken.mint(address(badLiquidator), 4e18);
        badLiquidator.approveToken(address(loanToken), address(gate), 4e18);

        bytes memory data = abi.encode(address(badLiquidator), address(badLiquidator), hex"deadbeef");
        vm.prank(address(morphoMidnight));
        vm.expectRevert(IMidnight.WrongLiquidateCallbackReturnValue.selector);
        gate.onLiquidate(address(gate), marketId, market, 0, 5e18, 4e18, borrower, address(badLiquidator), data, 0);
    }

    // ──────────────────────────────────────────────────────────────
    //  onLiquidate — loan-token repayment is always pulled from the caller (`sender`)
    // ──────────────────────────────────────────────────────────────

    function test_onLiquidate_pullsFromCallbackWhenCallbackSet() public {
        _callOnLiquidate(0, 7e18, bytes(""));
        assertEq(loanToken.balanceOf(address(mockLiquidator)), 0);
        assertEq(loanToken.balanceOf(address(gate)), 7e18);
    }

    function test_onLiquidate_pullsFromSenderWhenCallbackIsZero() public {
        loanToken.mint(liquidatorEOA, 7e18);
        vm.prank(liquidatorEOA);
        loanToken.approve(address(gate), 7e18);

        bytes memory data = abi.encode(liquidatorEOA, address(0), bytes(""));
        vm.prank(address(morphoMidnight));
        gate.onLiquidate(address(gate), marketId, market, 0, 0, 7e18, borrower, liquidatorEOA, data, 0);

        assertEq(loanToken.balanceOf(liquidatorEOA), 0);
        assertEq(loanToken.balanceOf(address(gate)), 7e18);
    }

    function test_onLiquidate_approvesMidnightForLoanTokens() public {
        _callOnLiquidate(0, 7e18, bytes(""));
        assertEq(loanToken.allowance(address(gate), address(morphoMidnight)), 7e18);
    }

    function test_onLiquidate_skipsLoanTokenPullWhenZeroRepaid() public {
        _callOnLiquidate(3e18, 0, bytes(""));
        assertEq(loanToken.balanceOf(address(gate)), 0);
        assertEq(loanToken.allowance(address(gate), address(morphoMidnight)), 0);
    }

    // ──────────────────────────────────────────────────────────────
    //  liquidate() — Midnight call shape
    // ──────────────────────────────────────────────────────────────

    function test_liquidate_forwardsReceiverAndEncodesCallback() public {
        _startGracePeriod();
        vm.warp(block.timestamp + GRACE_PERIOD);

        bytes memory userData = hex"1234";
        address receiver = makeAddr("collateralReceiver");
        // callback must be the caller (or zero); it is encoded into data, distinct from receiver.
        address callback = liquidatorEOA;
        bytes memory expectedData = abi.encode(liquidatorEOA, callback, userData);

        vm.expectCall(
            address(morphoMidnight),
            abi.encodeCall(
                morphoMidnight.liquidate, (market, 0, 1e18, 0, borrower, false, receiver, address(gate), expectedData)
            )
        );
        _mockMidnightLiquidate();

        vm.prank(liquidatorEOA);
        gate.liquidate(market, 0, 1e18, 0, borrower, false, receiver, callback, userData);
    }

    function test_liquidate_revertsWhenCallbackNotCaller() public {
        _startGracePeriod();
        vm.warp(block.timestamp + GRACE_PERIOD);

        address otherCallback = makeAddr("thirdParty");

        vm.prank(liquidatorEOA);
        vm.expectRevert(IDelayedLiquidationGate.InvalidCallback.selector);
        gate.liquidate(market, 0, 1e18, 0, borrower, false, liquidatorEOA, otherCallback, "");
    }

    function test_liquidate_forwardsHealthyPathTrue() public {
        // Post-maturity: gate is permissionless passthrough. postMaturityMode=true must reach Midnight unchanged.
        vm.warp(market.maturity + 1);

        bytes memory userData = hex"5678";
        bytes memory expectedData = abi.encode(liquidatorEOA, address(0), userData);

        vm.expectCall(
            address(morphoMidnight),
            abi.encodeCall(
                morphoMidnight.liquidate,
                (market, 0, 1e18, 0, borrower, true, liquidatorEOA, address(gate), expectedData)
            )
        );
        _mockMidnightLiquidate();

        vm.prank(liquidatorEOA);
        gate.liquidate(market, 0, 1e18, 0, borrower, true, liquidatorEOA, address(0), userData);
    }
}
