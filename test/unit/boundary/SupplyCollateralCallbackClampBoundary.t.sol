// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {SupplyCollateralCallbackClamp} from "../../../src/router/clamps/SupplyCollateralCallbackClamp.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {Offer, Market, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {MockERC20} from "../../helpers/mocks/MockERC20.sol";
import {Oracle} from "../../helpers/Oracle.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {LIQUIDATION_CURSOR} from "../../helpers/MaxLifLib.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";

/// @title SupplyCollateralCallbackClampBoundary
/// @notice Deterministic boundary tests for SupplyCollateralCallbackClamp
/// @dev Min chain: min(capacityToShares, collateralProRataShares, healthShares)
///      SELL offers: buy=false, maker=seller(borrower), taker=buyer(lender)
///      Collateral/health constraints only apply to units-based offers (units > 0).
contract SupplyCollateralCallbackClampBoundary is BoundaryTestBase {
    uint256 private _groupNonce;

    /// @notice Seller (maker/borrower) for callback sell offers
    address internal seller;
    uint256 internal sellerSK;

    /// @notice Callback contract for collateral supply
    MidnightSupplyCollateralCallback internal callback;

    /// @notice Offer capacity in seller assets — used as offerSellerAssets in callback data
    uint256 internal constant OFFER_SELLER_ASSETS = 1000e18;

    /// @notice Collateral amount for full offer fill
    uint256 internal constant COLLATERAL_FOR_FULL_FILL = 5000e18;

    function setUp() public override {
        super.setUp();

        (seller, sellerSK) = makeAddrAndKey("cbSeller");

        // Deploy callback
        callback = new MidnightSupplyCollateralCallback(address(midnight));

        // Default: buyer (lender/taker) has huge balance + approval
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        // Default: seller authorizes callback and has huge collateral + approval
        collateralToken.mint(seller, type(uint128).max);
        vm.startPrank(seller);
        collateralToken.approve(address(callback), type(uint256).max);
        midnight.setIsAuthorized(address(callback), true, seller);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seller);
        vm.stopPrank();
    }

    /* ═══════ Helpers ═══════ */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("scccBoundary", ++_groupNonce));
    }

    /// @notice Build callback data for the offer's callbackData field
    function _buildCallbackData(uint256 collateralForFull, uint256 offerSellerAssets)
        internal
        pure
        returns (bytes memory)
    {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = collateralForFull;

        return abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: amounts, offerSellerAssets: offerSellerAssets, maxBorrowCapacityUsage: 0
            })
        );
    }

    /// @notice Build a SELL offer with callback (maxSellerAssets-based)
    function _buildSellerAssetsOffer(
        address maker,
        uint128 sellerAssetsCapacity,
        uint16 tick,
        bytes32 group,
        uint256 collateralForFull
    ) internal view returns (Offer memory) {
        return Offer({
            market: targetMarket,
            buy: false,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(callback),
            callbackData: _buildCallbackData(collateralForFull, sellerAssetsCapacity),
            receiverIfMakerIsSeller: maker,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: sellerAssetsCapacity,
            continuousFeeCap: type(uint256).max
        });
    }

    /// @notice Build a SELL offer with callback (maxSellerAssets-based, with custom offerSellerAssets in callback data)
    function _buildCapacityOffer(
        address maker,
        uint128 sellerAssetsCapacity,
        uint16 tick,
        bytes32 group,
        uint256 collateralForFull,
        uint256 offerSellerAssets
    ) internal view returns (Offer memory) {
        return Offer({
            market: targetMarket,
            buy: false,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(callback),
            callbackData: _buildCallbackData(collateralForFull, offerSellerAssets),
            receiverIfMakerIsSeller: maker,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: sellerAssetsCapacity,
            continuousFeeCap: type(uint256).max
        });
    }

    /// @notice Build clamp data for the clamp contract
    function _buildClampData(uint256, address taker) internal view returns (bytes memory) {
        return abi.encode(SupplyCollateralCallbackClamp.ClampData({marketId: targetMarketId, taker: taker}));
    }

    /// @notice Default clamp data with standard collateral amount
    function _clampData() internal view returns (bytes memory) {
        return _buildClampData(COLLATERAL_FOR_FULL_FILL, lender);
    }

    /* ═══════ Collateral balance binding ═══════ */

    /// @notice Small collateral balance is binding (fresh 1:1 ratio, units-based offer)
    function test_bindingCollateral_fresh() public {
        // Reset seller's collateral to a small amount
        deal(address(collateralToken), seller, 50e18);
        vm.prank(seller);
        collateralToken.approve(address(callback), type(uint256).max);

        uint128 unitsCapacity = uint128(OFFER_SELLER_ASSETS);
        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellerAssetsOffer(seller, unitsCapacity, TICK_HIGH, group, COLLATERAL_FOR_FULL_FILL);

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(supplyCollateralCallbackClamp)), _clampData());
    }

    /// @notice Small collateral balance is binding with reduced totalUnits
    function test_bindingCollateral_1to2() public {
        _setTotalUnits(targetMarketId, 100e18);

        deal(address(collateralToken), seller, 50e18);
        vm.prank(seller);
        collateralToken.approve(address(callback), type(uint256).max);

        uint128 unitsCapacity = uint128(OFFER_SELLER_ASSETS);
        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellerAssetsOffer(seller, unitsCapacity, TICK_HIGH, group, COLLATERAL_FOR_FULL_FILL);

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        // Non-1:1 ratio: conservative floor rounding may leave tiny remainder
        _verifyBoundary(
            maxUnits, offer, sig, lender, ITakeClamp(address(supplyCollateralCallbackClamp)), _clampData(), false, false
        );
    }

    /// @notice Small collateral balance is binding with slightly reduced totalUnits
    function test_bindingCollateral_99to100() public {
        _setTotalUnits(targetMarketId, 99e18);

        deal(address(collateralToken), seller, 50e18);
        vm.prank(seller);
        collateralToken.approve(address(callback), type(uint256).max);

        uint128 unitsCapacity = uint128(OFFER_SELLER_ASSETS);
        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellerAssetsOffer(seller, unitsCapacity, TICK_HIGH, group, COLLATERAL_FOR_FULL_FILL);

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        // Non-1:1 ratio: conservative floor rounding may leave tiny remainder
        _verifyBoundary(
            maxUnits, offer, sig, lender, ITakeClamp(address(supplyCollateralCallbackClamp)), _clampData(), false, false
        );
    }

    /* ═══════ Collateral allowance binding ═══════ */

    /// @notice Allowance is binding (balance is large, allowance is small)
    function test_bindingCollateralAllowance() public {
        // Seller has huge balance but small allowance to the callback
        vm.prank(seller);
        collateralToken.approve(address(callback), 50e18);

        uint128 unitsCapacity = uint128(OFFER_SELLER_ASSETS);
        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellerAssetsOffer(seller, unitsCapacity, TICK_HIGH, group, COLLATERAL_FOR_FULL_FILL);

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(supplyCollateralCallbackClamp)), _clampData());
    }

    /* ═══════ Health headroom binding ═══════ */

    /// @notice Health headroom is binding — seller has small existing collateral, no prior debt
    /// @dev Uses cbForFull=100e18 with offerSellerAssets=1000e18 (1:10 ratio) so callback
    ///      collateral per unit is small, making health the binding constraint.
    ///      callbackMaxDebt = 100e18 * 10 * 0.945 = 945e18 < offerSellerAssets = 1000e18
    ///      netDrain per unit = 1 - 945/1000 = 0.055
    ///      maxUnits = headroom * 1000 / (1000 - 945) ≈ headroom * 18.18
    function test_bindingHealth_fresh() public {
        // Deposit small collateral directly for limited headroom
        _depositCollateral(seller, 1e18, targetMarket);

        uint256 cbCollateral = 100e18;
        uint128 unitsCapacity = uint128(OFFER_SELLER_ASSETS);
        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellerAssetsOffer(seller, unitsCapacity, TICK_HIGH, group, cbCollateral);
        bytes memory cd = _buildClampData(cbCollateral, lender);

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");
        assertTrue(maxUnits < uint256(unitsCapacity), "health should be binding, not capacity");

        // The debt-limit path is now conservative (existing-collateral headroom; defers upside to capacity), so it is
        // safe but not tight: assert take(maxUnits) succeeds without asserting take(maxUnits + 1) reverts.
        Signature memory sig = _signOffer(offer, sellerSK);
        _verifySafetyOnly(maxUnits, offer, sig, lender);
    }

    /// @notice Health headroom is binding with reduced totalUnits
    function test_bindingHealth_1to2() public {
        _depositCollateral(seller, 1e18, targetMarket);
        _setTotalUnits(targetMarketId, 100e18);

        uint256 cbCollateral = 100e18;
        uint128 unitsCapacity = uint128(OFFER_SELLER_ASSETS);
        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellerAssetsOffer(seller, unitsCapacity, TICK_HIGH, group, cbCollateral);
        bytes memory cd = _buildClampData(cbCollateral, lender);

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");
        assertTrue(maxUnits < uint256(unitsCapacity), "health should be binding");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifySafetyOnly(maxUnits, offer, sig, lender);
    }

    /// @notice Health headroom is binding with slightly reduced totalUnits
    function test_bindingHealth_99to100() public {
        _depositCollateral(seller, 1e18, targetMarket);
        _setTotalUnits(targetMarketId, 99e18);

        uint256 cbCollateral = 100e18;
        uint128 unitsCapacity = uint128(OFFER_SELLER_ASSETS);
        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellerAssetsOffer(seller, unitsCapacity, TICK_HIGH, group, cbCollateral);
        bytes memory cd = _buildClampData(cbCollateral, lender);

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");
        assertTrue(maxUnits < uint256(unitsCapacity), "health should be binding");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifySafetyOnly(maxUnits, offer, sig, lender);
    }

    /// @notice When callbackMaxDebt is just below offerSellerAssets, health constrains
    /// @dev callbackMaxDebt = 100e18 * 10 * 0.945 = 945e18 < 955e18 = offerSellerAssets
    ///      gap = 10e18, headroom = 1e18 * 10 * 0.945 = 9.45e18 < gap
    ///      → health constrains
    function test_healthBoundary_justBelow() public {
        // Give seller small existing collateral so headroom < gap
        _depositCollateral(seller, 1e18, targetMarket);

        uint256 cbCollateral = 100e18;
        uint128 unitsCapacity = 955e18; // slightly > callbackMaxDebt (945e18)
        bytes32 group = _freshGroup();

        Offer memory offer = _buildSellerAssetsOffer(seller, unitsCapacity, TICK_HIGH, group, cbCollateral);
        bytes memory cd = _buildClampData(cbCollateral, lender);

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "health below boundary: should have shares");
        // Health should be binding (less than capacity)
        assertTrue(maxUnits < uint256(unitsCapacity), "health below boundary: health should constrain");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifyBoundary(
            maxUnits, offer, sig, lender, ITakeClamp(address(supplyCollateralCallbackClamp)), cd, false, false
        );
    }

    /* ═══════ maxBorrowCapacityUsage constraint (callback-enforced) ═══════ */

    /// @notice maxBorrowCapacityUsage=50% is binding — clamp respects the callback's debt/capacity constraint
    /// @dev Without maxBorrowCapacityUsage, health allows ~190e18 units (95% debt/capacity).
    ///      With maxBorrowCapacityUsage=0.5e18, the clamp limits to ~10e18 units (50% debt/capacity).
    function test_bindingMaxBorrowCapacityUsage() public {
        // Seller has small existing collateral → limited headroom
        _depositCollateral(seller, 1e18, targetMarket);

        uint256 cbCollateral = 100e18;
        uint128 unitsCapacity = uint128(OFFER_SELLER_ASSETS); // 1000e18

        // Build callback data with maxBorrowCapacityUsage = 50%
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = cbCollateral;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: amounts, offerSellerAssets: unitsCapacity, maxBorrowCapacityUsage: 0.5e18
            })
        );

        bytes32 group = _freshGroup();
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(callback),
            callbackData: cbData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: unitsCapacity,
            continuousFeeCap: type(uint256).max
        });

        bytes memory cd = _buildClampData(cbCollateral, lender);

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "clamp should return shares");
        // maxBorrowCapacityUsage should be much tighter than health (50% vs 95%)
        assertTrue(maxUnits < uint256(unitsCapacity), "maxBorrowCapacityUsage should be binding");

        // Conservative debt-limit path: safe but not tight.
        Signature memory sig = _signOffer(offer, sellerSK);
        _verifySafetyOnly(maxUnits, offer, sig, lender);
    }

    /* ═══════ reduceOnly ═══════ */

    /// @notice reduceOnly=true returns 0 when seller has no credit on the market
    /// @dev SELL offer: reduceOnly caps by seller's credit on the market.
    ///      A fresh borrower has no credit, so reduceOnly → 0.
    function test_reduceOnly_noCredit_returnsZero() public {
        bytes32 group = _freshGroup();

        Offer memory offer =
            _buildSellerAssetsOffer(seller, uint128(OFFER_SELLER_ASSETS), TICK_HIGH, group, COLLATERAL_FOR_FULL_FILL);
        offer.reduceOnly = true;

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, _clampData());
        assertEq(maxUnits, 0, "reduceOnly with no credit should return 0");
    }

    /* ═══════ Zero edge cases ═══════ */

    /// @notice Zero collateral amount in config → collateral constraint is skipped, other constraints apply
    function test_zeroCollateralAmount() public {
        bytes32 group = _freshGroup();

        // Build offer with zero collateral in callback data
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;

        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: amounts, offerSellerAssets: OFFER_SELLER_ASSETS, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(callback),
            callbackData: cbData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: uint128(OFFER_SELLER_ASSETS),
            continuousFeeCap: type(uint256).max
        });

        bytes memory cd = abi.encode(SupplyCollateralCallbackClamp.ClampData({marketId: targetMarketId, taker: lender}));

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        // With zero collateral, no callback health gain, and seller has no existing collateral on this
        // market, health returns 0 (headroom = 0 since no existing collateral deposited).
        // So the result is 0.
        assertEq(maxUnits, 0, "zero collateral amount: clamp should return 0");
    }

    /* ═══════ Malformed callbackData ═══════ */

    /// @notice Malformed / truncated callbackData makes the clamp return 0 without reverting (CLAMP-3).
    /// @dev The clamp now mirrors the callback by decoding the full CallbackData; bytes that fail to decode (or
    ///      decode to offerSellerAssets == 0) yield 0 units, matching the callback which would itself revert.
    function test_shortCallbackData_returnsZero() public {
        bytes32 group = _freshGroup();

        // 128 zero bytes: decodes to an empty amounts array and offerSellerAssets == 0.
        bytes memory shortCbData = new bytes(128);

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(callback),
            callbackData: shortCbData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: uint128(OFFER_SELLER_ASSETS),
            continuousFeeCap: type(uint256).max
        });

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, _clampData());
        assertEq(maxUnits, 0, "malformed callbackData: clamp should return 0");

        // Truncated-to-32-bytes data must also be absorbed without reverting.
        offer.callbackData = new bytes(32);
        assertEq(
            supplyCollateralCallbackClamp.maxUnits(offer, _clampData()),
            0,
            "truncated callbackData: clamp should return 0"
        );
    }

    /* ═══════ Existing debt + headroom binding (mutants 138, 221, 243) ═══════ */

    /// @notice Seller with existing debt: headroom = existingLimit - currentDebt is binding
    /// @dev Kills mutant 138: headroom subtraction mutated to addition
    ///      When seller already has debt, the available headroom is reduced, constraining the clamp.
    ///      Uses _setupBorrowerWithDebt (provides 20x collateral per debt unit), then creates
    ///      a very large offer so health is the binding constraint (not capacity).
    function test_existingDebt_headroomBinding() public {
        // Seller borrows 10e18 units, gets 200e18 collateral deposited
        // existingLimit = 200e18 * 10 * 0.945 = 1890e18
        // headroom = 1890 - 10 = 1880e18 (massive)
        _setupBorrowerWithDebt(seller, sellerSK, 10e18, targetMarket, targetMarketId);

        // To make health binding, use very small callback collateral (1e18) relative to huge capacity
        // callbackLimit = 1e18 * 10 * 0.945 = 9.45e18
        // equivalentOfferUnits = 10000e18 * WAD / sellerPrice ~ 10000e18
        // callbackLimit (9.45e18) < equivalentOfferUnits (10000e18) → health constrains
        // maxUnits ≈ headroom * equivalentOfferUnits / (equivalentOfferUnits - callbackLimit) ≈ 1882
        uint256 cbCollateral = 1e18;
        uint128 unitsCapacity = 10_000e18;
        bytes32 group = _freshGroup();

        Offer memory offer = _buildSellerAssetsOffer(seller, unitsCapacity, TICK_HIGH, group, cbCollateral);
        bytes memory cd = _buildClampData(cbCollateral, lender);

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "existing debt: should have units");
        assertTrue(maxUnits < uint256(unitsCapacity), "existing debt: health should be binding");

        // Conservative debt-limit path: safe but not tight.
        Signature memory sig = _signOffer(offer, sellerSK);
        _verifySafetyOnly(maxUnits, offer, sig, lender);
    }

    /// @notice The conservative debt-limit path never over-sizes: take(maxUnits) succeeds even when the linearized
    ///         estimate would overshoot its own forward limit (the case the deleted _verifyForward handled). The clamp
    ///         falls back to the monotone-safe existing-collateral headroom instead of a tight, fill-specific estimate.
    function test_debtLimitFallback_safeNotOversized() public {
        // Deposit just enough existing collateral to give moderate headroom; small callback collateral so the debt
        // limit (not capacity) binds and the linearized estimate is in the overshoot-prone regime.
        _depositCollateral(seller, 1e18, targetMarket);

        uint256 cbCollateral = 1e18;
        uint128 unitsCapacity = 10_000e18;
        bytes32 group = _freshGroup();

        Offer memory offer = _buildSellerAssetsOffer(seller, unitsCapacity, TICK_HIGH, group, cbCollateral);
        bytes memory cd = _buildClampData(cbCollateral, lender);

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "fallback: should have units");
        assertTrue(maxUnits < uint256(unitsCapacity), "fallback: debt limit should be binding");

        // Safe: take(maxUnits) does not revert. (No tightness: the fallback is deliberately conservative.)
        Signature memory sig = _signOffer(offer, sellerSK);
        _verifySafetyOnly(maxUnits, offer, sig, lender);
    }

    /* ═══════ equivalentOfferUnits == 0 (mutants 145, 158) ═══════ */

    /* ═══════ offerSA == 0 skips collateral/health (mutants 93, 124) ═══════ */

    /* ═══════ Multi-collateral bitmap (mutants 23, 31, 33, 34, 36, 37, 56) ═══════ */

    /* ═══════ Multi-collateral binding ═══════ */

    /// @notice Second collateral slot is the binding constraint across 2-collateral market
    /// @dev Creates a 2-collateral market where the seller has plenty of collateral1
    ///      but limited collateral2. The clamp should be limited by collateral2's balance.
    function test_bindingCollateral_multiSlot() public {
        // 1. Create second collateral token and oracle
        MockERC20 collateralToken2 = new MockERC20("Col2", "COL2", 18);
        Oracle oracle2 = new Oracle();
        oracle2.setPrice(10e36); // Same price as oracle1: 1 collateral2 = 10 loan tokens

        // 2. Build 2-collateral market
        CollateralParams[] memory collaterals2 = new CollateralParams[](2);
        collaterals2[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });
        collaterals2[1] = CollateralParams({
            token: address(collateralToken2),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle2)
        });

        Market memory multiObl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals2,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        bytes32 multiOblId = IdLib.toId(multiObl);

        // 3. Seed the market (custom seed with 2 collateral configs)
        {
            (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey("multiSeedBorrower");
            address seedLender = makeAddr("multiSeedLender");

            loanToken.mint(seedLender, type(uint128).max);
            collateralToken.mint(seedBorrower, type(uint128).max);
            collateralToken2.mint(seedBorrower, type(uint128).max);

            MidnightSupplyCollateralCallback seedCb = new MidnightSupplyCollateralCallback(address(midnight));

            vm.startPrank(seedBorrower);
            collateralToken.approve(address(seedCb), type(uint256).max);
            collateralToken2.approve(address(seedCb), type(uint256).max);
            midnight.setIsAuthorized(address(seedCb), true, seedBorrower);
            midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedBorrower);
            vm.stopPrank();

            vm.prank(seedLender);
            loanToken.approve(address(midnight), type(uint256).max);

            uint256[] memory seedAmounts = new uint256[](2);
            seedAmounts[0] = SEED_AMOUNT * 10;
            seedAmounts[1] = SEED_AMOUNT * 10;
            bytes memory seedCbData = abi.encode(
                IMidnightSupplyCollateralCallback.CallbackData({
                    amounts: seedAmounts, offerSellerAssets: SEED_AMOUNT, maxBorrowCapacityUsage: 0
                })
            );

            Offer memory seedOffer = Offer({
                market: multiObl,
                buy: false,
                maker: seedBorrower,
                start: block.timestamp,
                expiry: block.timestamp + 1 hours,
                tick: MAX_TICK,
                group: keccak256("multiSeed"),
                callback: address(seedCb),
                callbackData: seedCbData,
                receiverIfMakerIsSeller: seedBorrower,
                ratifier: address(ecrecoverRatifier),
                reduceOnly: false,
                maxUnits: 0,
                maxAssets: type(uint128).max,
                continuousFeeCap: type(uint256).max
            });

            Signature memory seedSig = _signOffer(seedOffer, seedBorrowerSK);
            bytes32 seedRoot = HashLib.hashOffer(seedOffer);

            vm.prank(seedLender);
            midnight.take(
                seedOffer,
                abi.encode(seedSig, seedRoot, uint256(0), new bytes32[](0)),
                SEED_AMOUNT,
                seedLender,
                address(0),
                address(0),
                ""
            );
        }

        // 4. Setup seller: plenty of collateral1, limited collateral2
        uint256 col1ForFull = 5000e18;
        uint256 col2ForFull = 5000e18;
        uint256 sellerCol2Balance = 50e18; // Binding constraint

        collateralToken.mint(seller, type(uint128).max);
        collateralToken2.mint(seller, sellerCol2Balance);

        vm.startPrank(seller);
        collateralToken.approve(address(callback), type(uint256).max);
        collateralToken2.approve(address(callback), type(uint256).max);
        midnight.setIsAuthorized(address(callback), true, seller);
        vm.stopPrank();

        // 5. Build SELL offer with callback supplying both collateral tokens
        uint128 unitsCapacity = uint128(OFFER_SELLER_ASSETS);
        bytes32 group = _freshGroup();

        uint256[] memory offerAmounts = new uint256[](2);
        offerAmounts[0] = col1ForFull;
        offerAmounts[1] = col2ForFull;

        bytes memory offerCbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: offerAmounts, offerSellerAssets: unitsCapacity, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory offer = Offer({
            market: multiObl,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(callback),
            callbackData: offerCbData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: unitsCapacity,
            continuousFeeCap: type(uint256).max
        });

        // 6. Build clamp data
        bytes memory cd = abi.encode(SupplyCollateralCallbackClamp.ClampData({marketId: multiOblId, taker: lender}));

        // 7. Call clamp — should be limited by collateral2's balance
        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "multiSlot: should have shares");
        assertTrue(maxUnits < uint256(unitsCapacity), "multiSlot: collateral2 should be binding, not capacity");

        // 8. Verify boundary invariants: safety + tightness
        Signature memory sig = _signOffer(offer, sellerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(supplyCollateralCallbackClamp)), cd);
    }

    /* ═══════ 6-decimal token boundary tests ═══════ */

    /// @notice Collateral balance binding with 6-decimal token
    /// @dev When the 6-decimal collateral balance is small (e.g. 50e6 = 50 USDC),
    ///      floor rounding in pro-rata collateral calculations should produce correct
    ///      results despite the 1e12 scaling difference from 18-decimal tokens.
    function test_sixDecimal_bindingCollateral() public {
        MockERC20 col6 = new MockERC20("USDC-Col2", "USDCC2", 6);
        Oracle oracle6 = new Oracle();
        oracle6.setPrice(10e48);

        CollateralParams[] memory col6Array = new CollateralParams[](1);
        col6Array[0] = CollateralParams({
            token: address(col6), lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle6)
        });

        Market memory obl6 = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: col6Array,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        bytes32 obl6Id = IdLib.toId(obl6);

        // Seed
        {
            (address seedB, uint256 seedBSK) = makeAddrAndKey("6dColSeedB");
            address seedL = makeAddr("6dColSeedL");

            loanToken.mint(seedL, type(uint128).max);
            col6.mint(seedB, type(uint128).max);

            MidnightSupplyCollateralCallback seedCb = new MidnightSupplyCollateralCallback(address(midnight));

            vm.startPrank(seedB);
            col6.approve(address(seedCb), type(uint256).max);
            midnight.setIsAuthorized(address(seedCb), true, seedB);
            midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedB);
            vm.stopPrank();

            vm.prank(seedL);
            loanToken.approve(address(midnight), type(uint256).max);

            uint256[] memory seedAmounts = new uint256[](1);
            seedAmounts[0] = SEED_AMOUNT * 10;
            bytes memory seedCbData = abi.encode(
                IMidnightSupplyCollateralCallback.CallbackData({
                    amounts: seedAmounts, offerSellerAssets: SEED_AMOUNT, maxBorrowCapacityUsage: 0
                })
            );

            Offer memory seedOffer = Offer({
                market: obl6,
                buy: false,
                maker: seedB,
                start: block.timestamp,
                expiry: block.timestamp + 1 hours,
                tick: MAX_TICK,
                group: keccak256("6dColSeed"),
                callback: address(seedCb),
                callbackData: seedCbData,
                receiverIfMakerIsSeller: seedB,
                ratifier: address(ecrecoverRatifier),
                reduceOnly: false,
                maxUnits: type(uint128).max,
                maxAssets: 0,
                continuousFeeCap: type(uint256).max
            });

            Signature memory seedSig = _signOffer(seedOffer, seedBSK);
            bytes32 seedRoot = HashLib.hashOffer(seedOffer);

            vm.prank(seedL);
            midnight.take(
                seedOffer,
                abi.encode(seedSig, seedRoot, uint256(0), new bytes32[](0)),
                SEED_AMOUNT,
                seedL,
                address(0),
                address(0),
                ""
            );
        }

        // Seller has LIMITED 6-decimal collateral
        uint256 smallBalance = 50e6; // Only 50 USDC
        col6.mint(seller, smallBalance);
        vm.startPrank(seller);
        col6.approve(address(callback), type(uint256).max);
        midnight.setIsAuthorized(address(callback), true, seller);
        vm.stopPrank();

        uint256 col6ForFull = 5000e6;
        uint128 unitsCapacity = uint128(OFFER_SELLER_ASSETS);
        bytes32 group = _freshGroup();

        uint256[] memory offerAmounts = new uint256[](1);
        offerAmounts[0] = col6ForFull;
        bytes memory offerCbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: offerAmounts, offerSellerAssets: unitsCapacity, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory offer = Offer({
            market: obl6,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(callback),
            callbackData: offerCbData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: unitsCapacity,
            continuousFeeCap: type(uint256).max
        });

        bytes memory cd = abi.encode(SupplyCollateralCallbackClamp.ClampData({marketId: obl6Id, taker: lender}));

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "6-decimal binding collateral: should have units");
        // 50 USDC balance vs 5000 USDC for full fill -> ~1% of capacity
        assertTrue(maxUnits < uint256(unitsCapacity), "6-decimal: collateral should be binding");

        Signature memory sig = _signOffer(offer, sellerSK);
        // checkNoDust=false: 6-decimal tokens have coarser granularity (1e6 vs 1e18),
        // so floor rounding in pro-rata collateral calculations may leave a tiny remainder
        // that the clamp cannot consume without exceeding the collateral balance.
        _verifyBoundary(
            maxUnits, offer, sig, lender, ITakeClamp(address(supplyCollateralCallbackClamp)), cd, false, false
        );
    }

    /// @notice Health headroom binding with 6-decimal collateral token
    /// @dev Tests that health constraint calculations work correctly with 6-decimal tokens
    ///      where the oracle price scaling is different (10e48 instead of 10e36).
    function test_sixDecimal_bindingHealth() public {
        MockERC20 col6 = new MockERC20("USDC-Col3", "USDCC3", 6);
        Oracle oracle6 = new Oracle();
        oracle6.setPrice(10e48);

        CollateralParams[] memory col6Array = new CollateralParams[](1);
        col6Array[0] = CollateralParams({
            token: address(col6), lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle6)
        });

        Market memory obl6 = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: col6Array,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        bytes32 obl6Id = IdLib.toId(obl6);

        // Seed
        {
            (address seedB, uint256 seedBSK) = makeAddrAndKey("6dHpSeedB");
            address seedL = makeAddr("6dHpSeedL");

            loanToken.mint(seedL, type(uint128).max);
            col6.mint(seedB, type(uint128).max);

            MidnightSupplyCollateralCallback seedCb = new MidnightSupplyCollateralCallback(address(midnight));

            vm.startPrank(seedB);
            col6.approve(address(seedCb), type(uint256).max);
            midnight.setIsAuthorized(address(seedCb), true, seedB);
            midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedB);
            vm.stopPrank();

            vm.prank(seedL);
            loanToken.approve(address(midnight), type(uint256).max);

            uint256[] memory seedAmounts = new uint256[](1);
            seedAmounts[0] = SEED_AMOUNT * 10;
            bytes memory seedCbData = abi.encode(
                IMidnightSupplyCollateralCallback.CallbackData({
                    amounts: seedAmounts, offerSellerAssets: SEED_AMOUNT, maxBorrowCapacityUsage: 0
                })
            );

            Offer memory seedOffer = Offer({
                market: obl6,
                buy: false,
                maker: seedB,
                start: block.timestamp,
                expiry: block.timestamp + 1 hours,
                tick: MAX_TICK,
                group: keccak256("6dHpSeed"),
                callback: address(seedCb),
                callbackData: seedCbData,
                receiverIfMakerIsSeller: seedB,
                ratifier: address(ecrecoverRatifier),
                reduceOnly: false,
                maxUnits: type(uint128).max,
                maxAssets: 0,
                continuousFeeCap: type(uint256).max
            });

            Signature memory seedSig = _signOffer(seedOffer, seedBSK);
            bytes32 seedRoot = HashLib.hashOffer(seedOffer);

            vm.prank(seedL);
            midnight.take(
                seedOffer,
                abi.encode(seedSig, seedRoot, uint256(0), new bytes32[](0)),
                SEED_AMOUNT,
                seedL,
                address(0),
                address(0),
                ""
            );
        }

        // Deposit small existing 6-decimal collateral for limited headroom
        col6.mint(seller, 1e6); // 1 USDC
        vm.startPrank(seller);
        col6.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(obl6, 0, 1e6, seller);
        vm.stopPrank();

        // Setup seller for callback
        col6.mint(seller, type(uint128).max);
        vm.startPrank(seller);
        col6.approve(address(callback), type(uint256).max);
        midnight.setIsAuthorized(address(callback), true, seller);
        vm.stopPrank();

        // Small callback collateral relative to capacity → health constrains
        uint256 cbCol = 10e6; // 10 USDC for full fill
        uint128 unitsCapacity = uint128(OFFER_SELLER_ASSETS);
        bytes32 group = _freshGroup();

        uint256[] memory offerAmounts = new uint256[](1);
        offerAmounts[0] = cbCol;
        bytes memory offerCbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: offerAmounts, offerSellerAssets: unitsCapacity, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory offer = Offer({
            market: obl6,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(callback),
            callbackData: offerCbData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: unitsCapacity,
            continuousFeeCap: type(uint256).max
        });

        bytes memory cd = abi.encode(SupplyCollateralCallbackClamp.ClampData({marketId: obl6Id, taker: lender}));

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "6-decimal health: should have units");
        assertTrue(maxUnits < uint256(unitsCapacity), "6-decimal: health should be binding");

        // Conservative debt-limit path: safe but not tight.
        Signature memory sig = _signOffer(offer, sellerSK);
        _verifySafetyOnly(maxUnits, offer, sig, lender);
    }

    /* ═══════ Faithful CallbackData decode ═══════ */

    /// @notice offerSellerAssets (not offer.maxAssets) is the pro-rata denominator the callback uses.
    /// @dev With offerSellerAssets < offer.maxAssets the callback pulls MORE collateral per unit than a
    ///      maxAssets-based clamp assumes, so a stale clamp over-sizes and take(maxUnits) reverts on the binding
    ///      collateral allowance. The clamp must size off offerSellerAssets so the boundary fill stays takeable.
    function test_decodeUsesOfferSellerAssetsDenominator() public {
        // Small collateral balance so the collateral pro-rata is the binding constraint.
        deal(address(collateralToken), seller, 50e18);
        vm.prank(seller);
        collateralToken.approve(address(callback), type(uint256).max);

        uint128 capacity = uint128(OFFER_SELLER_ASSETS); // offer.maxAssets = 1000e18
        uint256 offerSellerAssets = uint256(capacity) / 2; // callback denominator = 500e18 (pulls 2x per unit)
        bytes32 group = _freshGroup();

        Offer memory offer =
            _buildCapacityOffer(seller, capacity, TICK_HIGH, group, COLLATERAL_FOR_FULL_FILL, offerSellerAssets);
        bytes memory cd = _clampData();

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "denominator: should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        // Safety + tightness: take(maxUnits) succeeds and take(maxUnits + 1) reverts. A maxAssets-based clamp
        // over-sizes here and take(maxUnits) reverts.
        _verifyBoundary(
            maxUnits, offer, sig, lender, ITakeClamp(address(supplyCollateralCallbackClamp)), cd, false, false
        );
    }

    /// @notice offerSellerAssets == 0 makes the clamp return 0 (the callback reverts ZeroAmount in this mode).
    function test_decodeZeroOfferSellerAssetsReturnsZero() public {
        bytes32 group = _freshGroup();
        Offer memory offer =
            _buildCapacityOffer(seller, uint128(OFFER_SELLER_ASSETS), TICK_HIGH, group, COLLATERAL_FOR_FULL_FILL, 0);

        assertEq(supplyCollateralCallbackClamp.maxUnits(offer, _clampData()), 0, "offerSellerAssets==0: should be 0");
    }

    /// @notice maxBorrowCapacityUsage is read from the decoded CallbackData: a tight maxBorrowCapacityUsage binds below
    /// a loose one. @dev The clamp now decodes the full struct instead of slicing a fixed ABI offset, so
    /// maxBorrowCapacityUsage tracks the value
    ///      the callback enforces.
    function test_decodeMaxBorrowCapacityUsageCorrectWord() public {
        _depositCollateral(seller, 1e18, targetMarket);

        uint256 cbCollateral = 100e18;
        uint128 capacity = uint128(OFFER_SELLER_ASSETS);

        uint256 looseUnits = _maxUnitsForMaxBorrowCapacityUsage(cbCollateral, capacity, 0.95e18);
        uint256 tightUnits = _maxUnitsForMaxBorrowCapacityUsage(cbCollateral, capacity, 0.3e18);

        assertTrue(tightUnits > 0, "tight maxBorrowCapacityUsage: should have units");
        assertTrue(tightUnits < looseUnits, "tight maxBorrowCapacityUsage must bind below loose maxBorrowCapacityUsage");
    }

    function _maxUnitsForMaxBorrowCapacityUsage(uint256 cbCollateral, uint128 capacity, uint256 maxBorrowCapacityUsage)
        internal
        returns (uint256)
    {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = cbCollateral;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: amounts, offerSellerAssets: capacity, maxBorrowCapacityUsage: maxBorrowCapacityUsage
            })
        );

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: _freshGroup(),
            callback: address(callback),
            callbackData: cbData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: capacity,
            continuousFeeCap: type(uint256).max
        });

        return supplyCollateralCallbackClamp.maxUnits(offer, _buildClampData(cbCollateral, lender));
    }

    /// @notice CallbackData amounts longer than the market collaterals makes the clamp return 0 without reverting.
    /// @dev The callback itself reverts InvalidCollateral on a length mismatch, so the clamp degrades to 0 (CLAMP-3)
    ///      rather than indexing collateralParams out of bounds.
    function test_callbackAmountsLengthMismatchReturnsZero() public {
        // 2-slot amounts on the single-collateral targetMarket.
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = COLLATERAL_FOR_FULL_FILL;
        amounts[1] = COLLATERAL_FOR_FULL_FILL;

        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: amounts, offerSellerAssets: OFFER_SELLER_ASSETS, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: _freshGroup(),
            callback: address(callback),
            callbackData: cbData,
            receiverIfMakerIsSeller: seller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: uint128(OFFER_SELLER_ASSETS),
            continuousFeeCap: type(uint256).max
        });

        assertEq(
            supplyCollateralCallbackClamp.maxUnits(offer, _clampData()), 0, "length mismatch: clamp should return 0"
        );
    }

    /// @notice At price == 1 (units == sellerAssets, every step a ceil-bucket edge), the conservative debt-limit
    ///         quote is takeable: take(maxUnits) succeeds even in the worst case for ceil/floor bucket crossings that
    ///         the deleted _verifyForward shrink logic targeted.
    function test_debtLimitQuoteSafe_priceOne() public {
        _depositCollateral(seller, 1e18, targetMarket);

        // TICK_HIGH gives sellerPrice == WAD (price 1.0): the worst case for ceil/floor bucket crossings.
        uint256 cbCollateral = 100e18;
        uint128 capacity = uint128(OFFER_SELLER_ASSETS);
        bytes32 group = _freshGroup();

        Offer memory offer = _buildSellerAssetsOffer(seller, capacity, TICK_HIGH, group, cbCollateral);
        bytes memory cd = _buildClampData(cbCollateral, lender);

        uint256 maxUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "fixed point: should have units");

        // Safety only: take(maxUnits) succeeds. The conservative debt-limit path is not tight.
        Signature memory sig = _signOffer(offer, sellerSK);
        _verifySafetyOnly(maxUnits, offer, sig, lender);
    }
}
