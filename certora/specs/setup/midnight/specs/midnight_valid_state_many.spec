// Valid-state invariants for Midnight (many-market regime).
//
// Three-market narrowing (idA, idB, idC) + three-user narrowing
// (ghostMiPositionUser{One,Two,Three}): every per-id ghost is bounded and every
// touched id is pinned to {idA, idB, idC}, so per-id invariants are expressed as
// explicit conjunctions over the three markets (no `forall id` quantifier) and
// the ERC20-backing invariants as explicit finite sums over them. Invariant
// names match midnight_valid_state_one.spec -- the two specs are never compiled
// together (separate confs).

import "setup/midnight_many.spec";

function setupValidStateManyMidnight(env e) {
    setupManyMidnight(e);
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
    requireInvariant untouchedMarketIsEmptyParametric(e);
    requireInvariant tickSpacingDividesDefault(e);
}

function SETUP_MANY_MIDNIGHT(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupManyMidnight(e);
}

function SETUP_MANY_MIDNIGHT_FULL(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupValidStateManyMidnight(e);
}

// VS-MI-01: in every market, the fee accrued on a lender position but not yet collected
// (pendingFee) never exceeds that lender's credit balance, so collecting the protocol fee can
// never consume more than the position actually holds.
// FORMULA: forall id, u. pendingFee[id][u] <= credit[id][u]
definition CREDIT_COVERS_PENDING_FEE(bytes32 id, address u) returns bool =
    ghostMiPositionPendingFee128[id][u] <= ghostMiPositionCredit128[id][u];
invariant creditCoversPendingFee(env e)
    forall address u.
        CREDIT_COVERS_PENDING_FEE(ghostMiMarketIdA, u)
        && CREDIT_COVERS_PENDING_FEE(ghostMiMarketIdB, u)
        && CREDIT_COVERS_PENDING_FEE(ghostMiMarketIdC, u)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_MANY_MIDNIGHT(e, eFunc);
    // take's buyer leg mints pendingFee = creditIncrease * continuousFee * ttm / WAD;
    // without the fee cap the induction pre-state admits an unreachable fee.
    requireInvariant marketContinuousFeeBounded(e);
} }

// VS-MI-02: a lender position's stored snapshot of the cumulative bad-debt socialization factor
// (lossFactor) never exceeds the market's current lossFactor, so the lazy slash applied on the
// position's next touch can only charge losses the market has actually recorded.
// FORMULA: forall id, u. lastLossFactor[id][u] <= lossFactor[id]
definition POSITION_LAST_LOSS_FACTOR_WITHIN_MARKET(bytes32 id, address u) returns bool =
    ghostMiPositionLastLossFactor128[id][u] <= ghostMiMarketLossFactor128[id];
invariant positionLastLossFactorWithinMarket(env e)
    forall address u.
        POSITION_LAST_LOSS_FACTOR_WITHIN_MARKET(ghostMiMarketIdA, u)
        && POSITION_LAST_LOSS_FACTOR_WITHIN_MARKET(ghostMiMarketIdB, u)
        && POSITION_LAST_LOSS_FACTOR_WITHIN_MARKET(ghostMiMarketIdC, u)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_MANY_MIDNIGHT(e, eFunc); } }

// VS-MI-03: no position records a fee-accrual timestamp in the future, so continuous-fee
// interest on debt is never computed over a negative time interval.
// FORMULA: forall id, u. lastAccrual[id][u] <= e.block.timestamp
definition LAST_ACCRUAL_NOT_IN_FUTURE(bytes32 id, address u, uint256 ts) returns bool =
    ghostMiPositionLastAccrual128[id][u] <= ts;
invariant lastAccrualNotInFuture(env e)
    forall address u.
        LAST_ACCRUAL_NOT_IN_FUTURE(ghostMiMarketIdA, u, e.block.timestamp)
        && LAST_ACCRUAL_NOT_IN_FUTURE(ghostMiMarketIdB, u, e.block.timestamp)
        && LAST_ACCRUAL_NOT_IN_FUTURE(ghostMiMarketIdC, u, e.block.timestamp)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_MANY_MIDNIGHT(e, eFunc); } }

definition COLLATERAL_BIT_SET(mathint bitmap, uint256 i) returns bool =
    (bitmap / (i == 0 ? 1 : 2)) % 2 == 1;

