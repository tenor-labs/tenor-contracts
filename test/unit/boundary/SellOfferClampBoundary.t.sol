// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {SellOfferClamp} from "../../../src/router/clamps/SellOfferClamp.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {creditAfterSlashing} from "../../helpers/CreditHelper.sol";

/// @title SellOfferClampBoundary
/// @notice Deterministic boundary tests for SellOfferClamp
/// @dev Resell path: min(capacityToShares(remaining), sellerShares)
///      Borrow path: min(capacityToShares(remaining), debtToMaxShares(maxDebt - currentDebt))
contract SellOfferClampBoundary is BoundaryTestBase {
    uint256 private _groupNonce;

    // Fresh borrower for borrow-path tests
    address internal seller;
    uint256 internal sellerSK;

    function setUp() public override {
        super.setUp();

        (seller, sellerSK) = makeAddrAndKey("seller");

        vm.prank(seller);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seller);

        // Default: buyer (lender/taker) has huge balance + approval
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ═══════ Helpers ═══════ */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("sellBoundary", ++_groupNonce));
    }

    function _buildSellOffer(address maker, uint128 unitsCapacity, uint16 tick, bytes32 group)
        internal
        view
        returns (Offer memory)
    {
        return Offer({
            market: targetMarket,
            buy: false,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: maker,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: unitsCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _clampData() internal view returns (bytes memory) {
        return abi.encode(SellOfferClamp.SellOfferClampData({marketId: targetMarketId, taker: lender}));
    }

    /* ═══════ Resell: SellerShares binding ═══════ */

    function test_resell_bindingSellerShares() public {
        // Give reseller only 5e18 shares
        _setupLenderWithCredit(lender, 5e18, targetMarket, targetMarketId);

        loanToken.mint(borrower, type(uint128).max);
        vm.prank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);

        // Offer capacity is huge — sellerShares is binding
        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(lender, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = abi.encode(SellOfferClamp.SellOfferClampData({marketId: targetMarketId, taker: borrower}));

        uint256 maxUnits = sellOfferClamp.maxUnits(offer, cd);
        uint256 sellerShares = creditAfterSlashing(midnight, targetMarketId, lender);
        assertEq(maxUnits, sellerShares, "resell: maxUnits == sellerShares");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(sellOfferClamp)), cd);
    }

    /* ═══════ Borrow: Health headroom ═══════ */

    function test_borrow_bindingHealth_fresh() public {
        // Small collateral so health is binding
        // 1 collateral token = 10 loan tokens (oracle 10e36), lltv 0.945
        // maxDebt = 1e18 * 10e36 / 1e36 * 0.945e18 / 1e18 = 9.45e18
        _depositCollateral(seller, 1e18, targetMarket);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = sellOfferClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(sellOfferClamp)), _clampData());
    }

    /// @dev Bug: debtToMaxShares uses mulDivDownInverse (inverts floor) but take() uses
    ///      mulDivUp (ceiling) when buyerIsLender. Overshoot scales linearly with ratio R:
    ///      k=0 at 1:1, k=1 at 99:100, k=2 at 1:2, etc.
    ///      Fix: https://github.com/Shippooor-Labs/tenor-morpho-v2-contracts-2/issues/160
    function test_borrow_bindingHealth_1to2() public {
        _setTotalUnits(targetMarketId, 100e18);
        _depositCollateral(seller, 1e18, targetMarket);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = sellOfferClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(sellOfferClamp)), _clampData());
    }

    /// @dev Bug: debtToMaxShares uses mulDivDownInverse (inverts floor) but take() uses
    ///      mulDivUp (ceiling) when buyerIsLender. Overshoot scales linearly with ratio R:
    ///      k=0 at 1:1, k=1 at 99:100, k=2 at 1:2, etc.
    ///      Fix: https://github.com/Shippooor-Labs/tenor-morpho-v2-contracts-2/issues/160
    function test_borrow_bindingHealth_99to100() public {
        _setTotalUnits(targetMarketId, 99e18);
        _depositCollateral(seller, 1e18, targetMarket);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = sellOfferClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(sellOfferClamp)), _clampData());
    }

    /* ═══════ Borrow: Edge cases ═══════ */

    /// @notice Seller nearly at maxDebt — tiny headroom, clamp returns small value
    function test_borrow_nearMaxDebt() public {
        // 1e18 collateral → maxDebt ≈ 9.5e18 units
        _depositCollateral(seller, 1e18, targetMarket);

        // Borrow most of the headroom via a direct SELL offer (no callback = no extra collateral)
        bytes32 setupGroup = _freshGroup();
        Offer memory setupOffer = _buildSellOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, setupGroup);
        Signature memory setupSig = _signOffer(setupOffer, sellerSK);
        bytes32 root = HashLib.hashOffer(setupOffer);

        // Take 9e18 units worth of shares — uses most of the 9.5e18 headroom
        uint256 unitsToTake = 9e18;
        vm.prank(lender);
        midnight.take(
            setupOffer,
            abi.encode(setupSig, root, uint256(0), new bytes32[](0)),
            unitsToTake,
            lender,
            address(0),
            address(0),
            ""
        );

        // Now seller has ~9e18 debt, maxDebt ≈ 9.5e18 — ~0.5e18 headroom
        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        uint256 maxUnits = sellOfferClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0 && maxUnits < 1e18, "near-max-debt: maxUnits should be small but non-zero");
    }

    /// @notice No collateral means zero maxDebt — clamp returns 0
    function test_borrow_zeroCollateral() public {
        // Seller has no collateral — maxDebt = 0
        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = sellOfferClamp.maxUnits(offer, _clampData());
        assertEq(maxUnits, 0, "zero collateral: maxUnits should be 0");
    }
}
