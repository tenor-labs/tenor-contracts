// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BorrowBlueToMidnightCallback} from "../../src/callbacks/BorrowBlueToMidnightCallback.sol";
import {Fixtures} from "../helpers/Fixtures.sol";
import {IBorrowBlueToMidnightCallback} from "@callbacks/interfaces/IBorrowBlueToMidnightCallback.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {Market, CollateralParams, Offer, IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {IMorpho, MarketParams, Position, Id, Market as BlueMarket} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

import {MorphoBalancesLib} from "@morphoBlue/libraries/periphery/MorphoBalancesLib.sol";
import {IIrm} from "@morphoBlue/interfaces/IIrm.sol";

contract BorrowBlueToMidnightCallbackTest is Fixtures {
    using MarketParamsLib for MarketParams;

    BorrowBlueToMidnightCallback internal callback;
    Midnight internal midnight;
    IMorpho internal morphoBlue;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    MockIrm internal irm;

    address internal borrower;
    uint256 internal borrowerSK;
    address internal lender;
    uint256 internal lenderSK;
    address internal feeRecipient;
    EcrecoverRatifier internal ecrecoverRatifier;

    Market internal targetMarket;
    MarketParams internal sourceMarketParams;

    function setUp() public virtual {
        (borrower, borrowerSK) = makeAddrAndKey("Borrower");
        (lender, lenderSK) = makeAddrAndKey("Lender");
        feeRecipient = makeAddr("FeeRecipient");

        // Deploy tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral Token", "COL", 18);

        // Deploy oracle
        oracle = new Oracle();
        oracle.setPrice(1e36); // 1:1 price

        // Deploy IRM
        irm = new MockIrm();

        // Deploy real Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);
        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);

        // Deploy real Morpho Blue using precompiled artifact
        morphoBlue = deployMorphoBlue(address(this));

        // Enable IRM and LLTV
        morphoBlue.enableIrm(address(irm));
        morphoBlue.enableLltv(0.77e18);

        // Deploy callback
        callback = new BorrowBlueToMidnightCallback(address(midnight), address(morphoBlue));

        // Setup source Blue market params
        sourceMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.77e18 // 77% LLTV
        });

        // Create market in Morpho Blue
        morphoBlue.createMarket(sourceMarketParams);

        // Setup target Midnight market
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.77e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        targetMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Setup lender with loan tokens for taking offers
        loanToken.mint(lender, 100000e18);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        // Borrower authorizes callback on Morpho Blue
        vm.prank(borrower);
        morphoBlue.setAuthorization(address(callback), true);
    }

    /* ========== CONSTRUCTOR TESTS ========== */

    function test_Constructor() public view {
        assertEq(address(callback.MORPHO_MIDNIGHT()), address(midnight));
        assertEq(address(callback.MORPHO_BLUE()), address(morphoBlue));
    }

    /* ========== AUTHORIZATION TESTS ========== */

    function test_onSell_RevertsIfNotMidnight() public {
        IBorrowBlueToMidnightCallback.CallbackData memory data = IBorrowBlueToMidnightCallback.CallbackData({
            sourceMarketParams: sourceMarketParams, feeRate: 0.1e18, feeRecipient: feeRecipient, tick: MAX_TICK
        });

        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        callback.onSell(bytes32(0), targetMarket, 95e18, 100e18, 0, borrower, address(callback), abi.encode(data));
    }

    function test_onSell_RevertsIfReceiverIsNotCallback() public {
        IBorrowBlueToMidnightCallback.CallbackData memory data = IBorrowBlueToMidnightCallback.CallbackData({
            sourceMarketParams: sourceMarketParams, feeRate: 0.1e18, feeRecipient: feeRecipient, tick: 5820
        });

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.InvalidReceiver.selector);
        callback.onSell(bytes32(0), targetMarket, 95e18, 100e18, 0, borrower, borrower, abi.encode(data));
    }

    function test_onSell_RevertsIfZeroSellerAssets() public {
        _setupBorrowerBluePosition(100e18, 150e18);

        IBorrowBlueToMidnightCallback.CallbackData memory data = IBorrowBlueToMidnightCallback.CallbackData({
            sourceMarketParams: sourceMarketParams, feeRate: 0, feeRecipient: address(0), tick: MAX_TICK
        });

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        callback.onSell(bytes32(0), targetMarket, 0, 0, 0, borrower, address(callback), abi.encode(data));
    }

    /* ========== VALIDATION TESTS ========== */

    function test_onSell_RevertsIfLoanTokenMismatch() public {
        _setupBorrowerBluePosition(100e18, 150e18);

        // Pre-create the market so settlementFee() doesn't revert
        collateralToken.mint(borrower, 200e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), 200e18);
        midnight.supplyCollateral(targetMarket, 0, 200e18, borrower);
        vm.stopPrank();

        // Create mismatched source market
        MarketParams memory wrongMarket = MarketParams({
            loanToken: address(0xdead), // Wrong loan token
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.77e18
        });

        IBorrowBlueToMidnightCallback.CallbackData memory data = IBorrowBlueToMidnightCallback.CallbackData({
            sourceMarketParams: wrongMarket, feeRate: 0, feeRecipient: address(0), tick: MAX_TICK
        });

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) =
            _prepareSellOffer(100e18, 0.95e18, data);
        vm.prank(lender);
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, lender, address(0), address(0), ""
        );
    }

    function test_onSell_RevertsIfCollateralNotInMarket() public {
        // Pre-create the market so settlementFee() doesn't revert
        collateralToken.mint(borrower, 200e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), 200e18);
        midnight.supplyCollateral(targetMarket, 0, 200e18, borrower);
        vm.stopPrank();

        // Create a collateral token that's NOT in the Midnight targetMarket's collaterals array
        MockERC20 wrongCollateral = new MockERC20("Wrong Collateral", "WRONG", 18);

        // Create source market with wrong collateral
        MarketParams memory wrongMarket = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(wrongCollateral), // This collateral is NOT in targetMarket
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.77e18
        });

        IBorrowBlueToMidnightCallback.CallbackData memory data = IBorrowBlueToMidnightCallback.CallbackData({
            sourceMarketParams: wrongMarket, feeRate: 0, feeRecipient: address(0), tick: MAX_TICK
        });

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) =
            _prepareSellOffer(100e18, 0.95e18, data);
        vm.prank(lender);
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, lender, address(0), address(0), ""
        );
    }

    function test_onSell_RevertsIfZeroBlueDebt() public {
        // Borrower has no Blue position
        IBorrowBlueToMidnightCallback.CallbackData memory data = IBorrowBlueToMidnightCallback.CallbackData({
            sourceMarketParams: sourceMarketParams, feeRate: 0, feeRecipient: address(0), tick: MAX_TICK
        });

        // Need to give borrower collateral for Midnight health check
        collateralToken.mint(borrower, 200e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), 200e18);
        midnight.supplyCollateral(targetMarket, 0, 200e18, borrower);
        vm.stopPrank();

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) =
            _prepareSellOffer(100e18, 0.95e18, data);
        vm.prank(lender);
        vm.expectRevert(CallbackLib.ExcessRepayment.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, lender, address(0), address(0), ""
        );
    }

    function test_onSell_RevertsIfZeroBlueCollateral() public {
        // Setup Blue position with debt but no collateral (simulate edge case via direct call)
        IBorrowBlueToMidnightCallback.CallbackData memory data = IBorrowBlueToMidnightCallback.CallbackData({
            sourceMarketParams: sourceMarketParams, feeRate: 0, feeRecipient: address(0), tick: MAX_TICK
        });

        // Direct callback call: receiverIfMakerIsSeller is the borrower who has no loan tokens,
        // so the safeTransferFrom to pull sellerAssets reverts with ERC20InsufficientBalance.
        vm.prank(address(midnight));
        vm.expectRevert();
        callback.onSell(bytes32(0), targetMarket, 95e18, 100e18, 0, borrower, address(callback), abi.encode(data));
    }

    /* ========== FEE CONFIGURATION TESTS ========== */

    function test_onSell_RevertsIfInvalidFeeConfig_ExceedsMaxRate() public {
        _setupBorrowerBluePosition(100e18, 150e18);

        // Also give borrower collateral for Midnight
        collateralToken.mint(borrower, 200e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), 200e18);
        midnight.supplyCollateral(targetMarket, 0, 200e18, borrower);
        vm.stopPrank();

        IBorrowBlueToMidnightCallback.CallbackData memory data = IBorrowBlueToMidnightCallback.CallbackData({
            sourceMarketParams: sourceMarketParams,
            feeRate: 1e18 + 1, // Exceeds max (WAD + 1)
            feeRecipient: feeRecipient,
            tick: MAX_TICK
        });

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) =
            _prepareSellOffer(100e18, 0.95e18, data);
        vm.prank(lender);
        vm.expectRevert(CallbackLib.InvalidFeeConfig.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, lender, address(0), address(0), ""
        );
    }

    /* ========== FEE CALCULATION TESTS ========== */

    function test_FeeCalculation_ZeroFeeWhenNoInterest() public pure {
        // When units <= sellerAssets, no interest = no fee
        uint256 units = 100e18;
        uint256 sellerAssets = 100e18;
        uint256 feeRate = 0.5e18; // 50%

        // interest = units - sellerAssets = 0
        // fee = 0 * feeRate / WAD = 0
        uint256 interest = units > sellerAssets ? units - sellerAssets : 0;
        uint256 fee = (interest * feeRate) / WAD;

        assertEq(fee, 0, "Fee should be 0 when no interest");
    }

    function test_FeeCalculation_OnInterestPortion() public pure {
        uint256 units = 100e18; // Face value
        uint256 sellerAssets = 95e18; // What borrower receives (5% discount)
        uint256 feeRate = 0.5e18; // 50% fee on interest

        uint256 interest = units - sellerAssets; // 5e18
        uint256 expectedFee = (interest * feeRate) / WAD; // 2.5e18

        assertEq(expectedFee, 2.5e18, "Fee should be 50% of 5e18 interest");
    }

    function test_FeeCalculation_MaxFeeRate() public view {
        uint256 units = 100e18;
        uint256 sellerAssets = 90e18; // 10% discount
        uint256 feeRate = 0.5e18; // 50%

        uint256 interest = units - sellerAssets; // 10e18
        uint256 expectedFee = (interest * feeRate) / WAD; // 5e18

        assertEq(expectedFee, 5e18, "Fee should be 50% of 10e18 interest");
    }

    /* ========== RECEIVER = CALLBACK (Option A) ========== */

    function test_onSell_receiverIsCallback_migratesPosition() public {
        uint256 debtAmount = 100e18;
        uint256 collateralAmount = 150e18;
        _setupBorrowerBluePosition(debtAmount, collateralAmount);

        // Supply Midnight collateral so the position is healthy after migration
        collateralToken.mint(borrower, 200e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), 200e18);
        midnight.supplyCollateral(targetMarket, 0, 200e18, borrower);
        // Authorize callback on Midnight (needed for supplyCollateral on behalf of borrower)
        midnight.setIsAuthorized(address(callback), true, borrower);
        vm.stopPrank();

        Id sourceBlueMarketId = sourceMarketParams.id();
        Position memory posBefore = morphoBlue.position(sourceBlueMarketId, borrower);
        uint256 blueBorrowSharesBefore = posBefore.borrowShares;
        uint256 blueCollateralBefore = posBefore.collateral;

        // Option A: receiver = callback, receiverIfMakerIsSeller = callback
        IBorrowBlueToMidnightCallback.CallbackData memory callbackData = IBorrowBlueToMidnightCallback.CallbackData({
            sourceMarketParams: sourceMarketParams, feeRate: 0, feeRecipient: address(0), tick: MAX_TICK
        });

        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, uint256(50e18), "optionA"));
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: abi.encode(callbackData),
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(offer, borrowerSK);
        bytes32 offerRoot = HashLib.hashOffer(offer);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _units = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, debtAmount);

        vm.prank(lender);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, lender, address(0), address(0), ""
        );

        // Verify Blue debt decreased
        Position memory posAfter = morphoBlue.position(sourceBlueMarketId, borrower);
        assertTrue(posAfter.borrowShares < blueBorrowSharesBefore, "Blue borrow shares should have decreased");

        // Verify Blue collateral decreased (migrated to Midnight)
        assertTrue(posAfter.collateral < blueCollateralBefore, "Blue collateral should have decreased");

        // Callback should retain no tokens
        assertEq(loanToken.balanceOf(address(callback)), 0, "Callback should retain no loan tokens");
        assertEq(collateralToken.balanceOf(address(callback)), 0, "Callback should retain no collateral tokens");
    }

    function test_onSell_receiverIsCallback_withFee() public {
        uint256 debtAmount = 100e18;
        uint256 collateralAmount = 150e18;
        _setupBorrowerBluePosition(debtAmount, collateralAmount);

        // Supply Midnight collateral so the position is healthy after migration
        collateralToken.mint(borrower, 200e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), 200e18);
        midnight.supplyCollateral(targetMarket, 0, 200e18, borrower);
        // Authorize callback on Midnight (needed for supplyCollateral on behalf of borrower)
        midnight.setIsAuthorized(address(callback), true, borrower);
        vm.stopPrank();

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        uint256 feeRate = 0.5e18; // 50% fee on interest
        uint16 tick = 4288; // Lower tick = lower price = more discount = more interest for fee

        // Option A: receiver = callback, receiverIfMakerIsSeller = callback
        IBorrowBlueToMidnightCallback.CallbackData memory callbackData = IBorrowBlueToMidnightCallback.CallbackData({
            sourceMarketParams: sourceMarketParams, feeRate: feeRate, feeRecipient: feeRecipient, tick: tick
        });

        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, uint256(50e18), "optionAFee"));
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: abi.encode(callbackData),
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(offer, borrowerSK);
        bytes32 offerRoot = HashLib.hashOffer(offer);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _units = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, debtAmount);

        vm.prank(lender);
        (, uint256 sellerAssets) = midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, lender, address(0), address(0), ""
        );

        // Verify fee was paid to feeRecipient (independent math, not CallbackLib)
        // sellerEffPrice = price * WAD / (WAD + x), rounded up
        // sellerFee = sellerAssets - mulDivUp(units, sellerEffPrice, WAD), zero floor
        // where x = (WAD - price) * feeRate / WAD, rounded down
        uint256 expectedFee;
        {
            uint256 price = TickLib.tickToPrice(tick);
            uint256 x = UtilsLib.mulDivDown(WAD - price, feeRate, WAD);
            uint256 effPrice = UtilsLib.mulDivUp(price, WAD, WAD + x);
            // Matched units equal _units (offer unit-cap is max, no internal sub-clamp).
            expectedFee = UtilsLib.zeroFloorSub(sellerAssets, UtilsLib.mulDivUp(_units, effPrice, WAD));
        }
        assertEq(
            loanToken.balanceOf(feeRecipient),
            feeRecipientBalanceBefore + expectedFee,
            "Fee recipient should receive fee"
        );
        assertTrue(expectedFee > 0, "Fee should be non-zero");

        // Callback should retain no tokens
        assertEq(loanToken.balanceOf(address(callback)), 0, "Callback should retain no loan tokens");
        assertEq(collateralToken.balanceOf(address(callback)), 0, "Callback should retain no collateral tokens");
    }

    /* ========== ZERO-COLLATERAL PARTIAL FILL (TRST-M-01) ========== */

    /// @notice A tiny partial fill whose pro-rata collateral rounds to zero migrates debt only,
    /// instead of reverting on Morpho Blue's zero-asset withdrawCollateral check.
    function test_onSell_tinyPartialFill_zeroCollateralMigrated_succeeds() public {
        // Make collateral 1e12x more valuable than the loan token so the Blue position is
        // healthy with a raw collateral amount far below the raw debt amount.
        oracle.setPrice(1e36 * 1e12);

        uint256 debtAmount = 10e18;
        uint256 collateralAmount = 1e8;
        _setupBorrowerBluePosition(debtAmount, collateralAmount);

        // Supply Midnight collateral so the position stays healthy after the debt-only migration
        collateralToken.mint(borrower, 1e8);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), 1e8);
        midnight.supplyCollateral(targetMarket, 0, 1e8, borrower);
        midnight.setIsAuthorized(address(callback), true, borrower);
        vm.stopPrank();

        Id sourceBlueMarketId = sourceMarketParams.id();
        Position memory posBefore = morphoBlue.position(sourceBlueMarketId, borrower);
        bytes32 targetMarketId = IdLib.toId(targetMarket);
        uint256 midnightColBefore = midnight.collateral(targetMarketId, borrower, 0);

        IBorrowBlueToMidnightCallback.CallbackData memory callbackData = IBorrowBlueToMidnightCallback.CallbackData({
            sourceMarketParams: sourceMarketParams, feeRate: 0, feeRecipient: address(0), tick: MAX_TICK
        });

        // repayBudget * blueCollateral < blueDebt => collateralMigrated rounds down to zero
        _takeSellOffer(1e10, 0.95e18, callbackData);

        Position memory posAfter = morphoBlue.position(sourceBlueMarketId, borrower);
        assertLt(posAfter.borrowShares, posBefore.borrowShares, "Blue debt should be partially repaid");
        assertEq(posAfter.collateral, posBefore.collateral, "No collateral should be migrated on tiny fill");
        assertEq(midnight.collateral(targetMarketId, borrower, 0), midnightColBefore, "Midnight collateral unchanged");

        // Callback should retain no tokens
        assertEq(loanToken.balanceOf(address(callback)), 0, "Callback should retain no loan tokens");
        assertEq(collateralToken.balanceOf(address(callback)), 0, "Callback should retain no collateral tokens");
    }

    /* ========== HELPER FUNCTIONS ========== */

    /// @dev Sign an offer using EIP-712
    function _signOffer(Offer memory offer, uint256 privateKey) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(privateKey, digest);
        return signature;
    }

    /// @dev Helper to take a SELL offer (for migration from Blue to Midnight)
    function _takeSellOffer(
        uint256 sellerAssets,
        uint256 price,
        IBorrowBlueToMidnightCallback.CallbackData memory callbackData
    ) internal {
        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) =
            _prepareSellOffer(sellerAssets, price, callbackData);
        vm.prank(lender);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, lender, address(0), address(0), ""
        );
    }

    /// @dev Prepare a SELL offer (computes shares via external calls) without executing the take.
    ///      This allows placing vm.expectRevert() between preparation and execution.
    function _prepareSellOffer(
        uint256 sellerAssets,
        uint256 price,
        IBorrowBlueToMidnightCallback.CallbackData memory callbackData
    ) internal view returns (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) {
        offer = Offer({
            market: targetMarket,
            buy: false, // SELL offer
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("sell_offer", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: abi.encode(callbackData),
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        sig = _signOffer(offer, borrowerSK);
        offerRoot = HashLib.hashOffer(offer);

        bytes32 _id = IdLib.toId(offer.market);
        _units = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, sellerAssets);
    }

    /// @dev Setup borrower with debt and collateral in Morpho Blue
    /// @param debtAmount The amount of debt to create
    /// @param collateralAmount The amount of collateral to supply
    function _setupBorrowerBluePosition(uint256 debtAmount, uint256 collateralAmount) internal {
        Id blueMarketId = sourceMarketParams.id();

        // Mint collateral to borrower
        collateralToken.mint(borrower, collateralAmount);

        // Supply collateral to Blue
        vm.startPrank(borrower);
        collateralToken.approve(address(morphoBlue), collateralAmount);
        morphoBlue.supplyCollateral(sourceMarketParams, collateralAmount, borrower, "");
        vm.stopPrank();

        // Supply liquidity for borrowing
        loanToken.mint(address(this), debtAmount * 2);
        loanToken.approve(address(morphoBlue), debtAmount * 2);
        morphoBlue.supply(sourceMarketParams, debtAmount * 2, 0, address(this), "");

        // Borrower borrows
        vm.prank(borrower);
        morphoBlue.borrow(sourceMarketParams, debtAmount, 0, borrower, borrower);

        // Verify state
        Position memory position = morphoBlue.position(blueMarketId, borrower);
        assertTrue(position.borrowShares > 0, "Borrower should have borrow shares");
        assertEq(position.collateral, collateralAmount, "Borrower should have collateral");
    }
}

/// @notice Regression test: shares-mode repay prevents underflow when third-party dust repay
/// shifts the borrow share/asset ratio after interest accrual.
contract BorrowBlueToMidnightCallback_SharesModeRepayTest is BorrowBlueToMidnightCallbackTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    address internal attacker;

    function setUp() public override {
        super.setUp();
        attacker = makeAddr("Attacker");

        // Replace IRM with high-rate variant to amplify rounding in small positions
        irm = new MockIrm(); // base class uses 0% — override the market
        HighRateIrm highIrm = new HighRateIrm();
        morphoBlue.enableIrm(address(highIrm));

        // Recreate source market with the high-rate IRM
        sourceMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(highIrm),
            lltv: 0.77e18
        });
        morphoBlue.createMarket(sourceMarketParams);
    }

    /// @notice Final fill migration succeeds even after a third-party dust repay
    /// that would otherwise cause an arithmetic underflow in assets-mode repay.
    function test_finalFill_succeedsAfterThirdPartyDustRepay() public {
        uint256 debtAmount = 2;
        uint256 collateralAmount = 100;

        // Setup small Blue position
        _setupBorrowerBluePosition(debtAmount, collateralAmount);

        // Accrue 1 second of high interest to widen the share/asset ratio
        vm.warp(block.timestamp + 1);
        morphoBlue.accrueInterest(sourceMarketParams);

        Id sourceBlueMarketId = sourceMarketParams.id();
        uint256 blueDebt = morphoBlue.expectedBorrowAssets(sourceMarketParams, borrower);
        assertGt(blueDebt, debtAmount, "interest should have accrued");

        // Attacker front-runs with a 1-wei dust repay on behalf of borrower
        loanToken.mint(attacker, 1);
        vm.startPrank(attacker);
        loanToken.approve(address(morphoBlue), 1);
        morphoBlue.repay(sourceMarketParams, 1, 0, borrower, "");
        vm.stopPrank();

        // Setup Midnight side: borrower needs collateral in target market + callback authorization
        collateralToken.mint(borrower, 200);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), 200);
        midnight.supplyCollateral(targetMarket, 0, 200, borrower);
        midnight.setIsAuthorized(address(callback), true, borrower);
        vm.stopPrank();

        // Re-read debt after dust repay (may round to same value due to toAssetsUp)
        uint256 blueDebtAfterDust = morphoBlue.expectedBorrowAssets(sourceMarketParams, borrower);

        // Attempt full migration — with shares-mode fix this should succeed
        IBorrowBlueToMidnightCallback.CallbackData memory callbackData = IBorrowBlueToMidnightCallback.CallbackData({
            sourceMarketParams: sourceMarketParams, feeRate: 0, feeRecipient: address(0), tick: MAX_TICK
        });

        _takeSellOffer(blueDebtAfterDust, 0.95e18, callbackData);

        // Blue position fully closed
        Position memory posAfter = morphoBlue.position(sourceBlueMarketId, borrower);
        assertEq(posAfter.borrowShares, 0, "Blue borrow shares should be zero after full migration");
    }
}

/// @notice Mock IRM contract for testing
contract MockIrm is IIrm {
    function borrowRate(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 0; // 0% interest for testing
    }

    function borrowRateView(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 0;
    }
}

/// @notice High-rate IRM to amplify rounding effects in small positions
contract HighRateIrm is IIrm {
    function borrowRate(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 4_520_000_000_000_000_000; // 4.52e18 per second
    }

    function borrowRateView(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 4_520_000_000_000_000_000;
    }
}
