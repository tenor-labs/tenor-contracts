// perf overlay BorrowMidnightRenewalCallback/many: branches B10 disabled — per the footprint matrix
// they do not intersect the read-set of the listed rules (footprint analysis: branch write-set is disjoint from the rules' read-set).
// RULES: renewalCannotAddCollateralWhenReducingDebt renewalCannotRemoveCollateralWhenOpeningDebt
// BASE: light
// STUBS: B10
// B7-ELIGIBLE (hashing flags, deferred to keccak inventory): renewalCannotAddCollateralWhenReducingDebt
// SATISFY-TWINS (re-check non-vacuity under the same overlay): renewalCannotAddCollateralWhenReducingDebt renewalCannotRemoveCollateralWhenOpeningDebt
// TIER2: B9L — lite touchMarketCVL via an override function (see block below); all profile rules are B9-IRRELEVANT

import "../many.spec";
import "../debug_satisfy/many_satisfy.spec";

methods {
    function MidnightHarness.isHealthy(MidnightHarness.Market memory market, bytes32 id, address borrower)
        internal returns (bool) => NONDET;
}

// B10: Midnight health gate -> NONDET bool (both branches reachable; not force-true).

// T2-B9LITE: `override` swaps in a lite touchMarketCVL that drops both validCollateralParamsCVL calls
// (branch B9, the nonlinear maxLif residual) and keeps every ghost write and stability require verbatim.
// SAFETY: the dropped call is a pure require-narrowing (no ghost writes, no revert path); dropping it only
// widens the admitted inputs -- sound for the assert rules, and the satisfy twins keep their witnesses in the wider set.
override function touchMarketCVL(env e, MidnightHarness.Market market) returns bytes32 {
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

use rule renewalCannotAddCollateralWhenReducingDebt;
use rule renewalCannotRemoveCollateralWhenOpeningDebt;
use rule renewalCannotAddCollateralWhenReducingDebt__satisfy;
use rule renewalCannotRemoveCollateralWhenOpeningDebt__satisfy;
