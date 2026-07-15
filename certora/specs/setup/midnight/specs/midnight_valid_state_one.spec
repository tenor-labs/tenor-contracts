// Valid-state invariants for Midnight (one-market regime).

import "setup/midnight_one.spec";

function setupValidStateOneMidnight(env e) {
    setupValidStateOneMidnightWithLock(e, true);
}

// Lock-pin passthrough — see setupMidnightWithLock (ST-MI-13 regime). The
// valid-state invariants are lock-agnostic (none mention the lock ghost), so
// requiring them under a free lock is consistent.
function setupValidStateOneMidnightWithLock(env e, bool pinLiquidationLock) {
    setupOneMidnightWithLock(e, pinLiquidationLock);
    requireInvariant creditCoversPendingFee(e);
    requireInvariant positionLastLossFactorWithinMarket(e);
    requireInvariant lastAccrualNotInFuture(e);
    requireInvariant collateralBitmapMatchesSlot(e);
    requireInvariant nonEmptyPositionImpliesTouched(e);
    requireInvariant creditAndDebtMutuallyExclusive(e);
    requireInvariant creditOrLastLossFactorImpliesLastAccrual(e);
    requireInvariant pendingFeePositiveImpliesCreditPositive(e);
    requireInvariant marketSettlementFeesBounded(e);
    requireInvariant marketContinuousFeeBounded(e);
    requireInvariant defaultSettlementFeesBounded(e);
    requireInvariant defaultContinuousFeeBounded(e);
    requireInvariant claimableAndWithdrawableBackedByBalance(e);
    requireInvariant collateralBackedByBalance(e);
    requireInvariant perTokenClaimableBounded(e);
    requireInvariant noSelfApprove(e);
    requireInvariant debtSumAndWithdrawableWithinTotalUnits(e);
    requireInvariant creditSumAndCfcEqualTotalUnitsWhenNoBadDebt(e);
    requireInvariant tickSpacingDividesDefault(e);
}

function SETUP_ONE_MIDNIGHT(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupOneMidnight(e);
}

function SETUP_ONE_MIDNIGHT_FULL(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupValidStateOneMidnight(e);
}

// VS-MI-01: fee accrued on a lender position but not yet collected (pendingFee) never exceeds
// that lender's credit balance, so collecting the protocol's fee can never consume more units
// than the position actually holds.
// FORMULA: forall u. pendingFee[u] <= credit[u]
invariant creditCoversPendingFee(env e)
    forall address u.
        ghostMiOnePositionPendingFee128[u] <= ghostMiOnePositionCredit128[u]
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_ONE_MIDNIGHT(e, eFunc);
    // take's buyer leg mints pendingFee = creditIncrease * continuousFee * ttm / WAD;
    // without the fee cap the induction pre-state admits an unreachable fee.
    requireInvariant marketContinuousFeeBounded(e);
} }

// VS-MI-02: each position's recorded snapshot of the cumulative bad-debt socialization factor
// (lossFactor) never runs ahead of the market's current value, so the lazy slash applied to a
// lender on its next touch is always a well-defined, non-negative loss.
// FORMULA: forall u. lastLossFactor[u] <= lossFactor
invariant positionLastLossFactorWithinMarket(env e)
    forall address u.
        ghostMiOnePositionLastLossFactor128[u] <= ghostMiOneMarketLossFactor128
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_ONE_MIDNIGHT(e, eFunc); } }

// VS-MI-03: a position's last fee-accrual timestamp never lies in the future, so the continuous
// fee charged on borrower debt is always computed over a non-negative elapsed time.
// FORMULA: forall u. lastAccrual[u] <= block.timestamp
invariant lastAccrualNotInFuture(env e)
    forall address u.
        ghostMiOnePositionLastAccrual128[u] <= e.block.timestamp
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_ONE_MIDNIGHT(e, eFunc); } }

definition COLLATERAL_BIT_SET(mathint bitmap, uint256 i) returns bool =
    (bitmap / (i == 0 ? 1 : 2)) % 2 == 1;

