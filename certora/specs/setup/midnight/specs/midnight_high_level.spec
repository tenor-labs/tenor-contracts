// High-Level behavioral rules for Midnight (one-market regime).
//
// High-Level properties target specific function sequences (or single entry points) and
// assert end-to-end behavioral guarantees that are not expressible as plain valid-state
// invariants. Every rule here is checkable under the ONE-market narrowing (no rule needs
// cross-id reasoning), so per the "check with one where possible" principle they all run
// on the one-market regime with the full valid-state set loaded via setupValidStateOneMidnight.

import "midnight_valid_state_one.spec";

definition ORACLE_PRICE_SCALE_CVL() returns mathint = 1000000000000000000000000000000000000; // 1e36

//
// Settlement-fee pot
//

// HL-MI-01: settlement fees owed to the fee claimer are never clawed back by trading — the take()
// trade entry point (a buyer fills a maker's offer) can only grow, never shrink, the pot of
// claimable settlement fees for any token.
// FORMULA: forall token. claimableSettlementFee[token]' >= claimableSettlementFee[token]
rule claimableSettlementFeeNeverDecreases(env e, calldataarg args, address token) {
    setupValidStateOneMidnight(e);

    mathint feeBefore = ghostMiClaimableSettlementFee256[token];
    take(e, args);
    mathint feeAfter = ghostMiClaimableSettlementFee256[token];

    assert(feeAfter >= feeBefore,
        "Midnight's claimable settlement fee for the token never decreases across a take");
}

// HL-MI-02 (HL-CAND-01, Pattern 2): in the take() trade entry point (a buyer fills a maker's
// offer), the buyer pays at least as much as the seller receives, and that spread is the
// settlement fee. The growth of the fee pot claimable by the fee claimer must exactly equal the
// loan tokens that flow into the protocol's own balance during the trade — the protocol neither
// skims tokens beyond the recorded fee nor records fees it never received. Checked with no trade
// participant, callback, or payout receiver being the protocol itself.
// FORMULA: claimableSettlementFee[loanToken]' - claimableSettlementFee[loanToken]
//          == balance[loanToken][Midnight]' - balance[loanToken][Midnight]
rule takeCapturesExactSettlementFee(
    env e,
    MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    address loanToken = offer.market.loanToken;
    // payer in {offer.callback, takerCallback, offer.maker, taker, msg.sender}; receiver in
    // {receiverIfTakerIsSeller, offer.receiverIfMakerIsSeller}. Exclude all from being Midnight so the only
    // loanToken movement touching Midnight's balance is the +spread pull.
    require(taker != _Midnight && offer.maker != _Midnight, "SAFE: counterparties are not Midnight");
    require(offer.callback != _Midnight && takerCallback != _Midnight, "SAFE: callbacks are not Midnight");
    require(receiverIfTakerIsSeller != _Midnight && offer.receiverIfMakerIsSeller != _Midnight,
        "SAFE: seller-assets receiver is not Midnight");

    mathint claimBefore = ghostMiClaimableSettlementFee256[loanToken];
    mathint balBefore   = ghostERC20Balances128[loanToken][_Midnight];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    mathint claimAfter = ghostMiClaimableSettlementFee256[loanToken];
    mathint balAfter   = ghostERC20Balances128[loanToken][_Midnight];

    assert(claimAfter - claimBefore == balAfter - balBefore,
        "take: settlement-fee captured equals the loanToken inflow into Midnight (the buyer/seller spread)");
}

//
// Exact Before/After + internal<->external balance match
//

// HL-MI-03 (HL-CAND-02, Pattern 1): withdraw removes exactly the requested amount from the
// market's available liquidity and total units, and sends exactly that amount of loan tokens
// out of the protocol to the receiver. The lender's position legs are exact too: credit drops by
// exactly the withdrawn units (measured after any pending bad-debt slash and fee accrual settle),
// the fee accrued but not yet collected (pendingFee) burns proportionally to the withdrawn credit
// rounded against the lender, and a full exit leaves no pendingFee behind — so a lender cannot
// time their exit to dodge a pending slash.
// FORMULA: withdrawable' == withdrawable - units
//          AND totalUnits' == totalUnits - units
//          AND balance[loanToken][Midnight]' == balance[loanToken][Midnight] - units
//          AND credit[onBehalf]' == viewCredit - units
//          AND viewCredit > 0 =>
//              pendingFee[onBehalf]' == viewPendingFee - ceil(viewPendingFee * units / viewCredit)
//          AND units == viewCredit => pendingFee[onBehalf]' == 0
//          where (viewCredit, viewPendingFee) = the position after its pending slash/accrual settles
rule withdrawExactDecrement(env e, MidnightHarness.Market market, uint256 units, address onBehalf, address receiver) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    require(receiver != _Midnight, "SAFE: withdraw receiver is not Midnight");
    address loanToken = market.loanToken;
    bytes32 id = toId(e, market);

    // Post-update pre-image: what _updatePosition will write before the decrement applies.
    uint128 viewCredit; uint128 viewPendingFee; uint128 viewAccrued;
    viewCredit, viewPendingFee, viewAccrued = updatePositionView(e, market, id, onBehalf);

    mathint withdrawableBefore = ghostMiOneMarketWithdrawable128;
    mathint totalUnitsBefore   = ghostMiOneMarketTotalUnits128;
    mathint balBefore          = ghostERC20Balances128[loanToken][_Midnight];

    withdraw(e, market, units, onBehalf, receiver);

    assert(ghostMiOneMarketWithdrawable128 == withdrawableBefore - units
        && ghostMiOneMarketTotalUnits128   == totalUnitsBefore - units
        && ghostERC20Balances128[loanToken][_Midnight] == balBefore - units,
        "withdraw: withdrawable, totalUnits, and Midnight loanToken balance each drop by exactly units");

    assert(ghostMiOnePositionCredit128[onBehalf] == viewCredit - units,
        "withdraw: the post-slash/accrual credit (view pre-image) drops by exactly units");

    mathint pfBurn = viewCredit > 0
        ? (to_mathint(viewPendingFee) * units + viewCredit - 1) / viewCredit  // mulDivUp
        : 0;
    assert(viewCredit > 0 => ghostMiOnePositionPendingFee128[onBehalf] == viewPendingFee - pfBurn,
        "withdraw: pendingFee burns proportionally to the withdrawn credit, rounded up against the lender");
    assert(to_mathint(units) == to_mathint(viewCredit) => ghostMiOnePositionPendingFee128[onBehalf] == 0,
        "withdraw: a full exit extinguishes the lender's pendingFee");
}

// HL-MI-04 (HL-CAND-03, Pattern 1): repaying converts a borrower's debt back into available
// liquidity one-for-one — debt drops by exactly the repaid units, the loan tokens available for
// withdrawal from the market (withdrawable) rise by the same amount, the market's total loan
// units (totalUnits) are unchanged, and exactly that many loan tokens are pulled into the
// protocol.
// FORMULA: debt[onBehalf]' == debt[onBehalf] - units
//          AND withdrawable' == withdrawable + units
//          AND totalUnits' == totalUnits
//          AND balance[loanToken][Midnight]' == balance[loanToken][Midnight] + units
rule repayExactSwap(env e, MidnightHarness.Market market, uint256 units, address onBehalf, address callback, bytes data) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    require(callback != _Midnight, "SAFE: repay payer (callback) is not Midnight");
    address loanToken = market.loanToken;

    mathint debtBefore         = ghostMiOnePositionDebt128[onBehalf];
    mathint withdrawableBefore = ghostMiOneMarketWithdrawable128;
    mathint totalUnitsBefore   = ghostMiOneMarketTotalUnits128;
    mathint balBefore          = ghostERC20Balances128[loanToken][_Midnight];

    repay(e, market, units, onBehalf, callback, data);

    assert(ghostMiOnePositionDebt128[onBehalf] == debtBefore - units
        && ghostMiOneMarketWithdrawable128     == withdrawableBefore + units
        && ghostMiOneMarketTotalUnits128       == totalUnitsBefore
        && ghostERC20Balances128[loanToken][_Midnight] == balBefore + units,
        "repay: debt -= units, withdrawable += units, totalUnits unchanged, Midnight loanToken balance += units");
}

// HL-MI-05 (HL-CAND-04, Pattern 1): when the fee claimer collects the protocol's continuous-fee
// credit (cfc — fee units accrued to the protocol), the claim is exact: the cfc pot, the market's
// total loan units (totalUnits), and the liquidity available for withdrawal (withdrawable) each
// drop by exactly the claimed amount, and exactly that many loan tokens leave the protocol.
// FORMULA: continuousFeeCredit' == continuousFeeCredit - amount
//          AND totalUnits' == totalUnits - amount
//          AND withdrawable' == withdrawable - amount
//          AND balance[loanToken][Midnight]' == balance[loanToken][Midnight] - amount
rule claimContinuousFeeExactDecrement(env e, MidnightHarness.Market market, uint256 amount, address receiver) {
    setupValidStateOneMidnight(e);
    require(receiver != _Midnight, "SAFE: fee receiver is not Midnight");
    address loanToken = market.loanToken;

    mathint cfcBefore          = ghostMiOneMarketContinuousFeeCredit128;
    mathint totalUnitsBefore   = ghostMiOneMarketTotalUnits128;
    mathint withdrawableBefore = ghostMiOneMarketWithdrawable128;
    mathint balBefore          = ghostERC20Balances128[loanToken][_Midnight];

    claimContinuousFee(e, market, amount, receiver);

    assert(ghostMiOneMarketContinuousFeeCredit128 == cfcBefore - amount
        && ghostMiOneMarketTotalUnits128          == totalUnitsBefore - amount
        && ghostMiOneMarketWithdrawable128        == withdrawableBefore - amount
        && ghostERC20Balances128[loanToken][_Midnight] == balBefore - amount,
        "claimContinuousFee: continuousFeeCredit, totalUnits, withdrawable, and Midnight balance each drop by amount");
}

// HL-MI-06 (HL-CAND-05, Pattern 1): supplying collateral credits the borrower's collateral slot by
// exactly the deposited amount and pulls exactly that many collateral tokens into the protocol —
// no fees, rounding, or leakage on the way in.
// FORMULA: collateral[onBehalf][i]' == collateral[onBehalf][i] + assets
//          AND balance[collateralToken[i]][Midnight]'
//              == balance[collateralToken[i]][Midnight] + assets
rule supplyCollateralExactAdd(env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 assets, address onBehalf) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    address collateralToken = ghostMiOneCollateralToken[collateralIndex];
    require(collateralToken != _Midnight, "SAFE: collateral token is not Midnight");

    mathint collBefore = ghostMiOnePositionCollateral128[onBehalf][collateralIndex];
    mathint balBefore  = ghostERC20Balances128[collateralToken][_Midnight];

    supplyCollateral(e, market, collateralIndex, assets, onBehalf);

    assert(ghostMiOnePositionCollateral128[onBehalf][collateralIndex] == collBefore + assets
        && ghostERC20Balances128[collateralToken][_Midnight] == balBefore + assets,
        "supplyCollateral: collateral slot and Midnight collateral balance each grow by exactly assets");
}

//
// Flash loan
//

// HL-MI-07 (HL-CAND-06, Pattern 2/9): flash loans are free and side-effect free — the protocol
// lends tokens out and pulls the same amount back within the call, charging no fee, so neither the
// protocol nor the caller profits, and a flash loan cannot be used to move any lender or borrower
// position, market aggregate, fee pot, offer-fill counter, or delegation.
// FORMULA: forall token, u, i in {0, 1}, g, a, b.
//          balance[token][Midnight]' == balance[token][Midnight]
//          AND credit[u]' == credit[u] AND debt[u]' == debt[u] AND pendingFee[u]' == pendingFee[u]
//          AND lastLossFactor[u]' == lastLossFactor[u] AND lastAccrual[u]' == lastAccrual[u]
//          AND collateralBitmap[u]' == collateralBitmap[u] AND collateral[u][i]' == collateral[u][i]
//          AND totalUnits' == totalUnits AND withdrawable' == withdrawable
//          AND continuousFeeCredit' == continuousFeeCredit AND lossFactor' == lossFactor
//          AND claimableSettlementFee[token]' == claimableSettlementFee[token]
//          AND consumed[u][g]' == consumed[u][g] AND isAuthorized[a][b]' == isAuthorized[a][b]
rule flashLoanBalanceNeutral(
    env e, address[] tokens, uint256[] assets, address callback, bytes data,
    address token, address u, bytes32 g, address a, address b
) {
    setupValidStateOneMidnight(e);

    mathint balBefore        = ghostERC20Balances128[token][_Midnight];
    mathint creditBefore     = ghostMiOnePositionCredit128[u];
    mathint debtBefore       = ghostMiOnePositionDebt128[u];
    mathint pendingFeeBefore = ghostMiOnePositionPendingFee128[u];
    mathint llfBefore        = ghostMiOnePositionLastLossFactor128[u];
    mathint lastAccrualBefore = ghostMiOnePositionLastAccrual128[u];
    mathint bitmapBefore     = ghostMiOnePositionCollateralBitmap128[u];
    mathint coll0Before      = ghostMiOnePositionCollateral128[u][0];
    mathint coll1Before      = ghostMiOnePositionCollateral128[u][1];
    mathint tuBefore         = ghostMiOneMarketTotalUnits128;
    mathint withdrawableBefore = ghostMiOneMarketWithdrawable128;
    mathint cfcBefore        = ghostMiOneMarketContinuousFeeCredit128;
    mathint lossFactorBefore = ghostMiOneMarketLossFactor128;
    mathint claimableBefore  = ghostMiClaimableSettlementFee256[token];
    mathint consumedBefore   = ghostMiConsumed256[u][g];
    bool    authBefore       = ghostMiIsAuthorized[a][b];

    flashLoan(e, tokens, assets, callback, data);

    assert(ghostERC20Balances128[token][_Midnight] == balBefore,
        "flashLoan leaves Midnight's balance of every token unchanged (zero fee)");
    assert(ghostMiOnePositionCredit128[u] == creditBefore
        && ghostMiOnePositionDebt128[u] == debtBefore
        && ghostMiOnePositionPendingFee128[u] == pendingFeeBefore
        && ghostMiOnePositionLastLossFactor128[u] == llfBefore
        && ghostMiOnePositionLastAccrual128[u] == lastAccrualBefore
        && ghostMiOnePositionCollateralBitmap128[u] == bitmapBefore
        && ghostMiOnePositionCollateral128[u][0] == coll0Before
        && ghostMiOnePositionCollateral128[u][1] == coll1Before,
        "flashLoan leaves every position field untouched");
    assert(ghostMiOneMarketTotalUnits128 == tuBefore
        && ghostMiOneMarketWithdrawable128 == withdrawableBefore
        && ghostMiOneMarketContinuousFeeCredit128 == cfcBefore
        && ghostMiOneMarketLossFactor128 == lossFactorBefore
        && ghostMiClaimableSettlementFee256[token] == claimableBefore,
        "flashLoan leaves the market aggregates and fee pots untouched");
    assert(ghostMiConsumed256[u][g] == consumedBefore && ghostMiIsAuthorized[a][b] == authBefore,
        "flashLoan leaves consumed and the authorization graph untouched");
}

//
// Safety preservation
//