// VS-MI-04: the per-borrower bitmap tracking which collateral types are posted agrees exactly
// with the stored balances: a collateral slot's bit is set if and only if the borrower holds a
// positive amount of that collateral, so liquidators and withdrawals always see the true set of
// seizable assets.
// FORMULA: forall id, u, valid i. bit_i(collateralBitmap[id][u]) <=> collateral[id][u][i] > 0
definition COLLATERAL_BITMAP_MATCHES_SLOT(bytes32 id, address u, uint256 i) returns bool =
    VALID_COLLATERAL_BIT(i) => (
        COLLATERAL_BIT_SET(ghostMiPositionCollateralBitmap128[id][u], i)
        <=> ghostMiPositionCollateral128[id][u][i] > 0
    );
invariant collateralBitmapMatchesSlot(env e)
    forall address u. forall uint256 i.
        COLLATERAL_BITMAP_MATCHES_SLOT(ghostMiMarketIdA, u, i)
        && COLLATERAL_BITMAP_MATCHES_SLOT(ghostMiMarketIdB, u, i)
        && COLLATERAL_BITMAP_MATCHES_SLOT(ghostMiMarketIdC, u, i)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_MANY_MIDNIGHT(e, eFunc); } }

// VS-MI-05: no credit, fees, debt, or collateral can exist in a market that was never created:
// a position with non-zero credit, pending fee, loss-factor snapshot, accrual timestamp, debt,
// or collateral bitmap implies the market has been initialized (its offer-price tick spacing is
// set); collateral balances themselves are tracked via the bitmap.
// FORMULA: forall id, u. (credit[id][u] > 0 OR pendingFee[id][u] > 0 OR lastLossFactor[id][u] > 0
//          OR lastAccrual[id][u] > 0 OR debt[id][u] > 0 OR collateralBitmap[id][u] > 0)
//          => tickSpacing[id] > 0
definition NON_EMPTY_POSITION_IMPLIES_TOUCHED(bytes32 id, address u) returns bool =
    (
        ghostMiPositionCredit128[id][u] > 0
        || ghostMiPositionPendingFee128[id][u] > 0
        || ghostMiPositionLastLossFactor128[id][u] > 0
        || ghostMiPositionLastAccrual128[id][u] > 0
        || ghostMiPositionDebt128[id][u] > 0
        || ghostMiPositionCollateralBitmap128[id][u] > 0
    ) => ghostMiMarketTickSpacing[id] > 0;
invariant nonEmptyPositionImpliesTouched(env e)
    forall address u.
        NON_EMPTY_POSITION_IMPLIES_TOUCHED(ghostMiMarketIdA, u)
        && NON_EMPTY_POSITION_IMPLIES_TOUCHED(ghostMiMarketIdB, u)
        && NON_EMPTY_POSITION_IMPLIES_TOUCHED(ghostMiMarketIdC, u)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_MANY_MIDNIGHT(e, eFunc); } }

// VS-MI-06: in every market a user is either a lender or a borrower, never both at once: no
// position simultaneously holds interest-bearing credit units and outstanding debt.
// FORMULA: forall id, u. credit[id][u] == 0 || debt[id][u] == 0
definition CREDIT_AND_DEBT_MUTUALLY_EXCLUSIVE(bytes32 id, address u) returns bool =
    ghostMiPositionCredit128[id][u] == 0 || ghostMiPositionDebt128[id][u] == 0;
invariant creditAndDebtMutuallyExclusive(env e)
    forall address u.
        CREDIT_AND_DEBT_MUTUALLY_EXCLUSIVE(ghostMiMarketIdA, u)
        && CREDIT_AND_DEBT_MUTUALLY_EXCLUSIVE(ghostMiMarketIdB, u)
        && CREDIT_AND_DEBT_MUTUALLY_EXCLUSIVE(ghostMiMarketIdC, u)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_MANY_MIDNIGHT(e, eFunc); } }

// VS-MI-07: any position holding lender credit, carrying a fee accrued but not yet collected
// (pendingFee), or stamped with a bad-debt socialization snapshot must have gone through at
// least one fee accrual, i.e. its accrual timestamp is set.
// FORMULA: forall id, u. (credit[id][u] > 0 || lastLossFactor[id][u] > 0 || pendingFee[id][u] > 0)
//                       => lastAccrual[id][u] > 0
definition CREDIT_OR_LAST_LOSS_FACTOR_IMPLIES_LAST_ACCRUAL(bytes32 id, address u) returns bool =
    (ghostMiPositionCredit128[id][u] > 0
        || ghostMiPositionLastLossFactor128[id][u] > 0
        || ghostMiPositionPendingFee128[id][u] > 0)
            => ghostMiPositionLastAccrual128[id][u] > 0;
