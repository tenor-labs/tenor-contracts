// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {LendMidnightToVaultClamp} from "../../../src/router/clamps/LendMidnightToVaultClamp.sol";
import {ILendMidnightToVaultCallback} from "@callbacks/interfaces/ILendMidnightToVaultCallback.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";

/// @title LendMidnightToVaultClampBoundary
/// @notice Deterministic boundary tests for LendMidnightToVaultClamp
/// @dev SELL offers: buy=false, maker=lender(seller), taker=borrower(buyer)
///      The maker sells their Midnight source lending position; the taker is the borrower.
///      Uses the real LendMidnightToVaultCallback so vault deposits are consumed during the take.
contract LendMidnightToVaultClampBoundary is BoundaryTestBase {
    uint256 private _groupNonce;

    function setUp() public override {
        super.setUp();

        // Taker (borrower/buyer): needs loan tokens and approval to buy the SELL offer
        loanToken.mint(borrower, type(uint128).max);
        vm.prank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);

        // Lender (maker/seller): authorize callback on Midnight + approve callback for loan tokens
        vm.startPrank(lender);
        midnight.setIsAuthorized(address(lendMidnightToVaultCallback), true, lender);
        vm.stopPrank();
    }

    /* ═══════ Helpers ═══════ */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("v2v1LendBoundary", ++_groupNonce));
    }

    /// @notice Build callback data for LendMidnightToVaultCallback
    function _callbackData() internal view returns (bytes memory) {
        return abi.encode(
            ILendMidnightToVaultCallback.CallbackData({vault: address(vault), feeRate: 0, feeRecipient: address(0)})
        );
    }

    /// @notice Build a SELL offer on the source market with the real callback
    function _buildSellOffer(address maker, uint128 unitsCapacity, uint16 tick, bytes32 group)
        internal
        view
        returns (Offer memory)
    {
        return Offer({
            market: sourceMarket,
            buy: false,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(lendMidnightToVaultCallback),
            callbackData: _callbackData(),
            receiverIfMakerIsSeller: address(lendMidnightToVaultCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: unitsCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    /// @notice Build clamp data for LendMidnightToVaultClamp
    function _clampData() internal view returns (bytes memory) {
        return abi.encode(
            LendMidnightToVaultClamp.LendMidnightToVaultClampData({
                sourceMarketId: sourceMarketId,
                targetVault: address(vault),
                positionOwner: lender,
                vaultType: LendMidnightToVaultClamp.VaultType.ERC4626
            })
        );
    }

    /* ═══════ Position assets binding ═══════ */

    /// @notice Position assets is binding at fresh 1:1 ratio
    function test_bindingPosition_fresh() public {
        // Small shares so position assets is binding
        _setupLenderWithCredit(lender, 10e18, sourceMarket, sourceMarketId);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(lender, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData();

        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendMidnightToVaultClamp)), cd);
    }

    /* ═══════ Vault deposit cap binding ═══════ */

    /// @notice Vault deposit cap is binding -- small maxDeposit, large credit
    function test_bindingVaultDeposit() public {
        _setupLenderWithCredit(lender, 50e18, sourceMarket, sourceMarketId);

        // Set cap relative to current deposits so there's exactly 5e18 remaining
        vault.setMaxDepositCap(vault.totalAssets() + 5e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(lender, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData();

        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendMidnightToVaultClamp)), cd);
    }

    /* ═══════ Zero edge cases ═══════ */

    /// @notice Zero user credit always returns 0
    function test_zeroUserCredit_returnsZero() public {
        // Lender has no credit on source market -- don't call _setupLenderWithCredit
        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(lender, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData();

        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "zero user shares: maxUnits should be 0");
    }

    /// @notice Zero vault deposit cap returns 0
    function test_zeroVaultDeposit_returnsZero() public {
        _setupLenderWithCredit(lender, 10e18, sourceMarket, sourceMarketId);

        // Vault deposit cap is zero
        vault.setMaxDepositCap(0);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(lender, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData();

        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "zero vault deposit: maxUnits should be 0");
    }

    /* ═══════ reduceOnly ═══════ */

    /// @notice reduceOnly=true caps by userCredit (already the binding constraint here)
    function test_reduceOnly_capsToUserCredit() public {
        _setupLenderWithCredit(lender, 10e18, sourceMarket, sourceMarketId);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(lender, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        offer.reduceOnly = true;
        bytes memory cd = _clampData();

        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "reduceOnly with source credit should return > 0");

        // Compare with reduceOnly=false — should be the same since userCredit already caps
        Offer memory offerNoExit = _buildSellOffer(lender, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        uint256 maxUnitsNoExit = lendMidnightToVaultClamp.maxUnits(offerNoExit, cd);
        assertEq(maxUnits, maxUnitsNoExit, "reduceOnly should be redundant when userCredit caps");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendMidnightToVaultClamp)), cd);
    }

    /* ═══════ Combined binding ═══════ */

    /// @notice Both position assets and vault deposit are small -- whichever is smaller binds
    function test_bindingPositionAndVault() public {
        _setupLenderWithCredit(lender, 8e18, sourceMarket, sourceMarketId);

        // Vault deposit cap slightly smaller than position assets
        vault.setMaxDepositCap(vault.totalAssets() + 3e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(lender, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData();

        uint256 maxUnits = lendMidnightToVaultClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, lenderSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(lendMidnightToVaultClamp)), cd);
    }
}