// HL-MI-08 (HL-CAND-08, Pattern 10): a borrower can only take collateral out if their position
// ends up healthy — whenever withdrawCollateral succeeds, the borrower's remaining collateral
// still covers their debt under the loan-to-liquidation-value threshold (lltv), so withdrawing
// collateral can never leave the position liquidatable.
// FORMULA: withdrawCollateral succeeds => isHealthy(market, onBehalf)'
rule withdrawCollateralLeavesBorrowerHealthy(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 assets, address onBehalf, address receiver
) {
    setupValidStateOneMidnight(e);
    bytes32 id = toId(e, market);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");

    withdrawCollateral(e, market, collateralIndex, assets, onBehalf, receiver);

    assert(isHealthy(e, market, id, onBehalf),
        "withdrawCollateral leaves the borrower healthy");
}

// HL-MI-09 (HL-CAND-09, Pattern 10): liquidation only shrinks the borrower's position, and by
// exact amounts: the targeted collateral slot drops by exactly the assets the liquidator seizes,
// no other collateral slot is touched, and the debt reduction splits exactly into the cash the
// liquidator repaid plus the bad debt written off and socialized across lenders (mirrored
// one-for-one as the only drop in the market's total loan units, totalUnits).
// FORMULA: collateral[borrower][i] - collateral[borrower][i]' == seized
//          AND collateral[borrower][other]' == collateral[borrower][other]
//          AND debt[borrower] - debt[borrower]' == repaid + (totalUnits - totalUnits')
rule liquidateIsReductive(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssetsIn,
    uint256 repaidUnitsIn, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    uint256 otherIndex = collateralIndex == 0 ? 1 : 0;

    mathint debtBefore      = ghostMiOnePositionDebt128[borrower];
    mathint collBefore      = ghostMiOnePositionCollateral128[borrower][collateralIndex];
    mathint collOtherBefore = ghostMiOnePositionCollateral128[borrower][otherIndex];
    mathint tuBefore        = ghostMiOneMarketTotalUnits128;

    uint256 seized; uint256 repaid;
    seized, repaid = liquidate(e, market, collateralIndex, seizedAssetsIn, repaidUnitsIn, borrower,
        postMaturityMode, receiver, callback, data);

    assert(collBefore - ghostMiOnePositionCollateral128[borrower][collateralIndex] == to_mathint(seized),
        "liquidate: the seized slot drops by exactly the returned seizedAssets");
    assert(ghostMiOnePositionCollateral128[borrower][otherIndex] == collOtherBefore,
        "liquidate: the non-seized collateral slot is untouched");
    assert(debtBefore - ghostMiOnePositionDebt128[borrower]
        == to_mathint(repaid) + (tuBefore - ghostMiOneMarketTotalUnits128),
        "liquidate: debt reduction == repaidUnits + badDebt (the only totalUnits movement)");
}

//
// Round-trips
//

// HL-MI-10 (HL-CAND-10, Pattern 3): collateral is not fee-bearing — depositing collateral and then
// withdrawing the same amount from the same slot restores the borrower's collateral balance
// exactly, with no leakage in either direction.
// FORMULA: after supplyCollateral(i, assets); withdrawCollateral(i, assets):
//          collateral[onBehalf][i]' == collateral[onBehalf][i]
rule collateralRoundTripRestoresSlot(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 assets, address onBehalf, address receiver
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");

    mathint collBefore = ghostMiOnePositionCollateral128[onBehalf][collateralIndex];

    supplyCollateral(e, market, collateralIndex, assets, onBehalf);
    withdrawCollateral(e, market, collateralIndex, assets, onBehalf, receiver);

    assert(ghostMiOnePositionCollateral128[onBehalf][collateralIndex] == collBefore,
        "supplyCollateral then withdrawCollateral of the same slot/assets restores the collateral slot");
}

//
// Accrual isolation
//

// HL-MI-11 (HL-CAND-12, Pattern 1 non-effect): settling a lender's position (applying the
// continuous-fee accrual and any pending bad-debt slash) only reshuffles value between the
// lender's credit, their fee accrued but not yet collected (pendingFee), and the protocol's fee
// pot — it never changes the market's total loan units (totalUnits) or the loan tokens available
// for withdrawal (withdrawable).
// FORMULA: totalUnits' == totalUnits AND withdrawable' == withdrawable
rule updatePositionPreservesTotalUnitsAndWithdrawable(env e, MidnightHarness.Market market, address user) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");

    mathint totalUnitsBefore   = ghostMiOneMarketTotalUnits128;
    mathint withdrawableBefore = ghostMiOneMarketWithdrawable128;

    updatePosition(e, market, user);

    assert(ghostMiOneMarketTotalUnits128   == totalUnitsBefore
        && ghostMiOneMarketWithdrawable128 == withdrawableBefore,
        "updatePosition must not change totalUnits or withdrawable");
}

//
// Bug-hunting / offensive rules (HL-MI-12..22)
//
// These assert protocol-safety properties whose REFUTATION would reveal a real bug (token leak,
// insolvency, over-seizure, missing auth, mis-accounting, view/state divergence). Unlike HL-MI-01..11
// they are EXPECTED to possibly fail -- a failure here is a finding to investigate, not a spec bug.
// Note: "take round-trip yields no taker profit" is NOT a valid property — a taker legitimately
// profits from a good offer; the only protocol-relevant no-loss property is surplus invariance HL-MI-12/13.

// HL-MI-12 (BH-1a, Pattern 2/4, bug-hunting): the protocol never pays out more loan tokens than
// the liability it discharges. Its loan-token surplus — token balance minus the settlement fees
// owed to the fee claimer, minus the loan tokens available for withdrawal from the market
// (withdrawable), minus any borrower collateral that happens to be denominated in the loan token —
// never decreases under any operation; a decrease would be a token leak.
// FORMULA: forall f. surplus' >= surplus
//          where surplus = balance[loanToken][Midnight] - claimableSettlementFee[loanToken]
//                          - withdrawable - Σ_u,i collateral[u][i] over slots whose token == loanToken
rule loanTokenSurplusNonDecreasing(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    address loanToken = ghostMiOneMarketLoanToken;

    mathint surplusBefore = ghostERC20Balances128[loanToken][_Midnight]
        - ghostMiClaimableSettlementFee256[loanToken] - ghostMiOneMarketWithdrawable128
        - COLLATERAL_SUM_FOR_LOANTOKEN_ONE();

    f(e, args);

    mathint surplusAfter = ghostERC20Balances128[loanToken][_Midnight]
        - ghostMiClaimableSettlementFee256[loanToken] - ghostMiOneMarketWithdrawable128
        - COLLATERAL_SUM_FOR_LOANTOKEN_ONE();

    assert(surplusAfter >= surplusBefore,
        "loanToken surplus (balance - claimable - withdrawable - aliased collateral) must never decrease (no leak)");
}

// HL-MI-13 (BH-1b, Pattern 2/4, bug-hunting): the protocol always holds at least as many
// collateral tokens as it owes back to borrowers. For a live collateral slot whose token differs
// from the loan token, the surplus — the protocol's token balance minus the collateral recorded
// for the three modeled users — never decreases under any operation; a decrease would be a
// collateral leak.
// FORMULA: forall f. surplus' >= surplus
//          where surplus = balance[collateralToken[i]][Midnight] - Σ_u collateral[u][i]
rule collateralTokenSurplusNonDecreasing(env e, method f, calldataarg args, uint256 idx)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    require(VALID_COLLATERAL_BIT(idx), "UNSAFE: idx is a live slot of the narrowed collateral model");
    address ct = ghostMiOneCollateralToken[idx];
    require(ct != ghostMiOneMarketLoanToken, "UNSAFE: collateral token distinct from loan token (aliased case covered by HL-MI-12)");

    mathint surplusBefore = ghostERC20Balances128[ct][_Midnight]
        - (ghostMiOnePositionCollateral128[ghostMiPositionUserOne][idx]
           + ghostMiOnePositionCollateral128[ghostMiPositionUserTwo][idx]
           + ghostMiOnePositionCollateral128[ghostMiPositionUserThree][idx]);

    f(e, args);

    mathint surplusAfter = ghostERC20Balances128[ct][_Midnight]
        - (ghostMiOnePositionCollateral128[ghostMiPositionUserOne][idx]
           + ghostMiOnePositionCollateral128[ghostMiPositionUserTwo][idx]
           + ghostMiOnePositionCollateral128[ghostMiPositionUserThree][idx]);

    assert(surplusAfter >= surplusBefore,
        "collateralToken surplus (balance - Σ collateral[idx]) must never decrease (no leak)");
}

// HL-MI-14 (BH-2, Pattern 1, bug-hunting): the read-only position preview tells the truth — the
// credit, pending fee, and accrued fee that updatePositionView predicts exactly match what a real
// settlement (updatePosition) writes to storage and returns; the protocol's continuous-fee credit
// (cfc — fee units accrued to the protocol, claimable by the fee claimer) grows by exactly the
// previewed accrued fee (no fee-pot minting); and the position's bookkeeping stamps are refreshed
// to the current time and the market's current bad-debt socialization factor (lossFactor).
// FORMULA: credit[u]' == viewCredit AND pendingFee[u]' == viewPendingFee
//          AND continuousFeeCredit' == continuousFeeCredit + viewAccrued
//          AND lastAccrual[u]' == block.timestamp AND lastLossFactor[u]' == lossFactor
//          AND updatePosition returns (viewCredit, viewPendingFee, viewAccrued)
rule updatePositionViewMatchesState(env e, MidnightHarness.Market market, address user) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");
    bytes32 id = toId(e, market);

    uint128 viewCredit;
    uint128 viewPendingFee;
    uint128 viewAccrued;
    viewCredit, viewPendingFee, viewAccrued = updatePositionView(e, market, id, user);

    mathint cfcBefore = ghostMiOneMarketContinuousFeeCredit128;

    uint128 retCredit;
    uint128 retPendingFee;
    uint128 retAccrued;
    retCredit, retPendingFee, retAccrued = updatePosition(e, market, user);

    assert(ghostMiOnePositionCredit128[user] == to_mathint(viewCredit)
        && ghostMiOnePositionPendingFee128[user] == to_mathint(viewPendingFee),
        "updatePositionView's preview must equal the state updatePosition actually writes");
    assert(ghostMiOneMarketContinuousFeeCredit128 == cfcBefore + viewAccrued,
        "updatePosition credits the fee pot by exactly the previewed accruedFee (no cfc minting)");
    assert(ghostMiOnePositionLastAccrual128[user] == to_mathint(e.block.timestamp)
        && ghostMiOnePositionLastLossFactor128[user] == ghostMiOneMarketLossFactor128,
        "updatePosition stamps lastAccrual := now and lastLossFactor := marketState.lossFactor");
    assert(retCredit == viewCredit && retPendingFee == viewPendingFee && retAccrued == viewAccrued,
        "updatePosition's return triple equals the view preview");
}

// HL-MI-15 (BH-3, Pattern 7, bug-hunting): a liquidator's bonus is capped — the oracle value of
// the collateral seized never exceeds the debt repaid times the liquidation incentive factor
// (lif), the WAD-scaled collateral bonus multiplier that ramps from 1.0 at maturity up to maxLif
// over 60 minutes (3600 s). In post-maturity mode the bound uses the actual time-ramped lif, so a
// liquidator just past maturity cannot collect the full maxLif bonus at the borrower's expense;
// the value seized never exceeds repaid * maxLif in any mode.
// FORMULA: seized * price * WAD <= repaid * lif * ORACLE_PRICE_SCALE
//          where lif = postMaturityMode
//                      ? min(maxLif, WAD + floor((maxLif - WAD) * max(0, now - maturity) / 3600))
//                      : maxLif
//          AND seized * price * WAD <= repaid * maxLif * ORACLE_PRICE_SCALE
rule liquidateRespectsLifSeizureBound(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssetsIn,
    uint256 repaidUnitsIn, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");

    mathint price  = ghostMiOraclePrice256[market.collateralParams[collateralIndex].oracle];
    mathint maxLif = maxLifCVL(market.collateralParams[collateralIndex].lltv, market.collateralParams[collateralIndex].liquidationCursor);

    uint256 seized;
    uint256 repaid;
    seized, repaid = liquidate(e, market, collateralIndex, seizedAssetsIn, repaidUnitsIn, borrower,
        postMaturityMode, receiver, callback, data);

    // Mirrors src/Midnight.sol L645-647; every successful postMaturityMode path has ts > maturity
    // (NotLiquidatable gate), so the zero-floor only guards infeasible-path arithmetic.
    mathint elapsed = to_mathint(e.block.timestamp) > to_mathint(market.maturity)
        ? e.block.timestamp - market.maturity : 0;
    mathint ramped  = WAD_CVL() + (maxLif - WAD_CVL()) * elapsed / 3600; // TIME_TO_MAX_LIF = 60 min
    mathint lifBound = postMaturityMode ? (ramped < maxLif ? ramped : maxLif) : maxLif;

    assert(seized * price * WAD_CVL() <= repaid * lifBound * ORACLE_PRICE_SCALE_CVL(),
        "liquidate must not seize collateral value beyond repaidUnits * lif (time-ramped post-maturity)");
    assert(seized * price * WAD_CVL() <= repaid * maxLif * ORACLE_PRICE_SCALE_CVL(),
        "fallback: seizure value never exceeds repaidUnits * maxLif");
}

// HL-MI-16 (BH-4a, Pattern 10/access, bug-hunting): only the position owner, or someone the owner
// delegated to before the call, can withdraw a lender's funds — any successful withdraw implies
// the caller already was the onBehalf account or held its authorization at entry.
// FORMULA: withdraw(onBehalf) succeeds
//          => e.msg.sender == onBehalf OR isAuthorized[onBehalf][e.msg.sender]  (pre-state)
rule withdrawRequiresAuthorization(env e, MidnightHarness.Market market, uint256 units, address onBehalf, address receiver) {
    setupValidStateOneMidnight(e);
    bool authBefore = e.msg.sender == onBehalf || ghostMiIsAuthorized[onBehalf][e.msg.sender];
    withdraw(e, market, units, onBehalf, receiver);
    assert(authBefore,
        "a successful withdraw implies the caller was onBehalf or pre-authorized by onBehalf");
}

// HL-MI-17 (BH-4b, Pattern 10/access, bug-hunting): only the position owner, or someone the owner
// delegated to before the call, can pull a borrower's collateral — any successful
// withdrawCollateral implies the caller already was the onBehalf account or held its authorization
// at entry.
// FORMULA: withdrawCollateral(onBehalf) succeeds
//          => e.msg.sender == onBehalf OR isAuthorized[onBehalf][e.msg.sender]  (pre-state)
rule withdrawCollateralRequiresAuthorization(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 assets, address onBehalf, address receiver
) {
    setupValidStateOneMidnight(e);
    bool authBefore = e.msg.sender == onBehalf || ghostMiIsAuthorized[onBehalf][e.msg.sender];
    withdrawCollateral(e, market, collateralIndex, assets, onBehalf, receiver);
    assert(authBefore,
        "a successful withdrawCollateral implies the caller was onBehalf or pre-authorized by onBehalf");
}

// HL-MI-18 (BH-5, Pattern 4, bug-hunting): socialized losses are never quietly reversed — the
// cumulative bad-debt socialization factor (lossFactor), which determines how much each lender
// position is slashed on its next touch, never decreases under any operation.
// FORMULA: forall f. lossFactor' >= lossFactor
rule lossFactorMonotonic(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    mathint lossFactorBefore = ghostMiOneMarketLossFactor128;
    f(e, args);
    assert(ghostMiOneMarketLossFactor128 >= lossFactorBefore,
        "marketState.lossFactor must never decrease");
}