invariant creditOrLastLossFactorImpliesLastAccrual(env e)
    forall address u.
        CREDIT_OR_LAST_LOSS_FACTOR_IMPLIES_LAST_ACCRUAL(ghostMiMarketIdA, u)
        && CREDIT_OR_LAST_LOSS_FACTOR_IMPLIES_LAST_ACCRUAL(ghostMiMarketIdB, u)
        && CREDIT_OR_LAST_LOSS_FACTOR_IMPLIES_LAST_ACCRUAL(ghostMiMarketIdC, u)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_MANY_MIDNIGHT(e, eFunc); } }

// VS-MI-08: uncollected fees only sit on live lender positions: a position with a positive
// pendingFee (fee accrued on a lender position but not yet collected) must also hold positive
// credit, so fee collection always has a funded position to draw from.
// FORMULA: forall id, u. pendingFee[id][u] > 0 => credit[id][u] > 0
definition PENDING_FEE_POSITIVE_IMPLIES_CREDIT_POSITIVE(bytes32 id, address u) returns bool =
    ghostMiPositionPendingFee128[id][u] > 0
    => ghostMiPositionCredit128[id][u] > 0;
invariant pendingFeePositiveImpliesCreditPositive(env e)
    forall address u.
        PENDING_FEE_POSITIVE_IMPLIES_CREDIT_POSITIVE(ghostMiMarketIdA, u)
        && PENDING_FEE_POSITIVE_IMPLIES_CREDIT_POSITIVE(ghostMiMarketIdB, u)
        && PENDING_FEE_POSITIVE_IMPLIES_CREDIT_POSITIVE(ghostMiMarketIdC, u)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_MANY_MIDNIGHT(e, eFunc);
    requireInvariant creditCoversPendingFee(e);
} }

// VS-MI-09: every market's stored settlement-fee schedule (seven fee buckets that trades pay
// into a per-token claimable pot) stays within the protocol's hard per-bucket maxima, bounding
// the fee any trade can be charged.
// FORMULA: forall id, i in 0..6. settlementFeeCbp_i[id] <= MAX_SETTLEMENT_FEE_STORED_i()
definition MARKET_SETTLEMENT_FEES_BOUNDED(bytes32 id) returns bool =
    ghostMiMarketSettlementFeeCbp0_16[id] <= MAX_SETTLEMENT_FEE_STORED_0()
    && ghostMiMarketSettlementFeeCbp1_16[id] <= MAX_SETTLEMENT_FEE_STORED_1()
    && ghostMiMarketSettlementFeeCbp2_16[id] <= MAX_SETTLEMENT_FEE_STORED_2()
    && ghostMiMarketSettlementFeeCbp3_16[id] <= MAX_SETTLEMENT_FEE_STORED_3()
    && ghostMiMarketSettlementFeeCbp4_16[id] <= MAX_SETTLEMENT_FEE_STORED_4()
    && ghostMiMarketSettlementFeeCbp5_16[id] <= MAX_SETTLEMENT_FEE_STORED_5()
    && ghostMiMarketSettlementFeeCbp6_16[id] <= MAX_SETTLEMENT_FEE_STORED_6();
invariant marketSettlementFeesBounded(env e)
    MARKET_SETTLEMENT_FEES_BOUNDED(ghostMiMarketIdA)
    && MARKET_SETTLEMENT_FEES_BOUNDED(ghostMiMarketIdB)
    && MARKET_SETTLEMENT_FEES_BOUNDED(ghostMiMarketIdC)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_MANY_MIDNIGHT(e, eFunc);
    requireInvariant defaultSettlementFeesBounded(e);
} }

// VS-MI-10: every market's continuous-fee rate -- the ongoing fee charged on borrower debt --
// never exceeds the protocol's hard cap.
// FORMULA: forall id. continuousFee[id] <= MAX_CONTINUOUS_FEE_CVL()
definition MARKET_CONTINUOUS_FEE_BOUNDED(bytes32 id) returns bool =
    ghostMiMarketContinuousFee32[id] <= MAX_CONTINUOUS_FEE_CVL();
