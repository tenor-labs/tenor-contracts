// perf kill overlay BorrowBlueToMidnightCallback/many: union of the stub sets of the two prior BBM kill
// channels (b11_b2_b14 and b11_b3_b4_b8_b14_t) plus the K1 kill-scene pins — every stub is a pure widening
// and both mutants' UNSAT arguments live entirely in the concrete callback body + concrete Blue
// repay/withdrawCollateral, so the clean-src WITNESS gate on this same conf is the only soundness obligation.
// The production footprint matrix downgrades B3/B8/B9 to SIDE_EFFECT_RELEVANT for CLB-BBM-08 on
// witness-MEANINGFULNESS grounds (adequacy of the production satisfy); witness EXISTENCE is untouched by
// those widenings, which is the only thing a kill channel needs.
// RULES: migrationCanFullyCloseOldPosition (BBM#21), fullCollateralMigrationClearsAllOldDebt__satisfy (BBM#12)
// BASE: light
// STUBS: B11,B2,B3,B4,B8,B14
// PINS: ghostNumTicks==1, ghostNumCollaterals==1 (kill scene; BBM cmn carries no global tick pin because
//       tickFeeVanishesAtPar needs the 5-tick model, so the pin lives per-channel here)
//       + E0: every created Blue market is fresh (lastUpdate == block.timestamp) — pinned inside the
//       touchMarketCVL override, NOT inside the projection, so it holds regardless of the unproven
//       CVL->CVL override resolution (CVL->CVL call sites can fall back to the base body); the aggressive
//       rung of the fallback ladder; gate clean=WITNESS is mandatory
// TIER2: B9L — lite touchMarketCVL via an override function (see block below)

import "../many.spec";
import "../debug_satisfy/many_satisfy.spec";

