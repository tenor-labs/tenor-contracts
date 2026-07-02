// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ClampFuzzFixtures} from "../helpers/ClampFuzzFixtures.sol";
import {VaultSupplyClamp} from "../../src/router/clamps/VaultSupplyClamp.sol";
import {MidnightSupplyVaultSharesCallback} from "@callbacks/MidnightSupplyVaultSharesCallback.sol";
import {IMidnightSupplyVaultSharesCallback} from "@callbacks/interfaces/IMidnightSupplyVaultSharesCallback.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {MockERC4626} from "../helpers/mocks/MockERC4626.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {OfferRemainingHelper} from "../helpers/OfferRemainingHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @title VaultSupplyClampFuzzTest
/// @notice Proves that VaultSupplyClamp.maxUnits() always returns a maxShares value
///         that results in a successful midnight.take() call (no revert).
/// @dev This clamp is for SELL offers using MidnightSupplyVaultSharesCallback.
///      Constraints: loan token balance/allowance + vault deposit capacity (TenorRouter handles consumption)
///
contract VaultSupplyClampFuzzTest is ClampFuzzFixtures {
    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    VaultSupplyClamp internal clampContract;
    MidnightSupplyVaultSharesCallback internal callback;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockERC4626 internal vault;
    Oracle internal oracle;
    OfferRemainingHelper internal offerRemainingHelper;

    uint256 internal borrowerSK;
    address internal borrower;
    address internal lender;

    Market internal market;
    bytes32 internal marketId;

    using UtilsLib for uint256;

    uint256 internal constant LLTV = 0.945e18;
    uint256 internal constant ADDITIONAL_DEPOSIT_PERCENT = 0.1e18; // 10% (used for seed + edge case tests)
    uint256 internal constant ORACLE_PRICE = 10e36;

    /// @dev Computes the minimum additionalDepositPercent to guarantee health at a given tick.
    ///      health requires: (1 + pct) * bondPrice * oraclePrice / 1e36 * lltv >= WAD
    ///      → pct >= WAD * 1e36 / (bondPrice * oraclePrice * lltv / WAD) - WAD
    function _minAdditionalDepositPercent(uint16 tick) internal pure returns (uint256) {
        uint256 bondPrice = TickLib.tickToPrice(tick);
        // denominator = bondPrice * ORACLE_PRICE / 1e36 * LLTV / WAD
        uint256 denom = bondPrice.mulDivDown(ORACLE_PRICE, 1e36).mulDivDown(LLTV, WAD);
        if (denom == 0) return type(uint256).max;
        uint256 minPct = WAD.mulDivUp(WAD, denom);
        return minPct > WAD ? minPct - WAD + 0.01e18 : 0.01e18; // 1% buffer
    }

    function setUp() public {
        (borrower, borrowerSK) = makeAddrAndKey("borrower");
        lender = makeAddr("lender");

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

        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        clampContract = new VaultSupplyClamp(IMidnight(address(midnight)));
        callback = new MidnightSupplyVaultSharesCallback(address(midnight));

        // Market accepts vault shares as collateral
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(vault), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
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

        // Lender (buyer/taker): unlimited balance and allowance
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ========== SETUP HELPERS ========== */

    function _seedMarket() internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey("seedBorrower");
        address seedLender = makeAddr("seedLender");

        loanToken.mint(seedLender, type(uint128).max);
        loanToken.mint(seedBorrower, type(uint128).max);

        vm.startPrank(seedBorrower);
        loanToken.approve(address(callback), type(uint256).max);
        midnight.setIsAuthorized(address(callback), true, seedBorrower);
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
            callback: address(callback),
            callbackData: abi.encode(
                IMidnightSupplyVaultSharesCallback.CallbackData({
                    vault: address(vault), collateralIndex: 0, additionalDepositPercent: ADDITIONAL_DEPOSIT_PERCENT
                })
            ),
            receiverIfMakerIsSeller: address(callback),
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

    function _buildClampData() internal view returns (VaultSupplyClamp.VaultSupplyClampData memory) {
        return VaultSupplyClamp.VaultSupplyClampData({
            loanToken: address(loanToken),
            vault: address(vault),
            callback: address(callback),
            marketId: marketId,
            taker: lender
        });
    }

    /* ========== FUZZ TESTS ========== */

    /// @notice Proves four invariants for shares-based SELL offers with vault supply:
    ///         1. Safety: take(maxShares) never reverts
    ///         2. CB-DUST: callback retains no loan tokens or vault shares
    ///         3. Exhaustion: take(1) after take(maxShares) either reverts or is zero-cost
    ///         4. Tightness: take(maxShares + 1) always reverts
    function testFuzz_clampedTakeNeverReverts_shares(
        uint128 loanTokenBalance,
        uint128 loanTokenAllowance,
        uint128 offerCapacity,
        uint16 tick,
        bool reduceOnly,
        uint8 denomSeed,
        uint256 additionalDepositPct
    ) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        uint256 minPct = _minAdditionalDepositPercent(tick);
        // Clamp inverse is tight only when additionalDepositPercent < WAD (two-step ceiling guarantee).
        // additionalDepositPercent >= WAD means >100% extra — unrealistic and breaks the guarantee.
        if (minPct >= WAD) return;
        uint256 additionalDepositPercent = bound(additionalDepositPct, minPct, WAD - 1);
        loanTokenBalance = uint128(bound(loanTokenBalance, 0, type(uint128).max));
        loanTokenAllowance = uint128(bound(loanTokenAllowance, 0, type(uint128).max));
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);

        bytes32 group = keccak256(
            abi.encodePacked("vault-supply-shares", loanTokenBalance, loanTokenAllowance, offerCapacity, tick)
        );

        (address freshBorrower, uint256 freshBorrowerSK) = makeAddrAndKey("freshBorrower");

        loanToken.mint(freshBorrower, loanTokenBalance);

        vm.startPrank(freshBorrower);
        loanToken.approve(address(callback), loanTokenAllowance);
        midnight.setIsAuthorized(address(callback), true, freshBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshBorrower);
        vm.stopPrank();

        (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: market,
            buy: false,
            maker: freshBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(callback),
            callbackData: abi.encode(
                IMidnightSupplyVaultSharesCallback.CallbackData({
                    vault: address(vault), collateralIndex: 0, additionalDepositPercent: additionalDepositPercent
                })
            ),
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        VaultSupplyClamp.VaultSupplyClampData memory clampData = _buildClampData();
        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(lender);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, lender, address(0), address(0), ""
        );

        // --- Invariant 2: CB-DUST — callback retains no tokens ---
        assertEq(loanToken.balanceOf(address(callback)), 0, "CB-DUST-1: callback retained loan tokens");
        assertEq(vault.balanceOf(address(callback)), 0, "CB-DUST-2: callback retained vault shares");

        // --- Invariant 3: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        uint256 lenderBalBefore = loanToken.balanceOf(lender);
        vm.prank(lender);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, lender, address(0), address(0), ""
        ) {
            uint256 lenderBalAfter = loanToken.balanceOf(lender);
            assertEq(lenderBalBefore, lenderBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
        } catch {}

        vm.revertToState(snap);

        // --- Invariant 4: Tightness — take(maxShares + 1) reverts ---
        vm.prank(lender);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            lender,
            address(0),
            address(0),
            ""
        );
    }

    /// @notice Proves four invariants for units-based SELL offers with vault supply:
    ///         1. Safety: take(maxShares) never reverts
    ///         2. CB-DUST: callback retains no loan tokens or vault shares
    ///         3. Exhaustion: take(1) after take(maxShares) either reverts or is zero-cost
    ///         4. Tightness: take(maxShares + 1) always reverts
    function testFuzz_clampedTakeNeverReverts_units(
        uint128 loanTokenBalance,
        uint128 loanTokenAllowance,
        uint128 offerCapacity,
        uint16 tick,
        bool reduceOnly,
        uint8 denomSeed,
        uint256 additionalDepositPct
    ) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        uint256 minPct = _minAdditionalDepositPercent(tick);
        if (minPct >= WAD) return;
        uint256 additionalDepositPercent = bound(additionalDepositPct, minPct, WAD - 1);
        loanTokenBalance = uint128(bound(loanTokenBalance, 0, type(uint128).max));
        loanTokenAllowance = uint128(bound(loanTokenAllowance, 0, type(uint128).max));
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);

        bytes32 group = keccak256(
            abi.encodePacked("vault-supply-units", loanTokenBalance, loanTokenAllowance, offerCapacity, tick)
        );

        (address freshBorrower, uint256 freshBorrowerSK) = makeAddrAndKey("freshBorrowerUnits");

        loanToken.mint(freshBorrower, loanTokenBalance);

        vm.startPrank(freshBorrower);
        loanToken.approve(address(callback), loanTokenAllowance);
        midnight.setIsAuthorized(address(callback), true, freshBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshBorrower);
        vm.stopPrank();

        (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: market,
            buy: false,
            maker: freshBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(callback),
            callbackData: abi.encode(
                IMidnightSupplyVaultSharesCallback.CallbackData({
                    vault: address(vault), collateralIndex: 0, additionalDepositPercent: additionalDepositPercent
                })
            ),
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        VaultSupplyClamp.VaultSupplyClampData memory clampData = _buildClampData();
        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(lender);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, lender, address(0), address(0), ""
        );

        // --- Invariant 2: CB-DUST — callback retains no tokens ---
        assertEq(loanToken.balanceOf(address(callback)), 0, "CB-DUST-1: callback retained loan tokens");
        assertEq(vault.balanceOf(address(callback)), 0, "CB-DUST-2: callback retained vault shares");

        // --- Invariant 3: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        uint256 lenderBalBefore = loanToken.balanceOf(lender);
        vm.prank(lender);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, lender, address(0), address(0), ""
        ) {
            uint256 lenderBalAfter = loanToken.balanceOf(lender);
            assertEq(lenderBalBefore, lenderBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
        } catch {}

        vm.revertToState(snap);

        // --- Invariant 4: Tightness — take(maxShares + 1) reverts ---
        vm.prank(lender);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            lender,
            address(0),
            address(0),
            ""
        );
    }

    /* ========== EDGE CASE FUZZ TESTS ========== */

    /// @notice Zero loan token balance always returns 0 shares
    function testFuzz_zeroLoanTokenBalance_returnsZero(uint128 offerCapacity, uint16 tick) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        offerCapacity = uint128(bound(offerCapacity, 1, MAX_OFFER_CAPACITY));

        (address emptyBorrower,) = makeAddrAndKey("emptyBorrower");

        vm.startPrank(emptyBorrower);
        loanToken.approve(address(callback), type(uint256).max);
        midnight.setIsAuthorized(address(callback), true, emptyBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, emptyBorrower);
        vm.stopPrank();

        Offer memory offer = Offer({
            market: market,
            buy: false,
            maker: emptyBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256("zero-balance"),
            callback: address(callback),
            callbackData: abi.encode(
                IMidnightSupplyVaultSharesCallback.CallbackData({
                    vault: address(vault), collateralIndex: 0, additionalDepositPercent: ADDITIONAL_DEPOSIT_PERCENT
                })
            ),
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        VaultSupplyClamp.VaultSupplyClampData memory clampData = _buildClampData();
        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        assertEq(maxShares, 0, "zero loan token balance should return zero units");
    }

    /// @notice Zero loan token allowance always returns 0 shares
    function testFuzz_zeroLoanTokenAllowance_returnsZero(uint128 loanTokenBalance, uint128 offerCapacity, uint16 tick)
        external
    {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        loanTokenBalance = uint128(bound(loanTokenBalance, 1, type(uint128).max));
        offerCapacity = uint128(bound(offerCapacity, 1, MAX_OFFER_CAPACITY));

        (address borrowerNoAllowance,) = makeAddrAndKey("borrowerNoAllowance");

        loanToken.mint(borrowerNoAllowance, loanTokenBalance);

        vm.startPrank(borrowerNoAllowance);
        loanToken.approve(address(callback), 0);
        midnight.setIsAuthorized(address(callback), true, borrowerNoAllowance);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrowerNoAllowance);
        vm.stopPrank();

        Offer memory offer = Offer({
            market: market,
            buy: false,
            maker: borrowerNoAllowance,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256("zero-allowance"),
            callback: address(callback),
            callbackData: abi.encode(
                IMidnightSupplyVaultSharesCallback.CallbackData({
                    vault: address(vault), collateralIndex: 0, additionalDepositPercent: ADDITIONAL_DEPOSIT_PERCENT
                })
            ),
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        VaultSupplyClamp.VaultSupplyClampData memory clampData = _buildClampData();
        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        assertEq(maxShares, 0, "zero loan token allowance should return zero units");
    }
}
