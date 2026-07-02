// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TenorAdapter} from "../../src/bundler/TenorAdapter.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EventsLib} from "@midnight/libraries/EventsLib.sol";
import {IBundler3, Call} from "@bundler3/interfaces/IBundler3.sol";
import {IMidnight, Market, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {Fixtures} from "../helpers/Fixtures.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

contract TenorAdapterTestBase is Fixtures {
    TenorAdapter internal adapter;
    Midnight internal midnight;
    IBundler3 internal bundler3;

    address internal user;
    address internal unauthorized;

    function setUp() public virtual {
        user = makeAddr("User");
        unauthorized = makeAddr("Unauthorized");

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        bundler3 = deployBundler3();
        adapter = new TenorAdapter(address(bundler3), address(midnight), makeAddr("Ratifier"));

        vm.prank(user);
        midnight.setIsAuthorized(address(adapter), true, user);
    }

    function _makeCall(bytes memory data) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({to: address(adapter), data: data, value: 0, skipRevert: false, callbackHash: bytes32(0)});
    }
}

contract TenorAdapterSetConsumedTest is TenorAdapterTestBase {
    bytes32 internal constant GROUP = keccak256("test-group");
    uint128 internal constant AMOUNT = 100e18;

    function test_midnightSetConsumed_viaBundler() public {
        vm.prank(user);
        bundler3.multicall(_makeCall(abi.encodeCall(adapter.midnightSetConsumed, (GROUP, AMOUNT))));
        assertEq(midnight.consumed(user, GROUP), AMOUNT);
    }

    function test_midnightSetConsumed_emitsEvent() public {
        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit EventsLib.SetConsumed(address(adapter), GROUP, AMOUNT, user);
        bundler3.multicall(_makeCall(abi.encodeCall(adapter.midnightSetConsumed, (GROUP, AMOUNT))));
    }

    function test_midnightSetConsumed_unauthorizedInitiator() public {
        vm.prank(unauthorized);
        vm.expectRevert(IMidnight.Unauthorized.selector);
        bundler3.multicall(_makeCall(abi.encodeCall(adapter.midnightSetConsumed, (GROUP, AMOUNT))));
    }

    function test_midnightSetConsumed_onlyBundler() public {
        vm.prank(user);
        vm.expectRevert();
        adapter.midnightSetConsumed(GROUP, AMOUNT);
    }

    function test_midnightSetConsumed_canIncrease() public {
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            to: address(adapter),
            data: abi.encodeCall(adapter.midnightSetConsumed, (GROUP, AMOUNT)),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        calls[1] = Call({
            to: address(adapter),
            data: abi.encodeCall(adapter.midnightSetConsumed, (GROUP, AMOUNT * 2)),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });

        vm.prank(user);
        bundler3.multicall(calls);
        assertEq(midnight.consumed(user, GROUP), AMOUNT * 2);
    }

    function testFuzz_midnightSetConsumed(bytes32 group, uint128 amount) public {
        vm.prank(user);
        bundler3.multicall(_makeCall(abi.encodeCall(adapter.midnightSetConsumed, (group, amount))));
        assertEq(midnight.consumed(user, group), amount);
    }

    /// @dev Midnight tracks `consumed` as uint128; calldata carrying a larger amount must be rejected
    ///      at ABI decoding of the `uint128` parameter.
    function testFuzz_midnightSetConsumed_overUint128Reverts(bytes32 group, uint256 amount) public {
        amount = bound(amount, uint256(type(uint128).max) + 1, type(uint256).max);
        vm.prank(user);
        vm.expectRevert();
        bundler3.multicall(_makeCall(abi.encodeWithSelector(adapter.midnightSetConsumed.selector, group, amount)));
    }
}

/// @dev Regression tests for audit M-04: `midnightSupplyCollateral` must pin `onBehalf` to
///      `initiator()` so an attacker cannot activate bitmap slots on a victim's market via
///      the adapter authorization.
contract TenorAdapterSupplyCollateralTest is TenorAdapterTestBase {
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    Market internal market;
    bytes32 internal marketId;

    uint256 internal constant SUPPLY = 1e18;

    function setUp() public override {
        super.setUp();

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(10e36);

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        marketId = IdLib.toId(market);
    }

    function _supplyCall(uint256 assets) internal view returns (Call[] memory) {
        return _makeCall(abi.encodeCall(adapter.midnightSupplyCollateral, (market, 0, assets)));
    }

    function test_midnightSupplyCollateral_suppliesForInitiator() public {
        collateralToken.mint(address(adapter), SUPPLY);

        vm.prank(user);
        bundler3.multicall(_supplyCall(SUPPLY));

        assertEq(midnight.collateral(marketId, user, 0), SUPPLY);
    }

    function test_midnightSupplyCollateral_griefingPrevented() public {
        address attacker = makeAddr("Attacker");
        collateralToken.mint(address(adapter), SUPPLY);

        vm.prank(attacker);
        midnight.setIsAuthorized(address(adapter), true, attacker);

        vm.prank(attacker);
        bundler3.multicall(_supplyCall(SUPPLY));

        assertEq(midnight.collateral(marketId, user, 0), 0, "victim bitmap not griefed");
        assertEq(midnight.collateral(marketId, attacker, 0), SUPPLY, "supply landed on initiator");
    }

    function test_midnightSupplyCollateral_unauthorizedInitiator_reverts() public {
        collateralToken.mint(address(adapter), SUPPLY);

        vm.prank(unauthorized);
        vm.expectRevert(IMidnight.Unauthorized.selector);
        bundler3.multicall(_supplyCall(SUPPLY));
    }

    function test_midnightSupplyCollateral_onlyBundler() public {
        vm.prank(user);
        vm.expectRevert();
        adapter.midnightSupplyCollateral(market, 0, SUPPLY);
    }

    function test_midnightSupplyCollateral_maxSentinel_usesAdapterBalance() public {
        collateralToken.mint(address(adapter), SUPPLY);

        vm.prank(user);
        bundler3.multicall(_supplyCall(type(uint256).max));

        assertEq(midnight.collateral(marketId, user, 0), SUPPLY);
        assertEq(collateralToken.balanceOf(address(adapter)), 0);
    }

    function test_midnightSupplyCollateral_zeroAmount_reverts() public {
        vm.prank(user);
        vm.expectRevert();
        bundler3.multicall(_supplyCall(0));
    }
}

