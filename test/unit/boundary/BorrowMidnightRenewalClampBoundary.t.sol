// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {BorrowMidnightRenewalClamp} from "../../../src/router/clamps/BorrowMidnightRenewalClamp.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {BorrowMidnightRenewalCallback} from "@callbacks/BorrowMidnightRenewalCallback.sol";
import {IBorrowMidnightRenewalCallback} from "@callbacks/interfaces/IBorrowMidnightRenewalCallback.sol";

/// @title BorrowMidnightRenewalClampBoundary
/// @notice Deterministic boundary tests for BorrowMidnightRenewalClamp
/// @dev Min chain: min(capacityToShares, maxSharesForBudget(sourceDebt, feeRate))
///      SELL offers on TARGET market for cross-market borrow renewals.
///      Maker (seller) has debt on SOURCE market.
///      Health NOT checked by clamp (may cause Midnight health revert).
contract BorrowMidnightRenewalClampBoundary is BoundaryTestBase {
    uint256 private _groupNonce;

    /// @notice Renewal callback contract
    BorrowMidnightRenewalCallback internal renewalCallback;

    /// @notice Fee recipient
    address internal feeRecipient;

    function setUp() public override {
        super.setUp();

        // Deploy renewal callback
        renewalCallback = new BorrowMidnightRenewalCallback(address(midnight));

        // Fee recipient
        feeRecipient = makeAddr("feeRecipient");

        // Lender (taker): unlimited balance and approval
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ═══════ Helpers ═══════ */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("v2v2BorrowBoundary", ++_groupNonce));
    }

    /// @notice Setup a fresh borrower with source debt and authorize the renewal callback
    function _setupBorrowerForRenewal(uint128 debtUnits)
        internal
        returns (address freshBorrower, uint256 freshBorrowerSK)
    {
        (freshBorrower, freshBorrowerSK) = makeAddrAndKey(string(abi.encodePacked("v2v2Borrower", _groupNonce)));
        _setupBorrowerWithDebt(freshBorrower, freshBorrowerSK, debtUnits, sourceMarket, sourceMarketId);

        // Authorize callback and approve loan token transfers
        vm.startPrank(freshBorrower);
        midnight.setIsAuthorized(address(renewalCallback), true, freshBorrower);
        vm.stopPrank();
    }

    /// @notice Build offer callback data
    function _buildCallbackData(uint256 feeRate, uint16 tick) internal view returns (bytes memory) {
        return abi.encode(
            IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: feeRate, feeRecipient: feeRecipient, tick: tick
            })
        );
    }

    /// @notice Build a SELL offer on targetMarket for borrow renewal
    function _buildSellOffer(address maker, uint128 unitsCapacity, uint16 tick, bytes32 group, uint256 feeRate)
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
            callback: address(renewalCallback),
            callbackData: _buildCallbackData(feeRate, tick),
            receiverIfMakerIsSeller: address(renewalCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: unitsCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    /// @notice Build clamp data
    function _buildClampData(address positionOwner, uint256 feeRate) internal view returns (bytes memory) {
        return abi.encode(
            BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData({
                sourceMarketId: sourceMarketId,
                targetMarketId: targetMarketId,
                positionOwner: positionOwner,
                feeRate: feeRate
            })
        );
    }

    /* ═══════ Source debt binding, no fee ═══════ */

    /// @notice Source debt is binding (no fee)
    function test_bindingSourceDebt_noFee() public {
        uint128 smallDebt = 10e18;
        bytes32 group = _freshGroup();

        (address freshBorrower, uint256 freshBorrowerSK) = _setupBorrowerForRenewal(smallDebt);

        // Huge capacity so source debt is the bottleneck
        Offer memory offer = _buildSellOffer(freshBorrower, MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);
        bytes memory cd = _buildClampData(freshBorrower, 0);
        uint256 maxUnits = borrowMidnightRenewalClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowMidnightRenewalClamp)), cd);
    }

    /* ═══════ Source debt binding, 10% fee ═══════ */

    /// @notice Source debt is binding (10% fee)
    function test_bindingSourceDebt_withFee() public {
        uint256 feeRate = 0.1e18; // 10%
        uint128 smallDebt = 10e18;
        bytes32 group = _freshGroup();

        (address freshBorrower, uint256 freshBorrowerSK) = _setupBorrowerForRenewal(smallDebt);

        Offer memory offer = _buildSellOffer(freshBorrower, MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _buildClampData(freshBorrower, feeRate);
        uint256 maxUnits = borrowMidnightRenewalClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowMidnightRenewalClamp)), cd);
    }

    /* ═══════ Source debt binding, max fee (50%) ═══════ */

    /// @notice Source debt is binding (50% max fee)
    function test_bindingSourceDebt_maxFee() public {
        uint256 feeRate = 0.5e18; // 50% (MAX_FEE_RATE from ClampFuzzFixtures)
        uint128 smallDebt = 10e18;
        bytes32 group = _freshGroup();

        (address freshBorrower, uint256 freshBorrowerSK) = _setupBorrowerForRenewal(smallDebt);

        Offer memory offer = _buildSellOffer(freshBorrower, MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _buildClampData(freshBorrower, feeRate);
        uint256 maxUnits = borrowMidnightRenewalClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowMidnightRenewalClamp)), cd);
    }

    /* ═══════ Source debt binding, 100% fee (feeRate = WAD) ═══════ */

    /// @notice Source debt is binding (100% fee)
    function test_bindingSourceDebt_100fee() public {
        uint256 feeRate = 1e18; // 100%
        uint128 smallDebt = 10e18;
        bytes32 group = _freshGroup();

        (address freshBorrower, uint256 freshBorrowerSK) = _setupBorrowerForRenewal(smallDebt);

        Offer memory offer = _buildSellOffer(freshBorrower, MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _buildClampData(freshBorrower, feeRate);
        uint256 maxUnits = borrowMidnightRenewalClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowMidnightRenewalClamp)), cd);
    }

    /* ═══════ Self-renewal guard ═══════ */

    /// @notice Self-renewal (source == target) returns 0
    function test_selfRenewal_returnsZero() public {
        uint128 smallDebt = 10e18;
        bytes32 group = _freshGroup();

        // Setup borrower with debt on sourceMarket
        (address freshBorrower,) = _setupBorrowerForRenewal(smallDebt);

        // Build offer on targetMarket but clamp data points source == target
        Offer memory offer = _buildSellOffer(freshBorrower, MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);

        // Clamp data with sourceMarketId == targetMarketId (self-renewal)
        bytes memory cd = abi.encode(
            BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData({
                sourceMarketId: targetMarketId, targetMarketId: targetMarketId, positionOwner: freshBorrower, feeRate: 0
            })
        );

        uint256 maxUnits = borrowMidnightRenewalClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "self-renewal should return zero");
    }

    /* ═══════ reduceOnly ═══════ */

    /// @notice reduceOnly=true returns 0 when maker has no credit on target market
    /// @dev SELL offer on TARGET: reduceOnly caps by seller's credit on target.
    ///      In a normal renewal the seller has source debt but no target credit,
    ///      so reduceOnly → 0.
    function test_reduceOnly_noTargetCredit_returnsZero() public {
        uint128 smallDebt = 10e18;
        bytes32 group = _freshGroup();

        // Borrower has source debt but NO credit on target market
        (address freshBorrower,) = _setupBorrowerForRenewal(smallDebt);

        Offer memory offer = _buildSellOffer(freshBorrower, MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);
        offer.reduceOnly = true;

        bytes memory cd = _buildClampData(freshBorrower, 0);
        uint256 maxUnits = borrowMidnightRenewalClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "reduceOnly with no target credit should return 0");
    }

    /* ═══════ Zero source debt ═══════ */

    /// @notice Zero source debt returns 0
    function test_zeroSourceDebt_returnsZero() public {
        bytes32 group = _freshGroup();

        // Borrower with NO debt on source market
        (address emptyBorrower,) = makeAddrAndKey("emptyBorrower");

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: emptyBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(renewalCallback),
            callbackData: _buildCallbackData(0, TICK_HIGH),
            receiverIfMakerIsSeller: address(renewalCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: MAX_OFFER_CAPACITY,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes memory cd = _buildClampData(emptyBorrower, 0);
        uint256 maxUnits = borrowMidnightRenewalClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "zero source debt should return zero");
    }
}
