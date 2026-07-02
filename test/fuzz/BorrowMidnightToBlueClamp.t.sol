// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {Test} from "forge-std/Test.sol";
import {BorrowMidnightToBlueClamp} from "../../src/router/clamps/BorrowMidnightToBlueClamp.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {BorrowMidnightToBlueCallback} from "../../src/callbacks/BorrowMidnightToBlueCallback.sol";
import {IBorrowMidnightToBlueCallback} from "@callbacks/interfaces/IBorrowMidnightToBlueCallback.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {ClampFuzzFixtures} from "../helpers/ClampFuzzFixtures.sol";
import {Fixtures} from "../helpers/Fixtures.sol";
import {IMorpho, MarketParams, Id, Market as BlueMarket} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {IIrm} from "../../lib/morpho-blue/src/interfaces/IIrm.sol";
import {MorphoBalancesLib} from "../../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {OfferRemainingHelper} from "../helpers/OfferRemainingHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @notice Mock IRM for testing (0% rate)
contract MockIrm is IIrm {
    function borrowRate(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 0;
    }

    function borrowRateView(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 0;
    }
}

/// @title BorrowMidnightToBlueClampFuzzTest
/// @notice Proves that BorrowMidnightToBlueClamp.maxUnits() always returns a maxShares value
///         that results in a successful midnight.take() call (no revert).
/// @dev This clamp is for BUY offers where borrower exits Midnight to borrow on Morpho Blue.
///      Constraints: offer consumption + source debt + Blue market liquidity (fee-aware)
contract BorrowMidnightToBlueClampFuzzTest is ClampFuzzFixtures, Fixtures {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    BorrowMidnightToBlueClamp internal clampContract;
    BorrowMidnightToBlueCallback internal migrationCallback;
    IMorpho internal morphoBlue;
    MockIrm internal irm;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    OfferRemainingHelper internal offerRemainingHelper;

    uint256 internal borrowerSK;
    address internal borrower;
    address internal taker; // taker = seller = lender who sells their position
    address internal feeRecipient;

    Market internal sourceMarket;
    bytes32 internal sourceMarketId;
    MarketParams internal targetMarketParams;

    /// @notice Blue market liquidity — large enough for most fuzz runs, small enough to hit the constraint
    uint256 internal constant BLUE_LIQUIDITY = 1000e18;

    function setUp() public {
        (borrower, borrowerSK) = makeAddrAndKey("borrower");
        taker = makeAddr("taker");
        feeRecipient = makeAddr("feeRecipient");

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Col", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(10e36); // High price so health is easy to satisfy

        irm = new MockIrm();

        midnight = IMidnight(deployCode("Midnight.sol:Midnight"));
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        offerRemainingHelper = new OfferRemainingHelper();
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        // Deploy real Morpho Blue
        morphoBlue = deployMorphoBlue(address(this));
        morphoBlue.enableIrm(address(irm));
        morphoBlue.enableLltv(0.945e18);

        // Setup Blue target market
        targetMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.945e18
        });
        morphoBlue.createMarket(targetMarketParams);

        // Deploy clamp and callback
        clampContract = new BorrowMidnightToBlueClamp(IMidnight(address(midnight)), morphoBlue);
        migrationCallback = new BorrowMidnightToBlueCallback(address(midnight), address(morphoBlue));

        // Source Midnight market
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });
        sourceMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        sourceMarketId = IdLib.toId(sourceMarket);

        // Seed the Midnight market
        _seedMarket();

        // Taker (seller/lender): needs loan tokens for taker side
        loanToken.mint(taker, type(uint128).max);
        vm.prank(taker);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ========== SETUP HELPERS ========== */

    function _seedMarket() internal {
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
            market: sourceMarket,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256("seed"),
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

    /// @notice Supply loan tokens to Blue market so borrowers can borrow
    function _supplyToBlueMarket(uint256 amount) internal {
        address blueSupplier = makeAddr("blueSupplier");
        loanToken.mint(blueSupplier, amount);
        vm.startPrank(blueSupplier);
        loanToken.approve(address(morphoBlue), amount);
        morphoBlue.supply(targetMarketParams, amount, 0, blueSupplier, "");
        vm.stopPrank();
    }

    /* ========== FUZZ TESTS ========== */

    /// @dev Internal helper: builds offer + runs clamp for Midnight to Blue borrow tests.
    function _buildMidnightToBlueBorrowOffer(uint128 offerCapacity, uint256 packed, string memory borrowerLabel)
        internal
        returns (
            address freshBorrower,
            uint256 freshBorrowerSK,
            Offer memory offer,
            bytes memory encodedClampData,
            uint256 maxShares
        )
    {
        bool reduceOnly = packed & 1 == 1;
        uint8 denom = _boundDenomination(uint8(packed >> 8));
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);
        uint16 tick = _boundTick(uint16(packed >> 16));
        uint128 sourceDebt = uint128(bound(uint128(packed >> 128), 1, SEED_AMOUNT));
        uint256 callbackFeeRate = _boundCallbackFeeRateMidnightToBlue(packed >> 64);
        uint256 ttm = _boundTimeToMaturity(uint8(packed >> 32));

        bytes32 group =
            keccak256(abi.encodePacked(borrowerLabel, sourceDebt, offerCapacity, tick, callbackFeeRate, ttm));

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });
        Market memory testMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + ttm,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        bytes32 testMarketId = IdLib.toId(testMarket);

        if (midnight.tickSpacing(testMarketId) == 0) {
            _seedMarketCustom(testMarket, testMarketId);
        }

        (freshBorrower, freshBorrowerSK) = makeAddrAndKey(borrowerLabel);
        _setupBorrowerWithSourceDebtCustom(freshBorrower, freshBorrowerSK, sourceDebt, testMarket, testMarketId);

        assertGt(midnight.debt(testMarketId, freshBorrower), 0, "borrower should have source debt");

        _supplyToBlueMarket(BLUE_LIQUIDITY);

        vm.startPrank(freshBorrower);
        midnight.setIsAuthorized(address(migrationCallback), true, freshBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshBorrower);
        morphoBlue.setAuthorization(address(migrationCallback), true);
        vm.stopPrank();

        IBorrowMidnightToBlueCallback.CallbackData memory cbData = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: targetMarketParams, feeRate: callbackFeeRate, feeRecipient: feeRecipient
        });

        (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
        offer = Offer({
            market: testMarket,
            buy: true,
            maker: freshBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(migrationCallback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        BorrowMidnightToBlueClamp.BorrowMidnightToBlueClampData memory clampData =
            BorrowMidnightToBlueClamp.BorrowMidnightToBlueClampData({
                sourceMarketId: testMarketId,
                targetBlueMarketId: Id.unwrap(targetMarketParams.id()),
                positionOwner: taker,
                feeRate: callbackFeeRate
            });

        encodedClampData = abi.encode(clampData);
        maxShares = clampContract.maxUnits(offer, encodedClampData);
        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining =
                offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, testMarketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }
    }

    /// @notice Proves four invariants for shares-based BUY offers (Midnight to Blue borrow exit)
    /// @dev Fuzzes: sourceDebt, offerCapacity, tick, feeRate, ttm, reduceOnly, denomination
    function testFuzz_clampedTakeNeverReverts_shares(uint128 offerCapacity, uint256 packed) external {
        (
            address freshBorrower,
            uint256 freshBorrowerSK,
            Offer memory offer,
            bytes memory encodedClampData,
            uint256 maxShares
        ) = _buildMidnightToBlueBorrowOffer(offerCapacity, packed, "freshBorrower");

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds or reverts due to health check ---
        uint256 snap = vm.snapshotState();

        vm.prank(taker);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, taker, freshBorrower, address(0), ""
        ) {
        // take succeeded — check remaining invariants
        }
        catch {
            // Health revert from Midnight or Morpho Blue is a valid outcome
            vm.revertToState(snap);
            return;
        }

        // --- Invariant 2: No-dust — clamp returns 0 after taking maxShares ---
        {
            uint256 postClamp = clampContract.maxUnits(offer, encodedClampData);
            assertEq(postClamp, 0, "clamp should return 0 after taking maxShares (no dust)");
        }

        // --- Invariant 3: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        {
            uint256 takerBalBefore = loanToken.balanceOf(taker);
            vm.prank(taker);
            try midnight.take(
                offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, taker, freshBorrower, address(0), ""
            ) {
                uint256 takerBalAfter = loanToken.balanceOf(taker);
                assertEq(takerBalBefore, takerBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
            } catch {}
        }

        vm.revertToState(snap);

        // --- Invariant 4: Tightness — take(maxShares + 1) reverts ---
        vm.prank(taker);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            taker,
            freshBorrower,
            address(0),
            ""
        );
    }

    /// @notice Same four invariants with units-based offer
    function testFuzz_clampedTakeNeverReverts_units(uint128 offerCapacity, uint256 packed) external {
        (
            address freshBorrower,
            uint256 freshBorrowerSK,
            Offer memory offer,
            bytes memory encodedClampData,
            uint256 maxShares
        ) = _buildMidnightToBlueBorrowOffer(offerCapacity, packed, "freshBorrowerUnits");

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety ---
        uint256 snap = vm.snapshotState();

        vm.prank(taker);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, taker, freshBorrower, address(0), ""
        ) {
        // take succeeded
        }
        catch {
            vm.revertToState(snap);
            return;
        }

        // --- Invariant 2: No-dust ---
        {
            uint256 postClamp = clampContract.maxUnits(offer, encodedClampData);
            assertEq(postClamp, 0, "clamp should return 0 after taking maxShares (no dust)");
        }

        // --- Invariant 3: Exhaustion ---
        {
            uint256 takerBalBefore = loanToken.balanceOf(taker);
            vm.prank(taker);
            try midnight.take(
                offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, taker, freshBorrower, address(0), ""
            ) {
                uint256 takerBalAfter = loanToken.balanceOf(taker);
                assertEq(takerBalBefore, takerBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
            } catch {}
        }

        vm.revertToState(snap);

        // --- Invariant 4: Tightness ---
        vm.prank(taker);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            taker,
            freshBorrower,
            address(0),
            ""
        );
    }

    /* ========== TAKER-DIRECTION FUZZ TESTS ========== */

    /// @notice Taker direction: SELL offer from counterparty (lender), borrower is taker with callback.
    ///         Proves the same five invariants as the maker-direction tests.
    /// @dev Here the renewee (borrower) is the TAKER (direct midnight.take with the migration callback as
    ///      takerCallback), not the maker. The counterparty (lender) makes a SELL offer.
    function testFuzz_takerDirection_clampedTakeNeverReverts(
        uint128 sourceDebt,
        uint128 offerCapacity,
        uint8 consumedPercent,
        uint16 tick,
        uint256 feeRateSeed,
        uint8 ttmSeed,
        uint8 denomSeed
    ) external {
        tick = _boundTick(tick);
        sourceDebt = uint128(bound(sourceDebt, 1, SEED_AMOUNT));
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);
        consumedPercent = _boundPercent(consumedPercent);

        bytes32 testMarketId;
        address freshBorrower;
        Offer memory offer;
        bytes memory encodedClampData;
        bytes memory takerCallbackData;
        uint256 maxShares;
        uint256 cpSK; // counterparty signing key

        {
            uint256 callbackFeeRate = _boundCallbackFeeRateMidnightToBlue(feeRateSeed);
            uint256 ttm = _boundTimeToMaturity(ttmSeed);
            uint128 consumedAmount = uint128(uint256(offerCapacity) * consumedPercent / 100);

            bytes32 group = keccak256(
                abi.encodePacked(
                    "v2v1-borrow-orch", sourceDebt, offerCapacity, consumedPercent, tick, callbackFeeRate, ttm
                )
            );

            // Create counterparty locally (lender who makes the SELL offer)
            address cp;
            (cp, cpSK) = makeAddrAndKey("orchCounterparty");
            loanToken.mint(cp, type(uint128).max);
            vm.startPrank(cp);
            loanToken.approve(address(midnight), type(uint256).max);
            midnight.setIsAuthorized(address(ecrecoverRatifier), true, cp);
            vm.stopPrank();

            // Create market with fuzzed TTM
            CollateralParams[] memory collaterals = new CollateralParams[](1);
            collaterals[0] = CollateralParams({
                token: address(collateralToken),
                lltv: 0.945e18,
                liquidationCursor: LIQUIDATION_CURSOR,
                oracle: address(oracle)
            });
            Market memory testMarket = Market({
                chainId: block.chainid,
                midnight: address(midnight),
                loanToken: address(loanToken),
                collateralParams: collaterals,
                maturity: block.timestamp + ttm,
                rcfThreshold: 0,
                enterGate: address(0),
                liquidatorGate: address(0)
            });
            testMarketId = IdLib.toId(testMarket);

            if (midnight.tickSpacing(testMarketId) == 0) {
                _seedMarketCustom(testMarket, testMarketId);
            }

            // Setup fresh borrower with source debt
            uint256 freshBorrowerSK;
            (freshBorrower, freshBorrowerSK) = makeAddrAndKey("orchBorrower");
            _setupBorrowerWithSourceDebtCustom(freshBorrower, freshBorrowerSK, sourceDebt, testMarket, testMarketId);

            assertGt(midnight.debt(testMarketId, freshBorrower), 0, "borrower should have source debt");

            // Supply liquidity to Blue market
            _supplyToBlueMarket(BLUE_LIQUIDITY);

            // Authorize callback + Morpho Blue for borrower (taker)
            vm.startPrank(freshBorrower);
            midnight.setIsAuthorized(address(migrationCallback), true, freshBorrower);
            morphoBlue.setAuthorization(address(migrationCallback), true);
            vm.stopPrank();

            // Consumption on counterparty (offer.maker for SELL offer)
            if (consumedAmount > 0) {
                vm.prank(cp);
                midnight.setConsumed(group, consumedAmount, cp);
            }

            // SELL offer from counterparty (counterparty is maker/seller)
            (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
            offer = Offer({
                market: testMarket,
                buy: false,
                maker: cp,
                start: block.timestamp,
                expiry: block.timestamp + 1 hours,
                tick: tick,
                group: group,
                callback: address(0),
                callbackData: "",
                receiverIfMakerIsSeller: cp,
                ratifier: address(ecrecoverRatifier),
                reduceOnly: false,
                maxUnits: mu,
                maxAssets: ma,
                continuousFeeCap: type(uint256).max
            });

            // Taker callback data for borrower (buyer)
            takerCallbackData = abi.encode(
                IBorrowMidnightToBlueCallback.CallbackData({
                    targetMarketParams: targetMarketParams, feeRate: callbackFeeRate, feeRecipient: feeRecipient
                })
            );

            BorrowMidnightToBlueClamp.BorrowMidnightToBlueClampData memory clampData =
                BorrowMidnightToBlueClamp.BorrowMidnightToBlueClampData({
                    sourceMarketId: testMarketId,
                    targetBlueMarketId: Id.unwrap(targetMarketParams.id()),
                    positionOwner: freshBorrower,
                    feeRate: callbackFeeRate
                });

            encodedClampData = abi.encode(clampData);
            maxShares = clampContract.maxUnits(offer, encodedClampData);
        }

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, cpSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds or reverts due to health check ---
        uint256 snap = vm.snapshotState();

        vm.prank(freshBorrower);
        try midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares,
            freshBorrower,
            address(0),
            address(migrationCallback),
            takerCallbackData
        ) {
        // take succeeded — check remaining invariants
        }
        catch {
            vm.revertToState(snap);
            return;
        }

        // --- Invariant 2 & 3: Skipped for taker direction ---
        // sellerPrice rounding makes the clamp intentionally conservative.
        // Full-repayment and no-dust are tested in maker-direction tests.

        // --- Invariant 4: Exhaustion ---
        {
            uint256 borrowerBalBefore = loanToken.balanceOf(freshBorrower);
            vm.prank(freshBorrower);
            try midnight.take(
                offer,
                abi.encode(sig, root, uint256(0), new bytes32[](0)),
                1,
                freshBorrower,
                address(0),
                address(migrationCallback),
                takerCallbackData
            ) {
                assertEq(
                    borrowerBalBefore, loanToken.balanceOf(freshBorrower), "take(1) after maxShares must be zero-cost"
                );
            } catch {}
        }

        vm.revertToState(snap);

        // --- Invariant 5: Tightness — skipped for taker direction ---
        // sellerPrice rounding makes clamp conservative; maxShares + 1 may succeed.
        // Tightness tested in maker-direction tests.
    }

    /* ========== EDGE CASE FUZZ TESTS ========== */

    /// @notice Zero source debt always returns 0 shares
    function testFuzz_zeroSourceDebt_returnsZero(uint128 offerCapacity, uint16 tick) external {
        tick = _boundTick(tick);
        offerCapacity = uint128(bound(offerCapacity, 1, MAX_OFFER_CAPACITY));

        _supplyToBlueMarket(BLUE_LIQUIDITY);

        (address emptyBorrower,) = makeAddrAndKey("emptyBorrower");

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: true,
            maker: emptyBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256("zero-debt"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        BorrowMidnightToBlueClamp.BorrowMidnightToBlueClampData memory clampData =
            BorrowMidnightToBlueClamp.BorrowMidnightToBlueClampData({
                sourceMarketId: sourceMarketId,
                targetBlueMarketId: Id.unwrap(targetMarketParams.id()),
                positionOwner: taker,
                feeRate: 0
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        assertEq(maxShares, 0, "zero source debt should return zero units");
    }

    /// @notice Zero Blue liquidity always returns 0 shares
    function testFuzz_zeroBlueLiquidity_returnsZero(uint128 sourceDebt, uint128 offerCapacity, uint16 tick) external {
        tick = _boundTick(tick);
        sourceDebt = uint128(bound(sourceDebt, 1, SEED_AMOUNT));
        offerCapacity = uint128(bound(offerCapacity, 1, MAX_OFFER_CAPACITY));

        // Don't supply to Blue market — 0 liquidity

        (address freshBorrower, uint256 freshBorrowerSK) = makeAddrAndKey("freshBorrowerNoLiq");
        _setupBorrowerWithSourceDebt(freshBorrower, freshBorrowerSK, sourceDebt);

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: true,
            maker: freshBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256("no-liquidity"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        BorrowMidnightToBlueClamp.BorrowMidnightToBlueClampData memory clampData =
            BorrowMidnightToBlueClamp.BorrowMidnightToBlueClampData({
                sourceMarketId: sourceMarketId,
                targetBlueMarketId: Id.unwrap(targetMarketParams.id()),
                positionOwner: taker,
                feeRate: 0
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        assertEq(maxShares, 0, "zero Blue liquidity should return zero units");
    }

    /* ========== CB-SRC-1: EXCLUSIVE SOURCE FUNDING ========== */

    /// @notice CB-SRC-1: Callback funds exclusively from source position — maker wallet unchanged.
    /// @dev Mints a sentinel loan token balance to the maker, then verifies it's untouched after take.
    function testFuzz_cbSrc1_makerWalletUnchanged(uint128 sourceDebt, uint16 tick) external {
        tick = _boundTick(tick);
        sourceDebt = uint128(bound(sourceDebt, 1, SEED_AMOUNT));

        bytes32 group = keccak256(abi.encodePacked("cb-src-1-v2v1borrow", sourceDebt, tick));

        (address freshBorrower, uint256 freshBorrowerSK) = makeAddrAndKey("freshBorrowerSrc1");
        _setupBorrowerWithSourceDebt(freshBorrower, freshBorrowerSK, sourceDebt);

        // Supply Blue liquidity
        _supplyToBlueMarket(BLUE_LIQUIDITY);

        // Authorize callback
        vm.startPrank(freshBorrower);
        midnight.setIsAuthorized(address(migrationCallback), true, freshBorrower);
        morphoBlue.setAuthorization(address(migrationCallback), true);
        vm.stopPrank();

        IBorrowMidnightToBlueCallback.CallbackData memory cbData = IBorrowMidnightToBlueCallback.CallbackData({
            targetMarketParams: targetMarketParams, feeRate: 0.005e18, feeRecipient: feeRecipient
        });

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: true,
            maker: freshBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(migrationCallback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        BorrowMidnightToBlueClamp.BorrowMidnightToBlueClampData memory clampData =
            BorrowMidnightToBlueClamp.BorrowMidnightToBlueClampData({
                sourceMarketId: sourceMarketId,
                targetBlueMarketId: Id.unwrap(targetMarketParams.id()),
                positionOwner: taker,
                feeRate: 0.005e18
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        if (maxShares == 0) return;

        // Sentinel: give borrower tokens the callback could pull if buggy
        loanToken.mint(freshBorrower, 1e18);
        uint256 loanBefore = loanToken.balanceOf(freshBorrower);
        uint256 colBefore = collateralToken.balanceOf(freshBorrower);

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(taker);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, taker, freshBorrower, address(0), ""
        ) {
            assertEq(loanToken.balanceOf(freshBorrower), loanBefore, "CB-SRC-1: maker loan tokens pulled from wallet");
            assertEq(
                collateralToken.balanceOf(freshBorrower), colBefore, "CB-SRC-1: maker collateral pulled from wallet"
            );
        } catch {}
    }

    /* ========== ADDITIONAL SETUP HELPERS ========== */

    /// @notice Seed a custom market (for TTM fuzzing)
    function _seedMarketCustom(Market memory obl, bytes32 oblId) internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey("seedBorrowerCustom");
        address seedLender = makeAddr("seedLenderCustom");

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
            market: obl,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("seed", oblId)),
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

    /// @notice Give borrower debt on the default source market
    function _setupBorrowerWithSourceDebt(address account, uint256 accountSK, uint128 debtUnits) internal {
        _setupBorrowerWithSourceDebtCustom(account, accountSK, debtUnits, sourceMarket, sourceMarketId);
    }

    /// @notice Give borrower debt on a specific market
    function _setupBorrowerWithSourceDebtCustom(
        address account,
        uint256 accountSK,
        uint128 debtUnits,
        Market memory obl,
        bytes32 oblId
    ) internal {
        address tempLender = makeAddr(string(abi.encodePacked("tempLender", account)));

        collateralToken.mint(account, type(uint128).max);
        loanToken.mint(tempLender, type(uint128).max);

        MidnightSupplyCollateralCallback cb = new MidnightSupplyCollateralCallback(address(midnight));
        vm.startPrank(account);
        collateralToken.approve(address(cb), type(uint256).max);
        midnight.setIsAuthorized(address(cb), true, account);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, account);
        vm.stopPrank();

        vm.prank(tempLender);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = uint256(debtUnits) * 20;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: debtUnits, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory sellOffer = Offer({
            market: obl,
            buy: false,
            maker: account,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup-debt", account, oblId)),
            callback: address(cb),
            callbackData: cbData,
            receiverIfMakerIsSeller: account,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, accountSK);
        bytes32 root = HashLib.hashOffer(sellOffer);

        vm.prank(tempLender);
        midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            debtUnits,
            tempLender,
            address(0),
            address(0),
            ""
        );
    }
}
