// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LendVaultToMidnightCallback} from "../../src/callbacks/LendVaultToMidnightCallback.sol";
import {ILendVaultToMidnightCallback} from "@callbacks/interfaces/ILendVaultToMidnightCallback.sol";
import {LendMidnightRenewalCallback} from "../../src/callbacks/LendMidnightRenewalCallback.sol";
import {ILendMidnightRenewalCallback} from "@callbacks/interfaces/ILendMidnightRenewalCallback.sol";
import {MidnightWithdrawVaultSharesCallback} from "../../src/callbacks/MidnightWithdrawVaultSharesCallback.sol";
import {IMidnightWithdrawVaultSharesCallback} from "@callbacks/interfaces/IMidnightWithdrawVaultSharesCallback.sol";
import {BorrowMidnightToBlueCallback} from "../../src/callbacks/BorrowMidnightToBlueCallback.sol";
import {IBorrowMidnightToBlueCallback} from "@callbacks/interfaces/IBorrowMidnightToBlueCallback.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {Market, CollateralParams, Offer, IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {MockERC4626} from "../helpers/mocks/MockERC4626.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {creditAfterSlashing} from "../helpers/CreditHelper.sol";
import {Fixtures} from "../helpers/Fixtures.sol";
import {
    IMorpho,
    MarketParams,
    Position,
    Id,
    Market as BlueMarket
} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {IIrm} from "../../lib/morpho-blue/src/interfaces/IIrm.sol";

/* ═══════════════════════════════════════════════════════════════════════
   Independent Fee Math Helpers
   ═══════════════════════════════════════════════════════════════════════
   These replicate the CallbackLib fee formulas using raw mulDivDown/mulDivUp
   to avoid circular assertions. Do NOT import or call CallbackLib here. */

library IndependentFeeLib {
    using UtilsLib for uint256;

    /// @dev Computes buyer fee independently from CallbackLib.
    ///      buyerEffPrice = price * WAD / (WAD - x)  (rounded down)
    ///      buyerFee = mulDivDown(units, buyerEffPrice, WAD) - buyerAssets  (zero floor)
    ///      where x = (WAD - price) * feeRate / WAD  (rounded down)
    function computeBuyerFee(uint256 tick, uint256 feeRate, uint256 units, uint256 buyerAssets)
        internal
        pure
        returns (uint256)
    {
        if (feeRate == 0) return 0;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 x = (WAD - price).mulDivDown(feeRate, WAD);
        uint256 effPrice = price.mulDivDown(WAD, WAD - x);
        return units.mulDivDown(effPrice, WAD).zeroFloorSub(buyerAssets);
    }

    /// @dev Computes seller fee independently from CallbackLib.
    ///      sellerEffPrice = price * WAD / (WAD + x)  (rounded up)
    ///      sellerFee = sellerAssets - mulDivUp(units, sellerEffPrice, WAD)  (zero floor)
    ///      where x = (WAD - price) * feeRate / WAD  (rounded down)
    function computeSellerFee(uint256 tick, uint256 feeRate, uint256 units, uint256 sellerAssets)
        internal
        pure
        returns (uint256)
    {
        if (feeRate == 0) return 0;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 x = (WAD - price).mulDivDown(feeRate, WAD);
        uint256 effPrice = price.mulDivUp(WAD, WAD + x);
        return sellerAssets.zeroFloorSub(units.mulDivUp(effPrice, WAD));
    }

    /// @dev Computes percentage fee independently: assets * feeRate / WAD (rounded down)
    function computePercentageFee(uint256 assets, uint256 feeRate) internal pure returns (uint256) {
        return assets.mulDivDown(feeRate, WAD);
    }
}

/* ═══════════════════════════════════════════════════════════════════════
   A1: LendVaultToMidnightCallback with 6-decimal and 8-decimal tokens
   ═══════════════════════════════════════════════════════════════════════ */

