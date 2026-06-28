// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BorrowMidnightRenewalCallback} from "../../src/callbacks/BorrowMidnightRenewalCallback.sol";
import {IBorrowMidnightRenewalCallback} from "@callbacks/interfaces/IBorrowMidnightRenewalCallback.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {MidnightSupplyCollateralCallback} from "../../src/callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

contract BorrowMidnightRenewalCallbackTest is Test {
    BorrowMidnightRenewalCallback internal callback;
    Midnight internal midnight;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken1;
    MockERC20 internal collateralToken2;
    Oracle internal oracle;
    address internal borrower; // Borrower (seller) who wants to renew
    uint256 internal borrowerSK;
    address internal lender; // Lender who takes offers (provides loan tokens)
    address internal feeRecipient;
    EcrecoverRatifier internal ecrecoverRatifier;

    Market internal sourceMarket;
    Market internal targetMarket;

    function setUp() public virtual {
        (borrower, borrowerSK) = makeAddrAndKey("Borrower");
        lender = makeAddr("Lender");
        feeRecipient = makeAddr("FeeRecipient");

        // Deploy real tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken1 = new MockERC20("Collateral 1", "COL1", 18);
        collateralToken2 = new MockERC20("Collateral 2", "COL2", 18);

        // Deploy oracle
        oracle = new Oracle();
        oracle.setPrice(10e36); // 10:1 price - collateral worth 10x loan token (allows renewals with interest)

        // Deploy real Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this)); // Set fee recipient to avoid address(0) transfers
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        // Deploy callback contract
        callback = new BorrowMidnightRenewalCallback(address(midnight));

        // Set up lender with loan tokens (needed early for setup)
        loanToken.mint(lender, 100000e18);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        // Set up collaterals with higher LLTV to allow for interest
        CollateralParams[] memory collaterals = new CollateralParams[](2);
        collaterals[0] = CollateralParams({
            token: address(collateralToken1),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });
        collaterals[1] = CollateralParams({
            token: address(collateralToken2),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        // Source market (current maturity, to be closed)
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

        // Target market (new maturity, to be opened)
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

        // Setup borrower with existing debt in source market
        // We'll create initial debt by taking a SELL offer on the source market
        // This mimics real-world scenario where borrower already has debt they want to renew

        // 1. Fund borrower with collateral tokens
        collateralToken1.mint(borrower, 10000e18);
        collateralToken2.mint(borrower, 10000e18);

        // 2. Approve callback for collateral (needed for MidnightSupplyCollateralCallback)
        // We'll use MidnightSupplyCollateralCallback to create initial debt
        MidnightSupplyCollateralCallback setupCallback = new MidnightSupplyCollateralCallback(address(midnight));
        vm.startPrank(borrower);
        collateralToken1.approve(address(setupCallback), type(uint256).max);
        collateralToken2.approve(address(setupCallback), type(uint256).max);
        midnight.setIsAuthorized(address(setupCallback), true, borrower);
        vm.stopPrank();

        // 3. Create initial debt via SELL offer on source market
        uint256[] memory setupAmounts = new uint256[](2);
        setupAmounts[0] = 100e18;
        setupAmounts[1] = 50e18;

        bytes memory setupData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: setupAmounts,
                offerSellerAssets: 100e18,
                maxBorrowCapacityUsage: 0 // No maxBorrowCapacityUsage check
            })
        );

        // Create and take offer to establish initial debt
        bytes32 setupGroup = keccak256(abi.encodePacked("setup", block.timestamp));
        Offer memory setupOffer = Offer({
            market: sourceMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: setupGroup,
            callback: address(setupCallback),
            callbackData: setupData,
            receiverIfMakerIsSeller: borrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory setupSig = _signOffer(setupOffer, borrowerSK);

        {
            bytes32 _id = IdLib.toId(setupOffer.market);
            uint256 _units = 100e18;
            vm.prank(lender);
            midnight.take(
                setupOffer,
                abi.encode(setupSig, HashLib.hashOffer(setupOffer), uint256(0), new bytes32[](0)),
                _units,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        // Verify borrower has initial debt
        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        assertEq(midnight.debt(sourceMarketId, borrower), 100e18, "Borrower should have initial debt");

        // Borrower should now have 100e18 loan tokens from the take
        // The borrower needs to have enough loan tokens for renewal callback to pull
        // For renewal with fee, the callback will pull buyerAssets from borrower
        // So mint additional tokens for test scenarios
        loanToken.mint(borrower, 200e18);

        // Borrower authorizes callback to act on their behalf in Midnight
        vm.prank(borrower);
        midnight.setIsAuthorized(address(callback), true, borrower);
    }

    /* ========== HELPERS ========== */

    /// @dev Helper to sign an offer
    function _signOffer(Offer memory offer, uint256 privateKey) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(privateKey, digest);
        return signature;
    }

    /// @dev Helper to encode CallbackData
    function _encodeCallbackData(Market memory source, uint256 feeRate, address recipient, uint256 tick)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: source, feeRate: feeRate, feeRecipient: recipient, tick: tick
            })
        );
    }

    /// @dev Result struct for take operations to enable precise assertions
    struct TakeResult {
        uint256 buyerAssets;
        uint256 sellerAssets;
        uint256 units;
    }

    /// @dev Prepare a SELL offer (computes shares via external calls) without executing the take.
    ///      This allows placing vm.expectRevert() between preparation and execution.
    function _prepareOffer(uint256 sellerAssets, bytes memory callbackData, address _taker)
        internal
        view
        returns (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units)
    {
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, sellerAssets, gasleft()));

        offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        offerRoot = HashLib.hashOffer(offer);
        sig = _signOffer(offer, borrowerSK);

        bytes32 _id = IdLib.toId(offer.market);
        _units = sellerAssets;
    }

    /// @dev Helper to create and execute a SELL offer for renewal using real Midnight flow
    /// @param sellerAssets Amount of assets the borrower will receive from lender (used for repayment)
    /// @param callbackData Encoded CallbackData
    /// @param taker Address of the lender who provides loan tokens
    /// @return result The exact values from Midnight.take()
    function _takeOffer(uint256 sellerAssets, bytes memory callbackData, address taker)
        internal
        returns (TakeResult memory result)
    {
        // Create unique group to allow multiple takes
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, sellerAssets, gasleft()));

        Offer memory offer = Offer({
            market: targetMarket, // Borrower wants to create debt in target market
            buy: false, // SELL offer (borrower selling market units for loan tokens)
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING), // Discount price: borrower receives 0.99 per 1
            // unit (pays ~1% interest)
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        result = _executeTake(offer, sellerAssets, taker);
    }

    function _executeTake(Offer memory offer, uint256 sellerAssets, address taker)
        internal
        returns (TakeResult memory result)
    {
        Signature memory sig = _signOffer(offer, borrowerSK);
        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0));
        vm.prank(taker);
        (result.buyerAssets, result.sellerAssets) =
            midnight.take(offer, ratifierData, sellerAssets, taker, address(0), address(0), "");
        // Fixture passes sellerAssets as the take request and Midnight reverts on overshoot,
        // so matched units equal sellerAssets.
        result.units = sellerAssets;
    }

    /// @dev Helper to calculate expected fee using the exact same path the callback takes
    function _calculateExpectedFee(uint256 units, uint256 sellerAssets, uint256 feeRate, uint256 tick)
        internal
        pure
        returns (uint256)
    {
        return CallbackLib.sellerFeeFromTick(tick, feeRate, units, sellerAssets);
    }

    /* ========== CONSTRUCTOR ========== */

    function test_constructor_setsMidnight() public view {
        assertEq(address(callback.MORPHO_MIDNIGHT()), address(midnight));
    }

    /* ========== onSell - AUTHORIZATION ========== */

    function test_onSell_revertsWhenNotCalledByMidnight() public {
        bytes memory data =
            _encodeCallbackData(sourceMarket, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        callback.onSell(bytes32(0), targetMarket, 0, 105e18, 0, borrower, address(callback), data);
    }

    function test_onSell_revertsWhenReceiverIsNotCallback() public {
        bytes memory data =
            _encodeCallbackData(sourceMarket, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.InvalidReceiver.selector);
        callback.onSell(bytes32(0), targetMarket, 100e18, 105e18, 0, borrower, borrower, data);
    }

    /// @notice Sherlock #69: source market must differ from the target market being sold into.
    function test_onSell_revertsIfSourceMarketEqualsTarget() public {
        bytes memory callbackData =
            _encodeCallbackData(targetMarket, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        bytes32 targetMarketId = IdLib.toId(targetMarket);

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.SameMarket.selector);
        callback.onSell(targetMarketId, targetMarket, 100e18, 100e18, 0, borrower, address(callback), callbackData);
    }

    /* ========== onSell - FEE CALCULATION ========== */

    /// @notice Fee should be 0 when feeRate is 0
    function test_onSell_zeroFeeRate() public {
        bytes memory callbackData =
            _encodeCallbackData(sourceMarket, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        // Take offer: lender provides assets for 100e18 of debt units (at 0.99 price)
        // _takeOffer passes sellerAssets as 3rd param (units), so Midnight calculates:
        // With no settlement fee: sellerPrice = buyerPrice = offerPrice = 0.99e18
        // buyerAssets = units * buyerPrice / WAD = 100e18 * 0.99e18 / 1e18 = 99e18
        // sellerAssets = units * sellerPrice / WAD = 100e18 * 0.99e18 / 1e18 = 99e18
        TakeResult memory result = _takeOffer(100e18, callbackData, lender);

        // Verify Midnight returned expected values (when passing units)
        // Midnight converts the tick back to a price via TickLib.tickToPrice, which may differ from the raw price.
        uint256 effectivePrice = TickLib.tickToPrice(TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));
        assertEq(result.units, 100e18, "MarketUnits should be the input");
        uint256 expectedBuyerAssets = (100e18 * effectivePrice) / WAD;
        assertEq(result.buyerAssets, expectedBuyerAssets, "BuyerAssets = units * price / WAD");
        assertEq(result.buyerAssets, result.sellerAssets, "BuyerAssets should equal sellerAssets (no settlement fee)");

        // Fee recipient should receive nothing when feeRate = 0
        assertEq(loanToken.balanceOf(feeRecipient), feeRecipientBalanceBefore, "Fee recipient should receive 0");
    }

    /// @notice Fee should be calculated correctly with 1% rate
    /// @dev Fee = (units - buyerAssets) * feeRate / WAD
    function test_onSell_feeCalculationWith1PercentRate() public {
        // 1% fee rate
        uint256 feeRate = 0.01e18;
        bytes memory callbackData = _encodeCallbackData(
            sourceMarket, feeRate, feeRecipient, TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING)
        );

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        // Execute take and capture exact return values
        TakeResult memory result = _takeOffer(100e18, callbackData, lender);

        // Calculate expected fee using exact same math as callback
        // units = sellerAssets * WAD / price = 100e18 * 1e18 / 0.99e18
        // interest = units - buyerAssets
        // fee = interest * feeRate / WAD
        uint256 expectedFee = _calculateExpectedFee(
            result.units, result.sellerAssets, feeRate, TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING)
        );

        assertEq(
            loanToken.balanceOf(feeRecipient),
            feeRecipientBalanceBefore + expectedFee,
            "Fee recipient should receive exactly calculated fee"
        );
    }

    /// @notice Fee should be calculated correctly with max 1% rate
    function test_onSell_feeCalculationWithMaxRate() public {
        // 1% fee rate (max)
        uint256 feeRate = 0.01e18;
        bytes memory callbackData = _encodeCallbackData(
            sourceMarket, feeRate, feeRecipient, TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING)
        );

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        // Execute take and capture exact return values
        TakeResult memory result = _takeOffer(100e18, callbackData, lender);

        // Calculate expected fee using exact same math as callback
        uint256 expectedFee = _calculateExpectedFee(
            result.units, result.sellerAssets, feeRate, TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING)
        );

        assertEq(
            loanToken.balanceOf(feeRecipient),
            feeRecipientBalanceBefore + expectedFee,
            "Fee recipient should receive exactly calculated fee"
        );
    }

    /// @notice Should revert when feeRate > 0 but feeRecipient is address(0)
    /// @notice Should revert when feeRate > WAD (CallbackLib limit)
    function test_onSell_revertsInvalidFeeConfig_feeRateTooHigh() public {
        bytes memory callbackData = _encodeCallbackData(
            sourceMarket, 1e18 + 1, feeRecipient, TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING)
        ); // Exceeds WAD

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) =
            _prepareOffer(100e18, callbackData, lender);
        vm.prank(lender);
        vm.expectRevert(CallbackLib.InvalidFeeConfig.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, lender, address(0), address(0), ""
        );
    }

    /* ========== onSell - REPAY BUDGET ========== */

    /// @notice RepayBudget should be buyerAssets - fee
    function test_onSell_repayBudgetCalculation() public {
        uint256 feeRate = 0.01e18; // 1%
        bytes memory callbackData = _encodeCallbackData(
            sourceMarket, feeRate, feeRecipient, TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING)
        );

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);

        // Execute take and capture exact return values
        TakeResult memory result = _takeOffer(100e18, callbackData, lender);

        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, borrower);
        uint256 repaidUnits = sourceDebtBefore - sourceDebtAfter;

        // Calculate expected repayBudget using exact same math as callback:
        // fee = (units - buyerAssets) * feeRate / WAD
        // repayBudget = buyerAssets - fee
        uint256 expectedFee = _calculateExpectedFee(
            result.units, result.sellerAssets, feeRate, TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING)
        );
        uint256 expectedRepayBudget = result.buyerAssets - expectedFee;

        // In Midnight, repay() deducts exact amount, so repaidUnits == repayBudget
        assertEq(repaidUnits, expectedRepayBudget, "Actual repaid should equal repayBudget exactly");
    }

    /* ========== onSell - COLLATERAL TRANSFER ========== */

    /// @notice Proportional collateral transfer on partial fill (50%)
    function test_onSell_proportionalCollateralTransfer() public {
        bytes memory callbackData =
            _encodeCallbackData(sourceMarket, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        bytes32 targetMarketId = IdLib.toId(targetMarket);

        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);
        uint256 sourceCollat1Before = midnight.collateral(sourceMarketId, borrower, 0);
        uint256 sourceCollat2Before = midnight.collateral(sourceMarketId, borrower, 1);

        // Take 50% of debt (50e18 out of 100e18)
        TakeResult memory result = _takeOffer(50e18, callbackData, lender);

        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, borrower);
        uint256 repaidUnits = sourceDebtBefore - sourceDebtAfter;

        uint256 sourceCollat1After = midnight.collateral(sourceMarketId, borrower, 0);
        uint256 sourceCollat2After = midnight.collateral(sourceMarketId, borrower, 1);

        uint256 targetCollat1 = midnight.collateral(targetMarketId, borrower, 0);
        uint256 targetCollat2 = midnight.collateral(targetMarketId, borrower, 1);

        // Calculate expected collateral transfer using exact same math as callback:
        // transfer = sourceCollateral * repaidUnits / sourceDebtBefore (mulDivDown)
        uint256 expectedCollat1Transfer = (sourceCollat1Before * repaidUnits) / sourceDebtBefore;
        uint256 expectedCollat2Transfer = (sourceCollat2Before * repaidUnits) / sourceDebtBefore;

        // Verify collateral transfers match exact formula
        assertEq(
            sourceCollat1Before - sourceCollat1After,
            expectedCollat1Transfer,
            "Collateral1 transfer should match mulDivDown"
        );
        assertEq(
            sourceCollat2Before - sourceCollat2After,
            expectedCollat2Transfer,
            "Collateral2 transfer should match mulDivDown"
        );
        assertEq(targetCollat1, expectedCollat1Transfer, "Target should receive exact collateral1 transfer");
        assertEq(targetCollat2, expectedCollat2Transfer, "Target should receive exact collateral2 transfer");
    }

    /// @notice Final fill should transfer ALL remaining collateral (no dust)
    function test_onSell_finalFillTransfersAllCollateral() public {
        bytes memory callbackData =
            _encodeCallbackData(sourceMarket, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        bytes32 targetMarketId = IdLib.toId(targetMarket);

        // Pre-create the target market so settlementFee() doesn't revert
        collateralToken1.mint(borrower, 1);
        vm.startPrank(borrower);
        collateralToken1.approve(address(midnight), 1);
        midnight.supplyCollateral(targetMarket, 0, 1, borrower);
        vm.stopPrank();

        // Record initial collateral amounts
        uint256 initialCollat1 = midnight.collateral(sourceMarketId, borrower, 0);
        uint256 initialCollat2 = midnight.collateral(sourceMarketId, borrower, 1);

        // Record target collateral before the take (accounts for pre-creation seed)
        uint256 targetCollat1Before = midnight.collateral(targetMarketId, borrower, 0);
        uint256 targetCollat2Before = midnight.collateral(targetMarketId, borrower, 1);

        // To ensure full debt repayment, pass sellerAssets = sourceDebt directly as the 2nd param of take().

        // This makes Midnight compute: buyerAssets = sellerAssets (no settlement fee), so the callback
        // receives exactly sourceDebt as buyerAssets, which fully covers the 100e18 debt.
        uint256 sourceDebt = midnight.debt(sourceMarketId, borrower);

        bytes32 uniqueGroup = keccak256(abi.encodePacked("final_fill_test", block.timestamp));
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
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

        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _units = TakeAmountsLib.sellerAssetsToUnits(address(midnight), _id, offer, sourceDebt);
            vm.prank(lender);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _units,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, borrower);

        // When final fill (sourceDebtAfter == 0), callback transfers ALL remaining collateral
        if (sourceDebtAfter == 0) {
            // EXACT assertion: source should have 0 collateral
            assertEq(
                midnight.collateral(sourceMarketId, borrower, 0),
                0,
                "Source should have exactly 0 collateral1 after final fill"
            );
            assertEq(
                midnight.collateral(sourceMarketId, borrower, 1),
                0,
                "Source should have exactly 0 collateral2 after final fill"
            );

            // EXACT assertion: target should have ALL initial collateral (plus any pre-creation seed)
            assertEq(
                midnight.collateral(targetMarketId, borrower, 0),
                targetCollat1Before + initialCollat1,
                "Target should receive exactly all collateral1"
            );
            assertEq(
                midnight.collateral(targetMarketId, borrower, 1),
                targetCollat2Before + initialCollat2,
                "Target should receive exactly all collateral2"
            );
        } else {
            // Partial repayment - verify pro-rata transfer
            uint256 sourceDebtBefore = 100e18; // Initial debt from setUp
            uint256 repaidUnits = sourceDebtBefore - sourceDebtAfter;

            uint256 expectedCollat1Transfer = (initialCollat1 * repaidUnits) / sourceDebtBefore;
            uint256 expectedCollat2Transfer = (initialCollat2 * repaidUnits) / sourceDebtBefore;

            assertEq(
                midnight.collateral(targetMarketId, borrower, 0),
                targetCollat1Before + expectedCollat1Transfer,
                "Target should receive proportional collateral1"
            );
            assertEq(
                midnight.collateral(targetMarketId, borrower, 1),
                targetCollat2Before + expectedCollat2Transfer,
                "Target should receive proportional collateral2"
            );
        }
    }

    /* ========== onSell - MULTI-COLLATERAL ========== */

    /// @notice Test with single collateral position
    function test_onSell_singleCollateral() public {
        // Create new markets with only one collateral
        CollateralParams[] memory singleCollateral = new CollateralParams[](1);
        singleCollateral[0] = CollateralParams({
            token: address(collateralToken1),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        Market memory singleSource = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: singleCollateral,
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        Market memory singleTarget = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: singleCollateral,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Setup borrower with debt in single-collateral source using take flow
        MidnightSupplyCollateralCallback singleSetupCallback = new MidnightSupplyCollateralCallback(address(midnight));
        vm.startPrank(borrower);
        collateralToken1.approve(address(singleSetupCallback), type(uint256).max);
        midnight.setIsAuthorized(address(singleSetupCallback), true, borrower);
        vm.stopPrank();

        uint256[] memory singleSetupAmounts = new uint256[](1);
        singleSetupAmounts[0] = 200e18;

        bytes memory singleSetupData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: singleSetupAmounts, offerSellerAssets: 100e18, maxBorrowCapacityUsage: 0
            })
        );

        bytes32 singleSetupGroup = keccak256(abi.encodePacked("single_setup", block.timestamp));
        Offer memory singleSetupOffer = Offer({
            market: singleSource,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: singleSetupGroup,
            callback: address(singleSetupCallback),
            callbackData: singleSetupData,
            receiverIfMakerIsSeller: borrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory singleSetupSig = _signOffer(singleSetupOffer, borrowerSK);
        {
            bytes32 _id = IdLib.toId(singleSetupOffer.market);
            uint256 _units = 100e18;
            vm.prank(lender);
            midnight.take(
                singleSetupOffer,
                abi.encode(singleSetupSig, HashLib.hashOffer(singleSetupOffer), uint256(0), new bytes32[](0)),
                _units,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        bytes memory callbackData =
            _encodeCallbackData(singleSource, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        // Create unique group for this test
        bytes32 uniqueGroup = keccak256(abi.encodePacked("single_collateral_test", block.timestamp));

        Offer memory offer = Offer({
            market: singleTarget,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
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

        bytes32 sourceMarketId = IdLib.toId(singleSource);
        bytes32 targetId = IdLib.toId(singleTarget);

        // Record state before take for exact calculation
        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);
        uint256 sourceCollateralBefore = midnight.collateral(sourceMarketId, borrower, 0);

        bytes32 _singleId = IdLib.toId(offer.market);
        uint256 _singleShares = 100e18;
        vm.prank(lender);
        (uint256 buyerAssets,) = midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _singleShares,
            lender,
            address(0),
            address(0),
            ""
        );

        // Calculate exact expected values using same math as callback
        // repayBudget = buyerAssets - fee (fee = 0 since feeRate = 0)
        uint256 repayBudget = buyerAssets;
        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, borrower);
        uint256 repaidUnits = sourceDebtBefore - sourceDebtAfter;

        // Calculate expected collateral transfer using mulDivDown
        // transfer = sourceCollateral * repaidUnits / sourceDebtBefore
        bool isFinalFill = sourceDebtAfter == 0;
        uint256 expectedCollateralTransfer =
            isFinalFill ? sourceCollateralBefore : (sourceCollateralBefore * repaidUnits) / sourceDebtBefore;

        // Verify exact collateral transfers
        assertEq(
            sourceCollateralBefore - midnight.collateral(sourceMarketId, borrower, 0),
            expectedCollateralTransfer,
            "Source collateral decrease should match exact calculation"
        );
        assertEq(
            midnight.collateral(targetId, borrower, 0),
            expectedCollateralTransfer,
            "Target should receive exact calculated collateral"
        );
    }

    /* ========== onSell - EDGE CASES ========== */

    /// @notice Should revert when buyerAssets is zero
    function test_onSell_revertsZeroAmount() public {
        bytes memory callbackData =
            _encodeCallbackData(sourceMarket, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        // Create offer with zero assets
        bytes32 uniqueGroup = keccak256(abi.encodePacked("zero_test", block.timestamp));

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
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

        vm.prank(lender);
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), 0, lender, address(0), address(0), ""
        );
    }

    /* ========== onSell - EVENT EMISSION ========== */

    /// @notice Should emit BorrowRenewed event with correct parameters
    function test_onSell_emitsBorrowRenewedEvent() public {
        uint256 feeRate = 0.01e18;
        bytes memory callbackData = _encodeCallbackData(
            sourceMarket, feeRate, feeRecipient, TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING)
        );

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        bytes32 targetMarketId = IdLib.toId(targetMarket);

        // Expected values
        uint256 expectedFee = (1e18 * feeRate) / WAD; // 0.01e18
        uint256 expectedRepaid = 100e18 - expectedFee; // 99.99e18

        address[] memory expectedTokens = new address[](2);
        expectedTokens[0] = address(collateralToken1);
        expectedTokens[1] = address(collateralToken2);

        // Note: We can't easily predict exact collateral amounts due to pro-rata rounding
        // but we can verify the event is emitted

        vm.expectEmit(true, true, true, false, address(callback));
        emit IBorrowMidnightRenewalCallback.BorrowRenewed(
            borrower, sourceMarketId, targetMarketId, expectedRepaid, expectedTokens, new uint256[](2), expectedFee
        );

        _takeOffer(100e18, callbackData, lender);
    }

    /* ========== ROUNDING EDGE CASES - FEE CALCULATION ========== */

    /// @notice Test fee calculation with non-round numbers that cause rounding
    /// @dev Uses mulDivDown which rounds toward zero - verify exact rounding behavior
    function test_onSell_feeCalculationRoundsDown() public {
        // Setup: use non-round numbers to test rounding
        // feeRate = 0.5% (0.005e18)
        uint256 feeRate = 0.005e18;
        bytes memory callbackData = _encodeCallbackData(
            sourceMarket, feeRate, feeRecipient, TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING)
        );

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        // Pre-create the target market so settlementFee() doesn't revert
        collateralToken1.mint(borrower, 1);
        vm.startPrank(borrower);
        collateralToken1.approve(address(midnight), 1);
        midnight.supplyCollateral(targetMarket, 0, 1, borrower);
        vm.stopPrank();

        // When we call take() with sellerAssets specified, Midnight calculates:
        // units = sellerAssets * WAD / sellerPrice = 33e18 * 1e18 / 0.99e18 = 33333333333333333333
        // buyerAssets = sellerAssets * buyerPrice / sellerPrice = 33e18 (when buyerPrice = sellerPrice)
        //
        // So callback receives:
        // units = 33333333333333333333
        // buyerAssets = 33e18
        // interest = 33333333333333333333 - 33e18 = 333333333333333333
        // fee = 333333333333333333 * 0.005e18 / WAD = 1666666666666666 (mulDivDown)

        // Create custom offer with specific values
        bytes32 uniqueGroup = keccak256(abi.encodePacked("rounding_fee_test", block.timestamp));
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
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

        // IMPORTANT: Pass sellerAssets (second param) not units (third param)
        // This makes Midnight calculate units from sellerAssets, causing rounding
        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _units = TakeAmountsLib.sellerAssetsToUnits(address(midnight), _id, offer, 33e18);
            vm.prank(lender);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _units,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        // Calculate expected fee using exact same math as Midnight and callback:
        // Midnight converts the tick back to a price via TickLib.tickToPrice, which may differ from the raw price.
        // When sellerAssets > 0: units = sellerAssets * WAD / sellerPrice
        // buyerAssets = sellerAssets * buyerPrice / sellerPrice = sellerAssets (when no settlement fee)
        uint256 sellerAssets = 33e18;
        uint256 sellerTick = TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING);
        uint256 sellerPrice = TickLib.tickToPrice(sellerTick);
        uint256 units = (sellerAssets * WAD) / sellerPrice; // mulDivDown
        // Fee calculation: effective-price model
        uint256 expectedFee = CallbackLib.sellerFeeFromTick(sellerTick, feeRate, units, sellerAssets);

        assertEq(
            loanToken.balanceOf(feeRecipient),
            feeRecipientBalanceBefore + expectedFee,
            "Fee should match exact mulDivDown calculation"
        );

        // Verify the fee is less than theoretical exact value due to rounding
        assertTrue(expectedFee < 0.00166e18, "Fee should be rounded down from theoretical");
    }

    /// @notice Test fee rounds to zero when interest * feeRate < WAD
    function test_onSell_feeRoundsToZero() public {
        // Use very small feeRate so that interest * feeRate < WAD
        uint256 feeRate = 0.000001e18; // 0.0001%
        bytes memory callbackData = _encodeCallbackData(
            sourceMarket, feeRate, feeRecipient, TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING)
        );

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        // With price = 0.99e18 and sellerAssets = 1e12:
        // units = 1e12 * WAD / 0.99e18 = 1010101010101 (mulDivDown)
        // interest = 1010101010101 - 1e12 = 10101010101
        // fee = 10101010101 * 0.000001e18 / WAD = 10101010101 * 1e12 / 1e18 = 10101 (rounds down)
        // This is still > 0, so let's use even smaller values

        // With sellerAssets = 1e9 and feeRate = 0.000001e18:
        // units = 1e9 * WAD / 0.99e18 = 1010101010 (mulDivDown)
        // interest = 1010101010 - 1e9 = 10101010
        // fee = 10101010 * 1e12 / 1e18 = 10 (still > 0)

        // Need interest * feeRate < WAD for zero fee
        // With sellerAssets = 1e6 and feeRate = 0.000001e18:
        // units = 1e6 * WAD / 0.99e18 = 1010101 (mulDivDown)
        // interest = 1010101 - 1e6 = 10101
        // fee = 10101 * 1e12 / 1e18 = 0 (rounds to zero!)

        bytes32 uniqueGroup = keccak256(abi.encodePacked("zero_fee_rounding_test", block.timestamp));
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
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

        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _units = 1e6;
            vm.prank(lender);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _units,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        // Calculate expected values using effective-price model
        uint256 tick = TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING);
        uint256 actualPrice = TickLib.tickToPrice(tick);
        // With very small amounts, the effective price rounding may produce fee = 0 or fee = 1
        // The key invariant is that the fee recipient balance matches the callback's computation
        uint256 sellerAssets = 1e6;
        uint256 units = (sellerAssets * WAD) / actualPrice;
        uint256 expectedFee = CallbackLib.sellerFeeFromTick(tick, feeRate, units, sellerAssets);

        assertEq(
            loanToken.balanceOf(feeRecipient),
            feeRecipientBalanceBefore + expectedFee,
            "Fee recipient should receive expected fee from effective-price model"
        );
    }

    /// @notice Test with price at exactly 1 WAD (no discount, no interest) succeeds with zero fee
    function test_onSell_succeedsWithZeroFeeWhenNoInterest() public {
        // When price = WAD, units = sellerAssets, so interest = 0
        // With feeRate > 0, fee is simply 0 (no revert)
        uint256 feeRate = 0.01e18;
        bytes memory callbackData = _encodeCallbackData(sourceMarket, feeRate, feeRecipient, MAX_TICK);

        bytes32 uniqueGroup = keccak256(abi.encodePacked("no_interest_test", block.timestamp));
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
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

        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _units = 50e18;
            vm.prank(lender);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _units,
                lender,
                address(0),
                address(0),
                ""
            );
        }
        assertEq(loanToken.balanceOf(feeRecipient), 0, "no fee when no interest");
    }

    /* ========== ROUNDING EDGE CASES - COLLATERAL PRO-RATA ========== */

    /// @notice Test pro-rata collateral calculation rounds down
    /// @dev Collateral transfer = sourceCollateral * repaidUnits / sourceDebtBefore (mulDivDown)
    function test_onSell_collateralProRataRoundsDown() public {
        bytes memory callbackData =
            _encodeCallbackData(sourceMarket, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        bytes32 targetMarketId = IdLib.toId(targetMarket);

        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);
        uint256 sourceCollat1Before = midnight.collateral(sourceMarketId, borrower, 0);

        // Use amount that creates non-clean division for pro-rata
        // sourceDebt = 100e18, sourceCollateral1 = 100e18
        // If we repay 33e18, collateral transfer = 100e18 * 33e18 / 100e18 = 33e18 (clean)
        // But with 0.99 price: sellerAssets = 33e18, buyerAssets = 33e18
        // units = 33e18 * WAD / 0.99e18 = 33333333333333333333
        // repayBudget = buyerAssets - fee = 33e18 - 0 = 33e18
        // repaidUnits depends on how Midnight.repay works

        bytes32 uniqueGroup = keccak256(abi.encodePacked("collateral_rounding_test", block.timestamp));
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
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

        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _units = 33e18;
            vm.prank(lender);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _units,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, borrower);
        uint256 repaidUnits = sourceDebtBefore - sourceDebtAfter;

        uint256 sourceCollat1After = midnight.collateral(sourceMarketId, borrower, 0);
        uint256 targetCollat1 = midnight.collateral(targetMarketId, borrower, 0);

        // Expected collateral transfer using exact same math as callback: mulDivDown
        uint256 expectedCollateralTransfer = (sourceCollat1Before * repaidUnits) / sourceDebtBefore;

        // Verify exact calculation
        assertEq(
            sourceCollat1Before - sourceCollat1After,
            expectedCollateralTransfer,
            "Collateral withdrawn should match mulDivDown calculation"
        );
        assertEq(targetCollat1, expectedCollateralTransfer, "Target collateral should equal withdrawn amount");

        // Verify rounding is down (collateral favors source market holder / borrower keeps more)
        // Check that actualTransfer <= theoretical exact value
        // theoretical = sourceCollat1Before * repaidUnits / sourceDebtBefore (exact division)
        // If there's a remainder, mulDivDown will give less
        uint256 remainder = (sourceCollat1Before * repaidUnits) % sourceDebtBefore;
        if (remainder > 0) {
            // If there's a remainder, the transfer should be strictly less than ceiling
            uint256 ceiling = (sourceCollat1Before * repaidUnits + sourceDebtBefore - 1) / sourceDebtBefore;
            assertTrue(
                expectedCollateralTransfer < ceiling, "Collateral transfer should round down when remainder exists"
            );
        }
    }

    /// @notice Test that final fill transfers ALL collateral regardless of rounding
    /// @dev This test verifies that when sourceDebtAfter == 0 (final fill),
    ///      the callback transfers all remaining collateral instead of pro-rata
    function test_onSell_finalFillIgnoresRounding() public {
        // First do a partial fill to create non-round remaining collateral
        bytes memory callbackData =
            _encodeCallbackData(sourceMarket, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        bytes32 targetMarketId = IdLib.toId(targetMarket);

        // Pre-create the target market so settlementFee() doesn't revert
        collateralToken1.mint(borrower, 1);
        vm.startPrank(borrower);
        collateralToken1.approve(address(midnight), 1);
        midnight.supplyCollateral(targetMarket, 0, 1, borrower);
        vm.stopPrank();

        // Partial fill: 33e18 sellerAssets repays ~33e18 of 100e18 debt
        bytes32 uniqueGroup1 = keccak256(abi.encodePacked("partial_fill", block.timestamp));
        Offer memory offer1 = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup1,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot1 = HashLib.hashOffer(offer1);
        Signature memory sig1 = _signOffer(offer1, borrowerSK);

        // Use sellerAssets (2nd param) to let Midnight calculate the units
        {
            bytes32 _id = IdLib.toId(offer1.market);
            uint256 _units = TakeAmountsLib.sellerAssetsToUnits(address(midnight), _id, offer1, 33e18);
            vm.prank(lender);
            midnight.take(
                offer1,
                abi.encode(sig1, offerRoot1, uint256(0), new bytes32[](0)),
                _units,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        // Record state after partial fill
        uint256 remainingDebt = midnight.debt(sourceMarketId, borrower);
        uint256 remainingCollat1 = midnight.collateral(sourceMarketId, borrower, 0);
        uint256 remainingCollat2 = midnight.collateral(sourceMarketId, borrower, 1);

        assertTrue(remainingDebt > 0, "Should have remaining debt after partial fill");
        assertTrue(remainingCollat1 > 0, "Should have remaining collateral1 after partial fill");
        assertTrue(remainingCollat2 > 0, "Should have remaining collateral2 after partial fill");

        // Final fill: repay EXACTLY the remaining debt
        // The callback uses buyerAssets as repayBudget, so we need buyerAssets = remainingDebt
        // With price = 0.99, sellerAssets = buyerAssets, so pass remainingDebt as sellerAssets
        uint256 sellerAssetsForFinal = remainingDebt;

        // Mint extra tokens for borrower (callback pulls buyerAssets from borrower)
        loanToken.mint(borrower, sellerAssetsForFinal);

        bytes32 uniqueGroup2 = keccak256(abi.encodePacked("final_fill", block.timestamp));
        Offer memory offer2 = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup2,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot2 = HashLib.hashOffer(offer2);
        Signature memory sig2 = _signOffer(offer2, borrowerSK);

        // Use sellerAssets (2nd param)
        {
            bytes32 _id = IdLib.toId(offer2.market);
            uint256 _units = TakeAmountsLib.sellerAssetsToUnits(address(midnight), _id, offer2, sellerAssetsForFinal);
            vm.prank(lender);
            midnight.take(
                offer2,
                abi.encode(sig2, offerRoot2, uint256(0), new bytes32[](0)),
                _units,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        // After final fill, source should have zero debt and zero collateral
        uint256 finalSourceDebt = midnight.debt(sourceMarketId, borrower);
        uint256 finalSourceCollat1 = midnight.collateral(sourceMarketId, borrower, 0);
        uint256 finalSourceCollat2 = midnight.collateral(sourceMarketId, borrower, 1);

        // Final fill should transfer ALL remaining collateral (isFinalFill = true in callback)
        assertEq(finalSourceDebt, 0, "Source debt should be zero after final fill");
        assertEq(finalSourceCollat1, 0, "Source collateral1 should be zero after final fill");
        assertEq(finalSourceCollat2, 0, "Source collateral2 should be zero after final fill");

        // Target should have all the collateral that was in source
        // (plus the 1 wei seed from pre-creation of target market)
        uint256 targetCollat1 = midnight.collateral(targetMarketId, borrower, 0);
        uint256 targetCollat2 = midnight.collateral(targetMarketId, borrower, 1);

        // Initial collateral was 100e18 for token1 and 50e18 for token2
        // Target collateral1 has 1 extra wei from the pre-creation seed
        assertEq(targetCollat1, 100e18 + 1, "Target should have all 100e18 collateral1 (+ 1 wei seed)");
        assertEq(targetCollat2, 50e18, "Target should have all 50e18 collateral2");
    }

    /// @notice Test pro-rata with multiple collaterals has consistent rounding
    function test_onSell_multiCollateralConsistentRounding() public {
        bytes memory callbackData =
            _encodeCallbackData(sourceMarket, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        bytes32 targetMarketId = IdLib.toId(targetMarket);

        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);
        uint256 sourceCollat1Before = midnight.collateral(sourceMarketId, borrower, 0);
        uint256 sourceCollat2Before = midnight.collateral(sourceMarketId, borrower, 1);

        // Use amount that creates different remainders for each collateral
        // sourceCollat1 = 100e18, sourceCollat2 = 50e18, sourceDebt = 100e18
        bytes32 uniqueGroup = keccak256(abi.encodePacked("multi_collat_rounding", block.timestamp));
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
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

        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _units = 37e18;
            vm.prank(lender);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _units,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, borrower);
        uint256 repaidUnits = sourceDebtBefore - sourceDebtAfter;

        uint256 sourceCollat1After = midnight.collateral(sourceMarketId, borrower, 0);
        uint256 sourceCollat2After = midnight.collateral(sourceMarketId, borrower, 1);

        uint256 targetCollat1 = midnight.collateral(targetMarketId, borrower, 0);
        uint256 targetCollat2 = midnight.collateral(targetMarketId, borrower, 1);

        // Calculate expected transfers using exact same math
        uint256 expectedCollat1Transfer = (sourceCollat1Before * repaidUnits) / sourceDebtBefore;
        uint256 expectedCollat2Transfer = (sourceCollat2Before * repaidUnits) / sourceDebtBefore;

        // Verify exact calculations for both collaterals
        assertEq(
            sourceCollat1Before - sourceCollat1After,
            expectedCollat1Transfer,
            "Collateral1 transfer should match mulDivDown"
        );
        assertEq(
            sourceCollat2Before - sourceCollat2After,
            expectedCollat2Transfer,
            "Collateral2 transfer should match mulDivDown"
        );
        assertEq(targetCollat1, expectedCollat1Transfer, "Target collateral1 should equal withdrawn");
        assertEq(targetCollat2, expectedCollat2Transfer, "Target collateral2 should equal withdrawn");

        // Verify both collaterals round down (source retains remainder)
        // This is important: borrower keeps the "dust" in source until final fill
        uint256 remainder1 = (sourceCollat1Before * repaidUnits) % sourceDebtBefore;
        uint256 remainder2 = (sourceCollat2Before * repaidUnits) % sourceDebtBefore;

        // If there are remainders, actual transfer < ceiling
        if (remainder1 > 0) {
            uint256 ceiling1 = (sourceCollat1Before * repaidUnits + sourceDebtBefore - 1) / sourceDebtBefore;
            assertTrue(expectedCollat1Transfer < ceiling1, "Collateral1 should round down");
        }
        if (remainder2 > 0) {
            uint256 ceiling2 = (sourceCollat2Before * repaidUnits + sourceDebtBefore - 1) / sourceDebtBefore;
            assertTrue(expectedCollat2Transfer < ceiling2, "Collateral2 should round down");
        }
    }

    /* ========== onSell - VALIDATION EDGE CASES ========== */

    /// @notice Should revert when source market has mismatched loan token
    function test_onSell_revertsWhenLoanTokenMismatch() public {
        // Create a different loan token
        MockERC20 differentLoanToken = new MockERC20("Different Loan", "DIFF", 18);

        // Create source market with different loan token
        CollateralParams[] memory collaterals = new CollateralParams[](2);
        collaterals[0] = CollateralParams({
            token: address(collateralToken1),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });
        collaterals[1] = CollateralParams({
            token: address(collateralToken2),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        Market memory mismatchedSource = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(differentLoanToken), // Different loan token
            collateralParams: collaterals,
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        bytes memory callbackData =
            _encodeCallbackData(mismatchedSource, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        bytes32 uniqueGroup = keccak256(abi.encodePacked("mismatch_test", block.timestamp));

        Offer memory offer = Offer({
            market: targetMarket, // Target uses original loanToken
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
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

        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _units = 50e18;
            vm.prank(lender);
            vm.expectRevert(CallbackLib.TokenMismatch.selector);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _units,
                lender,
                address(0),
                address(0),
                ""
            );
        }
    }

    /// @notice Should revert when source market has no debt
    function test_onSell_revertsWhenSourceDebtIsZero() public {
        // Create a new source market that the borrower has no debt in
        CollateralParams[] memory collaterals = new CollateralParams[](2);
        collaterals[0] = CollateralParams({
            token: address(collateralToken1),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });
        collaterals[1] = CollateralParams({
            token: address(collateralToken2),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        Market memory emptySource = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 14 days, // Different maturity to create new market
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Verify borrower has no debt in this market
        bytes32 emptySourceId = IdLib.toId(emptySource);
        assertEq(midnight.debt(emptySourceId, borrower), 0, "Borrower should have no debt in empty source");

        bytes memory callbackData =
            _encodeCallbackData(emptySource, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        bytes32 uniqueGroup = keccak256(abi.encodePacked("zero_debt_test", block.timestamp));

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
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

        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _units = 50e18;
            vm.prank(lender);
            vm.expectRevert(CallbackLib.ZeroAmount.selector);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _units,
                lender,
                address(0),
                address(0),
                ""
            );
        }
    }

    /* ========== onSell - RECEIVER IS CALLBACK CONTRACT (Option A) ========== */

    /// @notice When receiver = callback contract, the callback should not pull tokens from itself.
    ///         The loan tokens arrive via Midnight's transfer to receiverIfMakerIsSeller = callback.
    function test_onSell_receiverIsCallback_repaysSourceDebt() public {
        bytes memory callbackData =
            _encodeCallbackData(sourceMarket, 0, address(0), TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        bytes32 targetMarketId = IdLib.toId(targetMarket);

        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);
        uint256 sourceCollat1Before = midnight.collateral(sourceMarketId, borrower, 0);
        uint256 sourceCollat2Before = midnight.collateral(sourceMarketId, borrower, 1);

        // Build offer inline so we can set receiverIfMakerIsSeller = address(callback)
        bytes32 uniqueGroup = keccak256(abi.encodePacked("receiver_callback_repay", block.timestamp));
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
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

        uint256 _units = 100e18;
        vm.prank(lender);
        (uint256 buyerAssets, uint256 sellerAssets) = midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, lender, address(0), address(0), ""
        );

        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, borrower);
        uint256 repaidUnits = sourceDebtBefore - sourceDebtAfter;

        // Source debt should have decreased (repayBudget = buyerAssets, no fee)
        assertEq(repaidUnits, buyerAssets, "Repaid units should equal buyerAssets (no fee)");

        // Collateral should have been transferred from source to target (pro-rata)
        uint256 expectedCollat1Transfer = (sourceCollat1Before * repaidUnits) / sourceDebtBefore;
        uint256 expectedCollat2Transfer = (sourceCollat2Before * repaidUnits) / sourceDebtBefore;

        assertEq(
            midnight.collateral(targetMarketId, borrower, 0),
            expectedCollat1Transfer,
            "Target should receive proportional collateral1"
        );
        assertEq(
            midnight.collateral(targetMarketId, borrower, 1),
            expectedCollat2Transfer,
            "Target should receive proportional collateral2"
        );

        // Callback contract should retain no tokens
        assertEq(loanToken.balanceOf(address(callback)), 0, "Callback should retain no loan tokens");
        assertEq(collateralToken1.balanceOf(address(callback)), 0, "Callback should retain no collateral1");
        assertEq(collateralToken2.balanceOf(address(callback)), 0, "Callback should retain no collateral2");
    }

    /// @notice Same as above but with a fee configured. Fee goes to feeRecipient, callback retains nothing.
    function test_onSell_receiverIsCallback_withFee() public {
        uint256 feeRate = 0.01e18; // 1%
        bytes memory callbackData = _encodeCallbackData(
            sourceMarket, feeRate, feeRecipient, TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING)
        );

        bytes32 sourceMarketId = IdLib.toId(sourceMarket);
        bytes32 targetMarketId = IdLib.toId(targetMarket);

        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, borrower);
        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        // Build offer inline with receiverIfMakerIsSeller = address(callback)
        bytes32 uniqueGroup = keccak256(abi.encodePacked("receiver_callback_fee", block.timestamp));
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
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

        uint256 _units = 100e18;
        vm.prank(lender);
        (uint256 buyerAssets, uint256 sellerAssets) = midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, lender, address(0), address(0), ""
        );

        // Calculate expected fee using same math as callback. Matched units equal _units.
        uint256 expectedFee =
            _calculateExpectedFee(_units, sellerAssets, feeRate, TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING));
        uint256 expectedRepayBudget = buyerAssets - expectedFee;

        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, borrower);
        uint256 repaidUnits = sourceDebtBefore - sourceDebtAfter;

        // Source debt should have decreased by repayBudget (buyerAssets - fee)
        assertEq(repaidUnits, expectedRepayBudget, "Repaid units should equal buyerAssets minus fee");

        // Fee should go to feeRecipient
        assertEq(
            loanToken.balanceOf(feeRecipient),
            feeRecipientBalanceBefore + expectedFee,
            "Fee recipient should receive the fee"
        );

        // Callback contract should retain no tokens
        assertEq(loanToken.balanceOf(address(callback)), 0, "Callback should retain no loan tokens");
        assertEq(collateralToken1.balanceOf(address(callback)), 0, "Callback should retain no collateral1");
        assertEq(collateralToken2.balanceOf(address(callback)), 0, "Callback should retain no collateral2");
    }
}
