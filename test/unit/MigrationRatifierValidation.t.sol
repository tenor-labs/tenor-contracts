// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {MigrationRatifierTestBase} from "../helpers/MigrationRatifierTestBase.sol";
import {IMigrationRatifier} from "../../src/ratifiers/interfaces/IMigrationRatifier.sol";
import {IRenewalCadence} from "../../src/ratifiers/interfaces/IRenewalCadence.sol";
import {FourWeekCadence} from "../../src/ratifiers/policies/FourWeekCadence.sol";
import {StaticRatePolicy} from "../../src/ratifiers/policies/StaticRatePolicy.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {Market} from "@midnight/interfaces/IMidnight.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {Id, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";

/// @dev A cadence whose period start is always one second in the future, so a Blue/Vault entry never has a valid
///      `renewalPeriodStart <= block.timestamp`.
contract FutureCadence is IRenewalCadence {
    function cadencePeriodStart(uint256 timestamp) external pure returns (uint256) {
        return timestamp + 1;
    }
}

/// @dev A cadence that rejects every maturity by never returning a value equal to its input.
contract RejectAllCadence is IRenewalCadence {
    function cadencePeriodStart(uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @title MigrationRatifierValidationTest
/// @notice Renewal-window, duration-bound, cadence, and rate-ceiling validation coverage. The guards live in
///         `BaseMigrationRatifier` and are
///         reached through the make-on-behalf take path (`midnight.take` -> `MigrationRatifier.isRatified`); a revert
///         inside `isRatified` bubbles its selector through `Midnight.take`. Drives the borrow-renewal (V2->V2) path,
///         the canonical fixture for these path-independent checks.
contract MigrationRatifierValidationTest is MigrationRatifierTestBase {
    using TenorMarketIdLib for Market;

    bytes32 internal sourceTenorMarketId;
    bytes32 internal targetTenorMarketId;

    function setUp() public override {
        super.setUp();
        sourceTenorMarketId = sourceMarket.toTenorMarketId();
        targetTenorMarketId = targetMarket.toTenorMarketId();

        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        _setParams(
            borrower,
            address(borrowMidnightRenewalCallback),
            sourceTenorMarketId,
            targetTenorMarketId,
            _defaultMidnightParams()
        );
        _warpToRenewalWindow(sourceMarket);
    }

    /* ═══════ Helpers ═══════ */

    function _seededTarget(uint256 maturity) internal returns (Market memory tgt) {
        tgt = _cloneTarget(maturity);
        _seedMarket(tgt, IdLib.toId(tgt));
    }

    function _take(Market memory target, uint16 tick, uint256 units) internal returns (uint256 ou) {
        (,, ou) = _takeBorrowMidnightRenewal(borrower, lender, units, sourceMarket, target, tick);
    }

    /// @dev External wrapper so `vm.expectRevert` applies to the whole take (the intervening `getEffectiveFeeConfig`
    ///      view calls inside the helper would otherwise consume the expectation).
    function takeExt(Market memory target, uint16 tick, uint256 units) external returns (uint256) {
        return _take(target, tick, units);
    }

    /// @dev First 28-day cadence boundary that lies strictly inside the renewal window and past source maturity.
    function _firstFourWeekBoundaryInWindow() internal view returns (uint256 boundary) {
        boundary = ((block.timestamp + 28 days) / 28 days) * 28 days;
        while (boundary < block.timestamp + 7 days || boundary <= sourceMarket.maturity) {
            boundary += 28 days;
        }
    }

    /* ═══════ ORCH-8: renewal window (incl. zero-window semantic) ═══════ */

    function test_window_succeeds_atWindowStart() public {
        vm.warp(sourceMarket.maturity - 7 days);
        assertGt(_take(targetMarket, DEFAULT_TICK, 100e18), 0, "window start succeeds");
    }

    function test_window_succeeds_atWindowEnd() public {
        vm.warp(sourceMarket.maturity + 1 days);
        assertEq(_take(targetMarket, DEFAULT_TICK, 500e18), 500e18, "window end succeeds");
    }

    function test_window_reverts_oneSecondBeforeWindowStart() public {
        vm.warp(sourceMarket.maturity - 7 days - 1);
        vm.expectRevert(IMigrationRatifier.InvalidRenewalWindow.selector);
        this.takeExt(targetMarket, DEFAULT_TICK, 100e18);
    }

    function test_window_reverts_zeroWindow_beforeMaturity() public {
        IMigrationRatifier.UserMigrationParams memory params = _defaultMidnightParams();
        params.renewalWindow = 0;
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        vm.expectRevert(IMigrationRatifier.InvalidRenewalWindow.selector);
        this.takeExt(targetMarket, DEFAULT_TICK, 100e18);
    }

    function test_window_succeeds_zeroWindow_afterMaturity() public {
        IMigrationRatifier.UserMigrationParams memory params = _defaultMidnightParams();
        params.renewalWindow = 0;
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        vm.warp(sourceMarket.maturity + 1);
        assertGt(_take(targetMarket, DEFAULT_TICK, 100e18), 0, "zero window after maturity succeeds");
    }

    function test_window_reverts_renewalWindowExceedsMaturity() public {
        IMigrationRatifier.UserMigrationParams memory params = _defaultMidnightParams();
        params.renewalWindow = type(uint32).max;
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        vm.expectRevert(IMigrationRatifier.InvalidRenewalParams.selector);
        this.takeExt(targetMarket, DEFAULT_TICK, 100e18);
    }

    /* ═══════ ORCH-9 / ORCH-10: target-maturity bounds ═══════ */

    function test_duration_reverts_targetMaturityNotIncreasing() public {
        Market memory badTarget = _cloneTarget(sourceMarket.maturity);
        vm.expectRevert(IMigrationRatifier.InvalidTargetMaturity.selector);
        this.takeExt(badTarget, DEFAULT_TICK, 100e18);
    }

    function test_duration_reverts_targetMaturityBelowMinDuration() public {
        Market memory shortTarget = _cloneTarget(block.timestamp + 1 days);
        vm.expectRevert(IMigrationRatifier.InvalidTargetMaturity.selector);
        this.takeExt(shortTarget, DEFAULT_TICK, 100e18);
    }

    function test_duration_reverts_targetMaturityAboveMaxDuration() public {
        Market memory longTarget = _cloneTarget(block.timestamp + 366 days);
        vm.expectRevert(IMigrationRatifier.InvalidTargetMaturity.selector);
        this.takeExt(longTarget, DEFAULT_TICK, 100e18);
    }

    function test_duration_reverts_oneSecondBelowMinDuration() public {
        Market memory belowTarget = _cloneTarget(block.timestamp + 7 days - 1);
        vm.expectRevert(IMigrationRatifier.InvalidTargetMaturity.selector);
        this.takeExt(belowTarget, DEFAULT_TICK, 100e18);
    }

    function test_duration_succeeds_exactMinDuration() public {
        // Short duration needs near-par tick to pass the rate ceiling.
        Market memory exactTarget = _seededTarget(block.timestamp + 7 days);
        assertGt(_take(exactTarget, TICK_HIGH, 100e18), 0, "exact min duration succeeds");
    }

    function test_duration_succeeds_exactDuration() public {
        IMigrationRatifier.UserMigrationParams memory params = _defaultMidnightParams();
        params.minDuration = uint32(30 days);
        params.maxDuration = uint32(30 days);
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        Market memory exactTarget = _seededTarget(block.timestamp + 30 days);
        assertGt(_take(exactTarget, DEFAULT_TICK, 100e18), 0, "exact duration succeeds");
    }

    function test_duration_reverts_exactDuration_offByOne() public {
        IMigrationRatifier.UserMigrationParams memory params = _defaultMidnightParams();
        params.minDuration = uint32(30 days);
        params.maxDuration = uint32(30 days);
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        Market memory offTarget = _cloneTarget(block.timestamp + 30 days + 1);
        vm.expectRevert(IMigrationRatifier.InvalidTargetMaturity.selector);
        this.takeExt(offTarget, DEFAULT_TICK, 100e18);
    }

    /* ═══════ ORCH-11: cadence validation of target maturity ═══════ */

    function test_cadence_reverts_rejectsMaturity() public {
        IMigrationRatifier.UserMigrationParams memory params = _defaultMidnightParams();
        params.renewalCadence = address(new RejectAllCadence());
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        vm.expectRevert(IMigrationRatifier.InvalidTargetMaturity.selector);
        this.takeExt(targetMarket, DEFAULT_TICK, 100e18);
    }

    function test_cadence_succeeds_FourWeekCadence_onBoundary() public {
        FourWeekCadence fwCadence = new FourWeekCadence();
        uint256 candidate = _firstFourWeekBoundaryInWindow();
        assertTrue(candidate <= block.timestamp + 365 days, "precondition: within max duration");

        Market memory target = _seededTarget(candidate);
        IMigrationRatifier.UserMigrationParams memory params = _defaultMidnightParams();
        params.renewalCadence = address(fwCadence);
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        assertGt(_take(target, DEFAULT_TICK, 100e18), 0, "on-boundary maturity succeeds");
    }

    function test_cadence_reverts_FourWeekCadence_offBoundary() public {
        FourWeekCadence fwCadence = new FourWeekCadence();
        Market memory target = _cloneTarget(_firstFourWeekBoundaryInWindow() + 1);
        IMigrationRatifier.UserMigrationParams memory params = _defaultMidnightParams();
        params.renewalCadence = address(fwCadence);
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        vm.expectRevert(IMigrationRatifier.InvalidTargetMaturity.selector);
        this.takeExt(target, DEFAULT_TICK, 100e18);
    }

    /* ═══════ RATE-1: rate ceiling ═══════ */

    function _restrictivePolicy() internal returns (StaticRatePolicy) {
        uint128[] memory rates = new uint128[](1);
        rates[0] = 1;
        uint128[] memory durations = new uint128[](1);
        durations[0] = 0;
        return new StaticRatePolicy(rates, durations);
    }

    function test_rate_reverts_rateExceedsCeiling() public {
        IMigrationRatifier.UserMigrationParams memory params = _defaultMidnightParams();
        params.limitRatePerSecond = 1;
        params.interestRatePolicy = address(_restrictivePolicy());
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        vm.expectRevert(IMigrationRatifier.InvalidOfferRate.selector);
        this.takeExt(targetMarket, 500, 100e18);
    }

    function test_rate_control_succeedsAtParTick() public {
        IMigrationRatifier.UserMigrationParams memory params = _defaultMidnightParams();
        params.limitRatePerSecond = 1;
        params.interestRatePolicy = address(_restrictivePolicy());
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        assertGt(_take(targetMarket, TICK_HIGH, 100e18), 0, "par tick passes restrictive ceiling");
    }

    /* ═══════ Params gate ═══════ */

    function test_params_reverts_paramsNotSet() public {
        vm.prank(borrower);
        defaultRatifier.clearParams(
            borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId
        );
        vm.expectRevert(IMigrationRatifier.InvalidRenewalParams.selector);
        this.takeExt(targetMarket, DEFAULT_TICK, 100e18);
    }
}

/// @title MigrationRatifierDurationRateTest
/// @notice Restores the duration-sensitive tight-rate-boundary coverage, including the post-maturity `_computeDuration`
///         formula guard (`rejectsRateAllowedByOldFormula`). Fees are zeroed so the threshold-rate math is pure
///         duration arithmetic.
contract MigrationRatifierDurationRateTest is MigrationRatifierTestBase {
    using TenorMarketIdLib for Market;

    uint16 internal constant RATE_TEST_TICK = 2800;
    bytes32 internal sourceTenorMarketId;
    bytes32 internal targetTenorMarketId;

    function setUp() public override {
        super.setUp();
        sourceTenorMarketId = sourceMarket.toTenorMarketId();
        targetTenorMarketId = targetMarket.toTenorMarketId();

        // Zero fees so the threshold-rate computation is pure duration math.
        defaultRatifier.setFeeConfig(address(borrowMidnightRenewalCallback), bytes32(0), 0, address(0));
        defaultRatifier.setFeeConfig(address(lendMidnightRenewalCallback), bytes32(0), 0, address(0));

        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        _warpToRenewalWindow(sourceMarket);
    }

    /// @dev Rate where `price(rate, dur) == tickToPrice(tick)`: the ceiling check sits exactly at the boundary.
    function _thresholdRate(uint16 tick, uint256 duration) internal pure returns (uint40) {
        uint256 tickPrice = TickLib.tickToPrice(tick);
        uint256 rate = (WAD * WAD / tickPrice - WAD) / duration;
        require(rate <= type(uint40).max, "rate exceeds uint40");
        return uint40(rate);
    }

    function _makePolicy(uint40 rate) internal returns (StaticRatePolicy) {
        uint128[] memory rates = new uint128[](1);
        rates[0] = rate;
        uint128[] memory durations = new uint128[](1);
        durations[0] = 0;
        return new StaticRatePolicy(rates, durations);
    }

    /// @dev External wrapper so `vm.expectRevert` applies to the whole take (intervening view calls would otherwise
    ///      consume the expectation).
    function takeBorrowExt(uint16 tick, uint256 units) external returns (uint256 ou) {
        (,, ou) = _takeBorrowMidnightRenewal(borrower, lender, units, sourceMarket, targetMarket, tick);
    }

    function test_MidnightToMidnight_borrow_tightDuration() public {
        uint256 expectedDuration = targetMarket.maturity - sourceMarket.maturity;
        uint40 rate = _thresholdRate(RATE_TEST_TICK, expectedDuration) + 1;

        IMigrationRatifier.UserMigrationParams memory params = _defaultBorrowParams();
        params.limitRatePerSecond = rate;
        params.interestRatePolicy = address(_makePolicy(rate));
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        (,, uint256 ou) =
            _takeBorrowMidnightRenewal(borrower, lender, 10e18, sourceMarket, targetMarket, RATE_TEST_TICK);
        assertGt(ou, 0, "borrow passes at tight (correct-duration) rate");
    }

    function test_MidnightToMidnight_borrow_postMaturity_tightDuration() public {
        vm.warp(sourceMarket.maturity + 12 hours);
        uint256 expectedDuration = targetMarket.maturity - block.timestamp; // post-maturity: from now, not
        // sourceMaturity
        uint40 rate = _thresholdRate(RATE_TEST_TICK, expectedDuration) + 1;

        IMigrationRatifier.UserMigrationParams memory params = _defaultBorrowParams();
        params.limitRatePerSecond = rate;
        params.interestRatePolicy = address(_makePolicy(rate));
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        (,, uint256 ou) =
            _takeBorrowMidnightRenewal(borrower, lender, 10e18, sourceMarket, targetMarket, RATE_TEST_TICK);
        assertGt(ou, 0, "post-maturity borrow passes at correct-duration rate");
    }

    /// @dev Highest-value test: post-maturity, a rate that the OLD formula (`targetMaturity - sourceMaturity`) would
    ///      have admitted must be REJECTED, because the correct formula prices `targetMaturity - block.timestamp` (a
    ///      shorter window past maturity), tightening the ceiling.
    function test_MidnightToMidnight_borrow_postMaturity_rejectsRateAllowedByOldFormula() public {
        vm.warp(sourceMarket.maturity + 12 hours);
        uint256 oldDuration = targetMarket.maturity - sourceMarket.maturity;
        uint40 rate = _thresholdRate(RATE_TEST_TICK, oldDuration) + 1;

        IMigrationRatifier.UserMigrationParams memory params = _defaultBorrowParams();
        params.limitRatePerSecond = rate;
        params.interestRatePolicy = address(_makePolicy(rate));
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        vm.expectRevert(IMigrationRatifier.InvalidOfferRate.selector);
        this.takeBorrowExt(RATE_TEST_TICK, 10e18);
    }
}

/// @title MigrationRatifierCrossDirectionTest
/// @notice Cross-direction validation coverage: the V1->V2 entry-cadence path — where `renewalPeriodStart` is
///         derived from the cadence boundary instead of a renewal window (distinct code path in `_ratifyWindow`).
///         Exercised through the Blue->Midnight and Vault->Midnight entries.
contract MigrationRatifierCrossDirectionTest is MigrationRatifierTestBase {
    using TenorMarketIdLib for Market;
    using MarketParamsLib for MarketParams;

    bytes32 internal targetTenorMarketId;

    function setUp() public override {
        super.setUp();
        targetTenorMarketId = targetMarket.toTenorMarketId();
    }

    /* ═══════ Fixtures ═══════ */

    /// @dev Open a Blue borrow position for `borrower` (the migration source) and return its market id.
    function _setupBlueBorrow() internal returns (bytes32 blueMarketId) {
        uint256 blueBorrow = 500e18;
        uint256 blueCollateral = 5000e18;
        loanToken.mint(address(this), blueBorrow * 2);
        loanToken.approve(address(morphoBlue), blueBorrow * 2);
        morphoBlue.supply(blueMarketParams, blueBorrow * 2, 0, address(this), "");
        collateralToken.mint(borrower, blueCollateral);
        vm.startPrank(borrower);
        collateralToken.approve(address(morphoBlue), blueCollateral);
        morphoBlue.supplyCollateral(blueMarketParams, blueCollateral, borrower, "");
        morphoBlue.borrow(blueMarketParams, blueBorrow, 0, borrower, borrower);
        vm.stopPrank();
        blueMarketId = Id.unwrap(MarketParamsLib.id(blueMarketParams));
    }

    function takeBlueToMidnightExt(bytes32 blueMarketId, uint16 tick, uint256 units) external returns (uint256 ou) {
        (,, ou) = _takeBorrowBlueToMidnight(borrower, lender, blueMarketId, units, targetMarket, tick);
    }

    /// @dev Vault->Midnight lend source: lender funds the vault and approves the callback; the counterparty
    ///      (borrower) holds target collateral to sell into the buy offer. Returns the source vault tenor id.
    function _setupVaultLend() internal returns (bytes32 vaultMarketId) {
        uint256 deposit = 5000e18;
        loanToken.mint(lender, deposit);
        vm.startPrank(lender);
        loanToken.approve(address(vault), deposit);
        vault.deposit(deposit, lender);
        vault.approve(address(lendVaultToMidnightCallback), type(uint256).max);
        vm.stopPrank();
        _depositCollateral(borrower, DEFAULT_COLLATERAL_AMOUNT, targetMarket);
        vaultMarketId = TenorMarketIdLib.vaultToTenorMarketId(address(vault));
    }

    function takeVaultToMidnightExt(bytes32 vaultMarketId, uint16 tick, uint256 units) external returns (uint256 ou) {
        (,, ou) = _takeLendVaultToMidnight(lender, borrower, vaultMarketId, units, targetMarket, tick);
    }

    /* ═══════ ORCH-11 (entry path): cadence-derived renewalPeriodStart for V1->V2 ═══════
    */

    function test_cadence_blueToMidnight_reverts_noCadence() public {
        bytes32 blueMarketId = _setupBlueBorrow();
        IMigrationRatifier.UserMigrationParams memory params = _defaultBlueToMidnightParams();
        params.renewalCadence = address(0); // entry path requires a cadence to derive renewalPeriodStart
        _setParams(borrower, address(borrowBlueToMidnightCallback), blueMarketId, targetTenorMarketId, params);

        vm.expectRevert(IMigrationRatifier.InvalidRenewalParams.selector);
        this.takeBlueToMidnightExt(blueMarketId, DEFAULT_TICK, 100e18);
    }

    function test_cadence_blueToMidnight_reverts_futureCadenceBoundary() public {
        bytes32 blueMarketId = _setupBlueBorrow();
        IMigrationRatifier.UserMigrationParams memory params = _defaultBlueToMidnightParams();
        params.renewalCadence = address(new FutureCadence()); // boundary > now -> no valid renewalPeriodStart
        _setParams(borrower, address(borrowBlueToMidnightCallback), blueMarketId, targetTenorMarketId, params);

        vm.expectRevert(IMigrationRatifier.InvalidRenewalParams.selector);
        this.takeBlueToMidnightExt(blueMarketId, DEFAULT_TICK, 100e18);
    }

    function test_cadence_blueToMidnight_succeeds_onBoundary() public {
        bytes32 blueMarketId = _setupBlueBorrow();
        _setParams(
            borrower,
            address(borrowBlueToMidnightCallback),
            blueMarketId,
            targetTenorMarketId,
            _defaultBlueToMidnightParams()
        );

        (,, uint256 units) =
            _takeBorrowBlueToMidnight(borrower, lender, blueMarketId, 100e18, targetMarket, DEFAULT_TICK);
        assertEq(units, 100e18, "units");
        assertEq(midnight.debt(targetMarketId, borrower), units, "target Midnight debt = units");
    }

    function test_cadence_lendVaultToMidnight_reverts_noCadence() public {
        bytes32 vaultMarketId = _setupVaultLend();
        IMigrationRatifier.UserMigrationParams memory params = _defaultVaultToMidnightLendParams();
        params.renewalCadence = address(0);
        _setParams(lender, address(lendVaultToMidnightCallback), vaultMarketId, targetTenorMarketId, params);

        vm.expectRevert(IMigrationRatifier.InvalidRenewalParams.selector);
        this.takeVaultToMidnightExt(vaultMarketId, DEFAULT_TICK, 100e18);
    }

    function test_cadence_lendVaultToMidnight_succeeds_withCadence() public {
        bytes32 vaultMarketId = _setupVaultLend();
        _setParams(
            lender,
            address(lendVaultToMidnightCallback),
            vaultMarketId,
            targetTenorMarketId,
            _defaultVaultToMidnightLendParams()
        );

        (,, uint256 units) =
            _takeLendVaultToMidnight(lender, borrower, vaultMarketId, 100e18, targetMarket, DEFAULT_TICK);
        assertEq(units, 100e18, "units");
        assertEq(midnight.credit(targetMarketId, lender), units, "lender credit on target");
    }
}

/// @title MigrationRatifierFeeBoundaryTest
/// @notice The protocol fee is folded into the rate check (`feeConfig.feeRate` -> `netSellerPrice`/`netBuyerPrice`
///         -> `satisfiesRateLimit` in `BaseMigrationRatifier._ratifyRate`), so a non-zero fee tightens the
///         `InvalidOfferRate` boundary. Each test picks a limit rate strictly between the no-fee threshold and the
///         with-fee threshold: it would pass pre-fee but must REVERT once the fee is composed in. Fees stay ON (the
///         base setUp configures `DEFAULT_FEE_RATE` on the renewal callbacks).
contract MigrationRatifierFeeBoundaryTest is MigrationRatifierTestBase {
    using TenorMarketIdLib for Market;

    uint16 internal constant BORROW_TICK = 2800;
    uint16 internal constant LEND_TICK = 4288;
    bytes32 internal sourceTenorMarketId;
    bytes32 internal targetTenorMarketId;

    function setUp() public override {
        super.setUp();
        sourceTenorMarketId = sourceMarket.toTenorMarketId();
        targetTenorMarketId = targetMarket.toTenorMarketId();
        _warpToRenewalWindow(sourceMarket);
    }

    function _makePolicy(uint40 rate) internal returns (StaticRatePolicy) {
        uint128[] memory rates = new uint128[](1);
        rates[0] = rate;
        uint128[] memory durations = new uint128[](1);
        durations[0] = 0;
        return new StaticRatePolicy(rates, durations);
    }

    function takeBorrowExt(uint16 tick, uint256 units) external returns (uint256 ou) {
        (,, ou) = _takeBorrowMidnightRenewal(borrower, lender, units, sourceMarket, targetMarket, tick);
    }

    function takeLendExt(uint16 tick, uint256 units) external returns (uint256 ou) {
        (,, ou) = _takeLendMidnightRenewal(lender, borrower, units, sourceMarket, targetMarket, tick);
    }

    function test_borrow_feeShiftsRateBoundary() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);

        uint256 expectedDuration = targetMarket.maturity - sourceMarket.maturity;
        uint256 units = 100e18;
        uint256 tickPrice = TickLib.tickToPrice(BORROW_TICK);
        uint256 assets = (units * tickPrice) / WAD;
        uint256 net = assets - CallbackLib.sellerFeeFromTick(BORROW_TICK, DEFAULT_FEE_RATE, units, assets);

        // Seller fee lowers the borrower's net price, so the with-fee threshold rate is higher than the no-fee one.
        uint256 noFeeRate = (WAD * WAD / tickPrice - WAD) / expectedDuration;
        uint256 withFeeRate = (WAD * WAD / ((net * WAD) / units) - WAD) / expectedDuration;
        uint40 gapRate = uint40(noFeeRate + (withFeeRate - noFeeRate) / 2);

        IMigrationRatifier.UserMigrationParams memory params = _defaultBorrowParams();
        params.limitRatePerSecond = gapRate;
        params.interestRatePolicy = address(_makePolicy(gapRate));
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        // Passes pre-fee (gapRate > noFeeRate) but the fee tightens past gapRate -> revert.
        vm.expectRevert(IMigrationRatifier.InvalidOfferRate.selector);
        this.takeBorrowExt(BORROW_TICK, units);
    }

    function test_lend_feeShiftsRateBoundary() public {
        _setupLenderWithCredit(lender, uint128(DEFAULT_LEND_AMOUNT), sourceMarket, sourceMarketId);
        // Withdrawable balance on source (a temp borrower borrows + repays).
        (address tempBorrower, uint256 tempBorrowerSK) = makeAddrAndKey("tempBorrower");
        _setupBorrowerWithDebt(tempBorrower, tempBorrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        loanToken.mint(tempBorrower, DEFAULT_BORROW_AMOUNT);
        vm.startPrank(tempBorrower);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.repay(sourceMarket, DEFAULT_BORROW_AMOUNT, tempBorrower, address(0), "");
        vm.stopPrank();
        // Counterparty (borrower) takes as seller — needs collateral on target for health.
        _depositCollateral(borrower, DEFAULT_COLLATERAL_AMOUNT, targetMarket);

        uint256 expectedDuration = targetMarket.maturity - sourceMarket.maturity;
        uint256 units = 100e18;
        uint256 tickPrice = TickLib.tickToPrice(LEND_TICK);
        uint256 assets = (units * tickPrice + WAD - 1) / WAD;
        uint256 cost = assets + CallbackLib.buyerFeeFromTick(LEND_TICK, DEFAULT_FEE_RATE, units, assets);

        // Buyer fee raises the lender's cost, so the with-fee threshold rate is lower than the no-fee one.
        uint256 noFeeRate = (WAD * WAD / tickPrice - WAD) / expectedDuration;
        uint256 withFeeRate = (WAD * WAD / ((cost * WAD) / units) - WAD) / expectedDuration;
        uint40 gapRate = uint40(withFeeRate + (noFeeRate - withFeeRate) / 2);

        IMigrationRatifier.UserMigrationParams memory params = _defaultLendParams();
        params.limitRatePerSecond = gapRate;
        params.interestRatePolicy = address(_makePolicy(gapRate));
        _setParams(lender, address(lendMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        vm.expectRevert(IMigrationRatifier.InvalidOfferRate.selector);
        this.takeLendExt(LEND_TICK, units);
    }
}