invariant marketContinuousFeeBounded(env e)
    MARKET_CONTINUOUS_FEE_BOUNDED(ghostMiMarketIdA)
    && MARKET_CONTINUOUS_FEE_BOUNDED(ghostMiMarketIdB)
    && MARKET_CONTINUOUS_FEE_BOUNDED(ghostMiMarketIdC)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_MANY_MIDNIGHT(e, eFunc);
    requireInvariant defaultContinuousFeeBounded(e);
} }

// VS-MI-11: the per-token default settlement-fee schedule -- the seven trade-fee buckets a
// newly created market inherits for its loan token -- stays within the same hard per-bucket
// maxima as live markets, so the fee setter cannot stage an over-cap fee for future markets.
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
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_MANY_MIDNIGHT(e, eFunc); } }

// VS-MI-12: the per-token default continuous-fee rate, inherited by newly created markets of
// that loan token, never exceeds the protocol's hard cap on the fee charged on borrower debt.
// FORMULA: forall t. defaultContinuousFee[t] <= MAX_CONTINUOUS_FEE_CVL()
invariant defaultContinuousFeeBounded(env e)
    forall address t.
        ghostMiDefaultContinuousFee32[t] <= MAX_CONTINUOUS_FEE_CVL()
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_MANY_MIDNIGHT(e, eFunc); } }

// Σ position.collateral over the three narrowed users for one market slot.
definition COLLATERAL_SLOT_USERSUM(bytes32 id, uint256 slot) returns mathint =
    ghostMiPositionCollateral128[id][ghostMiPositionUserOne][slot]
    + ghostMiPositionCollateral128[id][ghostMiPositionUserTwo][slot]
    + ghostMiPositionCollateral128[id][ghostMiPositionUserThree][slot];

// Σ withdrawable over the three narrowed markets whose loanToken is t.
definition LOAN_WITHDRAWABLE_SUM_MANY(address t) returns mathint =
    (ghostMiMarketTickSpacing[ghostMiMarketIdA] > 0
        && ghostMiMarketLoanToken[ghostMiMarketIdA] == t
        ? ghostMiMarketWithdrawable128[ghostMiMarketIdA] : 0)
    + (ghostMiMarketTickSpacing[ghostMiMarketIdB] > 0
        && ghostMiMarketLoanToken[ghostMiMarketIdB] == t
        ? ghostMiMarketWithdrawable128[ghostMiMarketIdB] : 0)
    + (ghostMiMarketTickSpacing[ghostMiMarketIdC] > 0
        && ghostMiMarketLoanToken[ghostMiMarketIdC] == t
        ? ghostMiMarketWithdrawable128[ghostMiMarketIdC] : 0);

// Σ position.collateral over the three narrowed markets × (narrowed) slots
// × three narrowed users, restricted to slots whose collateralToken is t.
definition COLLATERAL_SUM_FOR_TOKEN_MANY(address t) returns mathint =
    (ghostMiMarketCollateralToken[ghostMiMarketIdA][0] == t
        ? COLLATERAL_SLOT_USERSUM(ghostMiMarketIdA, 0) : 0)
    + (ghostMiMarketCollateralToken[ghostMiMarketIdB][0] == t
        ? COLLATERAL_SLOT_USERSUM(ghostMiMarketIdB, 0) : 0)
    + (ghostMiMarketCollateralToken[ghostMiMarketIdC][0] == t
        ? COLLATERAL_SLOT_USERSUM(ghostMiMarketIdC, 0) : 0)
    + (ghostNumCollaterals == 2
       && ghostMiMarketCollateralToken[ghostMiMarketIdA][1] == t
        ? COLLATERAL_SLOT_USERSUM(ghostMiMarketIdA, 1) : 0)
    + (ghostNumCollaterals == 2
       && ghostMiMarketCollateralToken[ghostMiMarketIdB][1] == t
        ? COLLATERAL_SLOT_USERSUM(ghostMiMarketIdB, 1) : 0)
    + (ghostNumCollaterals == 2
       && ghostMiMarketCollateralToken[ghostMiMarketIdC][1] == t
        ? COLLATERAL_SLOT_USERSUM(ghostMiMarketIdC, 1) : 0);

