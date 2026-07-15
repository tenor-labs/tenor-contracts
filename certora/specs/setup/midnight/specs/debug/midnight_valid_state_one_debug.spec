// Debug rules for valid-state one-market invariants.
// Each rule snapshots ghosts before/after a parametric call so the Prover
// counterexample shows explicit *Before/*After locals instead of ambiguous
// ghost traces.

import "../midnight_valid_state_one.spec";
import "../setup/callbacks.spec";

// VS-MI-18 (diagnostic): while no bad debt has been socialized (the cumulative bad-debt
// socialization factor lossFactor is zero), every loan unit in the market is accounted for:
// the lenders' credit (summed over the three modeled users) plus the continuous-fee credit (cfc)
// — fee units accrued to the protocol, claimable by the fee claimer — exactly equals the market's
// total loan units (totalUnits). Stated as preservation of this balance across any state-changing
// entry point.
// FORMULA: forall f. (lossFactor == 0 => Σ_u credit[u] + continuousFeeCredit == totalUnits)
//          => (lossFactor' == 0 => Σ_u credit[u]' + continuousFeeCredit' == totalUnits')
rule creditSumAndCfcEqualTotalUnitsWhenNoBadDebtDebugRule(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) }
{
    setupValidStateOneMidnight(e);

    mathint lossFactorBefore   = ghostMiOneMarketLossFactor128;
    mathint creditOneBefore    = ghostMiOnePositionCredit128[ghostMiPositionUserOne];
    mathint creditTwoBefore    = ghostMiOnePositionCredit128[ghostMiPositionUserTwo];
    mathint creditThreeBefore  = ghostMiOnePositionCredit128[ghostMiPositionUserThree];
    mathint cfcBefore          = ghostMiOneMarketContinuousFeeCredit128;
    mathint totalUnitsBefore   = ghostMiOneMarketTotalUnits128;

    require(lossFactorBefore == 0 => (
        creditOneBefore + creditTwoBefore + creditThreeBefore + cfcBefore == totalUnitsBefore
    ), "INV: inductive hypothesis (Σ_3 credit + cfc == totalUnits | lossFactor == 0)");

    f(e, args);

    mathint lossFactorAfter    = ghostMiOneMarketLossFactor128;
    mathint creditOneAfter     = ghostMiOnePositionCredit128[ghostMiPositionUserOne];
    mathint creditTwoAfter     = ghostMiOnePositionCredit128[ghostMiPositionUserTwo];
    mathint creditThreeAfter   = ghostMiOnePositionCredit128[ghostMiPositionUserThree];
    mathint cfcAfter           = ghostMiOneMarketContinuousFeeCredit128;
    mathint totalUnitsAfter    = ghostMiOneMarketTotalUnits128;

    assert(lossFactorAfter == 0 => (
        creditOneAfter + creditTwoAfter + creditThreeAfter + cfcAfter == totalUnitsAfter
    ), "VS-MI-18 violated after function call");
}
