// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {BorrowMidnightRenewalCallback} from "@callbacks/BorrowMidnightRenewalCallback.sol";
import {IBorrowMidnightRenewalCallback} from "@callbacks/interfaces/IBorrowMidnightRenewalCallback.sol";
import {LendMidnightRenewalCallback} from "@callbacks/LendMidnightRenewalCallback.sol";
import {ILendMidnightRenewalCallback} from "@callbacks/interfaces/ILendMidnightRenewalCallback.sol";
import {IMigrationRatifier} from "../../src/ratifiers/interfaces/IMigrationRatifier.sol";
import {MigrationRatifier} from "../../src/ratifiers/MigrationRatifier.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";
import {StaticRatePolicy} from "../../src/ratifiers/policies/StaticRatePolicy.sol";
import {IMorpho, Market as BlueMarket, MarketParams} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";
import {IIrm} from "@morphoBlue/interfaces/IIrm.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @dev Zero-rate IRM for Morpho Blue market creation.
contract MockIrm6Dec is IIrm {
    function borrowRateView(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 0;
    }

    function borrowRate(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 0;
    }
}

/// @title MigrationRatifierIntegration6DecTest
/// @notice Migration-ratifier integration with 6-decimal loan tokens (USDC), maker-on-behalf model. Mirrors the
///         Midnight↔Midnight borrow + lend renewals at 6-decimal precision to catch rounding/dust bugs that only
///         manifest at low decimals. The migrating user is the offer MAKER; a counterparty takes via `midnight.take`,
///         which invokes `MigrationRatifier.isRatified`.
contract MigrationRatifierIntegration6DecTest is Test {
    using TenorMarketIdLib for Market;
    using MarketParamsLib for MarketParams;

    uint256 internal constant SEED_AMOUNT = 100e6;

    Midnight internal midnight;
    MockERC20 internal loanToken; // 6 decimals (USDC)
    MockERC20 internal collateralToken; // 18 decimals
    Oracle internal oracle;

    BorrowMidnightRenewalCallback internal borrowMidnightRenewalCallback;
    LendMidnightRenewalCallback internal lendMidnightRenewalCallback;

    MigrationRatifier internal defaultRatifier;
    StaticRatePolicy internal permissiveRatePolicy;
    StaticRatePolicy internal permissiveLendPolicy;

    IMorpho internal morphoBlue;
    MockIrm6Dec internal morphoIrm;
    MarketParams internal blueMarketParams;

    address internal lender;
    uint256 internal lenderSK;
    address internal borrower;
    uint256 internal borrowerSK;
    address internal feeRecipient;
    EcrecoverRatifier internal ecrecoverRatifier;

    Market internal sourceMarket;
    Market internal targetMarket;
    bytes32 internal sourceMarketId;
    bytes32 internal targetMarketId;
    bytes32 internal sourceTenorMarketId;
    bytes32 internal targetTenorMarketId;

    uint16 internal constant DEFAULT_TICK = 2800;
    uint256 internal constant DEFAULT_FEE_RATE = 0.01e18;
    uint128 internal constant DEFAULT_BORROW_AMOUNT = 1000e6;
    uint128 internal constant DEFAULT_COLLATERAL_AMOUNT = 5000e18;
    uint128 internal constant DEFAULT_LEND_AMOUNT = 1000e6;

    function setUp() public {
        (lender, lenderSK) = makeAddrAndKey("lender");
        (borrower, borrowerSK) = makeAddrAndKey("borrower");
        feeRecipient = makeAddr("feeRecipient");

        loanToken = new MockERC20("USDC", "USDC", 6);
        collateralToken = new MockERC20("Col", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(10e36);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);
        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        morphoIrm = new MockIrm6Dec();
        morphoBlue = IMorpho(deployCode("test/bin/Morpho.json", abi.encode(address(this))));
        morphoBlue.enableIrm(address(morphoIrm));
        morphoBlue.enableLltv(0.77e18);
        blueMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(morphoIrm),
            lltv: 0.77e18
        });
        morphoBlue.createMarket(blueMarketParams);

        borrowMidnightRenewalCallback = new BorrowMidnightRenewalCallback(address(midnight));
        lendMidnightRenewalCallback = new LendMidnightRenewalCallback(address(midnight));

        // MigrationRatifier needs a concrete address per action branch. Use address(1) for the four Blue/Vault
        // callbacks this suite never exercises — unknown callbacks revert InvalidCallback.
        address dummyCallback = address(1);
        defaultRatifier = new MigrationRatifier(
            address(midnight),
            address(borrowMidnightRenewalCallback),
            dummyCallback,
            dummyCallback,
            dummyCallback,
            dummyCallback,
            address(lendMidnightRenewalCallback),
            address(this)
        );

        {
            uint128[] memory rates = new uint128[](1);
            rates[0] = type(uint128).max;
            uint128[] memory durations = new uint128[](1);
            durations[0] = 0;
            permissiveRatePolicy = new StaticRatePolicy(rates, durations);
        }
        {
            uint128[] memory rates = new uint128[](1);
            rates[0] = 0;
            uint128[] memory durations = new uint128[](1);
            durations[0] = 0;
            permissiveLendPolicy = new StaticRatePolicy(rates, durations);
        }

        defaultRatifier.setFeeConfig(address(borrowMidnightRenewalCallback), bytes32(0), DEFAULT_FEE_RATE, feeRecipient);
        defaultRatifier.setFeeConfig(address(lendMidnightRenewalCallback), bytes32(0), DEFAULT_FEE_RATE, feeRecipient);

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        sourceMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        sourceMarketId = IdLib.toId(sourceMarket);

        targetMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        targetMarketId = IdLib.toId(targetMarket);

        sourceTenorMarketId = sourceMarket.toTenorMarketId();
        targetTenorMarketId = targetMarket.toTenorMarketId();

        _seedMarket(sourceMarket, sourceMarketId);
        _seedMarket(targetMarket, targetMarketId);

        vm.startPrank(borrower);
        loanToken.approve(address(borrowMidnightRenewalCallback), type(uint256).max);
        loanToken.approve(address(midnight), type(uint256).max);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.setIsAuthorized(address(borrowMidnightRenewalCallback), true, borrower);
        midnight.setIsAuthorized(address(lendMidnightRenewalCallback), true, borrower);
        vm.stopPrank();

        loanToken.mint(lender, type(uint128).max);
        vm.startPrank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.setIsAuthorized(address(borrowMidnightRenewalCallback), true, lender);
        midnight.setIsAuthorized(address(lendMidnightRenewalCallback), true, lender);
        vm.stopPrank();
    }

    /* ═══════ Signing / group helpers ═══════ */

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        return Signature({v: v, r: r, s: s});
    }

    function _freshGroup() internal view returns (bytes32) {
        return keccak256(abi.encodePacked("6dec-test", block.timestamp, gasleft()));
    }

    function _migrationGroup() internal view returns (bytes32) {
        bytes32 mask = defaultRatifier.MIGRATION_GROUP_HEADER_MASK();
        return (_freshGroup() & ~mask) | defaultRatifier.MIGRATION_GROUP_HEADER();
    }

    /// @dev The user's migration offer (user = maker). Receiver pinned per side.
    function _migrationOffer(address user, Market memory obl, bool buy, uint16 tick, address callback, bytes memory cbd)
        internal
        view
        returns (Offer memory)
    {
        return Offer({
            market: obl,
            buy: buy,
            maker: user,
            maxUnits: type(uint128).max,
            start: block.timestamp,
            expiry: block.timestamp + 365 days,
            tick: tick,
            group: _migrationGroup(),
            callback: callback,
            callbackData: cbd,
            receiverIfMakerIsSeller: buy ? address(0) : callback,
            ratifier: address(defaultRatifier),
            reduceOnly: false,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    /* ═══════ Position setup helpers ═══════ */

    function _seedMarket(Market memory obl, bytes32 oblId) internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey(string(abi.encodePacked("seed", oblId)));
        address seedLender = makeAddr(string(abi.encodePacked("seedL", oblId)));

        loanToken.mint(seedLender, type(uint128).max);
        collateralToken.mint(seedBorrower, type(uint128).max);

        MidnightSupplyCollateralCallback setupCb = new MidnightSupplyCollateralCallback(address(midnight));

        vm.startPrank(seedBorrower);
        collateralToken.approve(address(setupCb), type(uint256).max);
        midnight.setIsAuthorized(address(setupCb), true, seedBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedBorrower);
        vm.stopPrank();

        vm.prank(seedLender);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = SEED_AMOUNT * 10;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: SEED_AMOUNT, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory seedOffer = Offer({
            market: obl,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: 5820,
            group: keccak256(abi.encodePacked("seed", oblId)),
            callback: address(setupCb),
            callbackData: cbData,
            receiverIfMakerIsSeller: seedBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(seedOffer, seedBorrowerSK);
        bytes32 root = HashLib.hashOffer(seedOffer);
        vm.prank(seedLender);
        midnight.take(
            seedOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            SEED_AMOUNT,
            seedLender,
            address(0),
            address(0),
            ""
        );
    }

    function _setupBorrowerWithDebt(address account, uint256 accountSK, uint128 debtUnits) internal {
        address tempLender = makeAddr(string(abi.encodePacked("tL6", account, sourceMarketId)));

        collateralToken.mint(account, type(uint128).max);
        loanToken.mint(tempLender, type(uint128).max);

        MidnightSupplyCollateralCallback cb = new MidnightSupplyCollateralCallback(address(midnight));
        vm.startPrank(account);
        collateralToken.approve(address(cb), type(uint256).max);
        midnight.setIsAuthorized(address(cb), true, account);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, account);
        vm.stopPrank();

        vm.prank(tempLender);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = uint256(debtUnits) * 20;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: debtUnits, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory sellOffer = Offer({
            market: sourceMarket,
            buy: false,
            maker: account,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: 5820,
            group: keccak256(abi.encodePacked("debt6", account, sourceMarketId)),
            callback: address(cb),
            callbackData: cbData,
            receiverIfMakerIsSeller: account,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, accountSK);
        bytes32 root = HashLib.hashOffer(sellOffer);
        vm.prank(tempLender);
        midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            debtUnits,
            tempLender,
            address(0),
            address(0),
            ""
        );
    }

    function _setupLenderWithCredit(address account, uint128 creditAmount) internal {
        (address tempBorrower, uint256 tempBorrowerSK) =
            makeAddrAndKey(string(abi.encodePacked("tB6", account, sourceMarketId)));

        collateralToken.mint(tempBorrower, type(uint128).max);
        vm.startPrank(tempBorrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(sourceMarket, 0, uint256(creditAmount) * 100, tempBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, tempBorrower);
        vm.stopPrank();

        loanToken.mint(account, type(uint128).max);
        vm.prank(account);
        loanToken.approve(address(midnight), type(uint256).max);

        Offer memory sellOffer = Offer({
            market: sourceMarket,
            buy: false,
            maker: tempBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: 5820,
            group: keccak256(abi.encodePacked("lend6", account, sourceMarketId)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: tempBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, tempBorrowerSK);
        bytes32 root = HashLib.hashOffer(sellOffer);
        vm.prank(account);
        midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            creditAmount,
            account,
            address(0),
            address(0),
            ""
        );
    }

    function _depositCollateral(address account, uint256 amount) internal {
        collateralToken.mint(account, amount);
        vm.startPrank(account);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(targetMarket, 0, amount, account);
        vm.stopPrank();
    }

    function _warpToRenewalWindow() internal {
        vm.warp(sourceMarket.maturity - 1 days);
    }

    /* ═══════ Params helpers ═══════ */

    function _defaultBorrowParams() internal view returns (IMigrationRatifier.UserMigrationParams memory) {
        return IMigrationRatifier.UserMigrationParams({
            interestRatePolicy: address(permissiveRatePolicy),
            renewalWindow: uint32(7 days),
            minDuration: uint32(7 days),
            maxDuration: uint32(365 days),
            renewalCadence: address(0),
            limitRatePerSecond: type(uint40).max
        });
    }

    function _defaultLendParams() internal view returns (IMigrationRatifier.UserMigrationParams memory) {
        return IMigrationRatifier.UserMigrationParams({
            interestRatePolicy: address(permissiveLendPolicy),
            renewalWindow: uint32(7 days),
            minDuration: uint32(7 days),
            maxDuration: uint32(365 days),
            renewalCadence: address(0),
            limitRatePerSecond: 0
        });
    }

    function _setParams(
        address onBehalf,
        address callback,
        bytes32 src,
        bytes32 tgt,
        IMigrationRatifier.UserMigrationParams memory params
    ) internal {
        vm.startPrank(onBehalf);
        defaultRatifier.setParams(onBehalf, callback, src, tgt, params);
        midnight.setIsAuthorized(address(defaultRatifier), true, onBehalf);
        vm.stopPrank();
    }

    /* ═══════ CallbackData builders ═══════ */

    function _encodeBorrowMidnightRenewalCallbackData(uint16 tick) internal view returns (bytes memory) {
        IMigrationRatifier.FeeConfig memory fee =
            defaultRatifier.getEffectiveFeeConfig(address(borrowMidnightRenewalCallback), sourceTenorMarketId);
        return abi.encode(
            IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: fee.feeRate, feeRecipient: fee.feeRecipient, tick: tick
            })
        );
    }

    function _encodeLendMidnightRenewalCallbackData(uint16 tick) internal view returns (bytes memory) {
        IMigrationRatifier.FeeConfig memory fee =
            defaultRatifier.getEffectiveFeeConfig(address(lendMidnightRenewalCallback), sourceTenorMarketId);
        return abi.encode(
            ILendMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: fee.feeRate, feeRecipient: fee.feeRecipient, tick: tick
            })
        );
    }

    /* ═══════ Independent fee math ═══════ */

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

    function _independentBuyerFee(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal
        pure
        returns (uint256)
    {
        if (feeRate == 0) return 0;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 x = (WAD - price) * feeRate / WAD;
        uint256 effPrice = price * WAD / (WAD - x);
        uint256 budget = units * effPrice / WAD;
        return budget > assets ? budget - assets : 0;
    }

    /* ═══════════════════════════════════════════════════════════════
       Midnight→Midnight borrow renewal — user maker-seller, lender buys
       ═══════════════════════════════════════════════════════════════ */

    function test_borrowMidnightRenewal_6dec_1000USDC() public {
        _runBorrowMidnightRenewalTest(1000e6);
    }

    function test_borrowMidnightRenewal_6dec_100USDC() public {
        _runBorrowMidnightRenewalTest(100e6);
    }

    function test_borrowMidnightRenewal_6dec_1USDC_dust() public {
        _runBorrowMidnightRenewalTest(1e6);
    }

    function test_borrowMidnightRenewal_6dec_500USDC() public {
        _runBorrowMidnightRenewalTest(500e6);
    }

    function _runBorrowMidnightRenewalTest(uint128 takeUnits) internal {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT);

        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);
        assertEq(sourceDebtBefore, DEFAULT_BORROW_AMOUNT, "precondition: source debt");

        _setParams(
            borrower,
            address(borrowMidnightRenewalCallback),
            sourceTenorMarketId,
            targetTenorMarketId,
            _defaultBorrowParams()
        );
        _warpToRenewalWindow();

        uint16 tick = DEFAULT_TICK;
        bytes memory cbd = _encodeBorrowMidnightRenewalCallbackData(tick);
        Offer memory offer =
            _migrationOffer(borrower, targetMarket, false, tick, address(borrowMidnightRenewalCallback), cbd);

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        // Counterparty (lender) buys the user's sell offer.
        vm.prank(lender);
        (uint256 buyerAssets, uint256 sellerAssets) = midnight.take(
            offer, abi.encode(sourceTenorMarketId, targetTenorMarketId), takeUnits, lender, address(0), address(0), ""
        );
        assertGt(buyerAssets, 0, "buyerAssets > 0");

        uint256 rawSellerAssets = buyerAssets;
        uint256 expectedFee = _independentSellerFee(tick, DEFAULT_FEE_RATE, takeUnits, rawSellerAssets);
        assertEq(sellerAssets, rawSellerAssets, "sellerAssets is raw Midnight value (6-dec)");

        assertEq(
            loanToken.balanceOf(feeRecipient) - feeRecipientBefore,
            expectedFee,
            "Fee recipient received exact fee (6-dec)"
        );

        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, borrower);
        assertEq(
            sourceDebtBefore - sourceDebtAfter,
            rawSellerAssets - expectedFee,
            "Source debt decreased by repayBudget (6-dec)"
        );
        assertEq(midnight.debt(targetMarketId, borrower), takeUnits, "Target debt = takeUnits (6-dec)");

        assertEq(loanToken.balanceOf(address(borrowMidnightRenewalCallback)), 0, "CB-DUST-1 (6-dec)");
        assertEq(collateralToken.balanceOf(address(borrowMidnightRenewalCallback)), 0, "CB-DUST-2 (6-dec)");
    }

    /* ═══════════════════════════════════════════════════════════════
       Midnight→Midnight lend-withdrawable renewal — user maker-buyer, borrower sells
       ═══════════════════════════════════════════════════════════════ */

    function test_lendMidnightRenewal_6dec_1000USDC() public {
        _runLendMidnightRenewalTest(50e6);
    }

    function test_lendMidnightRenewal_6dec_5000USDC() public {
        _runLendMidnightRenewalTest(100e6);
    }

    function test_lendMidnightRenewal_6dec_1USDC_dust() public {
        _runLendMidnightRenewalTest(1e6);
    }

    function test_lendMidnightRenewal_6dec_100USDC() public {
        _runLendMidnightRenewalTest(10e6);
    }

    function _runLendMidnightRenewalTest(uint128 takeUnits) internal {
        _setupLenderWithCredit(lender, DEFAULT_LEND_AMOUNT);

        assertEq(midnight.credit(sourceMarketId, lender), DEFAULT_LEND_AMOUNT, "precondition: lender has credit");

        // Create withdrawable: temp borrower borrows and repays.
        (address tempBorrower2, uint256 tempBorrower2SK) = makeAddrAndKey("tempBorrower2_6dec");
        {
            collateralToken.mint(tempBorrower2, type(uint128).max);
            MidnightSupplyCollateralCallback cb = new MidnightSupplyCollateralCallback(address(midnight));
            vm.startPrank(tempBorrower2);
            collateralToken.approve(address(cb), type(uint256).max);
            midnight.setIsAuthorized(address(cb), true, tempBorrower2);
            midnight.setIsAuthorized(address(ecrecoverRatifier), true, tempBorrower2);
            vm.stopPrank();

            address tl = makeAddr("tempLender6dec");
            loanToken.mint(tl, type(uint128).max);
            vm.prank(tl);
            loanToken.approve(address(midnight), type(uint256).max);

            uint256[] memory colAmounts = new uint256[](1);
            colAmounts[0] = uint256(DEFAULT_BORROW_AMOUNT) * 20;
            bytes memory cbData = abi.encode(
                IMidnightSupplyCollateralCallback.CallbackData({
                    amounts: colAmounts, offerSellerAssets: DEFAULT_BORROW_AMOUNT, maxBorrowCapacityUsage: 0
                })
            );

            Offer memory sellOffer = Offer({
                market: sourceMarket,
                buy: false,
                maker: tempBorrower2,
                start: block.timestamp,
                expiry: block.timestamp + 1 hours,
                tick: 5820,
                group: keccak256("debt6-temp"),
                callback: address(cb),
                callbackData: cbData,
                receiverIfMakerIsSeller: tempBorrower2,
                ratifier: address(ecrecoverRatifier),
                reduceOnly: false,
                maxUnits: type(uint128).max,
                maxAssets: 0,
                continuousFeeCap: type(uint256).max
            });

            Signature memory sig = _signOffer(sellOffer, tempBorrower2SK);
            bytes32 root = HashLib.hashOffer(sellOffer);
            vm.prank(tl);
            midnight.take(
                sellOffer,
                abi.encode(sig, root, uint256(0), new bytes32[](0)),
                DEFAULT_BORROW_AMOUNT,
                tl,
                address(0),
                address(0),
                ""
            );
        }

        loanToken.mint(tempBorrower2, DEFAULT_BORROW_AMOUNT);
        vm.prank(tempBorrower2);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.prank(tempBorrower2);
        midnight.repay(sourceMarket, DEFAULT_BORROW_AMOUNT, tempBorrower2, address(0), "");

        uint256 withdrawableBefore = midnight.withdrawable(sourceMarketId);
        assertGt(withdrawableBefore, 0, "precondition: withdrawable > 0");

        _setParams(
            lender, address(lendMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, _defaultLendParams()
        );
        _warpToRenewalWindow();
        _depositCollateral(borrower, DEFAULT_COLLATERAL_AMOUNT);

        uint16 tick = DEFAULT_TICK;
        bytes memory cbd = _encodeLendMidnightRenewalCallbackData(tick);
        Offer memory offer =
            _migrationOffer(lender, targetMarket, true, tick, address(lendMidnightRenewalCallback), cbd);

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        // Counterparty (borrower) sells into the user's buy offer.
        vm.prank(borrower);
        (uint256 buyerAssets, uint256 sellerAssets) = midnight.take(
            offer, abi.encode(sourceTenorMarketId, targetTenorMarketId), takeUnits, borrower, borrower, address(0), ""
        );
        assertGt(buyerAssets, 0, "buyerAssets > 0 (6-dec lend)");
        assertGt(sellerAssets, 0, "sellerAssets > 0 (6-dec lend)");

        uint256 rawBuyerAssets = (uint256(takeUnits) * TickLib.tickToPrice(tick) + WAD - 1) / WAD;
        uint256 expectedFee = _independentBuyerFee(tick, DEFAULT_FEE_RATE, takeUnits, rawBuyerAssets);
        assertEq(buyerAssets, rawBuyerAssets, "buyerAssets is raw Midnight value (6-dec lend)");
        assertEq(
            loanToken.balanceOf(feeRecipient) - feeRecipientBefore,
            expectedFee,
            "Fee recipient received exact fee (6-dec lend)"
        );

        assertEq(
            withdrawableBefore - midnight.withdrawable(sourceMarketId),
            rawBuyerAssets + expectedFee,
            "Withdrawable decreased by rawBuyerAssets + fee (6-dec)"
        );
        assertEq(midnight.credit(targetMarketId, lender), takeUnits, "Lender has credit on target (6-dec)");
        assertEq(loanToken.balanceOf(address(lendMidnightRenewalCallback)), 0, "CB-DUST-1 (6-dec lend)");
    }
}
