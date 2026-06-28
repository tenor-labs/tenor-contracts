// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {VaultSupplyClamp} from "../../../src/router/clamps/VaultSupplyClamp.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {MidnightSupplyVaultSharesCallback} from "@callbacks/MidnightSupplyVaultSharesCallback.sol";
import {IMidnightSupplyVaultSharesCallback} from "@callbacks/interfaces/IMidnightSupplyVaultSharesCallback.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {LIQUIDATION_CURSOR} from "../../helpers/MaxLifLib.sol";

/// @title VaultSupplyClampBoundary
/// @notice Deterministic boundary tests for VaultSupplyClamp
/// @dev Min chain: min(capacityToShares, maxUnitsFromBudget(min(balance, allowance, vaultCap) * lltv / WAD))
contract VaultSupplyClampBoundary is BoundaryTestBase {
    uint256 private _groupNonce;

    MidnightSupplyVaultSharesCallback internal vaultCallback;
    Market internal vaultMarket;
    bytes32 internal vaultMarketId;

    uint256 internal constant LLTV = 0.945e18;
    uint256 internal constant ADDITIONAL_DEPOSIT_PERCENT = 0.1e18; // 10%

    // Seller (borrower/maker) for vault supply tests
    address internal seller;
    uint256 internal sellerSK;

    function setUp() public override {
        super.setUp();

        (seller, sellerSK) = makeAddrAndKey("vaultSeller");

        // Deploy vault supply callback
        vaultCallback = new MidnightSupplyVaultSharesCallback(address(midnight));

        // Create vault-collateral market (uses vault shares, not raw collateral)
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(vault), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        vaultMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        vaultMarketId = IdLib.toId(vaultMarket);

        // Seed the vault market
        _seedVaultMarket();

        // Lender (buyer/taker): unlimited balance and allowance
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        // Default seller setup: large loan token balance + callback auth
        loanToken.mint(seller, type(uint128).max);
        vm.startPrank(seller);
        loanToken.approve(address(vaultCallback), type(uint256).max);
        midnight.setIsAuthorized(address(vaultCallback), true, seller);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seller);
        vm.stopPrank();
    }

    /* ═══════ Seeding ═══════ */

    function _seedVaultMarket() internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey("vaultSeedBorrower");
        address seedLender = makeAddr("vaultSeedLender");

        loanToken.mint(seedLender, type(uint128).max);
        loanToken.mint(seedBorrower, type(uint128).max);

        vm.startPrank(seedBorrower);
        loanToken.approve(address(vaultCallback), type(uint256).max);
        midnight.setIsAuthorized(address(vaultCallback), true, seedBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedBorrower);
        vm.stopPrank();

        vm.prank(seedLender);
        loanToken.approve(address(midnight), type(uint256).max);

        Offer memory seedOffer = Offer({
            market: vaultMarket,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256("vaultSeed"),
            callback: address(vaultCallback),
            callbackData: abi.encode(
                IMidnightSupplyVaultSharesCallback.CallbackData({
                    vault: address(vault), collateralIndex: 0, additionalDepositPercent: ADDITIONAL_DEPOSIT_PERCENT
                })
            ),
            receiverIfMakerIsSeller: address(vaultCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(seedOffer, seedBorrowerSK);
        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(seedOffer), uint256(0), new bytes32[](0));
        uint256 units = SEED_AMOUNT;

        vm.prank(seedLender);
        midnight.take(seedOffer, ratifierData, units, seedLender, address(0), address(0), "");
    }

    /* ═══════ Helpers ═══════ */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("vaultSupplyBoundary", ++_groupNonce));
    }

    function _buildOffer(address maker, uint128 unitsCapacity, uint16 tick, bytes32 group)
        internal
        view
        returns (Offer memory)
    {
        return Offer({
            market: vaultMarket,
            buy: false,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(vaultCallback),
            callbackData: abi.encode(
                IMidnightSupplyVaultSharesCallback.CallbackData({
                    vault: address(vault), collateralIndex: 0, additionalDepositPercent: ADDITIONAL_DEPOSIT_PERCENT
                })
            ),
            receiverIfMakerIsSeller: address(vaultCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: unitsCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _clampData() internal view returns (bytes memory) {
        return abi.encode(
            VaultSupplyClamp.VaultSupplyClampData({
                loanToken: address(loanToken),
                vault: address(vault),
                callback: address(vaultCallback),
                marketId: vaultMarketId,
                taker: lender
            })
        );
    }

    /* ═══════ Balance binding ═══════ */

    function test_bindingBalance_fresh() public {
        deal(address(loanToken), seller, 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = vaultSupplyClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(vaultSupplyClamp)), _clampData());
    }

    function test_bindingBalance_1to2() public {
        _setTotalUnits(vaultMarketId, 100e18);
        deal(address(loanToken), seller, 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = vaultSupplyClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(vaultSupplyClamp)), _clampData());
    }

    function test_bindingBalance_99to100() public {
        _setTotalUnits(vaultMarketId, 99e18);
        deal(address(loanToken), seller, 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = vaultSupplyClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(vaultSupplyClamp)), _clampData());
    }

    /* ═══════ Allowance binding ═══════ */

    function test_bindingAllowance() public {
        vm.prank(seller);
        loanToken.approve(address(vaultCallback), 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = vaultSupplyClamp.maxUnits(offer, _clampData());
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(vaultSupplyClamp)), _clampData());
    }

    // Vault deposit cap is NOT checked by the clamp — production vaults have large caps
    // and the few-wei rounding surplus from the net-cost formula would not exceed them.

    /* ═══════ LLTV variations ═══════ */

    /// @notice Seed a vault market with custom LLTV
    function _seedCustomVaultMarket(uint256 customLltv) internal returns (Market memory obl, bytes32 oblId) {
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(vault), lltv: customLltv, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        obl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        oblId = IdLib.toId(obl);

        // Seed the market
        (address seedBorrower, uint256 seedBorrowerSK) =
            makeAddrAndKey(string(abi.encodePacked("vaultSeedCustom", oblId)));
        address seedLender = makeAddr(string(abi.encodePacked("vaultSeedLCustom", oblId)));

        loanToken.mint(seedLender, type(uint128).max);
        loanToken.mint(seedBorrower, type(uint128).max);

        vm.startPrank(seedBorrower);
        loanToken.approve(address(vaultCallback), type(uint256).max);
        midnight.setIsAuthorized(address(vaultCallback), true, seedBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedBorrower);
        vm.stopPrank();

        vm.prank(seedLender);
        loanToken.approve(address(midnight), type(uint256).max);

        Offer memory seedOffer = Offer({
            market: obl,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("vaultSeedCustom", oblId)),
            callback: address(vaultCallback),
            callbackData: abi.encode(
                IMidnightSupplyVaultSharesCallback.CallbackData({
                    vault: address(vault), collateralIndex: 0, additionalDepositPercent: ADDITIONAL_DEPOSIT_PERCENT
                })
            ),
            receiverIfMakerIsSeller: address(vaultCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(seedOffer, seedBorrowerSK);
        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(seedOffer), uint256(0), new bytes32[](0));
        uint256 units = SEED_AMOUNT;

        vm.prank(seedLender);
        midnight.take(seedOffer, ratifierData, units, seedLender, address(0), address(0), "");
    }

    /// @notice Balance binding with 38.5% LLTV (maxMarketUnits = maxTotalDeposit * 0.385)
    function test_bindingBalance_lltvSmall() public {
        uint256 lltvSmall = 0.385e18; // 38.5% (lowest allowed tier)
        (Market memory oblSmall, bytes32 oblIdSmall) = _seedCustomVaultMarket(lltvSmall);

        deal(address(loanToken), seller, 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = Offer({
            market: oblSmall,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(vaultCallback),
            callbackData: abi.encode(
                IMidnightSupplyVaultSharesCallback.CallbackData({
                    vault: address(vault), collateralIndex: 0, additionalDepositPercent: 1.6e18
                })
            ),
            receiverIfMakerIsSeller: address(vaultCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: MAX_OFFER_CAPACITY,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes memory cd = abi.encode(
            VaultSupplyClamp.VaultSupplyClampData({
                loanToken: address(loanToken),
                vault: address(vault),
                callback: address(vaultCallback),
                marketId: oblIdSmall,
                taker: lender
            })
        );

        uint256 maxUnits = vaultSupplyClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, sellerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(vaultSupplyClamp)), cd);
    }

    /* ═══════ reduceOnly ═══════ */

    /// @notice reduceOnly=true returns 0 when seller has no credit on the market
    /// @dev SELL offer: reduceOnly caps by seller's credit on the market.
    ///      A fresh seller has no credit, so reduceOnly → 0.
    function test_reduceOnly_noCredit_returnsZero() public {
        bytes32 group = _freshGroup();

        Offer memory offer = _buildOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        offer.reduceOnly = true;

        uint256 maxUnits = vaultSupplyClamp.maxUnits(offer, _clampData());
        assertEq(maxUnits, 0, "reduceOnly with no credit should return 0");
    }

    /* ═══════ uint128 cap ═══════ */

    /// @notice A tiny additionalDepositPercent inverts to ~available * WAD seller-assets, which converts to a unit
    ///         count exceeding uint128. maxUnits must saturate to uint128.max (via assetsToSellerUnits) so a single
    ///         Midnight take cannot forward more than uint128 units and revert at its toUint128 cast.
    /// @dev seller's available (balance ∧ allowance) is type(uint128).max here, so without the cap the clamp
    ///      would return a value ≫ uint128.max.
    function test_maxUnits_cappedToUint128_onTinyDepositPercent() public {
        bytes32 group = _freshGroup();
        Offer memory offer = _buildOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        offer.callbackData = abi.encode(
            IMidnightSupplyVaultSharesCallback.CallbackData({
                vault: address(vault),
                collateralIndex: 0,
                additionalDepositPercent: 1 // 1 wei
            })
        );

        uint256 maxUnits = vaultSupplyClamp.maxUnits(offer, _clampData());
        assertEq(maxUnits, type(uint128).max, "maxUnits must saturate to uint128.max");
    }

    /* ═══════ Zero edge cases ═══════ */

    function test_zeroBalance() public {
        deal(address(loanToken), seller, 0);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);

        uint256 maxUnits = vaultSupplyClamp.maxUnits(offer, _clampData());
        assertEq(maxUnits, 0, "zero balance: maxUnits should be 0");
    }

    /// @notice additionalDepositPercent == 0 pulls nothing from the seller, so the balance/allowance is not binding:
    ///         maxUnits saturates to uint128.max (it must not revert on the zero-divisor inverse).
    function test_zeroAdditionalPercent_saturates() public {
        deal(address(loanToken), seller, 10e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        offer.callbackData = abi.encode(
            IMidnightSupplyVaultSharesCallback.CallbackData({
                vault: address(vault), collateralIndex: 0, additionalDepositPercent: 0
            })
        );

        uint256 maxUnits = vaultSupplyClamp.maxUnits(offer, _clampData());
        assertEq(maxUnits, type(uint128).max, "zero percent: maxUnits should saturate");
    }

    /// @notice callbackData shorter than the CallbackData head returns 0
    function test_shortCallbackData_returnsZero() public {
        bytes32 group = _freshGroup();
        Offer memory offer = _buildOffer(seller, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        offer.callbackData = new bytes(64);

        uint256 maxUnits = vaultSupplyClamp.maxUnits(offer, _clampData());
        assertEq(maxUnits, 0, "short callbackData should return 0");
    }
}