contract MultiDecimal_LendVaultToMidnightCallback_6Dec is Test {
    using IndependentFeeLib for uint256;

    LendVaultToMidnightCallback internal callback;
    Midnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockERC4626 internal vault;
    Oracle internal oracle;

    address internal lender;
    uint256 internal lenderSK;
    address internal borrower;
    address internal feeRecipient;

    Market internal market;

    function setUp() public {
        (lender, lenderSK) = makeAddrAndKey("Lender");
        borrower = makeAddr("Borrower");
        feeRecipient = makeAddr("FeeRecipient");

        // 6-decimal tokens (USDC-like)
        loanToken = new MockERC20("USDC", "USDC", 6);
        collateralToken = new MockERC20("Collateral", "COL", 18);

        oracle = new Oracle();
        oracle.setPrice(1e36);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);

        vault = new MockERC4626(address(loanToken), "Vault USDC", "vUSDC");

        callback = new LendVaultToMidnightCallback(address(midnight));

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.77e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
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

        // Fund lender and deposit into vault
        loanToken.mint(lender, 100_000e6);
        vm.startPrank(lender);
        loanToken.approve(address(vault), type(uint256).max);
        loanToken.approve(address(midnight), type(uint256).max);
        vault.deposit(50_000e6, lender);
        vault.approve(address(callback), type(uint256).max);
        vm.stopPrank();

        // Fund borrower with collateral + loan tokens
        collateralToken.mint(borrower, 100_000e18);
        loanToken.mint(borrower, 100_000e6);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, 50_000e18, borrower);
        vm.stopPrank();
    }

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(sk, digest);
        return signature;
    }

    function _takeBuyOffer(uint256 buyerAssets, uint256 feeRate, address _feeRecipient)
        internal
        returns (uint256 retBuyerAssets, uint256 retSellerAssets, uint256 retUnits)
    {
        uint256 tick = TickLib.priceToTick(0.95e18, DEFAULT_TICK_SPACING);
        ILendVaultToMidnightCallback.CallbackData memory cbData = ILendVaultToMidnightCallback.CallbackData({
            vault: address(vault),
            feeRate: feeRate,
            feeRecipient: _feeRecipient,
            tick: tick,
            morphoBlueMarketId: bytes32(0)
        });

        Offer memory offer = Offer({
            buy: true,
            maker: lender,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256(abi.encodePacked(block.timestamp, feeRate, gasleft())),
            callback: address(callback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(offer, lenderSK);
        bytes32 offerRoot = HashLib.hashOffer(offer);
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, buyerAssets);

        vm.prank(borrower);
        (retBuyerAssets, retSellerAssets) = midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            borrower,
            offer.maker,
            address(0),
            ""
        );
        retUnits = _shares;
    }

    function test_6dec_happyPath_withFee_1000USDC() public {
        uint256 buyerAmount = 1000e6; // 1000 USDC
        uint256 feeRate = 0.5e18; // 50% of interest

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        (uint256 retBuyerAssets,, uint256 retUnits) = _takeBuyOffer(buyerAmount, feeRate, feeRecipient);

        uint256 tick = TickLib.priceToTick(0.95e18, DEFAULT_TICK_SPACING);
        uint256 expectedFee = IndependentFeeLib.computeBuyerFee(tick, feeRate, retUnits, retBuyerAssets);

        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "6dec: fee should match independent calculation");
        assertGt(feeReceived, 0, "6dec: fee should be > 0");

        // No dust
        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec: CB-DUST-1");
    }

    function test_6dec_happyPath_100USDC() public {
        uint256 buyerAmount = 100e6;
        uint256 feeRate = 0.5e18;

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        (uint256 retBuyerAssets,, uint256 retUnits) = _takeBuyOffer(buyerAmount, feeRate, feeRecipient);

        uint256 tick = TickLib.priceToTick(0.95e18, DEFAULT_TICK_SPACING);
        uint256 expectedFee = IndependentFeeLib.computeBuyerFee(tick, feeRate, retUnits, retBuyerAssets);

        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "6dec-100: fee should match independent calculation");

        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec-100: CB-DUST-1");
    }

    function test_6dec_happyPath_1USDC() public {
        uint256 buyerAmount = 1e6; // 1 USDC
        uint256 feeRate = 0.5e18;

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        (uint256 retBuyerAssets,, uint256 retUnits) = _takeBuyOffer(buyerAmount, feeRate, feeRecipient);

        uint256 tick = TickLib.priceToTick(0.95e18, DEFAULT_TICK_SPACING);
        uint256 expectedFee = IndependentFeeLib.computeBuyerFee(tick, feeRate, retUnits, retBuyerAssets);

        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "6dec-1: fee should match independent calculation");

        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec-1: CB-DUST-1");
    }

    /// @dev Dust amount test: 1 wei USDC = 1 (0.000001 USDC). Rounding could eat the entire fee.
    function test_6dec_dustAmount_1wei() public {
        uint256 buyerAmount = 1; // 1 wei USDC (0.000001 USDC)
        uint256 feeRate = 0.5e18;

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        (uint256 retBuyerAssets,, uint256 retUnits) = _takeBuyOffer(buyerAmount, feeRate, feeRecipient);

        uint256 tick = TickLib.priceToTick(0.95e18, DEFAULT_TICK_SPACING);
        uint256 expectedFee = IndependentFeeLib.computeBuyerFee(tick, feeRate, retUnits, retBuyerAssets);

        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "6dec-dust: fee should match independent calculation");

        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec-dust: CB-DUST-1");
    }

    function test_6dec_zeroFee() public {
        uint256 buyerAmount = 1000e6;

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        _takeBuyOffer(buyerAmount, 0, address(0));

        assertEq(loanToken.balanceOf(feeRecipient), feeRecipientBefore, "6dec: no fee with rate=0");
        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec: CB-DUST-1 zero fee");
    }
}

