// perf overlay BorrowBlueToMidnightCallback/many: branches B11, B2, B3, B4, B8 disabled — per the footprint matrix
// they do not intersect the read-set of the listed rules (footprint analysis: branch write-set is disjoint from the rules' read-set).
// RULES: migrationReducesOldDebtOnAtMostOneMarket
// BASE: light
// STUBS: B11,B2,B3,B4,B8
// B7-ELIGIBLE (hashing flags, deferred to keccak inventory): migrationReducesOldDebtOnAtMostOneMarket
// SATISFY-TWINS (re-check non-vacuity under the same overlay): migrationReducesOldDebtOnAtMostOneMarket
// TIER2: B9L — lite touchMarketCVL via an override function (see block below); all profile rules are B9-IRRELEVANT

import "../many.spec";
import "../debug_satisfy/many_satisfy.spec";

methods {
    function Morpho._isHealthy(MorphoHarness.MarketParams memory marketParams, MorphoHarness.Id id,
        address borrower) internal returns (bool) => NONDET;
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
    function MidnightHarness.settlementFee(bytes32 id, uint256 timeToMaturity)
        internal returns (uint256) => pfSettlementFee(id, timeToMaturity);
    function MidnightHarness.updatePositionView(MidnightHarness.Market market, bytes32 id, address user)
        external returns (uint128, uint128, uint128) => NONDET;
}

// B11: Blue health gate -> NONDET bool (both branches reachable).

// B2: callback fee math -> deterministic UFs (no axioms — no hidden fee bound).
ghost pfSellerFeeFromTick(uint256, uint256, uint256, uint256) returns uint256;
ghost pfBuyerFeeFromTick(uint256, uint256, uint256, uint256) returns uint256;
ghost pfPercentageFee(uint256, uint256) returns uint256;

// B3: second Midnight entry via collaterals -> NONDET (S1: exact-receiver over wildcard DISPATCHER
// is legal; NONDET external writes no storage -> ghosts stay synced). For BMR the transferCollaterals
// loop stays (the library struct param does not resolve to a CVL entry), but its Midnight calls are NONDET.

// B4 (partial): settlementFee -> UF; the inline mulDiv in take's body is not covered by this stub.
ghost pfSettlementFee(bytes32, uint256) returns uint256;

// B8: view leg only (the write leg _updatePosition must NOT be summarized —
// ghost-only writes break hook-sync -> silent vacuity).

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

use rule migrationReducesOldDebtOnAtMostOneMarket;
use rule migrationReducesOldDebtOnAtMostOneMarket__satisfy;
