// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {MigrationRatifierTestBase} from "../helpers/MigrationRatifierTestBase.sol";
import {IMigrationRatifier} from "../../src/ratifiers/interfaces/IMigrationRatifier.sol";
import {IInterestRatePolicy} from "@ratifiers/interfaces/IInterestRatePolicy.sol";
import {IMidnight, Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";
import {StaticRatePolicy} from "../../src/ratifiers/policies/StaticRatePolicy.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {MAX_FEE_RATE} from "../../src/ratifiers/BaseMigrationRatifier.sol";
import {MarketParams, Id} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {IBorrowMidnightToBlueCallback} from "@callbacks/interfaces/IBorrowMidnightToBlueCallback.sol";
import {Oracle} from "../helpers/Oracle.sol";

/// @dev Interest-rate policy that attempts to reenter Midnight from within `getRate`. Because `isRatified` is a
///      `view` function, Midnight calls it via STATICCALL, so any state-mutating reentry reverts and is sandboxed.
contract ReentrantPolicy is IInterestRatePolicy {
    address public midnight;
    bytes public reentrantCalldata;

    constructor(address _midnight) {
        midnight = _midnight;
    }

    function setReentrantCall(bytes memory data) external {
        reentrantCalldata = data;
    }

    function getRate(bytes32, bytes32, uint256, address, uint256, uint256, bool)
        external
        view
        override
        returns (uint256)
    {
        if (reentrantCalldata.length > 0) {
            address target = midnight;
            bytes memory data = reentrantCalldata;
            bool success;
            assembly ("memory-safe") {
                success := staticcall(gas(), target, add(data, 0x20), mload(data), 0, 0)
            }
            // success is false under STATICCALL because the reentrant call mutates state.
        }
        return 1e15;
    }
}

/// @title AdversarialScenariosTest
/// @notice Probes MigrationRatifier under adversarial inputs in the maker-on-behalf model: dust takes,
///         overflow-sized rates, oracle manipulation, reentrancy via policy, max fee rate, extreme ticks.
contract AdversarialScenariosTest is MigrationRatifierTestBase {
    using TenorMarketIdLib for Market;
    using MarketParamsLib for MarketParams;

    bytes32 internal sourceTenorMarketId;
    bytes32 internal targetTenorMarketId;

    function setUp() public override {
        super.setUp();
        sourceTenorMarketId = sourceMarket.toTenorMarketId();
        targetTenorMarketId = targetMarket.toTenorMarketId();
    }

    /* ═══════ Local maker-on-behalf take helpers (borrow renewal) ═══════ */

    function _borrowRenewalOffer(Market memory srcObl, Market memory tgtObl, uint16 tick)
        internal
        view
        returns (Offer memory)
    {
        bytes memory cbd = _encodeBorrowMidnightRenewalCallbackData(srcObl, tick);
        return _migrationOffer(borrower, tgtObl, false, tick, address(borrowMidnightRenewalCallback), cbd);
    }

    function _takeBorrowRenewal(uint256 takeUnits, Market memory srcObl, Market memory tgtObl, uint16 tick)
        internal
        returns (uint256, uint256, uint256)
    {
        return _takeBorrowMidnightRenewal(borrower, lender, takeUnits, srcObl, tgtObl, tick);
    }

    /// @dev External wrapper so try/catch can capture reverts in drydock probes.
    function takeBorrowRenewalDrydock(uint256 takeUnits, Market memory srcObl, Market memory tgtObl, uint16 tick)
        external
        returns (uint256, uint256, uint256)
    {
        return _takeBorrowMidnightRenewal(borrower, lender, takeUnits, srcObl, tgtObl, tick);
    }

    /* ═══════ Dust renewal: 1 unit of a large debt settles cleanly, no corruption ═══════
    */

    /// @dev In the maker-on-behalf model a single-unit renewal of a huge debt either reverts cleanly or settles to a
    ///      tiny valid position. Pins that it does not silently corrupt state or strand funds in the callback.
    function test_dustRenewal_1unitOf1millionDebt() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, 1_000_000e18, sourceMarket, sourceMarketId);
        _setParams(
            borrower,
            address(borrowMidnightRenewalCallback),
            sourceTenorMarketId,
            targetTenorMarketId,
            _defaultMidnightParams()
        );
        _warpToRenewalWindow(sourceMarket);

        uint256 srcBefore = midnight.debt(sourceMarketId, borrower);
        Offer memory offer = _borrowRenewalOffer(sourceMarket, targetMarket, DEFAULT_TICK);
        vm.prank(lender);
        try midnight.take(
            offer, abi.encode(sourceTenorMarketId, targetTenorMarketId), 1, lender, address(0), address(0), ""
        ) {
            assertEq(midnight.debt(targetMarketId, borrower), 1, "dust: target debt == 1 unit");
            assertLe(srcBefore - midnight.debt(sourceMarketId, borrower), 1, "dust: source debt reduced by <= 1");
            assertEq(loanToken.balanceOf(address(borrowMidnightRenewalCallback)), 0, "dust: no loan-token dust");
            assertEq(collateralToken.balanceOf(address(borrowMidnightRenewalCallback)), 0, "dust: no collateral dust");
        } catch (bytes memory reason) {
            _assertNoArithmeticPanic(reason);
        }
    }

    /* ═══════ Malicious policy with extreme rate — no arithmetic panic ═══════ */

    function test_maliciousPolicy_overflowRate() public {
        uint128[] memory rates = new uint128[](1);
        rates[0] = type(uint128).max;
        uint128[] memory durations = new uint128[](1);
        durations[0] = 0;
        StaticRatePolicy maliciousPolicy = new StaticRatePolicy(rates, durations);

        IMigrationRatifier.UserMigrationParams memory params = _defaultBorrowParams();
        params.interestRatePolicy = address(maliciousPolicy);
        params.limitRatePerSecond = type(uint40).max;

        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);
        _warpToRenewalWindow(sourceMarket);

        // No panic: min(policy, limit) clamps to uint40, and uint40 * uint256(dur) fits in uint256.
        try this.takeBorrowRenewalDrydock(100e18, sourceMarket, targetMarket, DEFAULT_TICK) {}
        catch (bytes memory reason) {
            _assertNoArithmeticPanic(reason);
        }
    }

    /* ═══════ Zero-duration boundary ═══════ */

    function test_zeroDuration_atExactMaturityBoundary() public {
        Market memory sameTarget = _cloneTarget(sourceMarket.maturity);
        bytes32 sameMktId = sameTarget.toTenorMarketId();
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);

        IMigrationRatifier.UserMigrationParams memory params = _defaultBorrowParams();
        params.minDuration = 1;
        params.maxDuration = uint32(365 days);
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, sameMktId, params);

        _warpToRenewalWindow(sourceMarket);
        _seedMarket(sameTarget, IdLib.toId(sameTarget));

        Offer memory offer1 = _borrowRenewalOffer(sourceMarket, sameTarget, DEFAULT_TICK);
        vm.prank(lender);
        vm.expectRevert(IMigrationRatifier.InvalidTargetMaturity.selector);
        midnight.take(offer1, abi.encode(sourceTenorMarketId, sameMktId), 100e18, lender, address(0), address(0), "");

        // Part B: target maturity = source + 1s — passes only at near-par tick.
        Market memory oneSecTarget = _cloneTarget(sourceMarket.maturity + 1);
        bytes32 oneSecMktId = oneSecTarget.toTenorMarketId();
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, oneSecMktId, params);
        _seedMarket(oneSecTarget, IdLib.toId(oneSecTarget));

        (,, uint256 ou) = _takeBorrowRenewal(100e18, sourceMarket, oneSecTarget, uint16(MAX_TICK));
        assertGt(ou, 0, "1s duration at near-par tick succeeds");
    }

    /* ═══════ minDuration=1 + instant extension, then expired target ═══════ */

    function test_minDurationSmall_instantMaturity() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        _warpToRenewalWindow(sourceMarket);

        Market memory instantTgt = _cloneTarget(sourceMarket.maturity + 1);
        bytes32 instantMktId = instantTgt.toTenorMarketId();
        _seedMarket(instantTgt, IdLib.toId(instantTgt));

        IMigrationRatifier.UserMigrationParams memory params = _defaultBorrowParams();
        params.minDuration = 1;
        params.maxDuration = uint32(365 days);
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, instantMktId, params);

        (,, uint256 ou) = _takeBorrowRenewal(100e18, sourceMarket, instantTgt, uint16(MAX_TICK));
        assertGt(ou, 0, "near-instant maturity extension succeeds at par");

        // Part B: target maturity in the past → reverts.
        Market memory freshSrc = _cloneTarget(block.timestamp + 30 days);
        bytes32 freshSrcId = IdLib.toId(freshSrc);
        _seedMarket(freshSrc, freshSrcId);
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, freshSrc, freshSrcId);

        vm.warp(instantTgt.maturity + 2);

        params.renewalWindow = uint32(30 days);
        _setParams(borrower, address(borrowMidnightRenewalCallback), freshSrc.toTenorMarketId(), instantMktId, params);

        Offer memory offer2 = _borrowRenewalOffer(freshSrc, instantTgt, uint16(MAX_TICK));
        vm.prank(lender);
        vm.expectRevert(IMigrationRatifier.InvalidTargetMaturity.selector);
        midnight.take(
            offer2, abi.encode(freshSrc.toTenorMarketId(), instantMktId), 100e18, lender, address(0), address(0), ""
        );
    }

    /* ═══════ Max fee rate: 50% of interest ═══════ */

    function test_renewalWithMaxFeeRate() public {
        defaultRatifier.setFeeConfig(address(borrowMidnightRenewalCallback), bytes32(0), MAX_FEE_RATE, feeRecipient);

        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        _setParams(
            borrower,
            address(borrowMidnightRenewalCallback),
            sourceTenorMarketId,
            targetTenorMarketId,
            _defaultMidnightParams()
        );
        _warpToRenewalWindow(sourceMarket);

        uint256 debtBefore = midnight.debt(sourceMarketId, borrower);
        uint256 feeBalBefore = loanToken.balanceOf(feeRecipient);

        (uint256 buyerAssets, uint256 sellerAssets, uint256 ou) =
            _takeBorrowRenewal(100e18, sourceMarket, targetMarket, DEFAULT_TICK);

        uint256 expectedFee = CallbackLib.sellerFeeFromTick(DEFAULT_TICK, MAX_FEE_RATE, ou, buyerAssets);
        assertGt(expectedFee, 0, "fee > 0 at 50%");
        assertEq(sellerAssets, buyerAssets, "raw sellerAssets == buyerAssets");
        assertEq(loanToken.balanceOf(feeRecipient) - feeBalBefore, expectedFee, "fee paid exactly");

        uint256 repayBudget = buyerAssets - expectedFee;
        assertEq(
            debtBefore - midnight.debt(sourceMarketId, borrower), repayBudget, "source debt decreased by repayBudget"
        );
        assertEq(midnight.debt(targetMarketId, borrower), ou, "target debt == units");
        assertGt(ou, repayBudget, "fee creates market > repayment gap");
    }

    /* ═══════ Reentrancy via policy (getRate is view → STATICCALL) ═══════ */

    function test_reentrancy_viaPolicy() public {
        ReentrantPolicy badPolicy = new ReentrantPolicy(address(midnight));
        // A state-mutating Midnight call — reverts under the STATICCALL through which getRate runs.
        badPolicy.setReentrantCall(abi.encodeCall(midnight.touchMarket, (sourceMarket)));

        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        IMigrationRatifier.UserMigrationParams memory params = _defaultBorrowParams();
        params.interestRatePolicy = address(badPolicy);
        _setParams(borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);
        _warpToRenewalWindow(sourceMarket);

        try this.takeBorrowRenewalDrydock(100e18, sourceMarket, targetMarket, DEFAULT_TICK) {}
        catch (bytes memory reason) {
            _assertNoArithmeticPanic(reason);
        }
    }

    /* ═══════ Oracle manipulation between renewals — no arithmetic panic ═══════ */

    function test_oracleManipulation_priceDropBetweenRenewals() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        _setParams(
            borrower,
            address(borrowMidnightRenewalCallback),
            sourceTenorMarketId,
            targetTenorMarketId,
            _defaultMidnightParams()
        );

        oracle.setPrice(0);
        _warpToRenewalWindow(sourceMarket);

        try this.takeBorrowRenewalDrydock(100e18, sourceMarket, targetMarket, DEFAULT_TICK) {
            assertGt(midnight.debt(targetMarketId, borrower), 0, "target debt exists after renewal");
        } catch (bytes memory reason) {
            _assertNoArithmeticPanic(reason);
        }
    }

    function test_oracleManipulation_priceSpikeBetweenRenewals() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        _setParams(
            borrower,
            address(borrowMidnightRenewalCallback),
            sourceTenorMarketId,
            targetTenorMarketId,
            _defaultMidnightParams()
        );

        oracle.setPrice(type(uint128).max);
        _warpToRenewalWindow(sourceMarket);

        try this.takeBorrowRenewalDrydock(100e18, sourceMarket, targetMarket, DEFAULT_TICK) {}
        catch (bytes memory reason) {
            _assertNoArithmeticPanic(reason);
        }
    }

    /* ═══════ Extreme-tick (tick=1) cleanly rejected ═══════ */

    /// @dev At tick=1 the price is off the market's tick grid, so Midnight rejects the offer with
    ///      `TickNotAccessible` before invoking the ratifier — a clean rejection of an extreme tick on the
    ///      maker-on-behalf path. (The ratifier-side `InvalidOfferRate` rate-ceiling check is covered by the
    ///      continuous-fee reject test.)
    function test_feeExceedsAssets_extremeTick() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        _setParams(
            borrower,
            address(borrowMidnightRenewalCallback),
            sourceTenorMarketId,
            targetTenorMarketId,
            _defaultMidnightParams()
        );
        _warpToRenewalWindow(sourceMarket);

        Offer memory offerA = _borrowRenewalOffer(sourceMarket, targetMarket, 1);
        vm.prank(lender);
        vm.expectRevert(IMidnight.TickNotAccessible.selector);
        midnight.take(
            offerA, abi.encode(sourceTenorMarketId, targetTenorMarketId), 1, lender, address(0), address(0), ""
        );

        Offer memory offerB = _borrowRenewalOffer(sourceMarket, targetMarket, 1);
        vm.prank(lender);
        vm.expectRevert(IMidnight.TickNotAccessible.selector);
        midnight.take(
            offerB, abi.encode(sourceTenorMarketId, targetTenorMarketId), 1e5, lender, address(0), address(0), ""
        );
    }

    /* ═══════ Midnight→Blue migration with v1 oracle returning 0 ═══════ */

    function test_v1Oracle_returnsZero_duringMigration() public {
        Oracle zeroOracle = new Oracle();
        zeroOracle.setPrice(0);

        MarketParams memory zeroBlueMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(zeroOracle),
            irm: address(morphoIrm),
            lltv: 0.77e18
        });
        morphoBlue.createMarket(zeroBlueMarketParams);
        bytes32 zeroBlueMarketId = Id.unwrap(zeroBlueMarketParams.id());

        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);

        loanToken.mint(address(this), DEFAULT_BORROW_AMOUNT * 2);
        loanToken.approve(address(morphoBlue), DEFAULT_BORROW_AMOUNT * 2);
        morphoBlue.supply(zeroBlueMarketParams, DEFAULT_BORROW_AMOUNT * 2, 0, address(this), "");

        _setParams(
            borrower, address(borrowMidnightToBlueCallback), sourceTenorMarketId, zeroBlueMarketId, _defaultLendParams()
        );
        _warpToRenewalWindow(sourceMarket);

        // Counterparty (keeper) sells on source — needs source collateral + loan funds.
        _depositCollateral(keeper, DEFAULT_COLLATERAL_AMOUNT * 2, sourceMarket);
        loanToken.mint(keeper, type(uint128).max);
        vm.prank(keeper);
        loanToken.approve(address(midnight), type(uint256).max);

        try this.takeBorrowMidnightToBlueDrydock(100e18, zeroBlueMarketId) {
            revert("expected revert: zero oracle prevents Blue borrow");
        } catch (bytes memory reason) {
            _assertNoArithmeticPanic(reason);
        }
    }

    function takeBorrowMidnightToBlueDrydock(uint256 takeUnits, bytes32 targetBlueMarketId)
        external
        returns (uint256, uint256, uint256)
    {
        return _takeBorrowMidnightToBlue(borrower, keeper, targetBlueMarketId, takeUnits, sourceMarket, DEFAULT_TICK);
    }

    /* ═══════ Helpers ═══════ */

    function _assertNoArithmeticPanic(bytes memory reason) internal pure {
        if (reason.length >= 36 && bytes4(reason) == bytes4(0x4e487b71)) {
            uint256 code;
            assembly ("memory-safe") {
                code := mload(add(reason, 36))
            }
            assertTrue(code != 0x11, "arithmetic overflow panic (0x11)");
        }
    }
}
