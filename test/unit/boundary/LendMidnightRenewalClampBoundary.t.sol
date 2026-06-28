// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {LendMidnightRenewalClamp} from "../../../src/router/clamps/LendMidnightRenewalClamp.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {LendMidnightRenewalCallback} from "@callbacks/LendMidnightRenewalCallback.sol";
import {ILendMidnightRenewalCallback} from "@callbacks/interfaces/ILendMidnightRenewalCallback.sol";

/// @title LendMidnightRenewalClampBoundary
/// @notice Deterministic boundary tests for LendMidnightRenewalClamp
/// @dev Min chain: min(capacityToShares, maxSharesForBudget(withdrawable, feeRate))
///      BUY offers: buy=true, maker=lender(buyer), taker=borrower(seller)
///      Callback: LendMidnightRenewalCallback withdraws from source market to fund BUY on target
contract LendMidnightRenewalClampBoundary is BoundaryTestBase {
    uint256 private _groupNonce;

    /// @notice Callback contract for lend withdrawal renewals
    LendMidnightRenewalCallback internal lendCallback;

    /// @notice Fee recipient for callback fees
    address internal feeRecipient;

    function setUp() public override {
        super.setUp();

        feeRecipient = makeAddr("feeRecipient");

        // Deploy callback
        lendCallback = new LendMidnightRenewalCallback(address(midnight));

        // Borrower (taker/seller): unlimited collateral on target market for health
        collateralToken.mint(borrower, type(uint128).max);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(targetMarket, 0, 1e38, borrower);
        vm.stopPrank();
    }

    /* ═══════ Helpers ═══════ */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("v2v2LendWdBoundary", ++_groupNonce));
    }

    /// @notice Build a BUY offer on the target market with the lend callback
    function _buildBuyOffer(address maker, uint128 unitsCapacity, uint16 tick, bytes32 group, uint256 feeRate)
        internal
        view
        returns (Offer memory)
    {
        ILendMidnightRenewalCallback.CallbackData memory cbData = ILendMidnightRenewalCallback.CallbackData({
            sourceMarket: sourceMarket, feeRate: feeRate, feeRecipient: feeRecipient, tick: tick
        });

        return Offer({
            market: targetMarket,
            buy: true,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(lendCallback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(0),
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
            LendMidnightRenewalClamp.LendMidnightRenewalClampData({
                sourceMarketId: sourceMarketId,
                targetMarketId: targetMarketId,
                positionOwner: positionOwner,
                feeRate: feeRate
            })
        );
    }

    /// @notice Setup a fresh lender with source credit and authorized callback.
    ///         Also ensures the source market has enough withdrawable liquidity
    ///         for the callback to withdraw from.
    function _setupFreshLender(uint128 sourceCredit) internal returns (address freshLender, uint256 freshLenderSK) {
        (freshLender, freshLenderSK) = makeAddrAndKey(string(abi.encodePacked("freshLender", _groupNonce)));

        // Give lender credit on source market
        _setupLenderWithCredit(freshLender, sourceCredit, sourceMarket, sourceMarketId);

        // Ensure the source market has enough withdrawable liquidity.
        // _setupLenderWithCredit creates debt (tempBorrower borrows from freshLender), which
        // sends loanToken to the borrower. The market's `withdrawable` field remains 0.
        // We need to set it so the callback's withdraw() can succeed.
        _ensureSourceWithdrawable(sourceCredit);

        // Authorize callback to withdraw from source on behalf of lender
        vm.startPrank(freshLender);
        midnight.setIsAuthorized(address(lendCallback), true, freshLender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshLender);
        vm.stopPrank();
    }

    /// @notice Ensure the source market has enough withdrawable liquidity.
    ///         Sets the `withdrawable` storage field and mints loanToken to Midnight.
    function _ensureSourceWithdrawable(uint128 amount) internal {
        // MarketState storage layout (mapping at slot 1):
        //   slot 0 (base): totalUnits (128 bits, lower)
        //   slot 1 (base+1): withdrawable (uint256)
        bytes32 baseSlot = keccak256(abi.encode(sourceMarketId, uint256(1)));
        bytes32 withdrawableSlot = bytes32(uint256(baseSlot) + 1);

        // Read current withdrawable and add the needed amount
        uint256 currentWithdrawable = uint256(vm.load(address(midnight), withdrawableSlot));
        uint256 newWithdrawable = currentWithdrawable + uint256(amount);
        vm.store(address(midnight), withdrawableSlot, bytes32(newWithdrawable));

        // Mint loanToken to Midnight so the transfer in withdraw() succeeds
        loanToken.mint(address(midnight), uint256(amount));
    }

    /* ═══════ Withdrawable, no fee ═══════ */

    /// @notice Withdrawable is binding, no fee
    function test_bindingWithdrawable_noFee() public {
        uint128 sourceCredit = 10e18; // Small source → withdrawable binds
        (address freshLender, uint256 freshLenderSK) = _setupFreshLender(sourceCredit);

        bytes32 group = _freshGroup();
        uint256 feeRate = 0;

        Offer memory offer = _buildBuyOffer(freshLender, MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _buildClampData(freshLender, feeRate);
        uint256 maxUnits = lendMidnightRenewalClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, freshLenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendMidnightRenewalClamp)), cd);
    }

    /* ═══════ Withdrawable, 10% fee ═══════ */

    /// @notice Withdrawable is binding, 10% fee
    function test_bindingWithdrawable_withFee() public {
        uint128 sourceCredit = 10e18;
        (address freshLender, uint256 freshLenderSK) = _setupFreshLender(sourceCredit);

        bytes32 group = _freshGroup();
        uint256 feeRate = 0.1e18; // 10% fee

        Offer memory offer = _buildBuyOffer(freshLender, MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _buildClampData(freshLender, feeRate);
        uint256 maxUnits = lendMidnightRenewalClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, freshLenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendMidnightRenewalClamp)), cd);
    }

    /* ═══════ Withdrawable, max fee (50%) ═══════ */

    /// @notice Withdrawable is binding, max fee (50%)
    function test_bindingWithdrawable_maxFee() public {
        uint128 sourceCredit = 10e18;
        (address freshLender, uint256 freshLenderSK) = _setupFreshLender(sourceCredit);

        bytes32 group = _freshGroup();
        uint256 feeRate = 0.5e18; // 50% fee

        Offer memory offer = _buildBuyOffer(freshLender, MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _buildClampData(freshLender, feeRate);
        uint256 maxUnits = lendMidnightRenewalClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, freshLenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendMidnightRenewalClamp)), cd);
    }

    /* ═══════ Withdrawable, 100% fee (feeRate = WAD) ═══════ */

    /// @notice Withdrawable is binding, 100% fee
    function test_bindingWithdrawable_100fee() public {
        uint128 sourceCredit = 10e18;
        (address freshLender, uint256 freshLenderSK) = _setupFreshLender(sourceCredit);

        bytes32 group = _freshGroup();
        uint256 feeRate = 1e18; // 100%

        Offer memory offer = _buildBuyOffer(freshLender, MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _buildClampData(freshLender, feeRate);
        uint256 maxUnits = lendMidnightRenewalClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, freshLenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendMidnightRenewalClamp)), cd);
    }

    /* ═══════ Self-renewal ═══════ */

    /// @notice Self-renewal (source == target) always returns 0
    function test_selfRenewal_returnsZero() public {
        uint128 sourceCredit = 10e18;
        // Setup lender with credit on the TARGET market (to simulate source == target)
        (address freshLender,) = makeAddrAndKey("selfRenewalLender");
        _setupLenderWithCredit(freshLender, sourceCredit, targetMarket, targetMarketId);

        vm.startPrank(freshLender);
        midnight.setIsAuthorized(address(lendCallback), true, freshLender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshLender);
        vm.stopPrank();

        bytes32 group = _freshGroup();

        ILendMidnightRenewalCallback.CallbackData memory cbData = ILendMidnightRenewalCallback.CallbackData({
            sourceMarket: targetMarket, // source == target
            feeRate: 0,
            feeRecipient: feeRecipient,
            tick: TICK_HIGH
        });

        Offer memory offer = Offer({
            market: targetMarket,
            buy: true,
            maker: freshLender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(lendCallback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: MAX_OFFER_CAPACITY,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        // Clamp data with source == target
        bytes memory cd = abi.encode(
            LendMidnightRenewalClamp.LendMidnightRenewalClampData({
                sourceMarketId: targetMarketId, targetMarketId: targetMarketId, positionOwner: freshLender, feeRate: 0
            })
        );

        uint256 maxUnits = lendMidnightRenewalClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "self-renewal should return 0");
    }

    /* ═══════ reduceOnly ═══════ */

    /// @notice reduceOnly=true returns 0 when maker has no debt on target market
    /// @dev BUY offer on TARGET: reduceOnly caps by buyer's debt on target.
    ///      In a normal renewal the buyer (lender) has source credit but no target debt,
    ///      so reduceOnly → 0.
    function test_reduceOnly_noTargetDebt_returnsZero() public {
        uint128 sourceCredit = 10e18;
        (address freshLender,) = _setupFreshLender(sourceCredit);

        bytes32 group = _freshGroup();
        uint256 feeRate = 0;

        Offer memory offer = _buildBuyOffer(freshLender, MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        offer.reduceOnly = true;

        bytes memory cd = _buildClampData(freshLender, feeRate);
        uint256 maxUnits = lendMidnightRenewalClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "reduceOnly with no target debt should return 0");
    }

    /* ═══════ Zero source credit ═══════ */

    /// @notice Zero source credit always returns 0
    function test_zeroSourceCredit_returnsZero() public {
        (address emptyLender,) = makeAddrAndKey("emptyLender");

        bytes32 group = _freshGroup();
        uint256 feeRate = 0;

        ILendMidnightRenewalCallback.CallbackData memory cbData = ILendMidnightRenewalCallback.CallbackData({
            sourceMarket: sourceMarket, feeRate: feeRate, feeRecipient: feeRecipient, tick: TICK_HIGH
        });

        Offer memory offer = Offer({
            market: targetMarket,
            buy: true,
            maker: emptyLender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(lendCallback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: MAX_OFFER_CAPACITY,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes memory cd = _buildClampData(emptyLender, feeRate);
        uint256 maxUnits = lendMidnightRenewalClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "zero source credit should return 0");
    }
}
