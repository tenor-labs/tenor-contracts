// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {VaultWithdrawClamp} from "../../../src/router/clamps/VaultWithdrawClamp.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {MidnightWithdrawVaultSharesCallback} from "@callbacks/MidnightWithdrawVaultSharesCallback.sol";
import {MidnightSupplyVaultSharesCallback} from "@callbacks/MidnightSupplyVaultSharesCallback.sol";
import {IMidnightWithdrawVaultSharesCallback} from "@callbacks/interfaces/IMidnightWithdrawVaultSharesCallback.sol";
import {IMidnightSupplyVaultSharesCallback} from "@callbacks/interfaces/IMidnightSupplyVaultSharesCallback.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {LIQUIDATION_CURSOR} from "../../helpers/MaxLifLib.sol";

/// @title VaultWithdrawClampBoundary
/// @notice Deterministic boundary tests for VaultWithdrawClamp
/// @dev Min chain: min(remainingCapacity, maxUnitsFromVault, capReduceOnly(debt))
///      + zero-amount guards (unitsDown==0, buyerAssets==0)
///
///      This clamp is for BUY offers where the maker (buyer) uses vault shares as collateral.
///      The callback withdraws vault shares from collateral, redeems them for loan tokens,
///      and uses those to fund the buy (repay debt).
contract VaultWithdrawClampBoundary is BoundaryTestBase {
    uint256 private _groupNonce;

    /// @dev Market that uses vault shares as collateral (not collateralToken)
    Market internal vaultMarket;
    bytes32 internal vaultMarketId;

    /// @dev Callback contracts
    MidnightWithdrawVaultSharesCallback internal withdrawCallback;
    MidnightSupplyVaultSharesCallback internal supplyCallback;

    function setUp() public override {
        super.setUp();

        // Deploy callbacks
        withdrawCallback = new MidnightWithdrawVaultSharesCallback(address(midnight));
        supplyCallback = new MidnightSupplyVaultSharesCallback(address(midnight));

        // Create market with vault shares as collateral
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(vault), lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
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

        // Borrower (taker) needs generous vault collateral for health checks
        _depositVaultCollateral(borrower, 1e38);
    }

    /* ======= Seeding ======= */

    function _seedVaultMarket() internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey("vaultSeedBorrower");
        address seedLender = makeAddr("vaultSeedLender");

        loanToken.mint(seedLender, type(uint128).max);
        loanToken.mint(seedBorrower, type(uint128).max);

        // Give seed borrower vault shares for collateral
        loanToken.mint(address(this), SEED_AMOUNT * 10);
        loanToken.approve(address(vault), SEED_AMOUNT * 10);
        vault.mint(SEED_AMOUNT * 10, seedBorrower);

        vm.startPrank(seedBorrower);
        loanToken.approve(address(supplyCallback), type(uint256).max);
        vault.approve(address(supplyCallback), type(uint256).max);
        midnight.setIsAuthorized(address(supplyCallback), true, seedBorrower);
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
            callback: address(supplyCallback),
            callbackData: abi.encode(
                IMidnightSupplyVaultSharesCallback.CallbackData({
                    vault: address(vault), collateralIndex: 0, additionalDepositPercent: 0.1e18
                })
            ),
            receiverIfMakerIsSeller: address(supplyCallback),
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

    /* ======= Helpers ======= */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("vaultWithdrawBoundary", ++_groupNonce));
    }

    /// @notice Deposit vault collateral for an account on the vault market
    function _depositVaultCollateral(address account, uint256 amount) internal {
        loanToken.mint(address(this), amount);
        loanToken.approve(address(vault), amount);
        vault.mint(amount, account);

        vm.startPrank(account);
        vault.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(vaultMarket, 0, amount, account);
        vm.stopPrank();
    }

    /// @notice Give account debt + vault collateral on the vault market using the vault supply callback
    function _setupRepayerWithVaultCollateral(
        address account,
        uint256 accountSK,
        uint128 debtUnits,
        uint128 vaultShares
    ) internal {
        address tempLender = makeAddr(string(abi.encodePacked("vTL", account)));

        loanToken.mint(tempLender, type(uint128).max);
        loanToken.mint(account, type(uint128).max);
        loanToken.mint(address(this), vaultShares);
        loanToken.approve(address(vault), vaultShares);
        vault.mint(vaultShares, account);

        vm.startPrank(account);
        loanToken.approve(address(supplyCallback), type(uint256).max);
        vault.approve(address(supplyCallback), type(uint256).max);
        midnight.setIsAuthorized(address(supplyCallback), true, account);
        midnight.setIsAuthorized(address(withdrawCallback), true, account);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, account);
        vm.stopPrank();

        vm.prank(tempLender);
        loanToken.approve(address(midnight), type(uint256).max);

        // SELL offer from account (creates debt + supplies vault collateral)
        Offer memory sellOffer = Offer({
            market: vaultMarket,
            buy: false,
            maker: account,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup-vault-repayer", account)),
            callback: address(supplyCallback),
            callbackData: abi.encode(
                IMidnightSupplyVaultSharesCallback.CallbackData({
                    vault: address(vault), collateralIndex: 0, additionalDepositPercent: 0.1e18
                })
            ),
            receiverIfMakerIsSeller: address(supplyCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, accountSK);
        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(sellOffer), uint256(0), new bytes32[](0));
        uint256 units = debtUnits;

        vm.prank(tempLender);
        midnight.take(sellOffer, ratifierData, units, tempLender, address(0), address(0), "");
    }

    /// @notice Build a BUY offer for the vault market
    function _buildBuyOffer(address maker, uint128 unitsCapacity, uint16 tick, bytes32 group)
        internal
        view
        returns (Offer memory)
    {
        return Offer({
            market: vaultMarket,
            buy: true,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(withdrawCallback),
            callbackData: abi.encode(
                IMidnightWithdrawVaultSharesCallback.CallbackData({vault: address(vault), collateralIndex: 0})
            ),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: unitsCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _clampData(address taker) internal view returns (bytes memory) {
        return abi.encode(
            VaultWithdrawClamp.VaultWithdrawClampData({
                vault: address(vault),
                collateralIndex: 0,
                marketId: vaultMarketId,
                callback: address(withdrawCallback),
                taker: taker
            })
        );
    }

    /* ======= Vault assets binding ======= */

    /// @notice Vault assets is the tightest clamp constraint. Fresh 1:1 ratio.
    function test_bindingVaultAssets_fresh() public {
        (address repayer, uint256 repayerSK) = makeAddrAndKey("vaultFresh");
        _setupRepayerWithVaultCollateral(repayer, repayerSK, 80e18, 10e18);

        loanToken.mint(repayer, type(uint128).max);
        vm.prank(repayer);
        loanToken.approve(address(midnight), type(uint256).max);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(repayer, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData(borrower);

        uint256 maxUnits = vaultWithdrawClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, repayerSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(vaultWithdrawClamp)), cd);
    }

    /// @notice Vault assets binding with reduced totalUnits.
    function test_bindingVaultAssets_1to2() public {
        _setTotalUnits(vaultMarketId, 100e18);

        (address repayer, uint256 repayerSK) = makeAddrAndKey("vault2to1");
        _setupRepayerWithVaultCollateral(repayer, repayerSK, 80e18, 10e18);

        loanToken.mint(repayer, type(uint128).max);
        vm.prank(repayer);
        loanToken.approve(address(midnight), type(uint256).max);

        _setTotalUnits(vaultMarketId, 100e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(repayer, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData(borrower);

        uint256 maxUnits = vaultWithdrawClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, repayerSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(vaultWithdrawClamp)), cd);
    }

    /// @notice Vault assets binding with slightly reduced totalUnits.
    function test_bindingVaultAssets_99to100() public {
        _setTotalUnits(vaultMarketId, 99e18);

        (address repayer, uint256 repayerSK) = makeAddrAndKey("vault100to99");
        _setupRepayerWithVaultCollateral(repayer, repayerSK, 80e18, 10e18);

        loanToken.mint(repayer, type(uint128).max);
        vm.prank(repayer);
        loanToken.approve(address(midnight), type(uint256).max);

        _setTotalUnits(vaultMarketId, 99e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(repayer, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData(borrower);

        uint256 maxUnits = vaultWithdrawClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, repayerSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(vaultWithdrawClamp)), cd);
    }

    /* ======= Buyer debt binding ======= */

    /// @notice Buyer debt (10e18) is binding — vault collateral (200e18) and capacity are larger. Fresh 1:1 ratio.
    function test_bindingDebt_fresh() public {
        (address repayer, uint256 repayerSK) = makeAddrAndKey("debtFresh");
        // Small debt (10e18), large vault collateral (200e18) — debt should bind
        _setupRepayerWithVaultCollateral(repayer, repayerSK, 10e18, 200e18);

        loanToken.mint(repayer, type(uint128).max);
        vm.prank(repayer);
        loanToken.approve(address(midnight), type(uint256).max);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(repayer, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData(borrower);

        uint256 maxUnits = vaultWithdrawClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, repayerSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(vaultWithdrawClamp)), cd);
    }

    /// @notice Buyer debt binding with reduced totalUnits.
    function test_bindingDebt_1to2() public {
        _setTotalUnits(vaultMarketId, 100e18);

        (address repayer, uint256 repayerSK) = makeAddrAndKey("debt2to1");
        _setupRepayerWithVaultCollateral(repayer, repayerSK, 10e18, 200e18);

        loanToken.mint(repayer, type(uint128).max);
        vm.prank(repayer);
        loanToken.approve(address(midnight), type(uint256).max);

        _setTotalUnits(vaultMarketId, 100e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(repayer, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData(borrower);

        uint256 maxUnits = vaultWithdrawClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, repayerSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(vaultWithdrawClamp)), cd);
    }

    /// @notice Buyer debt binding with slightly reduced totalUnits.
    function test_bindingDebt_99to100() public {
        _setTotalUnits(vaultMarketId, 99e18);

        (address repayer, uint256 repayerSK) = makeAddrAndKey("debt100to99");
        _setupRepayerWithVaultCollateral(repayer, repayerSK, 10e18, 200e18);

        loanToken.mint(repayer, type(uint128).max);
        vm.prank(repayer);
        loanToken.approve(address(midnight), type(uint256).max);

        _setTotalUnits(vaultMarketId, 99e18);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(repayer, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData(borrower);

        uint256 maxUnits = vaultWithdrawClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, repayerSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(vaultWithdrawClamp)), cd);
    }

    /* ======= Converging constraints ======= */

    /// @notice Debt and vault asset constraints converge — verifies min is selected correctly
    function test_convergingConstraints_debtAndVault() public {
        (address repayer, uint256 repayerSK) = makeAddrAndKey("converging");
        _setupRepayerWithVaultCollateral(repayer, repayerSK, 10e18, 10e18);

        loanToken.mint(repayer, type(uint128).max);
        vm.prank(repayer);
        loanToken.approve(address(midnight), type(uint256).max);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(repayer, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData(borrower);

        uint256 maxUnits = vaultWithdrawClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "converging: should have shares");

        Signature memory sig = _signOffer(offer, repayerSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(vaultWithdrawClamp)), cd);
    }

    /* ======= reduceOnly ======= */

    /// @notice reduceOnly + no debt → clamp returns 0 (prevents crossing to credit)
    function test_reduceOnly_noDebt_returnsZero() public {
        // Lender (no debt) with vault collateral — reduceOnly should prevent crossing
        _depositVaultCollateral(lender, 200e18);

        vm.prank(lender);
        midnight.setIsAuthorized(address(withdrawCallback), true, lender);

        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        bytes32 group = _freshGroup();
        Offer memory offer = Offer({
            market: vaultMarket,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(withdrawCallback),
            callbackData: abi.encode(
                IMidnightWithdrawVaultSharesCallback.CallbackData({vault: address(vault), collateralIndex: 0})
            ),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: true,
            maxUnits: MAX_OFFER_CAPACITY,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        bytes memory cd = _clampData(borrower);

        uint256 maxUnits = vaultWithdrawClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "reduceOnly + no debt should return 0");
    }

    /// @notice reduceOnly + debt → clamp caps by debt (same as debt-binding tests but explicitly reduceOnly)
    function test_reduceOnly_withDebt_capsByDebt() public {
        (address repayer, uint256 repayerSK) = makeAddrAndKey("reduceOnlyDebt");
        _setupRepayerWithVaultCollateral(repayer, repayerSK, 10e18, 200e18);

        loanToken.mint(repayer, type(uint128).max);
        vm.prank(repayer);
        loanToken.approve(address(midnight), type(uint256).max);

        bytes32 group = _freshGroup();
        Offer memory offer = Offer({
            market: vaultMarket,
            buy: true,
            maker: repayer,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TICK_HIGH,
            group: group,
            callback: address(withdrawCallback),
            callbackData: abi.encode(
                IMidnightWithdrawVaultSharesCallback.CallbackData({vault: address(vault), collateralIndex: 0})
            ),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: true,
            maxUnits: MAX_OFFER_CAPACITY,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        bytes memory cd = _clampData(borrower);

        uint256 maxUnits = vaultWithdrawClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "reduceOnly + debt should have units");

        Signature memory sig = _signOffer(offer, repayerSK);
        _verifyBoundary(maxUnits, offer, sig, borrower, ITakeClamp(address(vaultWithdrawClamp)), cd);
    }

    /* ======= Zero vault shares ======= */

    /// @notice When maker has zero vault shares as collateral, clamp returns 0
    function test_zeroVaultShares() public {
        (address emptyRepayer,) = makeAddrAndKey("emptyVaultRepayer");

        vm.startPrank(emptyRepayer);
        midnight.setIsAuthorized(address(withdrawCallback), true, emptyRepayer);
        vm.stopPrank();

        bytes32 group = _freshGroup();
        Offer memory offer = _buildBuyOffer(emptyRepayer, MAX_OFFER_CAPACITY, TICK_HIGH, group);
        bytes memory cd = _clampData(borrower);

        uint256 maxUnits = vaultWithdrawClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "zero vault shares should return 0");
    }
}
