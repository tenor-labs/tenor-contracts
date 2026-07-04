// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TenorAdapter} from "../../src/bundler/TenorAdapter.sol";
import {MigrationRatifier} from "../../src/ratifiers/MigrationRatifier.sol";
import {IMigrationRatifier} from "../../src/ratifiers/interfaces/IMigrationRatifier.sol";
import {IMidnightAdapter} from "../../src/bundler/interfaces/IMidnightAdapter.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EventsLib} from "@midnight/libraries/EventsLib.sol";
import {ErrorsLib} from "@bundler3/libraries/ErrorsLib.sol";
import {IBundler3, Call} from "@bundler3/interfaces/IBundler3.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {IRatifier} from "@midnight/interfaces/IRatifier.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {CALLBACK_SUCCESS, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {Fixtures} from "../helpers/Fixtures.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

contract RatifyAllRatifier is IRatifier {
    function isRatified(Offer memory, bytes memory, address) external pure returns (bytes32) {
        return CALLBACK_SUCCESS;
    }
}

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
        adapter = _deployAdapter();

        vm.prank(user);
        midnight.setIsAuthorized(address(adapter), true, user);
    }

    function _deployAdapter() internal virtual returns (TenorAdapter) {
        return new TenorAdapter(address(bundler3), address(midnight), makeAddr("Ratifier"));
    }

    function _makeCall(bytes memory data) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({to: address(adapter), data: data, value: 0, skipRevert: false, callbackHash: bytes32(0)});
    }
}