// VS-MI-13: the protocol can always pay out everything it owes in every token: Midnight's
// actual token balance covers the settlement fees claimable by the fee claimer, plus the loan
// tokens currently available for withdrawal from the market (withdrawable) of every created
// modeled market lending that token, plus all borrower collateral denominated in that token
// (summed over the three modeled markets and three modeled users).
// FORMULA: forall t. balance[t][this] >= claimableSettlementFee[t]
//            + Σ_id withdrawable[id]·[tickSpacing[id] > 0 AND loanToken[id]==t]
//            + Σ_(id,slot,u) collateral[id][u][slot]·[collateralToken[id][slot]==t]
invariant claimableAndWithdrawableBackedByBalance(env e)
    forall address t.
        ghostERC20Balances128[t][_Midnight] >= ghostMiClaimableSettlementFee256[t]
          + LOAN_WITHDRAWABLE_SUM_MANY(t)
          + COLLATERAL_SUM_FOR_TOKEN_MANY(t)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_MANY_MIDNIGHT(e, eFunc);
    requireInvariant noSelfApprove(e);
} }

// VS-MI-14: borrower collateral is always physically backed: for every token, Midnight's actual
// token balance covers all collateral deposited in that token (summed over the three modeled
// markets and three modeled users), so withdrawing or seizing collateral can never fail for
// lack of funds.
// FORMULA: forall t. balance[t][this] >= Σ_(id,slot,u) collateral[id][u][slot]·[collateralToken[id][slot]==t]
invariant collateralBackedByBalance(env e)
    forall address t.
        ghostERC20Balances128[t][_Midnight] >= COLLATERAL_SUM_FOR_TOKEN_MANY(t)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_MANY_MIDNIGHT(e, eFunc);
    requireInvariant claimableAndWithdrawableBackedByBalance(e);
    requireInvariant noSelfApprove(e);
} }

// VS-MI-15: settlement fees owed to the fee claimer are always physically backed: for every
// token, Midnight's actual token balance covers that token's claimable settlement-fee pot.
// FORMULA: forall t. balance[t][this] >= claimableSettlementFee[t]
invariant perTokenClaimableBounded(env e)
    forall address t.
        ghostERC20Balances128[t][_Midnight] >= ghostMiClaimableSettlementFee256[t]
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_MANY_MIDNIGHT(e, eFunc);
    requireInvariant claimableAndWithdrawableBackedByBalance(e);
    requireInvariant noSelfApprove(e);
} }

// VS-MI-16: the Midnight contract never holds an ERC20 allowance from itself to itself, closing
// off any transferFrom path that could move protocol funds against its own approval.
// FORMULA: forall t. allowance[t][this][this] == 0
invariant noSelfApprove(env e)
    forall address t. ghostERC20Allowances256[t][_Midnight][_Midnight] == 0
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_MANY_MIDNIGHT(e, eFunc);
} }

// VS-MI-17: debt-side market solvency: outstanding borrower debt (summed over the three modeled
// users) plus the loan tokens currently available for withdrawal from the market (withdrawable)
// exactly equals the market's total loan units (totalUnits) -- every loan unit is either lent
// out or sitting withdrawable, none is lost or double-counted.
// FORMULA: forall id. Σ_3users debt[id][u] + withdrawable[id] == totalUnits[id]
definition DEBT_SUM_AND_WITHDRAWABLE_WITHIN_TOTAL_UNITS(bytes32 id) returns bool =
    ghostMiPositionDebt128[id][ghostMiPositionUserOne]
    + ghostMiPositionDebt128[id][ghostMiPositionUserTwo]
    + ghostMiPositionDebt128[id][ghostMiPositionUserThree]
    + ghostMiMarketWithdrawable128[id]
    == ghostMiMarketTotalUnits128[id];
invariant debtSumAndWithdrawableWithinTotalUnits(env e)
    DEBT_SUM_AND_WITHDRAWABLE_WITHIN_TOTAL_UNITS(ghostMiMarketIdA)
    && DEBT_SUM_AND_WITHDRAWABLE_WITHIN_TOTAL_UNITS(ghostMiMarketIdB)
    && DEBT_SUM_AND_WITHDRAWABLE_WITHIN_TOTAL_UNITS(ghostMiMarketIdC)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_MANY_MIDNIGHT(e, eFunc);
} }

