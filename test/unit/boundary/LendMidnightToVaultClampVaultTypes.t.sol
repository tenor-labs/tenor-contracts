// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {LendMidnightToVaultClamp} from "../../../src/router/clamps/LendMidnightToVaultClamp.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {ILendMidnightToVaultCallback} from "@callbacks/interfaces/ILendMidnightToVaultCallback.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LendMidnightToVaultClampVaultTypes
/// @notice Tests for LendMidnightToVaultClamp across all three VaultType modes:
///         - ERC4626: standard maxDeposit (existing behavior, smoke-tested here)
///         - VAULT_V2: unconstrained (maxDeposit returns 0 by design, so we skip it)
///         - TENOR_VAULT_V2: unconstrained (same as VAULT_V2 for deposits)
contract LendMidnightToVaultClampVaultTypes is BoundaryTestBase {
    uint256 private _groupNonce;
    address internal vaultV2;

    function setUp() public override {
        super.setUp();

        // Real Morpho Vault V2 (ERC4626-style) with the same loanToken as the Midnight market.
        vaultV2 = deployCode("out/VaultV2.sol/VaultV2.json", abi.encode(address(this), address(loanToken)));

        // Taker (borrower/buyer): needs loan tokens and approval to buy the SELL offer
        loanToken.mint(borrower, type(uint128).max);
        vm.prank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);

        // Lender (maker/seller): authorize callback on Midnight
        vm.prank(lender);
        midnight.setIsAuthorized(address(lendMidnightToVaultCallback), true, lender);
    }

    /* ═══════ Helpers ═══════ */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("v2v1VaultTypes", ++_groupNonce));
    }

    function _callbackData(address targetVault) internal view returns (bytes memory) {
        return _callbackData(targetVault, 0);
    }

    function _callbackData(address targetVault, uint256 feeRate) internal view returns (bytes memory) {
        return abi.encode(
            ILendMidnightToVaultCallback.CallbackData({
                vault: targetVault, feeRate: feeRate, feeRecipient: feeRate == 0 ? address(0) : address(this)
            })
        );
    }

    function _buildSellOffer(uint128 unitsCapacity, uint16 tick, bytes32 group, address targetVault)
        internal
        view
        returns (Offer memory)
    {
        return _buildSellOffer(unitsCapacity, tick, group, targetVault, 0);
    }

    function _buildSellOffer(uint128 unitsCapacity, uint16 tick, bytes32 group, address targetVault, uint256 feeRate)
        internal
        view
        returns (Offer memory)
    {
        return Offer({
            market: sourceMarket,
            buy: false,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(lendMidnightToVaultCallback),
            callbackData: _callbackData(targetVault, feeRate),
            receiverIfMakerIsSeller: address(lendMidnightToVaultCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: unitsCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _clampData(address targetVault, LendMidnightToVaultClamp.VaultType vaultType)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            LendMidnightToVaultClamp.LendMidnightToVaultClampData({
                sourceMarketId: sourceMarketId, targetVault: targetVault, positionOwner: lender, vaultType: vaultType
            })
        );
    }

    /* ═══════════════════════════════════════════════════════════════
                          VAULT_V2 TESTS
       ═══════════════════════════════════════════════════════════════ */

    /// @notice VAULT_V2: maxDeposit() returns 0 but clamp is unconstrained — returns non-zero
    function test_vaultV2_unconstrained() public {
        _setupLenderWithCredit(lender, 50e18, sourceMarket, sourceMarketId);

        // Confirm VaultV2.maxDeposit is indeed 0
        assertEq(IERC4626(vaultV2).maxDeposit(lender), 0, "VaultV2.maxDeposit must be 0");

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, vaultV2);

        bytes memory cd = _clampData(vaultV2, LendMidnightToVaultClamp.VaultType.VAULT_V2);
        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);

        assertTrue(maxUnits > 0, "VAULT_V2: should return non-zero despite maxDeposit()==0");
    }

    /// @notice VAULT_V2: ERC4626 type with VaultV2 target returns 0 (the bug this fix addresses)
    function test_vaultV2_erc4626Type_returnsZero() public {
        _setupLenderWithCredit(lender, 50e18, sourceMarket, sourceMarketId);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, vaultV2);

        // Using ERC4626 vault type with VaultV2 target: maxDeposit()==0 → clamp returns 0
        bytes memory cd = _clampData(vaultV2, LendMidnightToVaultClamp.VaultType.ERC4626);
        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);

        assertEq(maxUnits, 0, "ERC4626 type on VaultV2: maxDeposit()==0 so clamp returns 0");
    }

    /// @notice VAULT_V2: boundary verification — take(maxUnits) succeeds via real callback
    function test_vaultV2_boundary() public {
        _setupLenderWithCredit(lender, 10e18, sourceMarket, sourceMarketId);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, vaultV2);

        bytes memory cd = _clampData(vaultV2, LendMidnightToVaultClamp.VaultType.VAULT_V2);
        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendMidnightToVaultClamp)), cd);
    }

    /// @notice VAULT_V2: matches ERC4626 result on standard vault (where maxDeposit works)
    function test_vaultV2_matchesERC4626OnStandardVault() public {
        _setupLenderWithCredit(lender, 10e18, sourceMarket, sourceMarketId);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, address(vault));

        bytes memory cdV2 = _clampData(address(vault), LendMidnightToVaultClamp.VaultType.VAULT_V2);
        bytes memory cdERC4626 = _clampData(address(vault), LendMidnightToVaultClamp.VaultType.ERC4626);

        uint256 maxUnitsV2 = lendMidnightToVaultClamp.maxUnits(offer, cdV2);
        uint256 maxUnitsERC4626 = lendMidnightToVaultClamp.maxUnits(offer, cdERC4626);

        assertEq(maxUnitsV2, maxUnitsERC4626, "VAULT_V2 should match ERC4626 on standard vault");
    }

    /* ═══════════════════════════════════════════════════════════════
                        TENOR_VAULT_V2 TESTS
       ═══════════════════════════════════════════════════════════════ */

    /// @notice TENOR_VAULT_V2: unconstrained — same behavior as VAULT_V2 for deposits
    function test_tenorVaultV2_unconstrained() public {
        _setupLenderWithCredit(lender, 50e18, sourceMarket, sourceMarketId);

        assertEq(IERC4626(vaultV2).maxDeposit(lender), 0, "VaultV2.maxDeposit must be 0");

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, vaultV2);

        bytes memory cd = _clampData(vaultV2, LendMidnightToVaultClamp.VaultType.TENOR_VAULT_V2);
        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);

        assertTrue(maxUnits > 0, "TENOR_VAULT_V2: should return non-zero despite maxDeposit()==0");
    }

    /// @notice TENOR_VAULT_V2: matches VAULT_V2 result
    function test_tenorVaultV2_matchesVaultV2() public {
        _setupLenderWithCredit(lender, 50e18, sourceMarket, sourceMarketId);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, vaultV2);

        bytes memory cdV2 = _clampData(vaultV2, LendMidnightToVaultClamp.VaultType.VAULT_V2);
        bytes memory cdTenor = _clampData(vaultV2, LendMidnightToVaultClamp.VaultType.TENOR_VAULT_V2);

        uint256 maxUnitsV2 = lendMidnightToVaultClamp.maxUnits(offer, cdV2);
        uint256 maxUnitsTenor = lendMidnightToVaultClamp.maxUnits(offer, cdTenor);

        assertEq(maxUnitsTenor, maxUnitsV2, "TENOR_VAULT_V2 should match VAULT_V2 for deposits");
    }

    /// @notice TENOR_VAULT_V2: boundary verification
    function test_tenorVaultV2_boundary() public {
        _setupLenderWithCredit(lender, 10e18, sourceMarket, sourceMarketId);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, vaultV2);

        bytes memory cd = _clampData(vaultV2, LendMidnightToVaultClamp.VaultType.TENOR_VAULT_V2);
        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendMidnightToVaultClamp)), cd);
    }

    /* ═══════════════════════════════════════════════════════════════
                    ERC4626 SMOKE TESTS (regression)
       ═══════════════════════════════════════════════════════════════ */

    /// @notice ERC4626: zero maxDeposit returns 0
    function test_erc4626_zeroMaxDeposit_returnsZero() public {
        _setupLenderWithCredit(lender, 10e18, sourceMarket, sourceMarketId);

        vault.setMaxDepositCap(0);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, address(vault));

        bytes memory cd = _clampData(address(vault), LendMidnightToVaultClamp.VaultType.ERC4626);
        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);

        assertEq(maxUnits, 0, "ERC4626: zero maxDeposit should return 0");
    }

    /// @notice ERC4626: zero user credit returns 0
    function test_erc4626_zeroUserCredit_returnsZero() public {
        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, address(vault));

        bytes memory cd = _clampData(address(vault), LendMidnightToVaultClamp.VaultType.ERC4626);
        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);

        assertEq(maxUnits, 0, "ERC4626: zero user credit should return 0");
    }

    /* ═══════════════════════════════════════════════════════════════
                    ERC4626 FEE GROSS-UP TESTS
       ═══════════════════════════════════════════════════════════════ */

    /// @notice With a binding maxDeposit cap and a non-zero callback fee, the clamp grosses up the assets budget so
    ///         the net deposit (sellerAssets - fee) fills the cap exactly: take(maxUnits) succeeds, take(maxUnits+1)
    ///         reverts. A fee-agnostic bound would underutilize the cap by the fee fraction.
    function test_erc4626_feeGrossUp_fillsCapExactly() public {
        _setupLenderWithCredit(lender, 100e18, sourceMarket, sourceMarketId);
        vault.setMaxDepositCap(10e18);

        bytes32 group = _freshGroup();
        bytes memory cd = _clampData(address(vault), LendMidnightToVaultClamp.VaultType.ERC4626);

        // Fee-agnostic baseline: a no-fee offer is sized so gross sellerAssets <= cap. This is exactly the pre-fix
        // bound, since with no fee gross == net.
        Offer memory noFeeOffer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, address(vault), 0);
        uint256 feeAgnosticUnits = lendMidnightToVaultClamp.maxUnits(noFeeOffer, cd);

        // With a 1% fee, the gross-up sizes strictly more units so the net deposit still fills the cap.
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, address(vault), 0.01e18);
        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);
        assertGt(maxUnits, feeAgnosticUnits, "gross-up should size more units than the fee-agnostic bound");

        // Taking only the fee-agnostic units leaves unused cap headroom (the under-utilization being fixed).
        uint256 snap = vm.snapshotState();
        _take(offer, feeAgnosticUnits);
        assertGt(IERC4626(address(vault)).maxDeposit(lender), 0, "fee-agnostic fill leaves unused cap headroom");
        vm.revertToState(snap);

        // The fee-aware sizing fills the cap exactly: take(maxUnits) succeeds, take(maxUnits + 1) reverts.
        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendMidnightToVaultClamp)), cd);
    }

    /// @notice feeRate == 0 (production default) is a no-op: net deposit fills the cap exactly with no gross-up.
    function test_erc4626_zeroFee_noGrossUp() public {
        _setupLenderWithCredit(lender, 100e18, sourceMarket, sourceMarketId);
        vault.setMaxDepositCap(10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, address(vault), 0);
        bytes memory cd = _clampData(address(vault), LendMidnightToVaultClamp.VaultType.ERC4626);

        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);
        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendMidnightToVaultClamp)), cd);
    }

    /// @notice An uncapped ERC-4626 vault reports maxDeposit == type(uint256).max; the gross-up must not overflow
    ///         (a reverting clamp DoS-es the router batch). The cap is not binding, so userCredit governs sizing.
    function test_erc4626_uncappedVaultWithFee_doesNotRevert() public {
        _setupLenderWithCredit(lender, 100e18, sourceMarket, sourceMarketId);
        // No setMaxDepositCap: vault.maxDeposit returns type(uint256).max.

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAPACITY, TICK_HIGH, group, address(vault), 0.01e18);
        bytes memory cd = _clampData(address(vault), LendMidnightToVaultClamp.VaultType.ERC4626);

        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifySafetyOnly(maxUnits, offer, sig, borrower);
    }

    function _take(Offer memory offer, uint256 units) internal {
        Signature memory sig = _signOffer(offer, lenderSK);
        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0));
        vm.prank(borrower);
        midnight.take(offer, ratifierData, units, borrower, address(0), address(0), "");
    }
}