methods {
    function Morpho._isHealthy(MorphoHarness.MarketParams memory marketParams, MorphoHarness.Id id,
        address borrower) internal returns (bool) => NONDET;
    function MidnightHarness.supplyCollateral(MidnightHarness.Market market, uint256 collateralIndex,
        uint256 assets, address onBehalf) external => NONDET;
    function MidnightHarness.withdrawCollateral(MidnightHarness.Market market, uint256 collateralIndex,
        uint256 assets, address onBehalf, address receiver) external => NONDET;
    function MidnightHarness.settlementFee(bytes32 id, uint256 timeToMaturity)
        internal returns (uint256) => pfSettlementFee(id, timeToMaturity);
    function MidnightHarness.updatePositionView(MidnightHarness.Market market, bytes32 id, address user)
        external returns (uint128, uint128, uint128) => NONDET;
    function CallbackLib.sellerFeeFromTick(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal returns (uint256) => pfSellerFeeFromTick(tick, feeRate, units, assets);
    function CallbackLib.buyerFeeFromTick(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal returns (uint256) => pfBuyerFeeFromTick(tick, feeRate, units, assets);
    function CallbackLib.percentageFee(uint256 assets, uint256 feeRate)
        internal returns (uint256) => pfPercentageFee(assets, feeRate);
}

// B11: Blue health gate -> NONDET bool (both branches reachable).

// B3: second Midnight entry via collaterals -> NONDET (S1: exact-receiver over wildcard DISPATCHER
// is legal; NONDET external writes no storage -> ghosts stay synced). KILL-CHANNEL NOTE: neither
// mutant's contrast reads Midnight collateral cells — the satisfy conjuncts are Blue-only — and the
// Blue cells are written only by the concrete DISPATCHER'd repay/withdrawCollateral, which stay live.

// B2: callback fee math -> deterministic UFs (no axioms — no hidden fee bound). KILL-CHANNEL NOTE: fee
// freedom only parameterizes repayBudget = sellerAssets - fee; both mutants' guards/branches sit
// downstream of that subtraction, so the clean/mutant contrast is fee-agnostic. The pro-rata
// blueCollateral.mulDivDown(repayBudget, blueDebt) (matrix-B2 for this callback) stays CONCRETE — it
// carries the kill semantics (partial fills strictly under-migrate) and must not be summarized.

// B4 (partial): settlementFee -> UF; the inline mulDiv in take's body is not covered by this stub.
ghost pfSettlementFee(bytes32, uint256) returns uint256;
ghost pfSellerFeeFromTick(uint256, uint256, uint256, uint256) returns uint256;
ghost pfBuyerFeeFromTick(uint256, uint256, uint256, uint256) returns uint256;
ghost pfPercentageFee(uint256, uint256) returns uint256;

// B8: view leg only (the write leg _updatePosition must NOT be summarized —
// ghost-only writes break hook-sync -> silent vacuity).

// B14 (blue-taylor-UF): wTaylorCompounded's degree-3 polynomial is the documented split-explosion
// root; replace it with a free argument-deterministic ghost.
// The SAME symbol serves BOTH Blue legs — the concrete _accrueInterest (MathLib.wTaylorCompounded
// methods-entry) AND the expectedBorrowAssets projection (expectedMarketBalancesCVL) — so blueDebt
// and the debt the concrete repay settles stay coherent by construction. SAFETY: a free UF with no
// axioms (a wrong bound could exclude the true value and fake a kill) is a pure widening — sound for
// assert rules, witness-preserving for satisfy rules.
ghost pfBlueTaylor(uint256, uint256) returns uint256;
override function wTaylorCompoundedCVL(uint256 x, uint256 n) returns uint256 {
    return pfBlueTaylor(x, n);
}

// B14 CONTINGENCY: CVL->CVL call resolution for `override function` is only T1-proven for
// methods-entry call sites (touch_market_summary.spec binds to the override); the direct CVL call
// inside expectedMarketBalancesCVL (morpho_lib_many.spec:115) is an unproven resolution path.
// Override the projection too, with a body byte-identical to the original except the taylor call
// goes through the same pfBlueTaylor symbol -- coherence across both Blue legs is then guaranteed
// under either resolution semantics (wTaylorCompoundedCVL has exactly these two call sites).
override function expectedMarketBalancesCVL(env e, MorphoHarness.Id id)
    returns (uint256, uint256, uint256, uint256)
{
    uint256 tSA = require_uint256(ghostMbTotalSupplyAssets128[id]);
    uint256 tSS = require_uint256(ghostMbTotalSupplyShares128[id]);
    uint256 tBA = require_uint256(ghostMbTotalBorrowAssets128[id]);
    uint256 tBS = require_uint256(ghostMbTotalBorrowShares128[id]);
    uint256 lu  = require_uint256(ghostMbLastUpdate128[id]);
    uint256 fee = require_uint256(ghostMbFee128[id]);
    address irm = ghostMbIrm[id];

    require(to_mathint(e.block.timestamp) >= to_mathint(lu),
        "SAFE: lastUpdateBoundedByTimestamp (defensive; not pulled by setupManyBlue)");
    uint256 elapsed = require_uint256(to_mathint(e.block.timestamp) - to_mathint(lu));

    // Shortcut path mirrors MorphoBalancesLib.sol:44 -- skip when
    // elapsed == 0 || totalBorrowAssets == 0 || irm == 0.
    if (elapsed == 0 || tBA == 0 || irm == 0) {
        return (tSA, tSS, tBA, tBS);
    }

    uint256 rate = ghostMbIrmBorrowRate[irm];
    uint256 taylor = pfBlueTaylor(rate, elapsed);   // B14: the only change vs the original body
    uint256 interest = wMulDownCVL(tBA, taylor);

    uint256 tBA1 = require_uint256(to_mathint(tBA) + to_mathint(interest));
    uint256 tSA1 = require_uint256(to_mathint(tSA) + to_mathint(interest));

    // Match MorphoBalancesLib.sol:50-56 -- feeShares is computed against
    // the PRE-feeShares totalSupplyShares (initial tSS), then added.
    uint256 tSS1;
    if (fee != 0) {
        uint256 feeAmount = wMulDownCVL(interest, fee);
        uint256 tSA1MinusFee = require_uint256(to_mathint(tSA1) - to_mathint(feeAmount));
        uint256 feeShares = toSharesDownCVL(feeAmount, tSA1MinusFee, tSS);
        tSS1 = require_uint256(to_mathint(tSS) + to_mathint(feeShares));
    } else {
        tSS1 = tSS;
    }

    return (tSA1, tSS1, tBA1, tBS);
}

// T2-B9LITE: `override` swaps in a lite touchMarketCVL that drops both validCollateralParamsCVL calls
// (branch B9, the nonlinear maxLif residual) and keeps every ghost write and stability require verbatim.
// SAFETY: the dropped call is a pure require-narrowing (no ghost writes, no revert path); dropping it only
// widens the admitted inputs -- sound for the assert rules, and the satisfy twins keep their witnesses in the wider set.
override function touchMarketCVL(env e, MidnightHarness.Market market) returns bytes32 {
    // K1 PINS: both BBM kill arguments live entirely in the seller's Blue source position (final fill
    // reverts under #12 / strands 1 wei under #21; partial fills strictly under-migrate), which is
    // tick-count- and collateral-count-agnostic; otherwise the 5-tick x 2-collateral grid inflates JVM
    // split generation. ghostNumTicks==1 mirrors the SAFE per-scene pin the LMR/BMR cmn setups carry
    // ("single take consumes one tick"); BBM cannot pin it globally (tickFeeVanishesAtPar needs 5 ticks).
    require(ghostNumTicks == 1,
        "SCOPE: single-tick kill scene (BBM#12/#21) — a single take consumes one tick (offer.tick)");
    require(ghostNumCollaterals == 1,
        "SCOPE: single-collateral kill scene (BBM#12/#21) — the full-close witness is collateral-count-agnostic");

    // E0 KILL-SCENE PIN: every created Blue market is fresh (virgin markets keep lastUpdate == 0 and,
    // per valid state, totalBorrowAssets == 0), so the projection takes its elapsed==0 / tBA==0
    // shortcut and the concrete _accrueInterest no-ops — the residual accrual arithmetic is dead code
    // on BOTH Blue legs. The pin lives HERE, on the T1-proven methods-entry override path, NOT inside
    // expectedMarketBalancesCVL, whose CVL->CVL call sites fall back to the base body
    // and would leave an in-projection pin inert.
    // touchMarket runs before onSell, so the pin lands on the initial Blue state and the later accrual
    // write (lastUpdate := block.timestamp) stays consistent; both mutation sites sit downstream of the
    // blueDebt read (BorrowBlueToMidnightCallback.sol:69), so the clean/mutant contrast is untouched.
    // A pin can delete the clean witness: this conf kills ONLY behind a clean-src WITNESS gate on this
    // same conf (fallback: the k1 twin without this pin).
    require(forall MorphoHarness.Id blueId.
        ghostMbLastUpdate128[blueId] == 0
        || ghostMbLastUpdate128[blueId] == to_mathint(e.block.timestamp),
        "SCOPE: zero-elapsed Blue kill scene (BBM#12/#21) — the full-close witness needs no accrual");

    bytes32 id = idLibToIdCVL(e, market);

    require(ghostMiMarketTickSpacing[id] > 0,
        "UNSAFE: touchMarket summary models only already-touched markets");

    require(ghostMiMarketLoanToken[id] == 0
         || ghostMiMarketLoanToken[id] == market.loanToken,
        "UNSAFE: loanToken stable across touchMarket calls for the same id");
    ghostMiMarketLoanToken[id] = market.loanToken;

    require(ghostMiOneMarketLoanToken == 0
         || ghostMiOneMarketLoanToken == market.loanToken,
        "UNSAFE: scalar loanToken stable across touchMarket calls");
    ghostMiOneMarketLoanToken = market.loanToken;

    require(market.collateralParams.length > 0,
        "UNSAFE: touched market has collateralParams (NoCollateralParams)");
    require(to_mathint(market.collateralParams.length) <= ghostNumCollaterals,
        "UNSAFE: collateralParams.length <= ghostNumCollaterals (two-collateral model)");

    require(market.collateralParams[0].token != 0,
        "UNSAFE: collateralParams sorted — token[0] != 0 (CollateralParamsNotSorted)");
    require(!ghostMiManyModeActive
         || market.collateralParams[0].token != market.loanToken,
        "UNSAFE: many-mode no-aliasing (collateralParams[0].token != loanToken)");
    // T2-B9LITE DROPPED: validCollateralParamsCVL(collateralParams[0]) — NLA maxLif narrowing.

    require(ghostMiOneCollateralToken[0] == 0
         || ghostMiOneCollateralToken[0] == market.collateralParams[0].token,
        "UNSAFE: scalar collateralToken[0] stable across touchMarket calls");
    ghostMiOneCollateralToken[0] = market.collateralParams[0].token;

    require(ghostMiMarketCollateralToken[id][0] == 0
         || ghostMiMarketCollateralToken[id][0] == market.collateralParams[0].token,
        "UNSAFE: per-id collateralToken[0] stable across touchMarket calls");
    ghostMiMarketCollateralToken[id][0] = market.collateralParams[0].token;

    if (market.collateralParams.length > 1) {
        require(market.collateralParams[1].token > market.collateralParams[0].token,
            "UNSAFE: collateralParams sorted — token[1] > token[0] (CollateralParamsNotSorted)");
        require(!ghostMiManyModeActive
             || market.collateralParams[1].token != market.loanToken,
            "UNSAFE: many-mode no-aliasing (collateralParams[1].token != loanToken)");
        // T2-B9LITE DROPPED: validCollateralParamsCVL(collateralParams[1]) — NLA maxLif narrowing.

        require(ghostMiOneCollateralToken[1] == 0
             || ghostMiOneCollateralToken[1] == market.collateralParams[1].token,
            "UNSAFE: scalar collateralToken[1] stable across touchMarket calls");
        ghostMiOneCollateralToken[1] = market.collateralParams[1].token;

        require(ghostMiMarketCollateralToken[id][1] == 0
             || ghostMiMarketCollateralToken[id][1] == market.collateralParams[1].token,
            "UNSAFE: per-id collateralToken[1] stable across touchMarket calls");
        ghostMiMarketCollateralToken[id][1] = market.collateralParams[1].token;
    }

    return id;
}

use rule migrationCanFullyCloseOldPosition;
use rule fullCollateralMigrationClearsAllOldDebt__satisfy;