/// @dev Regression tests: `midnightRepay` must pin `onBehalf` to `initiator()` so an attacker
///      cannot trigger a 1-wei repay on a victim's market via the adapter authorization.
contract TenorAdapterRepayTest is TenorAdapterTestBase {
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    Market internal market;

    uint256 internal constant REPAY_UNITS = 1;

    function setUp() public override {
        super.setUp();

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(10e36);

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _repayCall(uint256 assets, uint256 debt) internal view returns (Call[] memory) {
        return _makeCall(abi.encodeCall(adapter.midnightRepay, (market, assets, debt, address(0), "")));
    }

    function test_midnightRepay_targetsInitiator() public {
        loanToken.mint(address(adapter), REPAY_UNITS);

        vm.expectCall(address(midnight), abi.encodeCall(IMidnight.repay, (market, REPAY_UNITS, user, address(0), "")));
        vm.prank(user);
        vm.expectRevert();
        bundler3.multicall(_repayCall(REPAY_UNITS, 0));
    }

    function test_midnightRepay_griefingPrevented() public {
        address attacker = makeAddr("Attacker");
        loanToken.mint(address(adapter), REPAY_UNITS);

        vm.prank(attacker);
        midnight.setIsAuthorized(address(adapter), true, attacker);

        vm.expectCall(
            address(midnight), abi.encodeCall(IMidnight.repay, (market, REPAY_UNITS, attacker, address(0), ""))
        );
        vm.prank(attacker);
        vm.expectRevert();
        bundler3.multicall(_repayCall(REPAY_UNITS, 0));
    }

    function test_midnightRepay_zeroUnits_noOp() public {
        vm.prank(user);
        bundler3.multicall(_repayCall(0, 0));
    }

    function test_midnightRepay_onlyBundler() public {
        vm.prank(user);
        vm.expectRevert();
        adapter.midnightRepay(market, REPAY_UNITS, 0, address(0), "");
    }
}

/// @dev `midnightWithdraw`/`midnightWithdrawCollateral` forward a caller-chosen `receiver`: an
///      external address delivers funds straight to the user, while `address(this)` keeps them on
///      the adapter for a following bundle action.
contract TenorAdapterWithdrawTest is TenorAdapterTestBase {
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    Market internal market;
    bytes32 internal marketId;

    address internal receiver;

    uint256 internal constant AMOUNT = 1e18;

    function setUp() public override {
        super.setUp();
        receiver = makeAddr("Receiver");

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(10e36);

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        marketId = IdLib.toId(market);

        // Seed a collateral position for the initiator to withdraw against.
        collateralToken.mint(address(adapter), AMOUNT);
        vm.prank(user);
        bundler3.multicall(_makeCall(abi.encodeCall(adapter.midnightSupplyCollateral, (market, 0, AMOUNT))));
    }

    function _withdrawCollateralCall(uint256 assets, address to) internal view returns (Call[] memory) {
        return _makeCall(abi.encodeCall(adapter.midnightWithdrawCollateral, (market, 0, assets, to)));
    }

    function test_midnightWithdrawCollateral_toExternalReceiver_deliversToUser() public {
        vm.prank(user);
        bundler3.multicall(_withdrawCollateralCall(AMOUNT, receiver));

        assertEq(collateralToken.balanceOf(receiver), AMOUNT, "receiver got the collateral");
        assertEq(collateralToken.balanceOf(address(adapter)), 0, "nothing parked on the adapter");
        assertEq(midnight.collateral(marketId, user, 0), 0, "position withdrawn in full");
    }

    function test_midnightWithdrawCollateral_toAdapter_keepsForChaining() public {
        vm.prank(user);
        bundler3.multicall(_withdrawCollateralCall(AMOUNT, address(adapter)));

        assertEq(collateralToken.balanceOf(address(adapter)), AMOUNT, "collateral retained on adapter for chaining");
        assertEq(collateralToken.balanceOf(receiver), 0);
    }

    function test_midnightWithdraw_forwardsReceiver() public {
        // No credit position, so the underlying call reverts — but the receiver must still be the
        // one forwarded to Midnight, not a hardcoded address.
        vm.expectCall(address(midnight), abi.encodeCall(IMidnight.withdraw, (market, AMOUNT, user, receiver)));
        vm.prank(user);
        vm.expectRevert();
        bundler3.multicall(_makeCall(abi.encodeCall(adapter.midnightWithdraw, (market, AMOUNT, receiver))));
    }

    function test_midnightWithdrawCollateral_onlyBundler() public {
        vm.prank(user);
        vm.expectRevert();
        adapter.midnightWithdrawCollateral(market, 0, AMOUNT, receiver);
    }
}