// HL-MI-19 (BH-6, Pattern 7, bug-hunting): the lazy settlement of a lender position (the pending
// bad-debt slash plus fee accrual) can only take value from the lender, never create it — the
// credit a settlement would realize never exceeds the credit currently stored for the position.
// FORMULA: viewCredit <= credit[u]
//          where viewCredit = the credit the position's pending slash/accrual would realize
rule slashNeverMintsCredit(env e, MidnightHarness.Market market, address user) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");
    bytes32 id = toId(e, market);

    uint128 newCredit;
    uint128 newPendingFee;
    uint128 accrued;
    newCredit, newPendingFee, accrued = updatePositionView(e, market, id, user);

    assert(to_mathint(newCredit) <= ghostMiOnePositionCredit128[user],
        "the lazy slash/accrual must never increase a position's realized credit");
}

// HL-MI-20 (BH-7, Pattern 6, bug-hunting): a trade settles only between its two counterparties —
// the take() trade entry point (a buyer fills a maker's offer) leaves every stored field of any
// user who is neither the maker nor the taker untouched, including the bookkeeping stamps, the
// collateral bitmap, and that user's offer-fill counter.
// FORMULA: forall bystander not in {maker, taker}, i in {0, 1}.
//          credit[bystander]' == credit[bystander] AND debt[bystander]' == debt[bystander]
//          AND pendingFee[bystander]' == pendingFee[bystander]
//          AND lastLossFactor[bystander]' == lastLossFactor[bystander]
//          AND lastAccrual[bystander]' == lastAccrual[bystander]
//          AND collateralBitmap[bystander]' == collateralBitmap[bystander]
//          AND collateral[bystander][i]' == collateral[bystander][i]
//          AND consumed[bystander][offer.group]' == consumed[bystander][offer.group]
rule takeDoesNotTouchBystander(
    env e,
    MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData,
    address bystander
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(bystander), "UNSAFE: bystander in the narrowed three-user set");
    require(bystander != offer.maker && bystander != taker, "UNSAFE: bystander is not a take counterparty");

    mathint creditBefore     = ghostMiOnePositionCredit128[bystander];
    mathint debtBefore       = ghostMiOnePositionDebt128[bystander];
    mathint pendingFeeBefore = ghostMiOnePositionPendingFee128[bystander];
    mathint llfBefore        = ghostMiOnePositionLastLossFactor128[bystander];
    mathint lastAccrualBefore = ghostMiOnePositionLastAccrual128[bystander];
    mathint bitmapBefore     = ghostMiOnePositionCollateralBitmap128[bystander];
    mathint coll0Before      = ghostMiOnePositionCollateral128[bystander][0];
    mathint coll1Before      = ghostMiOnePositionCollateral128[bystander][1];
    mathint consumedBefore   = ghostMiConsumed256[bystander][offer.group];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostMiOnePositionCredit128[bystander] == creditBefore
        && ghostMiOnePositionDebt128[bystander] == debtBefore
        && ghostMiOnePositionPendingFee128[bystander] == pendingFeeBefore
        && ghostMiOnePositionLastLossFactor128[bystander] == llfBefore
        && ghostMiOnePositionLastAccrual128[bystander] == lastAccrualBefore
        && ghostMiOnePositionCollateralBitmap128[bystander] == bitmapBefore
        && ghostMiOnePositionCollateral128[bystander][0] == coll0Before
        && ghostMiOnePositionCollateral128[bystander][1] == coll1Before,
        "take must not change any position field of a user who is neither the maker nor the taker");
    assert(ghostMiConsumed256[bystander][offer.group] == consumedBefore,
        "take must not change a bystander's consumed counter");
}

// HL-MI-21 (BH-8, Pattern 7, bug-hunting): an offer can never be over-filled — the maker's
// cumulative fill counter (consumed) stays within the offer's cap, and advances by exactly the
// size of this fill: the capped-side assets for an assets-capped offer, the filled units for a
// units-capped one. A dropped or under-counted increment, which would allow unbounded aggregate
// over-fill or replay, refutes the exact-increment legs.
// FORMULA: (offer.maxAssets > 0 => consumed[maker][group]' <= offer.maxAssets)
//          AND (offer.maxAssets == 0 => consumed[maker][group]' <= offer.maxUnits)
//          AND (offer.maxAssets > 0 => consumed[maker][group]' == consumed[maker][group]
//               + (offer.buy ? buyerAssets : sellerAssets))
//          AND (offer.maxAssets == 0 => consumed[maker][group]' == consumed[maker][group] + units)
rule consumedBoundedByOfferMax(
    env e,
    MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(offer.maker), "UNSAFE: maker in the narrowed three-user set");
    require(VALID_POSITION_USER(taker), "UNSAFE: taker in the narrowed three-user set");

    mathint consumedBefore = ghostMiConsumed256[offer.maker][offer.group];

    uint256 buyerAssetsRet;
    uint256 sellerAssetsRet;
    buyerAssetsRet, sellerAssetsRet = take(e, offer, ratifierData, units, taker,
        receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    mathint consumedAfter = ghostMiConsumed256[offer.maker][offer.group];
    assert((offer.maxAssets > 0 => consumedAfter <= to_mathint(offer.maxAssets))
        && (offer.maxAssets == 0 => consumedAfter <= to_mathint(offer.maxUnits)),
        "consumed[maker][group] must never exceed the offer's maxAssets / maxUnits cap");
    assert(offer.maxAssets > 0 => consumedAfter == consumedBefore
            + (offer.buy ? to_mathint(buyerAssetsRet) : to_mathint(sellerAssetsRet)),
        "assets-capped offer: consumed advances by exactly the capped-side assets of this fill");
    assert(offer.maxAssets == 0 => consumedAfter == consumedBefore + to_mathint(units),
        "units-capped offer: consumed advances by exactly the filled units");
}

// HL-MI-22 (BH-11, Pattern 1, bug-hunting): the public view getters report the truth — credit,
// debt, totalUnits, and withdrawable each return exactly the underlying stored value, so
// off-chain integrations and on-chain callers see the real position and market state.
// FORMULA: credit(id, u) == credit[u] AND debt(id, u) == debt[u]
//          AND totalUnits(id) == totalUnits AND withdrawable(id) == withdrawable
rule gettersMatchStorage(env e, MidnightHarness.Market market, address user) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");
    bytes32 id = toId(e, market);

    assert(to_mathint(credit(e, id, user)) == ghostMiOnePositionCredit128[user]
        && to_mathint(debt(e, id, user)) == ghostMiOnePositionDebt128[user]
        && to_mathint(totalUnits(e, id)) == ghostMiOneMarketTotalUnits128
        && to_mathint(withdrawable(e, id)) == ghostMiOneMarketWithdrawable128,
        "credit/debt/totalUnits/withdrawable getters must equal the underlying storage");
}

//
// ============================================================================
// HL-MI-23..56: complex financial scenarios — slash/solvency mathematics, take
// microstructure, liquidation economics, fee accrual, and counterparty token routing.
// ============================================================================
//

definition LIQUIDATE_SELECTOR(method f) returns bool =
    f.selector == sig:MidnightHarness.liquidate(MidnightHarness.Market,uint256,uint256,uint256,address,bool,address,address,bytes).selector;

//
// Continuous-fee accrual & maturity (HL-MI-23..28)
//

// HL-MI-23: settling a lender position conserves value into the fee pot — the protocol's
// continuous-fee credit (cfc, fee units accrued to the protocol and claimable by the fee claimer)
// grows by exactly the accrued fee the settlement reports, and the pot never gains more than the
// lender's credit loses. When the lender has no pending bad-debt slash, the conservation is exact
// three ways: credit and the fee accrued but not yet collected (pendingFee) each drop by exactly
// the accrued fee, leaving the position's face value (credit - pendingFee) unchanged.
// FORMULA: continuousFeeCredit' == continuousFeeCredit + accruedFee
//          AND credit[u] - credit[u]' >= accruedFee
//          AND (lastLossFactor[u] == lossFactor AND lossFactor < max_uint128) =>
//              (credit[u] - credit[u]' == accruedFee
//               AND pendingFee[u] - pendingFee[u]' == accruedFee
//               AND credit[u] - pendingFee[u] == credit[u]' - pendingFee[u]')
//          where accruedFee is updatePosition's returned fee; in the third conjunct,
//                credit[u]' and pendingFee[u]' are updatePosition's returned values
rule accrualConservesCreditIntoFeePot(env e, MidnightHarness.Market market, address user) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");

    mathint creditBefore = ghostMiOnePositionCredit128[user];
    mathint pfBefore     = ghostMiOnePositionPendingFee128[user];
    mathint cfcBefore    = ghostMiOneMarketContinuousFeeCredit128;
    bool noSlash = ghostMiOnePositionLastLossFactor128[user] == ghostMiOneMarketLossFactor128
        && ghostMiOneMarketLossFactor128 < max_uint128;

    uint128 c; uint128 p; uint128 f;
    c, p, f = updatePosition(e, market, user);

    assert(ghostMiOneMarketContinuousFeeCredit128 == cfcBefore + f,
        "updatePosition: cfc += accruedFee exactly (no fee-pot minting)");
    assert(creditBefore - ghostMiOnePositionCredit128[user] >= to_mathint(f),
        "updatePosition: the fee pot never gains more than the lender's credit loses");
    assert(noSlash => (creditBefore - to_mathint(c) == to_mathint(f)
        && pfBefore - to_mathint(p) == to_mathint(f)
        && creditBefore - pfBefore == to_mathint(c) - to_mathint(p)),
        "no-slash accrual: exact 3-way conservation; face value credit - pendingFee is invariant");
}

// HL-MI-24: when a buyer gains credit through the take() trade entry point (a buyer fills a
// maker's offer), the up-front fee charge is exactly linear in the minted credit and the time to
// maturity, and never exceeds the credit minted — so neither fee evasion by splitting a take into
// pieces nor inflation of the pre-charge is possible. Deltas are measured against the position
// after its pending slash/accrual settles; maturity is assumed within the protocol's 100-year cap.
// FORMULA: pendingFee[buyer]' - viewPendingFee
//              == floor((credit[buyer]' - viewCredit) * continuousFee * ttm / WAD)
//          AND pendingFee[buyer]' - viewPendingFee <= credit[buyer]' - viewCredit
//          where ttm = max(0, maturity - now);
//                (viewCredit, viewPendingFee) = the buyer's position after its pending
//                slash/accrual settles
rule takeBuyerFeePreChargeExactAndBounded(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units,
    address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    address buyer = offer.buy ? offer.maker : taker;
    require(VALID_POSITION_USER(buyer), "UNSAFE: buyer in the narrowed three-user set");
    require(to_mathint(offer.market.maturity) <= e.block.timestamp + 3153600000,
        "TRUSTED: mirrors touchMarket's 100-year maturity cap (src L758), not re-checkable post-creation in the touched-market summary");
    bytes32 id = toId(e, offer.market);

    mathint cf  = ghostMiOneMarketContinuousFee32; // <= MAX_CONTINUOUS_FEE via VS-MI-10
    mathint ttm = to_mathint(offer.market.maturity) > e.block.timestamp
        ? offer.market.maturity - e.block.timestamp : 0;

    uint128 vc; uint128 vp; uint128 vf;
    vc, vp, vf = updatePositionView(e, offer.market, id, buyer);

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    mathint bci   = ghostMiOnePositionCredit128[buyer] - vc;
    mathint pfInc = ghostMiOnePositionPendingFee128[buyer] - vp;
    assert(pfInc == (bci * (cf * ttm)) / WAD_CVL(),
        "take: buyer pre-charge == floor(creditIncrease * continuousFee * ttm / WAD) (src L385-386)");
    assert(pfInc <= bci,
        "take: minted pendingFee never exceeds minted credit (VS-MI-01 take-path lemma)");
}


// HL-MI-25: when a seller's credit is consumed through the take() trade entry point (a buyer fills
// a maker's offer), the seller's fee accrued but not yet collected (pendingFee) burns exactly in
// proportion to the credit consumed, rounded up against the seller — selling credit cannot shed a
// smaller share of the pending fee than of the credit.
// FORMULA: viewCredit > 0 =>
//          pendingFee[seller]' == viewPendingFee
//              - ceil(viewPendingFee * (viewCredit - credit[seller]') / viewCredit)
//          where (viewCredit, viewPendingFee) = the seller's position after its pending
//          slash/accrual settles
rule takeSellerBurnsPendingFeeProportionally(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units,
    address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    address seller = offer.buy ? taker : offer.maker;
    require(VALID_POSITION_USER(seller), "UNSAFE: seller in the narrowed three-user set");
    bytes32 id = toId(e, offer.market);

    uint128 vc; uint128 vp; uint128 vf;
    vc, vp, vf = updatePositionView(e, offer.market, id, seller); // post-slash/accrual pre-image

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    mathint scd = to_mathint(vc) - ghostMiOnePositionCredit128[seller]; // sellerCreditDecrease
    assert(vc > 0 => ghostMiOnePositionPendingFee128[seller]
        == to_mathint(vp) - (to_mathint(vp) * scd + to_mathint(vc) - 1) / to_mathint(vc),
        "take: seller pendingFee burns exactly ceil-proportionally to the credit consumed");
}

// HL-MI-26: settling the same lender position twice at one timestamp charges nothing twice — the
// second updatePosition in the same block reports zero accrued fee and leaves the lender's credit,
// pending fee, and the protocol's continuous-fee credit (cfc) pot exactly where the first call put
// them: no double accrual, no double slash, no fee-pot drift.
// FORMULA: after updatePosition(u), a second updatePosition(u) at the same timestamp satisfies
//          accruedFee == 0 AND credit[u]' == credit[u] AND pendingFee[u]' == pendingFee[u]
//          AND continuousFeeCredit' == continuousFeeCredit
//          (accruedFee is the second call's returned fee; primes are pre/post the second call)
rule updatePositionIdempotentSameBlock(env e, MidnightHarness.Market market, address user) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");

    updatePosition(e, market, user);

    mathint creditMid = ghostMiOnePositionCredit128[user];
    mathint pfMid     = ghostMiOnePositionPendingFee128[user];
    mathint cfcMid    = ghostMiOneMarketContinuousFeeCredit128;

    uint128 c2; uint128 p2; uint128 f2;
    c2, p2, f2 = updatePosition(e, market, user);

    assert(to_mathint(f2) == 0
        && ghostMiOnePositionCredit128[user] == creditMid
        && ghostMiOnePositionPendingFee128[user] == pfMid
        && ghostMiOneMarketContinuousFeeCredit128 == cfcMid,
        "second same-timestamp updatePosition is a no-op: no double accrual/slash, no cfc drift");
}