// VS-MI-18: credit-side market solvency while no bad debt has been socialized: lender credit
// (summed over the three modeled users) plus the continuous-fee credit (cfc, fee units accrued
// to the protocol and claimable by the fee claimer) exactly equals the market's total loan
// units (totalUnits) -- lenders and the protocol together own the market exactly.
// FORMULA: forall id. lossFactor[id] == 0 => Σ_3users credit[id][u] + cfc[id] == totalUnits[id]
definition CREDIT_SUM_AND_CFC_EQUAL_TOTAL_UNITS_WHEN_NO_BAD_DEBT(bytes32 id) returns bool =
    ghostMiMarketLossFactor128[id] == 0 => (
        ghostMiPositionCredit128[id][ghostMiPositionUserOne]
        + ghostMiPositionCredit128[id][ghostMiPositionUserTwo]
        + ghostMiPositionCredit128[id][ghostMiPositionUserThree]
        + ghostMiMarketContinuousFeeCredit128[id]
        == ghostMiMarketTotalUnits128[id]
    );
invariant creditSumAndCfcEqualTotalUnitsWhenNoBadDebt(env e)
    CREDIT_SUM_AND_CFC_EQUAL_TOTAL_UNITS_WHEN_NO_BAD_DEBT(ghostMiMarketIdA)
    && CREDIT_SUM_AND_CFC_EQUAL_TOTAL_UNITS_WHEN_NO_BAD_DEBT(ghostMiMarketIdB)
    && CREDIT_SUM_AND_CFC_EQUAL_TOTAL_UNITS_WHEN_NO_BAD_DEBT(ghostMiMarketIdC)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_MANY_MIDNIGHT(e, eFunc);
    requireInvariant positionLastLossFactorWithinMarket(e);
} }

//
// MarketState (explicit over idA, idB, idC)
//

// VS-MI-19: a market that was never created holds nothing: while its offer-price tick spacing
// is unset, all of its accounting -- total loan units, bad-debt socialization factor,
// withdrawable liquidity, fee credit, and every fee parameter -- is zero.
// FORMULA: forall id. tickSpacing[id] == 0 => (all other MarketState[id] fields == 0)
definition UNTOUCHED_MARKET_IS_EMPTY(bytes32 id) returns bool =
    ghostMiMarketTickSpacing[id] == 0 => (
        ghostMiMarketTotalUnits128[id] == 0
        && ghostMiMarketLossFactor128[id] == 0
        && ghostMiMarketWithdrawable128[id] == 0
        && ghostMiMarketContinuousFeeCredit128[id] == 0
        && ghostMiMarketSettlementFeeCbp0_16[id] == 0
        && ghostMiMarketSettlementFeeCbp1_16[id] == 0
        && ghostMiMarketSettlementFeeCbp2_16[id] == 0
        && ghostMiMarketSettlementFeeCbp3_16[id] == 0
        && ghostMiMarketSettlementFeeCbp4_16[id] == 0
        && ghostMiMarketSettlementFeeCbp5_16[id] == 0
        && ghostMiMarketSettlementFeeCbp6_16[id] == 0
        && ghostMiMarketContinuousFee32[id] == 0
    );
invariant untouchedMarketIsEmptyParametric(env e)
    UNTOUCHED_MARKET_IS_EMPTY(ghostMiMarketIdA)
    && UNTOUCHED_MARKET_IS_EMPTY(ghostMiMarketIdB)
    && UNTOUCHED_MARKET_IS_EMPTY(ghostMiMarketIdC)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_MANY_MIDNIGHT(e, eFunc); } }

// VS-MI-20: a market's tick spacing -- the price granularity of offers filled through the
// take() trade entry point (a buyer fills a maker's offer) -- is always a divisor of the
// protocol default of 4: creation sets 4 and the tick-spacing setter may only refine it, so it
// is one of 0 (market not yet created), 1, 2, or 4.
// FORMULA: forall id. tickSpacing[id] in {0, 1, 2, 4}
definition TICK_SPACING_DIVIDES_DEFAULT(bytes32 id) returns bool =
    VALID_TICK_SPACING(ghostMiMarketTickSpacing[id]);