contract MultiDecimal_LendVaultToMidnightCallback_8Dec is Test {
    using IndependentFeeLib for uint256;

    LendVaultToMidnightCallback internal callback;
    Midnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockERC4626 internal vault;
    Oracle internal oracle;

    address internal lender;
    uint256 internal lenderSK;
    address internal borrower;
    address internal feeRecipient;

    Market internal market;

    function setUp() public {
        (lender, lenderSK) = makeAddrAndKey("Lender");
        borrower = makeAddr("Borrower");
        feeRecipient = makeAddr("FeeRecipient");

        // 8-decimal tokens (WBTC-like)
        loanToken = new MockERC20("WBTC", "WBTC", 8);
        collateralToken = new MockERC20("Collateral", "COL", 18);

        oracle = new Oracle();
        oracle.setPrice(1e36);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);

        vault = new MockERC4626(address(loanToken), "Vault WBTC", "vWBTC");

        callback = new LendVaultToMidnightCallback(address(midnight));

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.77e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
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

        loanToken.mint(lender, 100e8);
        vm.startPrank(lender);
        loanToken.approve(address(vault), type(uint256).max);
        loanToken.approve(address(midnight), type(uint256).max);
        vault.deposit(50e8, lender);
        vault.approve(address(callback), type(uint256).max);
        vm.stopPrank();

        collateralToken.mint(borrower, 100_000e18);
        loanToken.mint(borrower, 100e8);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, 50_000e18, borrower);
        vm.stopPrank();
    }

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(sk, digest);
        return signature;
    }

    function _takeBuyOffer(uint256 buyerAssets, uint256 feeRate, address _feeRecipient)
        internal
        returns (uint256 retBuyerAssets, uint256 retSellerAssets, uint256 retUnits)
    {
        uint256 tick = TickLib.priceToTick(0.95e18, DEFAULT_TICK_SPACING);
        ILendVaultToMidnightCallback.CallbackData memory cbData = ILendVaultToMidnightCallback.CallbackData({
            vault: address(vault),
            feeRate: feeRate,
            feeRecipient: _feeRecipient,
            tick: tick,
            morphoBlueMarketId: bytes32(0)
        });

        Offer memory offer = Offer({
            buy: true,
            maker: lender,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256(abi.encodePacked(block.timestamp, feeRate, gasleft())),
            callback: address(callback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(offer, lenderSK);
        bytes32 offerRoot = HashLib.hashOffer(offer);
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, buyerAssets);

        vm.prank(borrower);
        (retBuyerAssets, retSellerAssets) = midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            borrower,
            offer.maker,
            address(0),
            ""
        );
        retUnits = _shares;
    }

    function test_8dec_happyPath_1WBTC() public {
        uint256 buyerAmount = 1e8; // 1 WBTC
        uint256 feeRate = 0.5e18;

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        (uint256 retBuyerAssets,, uint256 retUnits) = _takeBuyOffer(buyerAmount, feeRate, feeRecipient);

        uint256 tick = TickLib.priceToTick(0.95e18, DEFAULT_TICK_SPACING);
        uint256 expectedFee = IndependentFeeLib.computeBuyerFee(tick, feeRate, retUnits, retBuyerAssets);

        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "8dec: fee should match independent calculation");
        assertGt(feeReceived, 0, "8dec: fee should be > 0");

        assertEq(loanToken.balanceOf(address(callback)), 0, "8dec: CB-DUST-1");
    }

    function test_8dec_halfWBTC() public {
        uint256 buyerAmount = 5e7; // 0.5 WBTC
        uint256 feeRate = 0.5e18;

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        (uint256 retBuyerAssets,, uint256 retUnits) = _takeBuyOffer(buyerAmount, feeRate, feeRecipient);

        uint256 tick = TickLib.priceToTick(0.95e18, DEFAULT_TICK_SPACING);
        uint256 expectedFee = IndependentFeeLib.computeBuyerFee(tick, feeRate, retUnits, retBuyerAssets);

        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "8dec-half: fee should match independent calculation");

        assertEq(loanToken.balanceOf(address(callback)), 0, "8dec-half: CB-DUST-1");
    }

    /// @dev Dust amount: 1 wei WBTC (0.00000001 BTC)
    function test_8dec_dustAmount_1wei() public {
        uint256 buyerAmount = 1;
        uint256 feeRate = 0.5e18;

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        (uint256 retBuyerAssets,, uint256 retUnits) = _takeBuyOffer(buyerAmount, feeRate, feeRecipient);

        uint256 tick = TickLib.priceToTick(0.95e18, DEFAULT_TICK_SPACING);
        uint256 expectedFee = IndependentFeeLib.computeBuyerFee(tick, feeRate, retUnits, retBuyerAssets);

        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "8dec-dust: fee should match independent calculation");

        assertEq(loanToken.balanceOf(address(callback)), 0, "8dec-dust: CB-DUST-1");
    }
}

