// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BorrowMidnightRenewalCallback} from "../../src/callbacks/BorrowMidnightRenewalCallback.sol";
import {IBorrowMidnightRenewalCallback} from "@callbacks/interfaces/IBorrowMidnightRenewalCallback.sol";
import {MidnightSupplyCollateralCallback} from "../../src/callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @title BorrowMidnightRenewalCallbackFuzzTest
/// @notice Fuzz tests for BorrowMidnightRenewalCallback to verify invariants hold across wide range of inputs
contract BorrowMidnightRenewalCallbackFuzzTest is Test {
    BorrowMidnightRenewalCallback internal callback;
    MidnightSupplyCollateralCallback internal setupCallback;
    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken1;
    MockERC20 internal collateralToken2;
    MockERC20 internal collateralToken3;
    Oracle internal oracle;

    uint256 internal borrowerSK;
    address internal borrower;
    uint256 internal lenderSK;
    address internal lender;
    address internal feeRecipient;

    Market internal sourceMarket;
    Market internal targetMarket;

    function setUp() public {
        // Create test accounts
        (borrower, borrowerSK) = makeAddrAndKey("borrower");
        (lender, lenderSK) = makeAddrAndKey("lender");
        feeRecipient = makeAddr("feeRecipient");

        // Deploy tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken1 = new MockERC20("Collateral 1", "COL1", 18);
        collateralToken2 = new MockERC20("Collateral 2", "COL2", 18);
        collateralToken3 = new MockERC20("Collateral 3", "COL3", 18);

        // Deploy oracle
        oracle = new Oracle();
        oracle.setPrice(1e36); // 1:1 price

        // Deploy Midnight
        midnight = IMidnight(deployCode("Midnight.sol:Midnight"));
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(borrower);
        IMidnight(address(midnight)).setIsAuthorized(address(ecrecoverRatifier), true, borrower);
        vm.prank(lender);
        IMidnight(address(midnight)).setIsAuthorized(address(ecrecoverRatifier), true, lender);

        // Deploy callbacks
        callback = new BorrowMidnightRenewalCallback(address(midnight));
        setupCallback = new MidnightSupplyCollateralCallback(address(midnight));

        // Set up approvals
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        loanToken.mint(borrower, type(uint128).max);
        vm.startPrank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);
        collateralToken1.approve(address(setupCallback), type(uint256).max);
        collateralToken2.approve(address(setupCallback), type(uint256).max);
        collateralToken3.approve(address(setupCallback), type(uint256).max);
        // Authorize callbacks to act on borrower's behalf
        IMidnight(address(midnight)).setIsAuthorized(address(callback), true, borrower);
        IMidnight(address(midnight)).setIsAuthorized(address(setupCallback), true, borrower);
        vm.stopPrank();
    }

    /* ========== HELPERS ========== */

    function _createMarket(uint256 numCollaterals, uint256 lltv, uint256 maturity)
        internal
        view
        returns (Market memory)
    {
        numCollaterals = bound(numCollaterals, 1, 3);
        lltv = bound(lltv, 0.385e18, 0.945e18); // Use allowed LLTV tier bounds
        maturity = bound(maturity, block.timestamp + 1 days, block.timestamp + 365 days);

        CollateralParams[] memory collaterals = new CollateralParams[](numCollaterals);
        collaterals[0] = CollateralParams({
            token: address(collateralToken1), lltv: lltv, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        if (numCollaterals > 1) {
            collaterals[1] = CollateralParams({
                token: address(collateralToken2),
                lltv: lltv,
                liquidationCursor: LIQUIDATION_CURSOR,
                oracle: address(oracle)
            });
        }
        if (numCollaterals > 2) {
            collaterals[2] = CollateralParams({
                token: address(collateralToken3),
                lltv: lltv,
                liquidationCursor: LIQUIDATION_CURSOR,
                oracle: address(oracle)
            });
        }

        // Sort collaterals by token address (Midnight requirement)
        collaterals = _sortCollaterals(collaterals);

        return Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: maturity,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _sortCollaterals(CollateralParams[] memory arr) internal pure returns (CollateralParams[] memory) {
        // Bubble sort (simple for small arrays)
        for (uint256 i = 1; i < arr.length; i++) {
            uint256 j = i;
            while (j > 0 && arr[j].token < arr[j - 1].token) {
                CollateralParams memory temp = arr[j];
                arr[j] = arr[j - 1];
                arr[j - 1] = temp;
                j--;
            }
        }
        return arr;
    }

    function _setupInitialDebt(Market memory market, uint256 debtAmount, uint256[] memory collateralAmounts) internal {
        debtAmount = bound(debtAmount, 1e18, 1000e18);

        // Mint collateral
        for (uint256 i = 0; i < market.collateralParams.length; i++) {
            address token = market.collateralParams[i].token;
            if (token == address(collateralToken1)) {
                collateralToken1.mint(borrower, collateralAmounts[i]);
            } else if (token == address(collateralToken2)) {
                collateralToken2.mint(borrower, collateralAmounts[i]);
            } else {
                collateralToken3.mint(borrower, collateralAmounts[i]);
            }
        }

        // Create supply collateral amounts
        uint256[] memory colAmounts = new uint256[](market.collateralParams.length);
        for (uint256 i = 0; i < market.collateralParams.length; i++) {
            colAmounts[i] = collateralAmounts[i];
        }

        bytes memory setupData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: debtAmount, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory borrowOffer = Offer({
            market: market,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup", block.timestamp, gasleft())),
            callback: address(setupCallback),
            callbackData: setupData,
            receiverIfMakerIsSeller: borrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(borrowOffer);
        Signature memory sig = _signOffer(borrowOffer, borrowerSK);

        bytes32 _id = IdLib.toId(borrowOffer.market);
        vm.prank(lender);
        midnight.take(
            borrowOffer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            debtAmount,
            lender,
            address(0),
            address(0),
            ""
        );
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

    /// @notice Fuzz test: Fee calculation remains consistent across various debt amounts and fee rates
    function testFuzz_feeCalculation(uint256 debtAmount, uint256 feeRate, uint256 price) public {
        // Bound inputs to reasonable ranges
        debtAmount = bound(debtAmount, 1e18, 1000e18);
        feeRate = bound(feeRate, 0, 0.5e18); // 0% to 50%
        // Upper bound kept strictly below the top tick's band (tickToPrice(priceToTick(p)) == WAD for
        // p >~ 0.9999963e18), where a 0% APR offer has no interest and the callback reverts by design.
        // Lower bound > 0 avoids the degenerate 100%-discount / infinite-APR case.
        price = bound(price, 0.001e18, 0.99999e18); // 0.1% to 99.999% (discount prices only)

        // Create markets
        sourceMarket = _createMarket(1, 0.945e18, block.timestamp + 7 days);
        targetMarket = _createMarket(1, 0.945e18, block.timestamp + 30 days);

        // Setup initial debt
        // Scale collateral to price: pro-rata transfer moves ~(price/WAD) of collateral to target,
        // so oversize the source collateral by 2e18/price to leave the target well above LLTV even
        // at deep-discount prices.
        uint256[] memory collaterals = new uint256[](1);
        collaterals[0] = (debtAmount * 2e18) / price;
        _setupInitialDebt(sourceMarket, debtAmount, collaterals);

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);

        // Skip if no debt
        vm.assume(sourceDebtBefore > 0);

        // Create renewal offer
        uint256 _tick = TickLib.priceToTick(price, DEFAULT_TICK_SPACING);

        bytes memory callbackData = abi.encode(
            IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: feeRate, feeRecipient: feeRecipient, tick: _tick
            })
        );

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: _tick,
            group: keccak256(abi.encodePacked("renew", block.timestamp, gasleft())),
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

        // Execute renewal
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = debtAmount;
        vm.prank(lender);
        (uint256 buyerAssets,) = midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );

        // Verify fee invariant using effective-price model
        uint256 feeRecipientBalanceAfter = loanToken.balanceOf(feeRecipient);
        uint256 actualFee = feeRecipientBalanceAfter - feeRecipientBalanceBefore;

        if (feeRate > 0) {
            // The callback uses sellerAssets (== buyerAssets when no settlement fee) with the seller effective price.
            // Matched units equal the take request (_shares == debtAmount) since the offer has unit-cap = max.
            uint256 sellerAssets = buyerAssets; // no settlement fee
            uint256 expectedFee = CallbackLib.sellerFeeFromTick(_tick, feeRate, _shares, sellerAssets);
            assertEq(actualFee, expectedFee, "Fee calculation invariant violated");
        } else {
            assertEq(actualFee, 0, "Fee should be zero when feeRate=0");
        }
    }

    /// @notice Fuzz test: Collateral transfer is proportional to debt repaid
    function testFuzz_proportionalCollateralTransfer(
        uint256 debtAmount,
        uint256 partialFillPercent,
        uint256 numCollaterals
    ) public {
        // Bound inputs
        debtAmount = bound(debtAmount, 10e18, 1000e18);
        partialFillPercent = bound(partialFillPercent, 10, 100); // 10% to 100%
        numCollaterals = bound(numCollaterals, 1, 3);

        // Create markets
        sourceMarket = _createMarket(numCollaterals, 0.945e18, block.timestamp + 7 days);
        targetMarket = _createMarket(numCollaterals, 0.945e18, block.timestamp + 30 days);

        // Setup collateral
        uint256[] memory collateralAmounts = new uint256[](numCollaterals);
        for (uint256 i = 0; i < numCollaterals; i++) {
            collateralAmounts[i] = (debtAmount * 2e18) / 0.945e18;
        }
        _setupInitialDebt(sourceMarket, debtAmount, collateralAmounts);

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        bytes32 targetId = IdLib.toId(targetMarket);

        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);
        vm.assume(sourceDebtBefore > 0);

        // Record collateral balances before
        uint256[] memory sourceCollateralsBefore = new uint256[](numCollaterals);
        for (uint256 i = 0; i < numCollaterals; i++) {
            sourceCollateralsBefore[i] = midnight.collateral(sourceMarketId, borrower, i);
        }

        // Create partial fill
        uint256 partialDebt = (debtAmount * partialFillPercent) / 100;
        uint256 _tick = TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING);

        bytes memory callbackData = abi.encode(
            IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: 0, feeRecipient: address(0), tick: _tick
            })
        );

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: _tick,
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
        uint256 _shares = partialDebt;
        vm.prank(lender);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );

        // Verify proportional transfer invariant
        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, borrower);
        uint256 debtRepaid = sourceDebtBefore - sourceDebtAfter;

        for (uint256 i = 0; i < numCollaterals; i++) {
            uint256 sourceCollateralAfter = midnight.collateral(sourceMarketId, borrower, i);
            uint256 targetCollateral = midnight.collateral(targetId, borrower, i);

            uint256 collateralTransferred = sourceCollateralsBefore[i] - sourceCollateralAfter;

            // Invariant: collateralTransferred = sourceCollateralBefore * debtRepaid / sourceDebtBefore (mulDivDown)
            if (sourceDebtBefore > 0 && sourceCollateralsBefore[i] > 0) {
                uint256 expectedTransfer = (sourceCollateralsBefore[i] * debtRepaid) / sourceDebtBefore;
                assertEq(collateralTransferred, expectedTransfer, "Collateral transfer not proportional");
                assertEq(targetCollateral, collateralTransferred, "Target should receive transferred collateral");
            }
        }
    }

    /// @notice Fuzz test: Final fill transfers ALL collateral (no dust remains)
    function testFuzz_finalFillNoCollateralDust(uint256 debtAmount) public {
        // Bound inputs to reasonable range
        debtAmount = bound(debtAmount, 50e18, 500e18);
        uint256 numCollaterals = 1; // Simplify to single collateral

        // Create markets
        sourceMarket = _createMarket(numCollaterals, 0.945e18, block.timestamp + 7 days);
        targetMarket = _createMarket(numCollaterals, 0.945e18, block.timestamp + 30 days);

        // Setup collateral
        uint256[] memory collateralAmounts = new uint256[](numCollaterals);
        for (uint256 i = 0; i < numCollaterals; i++) {
            collateralAmounts[i] = (debtAmount * 2e18) / 0.945e18;
        }
        _setupInitialDebt(sourceMarket, debtAmount, collateralAmounts);

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        bytes32 targetId = IdLib.toId(targetMarket);

        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);
        vm.assume(sourceDebtBefore > 0);

        // Record total collateral
        uint256[] memory totalCollaterals = new uint256[](numCollaterals);
        for (uint256 i = 0; i < numCollaterals; i++) {
            totalCollaterals[i] = midnight.collateral(sourceMarketId, borrower, i);
        }

        // For final fill at price=1 (no discount), buyerAssets == units
        // This ensures we repay EXACTLY the debt (no more, no less)
        // Using price=1 avoids rounding issues that can cause repayBudget > debt
        bytes memory callbackData = abi.encode(
            IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: 0, feeRecipient: address(0), tick: MAX_TICK
            })
        );

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK, // tick=MAX_TICK means price=WAD (no discount) so buyerAssets == units == sourceDebtBefore
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
        uint256 _shares = sourceDebtBefore;
        vm.prank(lender);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );

        // Verify final fill invariant: debt should be zero
        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, borrower);

        // Final fill: debt fully repaid, ALL collateral transferred exactly
        assertEq(sourceDebtAfter, 0, "Source debt should be fully repaid");

        for (uint256 i = 0; i < numCollaterals; i++) {
            uint256 sourceCollateralAfter = midnight.collateral(sourceMarketId, borrower, i);
            uint256 targetCollateral = midnight.collateral(targetId, borrower, i);

            // When debt is fully repaid (final fill), ALL collateral is transferred
            assertEq(sourceCollateralAfter, 0, "Source should have zero collateral after final fill");
            assertEq(targetCollateral, totalCollaterals[i], "Target should have all collateral");
        }
    }

    /// @notice Fuzz test: RepayBudget = buyerAssets - fee
    function testFuzz_repayBudgetCalculation(uint256 debtAmount, uint256 feeRate, uint256 price) public {
        // Bound inputs
        debtAmount = bound(debtAmount, 10e18, 1000e18);
        feeRate = bound(feeRate, 0, 0.5e18); // 0% to 50%
        price = bound(price, 0.9e18, 1e18); // 90% to 100%
        // When feeRate > 0 and the effective tick price == WAD, no interest exists so callback reverts by design.
        // Use the effective tick price (not the raw price) because Midnight converts tick -> price via TickLib.
        uint256 effectivePrice = TickLib.tickToPrice(TickLib.priceToTick(price, DEFAULT_TICK_SPACING));
        vm.assume(feeRate == 0 || effectivePrice < WAD);

        // Create markets
        sourceMarket = _createMarket(1, 0.945e18, block.timestamp + 7 days);
        targetMarket = _createMarket(1, 0.945e18, block.timestamp + 30 days);

        // Setup collateral
        uint256[] memory collaterals = new uint256[](1);
        collaterals[0] = (debtAmount * 2e18) / 0.945e18;
        _setupInitialDebt(sourceMarket, debtAmount, collaterals);

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);
        vm.assume(sourceDebtBefore > 0);

        // Create offer
        uint256 _tick = TickLib.priceToTick(price, DEFAULT_TICK_SPACING);

        bytes memory callbackData = abi.encode(
            IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: feeRate, feeRecipient: feeRecipient, tick: _tick
            })
        );

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: _tick,
            group: keccak256(abi.encodePacked("budget", block.timestamp, gasleft())),
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
        uint256 _shares = debtAmount;
        vm.prank(lender);
        (uint256 buyerAssets,) = midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );

        // Calculate expected fee and repayBudget
        uint256 actualFee = loanToken.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, borrower);
        uint256 repaidUnits = sourceDebtBefore - sourceDebtAfter;

        // Verify invariant: repayBudget = buyerAssets - fee (Midnight repays exact amount)
        uint256 expectedRepayBudget = buyerAssets - actualFee;
        assertEq(repaidUnits, expectedRepayBudget, "RepayBudget calculation invariant violated");

        // Verify fee calculation using effective-price model
        if (feeRate > 0) {
            // Matched units equal _shares (unit-cap is max, no internal sub-clamp).
            uint256 sellerAssets = buyerAssets; // no settlement fee
            uint256 expectedFee = CallbackLib.sellerFeeFromTick(_tick, feeRate, _shares, sellerAssets);
            assertEq(actualFee, expectedFee, "Fee should match formula");
        }
    }

    /// @notice Unit test: With 0.5e18 (50%) fee rate, fee is correctly calculated on discounted renewal
    /// @dev Uses discounted price to verify fee calculation works correctly
    function test_discountedPriceSucceedsWithFee() public {
        uint256 debtAmount = 100e18;

        // Create markets
        sourceMarket = _createMarket(1, 0.945e18, block.timestamp + 7 days);
        targetMarket = _createMarket(1, 0.945e18, block.timestamp + 30 days);

        // Setup collateral - ensure sufficient for the discounted price
        // At 80% price, market units = 100e18 / 0.8 = 125e18
        // Need collateral for 125e18 units at 94.5% LLTV
        uint256[] memory collaterals = new uint256[](1);
        collaterals[0] = 300e18; // Extra buffer for safety
        _setupInitialDebt(sourceMarket, debtAmount, collaterals);

        // Use 80% price (20% discount) with 50% fee rate
        // buyerAssets = 100e18, price = 0.80e18
        // units = 100e18 * WAD / 0.80e18 = 125e18
        // interest = 125e18 - 100e18 = 25e18
        // fee = 25e18 * 0.5 = 12.5e18
        uint256 price = 0.8e18;
        uint256 feeRate = 0.5e18;

        uint256 _tick = TickLib.priceToTick(price, DEFAULT_TICK_SPACING);

        bytes memory callbackData = abi.encode(
            IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: feeRate, feeRecipient: feeRecipient, tick: _tick
            })
        );

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: _tick,
            group: keccak256(abi.encodePacked("discount_test", block.timestamp, gasleft())),
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

        // Should succeed with fee collection
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = debtAmount;
        vm.prank(lender);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );

        // Verify fee was collected
        uint256 feeCollected = loanToken.balanceOf(feeRecipient);
        assertTrue(feeCollected > 0, "Fee should be collected for discounted renewal");
        assertTrue(feeCollected < debtAmount, "Fee should be much less than principal with 1% rate");
    }
}