invariant tickSpacingDividesDefault(env e)
    TICK_SPACING_DIVIDES_DEFAULT(ghostMiMarketIdA)
    && TICK_SPACING_DIVIDES_DEFAULT(ghostMiMarketIdB)
    && TICK_SPACING_DIVIDES_DEFAULT(ghostMiMarketIdC)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) { SETUP_MANY_MIDNIGHT(e, eFunc); } }

// VS-MI-21: in every market, a borrower with outstanding debt always has at least one activated
// collateral slot, so a liquidator always has something to seize: a position is only fully
// stripped of collateral once its debt has been repaid, seized away, or written off as
// socialized bad debt.
// FORMULA: forall id, u. debt[id][u] > 0 => collateralBitmap[id][u] != 0
definition DEBT_POSITIVE_IMPLIES_COLLATERAL_BITMAP_NON_ZERO(bytes32 id, address u) returns bool =
    ghostMiPositionDebt128[id][u] > 0 => ghostMiPositionCollateralBitmap128[id][u] > 0;
invariant debtPositiveImpliesCollateralBitmapNonZero(env e)
    forall address u.
        DEBT_POSITIVE_IMPLIES_COLLATERAL_BITMAP_NON_ZERO(ghostMiMarketIdA, u)
        && DEBT_POSITIVE_IMPLIES_COLLATERAL_BITMAP_NON_ZERO(ghostMiMarketIdB, u)
        && DEBT_POSITIVE_IMPLIES_COLLATERAL_BITMAP_NON_ZERO(ghostMiMarketIdC, u)
filtered { f -> !EXCLUDED_FUNCTION(f) } { preserved with (env eFunc) {
    SETUP_MANY_MIDNIGHT(e, eFunc);
    requireInvariant collateralBitmapMatchesSlot(e);
} }

//
// Getter / storage agreement (id-meaningful sibling of HL-MI-22)
//

// HL-MI-22m: public view functions keyed by a market id report exactly that market's stored
// accounting and never another market's: the market's total loan units (totalUnits), its loan
// tokens currently available for withdrawal (withdrawable), and per-user lender credit and
// borrower debt all read back the storage of the queried market, checked across two distinct
// markets and a user from the modeled three-user set.
// FORMULA: (forall id in {idA, idB}. totalUnits(id) == totalUnits[id]
//                                    AND withdrawable(id) == withdrawable[id])
//          AND credit(idA, user) == credit[idA][user]
//          AND debt(idB, user) == debt[idB][user]
rule gettersMatchStoragePerId(env e, address user) {
    setupValidStateManyMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");

    assert(to_mathint(totalUnits(e, ghostMiMarketIdA)) == ghostMiMarketTotalUnits128[ghostMiMarketIdA]
        && to_mathint(totalUnits(e, ghostMiMarketIdB)) == ghostMiMarketTotalUnits128[ghostMiMarketIdB],
        "totalUnits(id) must read marketState[id], not another market's slot");
    assert(to_mathint(withdrawable(e, ghostMiMarketIdA)) == ghostMiMarketWithdrawable128[ghostMiMarketIdA]
        && to_mathint(withdrawable(e, ghostMiMarketIdB)) == ghostMiMarketWithdrawable128[ghostMiMarketIdB],
        "withdrawable(id) must read marketState[id], not another market's slot");
    assert(to_mathint(credit(e, ghostMiMarketIdA, user)) == ghostMiPositionCredit128[ghostMiMarketIdA][user]
        && to_mathint(debt(e, ghostMiMarketIdB, user)) == ghostMiPositionDebt128[ghostMiMarketIdB][user],
        "credit/debt(id, user) must read position[id][user], not another market's position");
}

//
// Liquidate cross-market isolation
//

