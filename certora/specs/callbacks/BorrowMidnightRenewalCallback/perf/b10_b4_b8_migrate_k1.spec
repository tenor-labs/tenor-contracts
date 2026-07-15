// perf kill overlay BorrowMidnightRenewalCallback/many: branches B10, B4, B8 disabled — per the footprint matrix
// they do not intersect the read-set of the listed rule — plus a single-collateral kill-scene pin (K1).
// This mirrors the validated collateral-family cousin perf/b10_b4_b8_t_k1.spec (CLB-BMR-06, same
// source/target same-token collateral read-set); the ONLY change is the profiled rule.
// RULES: renewalCanMigrateCollateralBetweenMarkets (mutation-kill channel: CTL#4)
// BASE: light (the perf kill overlay downgrades the production _base_heavy conf to _base, matching the collateral-family cousins)
// STUBS: B10,B4,B8   (supply/withdrawCollateral stay CONCRETE — the migration witness needs the real moves,
//   and CTL#4 zeroes the concrete target supply, so the kill lives in un-summarized code)
// PINS: ghostNumCollaterals==1 (kill scene; ghostNumTicks==1 already pinned in cmn.spec setupMigrationRatifier)
// SATISFY: renewalCanMigrateCollateralBetweenMarkets is a native satisfy rule (no __satisfy twin) — no debug_satisfy import.
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
    // K1 PIN: the CTL#4 migration witness needs collateral to move between TWO distinct markets that
    // SHARE ONE collateral token (idSrc != idTgt, both list the token in slot 0). ghostNumCollaterals
    // counts collateral TOKENS, not markets, so a single token fully expresses "source collateral drops
    // AND target collateral rises" on slot 0 of each market — the pin PRESERVES the migration witness.
    // It only trims the per-slot pro-rata mulDiv fan-out in transferCollaterals that explodes JVM split
    // generation before any witness is found. The mutation supplies 0 to the target, so the concrete
    // (un-summarized) target supplyCollateral never increases tgtCol => the satisfy conjunct
    // (tgtColAfter > tgtColBefore) is unsatisfiable => VIOLATED = kill.
    // Satisfy channel: the pin MUST be gated by a clean-src WITNESS run of this same conf,
    // otherwise a pin-starved witness would fake the kill.
    require(ghostNumCollaterals == 1,
        "SCOPE: single-collateral kill scene (CTL#4) — one shared collateral token expresses the source->target migration");

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

use rule renewalCanMigrateCollateralBetweenMarkets;