/* ═══════════════════════════════════════════════════════════════════════
   A2: LendMidnightRenewalCallback with 6-decimal tokens
   ═══════════════════════════════════════════════════════════════════════ */

contract MultiDecimal_LendMidnightRenewal_6Dec is Test {
    using IndependentFeeLib for uint256;

    LendMidnightRenewalCallback internal callback;
    Midnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    address internal lender;
    uint256 internal lenderSK;
    address internal borrower;
    address internal feeRecipient;

    Market internal sourceMarket;
    Market internal targetMarket;

    uint256 internal offerTick;

    function setUp() public {
        (lender, lenderSK) = makeAddrAndKey("Lender");
        borrower = makeAddr("Borrower");
        feeRecipient = makeAddr("FeeRecipient");

        // 6-decimal loan token
        loanToken = new MockERC20("USDC", "USDC", 6);
        collateralToken = new MockERC20("Collateral", "COL", 18);

        oracle = new Oracle();
        oracle.setPrice(10e36);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);

        callback = new LendMidnightRenewalCallback(address(midnight));

        offerTick = TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING);

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
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        targetMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        _setupLenderWithCredit(200e6);

        vm.prank(lender);
        midnight.setIsAuthorized(address(callback), true, lender);

        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        collateralToken.mint(borrower, 10000e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(targetMarket, 0, 10000e18, borrower);
        vm.stopPrank();
    }

    function _setupLenderWithCredit(uint256 creditAmount) internal {
        loanToken.mint(lender, creditAmount);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        address tempBorrower = makeAddr("TempBorrower");
        collateralToken.mint(tempBorrower, 10000e18);
        vm.startPrank(tempBorrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(sourceMarket, 0, 10000e18, tempBorrower);
        vm.stopPrank();

        Offer memory buyOffer = Offer({
            market: sourceMarket,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256("setup-lender-credit-6dec"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(buyOffer, lenderSK);
        bytes32 offerRoot = HashLib.hashOffer(buyOffer);

        vm.prank(tempBorrower);
        midnight.take(
            buyOffer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            creditAmount,
            tempBorrower,
            tempBorrower,
            address(0),
            ""
        );

        // Temp borrower repays to create withdrawable
        bytes32 sourceId = IdLib.toId(sourceMarket);
        uint256 tempDebt = midnight.debt(sourceId, tempBorrower);
        loanToken.mint(tempBorrower, tempDebt);
        vm.startPrank(tempBorrower);
        loanToken.approve(address(midnight), tempDebt);
        midnight.repay(sourceMarket, tempDebt, tempBorrower, address(0), "");
        vm.stopPrank();
    }

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(sk, digest);
        return signature;
    }

    struct TakeResult {
        uint256 buyerAssets;
        uint256 sellerAssets;
        uint256 units;
    }

    function _takeBuyOffer(uint256 buyerAssets, uint256 feeRate, address _feeRecipient)
        internal
        returns (TakeResult memory result)
    {
        bytes memory callbackData = abi.encode(
            ILendMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: feeRate, feeRecipient: _feeRecipient, tick: offerTick
            })
        );

        Offer memory offer = Offer({
            market: targetMarket,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: offerTick,
            group: keccak256(abi.encodePacked("buy_6dec", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(offer, lenderSK);
        bytes32 offerRoot = HashLib.hashOffer(offer);
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _units = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, buyerAssets);

        vm.prank(borrower);
        (result.buyerAssets, result.sellerAssets) = midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, borrower, borrower, address(0), ""
        );
        result.units = _units;
    }

    function test_6dec_withFee_50USDC() public {
        uint256 feeRate = 0.5e18;
        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        TakeResult memory result = _takeBuyOffer(50e6, feeRate, feeRecipient);

        uint256 expectedFee = IndependentFeeLib.computeBuyerFee(offerTick, feeRate, result.units, result.buyerAssets);

        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "6dec-LW: fee should match independent calculation");
        assertGt(feeReceived, 0, "6dec-LW: fee > 0");

        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec-LW: CB-DUST-1");
    }

    function test_6dec_withFee_1USDC() public {
        uint256 feeRate = 0.5e18;
        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        TakeResult memory result = _takeBuyOffer(1e6, feeRate, feeRecipient);

        uint256 expectedFee = IndependentFeeLib.computeBuyerFee(offerTick, feeRate, result.units, result.buyerAssets);

        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "6dec-LW-1: fee should match independent calculation");

        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec-LW-1: CB-DUST-1");
    }

    /// @dev Dust amount: 1 wei USDC
    function test_6dec_dustAmount() public {
        uint256 feeRate = 0.5e18;
        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        TakeResult memory result = _takeBuyOffer(1, feeRate, feeRecipient);

        uint256 expectedFee = IndependentFeeLib.computeBuyerFee(offerTick, feeRate, result.units, result.buyerAssets);

        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "6dec-LW-dust: fee should match independent calculation");

        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec-LW-dust: CB-DUST-1");
    }

    function test_6dec_zeroFee() public {
        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        _takeBuyOffer(50e6, 0, address(0));

        assertEq(loanToken.balanceOf(feeRecipient), feeRecipientBefore, "6dec-LW: no fee with rate=0");
        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec-LW: CB-DUST-1 zero fee");
    }
}

