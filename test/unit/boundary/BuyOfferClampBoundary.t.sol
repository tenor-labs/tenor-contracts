// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {BuyOfferClamp} from "../../../src/router/clamps/BuyOfferClamp.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";

/// @title BuyOfferClampBoundary
/// @notice Deterministic boundary tests for BuyOfferClamp
/// @dev Min chain: min(capacityToShares(remaining), assetsToBuyerShares(min(balance, allowance)),
/// debtToMaxShares(buyerDebt))
contract BuyOfferClampBoundary is BoundaryTestBase {
    uint256 private _groupNonce;

    function setUp() public override {
        super.setUp();

        // Default: lender (maker) has huge balance, borrower (taker) has massive collateral
        loanToken.mint(lender, type(uint128).max);
        _depositCollateral(borrower, 1e38, targetMarket);

        // Default: lender approves Midnight
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ═══════ Helpers ═══════ */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("buyBoundary", ++_groupNonce));
    }

    function _buildBuyOffer(uint128 unitsCapacity, uint16 tick, bytes32 group) internal view returns (Offer memory) {
        return Offer({
            market: targetMarket,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: unitsCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _clampData() internal view returns (bytes memory) {
        return abi.encode(BuyOfferClamp.BuyOfferClampData({marketId: targetMarketId, taker: borrower}));
    }

    /* ═══════ Balance binding ═══════ */

    function test_bindingBalance_fresh() public {
        // Reset lender balance to a small amount
        deal(address(loanToken), lender, 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(type(uint128).max - uint128(SEED_AMOUNT), TICK_HIGH, group);
        uint256 maxUnits = buyOfferClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(buyOfferClamp)), _clampData());
    }

    /// @notice At 1:2 ratio (units < shares due to bad debt), clamp is tight.
    function test_bindingBalance_1to2() public {
        _setTotalUnits(targetMarketId, 100e18);
        deal(address(loanToken), lender, 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(type(uint128).max - uint128(SEED_AMOUNT), TICK_HIGH, group);
        uint256 maxUnits = buyOfferClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(buyOfferClamp)), _clampData());
    }

    /// @notice At 99:100 ratio (units < shares due to bad debt), clamp is tight.
    function test_bindingBalance_99to100() public {
        _setTotalUnits(targetMarketId, 99e18);
        deal(address(loanToken), lender, 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(type(uint128).max - uint128(SEED_AMOUNT), TICK_HIGH, group);
        uint256 maxUnits = buyOfferClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(buyOfferClamp)), _clampData());
    }

    /* ═══════ Allowance binding ═══════ */

    function test_bindingAllowance_fresh() public {
        // Set allowance to a small amount
        vm.prank(lender);
        loanToken.approve(address(midnight), 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(type(uint128).max - uint128(SEED_AMOUNT), TICK_HIGH, group);
        uint256 maxUnits = buyOfferClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(buyOfferClamp)), _clampData());
    }

    /// @notice At 1:2 ratio (units < shares due to bad debt), clamp is tight.
    function test_bindingAllowance_1to2() public {
        _setTotalUnits(targetMarketId, 100e18);
        vm.prank(lender);
        loanToken.approve(address(midnight), 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(type(uint128).max - uint128(SEED_AMOUNT), TICK_HIGH, group);
        uint256 maxUnits = buyOfferClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(buyOfferClamp)), _clampData());
    }

    function test_bindingAllowance_99to100() public {
        _setTotalUnits(targetMarketId, 99e18);
        vm.prank(lender);
        loanToken.approve(address(midnight), 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(type(uint128).max - uint128(SEED_AMOUNT), TICK_HIGH, group);
        uint256 maxUnits = buyOfferClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(buyOfferClamp)), _clampData());
    }

    /* ═══════ Buyer debt (repay path) ═══════ */

    function test_bindingDebt_fresh() public {
        // Create a repayer with small debt — debt is the binding constraint
        (address repayer, uint256 repayerSK) = makeAddrAndKey("repayer");
        _setupBorrowerWithDebt(repayer, repayerSK, 10e18, targetMarket, targetMarketId);

        loanToken.mint(repayer, type(uint128).max);
        vm.prank(repayer);
        loanToken.approve(address(midnight), type(uint256).max);

        bytes32 group = _freshGroup();
        bytes memory cd = abi.encode(BuyOfferClamp.BuyOfferClampData({marketId: targetMarketId, taker: borrower}));

        Offer memory offer = Offer({
            market: targetMarket,
            buy: true,
            maker: repayer,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: true,
            maxUnits: MAX_OFFER_CAPACITY,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        uint256 maxUnits = buyOfferClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, repayerSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(buyOfferClamp)), cd);
    }

    function test_bindingDebt_1to2() public {
        _setTotalUnits(targetMarketId, 100e18);

        (address repayer, uint256 repayerSK) = makeAddrAndKey("repayer2to1");
        _setupBorrowerWithDebt(repayer, repayerSK, 10e18, targetMarket, targetMarketId);

        loanToken.mint(repayer, type(uint128).max);
        vm.prank(repayer);
        loanToken.approve(address(midnight), type(uint256).max);

        // Re-set ratio after debt setup (which changes totals)
        _setTotalUnits(targetMarketId, 100e18);

        bytes32 group = _freshGroup();
        bytes memory cd = abi.encode(BuyOfferClamp.BuyOfferClampData({marketId: targetMarketId, taker: borrower}));

        Offer memory offer = Offer({
            market: targetMarket,
            buy: true,
            maker: repayer,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: true,
            maxUnits: MAX_OFFER_CAPACITY,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        uint256 maxUnits = buyOfferClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, repayerSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(buyOfferClamp)), cd);
    }

    function test_bindingDebt_99to100() public {
        _setTotalUnits(targetMarketId, 99e18);

        (address repayer, uint256 repayerSK) = makeAddrAndKey("repayer100to99");
        _setupBorrowerWithDebt(repayer, repayerSK, 10e18, targetMarket, targetMarketId);

        loanToken.mint(repayer, type(uint128).max);
        vm.prank(repayer);
        loanToken.approve(address(midnight), type(uint256).max);

        _setTotalUnits(targetMarketId, 99e18);

        bytes32 group = _freshGroup();
        bytes memory cd = abi.encode(BuyOfferClamp.BuyOfferClampData({marketId: targetMarketId, taker: borrower}));

        Offer memory offer = Offer({
            market: targetMarket,
            buy: true,
            maker: repayer,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: true,
            maxUnits: MAX_OFFER_CAPACITY,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        uint256 maxUnits = buyOfferClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, repayerSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(buyOfferClamp)), cd);
    }
}
