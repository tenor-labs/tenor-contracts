// perf kill overlay BorrowMidnightRenewalCallback/many: branches B10, B4, B8 disabled — per the footprint matrix
// they do not intersect the read-set of the listed rule — plus a single-collateral kill-scene pin (K1).
// This mirrors the validated collateral-family cousin perf/b10_b4_b8_migrate_k1.spec (CTL#4, same
// source collateral read-set / same take() flow); the ONLY change is the profiled rule (and the K1
// scope note, since the full-close witness observes ONE source market rather than a src->tgt pair).
// RULES: renewalCanFullyCloseOldPosition (mutation-kill channel: CTL#1)
// BASE: light (the perf kill overlay downgrades the production _base_heavy conf to _base, matching the collateral-family cousins)
// STUBS: B10,B4,B8   (supply/withdrawCollateral stay CONCRETE — the full-close witness needs the real source
//   moves, and CTL#1 under-reads the concrete source collateral by 1, so the kill lives in un-summarized code)
// PINS: ghostNumCollaterals==1 (kill scene; ghostNumTicks==1 already pinned in cmn.spec setupMigrationRatifier)
// SATISFY: renewalCanFullyCloseOldPosition is a native satisfy rule (no __satisfy twin) — no debug_satisfy import.
// TIER2: B9L — base b10_b4_b8 has NO touchMarketCVL override; this kill overlay adds one (mirroring b3_k1)
//   solely to host the K1 pin at the touchMarket entry. The added override is B9-lite (drops both
//   validCollateralParamsCVL calls); that drop is a pure require-narrowing (widening) and keeps the
//   satisfy witness in the wider set, exactly as documented for every sibling perf overlay.

import "../many.spec";

methods {
    function MidnightHarness.isHealthy(MidnightHarness.Market memory market, bytes32 id, address borrower)
        internal returns (bool) => NONDET;
    function MidnightHarness.settlementFee(bytes32 id, uint256 timeToMaturity)
        internal returns (uint256) => pfSettlementFee(id, timeToMaturity);
    function MidnightHarness.updatePositionView(MidnightHarness.Market market, bytes32 id, address user)
        external returns (uint128, uint128, uint128) => NONDET;
}

// B10: Midnight health gate -> NONDET bool (both branches reachable; not force-true).

// B4 (partial): settlementFee -> UF; the inline mulDiv in take's body is not covered by this stub.
ghost pfSettlementFee(bytes32, uint256) returns uint256;

// B8: view leg only (the write leg _updatePosition must NOT be summarized —
// ghost-only writes break hook-sync -> silent vacuity).

// T2-B9LITE: `override` swaps in a lite touchMarketCVL that drops both validCollateralParamsCVL calls
// (branch B9, the nonlinear maxLif residual) and keeps every ghost write and stability require verbatim.
// SAFETY: the dropped call is a pure require-narrowing (no ghost writes, no revert path); dropping it only
// widens the admitted inputs -- and the satisfy witness stays in the wider set.
override function touchMarketCVL(env e, MidnightHarness.Market market) returns bytes32 {
    // K1 PIN: the CTL#1 full-close witness observes a SINGLE source market position draining to zero
    // (debt==0 AND source collateral slot[anyIndex]==0). ghostNumCollaterals counts collateral TOKENS;
    // with one token the source market has exactly one collateral slot (index 0), which is precisely the
    // slot the closing fill withdraws — so a single collateral token FULLY expresses "the source position
    // can be fully closed", and the pin PRESERVES the full-close witness (it is the minimal witness scene).
    // It only trims the per-slot pro-rata mulDiv fan-out in transferCollaterals that explodes JVM split
    // generation before any witness is found. The mutation under-reads the concrete (un-summarized) source
    // collateral by 1 on the closing fill, so withdrawCollateral leaves 1 unit on the source =>
    // ghostMiPositionCollateral128[idSrc][anyUser][0] can never reach exactly 0 => the satisfy conjunct
    // (source collateral == 0) is unsatisfiable => VIOLATED = kill.
    // Satisfy channel: the pin MUST be gated by a clean-src WITNESS run of this same conf,
    // otherwise a pin-starved witness would fake the kill.
    require(ghostNumCollaterals == 1,
        "SCOPE: single-collateral kill scene (CTL#1) — one source collateral slot expresses the full-close witness");

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

use rule renewalCanFullyCloseOldPosition;
