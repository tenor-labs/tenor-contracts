// perf kill overlay LendMidnightRenewalCallback/many: branches B2, B3 disabled — per the footprint matrix
// they do not intersect the read-set of the listed rules — plus a single-collateral kill-scene pin.
// RULES: renewalAddsCreditOnAtMostOneMarket renewalReducesCreditOnAtMostOneMarket (mutation-kill channel: LMR#19 via renewalReducesCreditOnAtMostOneMarket)
// BASE: light
// STUBS: B2,B3
// PINS: ghostNumCollaterals==1 (kill scene; assert-CEX channel, so a found CEX is a genuine trace)
// B7-ELIGIBLE (hashing flags, deferred to keccak inventory): renewalAddsCreditOnAtMostOneMarket renewalReducesCreditOnAtMostOneMarket
// SATISFY-TWINS (re-check non-vacuity under the same overlay): renewalAddsCreditOnAtMostOneMarket renewalReducesCreditOnAtMostOneMarket
// TIER2: B9L — lite touchMarketCVL via an override function (see block below); all profile rules are B9-IRRELEVANT

import "../many.spec";
import "../debug_satisfy/many_satisfy.spec";

methods {
    function CallbackLib.sellerFeeFromTick(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal returns (uint256) => pfSellerFeeFromTick(tick, feeRate, units, assets);
    function CallbackLib.buyerFeeFromTick(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal returns (uint256) => pfBuyerFeeFromTick(tick, feeRate, units, assets);
    function CallbackLib.percentageFee(uint256 assets, uint256 feeRate)
        internal returns (uint256) => pfPercentageFee(assets, feeRate);
    function MidnightHarness.supplyCollateral(MidnightHarness.Market market, uint256 collateralIndex,
        uint256 assets, address onBehalf) external => NONDET;
    function MidnightHarness.withdrawCollateral(MidnightHarness.Market market, uint256 collateralIndex,
        uint256 assets, address onBehalf, address receiver) external => NONDET;
}

// B2: callback fee math -> deterministic UFs (no axioms — no hidden fee bound).
ghost pfSellerFeeFromTick(uint256, uint256, uint256, uint256) returns uint256;
ghost pfBuyerFeeFromTick(uint256, uint256, uint256, uint256) returns uint256;
ghost pfPercentageFee(uint256, uint256) returns uint256;

// B3: second Midnight entry via collaterals -> NONDET (S1: exact-receiver over wildcard DISPATCHER
// is legal; NONDET external writes no storage -> ghosts stay synced). For BMR the transferCollaterals
// loop stays (the library struct param does not resolve to a CVL entry), but its Midnight calls are NONDET.

// T2-B9LITE: `override` swaps in a lite touchMarketCVL that drops both validCollateralParamsCVL calls
// (branch B9, the nonlinear maxLif residual) and keeps every ghost write and stability require verbatim.
// SAFETY: the dropped call is a pure require-narrowing (no ghost writes, no revert path); dropping it only
// widens the admitted inputs -- sound for the assert rules, and the satisfy twins keep their witnesses in the wider set.
override function touchMarketCVL(env e, MidnightHarness.Market market) returns bytes32 {
    // K1 PIN: the LMR#19 kill lives entirely in the lender's per-market CREDIT (the inserted 2nd
    // target withdraw overshoots take's +units deposit, so credit net-drops on BOTH source and target);
    // the LMR onBuy flow is collateral-free, so ghostNumCollaterals is orthogonal to the CEX and the
    // collateral entries only inflate the parametric take grid / JVM split generation. Assert-CEX
    // channel: the pin can only hide a CEX (miss), never fabricate one, so it is safe-by-construction.
    require(ghostNumCollaterals == 1,
        "SCOPE: single-collateral kill scene (LMR#19) — credit-drop CEX is collateral-count-agnostic");

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

use rule renewalAddsCreditOnAtMostOneMarket;
use rule renewalReducesCreditOnAtMostOneMarket;
use rule renewalAddsCreditOnAtMostOneMarket__satisfy;
use rule renewalReducesCreditOnAtMostOneMarket__satisfy;
