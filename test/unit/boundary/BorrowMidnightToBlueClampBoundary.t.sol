// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {BorrowMidnightToBlueClamp} from "../../../src/router/clamps/BorrowMidnightToBlueClamp.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {IBorrowMidnightToBlueCallback} from "@callbacks/interfaces/IBorrowMidnightToBlueCallback.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {Id, MarketParams} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";

/// @title BorrowMidnightToBlueClampBoundary
/// @notice Deterministic boundary tests for BorrowMidnightToBlueClamp
/// @dev Min chain: min(capacityToShares, debtToMaxShares(sourceDebt), assetsToBuyerShares(effectiveBudget))
///      BUY offers on SOURCE market for Midnight to Blue borrow exit.
///      Maker (borrower) has debt on SOURCE (Midnight) market and buys it back.
///      Taker (lender) provides loan tokens.
///      effectiveBudget = availableLiquidity * WAD / (WAD + feeRate)
///      availableLiquidity = Blue totalSupplyAssets - totalBorrowAssets
contract BorrowMidnightToBlueClampBoundary is BoundaryTestBase {
    using MarketParamsLib for MarketParams;

    uint256 private _groupNonce;

    /// @notice Blue market ID for clamp data
    bytes32 internal blueTargetMarket;

    function setUp() public override {
        super.setUp();

        blueTargetMarket = bytes32(Id.unwrap(blueMarketParams.id()));

        // Default: seed Blue market with large liquidity (1000e18 supply, 0 borrow)
        _setBlueMarketLiquidity(1000e18, 0);

        // Give borrower (maker) debt on source market
        _setupBorrowerWithDebt(borrower, borrowerSK, uint128(SEED_AMOUNT), sourceMarket, sourceMarketId);

        // Borrower (maker in BUY offer): needs loan tokens + approval to pay buyerAssets
        loanToken.mint(borrower, type(uint128).max);
        vm.prank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);

        // Authorize borrowMidnightToBlueCallback for the borrower:
        // - On Midnight: callback needs to withdrawCollateral on behalf of borrower
        // - On MorphoBlue: callback needs to borrow on behalf of borrower
        vm.startPrank(borrower);
        midnight.setIsAuthorized(address(borrowMidnightToBlueCallback), true, borrower);
        morphoBlue.setAuthorization(address(borrowMidnightToBlueCallback), true);
        vm.stopPrank();

        // Lender (taker): needs collateral deposited on source market
        _depositCollateral(lender, 1e38, sourceMarket);
    }

    /* ═══════ Helpers ═══════ */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("v2v1BorrowBoundary", ++_groupNonce));
    }

    /// @notice Fee recipient address for fee tests
    address internal constant FEE_RECIPIENT = address(0xFEE);

    /// @notice Encode callback data for borrowMidnightToBlueCallback with fee
    function _callbackData(uint256 feeRate) internal view returns (bytes memory) {
        return abi.encode(
            IBorrowMidnightToBlueCallback.CallbackData({
                targetMarketParams: blueMarketParams,
                feeRate: feeRate,
                feeRecipient: feeRate > 0 ? FEE_RECIPIENT : address(0)
            })
        );
    }

    /// @notice Encode callback data for borrowMidnightToBlueCallback with no fee
    function _callbackData() internal view returns (bytes memory) {
        return _callbackData(0);
    }

    function _buildBuyOffer(address maker, uint128 unitsCapacity, uint16 tick, bytes32 group)
        internal
        view
        returns (Offer memory)
    {
        return Offer({
            market: sourceMarket,
            buy: true,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(borrowMidnightToBlueCallback),
            callbackData: _callbackData(),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: true,
            maxUnits: unitsCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _buildBuyOffer(address maker, uint128 unitsCapacity, uint16 tick, bytes32 group, uint256 feeRate)
        internal
        view
        returns (Offer memory)
    {
        return Offer({
            market: sourceMarket,
            buy: true,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(borrowMidnightToBlueCallback),
            callbackData: _callbackData(feeRate),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: true,
            maxUnits: unitsCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _clampData(address positionOwner, uint256 feeRate) internal view returns (bytes memory) {
        return abi.encode(
            BorrowMidnightToBlueClamp.BorrowMidnightToBlueClampData({
                sourceMarketId: sourceMarketId,
                targetBlueMarketId: blueTargetMarket,
                positionOwner: positionOwner,
                feeRate: feeRate
            })
        );
    }

    function _clampData(address positionOwner) internal view returns (bytes memory) {
        return _clampData(positionOwner, 0);
    }

    /// @notice Borrow from Blue market to reduce available liquidity
    function _reduceBlueLiquidity(uint256 borrowAmount) internal {
        uint256 collateralNeeded = borrowAmount * 10;
        collateralToken.mint(address(this), collateralNeeded);
        collateralToken.approve(address(morphoBlue), collateralNeeded);
        morphoBlue.supplyCollateral(blueMarketParams, collateralNeeded, address(this), "");
        morphoBlue.borrow(blueMarketParams, borrowAmount, 0, address(this), address(this));
    }

    /// @notice Setup a fresh borrower with source debt and loan token balance/approval for BUY offer
    function _setupFreshBorrowerForBuy(string memory name, uint128 debtUnits)
        internal
        returns (address freshBorrower, uint256 freshBorrowerSK)
    {
        (freshBorrower, freshBorrowerSK) = makeAddrAndKey(name);
        _setupBorrowerWithDebt(freshBorrower, freshBorrowerSK, debtUnits, sourceMarket, sourceMarketId);

        // BUY offer maker needs loan tokens + approval to pay buyerAssets
        loanToken.mint(freshBorrower, type(uint128).max);
        vm.startPrank(freshBorrower);
        loanToken.approve(address(midnight), type(uint256).max);
        // Authorize borrowMidnightToBlueCallback on Midnight and MorphoBlue
        midnight.setIsAuthorized(address(borrowMidnightToBlueCallback), true, freshBorrower);
        morphoBlue.setAuthorization(address(borrowMidnightToBlueCallback), true);
        vm.stopPrank();
    }

    /* ═══════ Source Midnight debt binding ═══════ */

    /// @notice Source debt is binding -- small debt, large capacity and liquidity
    function test_bindingSourceDebt() public {
        // Create a fresh borrower with small debt
        (address freshBorrower, uint256 freshBorrowerSK) = _setupFreshBorrowerForBuy("v2v1freshBorrower", 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(freshBorrower, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData(freshBorrower);

        uint256 maxUnits = borrowMidnightToBlueClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowMidnightToBlueClamp)), cd);
    }

    /* ═══════ Blue liquidity binding ═══════ */

    /// @notice Blue liquidity is binding -- small liquidity, large debt
    function test_bindingLiquidity() public {
        // setUp supplied 1000e18 to Blue. Borrow 995e18 to leave only 5e18 available.
        // Borrower has SEED_AMOUNT (100e18) Midnight debt, so liquidity (5e18) is binding.
        _reduceBlueLiquidity(995e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(borrower, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData(borrower);

        uint256 maxUnits = borrowMidnightToBlueClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, borrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowMidnightToBlueClamp)), cd);
    }

    /* ═══════ Blue liquidity + fee ═══════ */

    /// @notice Blue liquidity is binding with 1% fee -- effectiveBudget < availableLiquidity
    function test_bindingLiquidity_withFee() public {
        uint256 feeRate = 0.01e18; // 1% (max percentage fee rate)
        _reduceBlueLiquidity(995e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(borrower, MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _clampData(borrower, feeRate);

        uint256 maxUnits = borrowMidnightToBlueClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, borrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowMidnightToBlueClamp)), cd);
    }

    /* ═══════ Zero source debt ═══════ */

    /// @notice Zero source debt returns 0
    function test_zeroSourceDebt_returnsZero() public {
        // Use a borrower with NO debt on source market
        (address emptyBorrower,) = makeAddrAndKey("emptyBorrower");

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(emptyBorrower, MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = borrowMidnightToBlueClamp.maxUnits(offer, _clampData(emptyBorrower));
        assertEq(maxUnits, 0, "zero source debt should return zero");
    }

    /* ═══════ Debt + fee interaction ═══════ */

    /* ═══════ reduceOnly ═══════ */

    /// @notice reduceOnly=true caps by sourceDebt (already the binding constraint here)
    /// @dev BUY offer on source: reduceOnly prevents buyer from crossing debt→credit.
    ///      Since sourceDebt already caps the result, reduceOnly is redundant but confirmed.
    function test_reduceOnly_capsToSourceDebt() public {
        // Create a fresh borrower with small debt
        (address freshBorrower, uint256 freshBorrowerSK) = _setupFreshBorrowerForBuy("v2v1reduceOnlyBorrower", 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(freshBorrower, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        // offer already has reduceOnly: true from _buildBuyOffer
        bytes memory cd = _clampData(freshBorrower);

        uint256 maxUnits = borrowMidnightToBlueClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "reduceOnly with source debt should return > 0");

        // Compare with reduceOnly=false — should be the same since sourceDebt already caps
        Offer memory offerNoExit = _buildBuyOffer(freshBorrower, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        offerNoExit.reduceOnly = false;
        uint256 maxUnitsNoExit = borrowMidnightToBlueClamp.maxUnits(offerNoExit, cd);
        assertEq(maxUnits, maxUnitsNoExit, "reduceOnly should be redundant when sourceDebt caps");

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowMidnightToBlueClamp)), cd);
    }

    /* ═══════ Debt + fee interaction ═══════ */

    /// @notice Source debt is binding even with fee -- fee doesn't affect debt constraint
    function test_bindingSourceDebt_withFee() public {
        uint256 feeRate = 0.01e18; // 1% (max percentage fee rate)

        // Create a fresh borrower with small debt (debt is the bottleneck, not liquidity)
        (address freshBorrower, uint256 freshBorrowerSK) = _setupFreshBorrowerForBuy("v2v1BorrowerFee", 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(freshBorrower, MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _clampData(freshBorrower, feeRate);

        uint256 maxUnits = borrowMidnightToBlueClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        // Compare with no-fee version to verify fee doesn't change debt-binding result
        Offer memory offerNoFee = _buildBuyOffer(freshBorrower, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cdNoFee = _clampData(freshBorrower, 0);
        uint256 maxUnitsNoFee = borrowMidnightToBlueClamp.maxUnits(offerNoFee, cdNoFee);
        // When debt is binding, fee on liquidity doesn't matter -- both should give same result
        assertEq(maxUnits, maxUnitsNoFee, "debt-binding: fee should not affect result");

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowMidnightToBlueClamp)), cd);
    }
}
