// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {LendVaultToMidnightClamp} from "../../../src/router/clamps/LendVaultToMidnightClamp.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {ILendVaultToMidnightCallback} from "@callbacks/interfaces/ILendVaultToMidnightCallback.sol";
import {IMorpho, Id, MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "../../../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MarketParamsLib} from "../../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";

/// @title LendVaultToMidnightClampVaultTypes
/// @notice Tests for LendVaultToMidnightClamp across all three VaultType modes:
///         - ERC4626: standard maxWithdraw (existing behavior, smoke-tested here)
///         - VAULT_V2: always unconstrained (maxWithdraw returns 0 by design, so we skip it)
///         - TENOR_VAULT_V2: liquidity = min(maker vault balance in assets, Morpho Blue market liquidity)
contract LendVaultToMidnightClampVaultTypes is BoundaryTestBase {
    using MorphoBalancesLib for IMorpho;
    using MarketParamsLib for MarketParams;

    uint256 private _groupNonce;
    bytes32 internal blueMarketId;

    function setUp() public override {
        super.setUp();

        // Buyer (maker) needs loan tokens
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        // Taker (borrower/seller) needs collateral on target
        _depositCollateral(borrower, 1e38, targetMarket);

        // Lender owns vault shares
        loanToken.mint(address(this), 1000e18);
        loanToken.approve(address(vault), 1000e18);
        vault.deposit(1000e18, lender);

        // Lender approves callback to spend vault shares
        vm.prank(lender);
        vault.approve(address(lendVaultToMidnightCallback), type(uint256).max);

        // Capture the Blue market ID for TENOR_VAULT_V2 tests
        blueMarketId = Id.unwrap(blueMarketParams.id());
    }

    /* ═══════ Helpers ═══════ */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("vaultTypes", ++_groupNonce));
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

    function _clampData(uint256 feeRate, LendVaultToMidnightClamp.VaultType vaultType, bytes32 mktId)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            LendVaultToMidnightClamp.LendVaultToMidnightClampData({
                sourceVault: address(vault),
                marketId: targetMarketId,
                positionOwner: lender,
                feeRate: feeRate,
                vaultType: vaultType,
                morphoBlueMarketId: mktId
            })
        );
    }

    function _clampData(uint256 feeRate, LendVaultToMidnightClamp.VaultType vaultType)
        internal
        view
        returns (bytes memory)
    {
        return _clampData(feeRate, vaultType, bytes32(0));
    }

    /// @dev Reduce lender's vault shares so their vault balance == targetAssets.
    function _limitVaultBalance(uint256 targetAssets) internal {
        uint256 currentMax = vault.maxWithdraw(lender);
        if (currentMax > targetAssets) {
            uint256 excess = currentMax - targetAssets;
            vm.prank(lender);
            vault.withdraw(excess, address(this), lender);
        }
    }

    /* ═══════════════════════════════════════════════════════════════
                          VAULT_V2 TESTS
       ═══════════════════════════════════════════════════════════════ */

    /// @notice VAULT_V2: large capacity — vault balance becomes the bottleneck
    function test_vaultV2_largeCapacity() public {
        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);

        bytes memory cd = _clampData(0, LendVaultToMidnightClamp.VaultType.VAULT_V2);
        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);

        assertTrue(maxUnits > 0, "VAULT_V2: should return non-zero");
    }

    /// @notice VAULT_V2 with fee: constrained by convertToAssets
    function test_vaultV2_withFee() public {
        uint256 feeRate = 0.1e18;
        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);

        bytes memory cd = _clampData(feeRate, LendVaultToMidnightClamp.VaultType.VAULT_V2);
        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);

        assertTrue(maxUnits > 0, "VAULT_V2 with fee: should return non-zero");
    }

    /// @notice VAULT_V2 boundary: vault balance binding
    function test_vaultV2_boundary_vaultBalanceBinding() public {
        _limitVaultBalance(5e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);

        bytes memory cd = _clampData(0, LendVaultToMidnightClamp.VaultType.VAULT_V2);
        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendVaultToMidnightClamp)), cd);
    }

    /// @notice VAULT_V2: matches ERC4626 result (since test vault's maxWithdraw == convertToAssets)
    function test_vaultV2_matchesERC4626() public {
        _limitVaultBalance(5e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);

        bytes memory cdV2 = _clampData(0, LendVaultToMidnightClamp.VaultType.VAULT_V2);
        bytes memory cdERC4626 = _clampData(0, LendVaultToMidnightClamp.VaultType.ERC4626);

        uint256 maxUnitsV2 = lendVaultToMidnightClamp.maxUnits(offer, cdV2);
        uint256 maxUnitsERC4626 = lendVaultToMidnightClamp.maxUnits(offer, cdERC4626);

        assertEq(maxUnitsV2, maxUnitsERC4626, "VAULT_V2 should match ERC4626 on standard vault");
    }

    /* ═══════════════════════════════════════════════════════════════
                        TENOR_VAULT_V2 TESTS
       ═══════════════════════════════════════════════════════════════ */

    /// @notice TENOR_VAULT_V2: maker balance is the binding constraint (market has ample liquidity)
    function test_tenorVaultV2_makerBalanceBinding() public {
        // Supply lots of liquidity to Blue market so market liquidity isn't binding
        _setBlueMarketLiquidity(10_000e18, 0);

        // Lender has 1000e18 in vault, market has 10_000e18 liquidity
        // → maker balance (1000e18) is binding
        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);

        bytes memory cdERC4626 = _clampData(0, LendVaultToMidnightClamp.VaultType.ERC4626);
        bytes memory cdTenor = _clampData(0, LendVaultToMidnightClamp.VaultType.TENOR_VAULT_V2, blueMarketId);

        uint256 maxUnitsERC4626 = lendVaultToMidnightClamp.maxUnits(offer, cdERC4626);
        uint256 maxUnitsTenor = lendVaultToMidnightClamp.maxUnits(offer, cdTenor);

        // Both should give same result since maker balance is binding in both cases
        assertEq(maxUnitsTenor, maxUnitsERC4626, "TENOR_VAULT_V2: should match ERC4626 when maker balance binds");
        assertTrue(maxUnitsTenor > 0, "should have units");
    }

    /// @notice TENOR_VAULT_V2: market liquidity is the binding constraint
    function test_tenorVaultV2_marketLiquidityBinding() public {
        // Supply small amount to Blue market: only 50e18 available
        _setBlueMarketLiquidity(50e18, 0);

        // Lender has 1000e18 in vault, market has 50e18 liquidity
        // → market liquidity (50e18) is binding
        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);

        bytes memory cdTenor = _clampData(0, LendVaultToMidnightClamp.VaultType.TENOR_VAULT_V2, blueMarketId);
        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cdTenor);

        assertTrue(maxUnits > 0, "should have units");

        // Compute expected: market liquidity is 50e18, maker has 1000e18
        // min(1000e18, 50e18) = 50e18 → then capped by offer/budget
        bytes memory cdERC4626 = _clampData(0, LendVaultToMidnightClamp.VaultType.ERC4626);
        uint256 maxUnitsERC4626 = lendVaultToMidnightClamp.maxUnits(offer, cdERC4626);

        // TENOR_VAULT_V2 should return less since market liquidity binds tighter
        assertTrue(maxUnits < maxUnitsERC4626, "TENOR_VAULT_V2: market liquidity should bind tighter");
    }

    /// @notice TENOR_VAULT_V2: zero market liquidity returns 0
    function test_tenorVaultV2_zeroMarketLiquidity_returnsZero() public {
        // Supply to Blue market, then borrow everything to create 0 available liquidity
        _setBlueMarketLiquidity(100e18, 100e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);

        bytes memory cdTenor = _clampData(0, LendVaultToMidnightClamp.VaultType.TENOR_VAULT_V2, blueMarketId);
        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cdTenor);

        assertEq(maxUnits, 0, "TENOR_VAULT_V2: zero market liquidity should return 0");
    }

    /// @notice TENOR_VAULT_V2: zero vault balance returns 0
    function test_tenorVaultV2_zeroVaultBalance_returnsZero() public {
        _setBlueMarketLiquidity(10_000e18, 0);

        // Drain lender's vault balance
        _limitVaultBalance(0);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);

        bytes memory cdTenor = _clampData(0, LendVaultToMidnightClamp.VaultType.TENOR_VAULT_V2, blueMarketId);
        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cdTenor);

        assertEq(maxUnits, 0, "TENOR_VAULT_V2: zero vault balance should return 0");
    }

    /// @notice TENOR_VAULT_V2 with fee: market liquidity constrains correctly
    function test_tenorVaultV2_withFee_marketLiquidityBinding() public {
        _setBlueMarketLiquidity(50e18, 0);
        uint256 feeRate = 0.1e18;

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);

        bytes memory cdTenor = _clampData(feeRate, LendVaultToMidnightClamp.VaultType.TENOR_VAULT_V2, blueMarketId);
        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cdTenor);

        assertTrue(maxUnits > 0, "TENOR_VAULT_V2 with fee: should return non-zero");
    }

    /// @notice TENOR_VAULT_V2: limited vault balance with ample market → maker balance binds
    function test_tenorVaultV2_limitedVaultBalance() public {
        _setBlueMarketLiquidity(10_000e18, 0);
        _limitVaultBalance(5e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);

        bytes memory cdTenor = _clampData(0, LendVaultToMidnightClamp.VaultType.TENOR_VAULT_V2, blueMarketId);
        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cdTenor);

        assertTrue(maxUnits > 0, "should have units");

        // Should match ERC4626 since vault balance (5e18) binds, not market (10_000e18)
        bytes memory cdERC4626 = _clampData(0, LendVaultToMidnightClamp.VaultType.ERC4626);
        uint256 maxUnitsERC4626 = lendVaultToMidnightClamp.maxUnits(offer, cdERC4626);
        assertEq(maxUnits, maxUnitsERC4626, "limited vault balance: should match ERC4626");
    }

    /// @notice TENOR_VAULT_V2 boundary: take(maxUnits) succeeds when maker balance binds
    function test_tenorVaultV2_boundary_makerBalanceBinding() public {
        _setBlueMarketLiquidity(10_000e18, 0);
        _limitVaultBalance(5e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);

        bytes memory cd = _clampData(0, LendVaultToMidnightClamp.VaultType.TENOR_VAULT_V2, blueMarketId);
        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendVaultToMidnightClamp)), cd);
    }

    function test_tenorVaultV2_readsMarketIdFromClampData_notOfferCallbackData() public {
        _setBlueMarketLiquidity(50e18, 0);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);
        offer.callbackData = "";

        bytes memory cd = _clampData(0, LendVaultToMidnightClamp.VaultType.TENOR_VAULT_V2, blueMarketId);
        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);

        assertTrue(maxUnits > 0, "TENOR_VAULT_V2: empty offer.callbackData must not zero the cap");
    }

    /// @notice TENOR_VAULT_V2 boundary with fee
    function test_tenorVaultV2_boundary_withFee() public {
        _setBlueMarketLiquidity(10_000e18, 0);
        _limitVaultBalance(5e18);
        uint256 feeRate = 0.1e18;

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, feeRate);

        bytes memory cd = _clampData(feeRate, LendVaultToMidnightClamp.VaultType.TENOR_VAULT_V2, blueMarketId);
        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendVaultToMidnightClamp)), cd);
    }

    /* ═══════════════════════════════════════════════════════════════
                    ERC4626 SMOKE TESTS (regression)
       ═══════════════════════════════════════════════════════════════ */

    /// @notice ERC4626: zero maxWithdraw returns 0
    function test_erc4626_zeroMaxWithdraw_returnsZero() public {
        _limitVaultBalance(0);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, 0);

        bytes memory cd = _clampData(0, LendVaultToMidnightClamp.VaultType.ERC4626);
        uint256 maxUnits = lendVaultToMidnightClamp.maxUnits(offer, cd);

        assertEq(maxUnits, 0, "ERC4626: zero maxWithdraw should return 0");
    }
}
