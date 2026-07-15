// perf kill overlay LendMidnightRenewalCallback/many: branch B3 disabled — B3 and B9 are the only
// IRRELEVANT-verdict branches for this rule in the footprint matrix (every other LMR-scene branch is
// REQUIRED, which is why no production perf profile exists) — plus a single-collateral kill-scene pin.
// RULES: renewalCanFullyCloseOldCredit (mutation-kill channel: LMR#16)
// BASE: light
// STUBS: B3
// PINS: ghostNumCollaterals==1 (kill scene; ghostNumTicks==1 already pinned in many_setup)
// TIER2: B9L — lite touchMarketCVL via an override function (see block below); B9 is IRRELEVANT for this rule

import "../many.spec";

methods {
    function MidnightHarness.supplyCollateral(MidnightHarness.Market market, uint256 collateralIndex,
        uint256 assets, address onBehalf) external => NONDET;
    function MidnightHarness.withdrawCollateral(MidnightHarness.Market market, uint256 collateralIndex,
        uint256 assets, address onBehalf, address receiver) external => NONDET;
}

// B3: second Midnight entry via collaterals -> NONDET (S1: exact-receiver over wildcard DISPATCHER
// is legal; NONDET external writes no storage -> ghosts stay synced). The LMR onBuy flow itself is
// collateral-free (lender credit only), so the collateral entries only feed the parametric take grid.

// T2-B9LITE: `override` swaps in a lite touchMarketCVL that drops both validCollateralParamsCVL calls
// (branch B9, the nonlinear maxLif residual) and keeps every ghost write and stability require verbatim.
// SAFETY: the dropped call is a pure require-narrowing (no ghost writes, no revert path); dropping it only
// widens the admitted inputs -- sound for the assert rules, and the satisfy twins keep their witnesses in the wider set.
override function touchMarketCVL(env e, MidnightHarness.Market market) returns bytes32 {
    // K1 PIN: the LMR#16 kill argument lives entirely in the lender's source-market credit
    // (withdraw(0) is a no-op decrement, so credit can never reach zero), which is
    // collateral-count-agnostic; otherwise the collateral grid inflates JVM split generation.
    // Satisfy channel: the pin MUST be gated by a clean-src WITNESS run of this same conf,
    // otherwise a pin-starved witness would fake the kill.
    require(ghostNumCollaterals == 1,
        "SCOPE: single-collateral kill scene (LMR#16) — credit-close witness is collateral-count-agnostic");

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

use rule renewalCanFullyCloseOldCredit;