// HL-MI-27: with no pending bad-debt slash, the continuous fee accrues exactly linearly in time —
// a settlement collects the lender's fee accrued but not yet collected (pendingFee) scaled by the
// fraction of the time between the last settlement and maturity that has since elapsed. Nothing
// accrues once the position is stamped at or after maturity, and a settlement at or after maturity
// collects the entire remaining pendingFee.
// FORMULA: lastAccrual[u] < maturity =>
//              accruedFee == floor(pendingFee[u] * (min(now, maturity) - lastAccrual[u])
//                                  / (maturity - lastAccrual[u]))
//          AND lastAccrual[u] >= maturity => accruedFee == 0
//          AND (now >= maturity AND lastAccrual[u] < maturity) => pendingFee[u]' == 0
rule accrualLinearInTimeWithMaturityCutoff(env e, MidnightHarness.Market market, address user) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");
    require(ghostMiOnePositionLastLossFactor128[user] == ghostMiOneMarketLossFactor128
        && ghostMiOneMarketLossFactor128 < max_uint128,
        "isolate pure accrual (no slash term; slash exactness covered by HL-MI-38/39)");

    mathint pf = ghostMiOnePositionPendingFee128[user];
    mathint A  = ghostMiOnePositionLastAccrual128[user];
    mathint M  = market.maturity;
    mathint t  = e.block.timestamp;
    mathint accEnd = t < M ? t : M;

    uint128 c; uint128 p; uint128 f;
    c, p, f = updatePosition(e, market, user);

    assert(A < M  => to_mathint(f) == (pf * (accEnd - A)) / (M - A),
        "accruedFee follows the exact linear interpolation (src L814-816)");
    assert(A >= M => to_mathint(f) == 0,
        "no further accrual once stamped at/after maturity");
    assert(t >= M && A < M => ghostMiOnePositionPendingFee128[user] == 0,
        "an at/after-maturity accrual collects exactly the full remaining pendingFee");
}

// HL-MI-28: viewed at two moments over the same stored state (t1 <= t2), a lender position's fee
// surface only moves one way — the accrued fee grows with time and the realizable credit never
// grows by waiting; once maturity has passed the surface is frozen entirely; and by maturity the
// full fee accrued but not yet collected (pendingFee) has converted into collectable fee.
// FORMULA: t1 <= t2 =>
//          (accruedFee(t2) >= accruedFee(t1) AND viewCredit(t2) <= viewCredit(t1)
//           AND (t1 >= maturity => (viewCredit, viewPendingFee, accruedFee)(t1)
//                                  == (viewCredit, viewPendingFee, accruedFee)(t2))
//           AND (t2 >= maturity AND lastAccrual[u] < maturity => viewPendingFee(t2) == 0))
rule feeAccrualMonotoneAndFrozenAfterMaturity(env e1, env e2, MidnightHarness.Market market, address user) {
    setupValidStateOneMidnight(e1);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");
    require(e2.block.timestamp >= e1.block.timestamp
        && to_mathint(e2.block.timestamp) < MAX_BLOCK_TIMESTAMP(),
        "SAFE: time flows forward, bounded");
    bytes32 id = toId(e1, market);

    uint128 c1; uint128 p1; uint128 f1;
    uint128 c2; uint128 p2; uint128 f2;
    c1, p1, f1 = updatePositionView(e1, market, id, user);
    c2, p2, f2 = updatePositionView(e2, market, id, user); // same storage, later time

    assert(to_mathint(f2) >= to_mathint(f1) && to_mathint(c2) <= to_mathint(c1),
        "accrued fee is monotone in time; realizable credit never grows by waiting");
    assert(to_mathint(e1.block.timestamp) >= to_mathint(market.maturity)
        => (c1 == c2 && p1 == p2 && f1 == f2),
        "post-maturity the position surface is frozen");
    assert(to_mathint(e2.block.timestamp) >= to_mathint(market.maturity)
        && ghostMiOnePositionLastAccrual128[user] < to_mathint(market.maturity)
        => to_mathint(p2) == 0,
        "by maturity the full pendingFee has converted to fee");
}

//
// Liquidation economics (HL-MI-29..36)
//

// HL-MI-29: a borrower who is still solvent can never be liquidated — a normal-mode liquidation
// only succeeds against a borrower whose collateral no longer covered their debt under the
// loan-to-liquidation-value threshold (lltv) at entry, and the post-maturity liquidation mode is
// only available strictly after the market's maturity.
// FORMULA: liquidate(postMaturityMode == false) succeeds => NOT isHealthy(market, borrower)  (pre-state)
//          AND liquidate(postMaturityMode == true) succeeds => block.timestamp > maturity
rule liquidateOnlyWhenUnhealthyOrPastMaturity(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    bytes32 id = toId(e, market);

    bool healthyBefore = isHealthy(e, market, id, borrower); // PRE-state, same market arg as the call

    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);

    assert(!postMaturityMode => !healthyBefore,
        "normal-mode liquidate only succeeds against a pre-state-unhealthy borrower (NotLiquidatable, src L620-624)");
    assert(postMaturityMode => to_mathint(e.block.timestamp) > to_mathint(market.maturity),
        "post-maturity mode only succeeds strictly after maturity");
}

// HL-MI-30: lenders are slashed by exactly the share of value that bad debt destroys — when a
// liquidation writes off bad debt, the cumulative bad-debt socialization factor (lossFactor)
// advances by precisely the formula matching the fraction of the market's total loan units
// (totalUnits) wiped out, and it does not move at all when no bad debt is realized.
// FORMULA: totalUnits' == totalUnits => lossFactor' == lossFactor
//          AND totalUnits' < totalUnits =>
//              lossFactor' == max_uint128 - floor((max_uint128 - lossFactor) * totalUnits' / totalUnits)
rule lossFactorUpdateExact(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");

    mathint lfB = ghostMiOneMarketLossFactor128;
    mathint tuB = ghostMiOneMarketTotalUnits128;

    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);

    mathint lfA = ghostMiOneMarketLossFactor128;
    mathint tuA = ghostMiOneMarketTotalUnits128;

    assert(tuA == tuB => lfA == lfB,
        "no bad debt realised => lossFactor unchanged");
    assert(tuA < tuB => lfA == max_uint128
        - to_mathint(mulDivDownCVL(require_uint256(max_uint128 - lfB), require_uint256(tuA), require_uint256(tuB))),
        "lossFactor' == max - floor((max - lossFactor) * (TU - badDebt) / TU) exactly (src L631-633)");
}

// HL-MI-31: the protocol shares every socialized loss with the lenders — on a bad-debt write-off,
// the continuous-fee credit (cfc, fee units accrued to the protocol and claimable by the fee
// claimer) is haircut by exactly the same slash factor lender positions bear, so the fee claimer
// can neither dodge nor over-pay the loss; with no bad debt the pot is untouched by liquidate.
// FORMULA: totalUnits' == totalUnits => continuousFeeCredit' == continuousFeeCredit
//          AND (totalUnits' < totalUnits AND lossFactor < max_uint128) =>
//              continuousFeeCredit' == floor(continuousFeeCredit * (max_uint128 - lossFactor')
//                                            / (max_uint128 - lossFactor))
//          AND (totalUnits' < totalUnits AND lossFactor == max_uint128) => continuousFeeCredit' == 0
rule cfcRescaleExact(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");

    mathint lfB  = ghostMiOneMarketLossFactor128;
    mathint cfcB = ghostMiOneMarketContinuousFeeCredit128;
    mathint tuB  = ghostMiOneMarketTotalUnits128;

    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);

    mathint lfA  = ghostMiOneMarketLossFactor128;
    mathint cfcA = ghostMiOneMarketContinuousFeeCredit128;
    mathint tuA  = ghostMiOneMarketTotalUnits128;

    assert(tuA == tuB => cfcA == cfcB,
        "no bad debt realised => continuousFeeCredit unchanged");
    assert((tuA < tuB && lfB < max_uint128) => cfcA == to_mathint(
        mulDivDownCVL(require_uint256(cfcB), require_uint256(max_uint128 - lfA), require_uint256(max_uint128 - lfB))),
        "cfc' == floor(cfc * (2^128-1 - lossFactor') / (2^128-1 - lossFactor)) — the fee claimer shares the loss exactly (src L635-640)");
    assert((tuA < tuB && lfB == max_uint128) => cfcA == 0,
        "saturated lossFactor: a bad-debt realisation zeroes the fee pot (src L640)");
}

// HL-MI-32: liquidation's money legs are exact on the protocol's books — the loan tokens the
// liquidator repays land one-for-one in the loan tokens available for withdrawal from the market
// (withdrawable) and in the protocol's loan-token balance, while exactly the seized amount of
// collateral leaves both the protocol's collateral-token balance and the borrower's recorded
// collateral slot. Checked with the collateral token distinct from the loan token and neither
// the receiver nor the payer being the protocol itself.
// FORMULA: withdrawable' == withdrawable + repaid
//          AND balance[loanToken][Midnight]' == balance[loanToken][Midnight] + repaid
//          AND balance[collateralToken[i]][Midnight]' == balance[collateralToken[i]][Midnight] - seized
//          AND collateral[borrower][i]' == collateral[borrower][i] - seized
//          where (seized, repaid) = liquidate's returned amounts
rule liquidateLoanInCollateralOutExact(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssetsIn,
    uint256 repaidUnitsIn, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    address loanToken = ghostMiOneMarketLoanToken;
    address ct = ghostMiOneCollateralToken[collateralIndex];
    require(ct != loanToken, "UNSAFE: collateral token distinct from loan token (aliased flows confound the legs)");
    require(receiver != _Midnight && callback != _Midnight, "SAFE: receiver/payer are not Midnight");

    mathint wBefore  = ghostMiOneMarketWithdrawable128;
    mathint blBefore = ghostERC20Balances128[loanToken][_Midnight];
    mathint bcBefore = ghostERC20Balances128[ct][_Midnight];
    mathint coBefore = ghostMiOnePositionCollateral128[borrower][collateralIndex];

    uint256 seized; uint256 repaid;
    seized, repaid = liquidate(e, market, collateralIndex, seizedAssetsIn, repaidUnitsIn, borrower,
        postMaturityMode, receiver, callback, data);

    assert(ghostMiOneMarketWithdrawable128 == wBefore + repaid
        && ghostERC20Balances128[loanToken][_Midnight] == blBefore + repaid
        && ghostERC20Balances128[ct][_Midnight] == bcBefore - seized
        && ghostMiOnePositionCollateral128[borrower][collateralIndex] == coBefore - seized,
        "liquidate: loanToken-in == repaid == withdrawable-rise; collateral-out == seized == slot-drop");
}

// HL-MI-33: lenders are only ever forced to absorb bad debt from a genuinely insolvent borrower —
// the cumulative bad-debt socialization factor (lossFactor) can only rise when even seizing all of
// the borrower's collateral at the maximum liquidation bonus would not cover their debt. Checked
// in a single-collateral configuration.
// FORMULA: lossFactor' > lossFactor =>
//          ceil(ceil(collateral[borrower][0] * price / ORACLE_PRICE_SCALE) * WAD / maxLif)
//              < debt[borrower]   (pre-state)
rule lossFactorRiseImpliesUndercollateralizedAtMaxLif(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(ghostNumCollaterals == 1, "UNSAFE: single-collateral narrowing (worst case = slot 0)");
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");

    mathint lfBefore   = ghostMiOneMarketLossFactor128;
    mathint debtBefore = ghostMiOnePositionDebt128[borrower];
    mathint coll       = ghostMiOnePositionCollateral128[borrower][0];
    mathint price      = ghostMiOraclePrice256[market.collateralParams[0].oracle];
    mathint maxLif     = maxLifCVL(market.collateralParams[0].lltv, market.collateralParams[0].liquidationCursor);
    mathint worstCase  = to_mathint(mulDivUpCVL(
        mulDivUpCVL(require_uint256(coll), require_uint256(price), require_uint256(ORACLE_PRICE_SCALE_CVL())),
        require_uint256(WAD_CVL()), require_uint256(maxLif)));

    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);

    assert(ghostMiOneMarketLossFactor128 > lfBefore => worstCase < debtBefore,
        "a lossFactor rise requires the borrower's maxLif worst-case collateral value below its debt (src L605-618)");
}

// HL-MI-34: liquidating one borrower never touches anyone else's stored position — other lenders
// and borrowers absorb the socialized loss only lazily, through the market-level cumulative
// bad-debt socialization factor (lossFactor), when their own position is next settled.
// FORMULA: forall bystander != borrower.
//          credit[bystander]' == credit[bystander] AND debt[bystander]' == debt[bystander]
//          AND pendingFee[bystander]' == pendingFee[bystander]
//          AND lastAccrual[bystander]' == lastAccrual[bystander]
//          AND lastLossFactor[bystander]' == lastLossFactor[bystander]
//          AND collateralBitmap[bystander]' == collateralBitmap[bystander]
//          AND collateral[bystander][i]' == collateral[bystander][i]
rule liquidateDoesNotTouchBystander(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data,
    address bystander
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(VALID_POSITION_USER(bystander), "UNSAFE: bystander in the narrowed three-user set");
    require(bystander != borrower, "bystander is not the liquidated borrower");

    mathint creditBefore         = ghostMiOnePositionCredit128[bystander];
    mathint debtBefore           = ghostMiOnePositionDebt128[bystander];
    mathint pendingFeeBefore     = ghostMiOnePositionPendingFee128[bystander];
    mathint lastAccrualBefore    = ghostMiOnePositionLastAccrual128[bystander];
    mathint lastLossFactorBefore = ghostMiOnePositionLastLossFactor128[bystander];
    mathint bitmapBefore         = ghostMiOnePositionCollateralBitmap128[bystander];
    mathint coll0Before          = ghostMiOnePositionCollateral128[bystander][0];
    mathint coll1Before          = ghostMiOnePositionCollateral128[bystander][1];

    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);

    assert(ghostMiOnePositionCredit128[bystander] == creditBefore
        && ghostMiOnePositionDebt128[bystander] == debtBefore
        && ghostMiOnePositionPendingFee128[bystander] == pendingFeeBefore
        && ghostMiOnePositionLastAccrual128[bystander] == lastAccrualBefore
        && ghostMiOnePositionLastLossFactor128[bystander] == lastLossFactorBefore
        && ghostMiOnePositionCollateralBitmap128[bystander] == bitmapBefore
        && ghostMiOnePositionCollateral128[bystander][0] == coll0Before
        && ghostMiOnePositionCollateral128[bystander][1] == coll1Before,
        "liquidate must not mutate any stored field of a non-borrower position (slash is lazy via lossFactor only)");
}

