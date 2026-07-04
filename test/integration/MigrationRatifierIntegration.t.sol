// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {MigrationRatifierTestBase} from "../helpers/MigrationRatifierTestBase.sol";
import {IMigrationRatifier} from "../../src/ratifiers/interfaces/IMigrationRatifier.sol";
import {IMidnight, Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {WAD, MAX_CONTINUOUS_FEE} from "@midnight/libraries/ConstantsLib.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";
import {StaticRatePolicy} from "../../src/ratifiers/policies/StaticRatePolicy.sol";
import {Id} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";

/// @title MigrationRatifierIntegrationTest
/// @notice End-to-end tests for the maker-on-behalf migration model: the migrating user is the offer MAKER, the
///         migration callback is the maker's `offer.callback`, the offer's ratifier is `MigrationRatifier`,
///         and a counterparty takes via `midnight.take` (which invokes `isRatified`). Covers the Midnight↔Midnight
///         renewal happy paths plus core authorization/guard negatives.
contract MigrationRatifierIntegrationTest is MigrationRatifierTestBase {
    using TenorMarketIdLib for Market;

    bytes32 internal sourceTenorMarketId;
    bytes32 internal targetTenorMarketId;

    function setUp() public override {
        super.setUp();
        sourceTenorMarketId = sourceMarket.toTenorMarketId();
        targetTenorMarketId = targetMarket.toTenorMarketId();
    }

    /* ═══════════════════════════════════════════════════════════════
       Borrow renewal — user is maker-seller (buy=false), lender takes
       ═══════════════════════════════════════════════════════════════ */

    function test_borrowMidnightRenewal_happyPath() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);

        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);
        assertEq(sourceDebtBefore, DEFAULT_BORROW_AMOUNT, "precondition: source debt");

        _setParams(
            borrower,
            address(borrowMidnightRenewalCallback),
            sourceTenorMarketId,
            targetTenorMarketId,
            _defaultMidnightParams()
        );
        _warpToRenewalWindow(sourceMarket);

        uint256 takeUnits = 100e18;
        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        (uint256 buyerAssets,, uint256 units) =
            _takeBorrowMidnightRenewal(borrower, lender, takeUnits, sourceMarket, targetMarket, DEFAULT_TICK);

        assertEq(units, takeUnits, "units == takeUnits");
        assertEq(buyerAssets, takeUnits * TickLib.tickToPrice(DEFAULT_TICK) / WAD, "buyerAssets == floor(units*price)");
        assertGt(loanToken.balanceOf(feeRecipient) - feeRecipientBefore, 0, "fee recipient received fee");

        assertLt(midnight.debt(sourceMarketId, borrower), sourceDebtBefore, "source debt decreased");
        assertEq(midnight.debt(targetMarketId, borrower), units, "target debt = units");

        assertEq(loanToken.balanceOf(address(borrowMidnightRenewalCallback)), 0, "no loan token dust");
        assertEq(collateralToken.balanceOf(address(borrowMidnightRenewalCallback)), 0, "no collateral dust");
    }

    function test_borrowMidnightRenewal_revertsWithoutParams() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        // Authorize the ratifier on Midnight but DO NOT set params.
        vm.prank(borrower);
        midnight.setIsAuthorized(address(defaultRatifier), true, borrower);
        _warpToRenewalWindow(sourceMarket);

        bytes memory cbd = _encodeBorrowMidnightRenewalCallbackData(sourceMarket, DEFAULT_TICK);
        Offer memory offer =
            _migrationOffer(borrower, targetMarket, false, DEFAULT_TICK, address(borrowMidnightRenewalCallback), cbd);
        bytes memory rd = abi.encode(sourceTenorMarketId, targetTenorMarketId);

        vm.expectRevert(IMigrationRatifier.InvalidRenewalParams.selector);
        vm.prank(lender);
        midnight.take(offer, rd, 100e18, lender, address(0), address(0), "");
    }

    function test_borrowMidnightRenewal_revertsWhenRatifierNotAuthorizedOnMidnight() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        // Set params on the ratifier but DO NOT authorize it on Midnight.
        vm.prank(borrower);
        defaultRatifier.setParams(
            borrower,
            address(borrowMidnightRenewalCallback),
            sourceTenorMarketId,
            targetTenorMarketId,
            _defaultMidnightParams()
        );
        _warpToRenewalWindow(sourceMarket);

        bytes memory cbd = _encodeBorrowMidnightRenewalCallbackData(sourceMarket, DEFAULT_TICK);
        Offer memory offer =
            _migrationOffer(borrower, targetMarket, false, DEFAULT_TICK, address(borrowMidnightRenewalCallback), cbd);
        bytes memory rd = abi.encode(sourceTenorMarketId, targetTenorMarketId);

        vm.expectRevert(IMidnight.RatifierUnauthorized.selector);
        vm.prank(lender);
        midnight.take(offer, rd, 100e18, lender, address(0), address(0), "");
    }

    /* ═══════════════════════════════════════════════════════════════
       Lend renewal — user is maker-buyer (buy=true), borrower takes
       ═══════════════════════════════════════════════════════════════ */

    function test_lendMidnightRenewal_happyPath() public {
        _setupLenderWithCredit(lender, uint128(DEFAULT_LEND_AMOUNT), sourceMarket, sourceMarketId);

        // Create withdrawable balance on source (temp borrower borrows + repays).
        (address tempBorrower, uint256 tempBorrowerSK) = makeAddrAndKey("tempBorrower");
        _setupBorrowerWithDebt(tempBorrower, tempBorrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        loanToken.mint(tempBorrower, DEFAULT_BORROW_AMOUNT);
        vm.prank(tempBorrower);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.prank(tempBorrower);
        midnight.repay(sourceMarket, DEFAULT_BORROW_AMOUNT, tempBorrower, address(0), "");
        assertGt(midnight.withdrawable(sourceMarketId), 0, "precondition: withdrawable > 0");

        _setParams(
            lender, address(lendMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, _defaultLendParams()
        );
        _warpToRenewalWindow(sourceMarket);

        // Counterparty (borrower) takes as seller — needs collateral on target for health.
        _depositCollateral(borrower, DEFAULT_COLLATERAL_AMOUNT, targetMarket);

        uint256 takeUnits = 50e18;
        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        (, uint256 sellerAssets, uint256 units) =
            _takeLendMidnightRenewal(lender, borrower, takeUnits, sourceMarket, targetMarket, DEFAULT_TICK);

        assertEq(units, takeUnits, "units == takeUnits");
        assertEq(
            sellerAssets, takeUnits * TickLib.tickToPrice(DEFAULT_TICK) / WAD, "sellerAssets == floor(units*price)"
        );
        assertGt(loanToken.balanceOf(feeRecipient) - feeRecipientBefore, 0, "fee recipient received fee");
        assertEq(midnight.credit(targetMarketId, lender), units, "lender credit on target");
    }

    /* ═══════════════════════════════════════════════════════════════
       Ratifier guards surfaced through Midnight
       ═══════════════════════════════════════════════════════════════ */

    function test_revert_wrongGroupNamespace() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        _setParams(
            borrower,
            address(borrowMidnightRenewalCallback),
            sourceTenorMarketId,
            targetTenorMarketId,
            _defaultMidnightParams()
        );
        _warpToRenewalWindow(sourceMarket);

        // Build an offer with a NON-reserved group.
        bytes memory cbd = _encodeBorrowMidnightRenewalCallbackData(sourceMarket, DEFAULT_TICK);
        Offer memory offer =
            _migrationOffer(borrower, targetMarket, false, DEFAULT_TICK, address(borrowMidnightRenewalCallback), cbd);
        offer.group = _freshGroup(); // not stamped with MIGRATION_GROUP_HEADER

        vm.expectRevert(); // InvalidGroup via RatifierFail
        vm.prank(lender);
        midnight.take(
            offer, abi.encode(sourceTenorMarketId, targetTenorMarketId), 100e18, lender, address(0), address(0), ""
        );
    }

    /* ═══════════════════════════════════════════════════════════════
       Blue→Midnight borrow entry — user maker-seller (buy=false), lender buys
       ═══════════════════════════════════════════════════════════════ */

    function test_borrowBlueToMidnight_happyPath() public {
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

        bytes32 blueMarketId = Id.unwrap(MarketParamsLib.id(blueMarketParams));
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
        assertEq(loanToken.balanceOf(address(borrowBlueToMidnightCallback)), 0, "no dust");
    }

    /* ═══════════════════════════════════════════════════════════════
       Vault→Midnight lend entry — user maker-buyer (buy=true), borrower sells
       ═══════════════════════════════════════════════════════════════ */

    function test_lendVaultToMidnight_happyPath() public {
        uint256 deposit = 5000e18;
        loanToken.mint(lender, deposit);
        vm.startPrank(lender);
        loanToken.approve(address(vault), deposit);
        vault.deposit(deposit, lender);
        vault.approve(address(lendVaultToMidnightCallback), type(uint256).max);
        vm.stopPrank();

        // Counterparty (borrower) sells into the user's buy offer — needs target collateral.
        _depositCollateral(borrower, DEFAULT_COLLATERAL_AMOUNT, targetMarket);

        bytes32 vaultMarketId = TenorMarketIdLib.vaultToTenorMarketId(address(vault));
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
        assertEq(loanToken.balanceOf(address(lendVaultToMidnightCallback)), 0, "no dust");
    }

    /* ═══════════════════════════════════════════════════════════════
       Midnight→Blue borrow exit — user maker-buyer (buy=true), counterparty sells
       ═══════════════════════════════════════════════════════════════ */

    function test_borrowMidnightToBlue_happyPath() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        loanToken.mint(address(this), DEFAULT_BORROW_AMOUNT * 2);
        loanToken.approve(address(morphoBlue), DEFAULT_BORROW_AMOUNT * 2);
        morphoBlue.supply(blueMarketParams, DEFAULT_BORROW_AMOUNT * 2, 0, address(this), "");

        bytes32 blueTargetMarketId = Id.unwrap(MarketParamsLib.id(blueMarketParams));
        _setParams(
            borrower,
            address(borrowMidnightToBlueCallback),
            sourceTenorMarketId,
            blueTargetMarketId,
            _defaultLendParams()
        );
        _warpToRenewalWindow(sourceMarket);

        // Counterparty (keeper) sells on source — needs source collateral.
        _depositCollateral(keeper, DEFAULT_COLLATERAL_AMOUNT * 2, sourceMarket);

        (,, uint256 units) =
            _takeBorrowMidnightToBlue(borrower, keeper, blueTargetMarketId, 100e18, sourceMarket, DEFAULT_TICK);
        assertEq(units, 100e18, "units");
        assertEq(loanToken.balanceOf(address(borrowMidnightToBlueCallback)), 0, "no dust");
    }

    /* ═══════════════════════════════════════════════════════════════
       Midnight→Vault lend exit — user maker-seller (buy=false), lender buys
       ═══════════════════════════════════════════════════════════════ */

    function test_lendMidnightToVault_happyPath() public {
        _setupLenderWithCredit(lender, uint128(DEFAULT_LEND_AMOUNT), sourceMarket, sourceMarketId);

        bytes32 vaultMarketId = TenorMarketIdLib.vaultToTenorMarketId(address(vault));
        // Midnight→Vault lend uses isBuy=false → permissive ceiling (borrow params).
        _setParams(
            lender, address(lendMidnightToVaultCallback), sourceTenorMarketId, vaultMarketId, _defaultBorrowParams()
        );

        vm.prank(lender);
        loanToken.approve(address(lendMidnightToVaultCallback), type(uint256).max);
        _warpToRenewalWindow(sourceMarket);

        // Counterparty (keeper) buys the user's sold credit — needs loan tokens + Midnight approval.
        loanToken.mint(keeper, type(uint128).max);
        vm.prank(keeper);
        loanToken.approve(address(midnight), type(uint256).max);

        // tick near par so the permissive ceiling passes.
        (,, uint256 units) = _takeLendMidnightToVault(lender, keeper, vaultMarketId, 100e18, sourceMarket, 5220);
        assertEq(units, 100e18, "units");
        assertLt(midnight.credit(sourceMarketId, lender), DEFAULT_LEND_AMOUNT, "source credit drained");
        assertGt(vault.balanceOf(lender), 0, "vault position created");
        assertEq(loanToken.balanceOf(address(lendMidnightToVaultCallback)), 0, "no dust");
    }

    /* ═══════════════════════════════════════════════════════════════
       Market-specific fee config overrides the action-level default
       ═══════════════════════════════════════════════════════════════ */

    function _independentSellerFee(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal
        pure
        returns (uint256)
    {
        if (feeRate == 0) return 0;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 x = (WAD - price) * feeRate / WAD;
        uint256 effPrice = (price * WAD + (WAD + x) - 1) / (WAD + x);
        uint256 budget = (units * effPrice + WAD - 1) / WAD;
        return assets > budget ? assets - budget : 0;
    }

    function test_borrowMidnightRenewal_marketFeeOverridesActionFee() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);

        uint256 marketFeeRate = 0.005e18;
        address marketFeeAddr = makeAddr("marketFeeRecipient");
        defaultRatifier.setFeeConfig(
            address(borrowMidnightRenewalCallback), targetTenorMarketId, marketFeeRate, marketFeeAddr
        );

        (address actionRecipient, uint96 actionRate) =
            defaultRatifier.feeConfigs(address(borrowMidnightRenewalCallback), bytes32(0));
        assertEq(actionRate, uint96(DEFAULT_FEE_RATE), "precondition: action fee rate set");
        assertEq(actionRecipient, feeRecipient, "precondition: action fee recipient set");

        _setParams(
            borrower,
            address(borrowMidnightRenewalCallback),
            sourceTenorMarketId,
            targetTenorMarketId,
            _defaultMidnightParams()
        );
        _warpToRenewalWindow(sourceMarket);

        uint256 marketRecipientBefore = loanToken.balanceOf(marketFeeAddr);
        uint256 actionRecipientBefore = loanToken.balanceOf(feeRecipient);

        (uint256 buyerAssets, uint256 sellerAssets, uint256 units) =
            _takeBorrowMidnightRenewal(borrower, lender, 100e18, sourceMarket, targetMarket, DEFAULT_TICK);

        uint256 expectedMarketFee = _independentSellerFee(DEFAULT_TICK, marketFeeRate, units, buyerAssets);
        assertGt(expectedMarketFee, 0, "market fee > 0");
        assertEq(
            loanToken.balanceOf(marketFeeAddr) - marketRecipientBefore, expectedMarketFee, "market recipient got fee"
        );
        assertEq(loanToken.balanceOf(feeRecipient) - actionRecipientBefore, 0, "action recipient got nothing");
        assertEq(sellerAssets, buyerAssets, "raw seller assets pass-through");
        assertTrue(
            expectedMarketFee != _independentSellerFee(DEFAULT_TICK, DEFAULT_FEE_RATE, units, buyerAssets),
            "market fee differs from action fee"
        );
    }

    /* ═══════════════════════════════════════════════════════════════
       Continuous-fee interaction on Midnight-target lend (_effectiveUnitsPerWad)
       ═══════════════════════════════════════════════════════════════ */

    function _setupLendRenewalWithContinuousFee() internal {
        _setupLenderWithCredit(lender, uint128(DEFAULT_LEND_AMOUNT), sourceMarket, sourceMarketId);

        (address tempBorrower2, uint256 tempBorrower2SK) = makeAddrAndKey("tempBorrower2-cf");
        _setupBorrowerWithDebt(tempBorrower2, tempBorrower2SK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        loanToken.mint(tempBorrower2, DEFAULT_BORROW_AMOUNT);
        vm.startPrank(tempBorrower2);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.repay(sourceMarket, DEFAULT_BORROW_AMOUNT, tempBorrower2, address(0), "");
        vm.stopPrank();

        midnight.setFeeSetter(address(this));
        midnight.setMarketContinuousFee(targetMarketId, MAX_CONTINUOUS_FEE);

        _warpToRenewalWindow(sourceMarket);
        _depositCollateral(borrower, DEFAULT_COLLATERAL_AMOUNT, targetMarket);
    }

    function test_lendMidnightRenewal_rejectsWithContinuousFee() public {
        _setupLendRenewalWithContinuousFee();

        uint256 offerPrice = TickLib.tickToPrice(DEFAULT_TICK);
        uint256 rateDuration = targetMarket.maturity - sourceMarket.maturity;
        uint256 impliedRate = (WAD - offerPrice) * WAD / (offerPrice * rateDuration);

        IMigrationRatifier.UserMigrationParams memory params = _defaultLendParams();
        params.limitRatePerSecond = uint40(impliedRate);
        _setParams(lender, address(lendMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params);

        // The continuous fee erodes the effective face value below the user's limit → InvalidOfferRate.
        bytes memory cbd = _encodeLendMidnightRenewalCallbackData(sourceMarket, DEFAULT_TICK);
        Offer memory offer =
            _migrationOffer(lender, targetMarket, true, DEFAULT_TICK, address(lendMidnightRenewalCallback), cbd);

        vm.expectRevert(); // InvalidOfferRate via RatifierFail
        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sourceTenorMarketId, targetTenorMarketId), 50e18, borrower, borrower, address(0), ""
        );
    }

    function test_lendMidnightRenewal_succeedsWithContinuousFee_permissiveLimit() public {
        _setupLendRenewalWithContinuousFee();
        _setParams(
            lender, address(lendMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, _defaultLendParams()
        );

        (,, uint256 units) = _takeLendMidnightRenewal(lender, borrower, 50e18, sourceMarket, targetMarket, DEFAULT_TICK);
        assertEq(midnight.credit(targetMarketId, lender), units, "lender has credit on target");
        assertGt(midnight.pendingFee(targetMarketId, lender), 0, "pendingFee > 0 confirms continuous fee active");
    }

    /* ═══════════════════════════════════════════════════════════════
       Post-maturity migration semantics (ORCH-5 / ORCH-6 / ORCH-13).
       ═══════════════════════════════════════════════════════════════ */

    /// @dev V2→V2 borrow renewal after source maturity settles at par and reduces source debt by the repay budget.
    function test_borrowMidnightRenewal_postMaturity_succeeds() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);
        _setParams(
            borrower,
            address(borrowMidnightRenewalCallback),
            sourceTenorMarketId,
            targetTenorMarketId,
            _defaultMidnightParams()
        );

        vm.warp(sourceMarket.maturity + 1 hours);

        (uint256 buyerAssets,, uint256 units) =
            _takeBorrowMidnightRenewal(borrower, lender, 100e18, sourceMarket, targetMarket, DEFAULT_TICK);

        assertEq(units, 100e18, "units == takeUnits (post-maturity)");
        uint256 repayBudget = buyerAssets - _independentSellerFee(DEFAULT_TICK, DEFAULT_FEE_RATE, units, buyerAssets);
        assertEq(
            sourceDebtBefore - midnight.debt(sourceMarketId, borrower),
            repayBudget,
            "source debt decreased by repayBudget (post-maturity)"
        );
        assertEq(midnight.debt(targetMarketId, borrower), units, "target debt = units");
    }

    /// @dev V2→V1 lend exit after source maturity settles at par, takes no fee, and mints vault shares to the lender.
    function test_lendMidnightToVault_postMaturity_succeeds() public {
        _setupLenderWithCredit(lender, uint128(DEFAULT_LEND_AMOUNT), sourceMarket, sourceMarketId);
        uint256 lenderCreditBefore = midnight.credit(sourceMarketId, lender);

        bytes32 vaultMarketId = TenorMarketIdLib.vaultToTenorMarketId(address(vault));
        _setParams(
            lender, address(lendMidnightToVaultCallback), sourceTenorMarketId, vaultMarketId, _defaultBorrowParams()
        );

        vm.prank(lender);
        loanToken.approve(address(lendMidnightToVaultCallback), type(uint256).max);
        vm.warp(sourceMarket.maturity + 12 hours);
        loanToken.mint(keeper, type(uint128).max);
        vm.prank(keeper);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);
        (uint256 buyerAssets, uint256 sellerAssets, uint256 units) =
            _takeLendMidnightToVault(lender, keeper, vaultMarketId, 100e18, sourceMarket, TICK_HIGH);

        assertEq(units, 100e18, "units == takeUnits (post-maturity)");
        assertEq(buyerAssets, 100e18 * TickLib.tickToPrice(TICK_HIGH) / WAD, "buyerAssets at par");
        assertEq(sellerAssets, buyerAssets, "sellerAssets is raw");
        assertEq(loanToken.balanceOf(feeRecipient), feeRecipientBefore, "no Midnight->Vault fee taken");
        assertEq(lenderCreditBefore - midnight.credit(sourceMarketId, lender), units, "credit decreased by units");
        assertGt(vault.balanceOf(lender), 0, "vault shares created");
    }

    /// @dev V2→V1 borrow exit after source maturity reverts: Midnight forbids increasing debt post-maturity.
    function test_borrowMidnightToBlue_postMaturity_reverts() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        loanToken.mint(address(this), DEFAULT_BORROW_AMOUNT * 2);
        loanToken.approve(address(morphoBlue), DEFAULT_BORROW_AMOUNT * 2);
        morphoBlue.supply(blueMarketParams, DEFAULT_BORROW_AMOUNT * 2, 0, address(this), "");

        bytes32 blueTargetMarketId = Id.unwrap(MarketParamsLib.id(blueMarketParams));
        _setParams(
            borrower,
            address(borrowMidnightToBlueCallback),
            sourceTenorMarketId,
            blueTargetMarketId,
            _defaultLendParams()
        );

        vm.warp(sourceMarket.maturity + 12 hours);
        _depositCollateral(keeper, DEFAULT_COLLATERAL_AMOUNT * 2, sourceMarket);

        // Build offer + ratifierData before expectRevert so the helper's view calls don't consume the expectation.
        bytes memory cbd = _encodeBorrowMidnightToBlueCallbackData(sourceTenorMarketId, blueTargetMarketId);
        Offer memory offer =
            _migrationOffer(borrower, sourceMarket, true, DEFAULT_TICK, address(borrowMidnightToBlueCallback), cbd);
        bytes memory rd = abi.encode(sourceTenorMarketId, blueTargetMarketId);

        vm.expectRevert(IMidnight.CannotIncreaseDebtPostMaturity.selector);
        vm.prank(keeper);
        midnight.take(offer, rd, 100e18, keeper, keeper, address(0), "");
    }
}
