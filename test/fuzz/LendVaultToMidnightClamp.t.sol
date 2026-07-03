// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {Test} from "forge-std/Test.sol";
import {LendVaultToMidnightClamp} from "../../src/router/clamps/LendVaultToMidnightClamp.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
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
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {ClampFuzzFixtures} from "../helpers/ClampFuzzFixtures.sol";
import {IMorpho} from "@morphoBlue/interfaces/IMorpho.sol";
import {OfferRemainingHelper} from "../helpers/OfferRemainingHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @title LendVaultToMidnightClampFuzzTest
/// @notice Proves that LendVaultToMidnightClamp.maxUnits() always returns a maxShares value
///         that results in a successful midnight.take() call (no revert).
/// @dev This clamp is for Vault to Midnight lend migration.
///      Constraints: offer consumption + auction snapshot + vault liquidity
///      CRITICAL: Uses auction snapshot, NOT current position
contract LendVaultToMidnightClampFuzzTest is ClampFuzzFixtures {
    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    LendVaultToMidnightClamp internal clampContract;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockERC4626 internal sourceVault;
    Oracle internal oracle;
    OfferRemainingHelper internal offerRemainingHelper;

    uint256 internal lenderSK;
    address internal lender;
    uint256 internal borrowerSK;
    address internal borrower;

    Market internal targetMarket;
    bytes32 internal targetMarketId;

    function setUp() public {
        (lender, lenderSK) = makeAddrAndKey("lender");
        (borrower, borrowerSK) = makeAddrAndKey("borrower");

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Col", "COL", 18);
        sourceVault = new MockERC4626(address(loanToken), "Vault", "vLOAN");
        oracle = new Oracle();
        oracle.setPrice(10e36);

        midnight = IMidnight(deployCode("Midnight.sol:Midnight"));
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        offerRemainingHelper = new OfferRemainingHelper();
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);
        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        // Deploy Morpho Blue for clamp constructor (needed for TENOR_VAULT_V2 path)
        IMorpho morphoBlue = IMorpho(deployCode("test/bin/Morpho.json", abi.encode(address(this))));
        clampContract = new LendVaultToMidnightClamp(IMidnight(address(midnight)), morphoBlue);

        // Create Midnight target market
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });
        targetMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        targetMarketId = IdLib.toId(targetMarket);

        _seedTargetMarket();

        // Borrower (taker): unlimited collateral for health
        collateralToken.mint(borrower, 1e38);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(targetMarket, 0, 1e38, borrower);
        vm.stopPrank();
    }

    /* ========== SETUP HELPERS ========== */

    function _seedTargetMarket() internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey("seedBorrower");
        address seedLender = makeAddr("seedLender");

        loanToken.mint(seedLender, type(uint128).max);
        collateralToken.mint(seedBorrower, type(uint128).max);

        MidnightSupplyCollateralCallback setupCb = new MidnightSupplyCollateralCallback(address(midnight));

        vm.startPrank(seedBorrower);
        collateralToken.approve(address(setupCb), type(uint256).max);
        midnight.setIsAuthorized(address(setupCb), true, seedBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedBorrower);
        vm.stopPrank();

        vm.prank(seedLender);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = SEED_AMOUNT * 10;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: SEED_AMOUNT, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory seedOffer = Offer({
            market: targetMarket,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256("seed-v2"),
            callback: address(setupCb),
            callbackData: cbData,
            receiverIfMakerIsSeller: seedBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(seedOffer, seedBorrowerSK);
        bytes32 root = HashLib.hashOffer(seedOffer);

        vm.prank(seedLender);
        midnight.take(
            seedOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            SEED_AMOUNT,
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

    function _seedMarket(Market memory market, bytes32 marketId) internal {
        (address seedBorrower2, uint256 seedBorrowerSK2) = makeAddrAndKey(string(abi.encodePacked("seed2", marketId)));
        address seedLender2 = makeAddr(string(abi.encodePacked("lender2", marketId)));

        loanToken.mint(seedLender2, type(uint128).max);
        collateralToken.mint(seedBorrower2, type(uint128).max);

        MidnightSupplyCollateralCallback setupCb2 = new MidnightSupplyCollateralCallback(address(midnight));

        vm.startPrank(seedBorrower2);
        collateralToken.approve(address(setupCb2), type(uint256).max);
        midnight.setIsAuthorized(address(setupCb2), true, seedBorrower2);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedBorrower2);
        vm.stopPrank();

        vm.prank(seedLender2);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts2 = new uint256[](1);
        colAmounts2[0] = SEED_AMOUNT * 10;
        bytes memory cbData2 = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts2, offerSellerAssets: SEED_AMOUNT, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory seedOffer2 = Offer({
            market: market,
            buy: false,
            maker: seedBorrower2,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("seed2", marketId)),
            callback: address(setupCb2),
            callbackData: cbData2,
            receiverIfMakerIsSeller: seedBorrower2,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig2 = _signOffer(seedOffer2, seedBorrowerSK2);
        bytes32 root2 = HashLib.hashOffer(seedOffer2);

        vm.prank(seedLender2);
        midnight.take(
            seedOffer2,
            abi.encode(sig2, root2, uint256(0), new bytes32[](0)),
            SEED_AMOUNT,
            seedLender2,
            address(0),
            address(0),
            ""
        );
    }

    /// @notice Helper: Setup lender with vault shares
    function _setupLenderWithVaultShares(address account, uint128 vaultShares, uint128 vaultLiquidity) internal {
        // Mint vault shares to lender (simulating prior vault deposits)
        // sourceVault.mint() calls transferFrom on the loan token, so we need to fund + approve
        uint256 assetsNeeded = sourceVault.previewMint(vaultShares);
        loanToken.mint(address(this), assetsNeeded);
        loanToken.approve(address(sourceVault), assetsNeeded);
        sourceVault.mint(vaultShares, account);
        // Top up vault liquidity if needed (extra loan tokens beyond what mint deposited)
        if (vaultLiquidity > assetsNeeded) {
            loanToken.mint(address(sourceVault), vaultLiquidity - assetsNeeded);
        }

        // Give lender loan tokens + Midnight approval so the take works without a real callback.
        // In prod, the callback would handle vault→loan token conversion.
        loanToken.mint(account, type(uint128).max);
        vm.prank(account);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ========== FUZZ TESTS ========== */

    /// @notice Proves invariants for shares-based BUY offers (Vault to Midnight lend migration):
    ///         1. Safety: take(maxShares) never reverts
    ///         2. No-dust + Exhaustion (when vault wasn't the bottleneck)
    ///         3. Tightness: take(maxShares + 1) always reverts
    /// @dev Fuzzes BOTH fee dimensions: callback feeRate (0-50%) + settlement fee (via TTM).
    function testFuzz_clampedTakeNeverReverts_shares(
        uint128 snapshotShares,
        uint128 vaultLiquidity,
        uint128 offerCapacity,
        uint16 tick,
        uint256 feeRateSeed,
        uint8 ttmSeed,
        bool reduceOnly,
        uint8 denomSeed
    ) external {
        tick = _boundTick(tick);
        snapshotShares = uint128(bound(snapshotShares, 1e6, 1e24));
        vaultLiquidity = uint128(bound(vaultLiquidity, uint256(snapshotShares) / 2, uint256(snapshotShares) * 2));
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);
        uint256 callbackFeeRate = _boundCallbackFeeRate(feeRateSeed);
        uint256 ttm = _boundTimeToMaturity(ttmSeed);

        bytes32 group = keccak256(
            abi.encodePacked(
                "v1v2-lend-shares", snapshotShares, vaultLiquidity, offerCapacity, tick, callbackFeeRate, ttm
            )
        );

        // Create custom target market with specific TTM for settlement fee testing
        Market memory customTarget = targetMarket;
        customTarget.maturity = block.timestamp + ttm;
        bytes32 customTargetId = IdLib.toId(customTarget);

        if (midnight.tickSpacing(customTargetId) == 0) {
            _seedMarket(customTarget, customTargetId);
            collateralToken.mint(borrower, 1e38);
            vm.prank(borrower);
            midnight.supplyCollateral(customTarget, 0, 1e38, borrower);
        }

        // Setup fresh lender with vault shares
        (address freshLender, uint256 freshLenderSK) = makeAddrAndKey("freshLender");
        vm.prank(freshLender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshLender);

        _setupLenderWithVaultShares(freshLender, snapshotShares, vaultLiquidity);

        // BUY offer on target market (migrate vault shares to Midnight lending)
        (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: customTarget,
            buy: true,
            maker: freshLender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        LendVaultToMidnightClamp.LendVaultToMidnightClampData memory clampData =
            LendVaultToMidnightClamp.LendVaultToMidnightClampData({
                sourceVault: address(sourceVault),
                marketId: customTargetId,
                positionOwner: borrower,
                feeRate: callbackFeeRate,
                vaultType: LendVaultToMidnightClamp.VaultType.ERC4626,
                morphoBlueMarketId: bytes32(0)
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining =
                offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, customTargetId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshLenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, borrower, borrower, address(0), ""
        );

        // --- Invariant 2: No-dust + Exhaustion ---
        // When vault liquidity is binding, the test's callback-less take doesn't consume vault state,
        // so the clamp will still see available vault liquidity. Skip no-dust in that case.
        {
            uint256 postClamp = clampContract.maxUnits(offer, abi.encode(clampData));
            if (postClamp == 0) {
                uint256 lenderBalBefore = loanToken.balanceOf(freshLender);
                vm.prank(borrower);
                try midnight.take(
                    offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, borrower, borrower, address(0), ""
                ) {
                    uint256 lenderBalAfter = loanToken.balanceOf(freshLender);
                    assertEq(
                        lenderBalBefore, lenderBalAfter, "take(1) after maxShares must be zero-cost if it succeeds"
                    );
                } catch {}
            }
        }

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

    /// @notice Same invariants with units-based offer
    /// @dev Fuzzes BOTH fee dimensions: callback feeRate (0-50%) + settlement fee (via TTM).
    function testFuzz_clampedTakeNeverReverts_units(
        uint128 snapshotShares,
        uint128 vaultLiquidity,
        uint128 offerCapacity,
        uint16 tick,
        uint256 feeRateSeed,
        uint8 ttmSeed,
        bool reduceOnly,
        uint8 denomSeed
    ) external {
        tick = _boundTick(tick);
        snapshotShares = uint128(bound(snapshotShares, 1e6, 1e24));
        vaultLiquidity = uint128(bound(vaultLiquidity, uint256(snapshotShares) / 2, uint256(snapshotShares) * 2));
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);
        uint256 callbackFeeRate = _boundCallbackFeeRate(feeRateSeed);
        uint256 ttm = _boundTimeToMaturity(ttmSeed);

        bytes32 group = keccak256(
            abi.encodePacked(
                "v1v2-lend-units", snapshotShares, vaultLiquidity, offerCapacity, tick, callbackFeeRate, ttm
            )
        );

        Market memory customTarget = targetMarket;
        customTarget.maturity = block.timestamp + ttm;
        bytes32 customTargetId = IdLib.toId(customTarget);

        if (midnight.tickSpacing(customTargetId) == 0) {
            _seedMarket(customTarget, customTargetId);
            collateralToken.mint(borrower, 1e38);
            vm.prank(borrower);
            midnight.supplyCollateral(customTarget, 0, 1e38, borrower);
        }

        (address freshLender, uint256 freshLenderSK) = makeAddrAndKey("freshLenderUnits");
        vm.prank(freshLender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshLender);

        _setupLenderWithVaultShares(freshLender, snapshotShares, vaultLiquidity);

        (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: customTarget,
            buy: true,
            maker: freshLender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        LendVaultToMidnightClamp.LendVaultToMidnightClampData memory clampData =
            LendVaultToMidnightClamp.LendVaultToMidnightClampData({
                sourceVault: address(sourceVault),
                marketId: customTargetId,
                positionOwner: borrower,
                feeRate: callbackFeeRate,
                vaultType: LendVaultToMidnightClamp.VaultType.ERC4626,
                morphoBlueMarketId: bytes32(0)
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining =
                offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, customTargetId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshLenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety ---
        uint256 snap = vm.snapshotState();

        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, borrower, borrower, address(0), ""
        );

        // --- Invariant 2: No-dust + Exhaustion ---
        {
            uint256 postClamp = clampContract.maxUnits(offer, abi.encode(clampData));
            if (postClamp == 0) {
                uint256 lenderBalBefore = loanToken.balanceOf(freshLender);
                vm.prank(borrower);
                try midnight.take(
                    offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, borrower, borrower, address(0), ""
                ) {
                    uint256 lenderBalAfter = loanToken.balanceOf(freshLender);
                    assertEq(
                        lenderBalBefore, lenderBalAfter, "take(1) after maxShares must be zero-cost if it succeeds"
                    );
                } catch {}
            }
        }

        vm.revertToState(snap);

        // --- Invariant 3: Tightness ---
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

    /// @notice Zero vault liquidity should constrain withdrawals
    function testFuzz_zeroVaultLiquidity_returnsZero(uint128 snapshotShares, uint128 offerCapacity, uint16 tick)
        external
    {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        snapshotShares = uint128(bound(snapshotShares, 1e6, 1e24));
        offerCapacity = uint128(bound(offerCapacity, 1, MAX_OFFER_CAPACITY));

        (address freshLender, uint256 freshLenderSK) = makeAddrAndKey("freshLenderZeroLiq");
        vm.prank(freshLender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshLender);

        // Setup lender with vault shares, then override maxWithdraw to 0
        // to simulate zero vault liquidity (mock doesn't model liquidity constraints)
        _setupLenderWithVaultShares(freshLender, snapshotShares, 0);
        sourceVault.setMaxWithdrawOverride(freshLender, 0);

        Offer memory offer = Offer({
            market: targetMarket,
            buy: true,
            maker: freshLender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256("zero-liq"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        LendVaultToMidnightClamp.LendVaultToMidnightClampData memory clampData =
            LendVaultToMidnightClamp.LendVaultToMidnightClampData({
                sourceVault: address(sourceVault),
                marketId: targetMarketId,
                positionOwner: borrower,
                feeRate: 0,
                vaultType: LendVaultToMidnightClamp.VaultType.ERC4626,
                morphoBlueMarketId: bytes32(0)
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        assertEq(maxShares, 0, "zero vault liquidity should return zero units");
    }
}