// HL-MI-35 (HYP-07 / HL-CAND-14): a normal-mode liquidation is capped — the liquidator may not
// repay more than what restores the borrower to health (the recovery close factor, or RCF) —
// except through the documented dust escape: whenever the repayment exceeds the cap, the
// collateral value that would remain above the cap must be below the market's dust threshold, so
// a liquidator can never over-liquidate a borrower with non-dust collateral left. Checked on the
// repaid-input path with a single collateral and lltv below WAD (where the cap is finite).
// FORMULA: repaid > maxRepaid => max(0, dustValue - maxRepaid) < rcfThreshold
//          where collValue = floor(collateral[borrower][0] * price / ORACLE_PRICE_SCALE);
//                maxDebt   = floor(collValue * lltv / WAD);
//                dustValue = floor(collValue * WAD / maxLif);
//                maxRepaid = ceil((debt[borrower] - maxDebt) * WAD^2 / (WAD^2 - maxLif * lltv))   (pre-state)
rule rcfDustEscapeRequiresDustCollateral(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 repaidUnitsIn, address borrower,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(ghostNumCollaterals == 1 && collateralIndex == 0, "UNSAFE: single-collateral model; liquidated slot = 0");
    require(market.collateralParams.length == 1, "align struct arg with the one-collateral narrowing");
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(callback == 0 && data.length == 0, "trim callback paths (stub is stateless anyway)");

    mathint lltv   = market.collateralParams[0].lltv;
    mathint maxLif = maxLifCVL(market.collateralParams[0].lltv, market.collateralParams[0].liquidationCursor);
    require(lltv < WAD_CVL(), "RCF cap is finite only for lltv < WAD (src L659-661)");

    mathint price   = ghostMiOraclePrice256[market.collateralParams[0].oracle];
    mathint collPre = ghostMiOnePositionCollateral128[borrower][0];
    mathint debtPre = ghostMiOnePositionDebt128[borrower];

    // Term-match the code's collateral-value legs (L613 maxDebt, L664-665 dust value; lif == maxLif in normal mode).
    uint256 collValue = mulDivDownCVL(require_uint256(collPre), require_uint256(price),
        require_uint256(ORACLE_PRICE_SCALE_CVL()));
    mathint maxDebt = to_mathint(mulDivDownCVL(collValue, require_uint256(lltv), require_uint256(WAD_CVL())));
    mathint dustVal = to_mathint(mulDivDownCVL(collValue, require_uint256(WAD_CVL()), require_uint256(maxLif)));

    uint256 seized;
    uint256 repaid;
    // repaid-input path only (seizedAssets = 0): returned repaid == input, no seize-side rounding.
    seized, repaid = liquidate(e, market, collateralIndex, 0, repaidUnitsIn, borrower, false, receiver, callback, data);

    // Success in normal mode implies debtPre > maxDebt (NotLiquidatable), so the subtraction is
    // safe; WAD^2 - maxLif*lltv > 0 since lltv*maxLif <= 0.999e18*WAD when lltv < WAD (MaxLifTooHigh gate).
    mathint maxRepaid = to_mathint(mulDivUpCVL(require_uint256(debtPre - maxDebt),
        require_uint256(WAD_CVL() * WAD_CVL()),
        require_uint256(WAD_CVL() * WAD_CVL() - maxLif * lltv)));

    assert(to_mathint(repaid) > maxRepaid
            => (dustVal > maxRepaid ? dustVal - maxRepaid : 0) < to_mathint(market.rcfThreshold),
        "an over-RCF normal-mode liquidation must only be possible via the dust-threshold escape");
}

// HL-MI-35b (satisfy): the dust escape is a real code path — there exists a successful
// normal-mode liquidation whose repayment exceeds the recovery-close-factor cap.
// FORMULA: satisfy: exists execution of liquidate. repaid > maxRepaid
//          where maxRepaid = ceil((debt[borrower] - maxDebt) * WAD^2 / (WAD^2 - maxLif * lltv));
//                maxDebt   = floor(floor(collateral[borrower][0] * price / ORACLE_PRICE_SCALE)
//                                  * lltv / WAD)   (pre-state)
rule rcfDustEscapeReachable(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 repaidUnitsIn, address borrower,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(ghostNumCollaterals == 1 && collateralIndex == 0, "UNSAFE: single-collateral model; liquidated slot = 0");
    require(market.collateralParams.length == 1, "align struct arg with the one-collateral narrowing");
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(callback == 0 && data.length == 0, "trim callback paths");

    mathint lltv   = market.collateralParams[0].lltv;
    mathint maxLif = maxLifCVL(market.collateralParams[0].lltv, market.collateralParams[0].liquidationCursor);
    require(lltv < WAD_CVL(), "RCF cap is finite only for lltv < WAD");

    mathint price   = ghostMiOraclePrice256[market.collateralParams[0].oracle];
    mathint collPre = ghostMiOnePositionCollateral128[borrower][0];
    mathint debtPre = ghostMiOnePositionDebt128[borrower];

    uint256 collValue = mulDivDownCVL(require_uint256(collPre), require_uint256(price),
        require_uint256(ORACLE_PRICE_SCALE_CVL()));
    mathint maxDebt = to_mathint(mulDivDownCVL(collValue, require_uint256(lltv), require_uint256(WAD_CVL())));

    uint256 seized;
    uint256 repaid;
    seized, repaid = liquidate(e, market, collateralIndex, 0, repaidUnitsIn, borrower, false, receiver, callback, data);

    mathint maxRepaid = to_mathint(mulDivUpCVL(require_uint256(debtPre - maxDebt),
        require_uint256(WAD_CVL() * WAD_CVL()),
        require_uint256(WAD_CVL() * WAD_CVL() - maxLif * lltv)));

    satisfy(to_mathint(repaid) > maxRepaid);
}

// HL-MI-35c: the liquidation repayment cap stays sound when the borrower posts two collateral
// types — the cap counts the health value of BOTH collateral slots (so the second slot tightens,
// never widens, how much may be repaid), while the dust test that deactivates the recovery close
// factor (RCF) cap applies to the liquidated slot only; repaying beyond the cap is only possible
// when the liquidated slot's remaining value is dust. Checked on the normal-mode repaid-input
// path with lltv below WAD (where the cap is finite).
// FORMULA: repaid > maxRepaid => max(0, dustValue_idx - maxRepaid) < rcfThreshold
//          where maxDebt   = Σ_{i in {0,1}} floor(floor(collateral[borrower][i] * price_i
//                                / ORACLE_PRICE_SCALE) * lltv_i / WAD);
//                dustValue_idx = floor(floor(collateral[borrower][idx] * price_idx
//                                / ORACLE_PRICE_SCALE) * WAD / maxLif_idx);
//                maxRepaid = ceil((debt[borrower] - maxDebt) * WAD^2
//                                / (WAD^2 - maxLif_idx * lltv_idx))   (pre-state)
rule rcfDustEscapeTwoCollateral(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 repaidUnitsIn, address borrower,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(ghostNumCollaterals == 2, "UNSAFE: two-collateral model (single-slot case covered by HL-MI-35)");
    require(market.collateralParams.length == 2, "align struct arg with the two-collateral narrowing");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: liquidated slot within the narrowing");
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(callback == 0 && data.length == 0, "trim callback paths (stub is stateless anyway)");

    mathint lltv   = market.collateralParams[collateralIndex].lltv;
    mathint maxLif = maxLifCVL(market.collateralParams[collateralIndex].lltv, market.collateralParams[collateralIndex].liquidationCursor);
    require(lltv < WAD_CVL(), "RCF cap is finite only for lltv < WAD (src L659-661)");

    mathint price0   = ghostMiOraclePrice256[market.collateralParams[0].oracle];
    mathint price1   = ghostMiOraclePrice256[market.collateralParams[1].oracle];
    mathint coll0Pre = ghostMiOnePositionCollateral128[borrower][0];
    mathint coll1Pre = ghostMiOnePositionCollateral128[borrower][1];
    mathint debtPre  = ghostMiOnePositionDebt128[borrower];

    // Term-match the code's L613 maxDebt over BOTH slots: the loop visits set bits only, but an
    // unset bit holds a zero slot (VS-MI-04), so its floor term vanishes and the unconditional
    // two-term sum matches the loop.
    mathint maxDebt =
        to_mathint(mulDivDownCVL(
            mulDivDownCVL(require_uint256(coll0Pre), require_uint256(price0), require_uint256(ORACLE_PRICE_SCALE_CVL())),
            require_uint256(market.collateralParams[0].lltv), require_uint256(WAD_CVL())))
        + to_mathint(mulDivDownCVL(
            mulDivDownCVL(require_uint256(coll1Pre), require_uint256(price1), require_uint256(ORACLE_PRICE_SCALE_CVL())),
            require_uint256(market.collateralParams[1].lltv), require_uint256(WAD_CVL())));

    // Dust value of the LIQUIDATED slot only (src L664-665; lif == maxLif in normal mode).
    mathint priceIdx = collateralIndex == 0 ? price0 : price1;
    mathint collIdx  = collateralIndex == 0 ? coll0Pre : coll1Pre;
    mathint dustVal = to_mathint(mulDivDownCVL(
        mulDivDownCVL(require_uint256(collIdx), require_uint256(priceIdx), require_uint256(ORACLE_PRICE_SCALE_CVL())),
        require_uint256(WAD_CVL()), require_uint256(maxLif)));

    uint256 seized;
    uint256 repaid;
    // repaid-input path only (seizedAssets = 0): returned repaid == input, no seize-side rounding.
    seized, repaid = liquidate(e, market, collateralIndex, 0, repaidUnitsIn, borrower, false, receiver, callback, data);

    // Success in normal mode implies debtPre > maxDebt (NotLiquidatable), so the subtraction is
    // safe; WAD^2 - maxLif*lltv > 0 since lltv*maxLif <= 0.999e18*WAD when lltv < WAD (MaxLifTooHigh gate).
    mathint maxRepaid = to_mathint(mulDivUpCVL(require_uint256(debtPre - maxDebt),
        require_uint256(WAD_CVL() * WAD_CVL()),
        require_uint256(WAD_CVL() * WAD_CVL() - maxLif * lltv)));

    assert(to_mathint(repaid) > maxRepaid
            => (dustVal > maxRepaid ? dustVal - maxRepaid : 0) < to_mathint(market.rcfThreshold),
        "an over-RCF normal-mode liquidation with two collateral slots must only pass via the dust escape");
}

// HL-MI-36 (HYP-02): a market is only ever "bricked" — the cumulative bad-debt socialization
// factor (lossFactor) saturated at its maximum, after which trading halts and lender value is
// fully wiped — when the loss genuinely consumed the market: wiping all of the market's total
// loan units (totalUnits) forces the brick, and a fresh brick can only occur when the units that
// survive the write-off are below the slash's rounding dust.
// FORMULA: totalUnits' == 0 => lossFactor' == max_uint128
//          AND (lossFactor' == max_uint128 AND lossFactor < max_uint128) =>
//              (max_uint128 - lossFactor) * totalUnits' < totalUnits
rule lossFactorMaxOnlyWhenUnitsWiped(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");

    mathint lfBefore = ghostMiOneMarketLossFactor128;
    mathint tuBefore = ghostMiOneMarketTotalUnits128;

    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);

    mathint lfAfter = ghostMiOneMarketLossFactor128;
    mathint tuAfter = ghostMiOneMarketTotalUnits128;

    assert(tuAfter == 0 => lfAfter == max_uint128,
        "full unit wipe-out must coincide with lossFactor == max");
    assert((lfAfter == max_uint128 && lfBefore < max_uint128) =>
        (max_uint128 - lfBefore) * tuAfter < tuBefore,
        "premature brick: lossFactor maxed while more than dust-level units survive");
}

//
// Socialized-loss solvency & slash fairness (HL-MI-37..40)
//

// Realizable credit of u at the current lossFactor — mirrors updatePositionView's postSlashCredit
// (src L805-807, incl. the lastLossFactor == max ternary). mathint `/` is floor division.
function postSlashCreditCVL(address u) returns mathint {
    return ghostMiOnePositionLastLossFactor128[u] < max_uint128
        ? (ghostMiOnePositionCredit128[u] * (max_uint128 - ghostMiOneMarketLossFactor128))
            / (max_uint128 - ghostMiOnePositionLastLossFactor128[u])
        : 0;
}

function realizedLenderValuePlusFeePotCVL() returns mathint {
    return postSlashCreditCVL(ghostMiPositionUserOne)
        + postSlashCreditCVL(ghostMiPositionUserTwo)
        + postSlashCreditCVL(ghostMiPositionUserThree)
        + ghostMiOneMarketContinuousFeeCredit128;
}

// HL-MI-37 (bug-hunting): the market stays solvent even with socialized losses still unrealized —
// the credit every lender could still claim after their pending bad-debt slash, summed over the
// three modeled users, plus the protocol's continuous-fee credit (cfc), never grows past the
// market's total loan units (totalUnits) by more than one indivisible unit of rounding when the
// bound held before the operation.
// FORMULA: forall f. realizableValue <= totalUnits => realizableValue' <= totalUnits' + 1
//          where realizableValue = Σ_u postSlashCredit(u) + continuousFeeCredit;
//                postSlashCredit(u) = lastLossFactor[u] < max_uint128
//                    ? floor(credit[u] * (max_uint128 - lossFactor)
//                            / (max_uint128 - lastLossFactor[u]))
//                    : 0
rule postSlashSolvencyOneStep(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    require(realizedLenderValuePlusFeePotCVL() <= ghostMiOneMarketTotalUnits128,
        "UNSAFE-inductive: pre-state satisfies the post-slash solvency bound");

    f(e, args);

    assert(realizedLenderValuePlusFeePotCVL() <= ghostMiOneMarketTotalUnits128 + 1,
        "realizable lender value + fee pot must stay within totalUnits (mod 1-wei floor artifact)");
}

// HL-MI-37b: outside liquidation the solvency bound is exact — every entry point other than
// liquidate keeps the realizable lender value (summed over the three modeled users) plus the
// protocol's continuous-fee credit (cfc) within the market's total loan units (totalUnits) with
// no rounding tolerance at all.
// FORMULA: forall f != liquidate. realizableValue <= totalUnits => realizableValue' <= totalUnits'
//          where realizableValue = Σ_u postSlashCredit(u) + continuousFeeCredit
rule postSlashSolvencyPreservedExceptLiquidate(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) && !LIQUIDATE_SELECTOR(f) } {
    setupValidStateOneMidnight(e);
    require(realizedLenderValuePlusFeePotCVL() <= ghostMiOneMarketTotalUnits128,
        "UNSAFE-inductive: pre-state satisfies the post-slash solvency bound");

    f(e, args);

    assert(realizedLenderValuePlusFeePotCVL() <= ghostMiOneMarketTotalUnits128,
        "outside liquidate, realizable lender value + fee pot stays within totalUnits exactly");
}

// HL-MI-38 (bug-hunting): a bad-debt slash never shifts the burden toward the fee — settling a
// lender's position (applying the pending slash and fee accrual) never increases the ratio of the
// fee accrued but not yet collected (pendingFee) to credit, so a slashed lender is never left
// owing proportionally more fee on less credit.
// FORMULA: viewPendingFee * credit[u] <= pendingFee[u] * viewCredit
//          where (viewCredit, viewPendingFee) = the position after its pending slash/accrual settles
rule slashBurnsPendingFeeProportionally(env e, MidnightHarness.Market market, address user) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");
    bytes32 id = toId(e, market);

    mathint cB  = ghostMiOnePositionCredit128[user];
    mathint pfB = ghostMiOnePositionPendingFee128[user];

    uint128 nc; uint128 npf; uint128 acc;
    nc, npf, acc = updatePositionView(e, market, id, user);

    assert(to_mathint(npf) * cB <= pfB * to_mathint(nc),
        "slash/accrual must burn pendingFee at least proportionally to credit (no overcharge survives a slash)");
}