abstract contract TenorAdapterMarketTestBase is TenorAdapterTestBase {
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    Market internal market;
    bytes32 internal marketId;

    function setUp() public virtual override {
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
}

contract TenorAdapterConstructorTest is TenorAdapterTestBase {
    function test_constructor_revertsZeroRatifier() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TenorAdapter(address(bundler3), address(midnight), address(0));
    }

    function test_constructor_setsRatifier() public {
        address ratifier = makeAddr("RealRatifier");
        TenorAdapter fresh = new TenorAdapter(address(bundler3), address(midnight), ratifier);
        assertEq(address(fresh.RATIFIER()), ratifier);
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
contract TenorAdapterSupplyCollateralTest is TenorAdapterMarketTestBase {
    uint256 internal constant SUPPLY = 1e18;

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
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        bundler3.multicall(_supplyCall(0));
    }
}

/// @dev Regression tests: `midnightRepay` must pin `onBehalf` to `initiator()` so an attacker
///      cannot trigger a 1-wei repay on a victim's market via the adapter authorization.
contract TenorAdapterRepayTest is TenorAdapterMarketTestBase {
    uint256 internal constant REPAY_UNITS = 1;

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
contract TenorAdapterWithdrawTest is TenorAdapterMarketTestBase {
    address internal receiver;

    uint256 internal constant AMOUNT = 1e18;

    function setUp() public override {
        super.setUp();
        receiver = makeAddr("Receiver");

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

    function test_midnightWithdrawCollateral_maxSentinel_withdrawsFullPosition() public {
        vm.prank(user);
        bundler3.multicall(_withdrawCollateralCall(type(uint256).max, receiver));

        assertEq(collateralToken.balanceOf(receiver), AMOUNT, "receiver got the full collateral");
        assertEq(midnight.collateral(marketId, user, 0), 0, "position withdrawn in full");
    }

    function test_midnightWithdrawCollateral_zeroAmount_reverts() public {
        vm.prank(user);
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        bundler3.multicall(_withdrawCollateralCall(0, receiver));
    }

    function test_midnightWithdraw_zeroAmount_reverts() public {
        vm.prank(user);
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        bundler3.multicall(_makeCall(abi.encodeCall(adapter.midnightWithdraw, (market, 0, receiver))));
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

contract TenorAdapterMigrationParamsTest is TenorAdapterTestBase {
    MigrationRatifier internal ratifier;

    address internal callback;
    address internal ratePolicy;

    bytes32 internal constant SOURCE_ID = keccak256("source-tenor-market");
    bytes32 internal constant TARGET_ID = keccak256("target-tenor-market");

    function setUp() public override {
        super.setUp();

        callback = makeAddr("Callback");
        ratePolicy = makeAddr("RatePolicy");
    }

    function _deployAdapter() internal override returns (TenorAdapter) {
        ratifier = new MigrationRatifier(
            address(midnight),
            makeAddr("BorrowMidnightRenewalCallback"),
            makeAddr("BorrowBlueToMidnightCallback"),
            makeAddr("LendVaultToMidnightCallback"),
            makeAddr("BorrowMidnightToBlueCallback"),
            makeAddr("LendMidnightToVaultCallback"),
            makeAddr("LendMidnightRenewalCallback"),
            address(this)
        );
        return new TenorAdapter(address(bundler3), address(midnight), address(ratifier));
    }

    function _params() internal view returns (IMigrationRatifier.UserMigrationParams memory) {
        return IMigrationRatifier.UserMigrationParams({
            interestRatePolicy: ratePolicy,
            renewalWindow: uint32(7 days),
            minDuration: uint32(7 days),
            maxDuration: uint32(365 days),
            renewalCadence: address(0),
            limitRatePerSecond: type(uint40).max
        });
    }

    function _setParamsCall() internal view returns (Call[] memory) {
        return _makeCall(abi.encodeCall(adapter.migrationSetParams, (callback, SOURCE_ID, TARGET_ID, _params())));
    }

    function _clearParamsCall() internal view returns (Call[] memory) {
        return _makeCall(abi.encodeCall(adapter.migrationClearParams, (callback, SOURCE_ID, TARGET_ID)));
    }

    function test_migrationSetParams_storesForInitiator() public {
        vm.prank(user);
        bundler3.multicall(_setParamsCall());

        (
            address interestRatePolicy,
            uint32 renewalWindow,
            uint32 minDuration,
            uint32 maxDuration,
            address renewalCadence,
            uint40 limitRatePerSecond
        ) = ratifier.userParams(user, callback, SOURCE_ID, TARGET_ID);
        assertEq(interestRatePolicy, ratePolicy);
        assertEq(renewalWindow, uint32(7 days));
        assertEq(minDuration, uint32(7 days));
        assertEq(maxDuration, uint32(365 days));
        assertEq(renewalCadence, address(0));
        assertEq(limitRatePerSecond, type(uint40).max);

        (address adapterPolicy,,,,,) = ratifier.userParams(address(adapter), callback, SOURCE_ID, TARGET_ID);
        assertEq(adapterPolicy, address(0), "params keyed by initiator, not adapter");
    }

    function test_migrationSetParams_pinsOnBehalfToInitiator() public {
        address attacker = makeAddr("Attacker");

        vm.prank(attacker);
        midnight.setIsAuthorized(address(adapter), true, attacker);

        vm.prank(attacker);
        bundler3.multicall(_setParamsCall());

        (address victimPolicy,,,,,) = ratifier.userParams(user, callback, SOURCE_ID, TARGET_ID);
        (address attackerPolicy,,,,,) = ratifier.userParams(attacker, callback, SOURCE_ID, TARGET_ID);
        assertEq(victimPolicy, address(0), "victim params untouched");
        assertEq(attackerPolicy, ratePolicy, "params landed on initiator");
    }

    function test_migrationSetParams_emitsEvent() public {
        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(ratifier));
        emit IMigrationRatifier.ParamsSet(user, callback, SOURCE_ID, TARGET_ID, _params());
        bundler3.multicall(_setParamsCall());
    }

    function test_migrationSetParams_unauthorizedInitiator_ratifierReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(IMigrationRatifier.Unauthorized.selector);
        bundler3.multicall(_setParamsCall());
    }

    function test_migrationSetParams_onlyBundler() public {
        vm.prank(user);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        adapter.migrationSetParams(callback, SOURCE_ID, TARGET_ID, _params());
    }

    function test_migrationClearParams_clearsInitiatorParams() public {
        vm.prank(user);
        bundler3.multicall(_setParamsCall());

        vm.prank(user);
        bundler3.multicall(_clearParamsCall());

        (
            address interestRatePolicy,
            uint32 renewalWindow,
            uint32 minDuration,
            uint32 maxDuration,
            address renewalCadence,
            uint40 limitRatePerSecond
        ) = ratifier.userParams(user, callback, SOURCE_ID, TARGET_ID);
        assertEq(interestRatePolicy, address(0));
        assertEq(renewalWindow, 0);
        assertEq(minDuration, 0);
        assertEq(maxDuration, 0);
        assertEq(renewalCadence, address(0));
        assertEq(limitRatePerSecond, 0);
    }

    function test_migrationClearParams_pinsOnBehalfToInitiator() public {
        address attacker = makeAddr("Attacker");

        vm.prank(user);
        bundler3.multicall(_setParamsCall());

        vm.prank(attacker);
        midnight.setIsAuthorized(address(adapter), true, attacker);

        vm.prank(attacker);
        bundler3.multicall(_clearParamsCall());

        (address victimPolicy,,,,,) = ratifier.userParams(user, callback, SOURCE_ID, TARGET_ID);
        assertEq(victimPolicy, ratePolicy, "victim params not cleared by another initiator");
    }

    function test_migrationClearParams_emitsEvent() public {
        vm.prank(user);
        bundler3.multicall(_setParamsCall());

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(ratifier));
        emit IMigrationRatifier.ParamsCleared(user, callback, SOURCE_ID, TARGET_ID);
        bundler3.multicall(_clearParamsCall());
    }

    function test_migrationClearParams_unauthorizedInitiator_ratifierReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(IMigrationRatifier.Unauthorized.selector);
        bundler3.multicall(_clearParamsCall());
    }

    function test_migrationClearParams_onlyBundler() public {
        vm.prank(user);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        adapter.migrationClearParams(callback, SOURCE_ID, TARGET_ID);
    }

    function testFuzz_migrationSetAndClearParams(bytes32 src, bytes32 tgt) public {
        vm.prank(user);
        bundler3.multicall(_makeCall(abi.encodeCall(adapter.migrationSetParams, (callback, src, tgt, _params()))));

        (address setPolicy,,,,,) = ratifier.userParams(user, callback, src, tgt);
        assertEq(setPolicy, ratePolicy);

        vm.prank(user);
        bundler3.multicall(_makeCall(abi.encodeCall(adapter.migrationClearParams, (callback, src, tgt))));

        (address clearedPolicy,,,,,) = ratifier.userParams(user, callback, src, tgt);
        assertEq(clearedPolicy, address(0));
    }
}

abstract contract TenorAdapterPositionTestBase is TenorAdapterMarketTestBase {
    address internal maker;
    RatifyAllRatifier internal ratifier;

    uint256 internal constant POSITION_UNITS = 50e18;

    function setUp() public virtual override {
        super.setUp();
        maker = makeAddr("Maker");
        ratifier = new RatifyAllRatifier();

        vm.prank(maker);
        midnight.setIsAuthorized(address(ratifier), true, maker);
    }

    function _offer(bool buy) internal view returns (Offer memory) {
        return Offer({
            market: market,
            buy: buy,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: keccak256("offer"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: buy ? address(0) : maker,
            ratifier: address(ratifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }
}

contract TenorAdapterRepayResolutionTest is TenorAdapterPositionTestBase {
    function setUp() public override {
        super.setUp();

        // Seed a debt position for the initiator: maker is the buyer/lender, user takes as seller.
        collateralToken.mint(user, 1_000e18);
        vm.startPrank(user);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, 1_000e18, user);
        vm.stopPrank();

        loanToken.mint(maker, 100e18);
        vm.prank(maker);
        loanToken.approve(address(midnight), type(uint256).max);

        vm.prank(user);
        midnight.take(_offer(true), "", POSITION_UNITS, user, user, address(0), "");
    }

    function _repayCall(uint256 assets, uint256 debt) internal view returns (Call[] memory) {
        return _makeCall(abi.encodeCall(adapter.midnightRepay, (market, assets, debt, address(0), "")));
    }

    function test_midnightRepay_maxDebt_repaysFullDebt() public {
        loanToken.mint(address(adapter), POSITION_UNITS);
        assertEq(midnight.debt(marketId, user), POSITION_UNITS);

        vm.prank(user);
        bundler3.multicall(_repayCall(0, type(uint256).max));

        assertEq(midnight.debt(marketId, user), 0, "debt fully repaid");
        assertEq(loanToken.balanceOf(address(adapter)), 0, "adapter paid the resolved debt");
    }

    function test_midnightRepay_explicitDebt_repaysExactUnits() public {
        loanToken.mint(address(adapter), POSITION_UNITS);

        vm.prank(user);
        bundler3.multicall(_repayCall(0, POSITION_UNITS / 2));

        assertEq(midnight.debt(marketId, user), POSITION_UNITS / 2, "half the debt remains");
        assertEq(loanToken.balanceOf(address(adapter)), POSITION_UNITS / 2, "only the explicit units were pulled");
    }

    function test_midnightRepay_maxAssets_usesFullAdapterBalance() public {
        loanToken.mint(address(adapter), POSITION_UNITS / 2);

        vm.prank(user);
        bundler3.multicall(_repayCall(type(uint256).max, 0));

        assertEq(midnight.debt(marketId, user), POSITION_UNITS / 2, "debt reduced by the full adapter balance");
        assertEq(loanToken.balanceOf(address(adapter)), 0, "full balance consumed");
    }

    function test_midnightRepay_bothAssetsAndDebt_reverts() public {
        vm.prank(user);
        vm.expectRevert(IMidnightAdapter.InconsistentInput.selector);
        bundler3.multicall(_repayCall(1, 1));
    }
}

contract TenorAdapterWithdrawCreditTest is TenorAdapterPositionTestBase {
    address internal receiver;

    function setUp() public override {
        super.setUp();
        receiver = makeAddr("Receiver");

        // Seed a credit position for the initiator: maker is the seller/borrower, user takes as
        // buyer, then the maker repays so the units are withdrawable.
        collateralToken.mint(maker, 1_000e18);
        vm.startPrank(maker);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, 1_000e18, maker);
        vm.stopPrank();

        loanToken.mint(user, 100e18);
        vm.startPrank(user);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.take(_offer(false), "", POSITION_UNITS, user, address(0), address(0), "");
        vm.stopPrank();

        loanToken.mint(maker, POSITION_UNITS);
        vm.startPrank(maker);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.repay(market, POSITION_UNITS, maker, address(0), "");
        vm.stopPrank();
    }

    function test_midnightWithdraw_maxSentinel_withdrawsFullCredit() public {
        assertEq(midnight.credit(marketId, user), POSITION_UNITS);

        vm.prank(user);
        bundler3.multicall(_makeCall(abi.encodeCall(adapter.midnightWithdraw, (market, type(uint256).max, receiver))));

        assertEq(midnight.credit(marketId, user), 0, "credit fully withdrawn");
        assertEq(loanToken.balanceOf(receiver), POSITION_UNITS, "receiver got the resolved units");
    }
}