// VS-MI-04: the bitmap recording which collateral tokens a borrower has posted exactly mirrors
// the posted balances: a slot's bit is set if and only if the borrower holds a non-zero amount
// of that collateral, so health checks and liquidators never miss or double-count collateral.
// FORMULA: forall u, valid i. bit_i(collateralBitmap[u]) <=> collateral[u][i] > 0
invariant collateralBitmapMatchesSlot(env e)
    forall address u. forall uint256 i.
        VALID_COLLATERAL_BIT(i) => (
            COLLATERAL_BIT_SET(ghostMiOnePositionCollateralBitmap128[u], i)
            <=> ghostMiOnePositionCollateral128[u][i] > 0
        )
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_ONE_MIDNIGHT(e, eFunc); } }

// VS-MI-05: no lender credit, borrower debt, fee, or collateral record can exist in a market
// that was never created; an initialized market is recognizable by its non-zero tick spacing.
// FORMULA: forall u. (any position[u] field != 0) => tickSpacing > 0
invariant nonEmptyPositionImpliesTouched(env e)
    forall address u. (
        ghostMiOnePositionCredit128[u] > 0
        || ghostMiOnePositionPendingFee128[u] > 0
        || ghostMiOnePositionLastLossFactor128[u] > 0
        || ghostMiOnePositionLastAccrual128[u] > 0
        || ghostMiOnePositionDebt128[u] > 0
        || ghostMiOnePositionCollateralBitmap128[u] > 0
    ) => ghostMiOneMarketTickSpacing > 0
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_ONE_MIDNIGHT(e, eFunc); } }

// VS-MI-06: within a market a user is either a lender (holding interest-bearing credit units) or
// a borrower (owing debt), never both at once, so every position settles unambiguously on one
// side of the book.
// FORMULA: forall u. credit[u] == 0 OR debt[u] == 0
invariant creditAndDebtMutuallyExclusive(env e)
    forall address u.
        ghostMiOnePositionCredit128[u] == 0 || ghostMiOnePositionDebt128[u] == 0
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_ONE_MIDNIGHT(e, eFunc); } }

// VS-MI-07: any position carrying lender credit, a bad-debt socialization snapshot, or
// uncollected fee has been through fee accrual at least once -- its accrual timestamp is set,
// so the lazy fee and loss bookkeeping always has a valid starting point.
// FORMULA: forall u. (credit[u] > 0 OR lastLossFactor[u] > 0 OR pendingFee[u] > 0)
//          => lastAccrual[u] > 0
invariant creditOrLastLossFactorImpliesLastAccrual(env e)
    forall address u.
        (ghostMiOnePositionCredit128[u] > 0
            || ghostMiOnePositionLastLossFactor128[u] > 0
            || ghostMiOnePositionPendingFee128[u] > 0)
                => ghostMiOnePositionLastAccrual128[u] > 0
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_ONE_MIDNIGHT(e, eFunc); } }

// VS-MI-08: uncollected fee (pendingFee) can only exist on a live lender position: once a
// lender's credit is fully gone, no pending fee remains owed on that position.
// FORMULA: forall u. pendingFee[u] > 0 => credit[u] > 0
invariant pendingFeePositiveImpliesCreditPositive(env e)
    forall address u.
        ghostMiOnePositionPendingFee128[u] > 0
        => ghostMiOnePositionCredit128[u] > 0
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_ONE_MIDNIGHT(e, eFunc);
    requireInvariant creditCoversPendingFee(e);
} }