// HL-MI-39 (bug-hunting): a sleeping lender can never profit from someone else's loss event —
// across any operation that leaves the lender's own stored position untouched, the credit and the
// fee accrued but not yet collected (pendingFee) that the lender would realize on their next
// settlement never increase.
// FORMULA: forall f. f leaves u's stored position untouched =>
//          viewCredit' <= viewCredit AND viewPendingFee' <= viewPendingFee
//          where (viewCredit, viewPendingFee) = the position after its pending slash/accrual settles
rule idleLenderCreditNonIncreasing(env e, MidnightHarness.Market market, address user, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");
    bytes32 id = toId(e, market);

    // Snapshot the STORED position fields the view reads (do NOT reuse view outputs here).
    mathint creditStoreBefore     = ghostMiOnePositionCredit128[user];
    mathint pendingFeeStoreBefore = ghostMiOnePositionPendingFee128[user];
    mathint llfStoreBefore        = ghostMiOnePositionLastLossFactor128[user];
    mathint accrualStoreBefore    = ghostMiOnePositionLastAccrual128[user];

    uint128 cBefore; uint128 pfBefore; uint128 aBefore;
    cBefore, pfBefore, aBefore = updatePositionView(e, market, id, user);

    f(e, args);

    // Frame: f left this user's position untouched (idle lender slept through the drift).
    require(ghostMiOnePositionCredit128[user]         == creditStoreBefore
         && ghostMiOnePositionPendingFee128[user]     == pendingFeeStoreBefore
         && ghostMiOnePositionLastLossFactor128[user] == llfStoreBefore
         && ghostMiOnePositionLastAccrual128[user]    == accrualStoreBefore,
        "SAFE: idle lender — f did not touch user's position");

    uint128 cAfter; uint128 pfAfter; uint128 aAfter;
    cAfter, pfAfter, aAfter = updatePositionView(e, market, id, user);

    assert(to_mathint(cAfter) <= to_mathint(cBefore),
        "an idle lender's realizable credit must not rise as the market's lossFactor drifts up");
    assert(to_mathint(pfAfter) <= to_mathint(pfBefore),
        "an idle lender's realizable pendingFee must not rise as the market's lossFactor drifts up");
}

// HL-MI-40 (bug-hunting): a lender cannot dodge socialized losses by timing their
// interactions — starting from identical positions, a lender who settles between two bad-debt
// events (taking two compounded rounded slashes) never ends up with more credit than an identical
// lender who sleeps through both and is slashed once.
// FORMULA: credit[A] == credit[B] AND pendingFee[A] == pendingFee[B]
//          AND lastLossFactor[A] == lastLossFactor[B] AND lastAccrual[A] == lastAccrual[B] =>
//          after liquidate; updatePosition(A); liquidate; updatePosition(B); updatePosition(A):
//              credit[A]' <= credit[B]'
rule slashTimingFairness(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex,
    uint256 seized1, uint256 repaid1, uint256 seized2, uint256 repaid2,
    address borrower, bool postMaturityMode, address receiver, address callback, bytes data,
    address lenderA, address lenderB
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(lenderA) && VALID_POSITION_USER(lenderB) && lenderA != lenderB,
        "UNSAFE: two distinct lenders in the narrowed three-user set");
    require(VALID_POSITION_USER(borrower) && borrower != lenderA && borrower != lenderB,
        "UNSAFE: borrower distinct from the compared lenders");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    require(ghostMiOnePositionCredit128[lenderA] == ghostMiOnePositionCredit128[lenderB]
        && ghostMiOnePositionLastLossFactor128[lenderA] == ghostMiOnePositionLastLossFactor128[lenderB]
        && ghostMiOnePositionPendingFee128[lenderA] == ghostMiOnePositionPendingFee128[lenderB]
        && ghostMiOnePositionLastAccrual128[lenderA] == ghostMiOnePositionLastAccrual128[lenderB],
        "identical lender positions at the start");

    liquidate(e, market, collateralIndex, seized1, repaid1, borrower, postMaturityMode, receiver, callback, data);
    updatePosition(e, market, lenderA); // A realizes the intermediate slash
    liquidate(e, market, collateralIndex, seized2, repaid2, borrower, postMaturityMode, receiver, callback, data);
    updatePosition(e, market, lenderB); // B realizes both at once
    updatePosition(e, market, lenderA); // A realizes the second step

    assert(ghostMiOnePositionCredit128[lenderA] <= ghostMiOnePositionCredit128[lenderB],
        "an early-interacting lender never realizes more credit than one who waits (no slash-dodging by timing)");
}

//
// take microstructure (HL-MI-41..48)
//

// HL-MI-41: the matching engine neither mints nor destroys loan units — in the take() trade entry
// point (a buyer fills a maker's offer), the buyer's net position (credit minus debt) rises by
// exactly the filled units and the seller's falls by exactly the same, each measured against the
// position after its pending bad-debt slash and fee accrual settle.
// FORMULA: (credit[buyer]' - viewCredit_buyer) + (debt[buyer] - debt[buyer]') == units
//          AND (viewCredit_seller - credit[seller]') + (debt[seller]' - debt[seller]) == units
//          where viewCredit_* = each counterparty's credit after its pending slash/accrual settles
rule takeNettingUnitConservation(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units,
    address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(offer.maker) && VALID_POSITION_USER(taker),
        "UNSAFE: counterparties in the narrowed three-user set");
    bytes32 id = toId(e, offer.market);
    address buyer  = offer.buy ? offer.maker : taker;
    address seller = offer.buy ? taker : offer.maker;

    uint128 bC; uint128 bP; uint128 bA;
    bC, bP, bA = updatePositionView(e, offer.market, id, buyer);
    uint128 sC; uint128 sP; uint128 sA;
    sC, sP, sA = updatePositionView(e, offer.market, id, seller);
    mathint bD0 = ghostMiOnePositionDebt128[buyer];
    mathint sD0 = ghostMiOnePositionDebt128[seller];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert((ghostMiOnePositionCredit128[buyer] - to_mathint(bC)) + (bD0 - ghostMiOnePositionDebt128[buyer])
        == to_mathint(units),
        "buyer side: net (credit - debt) rises by exactly units");
    assert((to_mathint(sC) - ghostMiOnePositionCredit128[seller]) + (ghostMiOnePositionDebt128[seller] - sD0)
        == to_mathint(units),
        "seller side: net (credit - debt) falls by exactly units");
}

// HL-MI-42: the settlement fee the protocol captures on a trade matches its published fee
// schedule — the growth of the claimable settlement-fee pot equals the filled units times the
// market's time-interpolated settlement-fee rate, to within the tight rounding of the two
// pricing legs.
// FORMULA: levied - 1 <= claimableSettlementFee[loanToken]' - claimableSettlementFee[loanToken]
//              <= levied + 2
//          where levied = floor(units * settlementFee(id, max(0, maturity - now)) / WAD)
rule takeFeeIncidenceMatchesLeviedFee(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units,
    address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    bytes32 id = toId(e, offer.market);
    address loanToken = offer.market.loanToken;
    mathint ttm = to_mathint(offer.market.maturity) > to_mathint(e.block.timestamp)
        ? offer.market.maturity - e.block.timestamp : 0;
    uint256 sf = settlementFee(e, id, require_uint256(ttm));

    mathint claimableBefore = ghostMiClaimableSettlementFee256[loanToken];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    mathint spread = ghostMiClaimableSettlementFee256[loanToken] - claimableBefore;
    mathint levied = (to_mathint(units) * sf) / WAD_CVL();
    assert(spread >= levied - 1 && spread <= levied + 2,
        "captured settlement fee == units * settlementFee / WAD within [-1, +2] rounding");
}


// HL-MI-43 (recon INV-M37): a maker who flags an offer reduce-only can only have their exposure
// shrunk by fills — a reduce-only buy offer never grows the maker's credit and a reduce-only sell
// offer never grows the maker's debt, so a fill cannot push the maker into a larger position than
// they signed for.
// FORMULA: offer.reduceOnly AND offer.buy => credit[maker]' <= credit[maker]
//          AND offer.reduceOnly AND NOT offer.buy => debt[maker]' <= debt[maker]
rule reduceOnlyHonoredForMaker(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units,
    address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    require(offer.reduceOnly, "the rule targets reduceOnly offers");
    require(VALID_POSITION_USER(offer.maker), "UNSAFE: maker in the narrowed three-user set");

    mathint c0 = ghostMiOnePositionCredit128[offer.maker];
    mathint d0 = ghostMiOnePositionDebt128[offer.maker];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(offer.buy  => ghostMiOnePositionCredit128[offer.maker] <= c0,
        "reduceOnly buy offer: the maker's credit must not increase");
    assert(!offer.buy => ghostMiOnePositionDebt128[offer.maker] <= d0,
        "reduceOnly sell offer: the maker's debt must not increase");
}

// HL-MI-44: a fill only succeeds when the offer's integrity gates all held at entry — the maker
// had authorized the offer's ratifier (the maker's protection against forged offers), the offer's
// time window was open, the offer's price tick sat on the market's tick grid, and the market was
// not bricked by a saturated bad-debt socialization factor (lossFactor).
// FORMULA: take succeeds =>
//          isAuthorized[offer.maker][offer.ratifier]   (pre-state)
//          AND offer.start <= block.timestamp <= offer.expiry
//          AND tickSpacing > 0 AND offer.tick % tickSpacing == 0
//          AND lossFactor < max_uint128
rule takeHonorsOfferIntegrityGates(
    env e,
    MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);

    bool makerAuthorizedRatifier = ghostMiIsAuthorized[offer.maker][offer.ratifier]; // PRE-state
    mathint lfBefore      = ghostMiOneMarketLossFactor128;
    // per-id ghost: the Sload hook anchors only ghostMiMarketTickSpacing[id]; the
    // scalar one-mode mirror has no Sstore on take paths (touchMarket summarized)
    bytes32 preId = toId(e, offer.market);
    mathint spacingBefore = ghostMiMarketTickSpacing[preId];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(makerAuthorizedRatifier,
        "take: the maker had authorized the offer's ratifier at the pre-state (RatifierUnauthorized, src L355)");
    assert(offer.start <= e.block.timestamp && e.block.timestamp <= offer.expiry,
        "take: offer window open (OfferNotStarted/OfferExpired, src L352-353)");
    assert(spacingBefore > 0 && to_mathint(offer.tick) % spacingBefore == 0,
        "take: tick on the market grid (TickNotAccessible, src L351)");
    assert(lfBefore < max_uint128,
        "take: no trading in a bricked market (MarketLossFactorMaxedOut, src L349 / HYP-02)");
}

// HL-MI-45: a fill is priced exactly at the offer's tick with maker-favoring rounding — for a buy
// offer both money legs round down (the maker-buyer pays the floor price, the seller receives the
// floor of price minus fee), for a sell offer both round up (the maker-seller receives the
// ceiling price, the buyer pays the ceiling of price plus fee) — and the maker's cumulative fill
// counter advances by exactly the capped side of this fill.
// FORMULA: offer.buy => buyerAssets == floor(units * p / WAD)
//                       AND sellerAssets == floor(units * (p - sf) / WAD)
//          AND NOT offer.buy => sellerAssets == ceil(units * p / WAD)
//                       AND buyerAssets == ceil(units * (p + sf) / WAD)
//          AND consumed[maker][group]' == consumed[maker][group]
//              + (offer.maxAssets > 0 ? (offer.buy ? buyerAssets : sellerAssets) : units)
//          where p = tickPrice(offer.tick); sf = settlementFee(id, max(0, maturity - now))
rule takeFillAccountingExact(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units,
    address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    bytes32 id = toId(e, offer.market);
    mathint p = tickToPriceGhost(offer.tick); // the same uninterpreted price the code uses
    mathint ttm = to_mathint(offer.market.maturity) > to_mathint(e.block.timestamp)
        ? offer.market.maturity - e.block.timestamp : 0;
    mathint sf = settlementFee(e, id, require_uint256(ttm));
    mathint consumedBefore = ghostMiConsumed256[offer.maker][offer.group];

    uint256 buyerAssets; uint256 sellerAssets;
    buyerAssets, sellerAssets = take(e, offer, ratifierData, units, taker,
        receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(offer.buy => (to_mathint(buyerAssets) == (to_mathint(units) * p) / WAD_CVL()
        && to_mathint(sellerAssets) == (to_mathint(units) * (p - sf)) / WAD_CVL()),
        "buy offer: buyerAssets == floor(units*p/WAD), sellerAssets == floor(units*(p-sf)/WAD) (src L358-364)");
    assert(!offer.buy => (to_mathint(sellerAssets) == (to_mathint(units) * p + WAD_CVL() - 1) / WAD_CVL()
        && to_mathint(buyerAssets) == (to_mathint(units) * (p + sf) + WAD_CVL() - 1) / WAD_CVL()),
        "sell offer: sellerAssets == ceil(units*p/WAD), buyerAssets == ceil(units*(p+sf)/WAD) (src L358-364)");
    assert(ghostMiConsumed256[offer.maker][offer.group] == consumedBefore
        + (offer.maxAssets > 0 ? (offer.buy ? to_mathint(buyerAssets) : to_mathint(sellerAssets)) : to_mathint(units)),
        "consumed advances by exactly the capped-side fill (src L366-373)");
}

// HL-MI-46: a trade can never be charged more settlement fee than the protocol's hard cap — the
// spread captured into the claimable settlement-fee pot stays within the filled units times the
// maximum settlement-fee rate (0.5% of the 1e18 fixed-point scale, WAD), plus one wei of rounding.
// FORMULA: (claimableSettlementFee[loanToken]' - claimableSettlementFee[loanToken]) * WAD
//              <= units * MAX_SETTLEMENT_FEE_360_DAYS + WAD
//          where MAX_SETTLEMENT_FEE_360_DAYS == 0.005e18
rule takeSettlementSpreadCappedByProtocolMax(
    env e,
    MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);

    address loanToken = offer.market.loanToken;
    mathint claimableBefore = ghostMiClaimableSettlementFee256[loanToken];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    mathint spread = ghostMiClaimableSettlementFee256[loanToken] - claimableBefore;
    assert(spread * WAD_CVL() <= to_mathint(units) * MAX_SETTLEMENT_FEE_STORED_6() * CBP_CVL() + WAD_CVL(),
        "take's captured spread never exceeds units * MAX_SETTLEMENT_FEE_360_DAYS / WAD (+1 wei rounding)");
}


// HL-MI-46b: the published settlement-fee schedule itself never exceeds the protocol's hard cap —
// for any time to maturity, the interpolated settlement-fee rate stays at or below the maximum
// rate (0.5% of the 1e18 fixed-point scale, WAD).
// FORMULA: forall ttm. settlementFee(id, ttm) <= MAX_SETTLEMENT_FEE_360_DAYS  (== 0.005e18)
rule settlementFeeNeverExceedsProtocolMax(env e, bytes32 id, uint256 ttm) {
    setupValidStateOneMidnight(e);
    uint256 sf = settlementFee(e, id, ttm);
    assert(to_mathint(sf) <= MAX_SETTLEMENT_FEE_STORED_6() * CBP_CVL(),
        "interpolated settlement fee never exceeds MAX_SETTLEMENT_FEE_360_DAYS (no overshoot)");
}

