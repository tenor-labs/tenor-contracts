// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {BorrowMidnightRenewalCallback} from "../../src/callbacks/BorrowMidnightRenewalCallback.sol";
import {LendMidnightRenewalCallback} from "../../src/callbacks/LendMidnightRenewalCallback.sol";
import {MidnightSupplyCollateralCallback} from "../../src/callbacks/MidnightSupplyCollateralCallback.sol";
import {IBorrowMidnightRenewalCallback} from "@callbacks/interfaces/IBorrowMidnightRenewalCallback.sol";
import {ILendMidnightRenewalCallback} from "@callbacks/interfaces/ILendMidnightRenewalCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {IMidnight, Market, Offer, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

/// @notice Integration tests for BorrowMidnightRenewalCallback and LendMidnightRenewalCallback
/// @dev Tests the full renewal flow using real Midnight contracts
contract BorrowMidnightRenewalIntegrationTest is Test {
    BorrowMidnightRenewalCallback internal borrowCallback;
    LendMidnightRenewalCallback internal midnightLendWithdrawable;
    MidnightSupplyCollateralCallback internal supplyCallback;
    IMidnight internal midnight;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    uint256 internal BORROWER_SK;
    address internal BORROWER;
    uint256 internal LENDER_SK;
    address internal LENDER;
    address internal FEE_RECIPIENT;
    EcrecoverRatifier internal ecrecoverRatifier;

    uint256 constant INITIAL_BALANCE = 1_000_000e18;
    uint256 constant BORROW_AMOUNT = 1000e18;
    uint256 constant COLLATERAL_AMOUNT = 5000e18;

    function setUp() public {
        // Create test accounts
        (BORROWER, BORROWER_SK) = makeAddrAndKey("borrower");
        (LENDER, LENDER_SK) = makeAddrAndKey("lender");
        FEE_RECIPIENT = makeAddr("feeRecipient");

        // Deploy tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral Token", "COLL", 18);

        // Deploy oracle
        oracle = new Oracle();
        oracle.setPrice(1e36); // 1:1 price (ORACLE_PRICE_SCALE = 1e36)

        // Deploy Midnight
        midnight = IMidnight(address(new Midnight()));
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(BORROWER);
        Midnight(address(midnight)).setIsAuthorized(address(ecrecoverRatifier), true, BORROWER);
        vm.prank(LENDER);
        Midnight(address(midnight)).setIsAuthorized(address(ecrecoverRatifier), true, LENDER);

        // Deploy callback contracts
        borrowCallback = new BorrowMidnightRenewalCallback(address(midnight));
        midnightLendWithdrawable = new LendMidnightRenewalCallback(address(midnight));
        supplyCallback = new MidnightSupplyCollateralCallback(address(midnight));

        // Mint tokens
        loanToken.mint(BORROWER, INITIAL_BALANCE);
        loanToken.mint(LENDER, INITIAL_BALANCE);
        collateralToken.mint(BORROWER, INITIAL_BALANCE);

        // Approvals
        vm.startPrank(BORROWER);
        loanToken.approve(address(midnight), type(uint256).max);
        collateralToken.approve(address(midnight), type(uint256).max);
        collateralToken.approve(address(supplyCallback), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(LENDER);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Borrower authorizes callbacks to act on their behalf in Midnight
        vm.startPrank(BORROWER);
        Midnight(address(midnight)).setIsAuthorized(address(borrowCallback), true, BORROWER);
        Midnight(address(midnight)).setIsAuthorized(address(midnightLendWithdrawable), true, BORROWER);
        Midnight(address(midnight)).setIsAuthorized(address(supplyCallback), true, BORROWER);
        vm.stopPrank();
    }

    /* ========== HELPERS ========== */

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(sk, digest);
        return signature;
    }

    function _toId(Market memory market) internal view returns (bytes32) {
        return IdLib.toId(market);
    }

    function _createMarket(uint256 maturity) internal view returns (Market memory) {
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.77e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

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

    /* ========== FULL RENEWAL FLOW TEST ========== */

    function test_fullRenewalFlow() public {
        // === Setup ===
        Market memory sourceMarket = _createMarket(block.timestamp + 7 days);
        Market memory targetMarket = _createMarket(block.timestamp + 30 days);
        bytes32 sourceMarketId = _toId(sourceMarket);
        bytes32 targetId = _toId(targetMarket);
        uint256 price = 0.95e18; // 5% discount

        // === Phase 1: Borrower creates initial debt ===

        // Create SELL offer (borrower borrows) - collateral supplied via callback
        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = COLLATERAL_AMOUNT;

        bytes memory supplyData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: BORROW_AMOUNT, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory borrowOffer = Offer({
            market: sourceMarket,
            buy: false,
            maker: BORROWER,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("borrow", block.timestamp)),
            callback: address(supplyCallback),
            callbackData: supplyData,
            receiverIfMakerIsSeller: BORROWER,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory borrowSig = _signOffer(borrowOffer, BORROWER_SK);
        bytes32 borrowRoot = HashLib.hashOffer(borrowOffer);

        bytes32 _borrowId = IdLib.toId(borrowOffer.market);
        vm.prank(LENDER);
        midnight.take(
            borrowOffer,
            abi.encode(borrowSig, borrowRoot, uint256(0), new bytes32[](0)),
            BORROW_AMOUNT,
            LENDER,
            address(0),
            address(0),
            ""
        );

        // Verify initial debt - passing _renewalShares=BORROW_AMOUNT means debt = BORROW_AMOUNT exactly
        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, BORROWER);
        assertEq(sourceDebtBefore, BORROW_AMOUNT, "Borrower should have exactly BORROW_AMOUNT debt");

        // Note: MidnightSupplyCollateralCallback may supply less collateral than requested if offerSellerAssets is set
        // The callback uses: collateralAmount = min(requested, debt * offerSellerAssets / sellerAssets)
        // In this case with price=0.95, sellerAssets=950e18, so it supplies 950e18 * 5 = 4750e18
        uint256 sourceCollateralBefore = midnight.collateral(sourceMarketId, BORROWER, 0);
        assertTrue(sourceCollateralBefore > 0, "Borrower should have collateral");

        // === Phase 2: Renew to target market ===
        uint256 feeRate = 0.01e18; // 1% fee

        bytes memory renewalData = abi.encode(
            IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket,
                feeRate: feeRate,
                feeRecipient: FEE_RECIPIENT,
                tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING)
            })
        );

        Offer memory renewalOffer = Offer({
            market: targetMarket,
            buy: false,
            maker: BORROWER,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("renewal", block.timestamp)),
            callback: address(borrowCallback),
            callbackData: renewalData,
            receiverIfMakerIsSeller: address(borrowCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory renewalSig = _signOffer(renewalOffer, BORROWER_SK);
        bytes32 renewalRoot = HashLib.hashOffer(renewalOffer);

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(FEE_RECIPIENT);

        bytes32 _renewalId = IdLib.toId(renewalOffer.market);
        uint256 _renewalShares = BORROW_AMOUNT;
        vm.prank(LENDER);
        (uint256 buyerAssets,) = midnight.take(
            renewalOffer,
            abi.encode(renewalSig, renewalRoot, uint256(0), new bytes32[](0)),
            _renewalShares,
            LENDER,
            address(0),
            address(0),
            ""
        );

        // === Calculate expected values using exact same math as callback ===
        // Midnight converts the tick back to a price via TickLib.tickToPrice, which may differ from the raw price.
        // We must use the effective tick price for expected value calculations.
        uint256 tick = TickLib.priceToTick(price, DEFAULT_TICK_SPACING);
        uint256 effectivePrice = TickLib.tickToPrice(tick);
        uint256 expectedBuyerAssets = (BORROW_AMOUNT * effectivePrice) / WAD;
        assertEq(buyerAssets, expectedBuyerAssets, "BuyerAssets should match formula");
        assertEq(_renewalShares, BORROW_AMOUNT, "MarketUnits should be input");

        // Fee calculation using effective-price model
        uint256 sellerAssets = buyerAssets; // no settlement fee
        uint256 expectedFee = CallbackLib.sellerFeeFromTick(tick, feeRate, _renewalShares, sellerAssets);
        uint256 expectedRepayBudget = sellerAssets - expectedFee;

        // Expected collateral transfer: sourceCollateral * repaidUnits / sourceDebtBefore
        // repaidUnits = repayBudget (Midnight repays exact amount)
        uint256 sourceDebtAfter = midnight.debt(sourceMarketId, BORROWER);
        uint256 repaidUnits = sourceDebtBefore - sourceDebtAfter;
        assertEq(repaidUnits, expectedRepayBudget, "Actual repaid should equal repayBudget");

        bool isFinalFill = sourceDebtAfter == 0;
        uint256 expectedCollateralTransfer =
            isFinalFill ? sourceCollateralBefore : (sourceCollateralBefore * repaidUnits) / sourceDebtBefore;

        // === Verify renewal effects with exact assertions ===

        // Target debt should be exactly the _renewalShares
        uint256 targetDebt = midnight.debt(targetId, BORROWER);
        assertEq(targetDebt, _renewalShares, "Target debt should equal _renewalShares");

        // Collateral should be transferred exactly as calculated
        uint256 sourceCollateralAfter = midnight.collateral(sourceMarketId, BORROWER, 0);
        uint256 targetCollateral = midnight.collateral(targetId, BORROWER, 0);

        assertEq(
            sourceCollateralBefore - sourceCollateralAfter,
            expectedCollateralTransfer,
            "Source collateral decrease should match"
        );
        assertEq(targetCollateral, expectedCollateralTransfer, "Target collateral should equal transferred amount");

        // Fee should be exactly as calculated
        uint256 feeRecipientBalanceAfter = loanToken.balanceOf(FEE_RECIPIENT);
        assertEq(
            feeRecipientBalanceAfter - feeRecipientBalanceBefore, expectedFee, "Fee should match exact calculation"
        );
    }

    /* ========== PARTIAL RENEWAL TEST ========== */

    function test_partialRenewal() public {
        Market memory sourceMarket = _createMarket(block.timestamp + 7 days);
        Market memory targetMarket = _createMarket(block.timestamp + 30 days);
        bytes32 sourceMarketId = _toId(sourceMarket);
        bytes32 targetId = _toId(targetMarket);
        uint256 price = 0.95e18;

        // Setup initial debt - collateral supplied via callback
        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = COLLATERAL_AMOUNT;

        bytes memory supplyData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: BORROW_AMOUNT, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory borrowOffer = Offer({
            market: sourceMarket,
            buy: false,
            maker: BORROWER,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("borrow", block.timestamp)),
            callback: address(supplyCallback),
            callbackData: supplyData,
            receiverIfMakerIsSeller: BORROWER,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory borrowSig = _signOffer(borrowOffer, BORROWER_SK);
        bytes32 _borrowId = IdLib.toId(borrowOffer.market);
        vm.prank(LENDER);
        midnight.take(
            borrowOffer,
            abi.encode(borrowSig, HashLib.hashOffer(borrowOffer), uint256(0), new bytes32[](0)),
            BORROW_AMOUNT,
            LENDER,
            address(0),
            address(0),
            ""
        );

        uint256 sourceDebtBefore = midnight.debt(sourceMarketId, BORROWER);
        uint256 sourceCollateralBefore = midnight.collateral(sourceMarketId, BORROWER, 0);
        assertEq(sourceDebtBefore, BORROW_AMOUNT, "Initial debt should equal BORROW_AMOUNT");
        // Note: MidnightSupplyCollateralCallback may supply less collateral than requested based on price
        assertTrue(sourceCollateralBefore > 0, "Initial collateral should exist");

        // Create renewal offer (no fee for simplicity)
        bytes memory renewalData = abi.encode(
            IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket,
                feeRate: 0,
                feeRecipient: address(0),
                tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING)
            })
        );

        Offer memory renewalOffer = Offer({
            market: targetMarket,
            buy: false,
            maker: BORROWER,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("renewal", block.timestamp)),
            callback: address(borrowCallback),
            callbackData: renewalData,
            receiverIfMakerIsSeller: address(borrowCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory renewalSig = _signOffer(renewalOffer, BORROWER_SK);
        bytes32 renewalRoot = HashLib.hashOffer(renewalOffer);

        // Track cumulative state
        uint256 cumulativeRepaid = 0;
        uint256 cumulativeCollateralTransferred = 0;

        // First partial fill: 400 _renewalShares
        uint256 partialAmount = 400e18;
        bytes32 _renewalId = IdLib.toId(renewalOffer.market);
        uint256 _shares1 = partialAmount;
        vm.prank(LENDER);
        (uint256 buyerAssets1,) = midnight.take(
            renewalOffer,
            abi.encode(renewalSig, renewalRoot, uint256(0), new bytes32[](0)),
            _shares1,
            LENDER,
            address(0),
            address(0),
            ""
        );

        // Calculate expected repay: buyerAssets = _renewalShares * effectivePrice / WAD (no fee)
        uint256 effectivePrice = TickLib.tickToPrice(TickLib.priceToTick(price, DEFAULT_TICK_SPACING));
        uint256 expectedRepay1 = (partialAmount * effectivePrice) / WAD;
        assertEq(buyerAssets1, expectedRepay1, "First fill buyerAssets should match");

        uint256 sourceDebtAfterFirst = midnight.debt(sourceMarketId, BORROWER);
        uint256 repaidUnits1 = sourceDebtBefore - sourceDebtAfterFirst;
        assertEq(repaidUnits1, expectedRepay1, "First repaid should equal buyerAssets (no fee)");
        cumulativeRepaid += repaidUnits1;

        // Collateral transfer: sourceCollateral * repaidUnits / sourceDebtBefore
        uint256 expectedCollateral1 = (sourceCollateralBefore * repaidUnits1) / sourceDebtBefore;
        uint256 targetCollateral1 = midnight.collateral(targetId, BORROWER, 0);
        assertEq(targetCollateral1, expectedCollateral1, "First target collateral should match");
        cumulativeCollateralTransferred += expectedCollateral1;

        // Second partial fill: 400 more _renewalShares
        uint256 sourceCollateralBeforeSecond = midnight.collateral(sourceMarketId, BORROWER, 0);
        uint256 _shares2 = partialAmount;
        vm.prank(LENDER);
        (uint256 buyerAssets2,) = midnight.take(
            renewalOffer,
            abi.encode(renewalSig, renewalRoot, uint256(0), new bytes32[](0)),
            _shares2,
            LENDER,
            address(0),
            address(0),
            ""
        );

        uint256 expectedRepay2 = (partialAmount * effectivePrice) / WAD;
        assertEq(buyerAssets2, expectedRepay2, "Second fill buyerAssets should match");

        uint256 sourceDebtAfterSecond = midnight.debt(sourceMarketId, BORROWER);
        uint256 repaidUnits2 = sourceDebtAfterFirst - sourceDebtAfterSecond;
        assertEq(repaidUnits2, expectedRepay2, "Second repaid should equal buyerAssets (no fee)");
        cumulativeRepaid += repaidUnits2;

        // Collateral for second fill uses updated debt
        uint256 expectedCollateral2 = (sourceCollateralBeforeSecond * repaidUnits2) / sourceDebtAfterFirst;
        uint256 targetCollateral2 = midnight.collateral(targetId, BORROWER, 0);
        assertEq(targetCollateral2 - targetCollateral1, expectedCollateral2, "Second collateral transfer should match");
        cumulativeCollateralTransferred += expectedCollateral2;

        // Third partial fill: remaining 200 _renewalShares
        uint256 remaining = 200e18;
        uint256 sourceCollateralBeforeThird = midnight.collateral(sourceMarketId, BORROWER, 0);
        uint256 _shares3 = remaining;
        vm.prank(LENDER);
        (uint256 buyerAssets3,) = midnight.take(
            renewalOffer,
            abi.encode(renewalSig, renewalRoot, uint256(0), new bytes32[](0)),
            _shares3,
            LENDER,
            address(0),
            address(0),
            ""
        );

        uint256 expectedRepay3 = (remaining * effectivePrice) / WAD;
        assertEq(buyerAssets3, expectedRepay3, "Third fill buyerAssets should match");

        // Verify cumulative state
        assertEq(
            cumulativeRepaid + expectedRepay3,
            (BORROW_AMOUNT * effectivePrice) / WAD,
            "Total repaid should equal all buyerAssets"
        );
    }

    /* ========== WITHDRAWABLE USAGE TEST ========== */

    /// @notice Sherlock #69: renewing into the same market (here, buying debt back into the market that
    ///         funds the withdrawal) is rejected end-to-end by the callback's SameMarket guard.
    function test_useWithdrawableFlow_revertsSameMarket() public {
        Market memory market = _createMarket(block.timestamp + 30 days);
        bytes32 marketId = _toId(market);
        uint256 price = 0.95e18;
        uint256 feeRate = 0.01e18; // 1%

        // === Phase 1: Create withdrawable balance for borrower ===

        // Borrower creates debt - collateral supplied via callback
        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = COLLATERAL_AMOUNT;

        bytes memory supplyData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: BORROW_AMOUNT, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory borrowOffer = Offer({
            market: market,
            buy: false,
            maker: BORROWER,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("borrow", block.timestamp)),
            callback: address(supplyCallback),
            callbackData: supplyData,
            receiverIfMakerIsSeller: BORROWER,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory borrowSig = _signOffer(borrowOffer, BORROWER_SK);
        bytes32 _borrowId = IdLib.toId(borrowOffer.market);
        vm.prank(LENDER);
        midnight.take(
            borrowOffer,
            abi.encode(borrowSig, HashLib.hashOffer(borrowOffer), uint256(0), new bytes32[](0)),
            BORROW_AMOUNT,
            LENDER,
            address(0),
            address(0),
            ""
        );

        // Borrower repays to create withdrawable
        uint256 debt = midnight.debt(marketId, BORROWER);
        assertEq(debt, BORROW_AMOUNT, "Debt should equal BORROW_AMOUNT");
        vm.prank(BORROWER);
        midnight.repay(market, debt, BORROWER, address(0), "");

        uint256 withdrawableBefore = midnight.withdrawable(marketId);
        assertEq(withdrawableBefore, BORROW_AMOUNT, "Withdrawable should equal repaid amount");

        // === Phase 2: Use withdrawable to buy back debt ===

        bytes memory buyBackData = abi.encode(
            ILendMidnightRenewalCallback.CallbackData({
                sourceMarket: market,
                feeRate: feeRate,
                feeRecipient: FEE_RECIPIENT,
                tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING)
            })
        );

        uint256 buyBackAmount = 380e18;
        Offer memory buyBackOffer = Offer({
            market: market,
            buy: true, // BUY offer
            maker: BORROWER,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("buyback", block.timestamp)),
            callback: address(midnightLendWithdrawable),
            callbackData: buyBackData,
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory buyBackSig = _signOffer(buyBackOffer, BORROWER_SK);

        bytes32 _buyBackId = IdLib.toId(buyBackOffer.market);
        uint256 _buyBackShares =
            TakeAmountsLib.buyerAssetsToUnits(address(midnight), _buyBackId, buyBackOffer, buyBackAmount);

        // Source and target resolve to the same market id, so the take reverts inside the callback.
        vm.prank(LENDER);
        vm.expectRevert(CallbackLib.SameMarket.selector);
        midnight.take(
            buyBackOffer,
            abi.encode(buyBackSig, HashLib.hashOffer(buyBackOffer), uint256(0), new bytes32[](0)),
            _buyBackShares,
            LENDER,
            buyBackOffer.maker,
            address(0),
            ""
        );
    }
}