// VS-MI-09: each of the market's seven settlement-fee rates (the trading fee charged on take()
// fills, stored per time-to-maturity breakpoint in centi-basis-points) stays within its
// per-breakpoint protocol maximum, capping what a trade can ever be charged.
// FORMULA: forall i in 0..6. settlementFeeCbp_i <= MAX_SETTLEMENT_FEE_STORED_i()
invariant marketSettlementFeesBounded(env e)
    ghostMiOneMarketSettlementFeeCbp0_16 <= MAX_SETTLEMENT_FEE_STORED_0()
    && ghostMiOneMarketSettlementFeeCbp1_16 <= MAX_SETTLEMENT_FEE_STORED_1()
    && ghostMiOneMarketSettlementFeeCbp2_16 <= MAX_SETTLEMENT_FEE_STORED_2()
    && ghostMiOneMarketSettlementFeeCbp3_16 <= MAX_SETTLEMENT_FEE_STORED_3()
    && ghostMiOneMarketSettlementFeeCbp4_16 <= MAX_SETTLEMENT_FEE_STORED_4()
    && ghostMiOneMarketSettlementFeeCbp5_16 <= MAX_SETTLEMENT_FEE_STORED_5()
    && ghostMiOneMarketSettlementFeeCbp6_16 <= MAX_SETTLEMENT_FEE_STORED_6()
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_ONE_MIDNIGHT(e, eFunc);
    requireInvariant defaultSettlementFeesBounded(e);
} }

// VS-MI-10: the market's continuous fee rate -- the ongoing fee accrued on borrower debt for the
// protocol -- never exceeds the protocol-wide cap, bounding what borrowers can be charged.
// FORMULA: continuousFee <= MAX_CONTINUOUS_FEE_CVL()
invariant marketContinuousFeeBounded(env e)
    ghostMiOneMarketContinuousFee32 <= MAX_CONTINUOUS_FEE_CVL()
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_ONE_MIDNIGHT(e, eFunc);
    requireInvariant defaultContinuousFeeBounded(e);
} }

// VS-MI-11: the per-loan-token default settlement-fee rates (the schedule copied into every
// newly created market) each stay within the same per-breakpoint protocol maximum as the live
// market fees, so no market can be born with an excessive trading fee.
// FORMULA: forall t, i in 0..6. defaultSettlementFeeCbp[t][i] <= MAX_SETTLEMENT_FEE_STORED_i()
invariant defaultSettlementFeesBounded(env e)
    forall address t. (
        ghostMiDefaultSettlementFeeCbp16[t][0] <= MAX_SETTLEMENT_FEE_STORED_0()
        && ghostMiDefaultSettlementFeeCbp16[t][1] <= MAX_SETTLEMENT_FEE_STORED_1()
        && ghostMiDefaultSettlementFeeCbp16[t][2] <= MAX_SETTLEMENT_FEE_STORED_2()
        && ghostMiDefaultSettlementFeeCbp16[t][3] <= MAX_SETTLEMENT_FEE_STORED_3()
        && ghostMiDefaultSettlementFeeCbp16[t][4] <= MAX_SETTLEMENT_FEE_STORED_4()
        && ghostMiDefaultSettlementFeeCbp16[t][5] <= MAX_SETTLEMENT_FEE_STORED_5()
        && ghostMiDefaultSettlementFeeCbp16[t][6] <= MAX_SETTLEMENT_FEE_STORED_6()
    )
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_ONE_MIDNIGHT(e, eFunc); } }

// VS-MI-12: the per-loan-token default continuous fee (copied into every newly created market)
// never exceeds the protocol-wide cap, so no market can be born charging borrowers above it.
// FORMULA: forall t. defaultContinuousFee[t] <= MAX_CONTINUOUS_FEE_CVL()
invariant defaultContinuousFeeBounded(env e)
    forall address t.
        ghostMiDefaultContinuousFee32[t] <= MAX_CONTINUOUS_FEE_CVL()
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_ONE_MIDNIGHT(e, eFunc); } }

