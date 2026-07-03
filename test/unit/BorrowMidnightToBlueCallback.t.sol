// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BorrowMidnightToBlueCallback} from "../../src/callbacks/BorrowMidnightToBlueCallback.sol";
import {Fixtures} from "../helpers/Fixtures.sol";
import {IBorrowMidnightToBlueCallback} from "@callbacks/interfaces/IBorrowMidnightToBlueCallback.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {MidnightSupplyCollateralCallback} from "../../src/callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
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
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

import {IIrm} from "@morphoBlue/interfaces/IIrm.sol";

contract BorrowMidnightToBlueCallbackTest is Fixtures {
    using MarketParamsLib for MarketParams;

    BorrowMidnightToBlueCallback internal callback;
    Midnight internal midnight;
    IMorpho internal morphoBlue;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    MockIrm internal irm;

    address internal borrower;
    uint256 internal borrowerSK;
    address internal taker;
    address internal feeRecipient;
    EcrecoverRatifier internal ecrecoverRatifier;

    Market internal sourceMarket;
    MarketParams internal targetMarketParams;

    function setUp() public virtual {
        (borrower, borrowerSK) = makeAddrAndKey("Borrower");
        taker = makeAddr("Taker");
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

        // Deploy real Morpho Blue using precompiled artifact
        morphoBlue = deployMorphoBlue(address(this));

        // Enable IRM and LLTV
        morphoBlue.enableIrm(address(irm));
        morphoBlue.enableLltv(0.77e18);

        // Deploy callback
        callback = new BorrowMidnightToBlueCallback(address(midnight), address(morphoBlue));

        // Setup source Midnight market
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

        // Setup target Blue market params
        targetMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.77e18 // 77% LLTV
        });

        // Create market in Morpho Blue
        morphoBlue.createMarket(targetMarketParams);

        // Setup taker with loan tokens
        loanToken.mint(taker, 100000e18);
        vm.prank(taker);
        loanToken.approve(address(midnight), type(uint256).max);

        // Borrower approves callback for loan tokens (needed for fee payment)
        vm.prank(borrower);
        loanToken.approve(address(callback), type(uint256).max);

        // Borrower authorizes callback to act on their behalf in Midnight
        vm.prank(borrower);
        midnight.setIsAuthorized(address(callback), true, borrower);
    }

    /* ========== CONSTRUCTOR TESTS ========== */

    function test_Constructor() public view {
        assertEq(address(callback.MORPHO_MIDNIGHT()), address(midnight));
        assertEq(address(callback.MORPHO_BLUE()), address(morphoBlue));
    }

    /* ========== AUTHORIZATION TESTS ========== */

    function test_onBuy_RevertsIfNotMidnight() public {
        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: targetMarketParams, feeRate: 0.01e18, feeRecipient: feeRecipient
        });

        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        callback.onBuy(bytes32(0), sourceMarket, 0, 105e18, 0, borrower, abi.encode(data));
    }

    function test_onBuy_RevertsIfZeroBuyerAssets() public {
        _setupBorrowerPosition(100e18, 0);

        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: targetMarketParams, feeRate: 0.01e18, feeRecipient: feeRecipient
        });

        // Create BUY offer with zero assets
        Offer memory offer = Offer({
            market: sourceMarket,
            buy: true,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("zero_test", block.timestamp)),
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

        vm.prank(taker);
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), 0, taker, offer.maker, address(0), ""
        );
    }

    /* ========== VALIDATION TESTS ========== */

    function test_onBuy_RevertsIfLoanTokenMismatch_TargetMarket() public {
        _setupBorrowerPosition(100e18, 0);

        // Create mismatched target market
        MarketParams memory wrongMarket = MarketParams({
            loanToken: address(0xdead), // Wrong loan token
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.77e18
        });

        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: wrongMarket, feeRate: 0.01e18, feeRecipient: feeRecipient
        });

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _shares) = _prepareBuyOffer(100e18, data);
        vm.prank(taker);
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, taker, offer.maker, address(0), ""
        );
    }

    function test_onBuy_RevertsIfCollateralNotInMarket() public {
        _setupBorrowerPosition(100e18, 0);

        // Create a new collateral token that's NOT in the source market's collaterals array
        MockERC20 wrongCollateral = new MockERC20("Wrong Collateral", "WRONG", 18);

        // Target market uses wrong collateral that's not in sourceMarket.collateralParams
        MarketParams memory wrongMarket = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(wrongCollateral),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.77e18
        });

        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: wrongMarket, feeRate: 0, feeRecipient: address(0)
        });

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _shares) = _prepareBuyOffer(100e18, data);
        vm.prank(taker);
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, taker, offer.maker, address(0), ""
        );
    }

    function test_onBuy_RevertsIfZeroSourceDebt() public {
        // This test verifies callback validation when sourceDebtBefore = 0
        // Note: This scenario cannot be reached through normal midnight.take() flow
        // because Midnight would reject it earlier. Testing direct callback invocation
        // to ensure the validation logic is correct.

        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: targetMarketParams, feeRate: 0, feeRecipient: feeRecipient
        });

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        // sourceDebtBefore = sourceDebtAfter + units = 0 + 0 = 0
        callback.onBuy(bytes32(0), sourceMarket, 100e18, 0, 0, borrower, abi.encode(data));
    }

    function test_onBuy_RevertsIfZeroSourceCollateral() public {
        // Create a Midnight source market with two collaterals
        // Midnight requires collateralParams sorted by token address (ascending)
        CollateralParams[] memory multiCollaterals = new CollateralParams[](2);
        MockERC20 secondCollateral = new MockERC20("Second Collateral", "COL2", 18);

        uint256 collateralTokenIndex;
        if (address(collateralToken) < address(secondCollateral)) {
            multiCollaterals[0] = CollateralParams({
                token: address(collateralToken),
                lltv: 0.77e18,
                liquidationCursor: LIQUIDATION_CURSOR,
                oracle: address(oracle)
            });
            multiCollaterals[1] = CollateralParams({
                token: address(secondCollateral),
                lltv: 0.77e18,
                liquidationCursor: LIQUIDATION_CURSOR,
                oracle: address(oracle)
            });
            collateralTokenIndex = 0;
        } else {
            multiCollaterals[0] = CollateralParams({
                token: address(secondCollateral),
                lltv: 0.77e18,
                liquidationCursor: LIQUIDATION_CURSOR,
                oracle: address(oracle)
            });
            multiCollaterals[1] = CollateralParams({
                token: address(collateralToken),
                lltv: 0.77e18,
                liquidationCursor: LIQUIDATION_CURSOR,
                oracle: address(oracle)
            });
            collateralTokenIndex = 1;
        }

        Market memory multiCollatMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: multiCollaterals,
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Create Blue market with the second collateral that borrower has 0 of
        MarketParams memory secondCollatMarket = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(secondCollateral),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.77e18
        });

        // Setup borrower with position in the multi-collateral Midnight market
        // They only have collateralToken, not secondCollateral
        uint256 collateralAmount = 150e18;
        collateralToken.mint(borrower, collateralAmount);

        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), collateralAmount);
        midnight.supplyCollateral(multiCollatMarket, collateralTokenIndex, collateralAmount, borrower);
        vm.stopPrank();

        // Create debt in this market
        (address lender2, uint256 lender2SK) = makeAddrAndKey("lender2");
        loanToken.mint(lender2, 200e18);
        vm.prank(lender2);
        loanToken.approve(address(midnight), 200e18);
        vm.prank(lender2);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender2);

        Offer memory setupOffer = Offer({
            market: multiCollatMarket,
            buy: true,
            maker: lender2,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup_multicollat", block.timestamp)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory setupSig = _signOffer(setupOffer, lender2SK);
        // Borrower takes the offer (borrower is the taker, so msg.sender == taker)
        {
            bytes32 _id = IdLib.toId(setupOffer.market);
            uint256 _shares = 100e18;
            vm.prank(borrower);
            midnight.take(
                setupOffer,
                abi.encode(setupSig, HashLib.hashOffer(setupOffer), uint256(0), new bytes32[](0)),
                _shares,
                borrower,
                setupOffer.maker,
                address(0),
                ""
            );
        }

        // Now borrower has debt in multiCollatMarket with 0 secondCollateral
        // Try to migrate using secondCollateral which has 0 balance
        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: secondCollatMarket, feeRate: 0, feeRecipient: address(0)
        });

        // Override sourceMarket for this test
        Offer memory buyOffer = Offer({
            market: multiCollatMarket,
            buy: true,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("zero_collat_test", block.timestamp)),
            callback: address(callback),
            callbackData: abi.encode(data),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(buyOffer, borrowerSK);
        bytes32 offerRoot = HashLib.hashOffer(buyOffer);

        {
            bytes32 _id = IdLib.toId(buyOffer.market);
            uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, buyOffer, 100e18);
            vm.prank(taker);
            vm.expectRevert();
            midnight.take(
                buyOffer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _shares,
                taker,
                buyOffer.maker,
                address(0),
                ""
            );
        }
    }

    /* ========== FEE CONFIGURATION TESTS ========== */

    function test_onBuy_RevertsIfInvalidFeeConfig_ExceedsMaxRate() public {
        _setupBorrowerPosition(100e18, 0);

        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: targetMarketParams,
            feeRate: 0.01e18 + 1, // Exceeds MAX_PERCENTAGE_FEE_RATE (1% + 1 wei)
            feeRecipient: feeRecipient
        });

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _shares) = _prepareBuyOffer(100e18, data);
        vm.prank(taker);
        vm.expectRevert(CallbackLib.InvalidFeeConfig.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, taker, offer.maker, address(0), ""
        );
    }

    /* ========== HAPPY PATH: Full Midnight to Blue Migration ========== */

    function test_onBuy_happyPath_withFee() public {
        uint256 debtAmount = 100e18;
        // Use extra collateral (3x) so Blue health check passes even with fee
        uint256 actualCollateral = _setupBorrowerPosition(debtAmount, 400e18);
        bytes32 sourceMarketId = IdLib.toId(sourceMarket);

        // Supply Blue liquidity so borrower can borrow
        loanToken.mint(address(this), debtAmount * 2);
        loanToken.approve(address(morphoBlue), debtAmount * 2);
        morphoBlue.supply(targetMarketParams, debtAmount * 2, 0, address(this), "");

        // Borrower authorizes callback on Morpho Blue and approves Midnight for loan tokens
        vm.startPrank(borrower);
        morphoBlue.setAuthorization(address(callback), true);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Taker (seller) needs collateral for Midnight health check after take
        collateralToken.mint(taker, 500e18);
        vm.startPrank(taker);
        collateralToken.approve(address(midnight), 500e18);
        midnight.supplyCollateral(sourceMarket, 0, 500e18, taker);
        vm.stopPrank();

        // Execute migration with 0.5% fee
        uint256 feeRate = 0.005e18;
        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: targetMarketParams, feeRate: feeRate, feeRecipient: feeRecipient
        });

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);
        uint256 midnightDebtBefore = midnight.debt(sourceMarketId, borrower);
        uint256 midnightColBefore = midnight.collateral(sourceMarketId, borrower, 0);

        _takeBuyOffer(50e18, data); // migrate 50e18 of the 100e18 debt

        // Midnight debt decreased
        uint256 midnightDebtAfter = midnight.debt(sourceMarketId, borrower);
        assertLt(midnightDebtAfter, midnightDebtBefore, "Midnight debt decreased");

        // Midnight collateral decreased (pro-rata transfer)
        uint256 midnightColAfter = midnight.collateral(sourceMarketId, borrower, 0);
        assertLt(midnightColAfter, midnightColBefore, "Midnight collateral decreased");

        // Blue borrow position created
        Id blueMarketId = MarketParamsLib.id(targetMarketParams);
        Position memory bluePos = morphoBlue.position(blueMarketId, borrower);
        assertGt(bluePos.borrowShares, 0, "Blue borrow shares created");
        assertGt(bluePos.collateral, 0, "Blue collateral supplied");

        // Fee paid
        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertGt(feeReceived, 0, "Fee recipient received fee");

        // CB-DUST-1: no loan token dust in callback
        assertEq(loanToken.balanceOf(address(callback)), 0, "CB-DUST-1");
        // CB-DUST-2: no collateral dust in callback
        assertEq(collateralToken.balanceOf(address(callback)), 0, "CB-DUST-2");
    }

    function test_onBuy_happyPath_zeroFee() public {
        uint256 debtAmount = 100e18;
        _setupBorrowerPosition(debtAmount, 400e18);

        // Supply Blue liquidity
        loanToken.mint(address(this), debtAmount * 2);
        loanToken.approve(address(morphoBlue), debtAmount * 2);
        morphoBlue.supply(targetMarketParams, debtAmount * 2, 0, address(this), "");

        vm.startPrank(borrower);
        morphoBlue.setAuthorization(address(callback), true);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Taker needs collateral for health check
        collateralToken.mint(taker, 500e18);
        vm.startPrank(taker);
        collateralToken.approve(address(midnight), 500e18);
        midnight.supplyCollateral(sourceMarket, 0, 500e18, taker);
        vm.stopPrank();

        // Zero fee
        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: targetMarketParams, feeRate: 0, feeRecipient: address(0)
        });

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);
        _takeBuyOffer(50e18, data);

        // No fee paid
        assertEq(loanToken.balanceOf(feeRecipient) - feeRecipientBefore, 0, "No fee with rate=0");

        // Blue position created
        Id blueMarketId = MarketParamsLib.id(targetMarketParams);
        Position memory bluePos = morphoBlue.position(blueMarketId, borrower);
        assertGt(bluePos.borrowShares, 0, "Blue borrow created even with zero fee");
    }

    /* ========== ZERO-COLLATERAL PARTIAL FILL (TRST-M-01) ========== */

    /// @notice A tiny partial fill whose pro-rata collateral rounds to zero migrates debt only,
    /// instead of reverting on Morpho Blue's zero-asset supplyCollateral check. The Blue borrow
    /// stays healthy because the borrower pre-seeded collateral on Blue.
    function test_onBuy_tinyPartialFill_zeroCollateralMigrated_succeeds() public {
        // Make collateral 1e12x more valuable than the loan token so positions are healthy
        // with a raw collateral amount far below the raw debt amount.
        oracle.setPrice(1e36 * 1e12);

        uint256 debtAmount = 10e18;
        uint256 collateralAmount = 1e8;
        bytes32 sourceMarketId = IdLib.toId(sourceMarket);

        // Midnight source position: small raw collateral, large raw debt
        collateralToken.mint(borrower, collateralAmount);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), collateralAmount);
        midnight.supplyCollateral(sourceMarket, 0, collateralAmount, borrower);
        vm.stopPrank();

        // Create the Midnight debt by having the borrower take a lender's BUY offer
        (address lender, uint256 lenderSK) = makeAddrAndKey("lender");
        loanToken.mint(lender, debtAmount * 2);
        vm.startPrank(lender);
        loanToken.approve(address(midnight), debtAmount * 2);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);
        vm.stopPrank();

        Offer memory setupOffer = Offer({
            market: sourceMarket,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup_tiny_fill", block.timestamp)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory setupSig = _signOffer(setupOffer, lenderSK);
        vm.prank(borrower);
        midnight.take(
            setupOffer,
            abi.encode(setupSig, HashLib.hashOffer(setupOffer), uint256(0), new bytes32[](0)),
            debtAmount,
            borrower,
            setupOffer.maker,
            address(0),
            ""
        );
        assertEq(midnight.debt(sourceMarketId, borrower), debtAmount, "Borrower should have Midnight debt");

        // Pre-seed Blue collateral so the debt-only migration passes Blue's health check
        collateralToken.mint(borrower, 1e8);
        vm.startPrank(borrower);
        collateralToken.approve(address(morphoBlue), 1e8);
        morphoBlue.supplyCollateral(targetMarketParams, 1e8, borrower, "");
        morphoBlue.setAuthorization(address(callback), true);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Supply Blue liquidity for the borrow
        loanToken.mint(address(this), 100e18);
        loanToken.approve(address(morphoBlue), 100e18);
        morphoBlue.supply(targetMarketParams, 100e18, 0, address(this), "");

        // Taker (seller) needs Midnight collateral for the post-take health check
        collateralToken.mint(taker, 1e8);
        vm.startPrank(taker);
        collateralToken.approve(address(midnight), 1e8);
        midnight.supplyCollateral(sourceMarket, 0, 1e8, taker);
        vm.stopPrank();

        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: targetMarketParams, feeRate: 0, feeRecipient: address(0)
        });

        // units * sourceCollateral < sourceDebtBefore => collateralMigrated rounds down to zero
        _takeBuyOffer(1e10, data);

        assertLt(midnight.debt(sourceMarketId, borrower), debtAmount, "Midnight debt should decrease");
        assertEq(
            midnight.collateral(sourceMarketId, borrower, 0),
            collateralAmount,
            "No collateral should be withdrawn on tiny fill"
        );

        Id blueMarketId = MarketParamsLib.id(targetMarketParams);
        Position memory bluePos = morphoBlue.position(blueMarketId, borrower);
        assertGt(bluePos.borrowShares, 0, "Blue borrow created");
        assertEq(bluePos.collateral, 1e8, "Blue collateral should be the pre-seeded amount only");

        // Callback should retain no tokens
        assertEq(loanToken.balanceOf(address(callback)), 0, "Callback should retain no loan tokens");
        assertEq(collateralToken.balanceOf(address(callback)), 0, "Callback should retain no collateral tokens");
    }

    /* ========== POSITION CROSSING ========== */

    /// @dev Take MORE units than the borrower's debt to cross from debt to credit.
    ///      Borrower has 20 debt. Taking 50 UNITS (not buyerAssets) clears the 20 debt
    ///      and creates 30 credit. The callback's updatePositionView sees buyerCredit=30
    ///      and reverts with PositionCrossing.
    function test_onBuy_revertsPositionCrossing() public {
        _setupBorrowerPosition(20e18, 400e18);

        // Supply Blue liquidity
        loanToken.mint(address(this), 500e18);
        loanToken.approve(address(morphoBlue), 500e18);
        morphoBlue.supply(targetMarketParams, 500e18, 0, address(this), "");

        vm.startPrank(borrower);
        morphoBlue.setAuthorization(address(callback), true);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Taker (seller) needs collateral for Midnight's health check
        collateralToken.mint(taker, 1000e18);
        vm.startPrank(taker);
        collateralToken.approve(address(midnight), 1000e18);
        midnight.supplyCollateral(sourceMarket, 0, 1000e18, taker);
        vm.stopPrank();

        IBorrowMidnightToBlueCallback.CallbackData memory data = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: targetMarketParams, feeRate: 0, feeRecipient: address(0)
        });

        Offer memory buyOffer = Offer({
            market: sourceMarket,
            buy: true,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256("crossing-test"),
            callback: address(callback),
            callbackData: abi.encode(data),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory sig = _signOffer(buyOffer, borrowerSK);

        // Take 50 UNITS directly (not buyerAssets). Borrower has 20 debt → crosses to 30 credit.
        vm.prank(taker);
        vm.expectRevert(CallbackLib.PositionCrossing.selector);
        midnight.take(
            buyOffer,
            abi.encode(sig, HashLib.hashOffer(buyOffer), uint256(0), new bytes32[](0)),
            50e18,
            taker,
            borrower,
            address(0),
            ""
        );
    }

    /* ========== HELPER FUNCTIONS ========== */

    /// @dev Sign an offer using a private key
    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(sk, digest);
        return signature;
    }

    /// @dev Prepare a BUY offer (computes shares via external calls) without executing the take.
    ///      This allows placing vm.expectRevert() between preparation and execution.
    function _prepareBuyOffer(uint256 buyerAssets, IBorrowMidnightToBlueCallback.CallbackData memory callbackData)
        internal
        view
        returns (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _shares)
    {
        offer = Offer({
            market: sourceMarket,
            buy: true,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("buy_offer", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: abi.encode(callbackData),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        sig = _signOffer(offer, borrowerSK);
        offerRoot = HashLib.hashOffer(offer);

        bytes32 _id = IdLib.toId(offer.market);
        _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, buyerAssets);
    }

    /// @dev Helper to take a BUY offer (for migration from Midnight to Blue)
    function _takeBuyOffer(uint256 buyerAssets, IBorrowMidnightToBlueCallback.CallbackData memory callbackData)
        internal
    {
        Offer memory offer = Offer({
            market: sourceMarket,
            buy: true,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("buy_offer", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: abi.encode(callbackData),
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
        uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, buyerAssets);
        vm.prank(taker);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, taker, offer.maker, address(0), ""
        );
    }

    /// @dev Setup borrower with debt and collateral in Midnight
    /// @param debtAmount The amount of debt to create
    /// @param collateralAmount The requested collateral (will be increased if needed for health)
    /// @return actualCollateral The actual collateral amount used
    function _setupBorrowerPosition(uint256 debtAmount, uint256 collateralAmount)
        internal
        returns (uint256 actualCollateral)
    {
        bytes32 marketId = IdLib.toId(sourceMarket);

        // Ensure collateral is sufficient for the LLTV (77%)
        uint256 requiredCollateral = (debtAmount * 100) / 77 + 1;
        actualCollateral = collateralAmount > requiredCollateral ? collateralAmount : requiredCollateral;

        // Mint collateral to borrower
        collateralToken.mint(borrower, actualCollateral);

        // Supply collateral to Midnight
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), actualCollateral);
        midnight.supplyCollateral(sourceMarket, 0, actualCollateral, borrower);
        vm.stopPrank();

        // Create debt by having borrower take a lender's BUY offer
        (address lender, uint256 lenderSK) = makeAddrAndKey("lender");
        loanToken.mint(lender, debtAmount * 2);

        vm.prank(lender);
        loanToken.approve(address(midnight), debtAmount * 2);
        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup", block.timestamp)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(offer, lenderSK);
        bytes32 offerRoot = HashLib.hashOffer(offer);

        // Borrower takes the offer (borrower is the taker, so msg.sender == taker)
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _takeShares = debtAmount;
        vm.prank(borrower);
        midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _takeShares,
            borrower,
            offer.maker,
            address(0),
            ""
        );

        // Verify state
        assertEq(midnight.debt(marketId, borrower), debtAmount, "Borrower should have debt");
        assertEq(midnight.collateral(marketId, borrower, 0), actualCollateral, "Borrower should have collateral");
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
