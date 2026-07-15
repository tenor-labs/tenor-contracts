// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TenorAdapter} from "../../src/bundler/TenorAdapter.sol";
import {MigrationRatifier} from "../../src/ratifiers/MigrationRatifier.sol";
import {IMigrationRatifier} from "../../src/ratifiers/interfaces/IMigrationRatifier.sol";
import {IMidnightAdapter} from "../../src/bundler/interfaces/IMidnightAdapter.sol";
import {
    BorrowRenewalConfigurationV1Base
} from "../../src/ratifiers/configurations/BorrowRenewalConfigurationV1Base.sol";
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
import {Id, MarketParams} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";
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
        return deployTenorAdapter(bundler3, address(midnight));
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
        // Reading the callbacks from a zero ratifier reverts on empty returndata.
        vm.expectRevert();
        deployTenorAdapter(bundler3, address(midnight), address(0));
    }

    function test_constructor_setsRatifierAndCanonicalConfig() public {
        MigrationRatifier ratifier = deployMigrationRatifier(address(midnight));
        RenewalConfig memory config = defaultRenewalConfig();
        TenorAdapter fresh = deployTenorAdapter(bundler3, address(midnight), address(ratifier));

        assertEq(address(fresh.RATIFIER()), address(ratifier));
        assertEq(fresh.BORROW_MIDNIGHT_RENEWAL_CALLBACK(), ratifier.BORROW_MIDNIGHT_RENEWAL_CALLBACK());
        assertEq(fresh.BORROW_MIDNIGHT_TO_BLUE_CALLBACK(), ratifier.BORROW_MIDNIGHT_TO_BLUE_CALLBACK());
        assertEq(fresh.BORROW_BLUE_TO_MIDNIGHT_CALLBACK(), ratifier.BORROW_BLUE_TO_MIDNIGHT_CALLBACK());
        assertEq(fresh.ENTRY_RATE_POLICY(), config.entryRatePolicy);
        assertEq(fresh.EXIT_RATE_POLICY(), config.exitRatePolicy);
        assertEq(fresh.RENEWAL_CADENCE(), config.renewalCadence);
        assertEq(fresh.RENEWAL_WINDOW(), config.renewalWindow);
        assertEq(fresh.EXIT_WINDOW(), config.exitWindow);
        assertEq(fresh.MIN_DURATION(), config.minDuration);
        assertEq(fresh.MAX_DURATION(), config.maxDuration);
    }

    function test_constructor_maxRenewalRate_is15PercentApr() public {
        TenorAdapter fresh = deployTenorAdapter(bundler3, address(midnight));
        uint256 maxApr = 0.15e18;
        assertEq(fresh.MAX_RENEWAL_RATE_PER_SECOND(), maxApr / 365 days);
    }

    function test_constructor_revertsMinDurationNotAboveRenewalWindow() public {
        RenewalConfig memory config = defaultRenewalConfig();
        config.minDuration = config.renewalWindow;
        _expectConstructorRevert(config, BorrowRenewalConfigurationV1Base.InvalidRenewalConfig.selector);
    }

    function test_constructor_revertsMinDurationNotAboveExitWindow() public {
        RenewalConfig memory config = defaultRenewalConfig();
        config.exitWindow = config.minDuration;
        _expectConstructorRevert(config, BorrowRenewalConfigurationV1Base.InvalidRenewalConfig.selector);
    }

    function test_constructor_revertsMaxDurationBelowMinDuration() public {
        RenewalConfig memory config = defaultRenewalConfig();
        config.maxDuration = config.minDuration - 1;
        _expectConstructorRevert(config, BorrowRenewalConfigurationV1Base.InvalidRenewalConfig.selector);
    }

    function _expectConstructorRevert(RenewalConfig memory config, bytes4 selector) internal {
        MigrationRatifier ratifier = deployMigrationRatifier(address(midnight));
        vm.expectRevert(selector);
        deployTenorAdapter(bundler3, address(midnight), address(ratifier), config);
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

    function test_midnightRepay_maxAssetsWithCallback_reverts() public {
        vm.prank(user);
        vm.expectRevert(IMidnightAdapter.InconsistentInput.selector);
        bundler3.multicall(
            _makeCall(abi.encodeCall(adapter.midnightRepay, (market, type(uint256).max, 0, makeAddr("Callback"), "")))
        );
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

    function test_midnightRepay_withCallback_noApproval() public {
        address callback = makeAddr("Callback");

        vm.expectCall(address(loanToken), abi.encodeCall(loanToken.approve, (address(midnight), type(uint256).max)), 0);
        vm.expectCall(address(midnight), abi.encodeCall(IMidnight.repay, (market, REPAY_UNITS, user, callback, "")));
        vm.prank(user);
        vm.expectRevert();
        bundler3.multicall(_makeCall(abi.encodeCall(adapter.midnightRepay, (market, REPAY_UNITS, 0, callback, ""))));
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

contract TenorAdapterRenewalParamsTest is TenorAdapterTestBase {
    using MarketParamsLib for MarketParams;
    using TenorMarketIdLib for Market;

    MigrationRatifier internal ratifier;
    RenewalConfig internal config;

    address internal renewalCallback;
    address internal exitCallback;
    address internal entryCallback;

    Market internal tenorMarket;
    MarketParams internal blueParams;
    bytes32 internal tenorMarketId;
    bytes32 internal blueMarketId;

    uint40 internal constant RATE = 1e9;
    uint256 internal constant LLTV = 0.945e18;

    IMigrationRatifier.UserMigrationParams internal EMPTY_PARAMS =
        IMigrationRatifier.UserMigrationParams(address(0), 0, 0, 0, address(0), 0);

    function setUp() public override {
        super.setUp();

        config = defaultRenewalConfig();
        renewalCallback = ratifier.BORROW_MIDNIGHT_RENEWAL_CALLBACK();
        exitCallback = ratifier.BORROW_MIDNIGHT_TO_BLUE_CALLBACK();
        entryCallback = ratifier.BORROW_BLUE_TO_MIDNIGHT_CALLBACK();

        address loanToken = makeAddr("RenewalLoanToken");
        address collateralToken = makeAddr("RenewalCollateralToken");
        address oracle = makeAddr("RenewalOracle");

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: collateralToken, lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: oracle
        });
        tenorMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: loanToken,
            collateralParams: collaterals,
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        blueParams = MarketParams({
            loanToken: loanToken,
            collateralToken: collateralToken,
            oracle: oracle,
            irm: makeAddr("RenewalIrm"),
            lltv: LLTV
        });
        tenorMarketId = tenorMarket.toTenorMarketId();
        blueMarketId = Id.unwrap(blueParams.id());
    }

    function _deployAdapter() internal override returns (TenorAdapter) {
        ratifier = deployMigrationRatifier(address(midnight));
        return deployTenorAdapter(bundler3, address(midnight), address(ratifier));
    }

    function _renewalParams(uint40 limitRatePerSecond)
        internal
        view
        returns (IMigrationRatifier.UserMigrationParams memory)
    {
        return IMigrationRatifier.UserMigrationParams({
            interestRatePolicy: config.entryRatePolicy,
            renewalWindow: config.renewalWindow,
            minDuration: config.minDuration,
            maxDuration: config.maxDuration,
            renewalCadence: config.renewalCadence,
            limitRatePerSecond: limitRatePerSecond
        });
    }

    function _exitParams() internal view returns (IMigrationRatifier.UserMigrationParams memory) {
        return IMigrationRatifier.UserMigrationParams({
            interestRatePolicy: config.exitRatePolicy,
            renewalWindow: config.exitWindow,
            minDuration: 1,
            maxDuration: config.maxDuration,
            renewalCadence: config.renewalCadence,
            limitRatePerSecond: 0
        });
    }

    function _entryParams(uint40 limitRatePerSecond)
        internal
        view
        returns (IMigrationRatifier.UserMigrationParams memory)
    {
        return IMigrationRatifier.UserMigrationParams({
            interestRatePolicy: config.entryRatePolicy,
            renewalWindow: 0,
            minDuration: config.minDuration,
            maxDuration: config.maxDuration,
            renewalCadence: config.renewalCadence,
            limitRatePerSecond: limitRatePerSecond
        });
    }

    function _setCall(
        Market memory market,
        MarketParams memory blue,
        uint40 rate,
        bool enableMidnightToMidnight,
        bool enableBlueToMidnight
    ) internal view returns (Call[] memory) {
        return _makeCall(
            abi.encodeCall(
                adapter.setBorrowRenewalConfigurationV1,
                (market, blue, rate, enableMidnightToMidnight, enableBlueToMidnight)
            )
        );
    }

    function _setCall(uint40 rate, bool enableMidnightToMidnight, bool enableBlueToMidnight)
        internal
        view
        returns (Call[] memory)
    {
        return _setCall(tenorMarket, blueParams, rate, enableMidnightToMidnight, enableBlueToMidnight);
    }

    function _clearCall(Market memory market, MarketParams memory blue) internal view returns (Call[] memory) {
        return _makeCall(abi.encodeCall(adapter.clearBorrowRenewalConfigurationV1, (market, blue)));
    }

    function _clearCall() internal view returns (Call[] memory) {
        return _clearCall(tenorMarket, blueParams);
    }

    function _assertStoredParams(
        address owner,
        address callback,
        bytes32 src,
        bytes32 tgt,
        IMigrationRatifier.UserMigrationParams memory expected
    ) internal view {
        (
            address interestRatePolicy,
            uint32 renewalWindow,
            uint32 minDuration,
            uint32 maxDuration,
            address renewalCadence,
            uint40 limitRatePerSecond
        ) = ratifier.userParams(owner, callback, src, tgt);
        assertEq(interestRatePolicy, expected.interestRatePolicy);
        assertEq(renewalWindow, expected.renewalWindow);
        assertEq(minDuration, expected.minDuration);
        assertEq(maxDuration, expected.maxDuration);
        assertEq(renewalCadence, expected.renewalCadence);
        assertEq(limitRatePerSecond, expected.limitRatePerSecond);
    }

    /* SET */

    function test_setBorrowRenewalConfigurationV1_storesAllLegsForInitiator() public {
        vm.prank(user);
        bundler3.multicall(_setCall(RATE, true, true));

        _assertStoredParams(user, renewalCallback, tenorMarketId, tenorMarketId, _renewalParams(RATE));
        _assertStoredParams(user, exitCallback, tenorMarketId, blueMarketId, _exitParams());
        _assertStoredParams(user, entryCallback, blueMarketId, tenorMarketId, _entryParams(RATE));

        (address adapterPolicy,,,,,) =
            ratifier.userParams(address(adapter), renewalCallback, tenorMarketId, tenorMarketId);
        assertEq(adapterPolicy, address(0), "params keyed by initiator, not adapter");
    }

    function test_setBorrowRenewalConfigurationV1_blueToMidnightDisabled_writesTwoLegs() public {
        vm.prank(user);
        bundler3.multicall(_setCall(RATE, true, false));

        _assertStoredParams(user, renewalCallback, tenorMarketId, tenorMarketId, _renewalParams(RATE));
        _assertStoredParams(user, exitCallback, tenorMarketId, blueMarketId, _exitParams());
        _assertStoredParams(user, entryCallback, blueMarketId, tenorMarketId, EMPTY_PARAMS);
    }

    function test_setBorrowRenewalConfigurationV1_disablingBlueToMidnight_clearsEntryLeg() public {
        vm.prank(user);
        bundler3.multicall(_setCall(RATE, true, true));

        vm.prank(user);
        bundler3.multicall(_setCall(RATE, true, false));

        _assertStoredParams(user, entryCallback, blueMarketId, tenorMarketId, EMPTY_PARAMS);
        _assertStoredParams(user, renewalCallback, tenorMarketId, tenorMarketId, _renewalParams(RATE));
        _assertStoredParams(user, exitCallback, tenorMarketId, blueMarketId, _exitParams());
    }

    function test_setBorrowRenewalConfigurationV1_renewalLegIsSameMarket() public {
        vm.prank(user);
        bundler3.multicall(_setCall(RATE, true, true));

        (address offKeyPolicy,,,,,) = ratifier.userParams(user, renewalCallback, tenorMarketId, blueMarketId);
        assertEq(offKeyPolicy, address(0), "renewal leg keyed (market, market), nothing else");
    }

    function test_setBorrowRenewalConfigurationV1_exitLegMinDurationIsOne() public {
        vm.prank(user);
        bundler3.multicall(_setCall(RATE, true, true));

        (,, uint32 minDuration,,,) = ratifier.userParams(user, exitCallback, tenorMarketId, blueMarketId);
        assertEq(minDuration, 1, "exit leg minDuration pinned to 1");
    }

    function test_setBorrowRenewalConfigurationV1_zeroRate_reverts() public {
        vm.prank(user);
        vm.expectRevert(BorrowRenewalConfigurationV1Base.InvalidLimitRate.selector);
        bundler3.multicall(_setCall(0, true, true));
    }

    function test_setBorrowRenewalConfigurationV1_rateAboveCap_reverts() public {
        uint40 cap = adapter.MAX_RENEWAL_RATE_PER_SECOND();
        vm.prank(user);
        vm.expectRevert(BorrowRenewalConfigurationV1Base.InvalidLimitRate.selector);
        bundler3.multicall(_setCall(cap + 1, true, true));
    }

    function test_setBorrowRenewalConfigurationV1_rateAtCap_succeeds() public {
        uint40 cap = adapter.MAX_RENEWAL_RATE_PER_SECOND();
        vm.prank(user);
        bundler3.multicall(_setCall(cap, true, true));

        _assertStoredParams(user, renewalCallback, tenorMarketId, tenorMarketId, _renewalParams(cap));
        _assertStoredParams(user, entryCallback, blueMarketId, tenorMarketId, _entryParams(cap));
    }

    function testFuzz_setBorrowRenewalConfigurationV1_rate(
        uint40 rate,
        bool enableMidnightToMidnight,
        bool enableBlueToMidnight
    ) public {
        uint40 cap = adapter.MAX_RENEWAL_RATE_PER_SECOND();
        bool valid = enableMidnightToMidnight || enableBlueToMidnight ? rate != 0 && rate <= cap : rate == 0;
        vm.prank(user);
        if (!valid) vm.expectRevert(BorrowRenewalConfigurationV1Base.InvalidLimitRate.selector);
        bundler3.multicall(_setCall(rate, enableMidnightToMidnight, enableBlueToMidnight));
    }

    function test_setBorrowRenewalConfigurationV1_midnightToMidnightDisabled_writesTwoLegs() public {
        vm.prank(user);
        bundler3.multicall(_setCall(RATE, false, true));

        _assertStoredParams(user, renewalCallback, tenorMarketId, tenorMarketId, EMPTY_PARAMS);
        _assertStoredParams(user, exitCallback, tenorMarketId, blueMarketId, _exitParams());
        _assertStoredParams(user, entryCallback, blueMarketId, tenorMarketId, _entryParams(RATE));
    }

    function test_setBorrowRenewalConfigurationV1_disablingMidnightToMidnight_clearsRenewalLeg() public {
        vm.prank(user);
        bundler3.multicall(_setCall(RATE, true, true));

        vm.prank(user);
        bundler3.multicall(_setCall(RATE, false, true));

        _assertStoredParams(user, renewalCallback, tenorMarketId, tenorMarketId, EMPTY_PARAMS);
        _assertStoredParams(user, exitCallback, tenorMarketId, blueMarketId, _exitParams());
        _assertStoredParams(user, entryCallback, blueMarketId, tenorMarketId, _entryParams(RATE));
    }

    function test_setBorrowRenewalConfigurationV1_bothDisabled_zeroRate_writesExitOnly() public {
        vm.prank(user);
        bundler3.multicall(_setCall(0, false, false));

        _assertStoredParams(user, renewalCallback, tenorMarketId, tenorMarketId, EMPTY_PARAMS);
        _assertStoredParams(user, exitCallback, tenorMarketId, blueMarketId, _exitParams());
        _assertStoredParams(user, entryCallback, blueMarketId, tenorMarketId, EMPTY_PARAMS);
    }

    function test_setBorrowRenewalConfigurationV1_bothDisabled_nonZeroRate_reverts() public {
        vm.prank(user);
        vm.expectRevert(BorrowRenewalConfigurationV1Base.InvalidLimitRate.selector);
        bundler3.multicall(_setCall(RATE, false, false));
    }

    /* MARKET PAIR VALIDATION */

    function test_setBorrowRenewalConfigurationV1_loanTokenMismatch_reverts() public {
        MarketParams memory blue = blueParams;
        blue.loanToken = makeAddr("OtherLoanToken");

        vm.prank(user);
        vm.expectRevert(BorrowRenewalConfigurationV1Base.LoanTokenMismatch.selector);
        bundler3.multicall(_setCall(tenorMarket, blue, RATE, true, true));
    }

    function test_setBorrowRenewalConfigurationV1_zeroLoanTokens_revert() public {
        Market memory market = tenorMarket;
        MarketParams memory blue = blueParams;
        market.loanToken = address(0);
        blue.loanToken = address(0);

        vm.prank(user);
        vm.expectRevert(BorrowRenewalConfigurationV1Base.LoanTokenMismatch.selector);
        bundler3.multicall(_setCall(market, blue, RATE, true, true));
    }

    function test_setBorrowRenewalConfigurationV1_unknownCollateral_reverts() public {
        MarketParams memory blue = blueParams;
        blue.collateralToken = makeAddr("OtherCollateral");

        vm.prank(user);
        vm.expectRevert(BorrowRenewalConfigurationV1Base.CollateralMismatch.selector);
        bundler3.multicall(_setCall(tenorMarket, blue, RATE, true, true));
    }

    function test_setBorrowRenewalConfigurationV1_lltvMismatch_reverts() public {
        MarketParams memory blue = blueParams;
        blue.lltv = LLTV - 1;

        vm.prank(user);
        vm.expectRevert(BorrowRenewalConfigurationV1Base.CollateralMismatch.selector);
        bundler3.multicall(_setCall(tenorMarket, blue, RATE, true, true));
    }

    function test_setBorrowRenewalConfigurationV1_oracleMismatch_reverts() public {
        MarketParams memory blue = blueParams;
        blue.oracle = makeAddr("OtherOracle");

        vm.prank(user);
        vm.expectRevert(BorrowRenewalConfigurationV1Base.CollateralMismatch.selector);
        bundler3.multicall(_setCall(tenorMarket, blue, RATE, true, true));
    }

    function test_setBorrowRenewalConfigurationV1_noCollaterals_reverts() public {
        Market memory market = tenorMarket;
        market.collateralParams = new CollateralParams[](0);

        vm.prank(user);
        vm.expectRevert(BorrowRenewalConfigurationV1Base.CollateralMismatch.selector);
        bundler3.multicall(_setCall(market, blueParams, RATE, true, true));
    }

    function test_setBorrowRenewalConfigurationV1_matchesCorrectCollateralAmongSeveral() public {
        // Two collaterals sorted by token address; Blue matches the second, whose lltv/oracle differ from the
        // first. The check must compare the entry found by token, not another index.
        address tokenA = makeAddr("CollateralA");
        address tokenB = makeAddr("CollateralB");
        (address low, address high) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        Market memory market = tenorMarket;
        market.collateralParams = new CollateralParams[](2);
        market.collateralParams[0] = CollateralParams({
            token: low, lltv: 0.5e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: makeAddr("OracleLow")
        });
        market.collateralParams[1] = CollateralParams({
            token: high, lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: makeAddr("OracleHigh")
        });

        MarketParams memory blue = blueParams;
        blue.collateralToken = high;
        blue.oracle = makeAddr("OracleHigh");

        vm.prank(user);
        bundler3.multicall(_setCall(market, blue, RATE, true, true));

        bytes32 marketId = TenorMarketIdLib.toTenorMarketId(market);
        (address storedPolicy,,,,,) = ratifier.userParams(user, renewalCallback, marketId, marketId);
        assertEq(storedPolicy, config.entryRatePolicy);
    }

    function test_setBorrowRenewalConfigurationV1_mismatch_writesNoLeg() public {
        MarketParams memory blue = blueParams;
        blue.lltv = LLTV - 1;

        vm.prank(user);
        vm.expectRevert(BorrowRenewalConfigurationV1Base.CollateralMismatch.selector);
        bundler3.multicall(_setCall(tenorMarket, blue, RATE, true, true));

        (address renewalPolicy,,,,,) = ratifier.userParams(user, renewalCallback, tenorMarketId, tenorMarketId);
        assertEq(renewalPolicy, address(0), "no leg partially written");
    }

    /* AUTH */

    function test_setBorrowRenewalConfigurationV1_pinsOnBehalfToInitiator() public {
        address attacker = makeAddr("Attacker");

        vm.prank(attacker);
        midnight.setIsAuthorized(address(adapter), true, attacker);

        vm.prank(attacker);
        bundler3.multicall(_setCall(RATE, true, true));

        (address victimPolicy,,,,,) = ratifier.userParams(user, renewalCallback, tenorMarketId, tenorMarketId);
        (address victimExitPolicy,,,,,) = ratifier.userParams(user, exitCallback, tenorMarketId, blueMarketId);
        (address victimEntryPolicy,,,,,) = ratifier.userParams(user, entryCallback, blueMarketId, tenorMarketId);
        assertEq(victimPolicy, address(0), "victim renewal params untouched");
        assertEq(victimExitPolicy, address(0), "victim exit params untouched");
        assertEq(victimEntryPolicy, address(0), "victim entry params untouched");
        _assertStoredParams(attacker, renewalCallback, tenorMarketId, tenorMarketId, _renewalParams(RATE));
        _assertStoredParams(attacker, exitCallback, tenorMarketId, blueMarketId, _exitParams());
        _assertStoredParams(attacker, entryCallback, blueMarketId, tenorMarketId, _entryParams(RATE));
    }

    function test_setBorrowRenewalConfigurationV1_emitsAllEvents() public {
        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(ratifier));
        emit IMigrationRatifier.ParamsSet(user, renewalCallback, tenorMarketId, tenorMarketId, _renewalParams(RATE));
        vm.expectEmit(true, true, true, true, address(ratifier));
        emit IMigrationRatifier.ParamsSet(user, exitCallback, tenorMarketId, blueMarketId, _exitParams());
        vm.expectEmit(true, true, true, true, address(ratifier));
        emit IMigrationRatifier.ParamsSet(user, entryCallback, blueMarketId, tenorMarketId, _entryParams(RATE));
        bundler3.multicall(_setCall(RATE, true, true));
    }

    function test_setBorrowRenewalConfigurationV1_blueToMidnightDisabled_emitsEntryCleared() public {
        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(ratifier));
        emit IMigrationRatifier.ParamsSet(user, renewalCallback, tenorMarketId, tenorMarketId, _renewalParams(RATE));
        vm.expectEmit(true, true, true, true, address(ratifier));
        emit IMigrationRatifier.ParamsSet(user, exitCallback, tenorMarketId, blueMarketId, _exitParams());
        vm.expectEmit(true, true, true, true, address(ratifier));
        emit IMigrationRatifier.ParamsCleared(user, entryCallback, blueMarketId, tenorMarketId);
        bundler3.multicall(_setCall(RATE, true, false));
    }

    function test_setBorrowRenewalConfigurationV1_unauthorizedInitiator_ratifierReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(IMigrationRatifier.Unauthorized.selector);
        bundler3.multicall(_setCall(RATE, true, true));
    }

    function test_setBorrowRenewalConfigurationV1_onlyBundler() public {
        vm.prank(user);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        adapter.setBorrowRenewalConfigurationV1(tenorMarket, blueParams, RATE, true, true);
    }

    /* CLEAR */

    function test_clearBorrowRenewalConfigurationV1_clearsAllLegs() public {
        vm.prank(user);
        bundler3.multicall(_setCall(RATE, true, true));

        vm.prank(user);
        bundler3.multicall(_clearCall());

        _assertStoredParams(user, renewalCallback, tenorMarketId, tenorMarketId, EMPTY_PARAMS);
        _assertStoredParams(user, exitCallback, tenorMarketId, blueMarketId, EMPTY_PARAMS);
        _assertStoredParams(user, entryCallback, blueMarketId, tenorMarketId, EMPTY_PARAMS);
    }

    function test_clearBorrowRenewalConfigurationV1_mismatch_reverts() public {
        vm.prank(user);
        bundler3.multicall(_setCall(RATE, true, true));

        MarketParams memory blue = blueParams;
        blue.lltv = LLTV - 1;

        vm.prank(user);
        vm.expectRevert(BorrowRenewalConfigurationV1Base.CollateralMismatch.selector);
        bundler3.multicall(_clearCall(tenorMarket, blue));

        (address livePolicy,,,,,) = ratifier.userParams(user, renewalCallback, tenorMarketId, tenorMarketId);
        assertEq(livePolicy, config.entryRatePolicy, "mismatched clear reverts instead of no-op");
    }

    function test_clearBorrowRenewalConfigurationV1_pinsOnBehalfToInitiator() public {
        address attacker = makeAddr("Attacker");

        vm.prank(user);
        bundler3.multicall(_setCall(RATE, true, true));

        vm.prank(attacker);
        midnight.setIsAuthorized(address(adapter), true, attacker);

        vm.prank(attacker);
        bundler3.multicall(_clearCall());

        (address victimPolicy,,,,,) = ratifier.userParams(user, renewalCallback, tenorMarketId, tenorMarketId);
        (address victimExitPolicy,,,,,) = ratifier.userParams(user, exitCallback, tenorMarketId, blueMarketId);
        (address victimEntryPolicy,,,,,) = ratifier.userParams(user, entryCallback, blueMarketId, tenorMarketId);
        assertEq(victimPolicy, config.entryRatePolicy, "victim renewal params not cleared by another initiator");
        assertEq(victimExitPolicy, config.exitRatePolicy, "victim exit params not cleared by another initiator");
        assertEq(victimEntryPolicy, config.entryRatePolicy, "victim entry params not cleared by another initiator");
    }

    function test_clearBorrowRenewalConfigurationV1_emitsAllEvents() public {
        vm.prank(user);
        bundler3.multicall(_setCall(RATE, true, true));

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(ratifier));
        emit IMigrationRatifier.ParamsCleared(user, renewalCallback, tenorMarketId, tenorMarketId);
        vm.expectEmit(true, true, true, true, address(ratifier));
        emit IMigrationRatifier.ParamsCleared(user, exitCallback, tenorMarketId, blueMarketId);
        vm.expectEmit(true, true, true, true, address(ratifier));
        emit IMigrationRatifier.ParamsCleared(user, entryCallback, blueMarketId, tenorMarketId);
        bundler3.multicall(_clearCall());
    }

    function test_clearBorrowRenewalConfigurationV1_onlyBundler() public {
        vm.prank(user);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        adapter.clearBorrowRenewalConfigurationV1(tenorMarket, blueParams);
    }

    function testFuzz_setAndClear_roundTrip(uint256 lltv, bool enableBlueToMidnight) public {
        lltv = bound(lltv, 1, 1e18);
        Market memory market = tenorMarket;
        market.collateralParams[0].lltv = lltv;
        MarketParams memory blue = blueParams;
        blue.lltv = lltv;
        bytes32 marketId = TenorMarketIdLib.toTenorMarketId(market);
        bytes32 blueId = Id.unwrap(MarketParamsLib.id(blue));

        vm.prank(user);
        bundler3.multicall(_setCall(market, blue, RATE, true, enableBlueToMidnight));
        (address setPolicy,,,,,) = ratifier.userParams(user, renewalCallback, marketId, marketId);
        (address setExitPolicy,,,,,) = ratifier.userParams(user, exitCallback, marketId, blueId);
        (address setEntryPolicy,,,,,) = ratifier.userParams(user, entryCallback, blueId, marketId);
        assertEq(setPolicy, config.entryRatePolicy);
        assertEq(setExitPolicy, config.exitRatePolicy);
        assertEq(setEntryPolicy, enableBlueToMidnight ? config.entryRatePolicy : address(0));

        vm.prank(user);
        bundler3.multicall(_clearCall(market, blue));
        (address clearedPolicy,,,,,) = ratifier.userParams(user, renewalCallback, marketId, marketId);
        (address clearedExitPolicy,,,,,) = ratifier.userParams(user, exitCallback, marketId, blueId);
        (address clearedEntryPolicy,,,,,) = ratifier.userParams(user, entryCallback, blueId, marketId);
        assertEq(clearedPolicy, address(0));
        assertEq(clearedExitPolicy, address(0));
        assertEq(clearedEntryPolicy, address(0));
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