// HL-MI-47: when a maker's sell offer is filled, the loan tokens flow between exactly the right
// wallets — the buyer-side payer (the caller, when no taker callback is set) pays exactly the
// buyer's price, the receiver designated in the maker's signed offer gets exactly the seller's
// proceeds, the protocol keeps exactly the fee spread, and no other wallet's loan-token balance
// moves.
// FORMULA: buyerAssets >= sellerAssets
//          AND balance[loanToken][payer]' == balance[loanToken][payer] - buyerAssets
//          AND balance[loanToken][receiver]' == balance[loanToken][receiver] + sellerAssets
//          AND balance[loanToken][Midnight]' == balance[loanToken][Midnight]
//              + buyerAssets - sellerAssets
//          AND balance[loanToken][bystander]' == balance[loanToken][bystander]
//          where payer = msg.sender; receiver = offer.receiverIfMakerIsSeller
rule takeSellRoutesPayerReceiverMidnightExactly(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units,
    address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData,
    address bystander
) {
    setupValidStateOneMidnight(e);
    require(!offer.buy, "sell case");
    require(takerCallback == 0, "no buyer-side callback => payer == msg.sender (src L420-422)");

    address loanToken = offer.market.loanToken;
    address payer = e.msg.sender;
    address rcv = offer.receiverIfMakerIsSeller; // src L423
    require(payer != rcv && payer != _Midnight && rcv != _Midnight, "pairwise-distinct endpoints");
    require(bystander != payer && bystander != rcv && bystander != _Midnight, "bystander excludes endpoints");

    mathint bp = ghostERC20Balances128[loanToken][payer];
    mathint br = ghostERC20Balances128[loanToken][rcv];
    mathint bm = ghostERC20Balances128[loanToken][_Midnight];
    mathint bo = ghostERC20Balances128[loanToken][bystander];

    uint256 ba; uint256 sa;
    ba, sa = take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(to_mathint(ba) >= to_mathint(sa), "sell: buyerPrice = sellerPrice + fee, both ceil => spread >= 0");
    assert(ghostERC20Balances128[loanToken][payer] == bp - ba, "payer pays exactly buyerAssets total");
    assert(ghostERC20Balances128[loanToken][rcv] == br + sa, "receiver gets exactly sellerAssets");
    assert(ghostERC20Balances128[loanToken][_Midnight] == bm + ba - sa, "Midnight keeps exactly the spread");
    assert(ghostERC20Balances128[loanToken][bystander] == bo, "no 4th-party loanToken movement");
}

// HL-MI-48: when a maker's buy offer is filled, the loan tokens flow between exactly the right
// wallets — the maker (the buyer, when no maker callback is set) pays exactly the buyer's price,
// the taker-chosen receiver gets exactly the seller's proceeds, the protocol keeps exactly the
// fee spread, and no other wallet's loan-token balance moves.
// FORMULA: buyerAssets >= sellerAssets
//          AND balance[loanToken][payer]' == balance[loanToken][payer] - buyerAssets
//          AND balance[loanToken][receiver]' == balance[loanToken][receiver] + sellerAssets
//          AND balance[loanToken][Midnight]' == balance[loanToken][Midnight]
//              + buyerAssets - sellerAssets
//          AND balance[loanToken][bystander]' == balance[loanToken][bystander]
//          where payer = offer.maker; receiver = receiverIfTakerIsSeller
rule takeBuyRoutesPayerReceiverMidnightExactly(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units,
    address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData,
    address bystander
) {
    setupValidStateOneMidnight(e);
    require(offer.buy, "buy case");
    require(offer.callback == 0, "no maker-side callback => payer == buyer == maker (src L420-422)");

    address loanToken = offer.market.loanToken;
    address payer = offer.maker;
    address rcv = receiverIfTakerIsSeller; // src L423
    require(payer != rcv && payer != _Midnight && rcv != _Midnight, "pairwise-distinct endpoints");
    require(bystander != payer && bystander != rcv && bystander != _Midnight, "bystander excludes endpoints");

    mathint bp = ghostERC20Balances128[loanToken][payer];
    mathint br = ghostERC20Balances128[loanToken][rcv];
    mathint bm = ghostERC20Balances128[loanToken][_Midnight];
    mathint bo = ghostERC20Balances128[loanToken][bystander];

    uint256 ba; uint256 sa;
    ba, sa = take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(to_mathint(ba) >= to_mathint(sa), "buy: buyerPrice = sellerPrice + fee, both floor => spread >= 0");
    assert(ghostERC20Balances128[loanToken][payer] == bp - ba, "payer (maker-buyer) pays exactly buyerAssets total");
    assert(ghostERC20Balances128[loanToken][rcv] == br + sa, "receiver gets exactly sellerAssets");
    assert(ghostERC20Balances128[loanToken][_Midnight] == bm + ba - sa, "Midnight keeps exactly the spread");
    assert(ghostERC20Balances128[loanToken][bystander] == bo, "no 4th-party loanToken movement");
}

//
// Cross-cutting integrity & counterparty token routing (HL-MI-49..56)
//

// HL-MI-49: offer fills are irreversible — a maker's cumulative fill counter for any offer group
// can never be rolled back by any entry point, so a filled offer cap cannot be quietly reopened
// for replay.
// FORMULA: forall f, user, group. consumed[user][group]' >= consumed[user][group]
rule consumedMonotoneGlobally(env e, method f, calldataarg args, address u, bytes32 g)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    mathint c0 = ghostMiConsumed256[u][g];
    f(e, args);
    assert(ghostMiConsumed256[u][g] >= c0,
        "consumed[user][group] never decreases (offer fills are irreversible)");
}

// HL-MI-50: the health check that gates collateral withdrawals and liquidations computes exactly
// the documented formula — a borrower is healthy precisely when they have no debt, or the sum
// over their collateral slots of the oracle value discounted by each slot's
// loan-to-liquidation-value threshold (lltv) covers the debt, with every term rounded down
// against the borrower. Checked over the two modeled collateral slots.
// FORMULA: isHealthy(market, u) <=>
//          (debt[u] == 0
//           OR Σ_{i in {0,1}} floor(floor(collateral[u][i] * price_i / ORACLE_PRICE_SCALE)
//                                   * lltv_i / WAD) >= debt[u])
rule isHealthyMatchesFormula(env e, MidnightHarness.Market market, address user) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");
    require(ghostNumCollaterals == 2 && market.collateralParams.length == 2,
        "UNSAFE: two-collateral narrowing with a length-2 struct (slot-1 params addressable)");
    bytes32 id = toId(e, market);

    mathint debt  = ghostMiOnePositionDebt128[user];
    mathint p0    = ghostMiOraclePrice256[market.collateralParams[0].oracle];
    mathint p1    = ghostMiOraclePrice256[market.collateralParams[1].oracle];
    mathint term0 = to_mathint(mulDivDownCVL(
        mulDivDownCVL(require_uint256(ghostMiOnePositionCollateral128[user][0]), require_uint256(p0),
            require_uint256(ORACLE_PRICE_SCALE_CVL())),
        require_uint256(market.collateralParams[0].lltv), require_uint256(WAD_CVL())));
    mathint term1 = to_mathint(mulDivDownCVL(
        mulDivDownCVL(require_uint256(ghostMiOnePositionCollateral128[user][1]), require_uint256(p1),
            require_uint256(ORACLE_PRICE_SCALE_CVL())),
        require_uint256(market.collateralParams[1].lltv), require_uint256(WAD_CVL())));

    assert(isHealthy(e, market, id, user) <=> (debt == 0 || term0 + term1 >= debt),
        "isHealthy == (debt == 0 || maxDebt formula >= debt) with the exact floor roundings (src L944-960)");
}

// HL-MI-51..56: counterparty token legs for the six non-take money flows — each pull/push goes
// to/from exactly the designated counterparty for exactly the asserted amount, and no third
// address's balance moves.

// HL-MI-51: repaying a debt pulls the loan tokens from the caller's wallet only — exactly the
// repaid units leave msg.sender, the debtor's own wallet is never touched (so repaying on a
// borrower's behalf can never drain the borrower's standing token approval), and no third
// wallet's balance moves. Checked with no repay callback.
// FORMULA: balance[loanToken][msg.sender]' == balance[loanToken][msg.sender] - units
//          AND onBehalf not in {msg.sender, Midnight} =>
//              balance[loanToken][onBehalf]' == balance[loanToken][onBehalf]
//          AND forall v not in {msg.sender, Midnight}. balance[loanToken][v]' == balance[loanToken][v]
rule repayPullsExactlyFromPayerOnly(
    env e, MidnightHarness.Market market, uint256 units, address onBehalf, address callback, bytes data, address v
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    require(callback == 0, "callback == 0 => payer is msg.sender, no onRepay (src L511)");
    address loanToken = market.loanToken;
    require(v != e.msg.sender && v != _Midnight, "bystander is neither payer nor Midnight");

    mathint senderBefore   = ghostERC20Balances128[loanToken][e.msg.sender];
    mathint onBehalfBefore = ghostERC20Balances128[loanToken][onBehalf];
    mathint vBefore        = ghostERC20Balances128[loanToken][v];

    repay(e, market, units, onBehalf, callback, data);

    assert(ghostERC20Balances128[loanToken][e.msg.sender] == senderBefore - units,
        "repay: exactly units pulled from msg.sender");
    assert(onBehalf != e.msg.sender && onBehalf != _Midnight
        => ghostERC20Balances128[loanToken][onBehalf] == onBehalfBefore,
        "repay: the debtor's wallet is never touched (anti approval-mining)");
    assert(ghostERC20Balances128[loanToken][v] == vBefore,
        "repay: no third address's balance moves");
}

// HL-MI-52: a lender's withdrawal pays out to the designated receiver only — exactly the
// withdrawn units land in the receiver's wallet, and no other wallet's loan-token balance moves.
// FORMULA: balance[loanToken][receiver]' == balance[loanToken][receiver] + units
//          AND forall v not in {receiver, Midnight}. balance[loanToken][v]' == balance[loanToken][v]
rule withdrawPaysReceiverExactly(
    env e, MidnightHarness.Market market, uint256 units, address onBehalf, address receiver, address v
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    require(receiver != _Midnight, "SAFE: receiver is not Midnight");
    address loanToken = market.loanToken;
    require(v != receiver && v != _Midnight, "bystander is neither receiver nor Midnight");

    mathint receiverBefore = ghostERC20Balances128[loanToken][receiver];
    mathint vBefore        = ghostERC20Balances128[loanToken][v];

    withdraw(e, market, units, onBehalf, receiver);

    assert(ghostERC20Balances128[loanToken][receiver] == receiverBefore + units,
        "withdraw: the designated receiver gains exactly units");
    assert(ghostERC20Balances128[loanToken][v] == vBefore,
        "withdraw: no third address's balance moves");
}

// HL-MI-53: posting collateral pulls the tokens from the caller's wallet only — exactly the
// deposited assets leave msg.sender, the credited borrower's own wallet is never touched (no
// draining of the borrower's standing approval), and no third wallet's balance moves.
// FORMULA: balance[collateralToken[i]][msg.sender]'
//              == balance[collateralToken[i]][msg.sender] - assets
//          AND onBehalf not in {msg.sender, Midnight} =>
//              balance[collateralToken[i]][onBehalf]' == balance[collateralToken[i]][onBehalf]
//          AND forall v not in {msg.sender, Midnight}.
//              balance[collateralToken[i]][v]' == balance[collateralToken[i]][v]
rule supplyCollateralPullsSenderOnly(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 assets, address onBehalf, address v
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    address collateralToken = ghostMiOneCollateralToken[collateralIndex];
    require(collateralToken != _Midnight, "SAFE: collateral token is not Midnight");
    require(v != e.msg.sender && v != _Midnight, "bystander is neither payer nor Midnight");

    mathint senderBefore   = ghostERC20Balances128[collateralToken][e.msg.sender];
    mathint onBehalfBefore = ghostERC20Balances128[collateralToken][onBehalf];
    mathint vBefore        = ghostERC20Balances128[collateralToken][v];

    supplyCollateral(e, market, collateralIndex, assets, onBehalf);

    assert(ghostERC20Balances128[collateralToken][e.msg.sender] == senderBefore - assets,
        "supplyCollateral: exactly assets pulled from msg.sender (src L545)");
    assert(onBehalf != e.msg.sender && onBehalf != _Midnight
        => ghostERC20Balances128[collateralToken][onBehalf] == onBehalfBefore,
        "supplyCollateral: onBehalf's wallet is never touched (anti approval-mining)");
    assert(ghostERC20Balances128[collateralToken][v] == vBefore,
        "supplyCollateral: no third address's balance moves");
}

// HL-MI-54: withdrawing collateral pays the designated receiver only — exactly the withdrawn
// assets land in the receiver's wallet, and no other wallet's collateral-token balance moves.
// FORMULA: balance[collateralToken[i]][receiver]' == balance[collateralToken[i]][receiver] + assets
//          AND forall v not in {receiver, Midnight}.
//              balance[collateralToken[i]][v]' == balance[collateralToken[i]][v]
rule withdrawCollateralPaysReceiverExactly(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 assets,
    address onBehalf, address receiver, address v
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    address collateralToken = ghostMiOneCollateralToken[collateralIndex];
    require(collateralToken != _Midnight, "SAFE: collateral token is not Midnight");
    require(receiver != _Midnight, "SAFE: receiver is not Midnight");
    require(v != receiver && v != _Midnight, "bystander is neither receiver nor Midnight");

    mathint receiverBefore = ghostERC20Balances128[collateralToken][receiver];
    mathint vBefore        = ghostERC20Balances128[collateralToken][v];

    withdrawCollateral(e, market, collateralIndex, assets, onBehalf, receiver);

    assert(ghostERC20Balances128[collateralToken][receiver] == receiverBefore + assets,
        "withdrawCollateral: the designated receiver gains exactly assets (src L572)");
    assert(ghostERC20Balances128[collateralToken][v] == vBefore,
        "withdrawCollateral: no third address's balance moves");
}

// HL-MI-55: when the fee claimer collects the protocol's continuous-fee credit (cfc — fee units
// accrued to the protocol), the payout reaches the designated receiver only — exactly the claimed
// amount lands there, and no other wallet's loan-token balance moves.
// FORMULA: balance[loanToken][receiver]' == balance[loanToken][receiver] + amount
//          AND forall v not in {receiver, Midnight}. balance[loanToken][v]' == balance[loanToken][v]
rule claimContinuousFeePaysReceiverExactly(
    env e, MidnightHarness.Market market, uint256 amount, address receiver, address v
) {
    setupValidStateOneMidnight(e);
    require(receiver != _Midnight, "SAFE: receiver is not Midnight");
    address loanToken = market.loanToken;
    require(v != receiver && v != _Midnight, "bystander is neither receiver nor Midnight");

    mathint receiverBefore = ghostERC20Balances128[loanToken][receiver];
    mathint vBefore        = ghostERC20Balances128[loanToken][v];

    claimContinuousFee(e, market, amount, receiver);

    assert(ghostERC20Balances128[loanToken][receiver] == receiverBefore + amount,
        "claimContinuousFee: the designated receiver gains exactly amount (src L324)");
    assert(ghostERC20Balances128[loanToken][v] == vBefore,
        "claimContinuousFee: no third address's balance moves");
}

// HL-MI-56: when the fee claimer collects accumulated settlement fees for a token, the payout
// reaches the designated receiver only — exactly the claimed amount lands there, and no other
// wallet's balance of that token moves.
// FORMULA: balance[token][receiver]' == balance[token][receiver] + amount
//          AND forall v not in {receiver, Midnight}. balance[token][v]' == balance[token][v]
rule claimSettlementFeePaysReceiverExactly(
    env e, address token, uint256 amount, address receiver, address v
) {
    setupValidStateOneMidnight(e);
    require(receiver != _Midnight, "SAFE: receiver is not Midnight");
    require(v != receiver && v != _Midnight, "bystander is neither receiver nor Midnight");

    mathint receiverBefore = ghostERC20Balances128[token][receiver];
    mathint vBefore        = ghostERC20Balances128[token][v];

    claimSettlementFee(e, token, amount, receiver);

    assert(ghostERC20Balances128[token][receiver] == receiverBefore + amount,
        "claimSettlementFee: the designated receiver gains exactly amount (src L309)");
    assert(ghostERC20Balances128[token][v] == vBefore,
        "claimSettlementFee: no third address's balance moves");
}