definition COLLATERAL_SUM_FOR_LOANTOKEN_ONE() returns mathint =
    (ghostMiOneCollateralToken[0] == ghostMiOneMarketLoanToken
        ? ghostMiOnePositionCollateral128[ghostMiPositionUserOne][0]
          + ghostMiOnePositionCollateral128[ghostMiPositionUserTwo][0]
          + ghostMiOnePositionCollateral128[ghostMiPositionUserThree][0]
        : 0)
    + (ghostNumCollaterals == 2
       && ghostMiOneCollateralToken[1] == ghostMiOneMarketLoanToken
        ? ghostMiOnePositionCollateral128[ghostMiPositionUserOne][1]
          + ghostMiOnePositionCollateral128[ghostMiPositionUserTwo][1]
          + ghostMiOnePositionCollateral128[ghostMiPositionUserThree][1]
        : 0);

// VS-MI-13: the protocol's loan-token balance always covers everything payable on demand in that
// token: the settlement-fee pot claimable by the fee claimer, the loan tokens currently available
// for withdrawal from the market (withdrawable), and any posted collateral that happens to be
// denominated in the loan token itself (collateral summed over the three modeled users and the
// modeled collateral slots).
// FORMULA: balance[loanToken][Midnight] >= claimableSettlementFee[loanToken] + withdrawable
//          + Σ_3users collateral_in_loanToken
invariant claimableAndWithdrawableBackedByBalance(env e)
    ghostERC20Balances128[ghostMiOneMarketLoanToken][_Midnight]
        >= ghostMiClaimableSettlementFee256[ghostMiOneMarketLoanToken]
         + ghostMiOneMarketWithdrawable128
         + COLLATERAL_SUM_FOR_LOANTOKEN_ONE()
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_ONE_MIDNIGHT(e, eFunc);
    requireInvariant noSelfApprove(e);
} }

// VS-MI-14: the protocol's balance of each collateral token covers the total collateral posted
// by borrowers in that token (summed over the three modeled users), so every borrower's
// collateral can always be returned or seized in full.
// FORMULA: forall valid i. balance[collateralToken[i]][Midnight] >= Σ_3users collateral[u][i]
invariant collateralBackedByBalance(env e)
    forall uint256 i. VALID_COLLATERAL_BIT(i) => (
        ghostERC20Balances128[ghostMiOneCollateralToken[i]][_Midnight]
            >= ghostMiOnePositionCollateral128[ghostMiPositionUserOne][i]
             + ghostMiOnePositionCollateral128[ghostMiPositionUserTwo][i]
             + ghostMiOnePositionCollateral128[ghostMiPositionUserThree][i]
    )
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_ONE_MIDNIGHT(e, eFunc);
    requireInvariant claimableAndWithdrawableBackedByBalance(e);
    requireInvariant noSelfApprove(e);
} }

// VS-MI-15: for every token, the protocol's balance covers the settlement-fee pot owed to the
// fee claimer in that token, so a fee claim can always be paid out.
// FORMULA: forall t. balance[t][Midnight] >= claimableSettlementFee[t]
invariant perTokenClaimableBounded(env e)
    forall address t.
        ghostERC20Balances128[t][_Midnight] >= ghostMiClaimableSettlementFee256[t]
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_ONE_MIDNIGHT(e, eFunc);
    requireInvariant claimableAndWithdrawableBackedByBalance(e);
    requireInvariant noSelfApprove(e);
} }

// VS-MI-16: the protocol never grants an ERC20 spending allowance to itself on any token, so no
// code path can move the protocol's own funds through a self-directed transferFrom.
// FORMULA: forall t. allowance[t][Midnight][Midnight] == 0
invariant noSelfApprove(env e)
    forall address t. ghostERC20Allowances256[t][_Midnight][_Midnight] == 0
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_ONE_MIDNIGHT(e, eFunc);
} }

// VS-MI-17: loan-side conservation: every unit of the market's total loan units (totalUnits) is
// either lent out as some borrower's debt or sitting as loan tokens currently available for
// withdrawal from the market (withdrawable) -- debt summed over the three modeled users.
// FORMULA: Σ_3users debt[u] + withdrawable == totalUnits
invariant debtSumAndWithdrawableWithinTotalUnits(env e)
    ghostMiOnePositionDebt128[ghostMiPositionUserOne]
    + ghostMiOnePositionDebt128[ghostMiPositionUserTwo]
    + ghostMiOnePositionDebt128[ghostMiPositionUserThree]
    + ghostMiOneMarketWithdrawable128
    == ghostMiOneMarketTotalUnits128
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_ONE_MIDNIGHT(e, eFunc);
} }