// ST-MI-17 (Pattern 6): liquidation is strictly market-local: a liquidator repaying debt and
// seizing collateral on one market leaves every other market completely untouched -- both the
// other market's state (total loan units, withdrawable liquidity, bad-debt socialization
// factor, fee credit, and all fee parameters) and every user position on it (credit, fees,
// debt, collateral). Losses and funds can never leak across markets through a liquidation.
// FORMULA: forall other != toId(market), forall u. after liquidate(market, ...):
//          totalUnits[other]' == totalUnits[other]
//          AND withdrawable[other]' == withdrawable[other]
//          AND lossFactor[other]' == lossFactor[other]
//          AND continuousFeeCredit[other]' == continuousFeeCredit[other]
//          AND tickSpacing[other]' == tickSpacing[other]
//          AND continuousFee[other]' == continuousFee[other]
//          AND settlementFeeCbp_i[other]' == settlementFeeCbp_i[other] for i in 0..6
//          AND credit[other][u]' == credit[other][u]
//          AND pendingFee[other][u]' == pendingFee[other][u]
//          AND lastAccrual[other][u]' == lastAccrual[other][u]
//          AND lastLossFactor[other][u]' == lastLossFactor[other][u]
//          AND debt[other][u]' == debt[other][u]
//          AND collateralBitmap[other][u]' == collateralBitmap[other][u]
//          AND collateral[other][u][i]' == collateral[other][u][i] for i in {0, 1}
rule liquidateMarketIsolationMany(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data, bytes32 other, address u
) {
    setupValidStateManyMidnight(e);
    bytes32 id = toId(e, market);
    require(other != id, "frame target is a market different from the liquidated one");

    mathint tuBefore     = ghostMiMarketTotalUnits128[other];
    mathint wBefore      = ghostMiMarketWithdrawable128[other];
    mathint lfBefore     = ghostMiMarketLossFactor128[other];
    mathint cfcBefore    = ghostMiMarketContinuousFeeCredit128[other];
    mathint tsBefore     = ghostMiMarketTickSpacing[other];
    mathint cfBefore     = ghostMiMarketContinuousFee32[other];
    mathint sf0Before    = ghostMiMarketSettlementFeeCbp0_16[other];
    mathint sf1Before    = ghostMiMarketSettlementFeeCbp1_16[other];
    mathint sf2Before    = ghostMiMarketSettlementFeeCbp2_16[other];
    mathint sf3Before    = ghostMiMarketSettlementFeeCbp3_16[other];
    mathint sf4Before    = ghostMiMarketSettlementFeeCbp4_16[other];
    mathint sf5Before    = ghostMiMarketSettlementFeeCbp5_16[other];
    mathint sf6Before    = ghostMiMarketSettlementFeeCbp6_16[other];
    mathint creditBefore = ghostMiPositionCredit128[other][u];
    mathint pfBefore     = ghostMiPositionPendingFee128[other][u];
    mathint laBefore     = ghostMiPositionLastAccrual128[other][u];
    mathint llfBefore    = ghostMiPositionLastLossFactor128[other][u];
    mathint debtBefore   = ghostMiPositionDebt128[other][u];
    mathint bmBefore     = ghostMiPositionCollateralBitmap128[other][u];
    mathint c0Before     = ghostMiPositionCollateral128[other][u][0];
    mathint c1Before     = ghostMiPositionCollateral128[other][u][1];

    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);

    assert(ghostMiMarketTotalUnits128[other]          == tuBefore
        && ghostMiMarketWithdrawable128[other]        == wBefore
        && ghostMiMarketLossFactor128[other]          == lfBefore
        && ghostMiMarketContinuousFeeCredit128[other] == cfcBefore
        && ghostMiMarketTickSpacing[other]            == tsBefore
        && ghostMiMarketContinuousFee32[other]        == cfBefore
        && ghostMiMarketSettlementFeeCbp0_16[other]   == sf0Before
        && ghostMiMarketSettlementFeeCbp1_16[other]   == sf1Before
        && ghostMiMarketSettlementFeeCbp2_16[other]   == sf2Before
        && ghostMiMarketSettlementFeeCbp3_16[other]   == sf3Before
        && ghostMiMarketSettlementFeeCbp4_16[other]   == sf4Before
        && ghostMiMarketSettlementFeeCbp5_16[other]   == sf5Before
        && ghostMiMarketSettlementFeeCbp6_16[other]   == sf6Before,
        "liquidate must leave every other market's state untouched");
    assert(ghostMiPositionCredit128[other][u]            == creditBefore
        && ghostMiPositionPendingFee128[other][u]        == pfBefore
        && ghostMiPositionLastAccrual128[other][u]       == laBefore
        && ghostMiPositionLastLossFactor128[other][u]    == llfBefore
        && ghostMiPositionDebt128[other][u]              == debtBefore
        && ghostMiPositionCollateralBitmap128[other][u]  == bmBefore
        && ghostMiPositionCollateral128[other][u][0]     == c0Before
        && ghostMiPositionCollateral128[other][u][1]     == c1Before,
        "liquidate must leave every other market's positions untouched");
}
