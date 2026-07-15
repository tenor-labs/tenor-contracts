// perf kill overlay BorrowMidnightRenewalCallback/many: branches B10, B4, B8 disabled — per the footprint matrix
// they do not intersect the read-set of the listed rule — plus a single-collateral kill-scene pin.
// RULES: renewalCannotMoveMoreCollateralThanWithdrawn (mutation-kill channel: CTL#3)
// BASE: light
// STUBS: B10,B4,B8
// PINS: ghostNumCollaterals==1 (kill scene; assert-CEX channel, so a found CEX is a genuine trace)
// SATISFY-TWINS (re-check non-vacuity under the same overlay): renewalCannotMoveMoreCollateralThanWithdrawn
// TIER2: B9L — base b10_b4_b8_t has NO touchMarketCVL override; this kill overlay adds one (mirroring b3_k1)
//   solely to host the K1 pin at the touchMarket entry. The added override is B9-lite (drops both
//   validCollateralParamsCVL calls); that drop is a pure require-narrowing (widening) and is sound for
//   this assert rule + its satisfy twin, exactly as documented for every sibling perf overlay.

import "../many.spec";
import "../debug_satisfy/many_satisfy.spec";

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
// widens the admitted inputs -- sound for the assert rules, and the satisfy twins keep their witnesses in the wider set.
override function touchMarketCVL(env e, MidnightHarness.Market market) returns bytes32 {
    // K1 PIN: the CTL#3 kill needs only ONE same-token collateral slot — the mutated inlined loop
    // withdraws collateralToTransfer-1 from source but supplies the full collateralToTransfer to target,
    // so on slot 0 the target inflow (collateralToTransfer) exceeds the source outflow (collateralToTransfer-1)
    // by the +1 callback seed; the assert (srcColOut >= tgtColIn, same token) is violated on a single slot.
    // Otherwise the transferCollaterals per-slot pro-rata mulDiv fan-out explodes JVM split generation
    // before any CEX is attempted. Assert-CEX channel: the pin can only hide a CEX (miss), never fabricate
    // one, so it is safe-by-construction.
    require(ghostNumCollaterals == 1,
        "SCOPE: single-collateral kill scene (CTL#3) — the moves-more-than-withdrawn CEX fits one slot");

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

use rule renewalCannotMoveMoreCollateralThanWithdrawn;
use rule renewalCannotMoveMoreCollateralThanWithdrawn__satisfy;
