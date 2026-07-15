// perf overlay BorrowMidnightToBlueCallback/many: branches B1, B4, B8 disabled — per the footprint matrix
// they do not intersect the read-set of the listed rules (footprint analysis: branch write-set is disjoint from the rules' read-set).
// RULES: migrationCannotDepositMoreCollateralThanWithdrawn migrationOnlyWithdrawsOldMidnightCollateral
// BASE: light
// STUBS: B1,B4,B8
// B7-ELIGIBLE (hashing flags, deferred to keccak inventory): migrationCannotDepositMoreCollateralThanWithdrawn migrationOnlyWithdrawsOldMidnightCollateral
// SATISFY-TWINS (re-check non-vacuity under the same overlay): migrationCannotDepositMoreCollateralThanWithdrawn migrationOnlyWithdrawsOldMidnightCollateral
// TIER2: B9L — lite touchMarketCVL via an override function (see block below); all profile rules are B9-IRRELEVANT

import "../many.spec";
import "../debug_satisfy/many_satisfy.spec";

methods {
    function Morpho._accrueInterest(MorphoHarness.MarketParams memory marketParams, MorphoHarness.Id id)
        internal with (env e) => accrueInterestFrozenCVL(e, marketParams, id);
    function MidnightHarness.settlementFee(bytes32 id, uint256 timeToMaturity)
        internal returns (uint256) => pfSettlementFee(id, timeToMaturity);
    function MidnightHarness.updatePositionView(MidnightHarness.Market market, bytes32 id, address user)
        external returns (uint128, uint128, uint128) => NONDET;
}

// B1 freeze: Blue interest already accrued in this block; NO writes (hook-sync preserved);
// coherent with expected* projections (B1<->B6).
function accrueInterestFrozenCVL(env e, MorphoHarness.MarketParams marketParams, MorphoHarness.Id id) {
    require(to_mathint(ghostMbLastUpdate128[id]) == to_mathint(e.block.timestamp),
        "UNSAFE: market already accrued this block - freeze coherent with expected* projections");
}

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

use rule migrationCannotDepositMoreCollateralThanWithdrawn;
use rule migrationOnlyWithdrawsOldMidnightCollateral;
use rule migrationCannotDepositMoreCollateralThanWithdrawn__satisfy;
use rule migrationOnlyWithdrawsOldMidnightCollateral__satisfy;
