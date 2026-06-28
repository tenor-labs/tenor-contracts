// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {SupplyCollateralCallbackClamp} from "../../../src/router/clamps/SupplyCollateralCallbackClamp.sol";
import {Offer, Market, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {MockERC20} from "../../helpers/mocks/MockERC20.sol";
import {Oracle} from "../../helpers/Oracle.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {LIQUIDATION_CURSOR} from "../../helpers/MaxLifLib.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {TakeMathLib} from "../../../src/libraries/TakeMathLib.sol";
import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";

/// @title SCCC_OversizeProbe
/// @notice Adversarial probe asserting SupplyCollateralCallbackClamp never over-sizes the debt-limit path:
///         for any seeded seller state and offer, take(maxUnits) never reverts (CLAMP-3 / batch-DoS safety).
/// @dev Seeds existing debt + collateral so the headroom/debt-limit bound binds, gives the seller a huge collateral
///      balance/allowance so collateral never binds, fuzzes amounts/offerSellerAssets/tick/oracle/LLTV/decimals/slots
///      and maxBorrowCapacityUsage, then performs the real Midnight.take at the clamped units and asserts no revert.
contract SCCC_OversizeProbe is BoundaryTestBase {
    uint256 private _nonce;

    address internal pSeller;
    uint256 internal pSellerSK;
    MidnightSupplyCollateralCallback internal probeCallback;

    /// @dev The 8 allowed LLTV tiers below WAD (excluding the special LLTV == 1e18 case).
    function _allowedLltv(uint256 sel) internal pure returns (uint256) {
        uint256[8] memory lltvs = [uint256(0.385e18), 0.625e18, 0.77e18, 0.86e18, 0.915e18, 0.945e18, 0.965e18, 0.98e18];
        return lltvs[sel % 8];
    }

    function setUp() public override {
        super.setUp();
        (pSeller, pSellerSK) = makeAddrAndKey("probeSeller");
        probeCallback = new MidnightSupplyCollateralCallback(address(midnight));

        // Buyer (lender/taker): unlimited loan-token balance + allowance so the take is funded.
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ═══════ Probe-local market construction ═══════ */

    struct MarketCtx {
        Market market;
        bytes32 marketId;
        MockERC20[] tokens;
    }

    /// @dev Builds (and seeds) a fresh market with `slots` collaterals, decimals `dec`, lltv tier `lltv`, oracle price
    ///      `oraclePrice` (in 1e36 base for 18-dec; scaled here for other decimals). Returns the market + its tokens.
    function _buildMarket(uint256 slots, uint8 dec, uint256 lltv, uint256 oraclePriceBase)
        internal
        returns (MarketCtx memory ctx)
    {
        ctx.tokens = new MockERC20[](slots);
        CollateralParams[] memory cps = new CollateralParams[](slots);
        // oracle.price() base ORACLE_PRICE_SCALE=1e36 assumes equal decimals; the existing helper markets use
        // 10e36 for 18-dec collateral and 10e48 for 6-dec, i.e. base * 10^(36 + (18 - dec)).
        uint256 priceScaled = oraclePriceBase * (10 ** (36 + (18 - dec)));

        for (uint256 i = 0; i < slots; i++) {
            ctx.tokens[i] = new MockERC20("Col", "COL", dec);
        }
        // Midnight requires collateral tokens sorted ascending by address (no duplicates). Sort in place.
        for (uint256 i = 0; i < slots; i++) {
            for (uint256 j = i + 1; j < slots; j++) {
                if (address(ctx.tokens[j]) < address(ctx.tokens[i])) {
                    MockERC20 tmp = ctx.tokens[i];
                    ctx.tokens[i] = ctx.tokens[j];
                    ctx.tokens[j] = tmp;
                }
            }
        }
        for (uint256 i = 0; i < slots; i++) {
            Oracle o = new Oracle();
            o.setPrice(priceScaled);
            cps[i] = CollateralParams({
                token: address(ctx.tokens[i]), lltv: lltv, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(o)
            });
        }

        ctx.market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: cps,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        ctx.marketId = IdLib.toId(ctx.market);

        _seedProbeMarket(ctx, dec);
    }

    function _seedProbeMarket(MarketCtx memory ctx, uint8 dec) internal {
        uint256 slots = ctx.tokens.length;
        (address sb, uint256 sbSK) = makeAddrAndKey(string(abi.encodePacked("probeSeedB", ++_nonce, ctx.marketId)));
        address sl = makeAddr(string(abi.encodePacked("probeSeedL", _nonce, ctx.marketId)));

        loanToken.mint(sl, type(uint128).max);
        MidnightSupplyCollateralCallback cb = new MidnightSupplyCollateralCallback(address(midnight));

        vm.startPrank(sb);
        for (uint256 i = 0; i < slots; i++) {
            ctx.tokens[i].mint(sb, type(uint128).max);
            ctx.tokens[i].approve(address(cb), type(uint256).max);
        }
        midnight.setIsAuthorized(address(cb), true, sb);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, sb);
        vm.stopPrank();

        vm.prank(sl);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory seedAmounts = new uint256[](slots);
        for (uint256 i = 0; i < slots; i++) {
            seedAmounts[i] = 100 * (10 ** dec) * 50; // ample collateral so the seed take is healthy
        }
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: seedAmounts, offerSellerAssets: SEED_AMOUNT, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory seedOffer = Offer({
            market: ctx.market,
            buy: false,
            maker: sb,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: 5820,
            group: keccak256(abi.encodePacked("probeSeed", _nonce, ctx.marketId)),
            callback: address(cb),
            callbackData: cbData,
            receiverIfMakerIsSeller: sb,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(seedOffer, sbSK);
        vm.prank(sl);
        midnight.take(
            seedOffer,
            abi.encode(sig, HashLib.hashOffer(seedOffer), uint256(0), new bytes32[](0)),
            SEED_AMOUNT,
            sl,
            address(0),
            address(0),
            ""
        );
    }

    /// @dev Sets up pSeller with existing debt (so headroom binds) + huge balances/allowances on every collateral.
    /// @param colNumer/colDenom collateral supplied per debt unit = debtUnits * colNumer / colDenom (per slot). Tunes
    ///        the resulting headroom: a tight ratio (just enough to be healthy) makes the debt-limit path bind below
    ///        the offer capacity, which is the regime that triggered the old shrink-branch over-size.
    function _setupProbeSeller(MarketCtx memory ctx, uint128 debtUnits, uint256 colNumer, uint256 colDenom) internal {
        uint256 slots = ctx.tokens.length;
        address tempLender = makeAddr(string(abi.encodePacked("probeTL", ++_nonce, ctx.marketId)));
        loanToken.mint(tempLender, type(uint128).max);

        MidnightSupplyCollateralCallback cb = new MidnightSupplyCollateralCallback(address(midnight));
        vm.startPrank(pSeller);
        for (uint256 i = 0; i < slots; i++) {
            ctx.tokens[i].mint(pSeller, type(uint128).max);
            ctx.tokens[i].approve(address(cb), type(uint256).max);
            ctx.tokens[i].approve(address(probeCallback), type(uint256).max);
        }
        midnight.setIsAuthorized(address(cb), true, pSeller);
        midnight.setIsAuthorized(address(probeCallback), true, pSeller);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, pSeller);
        vm.stopPrank();

        vm.prank(tempLender);
        loanToken.approve(address(midnight), type(uint256).max);

        // colAmount in collateral-token units. The setup take is at tick 5820 (price ~ WAD), so seller assets received
        // ~ debtUnits (18-dec loan). Per-slot collateral value must cover debtUnits/slots; scale loan-unit math to the
        // collateral token's decimals. (For 18-dec, colNumer/colDenom == 20 reproduces the base-class 20x ratio.)
        uint8 dec = ctx.tokens[0].decimals();
        uint256[] memory colAmounts = new uint256[](slots);
        for (uint256 i = 0; i < slots; i++) {
            colAmounts[i] = (uint256(debtUnits) * colNumer / colDenom) * (10 ** dec) / 1e18;
        }
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: debtUnits, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory sellOffer = Offer({
            market: ctx.market,
            buy: false,
            maker: pSeller,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: 5820,
            group: keccak256(abi.encodePacked("probeDebt", _nonce, ctx.marketId)),
            callback: address(cb),
            callbackData: cbData,
            receiverIfMakerIsSeller: pSeller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, pSellerSK);
        vm.prank(tempLender);
        midnight.take(
            sellOffer,
            abi.encode(sig, HashLib.hashOffer(sellOffer), uint256(0), new bytes32[](0)),
            debtUnits,
            tempLender,
            address(0),
            address(0),
            ""
        );
    }

    /* ═══════ Core probe: clamp -> real take, assert no over-size ═══════ */

    /// @dev External wrapper so getOfferRemaining (Offer calldata) is callable from a memory-held offer.
    function offerRemaining(Offer calldata offer, bytes32 marketId) external view returns (uint256) {
        return TakeMathLib.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
    }

    /// @notice Number of fuzz iterations where the clamp's debt-limit headroom was the binding constraint (the regime
    ///         that triggered the old over-size). Persisted in storage so a coverage gate can read it across runs.
    uint256 public debtLimitBindingHits;
    /// @notice Iterations where a real, non-zero take executed.
    uint256 public realTakeHits;

    /// @dev Runs the router-faithful cycle for a built market/offer: take min(offerRemaining, clamp) and assert the
    ///      take does not revert. Returns true if a real take was attempted (r > 0).
    function _probe(MarketCtx memory ctx, Offer memory offer) internal returns (bool tookReal) {
        bytes memory cd = abi.encode(SupplyCollateralCallbackClamp.ClampData({marketId: ctx.marketId, taker: lender}));

        uint256 clampUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        // Mirror TenorRouter._capTakeUnits: cap by the offer's remaining capacity, then by the clamp.
        uint256 remaining = this.offerRemaining(offer, ctx.marketId);
        uint256 r = UtilsLib.min(remaining, clampUnits);
        // The debt-limit headroom binds (and is non-trivial) exactly when the clamp, not capacity, sets r.
        if (clampUnits > 0 && clampUnits < remaining) debtLimitBindingHits++;
        if (r == 0) return false;
        realTakeHits++;

        Signature memory sig = _signOffer(offer, pSellerSK);
        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0));

        // Monotone-safety: the router may cap any fill at or below the clamp, so take(u') must also be safe for any
        // u' in (0, r]. Probe a few interior points first (each on its own snapshot) — a revert at any is a CLAMP-3
        // violation just as much as a revert at r.
        uint256[3] memory probes = [r, r / 2 == 0 ? 1 : r / 2, uint256(1)];
        for (uint256 i = 0; i < probes.length; i++) {
            uint256 u = probes[i];
            if (u == 0 || u > r) continue;
            uint256 snap = vm.snapshotState();
            vm.prank(lender);
            midnight.take(offer, ratifierData, u, lender, address(0), address(0), "");
            vm.revertToState(snap);
        }
        return true;
    }

    function _mkOffer(
        MarketCtx memory ctx,
        uint16 tick,
        uint128 capacity,
        uint256[] memory amounts,
        uint256 offerSA,
        uint256 mbcu
    ) internal view returns (Offer memory) {
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: amounts, offerSellerAssets: offerSA, maxBorrowCapacityUsage: mbcu
            })
        );
        return Offer({
            market: ctx.market,
            buy: false,
            maker: pSeller,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256(abi.encodePacked("probeOffer", ctx.marketId, tick, offerSA, capacity)),
            callback: address(probeCallback),
            callbackData: cbData,
            receiverIfMakerIsSeller: pSeller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: capacity,
            continuousFeeCap: type(uint256).max
        });
    }

    /* ═══════ Fuzz ═══════ */

    /// @notice Adversarial fuzz: the clamp must never over-size — take(maxUnits) must not revert.
    function testFuzz_neverOversizes(
        uint16 tickRaw,
        uint128 cbAmount,
        uint128 offerSARaw,
        uint128 capacityRaw,
        uint256 lltvSel,
        uint256 oracleBase,
        uint128 existingDebt,
        bool twoSlots,
        bool sixDec,
        uint256 mbcuRaw
    ) public {
        _runOne(
            tickRaw, cbAmount, offerSARaw, capacityRaw, lltvSel, oracleBase, existingDebt, twoSlots, sixDec, mbcuRaw
        );
    }

    /// @dev One adversarial configuration: build market, seed seller debt/collateral, size with the clamp, take.
    function _runOne(
        uint16 tickRaw,
        uint128 cbAmount,
        uint128 offerSARaw,
        uint128 capacityRaw,
        uint256 lltvSel,
        uint256 oracleBase,
        uint128 existingDebt,
        bool twoSlots,
        bool sixDec,
        uint256 mbcuRaw
    ) internal {
        // Tick: multiple of 4, in (0, 5820]. Bias high so sellerPrice ~ WAD (the regime of the minimized cases).
        uint16 tick = uint16(((uint256(tickRaw) % 1455) + 1) * 4); // 4..5820
        if (uint256(tickRaw) % 3 != 0) tick = uint16(5820 - (uint256(tickRaw) % 80) * 4); // bias high 2/3 of the time
        if (tick == 0) tick = 4;

        uint8 dec = sixDec ? 6 : 18;
        uint256 slots = twoSlots ? 2 : 1;
        uint256 lltv = _allowedLltv(lltvSel);
        uint256 oracleBaseV = (oracleBase % 20) + 1; // 1..20 (loan tokens per collateral unit)

        MarketCtx memory ctx = _buildMarket(slots, dec, lltv, oracleBaseV);

        // Existing debt so headroom binds; keep modest so the setup take is feasible.
        uint128 debtUnits = uint128(bound(existingDebt, 1e18, 1e22));
        // Tight-to-moderate collateral ratio. Min healthy ratio = 1/(P*L*slots); P>=1, L>=0.385 -> >= ~2.6 single slot.
        // Bias toward tight ratios (small headroom) — the regime that triggered the old over-size.
        uint256 colNumer = bound(uint256(keccak256(abi.encode(existingDebt, lltvSel))), 3, 40);
        _setupProbeSeller(ctx, debtUnits, colNumer, 1);

        // Callback amounts: bounded to realistic token magnitudes so the callback's collateral-value math
        // (supplied * oraclePrice) cannot itself overflow uint256 (out of scope: a magnitude bound, not the
        // debt-limit over-size under test). Small relative to capacity so the debt-limit path tends to bind.
        uint256 amt = bound(cbAmount, 1, 1e8) * (10 ** dec);
        uint256[] memory amounts = new uint256[](slots);
        for (uint256 i = 0; i < slots; i++) {
            amounts[i] = amt;
        }

        // In production the offer's seller-asset capacity == the callback's offerSellerAssets denominator, so the take
        // is capacity-bound by `equivalentOfferUnits`. Mirror that: maxAssets == offerSA. Also fuzz a looser-capacity
        // regime (maxAssets up to 8x offerSA) so the debt-limit path, not capacity, dominates. offerSA is bounded so
        // the callback's collateral-value product (amount * sa * oraclePrice) cannot overflow uint256 (a magnitude
        // bound, out of scope vs. the debt-limit over-size under test).
        uint256 offerSA = bound(offerSARaw, 1e6, 1e24);
        uint128 capacity = capacityRaw % 2 == 0 ? uint128(offerSA) : uint128(bound(capacityRaw, offerSA, offerSA * 8));
        uint256 mbcu = mbcuRaw % 2 == 0 ? 0 : bound(mbcuRaw, 1, WAD - 1);

        Offer memory offer = _mkOffer(ctx, tick, capacity, amounts, offerSA, mbcu);

        // Wrap the whole thing so seed/setup infeasibilities are skipped, but a take revert at clamped units fails.
        _probe(ctx, offer);
    }

    /// @notice Deterministic coverage gate: a grid that drives many configs through the debt-limit-binding regime
    ///         (clamp < capacity) and asserts both that the regime is actually exercised and that no take over-sizes.
    ///         Runs in a single call so the counters aggregate (fuzz reverts per-run state, this does not).
    function test_coverage_debtLimitBindingExercised() public {
        // Loose-capacity (8x), tight headroom, varied LLTV/decimals/usage so the clamp's headroom is the binding cap.
        uint256[4] memory lltvSel = [uint256(0), 2, 4, 5]; // 0.385, 0.77, 0.915, 0.945
        for (uint256 a = 0; a < lltvSel.length; a++) {
            for (uint256 d = 0; d < 2; d++) {
                bool sixDec = d == 1;
                for (uint256 m = 0; m < 2; m++) {
                    // even mbcuRaw -> usage disabled (0); odd -> maxBorrowCapacityUsage = 0.9e18 + 1 (binds via usage).
                    uint256 mbcuRaw = m == 0 ? 2 : uint256(0.9e18) + 1;
                    // Large offer (offerSA ~ 1e24) with oracle price 1, tight collateral ratio, so the seller's small
                    // existing-collateral headroom binds well below the offer's (8x) capacity. capacityRaw=3 (odd).
                    _runOne(5800, 5, type(uint128).max, 3, lltvSel[a], 0, 5e21, false, sixDec, mbcuRaw);
                }
            }
        }
        assertGt(debtLimitBindingHits, 0, "debt-limit headroom regime must be exercised");
        assertGt(realTakeHits, 0, "at least one real non-zero take must execute");
    }

    /* ═══════ Deterministic reproductions of the 3 minimized over-size cases ═══════ */

    /// @dev usage=0, tick=2768, 18-dec, lltv=0.915, oracle price 1 so callbackLimit < equivalentOfferUnits (debt-limit
    ///      binds). offerSA == cbAmount == 1e12. Formerly over-sized (SellerIsLiquidatable) via the shrink branch.
    function test_minimized_case1_usage0_tick2768() public {
        MarketCtx memory ctx = _buildMarket(1, 18, 0.915e18, 1);
        // Tight collateral ratio (just above 1/L) so headroom is small and the debt limit binds below capacity.
        _setupProbeSeller(ctx, 2390e18, 12, 10); // 1.2x value at L=0.915,P=1 -> healthy, small headroom
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e12;
        Offer memory offer = _mkOffer(ctx, 2768, MAX_OFFER_CAPACITY, amounts, 1e12, 0);
        assertTrue(_probeNoRevert(ctx, offer), "case1: take(maxUnits) must not revert");
    }

    /// @dev usage=0, tick=1940, 18-dec, lltv=0.945, oracle price 1, offerSA == cbAmount == 1e12. Formerly over-sized
    ///      (SellerIsLiquidatable) by ~1e12 units.
    function test_minimized_case2_usage0_tick1940() public {
        MarketCtx memory ctx = _buildMarket(1, 18, 0.945e18, 1);
        _setupProbeSeller(ctx, 1e21, 12, 10);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e12;
        Offer memory offer = _mkOffer(ctx, 1940, MAX_OFFER_CAPACITY, amounts, 1e12, 0);
        assertTrue(_probeNoRevert(ctx, offer), "case2: take(maxUnits) must not revert");
    }

    /// @dev maxBorrowCapacityUsage path, 6-dec, lltv=0.385, tiny usage cap. This is a fuzz-minimized counterexample:
    ///      under the old code the offer's capacity (loose, > clamp) let the take run while the mbcu-scaled debt limit
    ///      was actually exceeded, reverting InvalidBorrowCapacityUsage. The new monotone-safe headroom quotes within
    ///      the usage cap. Driven through _runOne so the exact clamp-vs-capacity interaction is reproduced.
    function test_minimized_case3_usageBound_mbcu() public {
        // args from the fuzz counterexample that reverted InvalidBorrowCapacityUsage under the old clamp.
        _runOne({
            tickRaw: 2,
            cbAmount: 10423,
            offerSARaw: 532071641,
            capacityRaw: type(uint128).max - 1, // odd -> loose capacity above the clamp
            lltvSel: 895448749173096470382259453980566796412203216,
            oracleBase: 97498935231489806308874186713449671327341077787219583108741905065011708,
            existingDebt: uint128(794598537704186187107085409663),
            twoSlots: false,
            sixDec: true,
            mbcuRaw: 1061926812426179
        });
    }

    /// @dev Minimized-case driver: takes the router-faithful min(remaining, clamp) and requires no revert.
    ///      Returns true once a non-zero take has executed without reverting.
    function _probeNoRevert(MarketCtx memory ctx, Offer memory offer) internal returns (bool) {
        bytes memory cd = abi.encode(SupplyCollateralCallbackClamp.ClampData({marketId: ctx.marketId, taker: lender}));
        uint256 clampUnits = supplyCollateralCallbackClamp.maxUnits(offer, cd);
        uint256 remaining = this.offerRemaining(offer, ctx.marketId);
        uint256 r = UtilsLib.min(remaining, clampUnits);
        assertTrue(r > 0, "minimized case must produce a non-zero take");

        Signature memory sig = _signOffer(offer, pSellerSK);
        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0));
        vm.prank(lender);
        midnight.take(offer, ratifierData, r, lender, address(0), address(0), "");
        return true;
    }
}
