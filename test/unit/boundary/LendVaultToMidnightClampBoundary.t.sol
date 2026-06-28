// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {LendVaultToMidnightClamp} from "../../../src/router/clamps/LendVaultToMidnightClamp.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {ILendVaultToMidnightCallback} from "@callbacks/interfaces/ILendVaultToMidnightCallback.sol";

/// @title LendVaultToMidnightClampBoundary
/// @notice Deterministic boundary tests for LendVaultToMidnightClamp
/// @dev Min chain: min(capacityToShares, assetsToBuyerShares(vaultLiquidity))
contract LendVaultToMidnightClampBoundary is BoundaryTestBase {
    uint256 private _groupNonce;

    function setUp() public override {
        super.setUp();

        // Buyer (maker) needs loan tokens
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        // Taker (borrower/seller) needs collateral on target
        _depositCollateral(borrower, 1e38, targetMarket);

        // Lender owns vault shares (the clamp checks maxWithdraw(offer.maker))
        loanToken.mint(address(this), 1000e18);
        loanToken.approve(address(vault), 1000e18);
        vault.deposit(1000e18, lender);

        // Lender approves callback to spend vault shares
        vm.prank(lender);
        vault.approve(address(lendVaultToMidnightCallback), type(uint256).max);
    }

    /* ═══════ Helpers ═══════ */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("v1v2LendBoundary", ++_groupNonce));
    }

    function _callbackData() internal view returns (bytes memory) {
        return _callbackData(0);
    }

    function _callbackData(uint256 feeRate) internal view returns (bytes memory) {
        return abi.encode(
            ILendVaultToMidnightCallback.CallbackData({
                vault: address(vault),
                feeRate: feeRate,
                feeRecipient: address(this),
                tick: TICK_HIGH,
                morphoBlueMarketId: bytes32(0)
            })
        );
    }

    function _buildBuyOffer(uint128 unitsCapacity, uint16 tick, bytes32 group) internal view returns (Offer memory) {
        return _buildBuyOffer(unitsCapacity, tick, group, 0);
    }

    function _buildBuyOffer(uint128 unitsCapacity, uint16 tick, bytes32 group, uint256 feeRate)
        internal
        view
        returns (Offer memory)
    {
        return Offer({
            market: targetMarket,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(lendVaultToMidnightCallback),
            callbackData: _callbackData(feeRate),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: unitsCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _clampData() internal view returns (bytes memory) {
        return _clampData(0);
    }

    function _clampData(uint256 feeRate) internal view returns (bytes memory) {
        return abi.encode(
            LendVaultToMidnightClamp.LendVaultToMidnightClampData({
                sourceVault: address(vault),
                marketId: targetMarketId,
                positionOwner: lender,
                feeRate: feeRate,
                vaultType: LendVaultToMidnightClamp.VaultType.ERC4626,
                morphoBlueMarketId: bytes32(0)
            })
        );
    }

    /// @dev Reduce lender's vault shares so maxWithdraw(lender) == targetAssets.
    ///      Redeems the excess shares, sending loan tokens back to address(this).
    function _limitVaultLiquidity(uint256 targetAssets) internal {
        uint256 currentMax = vault.maxWithdraw(lender);
        if (currentMax > targetAssets) {
            uint256 excess = currentMax - targetAssets;
            vm.prank(lender);
            vault.withdraw(excess, address(this), lender);
        }
    }

    /* ═══════ Vault liquidity binding ═══════ */

    function test_bindingVaultLiquidity_fresh() public {
        _limitVaultLiquidity(5e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendVaultToMidnightClamp)), _clampData());
    }

    function test_bindingVaultLiquidity_1to2() public {
        _setTotalUnits(targetMarketId, 100e18);
        _limitVaultLiquidity(5e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendVaultToMidnightClamp)), _clampData());
    }

    function test_bindingVaultLiquidity_99to100() public {
        _setTotalUnits(targetMarketId, 99e18);
        _limitVaultLiquidity(5e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendVaultToMidnightClamp)), _clampData());
    }

    /* ═══════ Vault liquidity binding, with fee (10%) ═══════ */

    function test_bindingVaultLiquidity_withFee_fresh() public {
        _limitVaultLiquidity(5e18);
        uint256 feeRate = 0.1e18;

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _clampData(feeRate);

        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendVaultToMidnightClamp)), cd);
    }

    function test_bindingVaultLiquidity_withFee_1to2() public {
        _setTotalUnits(targetMarketId, 100e18);
        _limitVaultLiquidity(5e18);
        uint256 feeRate = 0.1e18;

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _clampData(feeRate);

        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendVaultToMidnightClamp)), cd);
    }

    function test_bindingVaultLiquidity_withFee_99to100() public {
        _setTotalUnits(targetMarketId, 99e18);
        _limitVaultLiquidity(5e18);
        uint256 feeRate = 0.1e18;

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _clampData(feeRate);

        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendVaultToMidnightClamp)), cd);
    }

    /* ═══════ Vault liquidity binding, max fee (50%) ═══════ */

    function test_bindingVaultLiquidity_maxFee() public {
        _limitVaultLiquidity(5e18);
        uint256 feeRate = 0.5e18;

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _clampData(feeRate);

        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendVaultToMidnightClamp)), cd);
    }

    function test_bindingVaultLiquidity_maxFee_1to2() public {
        _setTotalUnits(targetMarketId, 100e18);
        _limitVaultLiquidity(5e18);
        uint256 feeRate = 0.5e18;

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _clampData(feeRate);

        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendVaultToMidnightClamp)), cd);
    }

    function test_bindingVaultLiquidity_maxFee_99to100() public {
        _setTotalUnits(targetMarketId, 99e18);
        _limitVaultLiquidity(5e18);
        uint256 feeRate = 0.5e18;

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);
        bytes memory cd = _clampData(feeRate);

        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendVaultToMidnightClamp)), cd);
    }

    /* ═══════ reduceOnly ═══════ */

    /// @notice reduceOnly=true returns 0 when maker has no debt on target market
    /// @dev BUY offer on target Midnight: reduceOnly caps by buyer's debt on target.
    ///      In a normal Vault to Midnight migration the buyer (lender) has vault shares but
    ///      no Midnight debt on target, so reduceOnly → 0.
    function test_reduceOnly_noTargetDebt_returnsZero() public {
        bytes32 group = _freshGroup();

        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group);
        offer.reduceOnly = true;

        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, _clampData());
        assertEq(maxUnits, 0, "reduceOnly with no target debt should return 0");
    }

    /* ═══════ Zero edge cases ═══════ */

    function test_zeroVaultLiquidity_returnsZero() public {
        // Withdraw everything so lender has 0 withdrawable
        _limitVaultLiquidity(0);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, _clampData());
        assertEq(maxUnits, 0, "zero vault liquidity: should return 0");
    }
}
