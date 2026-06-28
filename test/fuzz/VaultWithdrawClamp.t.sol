// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ClampFuzzFixtures} from "../helpers/ClampFuzzFixtures.sol";
import {VaultWithdrawClamp} from "../../src/router/clamps/VaultWithdrawClamp.sol";
import {MidnightWithdrawVaultSharesCallback} from "@callbacks/MidnightWithdrawVaultSharesCallback.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {MidnightSupplyVaultSharesCallback} from "@callbacks/MidnightSupplyVaultSharesCallback.sol";
import {IMidnightSupplyVaultSharesCallback} from "@callbacks/interfaces/IMidnightSupplyVaultSharesCallback.sol";
import {IMidnightWithdrawVaultSharesCallback} from "@callbacks/interfaces/IMidnightWithdrawVaultSharesCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {MockERC4626} from "../helpers/mocks/MockERC4626.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {OfferRemainingHelper} from "../helpers/OfferRemainingHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @title VaultWithdrawClampFuzzTest
/// @notice Proves that VaultWithdrawClamp.maxUnits() always returns a maxShares value
///         that results in a successful midnight.take() call (no revert).
/// @dev This clamp is for BUY offers using MidnightWithdrawVaultSharesCallback.
///      Constraints: vault collateral position (TenorRouter handles consumption)
contract VaultWithdrawClampFuzzTest is ClampFuzzFixtures {
    using UtilsLib for uint256;

    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    VaultWithdrawClamp internal clampContract;
    MidnightWithdrawVaultSharesCallback internal callback;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockERC4626 internal vault;
    Oracle internal oracle;
    OfferRemainingHelper internal offerRemainingHelper;

    uint256 internal repayerSK;
    address internal repayer;
    address internal borrower;

    Market internal market;
    bytes32 internal marketId;

    function setUp() public {
        (repayer, repayerSK) = makeAddrAndKey("repayer");
        borrower = makeAddr("borrower");

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Col", "COL", 18);
        vault = new MockERC4626(address(loanToken), "Vault", "vLOAN");
        oracle = new Oracle();
        oracle.setPrice(10e36);

        midnight = IMidnight(deployCode("Midnight.sol:Midnight"));
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        offerRemainingHelper = new OfferRemainingHelper();
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(repayer);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, repayer);

        clampContract = new VaultWithdrawClamp(IMidnight(address(midnight)));
        callback = new MidnightWithdrawVaultSharesCallback(address(midnight));

        // Market accepts vault shares as collateral
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(vault), lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        marketId = IdLib.toId(market);

        _seedMarket();

        // Borrower (taker): needs generous collateral for health checks
        loanToken.mint(address(this), 1e38);
        loanToken.approve(address(vault), 1e38);
        vault.mint(1e38, borrower);
        vm.startPrank(borrower);
        vault.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, 1e38, borrower);
        vm.stopPrank();
    }

    /* ========== SETUP HELPERS ========== */

    function _seedMarket() internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey("seedBorrower");
        address seedLender = makeAddr("seedLender");

        loanToken.mint(seedLender, type(uint128).max);
        loanToken.mint(seedBorrower, type(uint128).max);
        loanToken.mint(address(this), SEED_AMOUNT * 10);
        loanToken.approve(address(vault), SEED_AMOUNT * 10);
        vault.mint(SEED_AMOUNT * 10, seedBorrower);

        MidnightSupplyVaultSharesCallback supplyCallback = new MidnightSupplyVaultSharesCallback(address(midnight));

        vm.startPrank(seedBorrower);
        loanToken.approve(address(supplyCallback), type(uint256).max);
        vault.approve(address(supplyCallback), type(uint256).max);
        midnight.setIsAuthorized(address(supplyCallback), true, seedBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedBorrower);
        vm.stopPrank();

        vm.prank(seedLender);
        loanToken.approve(address(midnight), type(uint256).max);

        Offer memory seedOffer = Offer({
            market: market,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256("seed"),
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
        bytes32 root = HashLib.hashOffer(seedOffer);
        uint256 shares = SEED_AMOUNT;

        vm.prank(seedLender);
        midnight.take(
            seedOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            shares,
            seedLender,
            address(0),
            address(0),
            ""
        );
    }

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        return Signature({v: v, r: r, s: s});
    }

    /// @notice Helper: give repayer debt + vault collateral on market
    function _setupRepayerWithVaultCollateral(
        address account,
        uint256 accountSK,
        uint128 debtUnits,
        uint128 vaultShares
    ) internal {
        address tempLender = makeAddr(string(abi.encodePacked("tempLender", account)));

        loanToken.mint(tempLender, type(uint128).max);
        loanToken.mint(account, type(uint128).max);
        loanToken.mint(address(this), vaultShares);
        loanToken.approve(address(vault), vaultShares);
        vault.mint(vaultShares, account);

        MidnightSupplyVaultSharesCallback supplyCallback = new MidnightSupplyVaultSharesCallback(address(midnight));
        vm.startPrank(account);
        loanToken.approve(address(supplyCallback), type(uint256).max);
        vault.approve(address(supplyCallback), type(uint256).max);
        midnight.setIsAuthorized(address(supplyCallback), true, account);
        midnight.setIsAuthorized(address(callback), true, account);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, account);
        vm.stopPrank();

        vm.prank(tempLender);
        loanToken.approve(address(midnight), type(uint256).max);

        // SELL offer from account (creates debt + supplies vault collateral)
        Offer memory sellOffer = Offer({
            market: market,
            buy: false,
            maker: account,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup-repayer", account)),
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
        bytes32 root = HashLib.hashOffer(sellOffer);
        uint256 shares = debtUnits;

        vm.prank(tempLender);
        midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            shares,
            tempLender,
            address(0),
            address(0),
            ""
        );
    }

    /* ========== FUZZ TESTS ========== */

    /// @notice Proves three invariants for shares-based BUY offers with vault withdrawal (repay path):
    ///         1. Safety: take(maxShares) never reverts
    ///         2. Exhaustion: take(1) after take(maxShares) either reverts or is zero-cost
    ///         3. Tightness: take(maxShares + 1) always reverts
    function testFuzz_clampedTakeNeverReverts_shares(
        uint128 vaultCollateral,
        uint128 debtAmount,
        uint128 offerCapacity,
        uint16 tick,
        bool reduceOnly,
        uint8 denomSeed
    ) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        vaultCollateral = uint128(bound(vaultCollateral, 1, type(uint64).max)); // Reasonable vault shares
        debtAmount = uint128(bound(debtAmount, 1, SEED_AMOUNT)); // Cap to seed liquidity
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);

        bytes32 group =
            keccak256(abi.encodePacked("vault-withdraw-shares", vaultCollateral, debtAmount, offerCapacity, tick));

        // Setup fresh repayer with vault collateral + debt
        (address freshRepayer, uint256 freshRepayerSK) = makeAddrAndKey("freshRepayer");
        _setupRepayerWithVaultCollateral(freshRepayer, freshRepayerSK, debtAmount, vaultCollateral);

        uint256 actualDebt = midnight.debt(marketId, freshRepayer);
        uint128 actualVaultCollateral = midnight.collateral(marketId, freshRepayer, 0);
        assertGt(actualDebt, 0, "repayer should have debt");
        assertGt(actualVaultCollateral, 0, "repayer should have vault collateral");

        // Repayer needs loan tokens to repay
        loanToken.mint(freshRepayer, type(uint128).max);
        vm.prank(freshRepayer);
        loanToken.approve(address(midnight), type(uint256).max);

        // BUY offer from repayer (repay + withdraw vault collateral)
        (uint256 mu, uint256 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: market,
            buy: true,
            maker: freshRepayer,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(callback),
            callbackData: abi.encode(
                IMidnightWithdrawVaultSharesCallback.CallbackData({vault: address(vault), collateralIndex: 0})
            ),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        VaultWithdrawClamp.VaultWithdrawClampData memory clampData = VaultWithdrawClamp.VaultWithdrawClampData({
            vault: address(vault), collateralIndex: 0, marketId: marketId, callback: address(callback), taker: borrower
        });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        // After external cap, re-check zero-amount guard (capped value may round to 0 assets)
        if (maxShares == 0) return;
        {
            uint256 buyerPrice = TickLib.tickToPrice(offer.tick);
            if (buyerPrice > 0 && maxShares.mulDivDown(buyerPrice, WAD) == 0) return;
        }

        Signature memory sig = _signOffer(offer, freshRepayerSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, borrower, borrower, address(0), ""
        );

        // --- Invariant 2: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        uint256 buyerBalBefore = loanToken.balanceOf(freshRepayer);
        vm.prank(borrower);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, borrower, borrower, address(0), ""
        ) {
            uint256 buyerBalAfter = loanToken.balanceOf(freshRepayer);
            assertEq(buyerBalBefore, buyerBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
        } catch {}

        vm.revertToState(snap);

        // --- Invariant 3: Tightness — take(maxShares + 1) reverts ---
        vm.prank(borrower);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            borrower,
            borrower,
            address(0),
            ""
        );
    }

    /// @notice Same three invariants (safety, exhaustion, tightness) with units-based offer.
    function testFuzz_clampedTakeNeverReverts_units(
        uint128 vaultCollateral,
        uint128 debtAmount,
        uint128 offerCapacity,
        uint16 tick,
        bool reduceOnly,
        uint8 denomSeed
    ) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        vaultCollateral = uint128(bound(vaultCollateral, 1, type(uint64).max));
        debtAmount = uint128(bound(debtAmount, 1, SEED_AMOUNT));
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);

        bytes32 group =
            keccak256(abi.encodePacked("vault-withdraw-units", vaultCollateral, debtAmount, offerCapacity, tick));

        (address freshRepayer, uint256 freshRepayerSK) = makeAddrAndKey("freshRepayerUnits");
        _setupRepayerWithVaultCollateral(freshRepayer, freshRepayerSK, debtAmount, vaultCollateral);

        uint256 actualDebt = midnight.debt(marketId, freshRepayer);
        uint128 actualVaultCollateral = midnight.collateral(marketId, freshRepayer, 0);
        assertGt(actualDebt, 0, "repayer should have debt");
        assertGt(actualVaultCollateral, 0, "repayer should have vault collateral");

        loanToken.mint(freshRepayer, type(uint128).max);
        vm.prank(freshRepayer);
        loanToken.approve(address(midnight), type(uint256).max);

        (uint256 mu, uint256 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: market,
            buy: true,
            maker: freshRepayer,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(callback),
            callbackData: abi.encode(
                IMidnightWithdrawVaultSharesCallback.CallbackData({vault: address(vault), collateralIndex: 0})
            ),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        VaultWithdrawClamp.VaultWithdrawClampData memory clampData = VaultWithdrawClamp.VaultWithdrawClampData({
            vault: address(vault), collateralIndex: 0, marketId: marketId, callback: address(callback), taker: borrower
        });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        // After external cap, re-check zero-amount guard (capped value may round to 0 assets)
        if (maxShares == 0) return;
        {
            uint256 buyerPrice = TickLib.tickToPrice(offer.tick);
            if (buyerPrice > 0 && maxShares.mulDivDown(buyerPrice, WAD) == 0) return;
        }

        Signature memory sig = _signOffer(offer, freshRepayerSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, borrower, borrower, address(0), ""
        );

        // --- Invariant 2: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        uint256 buyerBalBefore = loanToken.balanceOf(freshRepayer);
        vm.prank(borrower);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, borrower, borrower, address(0), ""
        ) {
            uint256 buyerBalAfter = loanToken.balanceOf(freshRepayer);
            assertEq(buyerBalBefore, buyerBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
        } catch {}

        vm.revertToState(snap);

        // --- Invariant 3: Tightness — take(maxShares + 1) reverts ---
        vm.prank(borrower);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            borrower,
            borrower,
            address(0),
            ""
        );
    }

    /* ========== EDGE CASE FUZZ TESTS ========== */

    /// @notice Zero vault collateral always returns 0 shares
    function testFuzz_zeroVaultCollateral_returnsZero(uint128 offerCapacity, uint16 tick) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        offerCapacity = uint128(bound(offerCapacity, 1, MAX_OFFER_CAPACITY));

        (address emptyRepayer,) = makeAddrAndKey("emptyRepayer");

        vm.startPrank(emptyRepayer);
        midnight.setIsAuthorized(address(callback), true, emptyRepayer);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, emptyRepayer);
        vm.stopPrank();

        Offer memory offer = Offer({
            market: market,
            buy: true,
            maker: emptyRepayer,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256("zero-vault-col"),
            callback: address(callback),
            callbackData: abi.encode(
                IMidnightWithdrawVaultSharesCallback.CallbackData({vault: address(vault), collateralIndex: 0})
            ),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        VaultWithdrawClamp.VaultWithdrawClampData memory clampData = VaultWithdrawClamp.VaultWithdrawClampData({
            vault: address(vault), collateralIndex: 0, marketId: marketId, callback: address(callback), taker: borrower
        });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        assertEq(maxShares, 0, "zero vault collateral should return zero units");
    }
}