/* ═══════════════════════════════════════════════════════════════════════
   A3: MidnightWithdrawVaultSharesCallback with 6-decimal tokens
   ═══════════════════════════════════════════════════════════════════════ */

contract MultiDecimal_MidnightWithdrawVaultShares_6Dec is Test {
    MidnightWithdrawVaultSharesCallback internal callback;
    Midnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    MockERC20 internal loanToken;
    MockERC4626 internal vault;
    Oracle internal oracle;

    address internal buyer;
    uint256 internal buyerSK;
    address internal seller;

    Market internal testMarket;

    function setUp() public {
        (buyer, buyerSK) = makeAddrAndKey("Buyer");
        seller = makeAddr("Seller");

        // 6-decimal token
        loanToken = new MockERC20("USDC", "USDC", 6);

        vault = new MockERC4626(address(loanToken), "Vault Shares", "vUSDC");

        oracle = new Oracle();
        oracle.setPrice(1e36);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(buyer);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, buyer);

        callback = new MidnightWithdrawVaultSharesCallback(address(midnight));

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(vault), lltv: 0.77e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        testMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        loanToken.mint(seller, 100_000e6);
        vm.prank(seller);
        loanToken.approve(address(midnight), type(uint256).max);

        vm.prank(buyer);
        midnight.setIsAuthorized(address(callback), true, buyer);
    }

    function _signOffer(Offer memory offer, uint256 privateKey) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(privateKey, digest);
        return signature;
    }

    function _setupBuyerPosition(uint256 vaultShareAmount) internal {
        loanToken.mint(buyer, vaultShareAmount);
        vm.startPrank(buyer);
        loanToken.approve(address(vault), vaultShareAmount);
        uint256 shares = vault.deposit(vaultShareAmount, buyer);
        vault.approve(address(midnight), shares);
        midnight.supplyCollateral(testMarket, 0, shares, buyer);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        uint256 borrowAmount = vaultShareAmount / 2;

        Offer memory sellOffer = Offer({
            market: testMarket,
            buy: false,
            maker: buyer,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup_6dec_borrow", block.timestamp)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: buyer,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(sellOffer);
        Signature memory sig = _signOffer(sellOffer, buyerSK);

        bytes32 _id = IdLib.toId(sellOffer.market);
        uint256 _shares = TakeAmountsLib.sellerAssetsToUnits(address(midnight), _id, sellOffer, borrowAmount);
        vm.prank(seller);
        midnight.take(
            sellOffer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            seller,
            address(0),
            address(0),
            ""
        );
    }

    function _takeBuyOffer(uint256 buyerAssets, bytes memory callbackData) internal {
        Offer memory offer = Offer({
            market: testMarket,
            buy: true,
            maker: buyer,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked(block.timestamp, buyerAssets, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, buyerSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _takeShares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, buyerAssets);
        vm.prank(seller);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _takeShares, seller, seller, address(0), ""
        );
    }

    function test_6dec_withdrawVaultShares_200USDC() public {
        _setupBuyerPosition(200e6);

        bytes32 marketId = IdLib.toId(testMarket);
        uint256 collateralBefore = midnight.collateral(marketId, buyer, 0);

        // Take partial (25 USDC), leaves remaining debt
        bytes memory callbackData =
            abi.encode(IMidnightWithdrawVaultSharesCallback.CallbackData({vault: address(vault), collateralIndex: 0}));
        _takeBuyOffer(25e6, callbackData);

        uint256 collateralAfter = midnight.collateral(marketId, buyer, 0);
        uint256 expectedSharesWithdrawn = vault.previewWithdraw(25e6);
        assertEq(collateralAfter, collateralBefore - expectedSharesWithdrawn, "6dec-VS: collateral reduced correctly");

        assertEq(vault.balanceOf(address(callback)), 0, "6dec-VS: no vault dust");
        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec-VS: no loan dust");
    }

    function test_6dec_withdrawVaultShares_1USDC() public {
        _setupBuyerPosition(200e6);

        bytes32 marketId = IdLib.toId(testMarket);
        uint256 collateralBefore = midnight.collateral(marketId, buyer, 0);

        bytes memory callbackData =
            abi.encode(IMidnightWithdrawVaultSharesCallback.CallbackData({vault: address(vault), collateralIndex: 0}));
        _takeBuyOffer(1e6, callbackData);

        uint256 collateralAfter = midnight.collateral(marketId, buyer, 0);
        uint256 expectedSharesWithdrawn = vault.previewWithdraw(1e6);
        assertEq(collateralAfter, collateralBefore - expectedSharesWithdrawn, "6dec-VS-1: collateral reduced correctly");

        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec-VS-1: no loan dust");
    }

    /// @dev Dust: 1 wei USDC
    function test_6dec_withdrawVaultShares_dust() public {
        _setupBuyerPosition(200e6);

        bytes memory callbackData =
            abi.encode(IMidnightWithdrawVaultSharesCallback.CallbackData({vault: address(vault), collateralIndex: 0}));
        _takeBuyOffer(1, callbackData);

        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec-VS-dust: no loan dust");
    }
}

/* ═══════════════════════════════════════════════════════════════════════
   A4: BorrowMidnightToBlueCallback with 6-decimal tokens
   ═══════════════════════════════════════════════════════════════════════ */

contract MultiDecimal_BorrowMidnightToBlueCallback_6Dec is Fixtures {
    using MarketParamsLib for MarketParams;
    using IndependentFeeLib for uint256;

    BorrowMidnightToBlueCallback internal callback;
    Midnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    IMorpho internal morphoBlue;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    address internal borrower;
    uint256 internal borrowerSK;
    address internal taker;
    address internal feeRecipient;

    Market internal sourceMarket;
    MarketParams internal targetMarketParams;

    function setUp() public {
        (borrower, borrowerSK) = makeAddrAndKey("Borrower");
        taker = makeAddr("Taker");
        feeRecipient = makeAddr("FeeRecipient");

        // 6-decimal loan token
        loanToken = new MockERC20("USDC", "USDC", 6);
        collateralToken = new MockERC20("Collateral", "COL", 18);

        oracle = new Oracle();
        oracle.setPrice(1e36);

        MockIrm6 irm = new MockIrm6();

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        morphoBlue = deployMorphoBlue(address(this));
        morphoBlue.enableIrm(address(irm));
        morphoBlue.enableLltv(0.77e18);

        callback = new BorrowMidnightToBlueCallback(address(midnight), address(morphoBlue));

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.77e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        sourceMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        targetMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.77e18
        });

        morphoBlue.createMarket(targetMarketParams);

        loanToken.mint(taker, 100_000e6);
        vm.prank(taker);
        loanToken.approve(address(midnight), type(uint256).max);

        vm.prank(borrower);
        loanToken.approve(address(callback), type(uint256).max);

        vm.prank(borrower);
        midnight.setIsAuthorized(address(callback), true, borrower);
    }

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(sk, digest);
        return signature;
    }

    function _setupBorrowerPosition(uint256 debtAmount, uint256 collateralAmount)
        internal
        returns (uint256 actualCollateral)
    {
        uint256 requiredCollateral = (debtAmount * 100) / 77 + 1;
        actualCollateral = collateralAmount > requiredCollateral ? collateralAmount : requiredCollateral;

        collateralToken.mint(borrower, actualCollateral);

        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), actualCollateral);
        midnight.supplyCollateral(sourceMarket, 0, actualCollateral, borrower);
        vm.stopPrank();

        (address lender2, uint256 lender2SK) = makeAddrAndKey("lender");
        loanToken.mint(lender2, debtAmount * 2);
        vm.prank(lender2);
        loanToken.approve(address(midnight), debtAmount * 2);
        vm.prank(lender2);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender2);

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: true,
            maker: lender2,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup-6dec", block.timestamp)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(offer, lender2SK);
        bytes32 offerRoot = HashLib.hashOffer(offer);

        vm.prank(borrower);
        midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            debtAmount,
            borrower,
            offer.maker,
            address(0),
            ""
        );
    }

    function test_6dec_midnightToBlue_withFee() public {
        uint256 debtAmount = 100e6; // 100 USDC
        _setupBorrowerPosition(debtAmount, 400e18);

        // Supply Blue liquidity
        loanToken.mint(address(this), debtAmount * 2);
        loanToken.approve(address(morphoBlue), debtAmount * 2);
        morphoBlue.supply(targetMarketParams, debtAmount * 2, 0, address(this), "");

        vm.startPrank(borrower);
        morphoBlue.setAuthorization(address(callback), true);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        collateralToken.mint(taker, 500e18);
        vm.startPrank(taker);
        collateralToken.approve(address(midnight), 500e18);
        midnight.supplyCollateral(sourceMarket, 0, 500e18, taker);
        vm.stopPrank();

        uint256 feeRate = 0.005e18; // 0.5%
        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: targetMarketParams, feeRate: feeRate, feeRecipient: feeRecipient
        });

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: true,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("buy_6dec_v2tov1", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: abi.encode(data),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(offer, borrowerSK);
        bytes32 offerRoot = HashLib.hashOffer(offer);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, 50e6);

        vm.prank(taker);
        (uint256 retBuyerAssets,) = midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, taker, offer.maker, address(0), ""
        );

        // Verify fee with independent math (percentage fee)
        uint256 expectedFee = IndependentFeeLib.computePercentageFee(retBuyerAssets, feeRate);
        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "6dec-Midnight to Blue: fee should match independent calculation");
        assertGt(feeReceived, 0, "6dec-Midnight to Blue: fee > 0");

        // Blue position created
        Id blueMarketId = MarketParamsLib.id(targetMarketParams);
        Position memory bluePos = morphoBlue.position(blueMarketId, borrower);
        assertGt(bluePos.borrowShares, 0, "6dec-Midnight to Blue: Blue borrow shares created");

        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec-Midnight to Blue: CB-DUST-1");
        assertEq(collateralToken.balanceOf(address(callback)), 0, "6dec-Midnight to Blue: CB-DUST-2");
    }

    function test_6dec_midnightToBlue_dustAmount() public {
        uint256 debtAmount = 100e6;
        _setupBorrowerPosition(debtAmount, 400e18);

        loanToken.mint(address(this), debtAmount * 2);
        loanToken.approve(address(morphoBlue), debtAmount * 2);
        morphoBlue.supply(targetMarketParams, debtAmount * 2, 0, address(this), "");

        vm.startPrank(borrower);
        morphoBlue.setAuthorization(address(callback), true);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        collateralToken.mint(taker, 500e18);
        vm.startPrank(taker);
        collateralToken.approve(address(midnight), 500e18);
        midnight.supplyCollateral(sourceMarket, 0, 500e18, taker);
        vm.stopPrank();

        uint256 feeRate = 0.005e18;
        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: targetMarketParams, feeRate: feeRate, feeRecipient: feeRecipient
        });

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: true,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("buy_6dec_dust", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: abi.encode(data),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(offer, borrowerSK);
        bytes32 offerRoot = HashLib.hashOffer(offer);

        bytes32 _id = IdLib.toId(offer.market);
        // Smallest meaningful amount: 1 wei USDC
        uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, 1);

        vm.prank(taker);
        (uint256 retBuyerAssets,) = midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, taker, offer.maker, address(0), ""
        );

        uint256 expectedFee = IndependentFeeLib.computePercentageFee(retBuyerAssets, feeRate);
        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "6dec-Midnight to Blue-dust: fee should match independent calculation");

        assertEq(loanToken.balanceOf(address(callback)), 0, "6dec-Midnight to Blue-dust: CB-DUST-1");
    }
}

/// @notice Mock IRM for 6-decimal tests
contract MockIrm6 is IIrm {
    function borrowRate(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 0;
    }

    function borrowRateView(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 0;
    }
}
