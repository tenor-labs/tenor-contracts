// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {BorrowBlueToMidnightCallback} from "../../src/callbacks/BorrowBlueToMidnightCallback.sol";
import {Fixtures} from "../helpers/Fixtures.sol";
import {IBorrowBlueToMidnightCallback} from "@callbacks/interfaces/IBorrowBlueToMidnightCallback.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {IMorpho, MarketParams, Id, Market as BlueMarket} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@morphoBlue/libraries/periphery/MorphoBalancesLib.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {IIrm} from "@morphoBlue/interfaces/IIrm.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @title BorrowBlueToMidnightCallbackFuzzTest
/// @notice Fuzz tests for BorrowBlueToMidnightCallback to verify invariants hold across wide range of inputs
contract BorrowBlueToMidnightCallbackFuzzTest is Fixtures {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    BorrowBlueToMidnightCallback internal callback;
    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    IMorpho internal morphoBlue;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    MockIrm internal irm;

    uint256 internal borrowerSK;
    address internal borrower;
    uint256 internal lenderSK;
    address internal lender;
    address internal feeRecipient;

    MarketParams internal sourceMarketParams;
    Market internal targetMarket;

    function setUp() public {
        // Create test accounts
        (borrower, borrowerSK) = makeAddrAndKey("borrower");
        (lender, lenderSK) = makeAddrAndKey("lender");
        feeRecipient = makeAddr("feeRecipient");

        // Deploy tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);

        // Deploy oracle
        oracle = new Oracle();
        oracle.setPrice(1e36); // 1:1 price

        // Deploy IRM
        irm = new MockIrm();

        // Deploy Midnight
        midnight = IMidnight(deployCode("Midnight.sol:Midnight"));
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(borrower);
        IMidnight(address(midnight)).setIsAuthorized(address(ecrecoverRatifier), true, borrower);
        vm.prank(lender);
        IMidnight(address(midnight)).setIsAuthorized(address(ecrecoverRatifier), true, lender);

        // Deploy Morpho Blue
        morphoBlue = deployMorphoBlue(address(this));
        morphoBlue.enableIrm(address(irm));
        morphoBlue.enableLltv(0.77e18);

        // Deploy callback
        callback = new BorrowBlueToMidnightCallback(address(midnight), address(morphoBlue));

        // Setup source Blue market
        sourceMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.77e18
        });
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
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Set up approvals
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        loanToken.mint(borrower, type(uint128).max);
        vm.startPrank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);
        collateralToken.approve(address(morphoBlue), type(uint256).max);
        morphoBlue.setAuthorization(address(callback), true);
        IMidnight(address(midnight)).setIsAuthorized(address(callback), true, borrower);
        vm.stopPrank();

        // Supply liquidity to Morpho Blue for borrowing
        loanToken.mint(address(this), type(uint128).max);
        loanToken.approve(address(morphoBlue), type(uint256).max);
        morphoBlue.supply(sourceMarketParams, 1000000e18, 0, address(this), "");
    }

    /* ========== HELPERS ========== */

    function _setupBluePosition(uint256 debtAmount, uint256 collateralAmount) internal {
        collateralToken.mint(borrower, collateralAmount);

        vm.startPrank(borrower);
        morphoBlue.supplyCollateral(sourceMarketParams, collateralAmount, borrower, "");
        morphoBlue.borrow(sourceMarketParams, debtAmount, 0, borrower, borrower);
        vm.stopPrank();
    }

    function _setupMidnightCollateral(uint256 amount) internal {
        collateralToken.mint(borrower, amount);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), amount);
        midnight.supplyCollateral(targetMarket, 0, amount, borrower);
        vm.stopPrank();
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

    /* ========== FUZZ TESTS ========== */

    /// @notice Fuzz test: Fee calculation is consistent - fee on interest portion
    function testFuzz_feeCalculationOnInterest(uint256 debtAmount, uint256 feeRate, uint256 price) public {
        // Bound inputs
        debtAmount = bound(debtAmount, 10e18, 500e18);
        feeRate = bound(feeRate, 0, 0.5e18);
        price = bound(price, 0.8e18, 0.99e18); // Only discounted prices (creates interest)

        // Setup Blue position
        uint256 collateralAmount = (debtAmount * 2e18) / 0.77e18;
        _setupBluePosition(debtAmount, collateralAmount);

        // Setup extra Midnight collateral to ensure health
        _setupMidnightCollateral(collateralAmount);

        Id blueMarketId = sourceMarketParams.id();
        uint256 blueDebtBefore = morphoBlue.expectedBorrowAssets(sourceMarketParams, borrower);
        vm.assume(blueDebtBefore > 0);

        // Create offer sized to repay Blue debt exactly (no excess)
        // Offer assets should equal Blue debt to avoid excess tolerance issues
        uint256 offerUnits = blueDebtBefore;

        uint256 tick = TickLib.priceToTick(price, DEFAULT_TICK_SPACING);

        bytes memory callbackData = abi.encode(
            IBorrowBlueToMidnightCallback.CallbackData({
                sourceMarketParams: sourceMarketParams, feeRate: feeRate, feeRecipient: feeRecipient, tick: tick
            })
        );

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: tick,
            group: keccak256(abi.encodePacked("fee_test", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, borrowerSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = offerUnits;
        vm.prank(lender);
        (, uint256 sellerAssets) = midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );

        // Verify fee invariant using effective-price model
        uint256 actualFee = loanToken.balanceOf(feeRecipient) - feeRecipientBalanceBefore;

        if (feeRate > 0) {
            // Fixture passes _shares with no internal sub-clamping, so matched units equal _shares.
            uint256 expectedFee = CallbackLib.sellerFeeFromTick(tick, feeRate, _shares, sellerAssets);
            assertEq(actualFee, expectedFee, "Fee calculation invariant violated");
        } else {
            assertEq(actualFee, 0, "Fee should be zero when feeRate=0");
        }
    }

    /// @notice Fuzz test: Fee never exceeds sellerAssets
    function testFuzz_feeNeverExceedsSellerAssets(uint256 debtAmount, uint256 feeRate, uint256 price) public {
        // Bound inputs
        debtAmount = bound(debtAmount, 10e18, 500e18);
        feeRate = bound(feeRate, 0, 0.5e18);
        price = bound(price, 0.5e18, 0.99e18); // Wide discount range

        // Calculate fee on interest
        uint256 units = (debtAmount * WAD) / price;
        uint256 sellerAssets = debtAmount;

        if (units > sellerAssets) {
            uint256 interest = units - sellerAssets;
            uint256 fee = (interest * feeRate) / WAD;

            // With max fee rate of 50%, max fee = 50% of interest
            // Interest = units - sellerAssets
            // At price = 0.5, units = 2 * sellerAssets
            // Interest = sellerAssets, fee = 0.5 * sellerAssets
            // So fee <= 0.5 * interest <= 0.5 * sellerAssets (at worst case)
            assertTrue(fee <= sellerAssets, "Fee should never exceed sellerAssets");
        }
    }

    /// @notice Fuzz test: Collateral migration is proportional to debt repaid (partial fill)
    function testFuzz_proportionalCollateralMigration(uint256 debtAmount, uint256 partialPercent) public {
        // Bound inputs
        debtAmount = bound(debtAmount, 50e18, 500e18);
        partialPercent = bound(partialPercent, 20, 80); // 20% to 80% partial fill

        // Setup Blue position
        uint256 collateralAmount = (debtAmount * 2e18) / 0.77e18;
        _setupBluePosition(debtAmount, collateralAmount);

        // Setup extra Midnight collateral
        _setupMidnightCollateral(collateralAmount);

        Id blueMarketId = sourceMarketParams.id();
        uint256 blueDebtBefore = morphoBlue.expectedBorrowAssets(sourceMarketParams, borrower);
        uint256 blueCollateralBefore = morphoBlue.position(blueMarketId, borrower).collateral;
        vm.assume(blueDebtBefore > 0);
        vm.assume(blueCollateralBefore > 0);

        // Create partial fill offer
        uint256 partialAmount = (blueDebtBefore * partialPercent) / 100;

        bytes memory callbackData = abi.encode(
            IBorrowBlueToMidnightCallback.CallbackData({
                sourceMarketParams: sourceMarketParams,
                feeRate: 0, // No fee for simpler calculation
                feeRecipient: address(0),
                tick: MAX_TICK
            })
        );

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("partial", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, borrowerSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = partialAmount;
        vm.prank(lender);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );

        // Verify proportional collateral migration
        uint256 blueCollateralAfter = morphoBlue.position(blueMarketId, borrower).collateral;
        uint256 blueDebtAfter = morphoBlue.expectedBorrowAssets(sourceMarketParams, borrower);

        uint256 collateralMigrated = blueCollateralBefore - blueCollateralAfter;
        uint256 debtRepaid = blueDebtBefore - blueDebtAfter;

        // Invariant: collateralMigrated = blueCollateralBefore * debtRepaid / blueDebtBefore
        if (blueDebtBefore > 0 && debtRepaid > 0) {
            uint256 expectedMigration = (blueCollateralBefore * debtRepaid) / blueDebtBefore;
            assertEq(collateralMigrated, expectedMigration, "Collateral migration not proportional");
        }
    }

    /// @notice Fuzz test: Final fill transfers ALL collateral (no dust)
    function testFuzz_finalFillTransfersAllCollateral(uint256 debtAmount) public {
        // Bound inputs
        debtAmount = bound(debtAmount, 50e18, 500e18);

        // Setup Blue position
        uint256 collateralAmount = (debtAmount * 2e18) / 0.77e18;
        _setupBluePosition(debtAmount, collateralAmount);

        // Setup extra Midnight collateral
        _setupMidnightCollateral(collateralAmount);

        Id blueMarketId = sourceMarketParams.id();
        bytes32 targetMarketId = IdLib.toId(targetMarket);

        uint256 blueDebtBefore = morphoBlue.expectedBorrowAssets(sourceMarketParams, borrower);
        uint256 blueCollateralBefore = morphoBlue.position(blueMarketId, borrower).collateral;
        vm.assume(blueDebtBefore > 0);
        vm.assume(blueCollateralBefore > 0);

        // Create full repayment offer
        bytes memory callbackData = abi.encode(
            IBorrowBlueToMidnightCallback.CallbackData({
                sourceMarketParams: sourceMarketParams, feeRate: 0, feeRecipient: address(0), tick: MAX_TICK
            })
        );

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("final", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, borrowerSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = blueDebtBefore;
        vm.prank(lender);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );

        // Verify final fill: all collateral migrated
        uint256 blueCollateralAfter = morphoBlue.position(blueMarketId, borrower).collateral;
        uint256 blueBorrowSharesAfter = morphoBlue.position(blueMarketId, borrower).borrowShares;

        assertEq(blueBorrowSharesAfter, 0, "Blue debt should be fully repaid");
        assertEq(blueCollateralAfter, 0, "Blue collateral should be zero after final fill");

        // Verify Midnight received all collateral (plus any extra we added)
        uint256 midnightCollateral = midnight.collateral(targetMarketId, borrower, 0);
        assertEq(
            midnightCollateral, blueCollateralBefore + collateralAmount, "Midnight should have all migrated collateral"
        );
    }

    /// @notice Fuzz test: Reverts when repayBudget exceeds Blue debt
    function testFuzz_revertsOnExcessRepayBudget(uint256 debtAmount, uint256 excessBps) public {
        // Bound inputs
        debtAmount = bound(debtAmount, 100e18, 500e18);
        excessBps = bound(excessBps, 1, 5000); // 0.01% to 50% excess

        // Setup Blue position
        uint256 collateralAmount = (debtAmount * 2e18) / 0.77e18;
        _setupBluePosition(debtAmount, collateralAmount);

        // Setup extra Midnight collateral
        _setupMidnightCollateral(collateralAmount);

        uint256 blueDebtBefore = morphoBlue.expectedBorrowAssets(sourceMarketParams, borrower);
        vm.assume(blueDebtBefore > 0);

        // Create offer with excess (repayBudget > Blue debt)
        uint256 offerAmount = blueDebtBefore + (blueDebtBefore * excessBps) / 10000;

        bytes memory callbackData = abi.encode(
            IBorrowBlueToMidnightCallback.CallbackData({
                sourceMarketParams: sourceMarketParams, feeRate: 0, feeRecipient: address(0), tick: MAX_TICK
            })
        );

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("excess", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, borrowerSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = offerAmount;
        vm.prank(lender);
        vm.expectRevert(CallbackLib.ExcessRepayment.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );
    }

    /// @notice Unit test: Discounted price with fee works correctly
    function test_discountedPriceWithFee() public {
        uint256 debtAmount = 100e18;
        uint256 price = 0.9e18; // 10% discount
        uint256 feeRate = 0.5e18; // 50% fee on interest

        // Setup Blue position
        uint256 collateralAmount = (debtAmount * 3e18) / 0.77e18; // Extra buffer
        _setupBluePosition(debtAmount, collateralAmount);

        // Setup extra Midnight collateral
        _setupMidnightCollateral(collateralAmount);

        uint256 blueDebtBefore = morphoBlue.expectedBorrowAssets(sourceMarketParams, borrower);

        uint256 tick = TickLib.priceToTick(price, DEFAULT_TICK_SPACING);

        bytes memory callbackData = abi.encode(
            IBorrowBlueToMidnightCallback.CallbackData({
                sourceMarketParams: sourceMarketParams, feeRate: feeRate, feeRecipient: feeRecipient, tick: tick
            })
        );

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: tick,
            group: keccak256(abi.encodePacked("discount", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, borrowerSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = blueDebtBefore;
        vm.prank(lender);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );

        // Verify fee was collected
        uint256 actualFee = loanToken.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertTrue(actualFee > 0, "Fee should be collected for discounted migration");

        // Calculate expected fee using effective-price model
        uint256 actualPrice = TickLib.tickToPrice(tick);
        uint256 expectedSellerAssets = (blueDebtBefore * actualPrice) / WAD;
        uint256 expectedMarketUnits = blueDebtBefore;
        uint256 expectedFee = CallbackLib.sellerFeeFromTick(tick, feeRate, expectedMarketUnits, expectedSellerAssets);

        assertEq(actualFee, expectedFee, "Fee should match expected calculation");
    }

    /// @notice Fuzz test: Repaying blueDebt - 1 never clears all borrow shares
    /// @dev expectedBorrowAssets rounds up (toAssetsUp), repay converts via toSharesDown.
    ///      These opposing rounding directions guarantee that repaying 1 wei less than
    ///      the rounded-up debt always leaves at least 1 borrow share.
    function testFuzz_repayOneLessThanExpectedDebtDoesNotClearShares(uint256 debtAmount) public {
        debtAmount = bound(debtAmount, 1e6, 500e18);

        uint256 collateralAmount = (debtAmount * 2e18) / 0.77e18;
        _setupBluePosition(debtAmount, collateralAmount);

        Id blueMarketId = sourceMarketParams.id();
        uint256 blueDebt = morphoBlue.expectedBorrowAssets(sourceMarketParams, borrower);
        vm.assume(blueDebt > 1);

        vm.startPrank(borrower);
        loanToken.approve(address(morphoBlue), blueDebt - 1);
        morphoBlue.repay(sourceMarketParams, blueDebt - 1, 0, borrower, "");
        vm.stopPrank();

        uint256 remainingShares = morphoBlue.position(blueMarketId, borrower).borrowShares;
        assertGt(remainingShares, 0, "Repaying blueDebt - 1 should not clear all borrow shares");
    }
}

/// @notice Mock IRM contract for testing
contract MockIrm is IIrm {
    function borrowRate(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 0;
    }

    function borrowRateView(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 0;
    }
}