// VS-MI-18: while no bad debt has been socialized, the market's total loan units (totalUnits)
// are fully and exactly attributed to lender credit plus the continuous-fee credit (cfc) -- the
// fee units accrued to the protocol and claimable by the fee claimer -- with credit summed over
// the three modeled users.
// FORMULA: lossFactor == 0 => Σ_3users credit[u] + continuousFeeCredit == totalUnits
invariant creditSumAndCfcEqualTotalUnitsWhenNoBadDebt(env e)
    ghostMiOneMarketLossFactor128 == 0 => (
        ghostMiOnePositionCredit128[ghostMiPositionUserOne]
        + ghostMiOnePositionCredit128[ghostMiPositionUserTwo]
        + ghostMiOnePositionCredit128[ghostMiPositionUserThree]
        + ghostMiOneMarketContinuousFeeCredit128
        == ghostMiOneMarketTotalUnits128
    )
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_ONE_MIDNIGHT(e, eFunc);
    requireInvariant positionLastLossFactorWithinMarket(e);
} }

// VS-MI-20: every market's tick spacing -- the granularity of offer price ticks in the take()
// trade entry point -- is a divisor of the protocol default: it starts at 4 on market creation
// and can only ever be refined to 2 or 1, never coarsened (0 marks an uncreated market).
// FORMULA: forall id. tickSpacing[id] in {0, 1, 2, 4}
invariant tickSpacingDividesDefault(env e)
    forall bytes32 id. VALID_TICK_SPACING(ghostMiMarketTickSpacing[id])
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_ONE_MIDNIGHT(e, eFunc); } }

// VS-MI-21: a borrower carrying live debt always has at least one collateral slot on record, so
// outstanding debt is never left with nothing for a liquidator to seize -- whenever the last
// collateral is taken, the debt is either cleared exactly or realized as bad debt and the
// position zeroed.
// FORMULA: forall u. debt[u] > 0 => collateralBitmap[u] != 0
invariant debtPositiveImpliesCollateralBitmapNonZero(env e)
    forall address u.
        ghostMiOnePositionDebt128[u] > 0 => ghostMiOnePositionCollateralBitmap128[u] > 0
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_ONE_MIDNIGHT(e, eFunc);
    requireInvariant collateralBitmapMatchesSlot(e);
} }

// VS-MI-22 (EXPLORATORY, bug-hunting): the continuous-fee credit (cfc) -- the fee units accrued
// to the protocol and claimable by the fee claimer -- plus all outstanding borrower debt fits
// within the market's total loan units (totalUnits); equivalently the fee pot never exceeds the
// loan tokens currently available for withdrawal from the market (withdrawable), so claiming the
// continuous fee can always be paid out (debt summed over the three modeled users).
// FORMULA: continuousFeeCredit + Σ_3users debt[u] <= totalUnits
invariant continuousFeeCreditWithinTotalUnitsMinusDebt(env e)
    ghostMiOneMarketContinuousFeeCredit128
    + ghostMiOnePositionDebt128[ghostMiPositionUserOne]
    + ghostMiOnePositionDebt128[ghostMiPositionUserTwo]
    + ghostMiOnePositionDebt128[ghostMiPositionUserThree]
    <= ghostMiOneMarketTotalUnits128
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_ONE_MIDNIGHT(e, eFunc);
    requireInvariant debtSumAndWithdrawableWithinTotalUnits(e);
    requireInvariant creditSumAndCfcEqualTotalUnitsWhenNoBadDebt(e);
    requireInvariant creditCoversPendingFee(e);
    requireInvariant positionLastLossFactorWithinMarket(e);
} }
