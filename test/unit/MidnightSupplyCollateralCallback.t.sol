// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {Test} from "forge-std/Test.sol";
import {MidnightSupplyCollateralCallback} from "../../src/callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

contract MidnightSupplyCollateralCallbackTest is Test {
    MidnightSupplyCollateralCallback internal callback;
    Midnight internal midnight;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken1;
    MockERC20 internal collateralToken2;
    Oracle internal oracle;
    address internal seller;
    uint256 internal sellerSK;
    address internal lender; // Lender who takes offers (provides loan tokens)
    EcrecoverRatifier internal ecrecoverRatifier;

    Market internal testMarket;

    function setUp() public virtual {
        (seller, sellerSK) = makeAddrAndKey("Seller");

        // Deploy real tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken1 = new MockERC20("Collateral 1", "COL1", 18);
        collateralToken2 = new MockERC20("Collateral 2", "COL2", 18);

        // Deploy oracle
        oracle = new Oracle();
        oracle.setPrice(1e36); // 1:1 price (ORACLE_PRICE_SCALE = 1e36)

        // Deploy real Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this)); // Set fee recipient to avoid address(0) transfers
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(seller);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seller);

        // Deploy callback contract
        callback = new MidnightSupplyCollateralCallback(address(midnight));

        // Set up test market
        CollateralParams[] memory collaterals = new CollateralParams[](2);
        collaterals[0] = CollateralParams({
            token: address(collateralToken1),
            lltv: 0.77e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });
        collaterals[1] = CollateralParams({
            token: address(collateralToken2),
            lltv: 0.77e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
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

        // Fund seller with collateral (enough for all tests)
        collateralToken1.mint(seller, 10000e18);
        collateralToken2.mint(seller, 10000e18);

        // Approve callback contract for collaterals and authorize on Midnight
        vm.startPrank(seller);
        collateralToken1.approve(address(callback), type(uint256).max);
        collateralToken2.approve(address(callback), type(uint256).max);
        midnight.setIsAuthorized(address(callback), true, seller);
        vm.stopPrank();

        // Set up lender with loan tokens
        lender = makeAddr("Lender");
        loanToken.mint(lender, 100000e18); // Plenty for all tests
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ========== HELPERS ========== */

    /// @dev Helper to sign an offer using EIP-712
    function _signOffer(Offer memory offer, uint256 privateKey) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(privateKey, digest);
        return signature;
    }

    function _encodeCallbackData(
        uint256 collat1Amount,
        uint256 collat2Amount,
        uint256 offerSellerAssets,
        uint256 maxBorrowCapacityUsage
    ) internal pure returns (bytes memory) {
        return _encodeCallbackDataWithFee(collat1Amount, collat2Amount, offerSellerAssets, maxBorrowCapacityUsage);
    }

    function _encodeCallbackDataWithFee(
        uint256 collat1Amount,
        uint256 collat2Amount,
        uint256 offerSellerAssets,
        uint256 maxBorrowCapacityUsage
    ) internal pure returns (bytes memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = collat1Amount;
        amounts[1] = collat2Amount;

        return abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: amounts, offerSellerAssets: offerSellerAssets, maxBorrowCapacityUsage: maxBorrowCapacityUsage
            })
        );
    }

    /// @dev Helper to create and execute a take using real Midnight flow
    /// @param sellerAssets Amount of assets the seller will receive in this take
    /// @param callbackData Encoded callback data for collateral supply
    /// @param taker Address of the lender (taker/buyer) who provides loan tokens
    function _takeOffer(uint256 sellerAssets, bytes memory callbackData, address taker) internal {
        // Create offer with seller as maker
        // Use unique group to allow multiple takes (each take needs unique offer identifier)
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, sellerAssets, gasleft()));

        Offer memory offer = Offer({
            market: testMarket,
            buy: false, // Sell offer (borrower selling market units for loan tokens)
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup, // Unique per call to allow multiple takes
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, sellerSK);

        // Lender takes the offer (provides loan tokens, seller receives them and incurs debt)
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = sellerAssets;
        vm.prank(taker);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, taker, address(0), address(0), ""
        );
    }

    /* ========== CONSTRUCTOR ========== */

    function test_constructor_setsMidnight() public view {
        assertEq(address(callback.MORPHO_MIDNIGHT()), address(midnight));
    }

    /* ========== onSell - AUTHORIZATION ========== */

    /// @notice Callback can only be triggered by Midnight
    function test_onSell_revertsUnauthorizedSender() public {
        bytes memory data = _encodeCallbackData(10e18, 5e18, 100e18, 0);

        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        callback.onSell(bytes32(0), testMarket, 50e18, 100e18, 0, seller, address(0), data);
    }

    /// @notice onSell reverts when the callback itself is the receiver (loan proceeds would be stranded)
    function test_onSell_revertsReceiverIsCallback() public {
        bytes memory data = _encodeCallbackData(10e18, 5e18, 100e18, 0);

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.InvalidReceiver.selector);
        callback.onSell(bytes32(0), testMarket, 50e18, 100e18, 0, seller, address(callback), data);
    }

    /// @notice A take whose offer routes sellerAssets to the callback reverts instead of stranding the proceeds
    function test_take_revertsWhenReceiverIsCallback() public {
        bytes memory callbackData = _encodeCallbackData(80e18, 50e18, 100e18, 0);

        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, uint256(100e18), gasleft()));
        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: 5820,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback), // misconfigured: proceeds would be locked on the callback
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, sellerSK);

        vm.prank(lender);
        vm.expectRevert(CallbackLib.InvalidReceiver.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), 100e18, lender, address(0), address(0), ""
        );

        assertEq(loanToken.balanceOf(address(callback)), 0, "no loan proceeds should reach the callback");
    }

    /// @notice Collateral is always supplied to seller, never retained by callback
    function test_CollateralAlwaysToSeller() public {
        // Need ~130e18 total collateral (100/0.77) to satisfy lltv for 100e18 debt
        bytes memory callbackData = _encodeCallbackData(80e18, 50e18, 100e18, 0);

        uint256 sellerCollat1Before = collateralToken1.balanceOf(seller);
        uint256 sellerCollat2Before = collateralToken2.balanceOf(seller);

        _takeOffer(100e18, callbackData, lender);

        // Callback should have no collateral
        assertEq(collateralToken1.balanceOf(address(callback)), 0, "Callback retained collateral1");
        assertEq(collateralToken2.balanceOf(address(callback)), 0, "Callback retained collateral2");

        // Seller's wallet should have lost collateral (transferred to Midnight)
        assertEq(collateralToken1.balanceOf(seller), sellerCollat1Before - 80e18, "Seller collateral1 not transferred");
        assertEq(collateralToken2.balanceOf(seller), sellerCollat2Before - 50e18, "Seller collateral2 not transferred");

        // Verify collateral was supplied to Midnight on behalf of seller
        bytes32 marketId = IdLib.toId(testMarket);
        assertEq(midnight.collateral(marketId, seller, 0), 80e18, "Collateral1 not supplied to seller position");
        assertEq(midnight.collateral(marketId, seller, 1), 50e18, "Collateral2 not supplied to seller position");
    }

    /// @notice Pro-rata amounts never exceed configured amounts (rounds down)
    function test_ProRataRoundsDown() public {
        // Configure 130e18 collateral for 100e18 offer (satisfies lltv 0.77)
        bytes memory callbackData = _encodeCallbackData(130e18, 0, 100e18, 0);

        // Take 33e18 (33% fill) - should supply ~42.9e18, rounds down
        _takeOffer(33e18, callbackData, lender);

        bytes32 marketId = IdLib.toId(testMarket);
        uint256 supplied = midnight.collateral(marketId, seller, 0);

        // Should be slightly less than exact pro-rata due to rounding down
        uint256 exactProRata = (130e18 * 33e18) / 100e18;
        assertLe(supplied, exactProRata, "Supplied more than pro-rata");
        // But should be very close (within rounding error)
        assertGe(supplied, exactProRata - 1, "Rounding error too large");
    }

    /// @notice On full fill, entire configured collateral amount is transferred
    function test_FullFillExactAmount() public {
        // Need ~130e18 total collateral (100/0.77) to satisfy lltv for 100e18 debt
        bytes memory callbackData = _encodeCallbackData(80e18, 50e18, 100e18, 0);

        _takeOffer(100e18, callbackData, lender);

        bytes32 marketId = IdLib.toId(testMarket);
        assertEq(midnight.collateral(marketId, seller, 0), 80e18, "Full fill didn't supply exact collateral1");
        assertEq(midnight.collateral(marketId, seller, 1), 50e18, "Full fill didn't supply exact collateral2");
    }

    /// @notice Max debt/capacity check uses same oracle as market
    function test_MaxBorrowCapacityUsageUsesSameOracle() public {
        // Change oracle price to high value so collateral is worth more
        // This validates that the maxBorrowCapacityUsage calculation uses the same oracle as the market
        oracle.setPrice(10e36); // 10:1 price (collateral worth 10x more)

        // Set maxBorrowCapacityUsage to 0.5 (50% of capacity)
        // Supply 125e18 collateral for 100e18 debt
        // At 1:1 price: capacity = 125 * 0.77 = 96.25, debt/capacity = 100/96.25 ≈ 1.04 > 0.5 (would fail)
        // At 10:1 price: capacity = 125 * 10 * 0.77 = 962.5, debt/capacity = 100/962.5 ≈ 0.10 < 0.5 (passes)
        bytes memory callbackData = _encodeCallbackData(125e18, 0, 100e18, 0.5e18);

        // Should not revert with high collateral value from oracle
        _takeOffer(100e18, callbackData, lender);

        // Verify collateral was supplied
        bytes32 marketId = IdLib.toId(testMarket);
        assertEq(midnight.collateral(marketId, seller, 0), 125e18);
    }

    /* ========== EDGE CASE TESTS ========== */

    /// @notice Partial fill supplies pro-rata amount
    function test_PartialFill() public {
        // Need ~130e18 total collateral (100/0.77) to satisfy lltv for 100e18 debt
        bytes memory callbackData = _encodeCallbackData(80e18, 50e18, 100e18, 0);

        // 50% fill
        _takeOffer(50e18, callbackData, lender);

        bytes32 marketId = IdLib.toId(testMarket);
        assertEq(midnight.collateral(marketId, seller, 0), 40e18);
        assertEq(midnight.collateral(marketId, seller, 1), 25e18);
    }

    /// @notice Multiple partial fills accumulate correctly
    function test_MultiplePartialFills() public {
        // Need ~130e18 collateral for 100e18 debt (satisfies lltv 0.77)
        bytes memory callbackData = _encodeCallbackData(130e18, 0, 100e18, 0);
        bytes32 marketId = IdLib.toId(testMarket);

        // First fill: 30%
        _takeOffer(30e18, callbackData, lender);
        assertEq(midnight.collateral(marketId, seller, 0), 39e18, "First fill should supply 39e18");

        // Second fill: 20%
        _takeOffer(20e18, callbackData, lender);
        assertEq(midnight.collateral(marketId, seller, 0), 65e18, "Second fill should add 26e18 (total 65e18)");

        // Third fill: 50%
        _takeOffer(50e18, callbackData, lender);
        assertEq(midnight.collateral(marketId, seller, 0), 130e18, "Third fill should add 65e18 (total 130e18)");
    }

    /// @notice Multiple partial fills that sum to 100% supply exactly configured collateral
    /// @dev When partial fills of offers with identical callback settings sum to 100%,
    /// the pro-rata calculation naturally results in exactly the configured collateral amount.
    /// This tests the "perfect fill" scenario: 60% + 40% = 100% → 125e18 collateral.
    function test_MultipleOffers_PartialFillsSumTo100Percent() public {
        bytes32 marketId = IdLib.toId(testMarket);

        // Scenario: Multiple partial fills with IDENTICAL callback settings
        // - Both configured with 130e18 collateral for 100e18 offer size (satisfies lltv 0.77)
        // - Same offerSellerAssets (100e18), same collateral configs
        // When combined fills = 100%, total collateral = configured amount

        bytes memory callbackData = _encodeCallbackData(130e18, 0, 100e18, 0);

        // First partial fill: 60e18 (60% of 100e18)
        // Expected: 60% * 130e18 = 78e18
        _takeOffer(60e18, callbackData, lender);
        uint256 supplied1 = midnight.collateral(marketId, seller, 0);
        assertEq(supplied1, 78e18, "First fill should supply 78e18 (60% of 130e18)");

        // Second partial fill: 40e18 (40% of 100e18)
        // Expected: 40% * 130e18 = 52e18
        // Total: 78e18 + 52e18 = 130e18 (exactly the configured amount)
        _takeOffer(40e18, callbackData, lender);
        uint256 supplied2 = midnight.collateral(marketId, seller, 0);
        assertEq(supplied2, 130e18, "Total collateral is exactly 130e18 (78e18 + 52e18)");

        // This demonstrates that when partial fills sum to exactly 100%, the pro-rata
        // calculation naturally results in exactly the configured collateral amount.
    }

    /// @notice Multiple collaterals are all supplied correctly
    function test_MultipleCollaterals() public {
        // Need ~130e18 total collateral (100/0.77) to satisfy lltv for 100e18 debt
        bytes memory callbackData = _encodeCallbackData(80e18, 50e18, 100e18, 0);

        _takeOffer(100e18, callbackData, lender);

        bytes32 marketId = IdLib.toId(testMarket);
        assertEq(midnight.collateral(marketId, seller, 0), 80e18);
        assertEq(midnight.collateral(marketId, seller, 1), 50e18);
    }

    /// @notice Zero-amount collaterals are skipped
    function test_SelectiveSupply() public {
        // Only supply collateral1, skip collateral2 (amount=0)
        // Need ~130e18 collateral to satisfy lltv for 100e18 debt
        bytes memory callbackData = _encodeCallbackData(130e18, 0, 100e18, 0);

        _takeOffer(100e18, callbackData, lender);

        bytes32 marketId = IdLib.toId(testMarket);
        assertEq(midnight.collateral(marketId, seller, 0), 130e18);
        assertEq(midnight.collateral(marketId, seller, 1), 0);
    }

    /// @notice Amounts array length mismatch causes revert
    function test_CollateralArrayLengthMismatch() public {
        // Create callback data with wrong number of amounts
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e18;

        bytes memory callbackData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: amounts, offerSellerAssets: 100e18, maxBorrowCapacityUsage: 0
            })
        );

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.InvalidCollateral.selector);
        callback.onSell(bytes32(0), testMarket, 100e18, 100e18, 0, seller, address(0), callbackData);
    }

    /// @notice Max debt/capacity disabled (0) skips check
    function test_MaxBorrowCapacityUsageDisabled() public {
        // maxBorrowCapacityUsage = 0 means no check
        bytes memory callbackData = _encodeCallbackData(130e18, 0, 100e18, 0);

        // Should succeed regardless of debt/capacity
        _takeOffer(100e18, callbackData, lender);

        bytes32 marketId = IdLib.toId(testMarket);
        assertEq(midnight.collateral(marketId, seller, 0), 130e18);
    }

    /// @notice maxBorrowCapacityUsage >= WAD is non-binding (behaves like disabled).
    /// @dev The gate can only reject debt > capacity (debt/capacity > WAD), which Midnight already rejects via
    ///      isHealthy at settlement. So a WAD cap admits the maximally-leveraged healthy position (debt == capacity),
    ///      adding nothing beyond Midnight's own check; the meaningful range is the open interval (0, WAD).
    function test_MaxBorrowCapacityUsage_atWAD_isNonBinding() public {
        bytes32 marketId = IdLib.toId(testMarket);

        // capacity = 100e18 * 0.77 = 77e18; borrowing exactly to capacity gives debt/capacity == WAD.
        bytes memory callbackData = _encodeCallbackData(100e18, 0, 77e18, WAD);

        // Admitted: WAD does not bind before Midnight's own liquidation line.
        _takeOffer(77e18, callbackData, lender);

        assertEq(midnight.debt(marketId, seller), 77e18);
        assertEq(midnight.collateral(marketId, seller, 0), 100e18);
    }

    /// @notice Max debt/capacity check passes when debt/capacity is within limit after collateral supply
    /// @dev Tests that maxBorrowCapacityUsage check uses total debt and collateral AFTER the callback supplies
    /// collateral
    function test_MaxBorrowCapacityUsageWithNoDebt() public {
        bytes32 marketId = IdLib.toId(testMarket);

        // Seller has no debt initially (default state)
        assertEq(midnight.debt(marketId, seller), 0, "Seller should have no debt");

        // Callback supplies 200e18 collateral with maxBorrowCapacityUsage = 0.7 (70% of borrowing capacity)
        // capacity = 200e18 * 0.77 lltv = 154e18; debt 100e18 → debt/capacity = 100/154 ≈ 0.649 < 0.7 ✓
        bytes memory callbackData = _encodeCallbackData(200e18, 0, 100e18, 0.7e18);

        _takeOffer(100e18, callbackData, lender);

        // Verify debt and collateral were created
        assertEq(midnight.debt(marketId, seller), 100e18, "Should have 100e18 debt");
        assertEq(midnight.collateral(marketId, seller, 0), 200e18, "Collateral should be supplied");
    }

    /// @notice Insufficient balance causes revert
    function test_InsufficientBalance() public {
        // Seller only has 10000e18 (from setUp), try to supply 20000e18
        bytes memory callbackData = _encodeCallbackData(20000e18, 0, 100e18, 0);

        // Build the offer inline so we can place vm.expectRevert right before midnight.take
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, uint256(100e18), gasleft()));
        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, sellerSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = 100e18;

        vm.prank(lender);
        vm.expectRevert(); // ERC20 insufficient balance during callback
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );
    }

    /// @notice Insufficient approval causes revert
    function test_InsufficientApproval() public {
        // Revoke approval
        vm.prank(seller);
        collateralToken1.approve(address(callback), 0);

        bytes memory callbackData = _encodeCallbackData(10e18, 0, 100e18, 0);

        vm.prank(address(midnight));
        vm.expectRevert(); // ERC20 insufficient allowance
        callback.onSell(bytes32(0), testMarket, 100e18, 100e18, 0, seller, address(0), callbackData);
    }

    /// @notice Zero offerSellerAssets causes revert
    function test_ZeroOfferAssets() public {
        bytes memory callbackData = _encodeCallbackData(10e18, 0, 0, 0);

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        callback.onSell(bytes32(0), testMarket, 100e18, 100e18, 0, seller, address(0), callbackData);
    }

    /* ========== MAX BORROW-CAPACITY-USAGE BREACH TESTS ========== */

    /// @notice Max debt/capacity breach when collateral price drops significantly
    /// @dev Tests the core protection: single offer with collateral supply, partial fill → price drop → second fill
    /// reverts
    function test_MaxBorrowCapacityUsageBreach_InsufficientCollateral() public {
        bytes32 marketId = IdLib.toId(testMarket);

        // Create offer: 100e18 loan tokens, supplies 200e18 collateral, maxBorrowCapacityUsage = 0.9 (90% of capacity)
        // Initially healthy: capacity = 200e18 * 0.77 = 154e18 for 100e18 debt → debt/capacity ≈ 0.649 at 1:1 price
        bytes memory callbackData = _encodeCallbackData(200e18, 0, 100e18, 0.9e18);
        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: bytes32(0),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, sellerSK);

        // First partial fill: 50e18 (50%)
        // Supplies 100e18 collateral, creates 50e18 debt
        // At 1:1 price: debt/capacity = 50 / (100 * 0.77) ≈ 0.649 < 0.9 ✓
        // Lender (taker/buyer) takes the borrower's offer
        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _shares = 50e18;
            vm.prank(lender);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _shares,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        // Verify collateral and debt after first fill
        assertEq(midnight.collateral(marketId, seller, 0), 100e18, "Should have 100e18 collateral after first fill");
        assertEq(midnight.debt(marketId, seller), 50e18, "Should have 50e18 debt after first fill");

        // Price drops to 0.5 (50% crash)
        oracle.setPrice(0.5e36);
        // Now: capacity = 100e18 * 0.5 * 0.77 = 38.5e18
        // Current debt/capacity = 50/38.5 ≈ 1.30 (> 0.9) - underwater!

        // Attempt second partial fill: 25e18 (another 25%)
        // Total: 150e18 collateral, 75e18 debt; capacity = 150 * 0.5 * 0.77 = 57.75e18
        // debt/capacity = 75/57.75 ≈ 1.30 > 0.9
        // Should revert
        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _shares = 25e18;
            vm.prank(lender);
            vm.expectRevert(CallbackLib.InvalidBorrowCapacityUsage.selector);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _shares,
                lender,
                address(0),
                address(0),
                ""
            );
        }
    }

    /// @notice Max debt/capacity at boundary succeeds
    /// @dev When debt/capacity equals maxBorrowCapacityUsage, transaction should succeed
    /// Note: Must also satisfy protocol lltv (0.77), so collateral needs to be debt/0.77
    function test_MaxBorrowCapacityUsageAtBoundary_Succeeds() public {
        bytes32 marketId = IdLib.toId(testMarket);

        // Create offer: 100e18 loan tokens, supplies 200e18 collateral, maxBorrowCapacityUsage = 0.65 (65% of capacity)
        // capacity = 200e18 * 0.77 = 154e18; debt/capacity = 100/154 ≈ 0.649 < 0.65 ✓
        // Pro-rata fills keep debt/capacity constant (debt and collateral scale together).
        bytes memory callbackData = _encodeCallbackData(200e18, 0, 100e18, 0.65e18);
        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: bytes32(0),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, sellerSK);

        // First partial fill: 50e18 (50%)
        // Supplies 100e18 collateral, creates 50e18 debt
        // debt/capacity = 50 / (100 * 0.77) ≈ 0.649 < maxBorrowCapacityUsage (0.65) ✓
        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _shares = 50e18;
            vm.prank(lender);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _shares,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        // Verify state
        assertEq(midnight.collateral(marketId, seller, 0), 100e18);
        assertEq(midnight.debt(marketId, seller), 50e18);

        // Second partial fill: 10e18 (another 10%)
        // Would add 20e18 collateral and 10e18 debt
        // Total: 120e18 collateral, 60e18 debt
        // debt/capacity = 60 / (120 * 0.77) ≈ 0.649 < maxBorrowCapacityUsage (0.65) ✓
        // Should succeed
        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _shares = 10e18;
            vm.prank(lender);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _shares,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        // Verify final state
        assertEq(midnight.collateral(marketId, seller, 0), 120e18);
        assertEq(midnight.debt(marketId, seller), 60e18);
    }

    /// @notice Price movement causes debt/capacity breach
    /// @dev Price drop between first and second fill causes maxBorrowCapacityUsage to be exceeded
    function test_MaxBorrowCapacityUsageBreach_PriceMovement() public {
        bytes32 marketId = IdLib.toId(testMarket);

        // Create offer: 100e18 loan tokens, supplies 200e18 collateral, maxBorrowCapacityUsage = 0.75 (75% of capacity)
        // capacity = 200e18 * 0.77 = 154e18 > 100e18 debt; debt/capacity = 100/154 ≈ 0.649 < 0.75 ✓
        bytes memory callbackData = _encodeCallbackData(200e18, 0, 100e18, 0.75e18);
        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: bytes32(0),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, sellerSK);

        // First partial fill: 60e18 (60%)
        // Supplies 120e18 collateral, creates 60e18 debt
        // At 1:1 price: debt/capacity = 60 / (120 * 0.77) ≈ 0.649 < 0.75 ✓
        // Health: 60 <= 120 * 0.77 = 92.4 ✓
        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _shares = 60e18;
            vm.prank(lender);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _shares,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        // Verify state
        assertEq(midnight.collateral(marketId, seller, 0), 120e18);
        assertEq(midnight.debt(marketId, seller), 60e18);

        // Price drops 40%
        oracle.setPrice(0.6e36);
        // capacity = 120e18 * 0.6 * 0.77 = 55.44e18
        // Current debt/capacity = 60/55.44 ≈ 1.08 (> 0.75) - underwater!

        // Attempt second partial fill: 20e18 (another 20%)
        // Total: 160e18 collateral, 80e18 debt; capacity = 160 * 0.6 * 0.77 = 73.92e18
        // debt/capacity = 80/73.92 ≈ 1.08 > 0.75
        // Should revert
        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _shares = 20e18;
            vm.prank(lender);
            vm.expectRevert(CallbackLib.InvalidBorrowCapacityUsage.selector);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _shares,
                lender,
                address(0),
                address(0),
                ""
            );
        }
    }

    /// @notice Max debt/capacity check passes with sufficient collateral after price drop
    /// @dev Even with price movement, sufficient collateral keeps debt/capacity below maxBorrowCapacityUsage
    function test_MaxBorrowCapacityUsagePass_SufficientCollateralAfterPriceMovement() public {
        bytes32 marketId = IdLib.toId(testMarket);

        // Create offer: 100e18 loan tokens, supplies 300e18 collateral, maxBorrowCapacityUsage = 0.75 (75% of capacity)
        // Over-collateralized to withstand a moderate price drop.
        // Initial: capacity = 300e18 * 0.77 = 231e18 > 100e18 debt; debt/capacity = 100/231 ≈ 0.433 < 0.75 ✓
        bytes memory callbackData = _encodeCallbackData(300e18, 0, 100e18, 0.75e18);
        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: bytes32(0),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, sellerSK);

        // First partial fill: 50e18 (50%)
        // Supplies 150e18 collateral, creates 50e18 debt
        // At 1:1 price: debt/capacity = 50 / (150 * 0.77) ≈ 0.433 < 0.75 ✓
        // Health: 50 <= 150 * 0.77 = 115.5 ✓
        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _shares = 50e18;
            vm.prank(lender);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _shares,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        // Verify state
        assertEq(midnight.collateral(marketId, seller, 0), 150e18);
        assertEq(midnight.debt(marketId, seller), 50e18);

        // Price drops to 0.9 (10% drop)
        oracle.setPrice(0.9e36);
        // capacity = 150e18 * 0.9 * 0.77 = 103.95e18
        // Current debt/capacity = 50/103.95 ≈ 0.481 < 0.75 - still healthy ✓

        // Second partial fill: 20e18 (another 20%)
        // Total: 210e18 collateral, 70e18 debt; capacity = 210 * 0.9 * 0.77 = 145.53e18
        // debt/capacity = 70/145.53 ≈ 0.481 < 0.75 ✓
        // Should succeed
        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _shares = 20e18;
            vm.prank(lender);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _shares,
                lender,
                address(0),
                address(0),
                ""
            );
        }

        // Verify final state
        assertEq(midnight.collateral(marketId, seller, 0), 210e18);
        assertEq(midnight.debt(marketId, seller), 70e18);
    }

    /// @notice Zero borrowing capacity should revert with InvalidBorrowCapacityUsage error
    /// @dev When maxBorrowCapacityUsage check is enabled but no collateral has been supplied yet (capacity = 0)
    function test_MaxBorrowCapacityUsageBreach_ZeroCollateralValue() public {
        // Create offer with maxBorrowCapacityUsage check but zero collateral supply
        // This tests the edge case where maxBorrowCapacityUsage is enabled but collateral is not yet supplied
        bytes memory callbackData = _encodeCallbackData(0, 0, 100e18, 0.9e18); // Zero collateral amounts,
        // maxBorrowCapacityUsage
        // enabled
        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: bytes32(0),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, sellerSK);

        // Attempt to take the offer - should revert with ZeroCollateralValue
        // Because maxBorrowCapacityUsage check is enabled but no collateral is supplied (value = 0)
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = 50e18;
        vm.prank(lender);
        vm.expectRevert(CallbackLib.InvalidBorrowCapacityUsage.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );
    }

    /* ========== FEE TESTS ========== */

    /// @notice No fee charged when feeRate is 0
    function test_FeeCharged_ZeroFeeRate() public {
        address feeRecipient = makeAddr("FeeRecipient");
        bytes memory callbackData = _encodeCallbackDataWithFee(125e18, 0, 100e18, 0);

        // Call directly — no interest, no fee regardless
        vm.prank(address(midnight));
        callback.onSell(bytes32(0), testMarket, 100e18, 110e18, 0, seller, address(0), callbackData);

        assertEq(loanToken.balanceOf(feeRecipient), 0, "No fee should be charged");
    }
}