// HL-MI-57/58: the liquidate counterparty token legs — seized collateral reaches only the
// liquidator's designated receiver, and the repayment is pulled only from the liquidation payer;
// no third wallet's balance moves.

// HL-MI-57: the collateral a liquidation seizes reaches the liquidator's designated receiver only
// — exactly the returned seized assets land in the receiver's wallet, the borrower's own wallet
// is never touched (the collateral leaves the protocol's custody, not the borrower's wallet), and
// no third wallet's collateral-token balance moves.
// FORMULA: balance[collateralToken[i]][receiver]' == balance[collateralToken[i]][receiver] + seized
//          AND borrower not in {receiver, Midnight} =>
//              balance[collateralToken[i]][borrower]' == balance[collateralToken[i]][borrower]
//          AND forall v not in {receiver, Midnight}.
//              balance[collateralToken[i]][v]' == balance[collateralToken[i]][v]
rule liquidateCollateralTokenRoutingExact(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssetsIn,
    uint256 repaidUnitsIn, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data, address v
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    address collateralToken = ghostMiOneCollateralToken[collateralIndex];
    require(collateralToken != ghostMiOneMarketLoanToken,
        "UNSAFE: collateral token distinct from loan token (aliased flows confound the legs)");
    require(receiver != _Midnight, "SAFE: receiver is not Midnight");
    require(v != receiver && v != _Midnight, "bystander is neither receiver nor Midnight");

    mathint receiverBefore = ghostERC20Balances128[collateralToken][receiver];
    mathint borrowerBefore = ghostERC20Balances128[collateralToken][borrower];
    mathint vBefore        = ghostERC20Balances128[collateralToken][v];

    uint256 seized; uint256 repaid;
    seized, repaid = liquidate(e, market, collateralIndex, seizedAssetsIn, repaidUnitsIn, borrower,
        postMaturityMode, receiver, callback, data);

    assert(ghostERC20Balances128[collateralToken][receiver] == receiverBefore + seized,
        "liquidate: the designated receiver gains exactly the returned seizedAssets (src L696)");
    assert(borrower != receiver && borrower != _Midnight
        => ghostERC20Balances128[collateralToken][borrower] == borrowerBefore,
        "liquidate: the borrower's wallet is never touched on the collateral leg");
    assert(ghostERC20Balances128[collateralToken][v] == vBefore,
        "liquidate: no third address's collateral-token balance moves");
}

// HL-MI-58: a liquidation's repayment is pulled from the liquidator's side only — exactly the
// returned repaid units leave the resolved payer (the callback contract if one is given,
// otherwise the caller), the borrower's own wallet is never pulled (the debtor cannot be made to
// pay for their own liquidation through a standing approval), and no third wallet's loan-token
// balance moves.
// FORMULA: balance[loanToken][payer]' == balance[loanToken][payer] - repaid
//          AND borrower not in {payer, Midnight} =>
//              balance[loanToken][borrower]' == balance[loanToken][borrower]
//          AND forall v not in {payer, Midnight}. balance[loanToken][v]' == balance[loanToken][v]
//          where payer = (callback != 0 ? callback : msg.sender)
rule liquidateLoanTokenRoutingExact(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssetsIn,
    uint256 repaidUnitsIn, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data, address v
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    address loanToken = ghostMiOneMarketLoanToken;
    require(ghostMiOneCollateralToken[collateralIndex] != loanToken,
        "UNSAFE: collateral token distinct from loan token (aliased flows confound the legs)");
    address payer = callback != 0 ? callback : e.msg.sender;
    require(payer != _Midnight, "SAFE: payer is not Midnight");
    require(v != payer && v != _Midnight, "bystander is neither payer nor Midnight");

    mathint payerBefore    = ghostERC20Balances128[loanToken][payer];
    mathint borrowerBefore = ghostERC20Balances128[loanToken][borrower];
    mathint vBefore        = ghostERC20Balances128[loanToken][v];

    uint256 seized; uint256 repaid;
    seized, repaid = liquidate(e, market, collateralIndex, seizedAssetsIn, repaidUnitsIn, borrower,
        postMaturityMode, receiver, callback, data);

    assert(ghostERC20Balances128[loanToken][payer] == payerBefore - repaid,
        "liquidate: exactly the returned repaidUnits pulled from the resolved payer (src L679/L717)");
    assert(borrower != payer && borrower != _Midnight
        => ghostERC20Balances128[loanToken][borrower] == borrowerBefore,
        "liquidate: the borrower's wallet is never pulled on the loan leg (anti approval-mining)");
    assert(ghostERC20Balances128[loanToken][v] == vBefore,
        "liquidate: no third address's loan-token balance moves");
}

//
// Liquidate exactness (HL-MI-59..62, heavy tier)
//

// HL-MI-59: the bad debt a liquidation socializes onto lenders is exactly the borrower's true
// shortfall — the drop in the market's total loan units (totalUnits) equals the debt minus the
// worst-case recoverable value of ALL the borrower's collateral (each slot valued at its oracle
// price and discounted by its maximum liquidation incentive factor, rounded against the
// write-off), floored at zero. The formula involves no liquidator-chosen input, so the seized and
// repaid amounts cannot steer how much loss gets socialized. Checked over the two modeled
// collateral slots.
// FORMULA: totalUnits - totalUnits' ==
//          max(0, debt[borrower] - Σ_{i in {0,1}} ceil(ceil(collateral[borrower][i] * price_i
//                                                           / ORACLE_PRICE_SCALE) * WAD / maxLif_i))
//          (RHS values pre-state)
rule badDebtFormulaExact(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssetsIn,
    uint256 repaidUnitsIn, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(ghostNumCollaterals == 2, "UNSAFE: two-collateral model (an unset bit zeroes its term, so single-slot states stay reachable)");
    require(market.collateralParams.length == 2, "align struct arg with the two-collateral narrowing");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: liquidated slot within the narrowing");

    mathint debtPre = ghostMiOnePositionDebt128[borrower];
    mathint tuPre   = ghostMiOneMarketTotalUnits128;
    mathint coll0   = ghostMiOnePositionCollateral128[borrower][0];
    mathint coll1   = ghostMiOnePositionCollateral128[borrower][1];
    mathint price0  = ghostMiOraclePrice256[market.collateralParams[0].oracle];
    mathint price1  = ghostMiOraclePrice256[market.collateralParams[1].oracle];

    // The L607-617 loop visits set bits only, but an unset bit holds a zero slot (VS-MI-04),
    // so its ceil term vanishes and the unconditional two-term sum matches the loop.
    mathint deduction0 = to_mathint(mulDivUpCVL(
        mulDivUpCVL(require_uint256(coll0), require_uint256(price0), require_uint256(ORACLE_PRICE_SCALE_CVL())),
        require_uint256(WAD_CVL()), require_uint256(maxLifCVL(market.collateralParams[0].lltv, market.collateralParams[0].liquidationCursor))));
    mathint deduction1 = to_mathint(mulDivUpCVL(
        mulDivUpCVL(require_uint256(coll1), require_uint256(price1), require_uint256(ORACLE_PRICE_SCALE_CVL())),
        require_uint256(WAD_CVL()), require_uint256(maxLifCVL(market.collateralParams[1].lltv, market.collateralParams[1].liquidationCursor))));
    mathint expectedBadDebt = debtPre > deduction0 + deduction1 ? debtPre - (deduction0 + deduction1) : 0;

    liquidate(e, market, collateralIndex, seizedAssetsIn, repaidUnitsIn, borrower,
        postMaturityMode, receiver, callback, data);

    assert(tuPre - ghostMiOneMarketTotalUnits128 == expectedBadDebt,
        "liquidate: the totalUnits write-off equals the exact entry-loop badDebt formula (src L605-618, L634)");
}

// HL-MI-60: when the liquidator names the collateral to seize, the debt they must repay is
// computed exactly — the returned seized amount is the input verbatim, and the repaid units equal
// the seized collateral's oracle value divided by the liquidation incentive factor (lif), the
// WAD-scaled collateral bonus multiplier ramping from 1.0 at maturity to maxLif over 60 minutes,
// with both division steps rounded against the liquidator so they can never under-pay per seized
// unit.
// FORMULA: seized == seizedAssetsIn
//          AND repaid == ceil(ceil(seizedAssetsIn * price / ORACLE_PRICE_SCALE) * WAD / lif)
//          where lif = postMaturityMode
//                      ? min(maxLif, WAD + floor((maxLif - WAD) * max(0, now - maturity) / 3600))
//                      : maxLif
rule seizureToRepaidConversionExact(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssetsIn,
    address borrower, bool postMaturityMode, address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    require(seizedAssetsIn > 0, "seized-input path (the repaid-input path is HL-MI-61)");

    // Successful seized > 0 paths force the liquidated bit set: an unset bit keeps the slot at
    // zero (VS-MI-04) and the L670 subtraction underflows, so the in-loop liquidatedCollatPrice
    // binding (L611) always equals this oracle ghost.
    mathint price  = ghostMiOraclePrice256[market.collateralParams[collateralIndex].oracle];
    mathint maxLif = maxLifCVL(market.collateralParams[collateralIndex].lltv, market.collateralParams[collateralIndex].liquidationCursor);

    uint256 seized;
    uint256 repaid;
    seized, repaid = liquidate(e, market, collateralIndex, seizedAssetsIn, 0, borrower,
        postMaturityMode, receiver, callback, data);

    // Mirrors src L645-647; every successful postMaturityMode path has ts > maturity
    // (NotLiquidatable gate), so the zero-floor only guards infeasible-path arithmetic.
    mathint elapsed = to_mathint(e.block.timestamp) > to_mathint(market.maturity)
        ? e.block.timestamp - market.maturity : 0;
    mathint ramped = WAD_CVL() + (maxLif - WAD_CVL()) * elapsed / 3600; // TIME_TO_MAX_LIF = 60 min
    mathint lif    = postMaturityMode ? (ramped < maxLif ? ramped : maxLif) : maxLif;

    assert(to_mathint(seized) == to_mathint(seizedAssetsIn),
        "liquidate: the seized-input path returns the input verbatim (src L650 writes only repaidUnits)");
    assert(to_mathint(repaid) == to_mathint(mulDivUpCVL(
            mulDivUpCVL(seizedAssetsIn, require_uint256(price), require_uint256(ORACLE_PRICE_SCALE_CVL())),
            require_uint256(WAD_CVL()), require_uint256(lif))),
        "liquidate: repaid == ceil(ceil(seized*price/OPS)*WAD/lif) exactly, ramp-aware (src L650)");
}

// HL-MI-61: when the liquidator names the debt to repay, the collateral they receive is computed
// exactly — the returned repaid amount is the input verbatim, and the seized collateral equals
// the repaid units scaled up by the liquidation incentive factor (lif, the time-ramped WAD-scaled
// bonus multiplier) and converted at the oracle price, with both steps rounded down so the
// borrower can never be over-seized per repaid unit.
// FORMULA: repaid == repaidUnitsIn
//          AND seized == floor(floor(repaidUnitsIn * lif / WAD) * ORACLE_PRICE_SCALE / price)
//          where lif = postMaturityMode
//                      ? min(maxLif, WAD + floor((maxLif - WAD) * max(0, now - maturity) / 3600))
//                      : maxLif
rule repaidToSeizedConversionExact(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 repaidUnitsIn,
    address borrower, bool postMaturityMode, address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    require(repaidUnitsIn > 0, "repaid-input path (the seized-input path is HL-MI-60)");

    // Successful repaid > 0 paths force the liquidated bit set: an unset bit leaves
    // liquidatedCollatPrice == 0 and the L652 division reverts, so the in-loop price binding
    // always equals this oracle ghost.
    mathint price  = ghostMiOraclePrice256[market.collateralParams[collateralIndex].oracle];
    mathint maxLif = maxLifCVL(market.collateralParams[collateralIndex].lltv, market.collateralParams[collateralIndex].liquidationCursor);

    uint256 seized;
    uint256 repaid;
    seized, repaid = liquidate(e, market, collateralIndex, 0, repaidUnitsIn, borrower,
        postMaturityMode, receiver, callback, data);

    mathint elapsed = to_mathint(e.block.timestamp) > to_mathint(market.maturity)
        ? e.block.timestamp - market.maturity : 0;
    mathint ramped = WAD_CVL() + (maxLif - WAD_CVL()) * elapsed / 3600; // TIME_TO_MAX_LIF = 60 min
    mathint lif    = postMaturityMode ? (ramped < maxLif ? ramped : maxLif) : maxLif;

    assert(to_mathint(repaid) == to_mathint(repaidUnitsIn),
        "liquidate: the repaid-input path returns the input verbatim (src L652 writes only seizedAssets)");
    assert(to_mathint(seized) == to_mathint(mulDivDownCVL(
            mulDivDownCVL(repaidUnitsIn, require_uint256(lif), require_uint256(WAD_CVL())),
            require_uint256(ORACLE_PRICE_SCALE_CVL()), require_uint256(price))),
        "liquidate: seized == floor(floor(repaid*lif/WAD)*OPS/price) exactly, ramp-aware (src L652)");
}

// HL-MI-62: the post-maturity liquidation bonus only grows with time — for a fixed repayment, the
// collateral a liquidator seizes now is at least what the conversion formula would have granted
// at any earlier post-maturity instant, so liquidators are never pushed to wait out a decaying
// incentive while an underwater position sits unliquidated.
// FORMULA: forall tEarlier in (maturity, block.timestamp].
//          seized >= floor(floor(repaidUnitsIn * lif(tEarlier) / WAD) * ORACLE_PRICE_SCALE / price)
//          where lif(t) = min(maxLif, WAD + floor((maxLif - WAD) * (t - maturity) / 3600))
rule postMaturityLifIncentiveMonotoneInTime(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 repaidUnitsIn,
    address borrower, address receiver, address callback, bytes data, uint256 tEarlier
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    require(repaidUnitsIn > 0, "repaid-input path (fixed repayment, compare seized output)");
    require(to_mathint(tEarlier) > to_mathint(market.maturity)
        && to_mathint(tEarlier) <= to_mathint(e.block.timestamp),
        "tEarlier is an earlier post-maturity instant");

    mathint price  = ghostMiOraclePrice256[market.collateralParams[collateralIndex].oracle];
    mathint maxLif = maxLifCVL(market.collateralParams[collateralIndex].lltv, market.collateralParams[collateralIndex].liquidationCursor);

    uint256 seized;
    uint256 repaid;
    seized, repaid = liquidate(e, market, collateralIndex, 0, repaidUnitsIn, borrower,
        true, receiver, callback, data);

    mathint rampedEarlier = WAD_CVL() + (maxLif - WAD_CVL()) * (tEarlier - market.maturity) / 3600;
    mathint lifEarlier    = rampedEarlier < maxLif ? rampedEarlier : maxLif;

    assert(to_mathint(seized) >= to_mathint(mulDivDownCVL(
            mulDivDownCVL(repaidUnitsIn, require_uint256(lifEarlier), require_uint256(WAD_CVL())),
            require_uint256(ORACLE_PRICE_SCALE_CVL()), require_uint256(price))),
        "post-maturity: for a fixed repayment, waiting never shrinks the seizable collateral (lif ramps up, src L645-647)");
}
