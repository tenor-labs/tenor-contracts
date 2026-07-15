// State-transition properties for Midnight (one-market regime).
//
// Each rule asserts a multi-variable co-transition that must hold across any function
// call, building on the valid-state invariants (loaded via setupValidStateOneMidnight).
// Candidate provenance is tagged per rule header (ST-CAND-NN).

import "midnight_valid_state_one.spec";

//
// Method-category filters
//

definition CLAIM_SETTLEMENT_FEE(method f) returns bool =
    f.selector == sig:MidnightHarness.claimSettlementFee(address,uint256,address).selector;

definition COLLATERAL_OP(method f) returns bool =
    f.selector == sig:MidnightHarness.supplyCollateral(MidnightHarness.Market,uint256,uint256,address).selector
 || f.selector == sig:MidnightHarness.withdrawCollateral(MidnightHarness.Market,uint256,uint256,address,address).selector;

definition TAKE_SELECTOR(method f) returns bool =
    f.selector == sig:MidnightHarness.take(MidnightHarness.Offer,bytes,uint256,address,address,address,bytes).selector;

//
// Settlement-fee pot
//

// ST-MI-09 (ST-CAND-10, Pattern 7): the per-token pot of settlement fees collected from trades can
// only be drained by an explicit claim through claimSettlementFee -- no trade, lending, collateral,
// or liquidation path can take money out of the fee claimer's pot.
// FORMULA: forall f. claimableSettlementFee[token]' < claimableSettlementFee[token]
//          => f == claimSettlementFee
rule claimableSettlementFeeDecreasesOnlyViaClaim(env e, method f, calldataarg args, address token)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);

    mathint claimableBefore = ghostMiClaimableSettlementFee256[token];

    f(e, args);

    mathint claimableAfter = ghostMiClaimableSettlementFee256[token];

    assert(claimableAfter < claimableBefore => CLAIM_SETTLEMENT_FEE(f),
        "claimableSettlementFee[token] can only decrease via claimSettlementFee");
}

//
// Collateral management
//

// ST-MI-07 (ST-CAND-08, Pattern 6): posting or withdrawing collateral is a pure collateral movement.
// It leaves every position's credit, debt, and uncollected fee (pendingFee) untouched, and leaves
// the market's total loan units (totalUnits), the loan tokens available for withdrawal
// (withdrawable), and the protocol's continuous-fee credit (cfc) unchanged.
// FORMULA: forall f, u. f in {supplyCollateral, withdrawCollateral} =>
//          credit[u]' == credit[u] AND debt[u]' == debt[u] AND pendingFee[u]' == pendingFee[u]
//          AND totalUnits' == totalUnits AND withdrawable' == withdrawable
//          AND continuousFeeCredit' == continuousFeeCredit
rule collateralOpsPreserveCreditDebtFeeSurface(env e, method f, calldataarg args, address u)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);

    mathint creditBefore       = ghostMiOnePositionCredit128[u];
    mathint debtBefore         = ghostMiOnePositionDebt128[u];
    mathint pendingFeeBefore   = ghostMiOnePositionPendingFee128[u];
    mathint totalUnitsBefore   = ghostMiOneMarketTotalUnits128;
    mathint withdrawableBefore = ghostMiOneMarketWithdrawable128;
    mathint cfcBefore          = ghostMiOneMarketContinuousFeeCredit128;

    f(e, args);

    assert(COLLATERAL_OP(f) => (
        ghostMiOnePositionCredit128[u]       == creditBefore
        && ghostMiOnePositionDebt128[u]      == debtBefore
        && ghostMiOnePositionPendingFee128[u] == pendingFeeBefore
        && ghostMiOneMarketTotalUnits128     == totalUnitsBefore
        && ghostMiOneMarketWithdrawable128   == withdrawableBefore
        && ghostMiOneMarketContinuousFeeCredit128 == cfcBefore
    ), "collateral supply/withdraw must not change credit/debt/pendingFee/totalUnits/withdrawable/continuousFeeCredit");
}

//
// Liquidation / bad-debt slashing
//

// ST-MI-05 (ST-CAND-06, Pattern 1): socializing bad debt always destroys loan units. Whenever the
// cumulative bad-debt socialization factor (lossFactor) rises -- a bad-debt slash against lenders --
// the market's total loan units (totalUnits) must strictly fall, reflecting the written-off debt.
// FORMULA: forall f. lossFactor' > lossFactor => totalUnits' < totalUnits
rule lossFactorIncreaseCoincidesWithTotalUnitsDecrease(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);

    mathint lossFactorBefore = ghostMiOneMarketLossFactor128;
    mathint totalUnitsBefore = ghostMiOneMarketTotalUnits128;

    f(e, args);

    assert(ghostMiOneMarketLossFactor128 > lossFactorBefore
        => ghostMiOneMarketTotalUnits128 < totalUnitsBefore,
        "a lossFactor increase (bad-debt slash) must strictly decrease totalUnits");
}

// ST-MI-04 (ST-CAND-05, Pattern 10): a liquidator can never liquidate a debt-free position. Every
// liquidate call that succeeds implies the targeted borrower held positive debt beforehand.
// FORMULA: liquidate(borrower) succeeds => debt[borrower] > 0
rule liquidateRequiresBorrowerDebt(
    env e,
    MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");

    mathint debtBefore = ghostMiOnePositionDebt128[borrower];

    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);

    assert(debtBefore > 0,
        "liquidate only succeeds when the borrower holds debt (NotBorrower guard)");
}

//
// Trading (take)
//

// ST-MI-03 (ST-CAND-04, Pattern 10): once a market is past its maturity date, trading can no longer
// create new debt. A take() (a buyer fills a maker's offer) executed after maturity may not increase
// the debt of either counterparty -- maker and taker debts can only stay flat or fall.
// FORMULA: block.timestamp > market.maturity
//          => debt[offer.maker]' <= debt[offer.maker] AND debt[taker]' <= debt[taker]
rule takeCannotIncreaseDebtPostMaturity(
    env e,
    MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(offer.maker), "UNSAFE: maker in the narrowed three-user set");
    require(VALID_POSITION_USER(taker), "UNSAFE: taker in the narrowed three-user set");

    mathint makerDebtBefore = ghostMiOnePositionDebt128[offer.maker];
    mathint takerDebtBefore = ghostMiOnePositionDebt128[taker];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(e.block.timestamp > offer.market.maturity => (
        ghostMiOnePositionDebt128[offer.maker] <= makerDebtBefore
        && ghostMiOnePositionDebt128[taker] <= takerDebtBefore
    ), "post-maturity take must not increase maker or taker debt");
}

// ST-MI-01 (ST-CAND-01, Pattern 1): a trade through the take() entry point (a buyer fills a maker's
// offer) moves each side's position in the right direction: the buyer -- the party receiving credit
// -- never picks up debt, while the seller -- the party taking on the loan -- never gains credit and
// never sheds debt. Checked for two distinct counterparties.
// FORMULA: debt[buyer]' <= debt[buyer]
//          AND credit[seller]' <= credit[seller]
//          AND debt[seller]' >= debt[seller]
//          where buyer = offer.buy ? offer.maker : taker, seller = the other counterparty
rule takePairsCreditAndDebtDirectionally(
    env e,
    MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    address buyer  = offer.buy ? offer.maker : taker;
    address seller = offer.buy ? taker : offer.maker;
    require(VALID_POSITION_USER(buyer) && VALID_POSITION_USER(seller), "UNSAFE: counterparties in narrowed user set");
    require(buyer != seller, "UNSAFE: distinct buyer and seller (no self-take)");

    mathint buyerDebtBefore    = ghostMiOnePositionDebt128[buyer];
    mathint sellerCreditBefore = ghostMiOnePositionCredit128[seller];
    mathint sellerDebtBefore   = ghostMiOnePositionDebt128[seller];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(
        ghostMiOnePositionDebt128[buyer]    <= buyerDebtBefore
        && ghostMiOnePositionCredit128[seller] <= sellerCreditBefore
        && ghostMiOnePositionDebt128[seller]   >= sellerDebtBefore,
        "take: buyer never gains debt; seller credit non-increasing and debt non-decreasing");
}

// ST-MI-02 (ST-CAND-03, Pattern 1): when a lender's credit shrinks, the fee accrued on the position
// but not yet collected (pendingFee) is burned proportionally with it, so a smaller position can
// never end up owing MORE fee. Holds for every entry point except the take() trade path, where the
// fee pre-charged on newly bought credit can legitimately raise pendingFee even as the buyer's
// existing credit is reduced.
// FORMULA: forall f != take, u. credit[u]' < credit[u] => pendingFee[u]' <= pendingFee[u]
rule creditDecreaseDoesNotRaisePendingFee(env e, method f, calldataarg args, address u)
    filtered { f -> !EXCLUDED_FUNCTION(f) && !TAKE_SELECTOR(f) } {
    setupValidStateOneMidnight(e);

    mathint creditBefore     = ghostMiOnePositionCredit128[u];
    mathint pendingFeeBefore = ghostMiOnePositionPendingFee128[u];

    f(e, args);

    assert(ghostMiOnePositionCredit128[u] < creditBefore
        => ghostMiOnePositionPendingFee128[u] <= pendingFeeBefore,
        "a reduction of a position's credit must not raise its pendingFee");
}

// ST-MI-06 (ST-CAND-07, Pattern 1): withdrawing collateral is token-conservative: collateral removed
// from borrower positions leaves the protocol's own token holdings one-for-one. Summed over the
// three modeled users, the recorded collateral at the given index changes by exactly the change in
// the protocol's balance of that collateral token (with the receiver outside the protocol itself).
// FORMULA: Sigma_u (collateral[u][idx]' - collateral[u][idx])
//          == balance[collateralToken[idx]][Midnight]' - balance[collateralToken[idx]][Midnight]
rule withdrawCollateralMatchesMidnightBalance(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 assets, address onBehalf, address receiver
) {
    setupValidStateOneMidnight(e);
    require(onBehalf == ghostMiPositionUserOne || onBehalf == ghostMiPositionUserTwo || onBehalf == ghostMiPositionUserThree,
        "UNSAFE: onBehalf in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    require(receiver != _Midnight, "SAFE: collateral receiver is not Midnight itself");
    address ctoken = ghostMiOneCollateralToken[collateralIndex];

    mathint sumCollateralBefore =
        ghostMiOnePositionCollateral128[ghostMiPositionUserOne][collateralIndex]
        + ghostMiOnePositionCollateral128[ghostMiPositionUserTwo][collateralIndex]
        + ghostMiOnePositionCollateral128[ghostMiPositionUserThree][collateralIndex];
    mathint midnightBalanceBefore = ghostERC20Balances128[ctoken][_Midnight];

    withdrawCollateral(e, market, collateralIndex, assets, onBehalf, receiver);

    mathint sumCollateralAfter =
        ghostMiOnePositionCollateral128[ghostMiPositionUserOne][collateralIndex]
        + ghostMiOnePositionCollateral128[ghostMiPositionUserTwo][collateralIndex]
        + ghostMiOnePositionCollateral128[ghostMiPositionUserThree][collateralIndex];
    mathint midnightBalanceAfter = ghostERC20Balances128[ctoken][_Midnight];

    assert(sumCollateralAfter - sumCollateralBefore == midnightBalanceAfter - midnightBalanceBefore,
        "withdrawCollateral: change in Σ collateral[idx] equals change in Midnight's collateralToken balance");
}

// ST-MI-10 (ST-CAND-11, Pattern 3): claiming settlement fees pays out exactly what it deducts: a
// claim of `amount` reduces both the per-token claimable settlement-fee pot and the protocol's own
// balance of that token by exactly that amount, so the fee claimer cannot extract more than the pot
// records (receiver outside the protocol itself).
// FORMULA: claimableSettlementFee[token]' == claimableSettlementFee[token] - amount
//          AND balance[token][Midnight]' == balance[token][Midnight] - amount
rule claimSettlementFeeMatchesBalance(env e, address token, uint256 amount, address receiver) {
    setupValidStateOneMidnight(e);
    require(receiver != _Midnight, "SAFE: fee receiver is not Midnight itself");

    mathint claimableBefore = ghostMiClaimableSettlementFee256[token];
    mathint balanceBefore   = ghostERC20Balances128[token][_Midnight];

    claimSettlementFee(e, token, amount, receiver);

    assert(ghostMiClaimableSettlementFee256[token] == claimableBefore - amount
        && ghostERC20Balances128[token][_Midnight] == balanceBefore - amount,
        "claimSettlementFee: claimable and Midnight balance both drop by amount");
}

// ST-MI-11 (ST-CAND-12, Pattern 6/10): a trade can never leave its seller exposed to liquidation:
// every successful take() (a buyer fills a maker's offer) exits with the seller either healthy
// (collateral still covers the debt under the loan-to-liquidation-value threshold) or protected by
// the in-transaction liquidation lock.
// FORMULA: liquidationLocked[id][seller]' OR isHealthy(market, seller)'
rule takeLeavesSellerLockedOrHealthy(
    env e,
    MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    address seller = offer.buy ? taker : offer.maker;
    require(VALID_POSITION_USER(seller), "UNSAFE: seller in the narrowed three-user set");

    bytes32 id = toId(e, offer.market);

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(liquidationLocked(e, id, seller) || isHealthy(e, offer.market, id, seller),
        "a successful take must leave the seller liquidation-locked or healthy");
}

//
// Continuous-fee accrual
//

// ST-MI-08 (ST-CAND-09, Pattern 5/3): no function can change a lender's money without bringing the
// position fully up to date in the same step. Whenever any call changes a position's credit or its
// uncollected fee (pendingFee), it must also stamp the position's accrual time to the current block
// timestamp and re-sync its snapshot of the cumulative bad-debt socialization factor (lossFactor) --
// so fee accrual and bad-debt slashing can never be skipped on a touched position.
// FORMULA: forall f, u. (credit[u]' != credit[u] OR pendingFee[u]' != pendingFee[u])
//          => lastAccrual[u]' == block.timestamp AND lastLossFactor[u]' == lossFactor'
rule creditSideChangeStampsAccrual(env e, method f, calldataarg args, address u)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);

    mathint creditBefore     = ghostMiOnePositionCredit128[u];
    mathint pendingFeeBefore = ghostMiOnePositionPendingFee128[u];

    f(e, args);

    bool creditSideChanged =
        ghostMiOnePositionCredit128[u] != creditBefore
        || ghostMiOnePositionPendingFee128[u] != pendingFeeBefore;

    assert(creditSideChanged => (
        ghostMiOnePositionLastAccrual128[u] == e.block.timestamp
        && ghostMiOnePositionLastLossFactor128[u] == ghostMiOneMarketLossFactor128
    ), "a credit/pendingFee change must stamp lastAccrual:=now and lastLossFactor:=marketState.lossFactor");
}

//
// Tick-spacing refinement & liquidation lock (U-36/U-37 and U-22)
//

// ST-MI-12 (Pattern 1/4): a market's tick spacing -- the granularity at which offer prices may be
// quoted -- can only be refined, never coarsened: any change must install a positive value that
// exactly divides the old one, so every previously valid price tick remains valid.
// FORMULA: forall f. tickSpacing[id]' != tickSpacing[id]
//          => tickSpacing[id]' > 0 AND tickSpacing[id] % tickSpacing[id]' == 0
rule tickSpacingRefinesToDivisor(env e, method f, calldataarg args, bytes32 id)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);

    mathint spacingBefore = ghostMiMarketTickSpacing[id];

    f(e, args);

    mathint spacingAfter = ghostMiMarketTickSpacing[id];
    assert(spacingAfter != spacingBefore
        => (spacingAfter > 0 && spacingBefore % spacingAfter == 0),
        "tickSpacing changes only to a positive divisor of the current spacing (src L590-592)");
}

// ST-MI-13 (Pattern 10): liquidation respects the in-transaction liquidation lock: a liquidator can
// never liquidate a borrower whose position is currently liquidation-locked, even when liquidate is
// entered mid-transaction (e.g. from a trade callback) while the lock is still set.
// FORMULA: liquidate(borrower) succeeds => NOT liquidationLocked[id][borrower]
rule liquidateRequiresUnlockedBorrower(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode, address receiver, address callback, bytes data
) {
    setupValidStateOneMidnightWithLock(e, false);
    bytes32 id = toId(e, market);

    bool lockedBefore = ghostMiLiquidationLock[id][borrower];

    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);

    assert(!lockedBefore,
        "liquidate must not proceed while the borrower is liquidation-locked (src L621)");
}

//
// Liquidate source-tracking & frame
//

definition LIQUIDATE_SELECTOR(method f) returns bool =
    f.selector == sig:MidnightHarness.liquidate(MidnightHarness.Market,uint256,uint256,uint256,address,bool,address,address,bytes).selector;

definition REPAY_SELECTOR(method f) returns bool =
    f.selector == sig:MidnightHarness.repay(MidnightHarness.Market,uint256,address,address,bytes).selector;

// ST-MI-14 (Pattern 7): only liquidation can socialize losses onto lenders: the cumulative bad-debt
// socialization factor (lossFactor), which lazily slashes every lender position on its next touch,
// can be raised by liquidate and by no other function -- no fee, trade, or admin path can dilute
// lenders' credit.
// FORMULA: forall f. lossFactor' > lossFactor => f == liquidate
rule lossFactorRaisedOnlyByLiquidate(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);

    mathint lossFactorBefore = ghostMiOneMarketLossFactor128;

    f(e, args);

    assert(ghostMiOneMarketLossFactor128 > lossFactorBefore => LIQUIDATE_SELECTOR(f),
        "a lossFactor rise (bad-debt slash) can only originate in liquidate (src L631)");
}

// ST-MI-15 (Pattern 6): liquidation settles purely on the debt-and-collateral side: it never writes
// any position's credit-side accounting -- credit, uncollected fee (pendingFee), accrual timestamp,
// or loss-factor snapshot -- not even the liquidated borrower's, because the bad-debt slash is
// applied lazily on each position's next touch; nor does it touch the market's fee configuration
// (the settlement-fee schedule, the continuous fee rate, or the tick spacing). Proven for every
// position, the borrower included.
// FORMULA: forall u. credit[u]' == credit[u] AND pendingFee[u]' == pendingFee[u]
//          AND lastAccrual[u]' == lastAccrual[u] AND lastLossFactor[u]' == lastLossFactor[u]
//          AND tickSpacing' == tickSpacing AND continuousFee' == continuousFee
//          AND forall bucket in 0..6. settlementFee[bucket]' == settlementFee[bucket]
rule liquidatePreservesCreditSideSurface(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode,
    address receiver, address callback, bytes data, address u
) {
    setupValidStateOneMidnight(e);

    mathint creditBefore         = ghostMiOnePositionCredit128[u];
    mathint pendingFeeBefore     = ghostMiOnePositionPendingFee128[u];
    mathint lastAccrualBefore    = ghostMiOnePositionLastAccrual128[u];
    mathint lastLossFactorBefore = ghostMiOnePositionLastLossFactor128[u];
    mathint tickSpacingBefore    = ghostMiOneMarketTickSpacing;
    mathint continuousFeeBefore  = ghostMiOneMarketContinuousFee32;
    mathint sf0Before = ghostMiOneMarketSettlementFeeCbp0_16;
    mathint sf1Before = ghostMiOneMarketSettlementFeeCbp1_16;
    mathint sf2Before = ghostMiOneMarketSettlementFeeCbp2_16;
    mathint sf3Before = ghostMiOneMarketSettlementFeeCbp3_16;
    mathint sf4Before = ghostMiOneMarketSettlementFeeCbp4_16;
    mathint sf5Before = ghostMiOneMarketSettlementFeeCbp5_16;
    mathint sf6Before = ghostMiOneMarketSettlementFeeCbp6_16;

    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);

    assert(ghostMiOnePositionCredit128[u]            == creditBefore
        && ghostMiOnePositionPendingFee128[u]        == pendingFeeBefore
        && ghostMiOnePositionLastAccrual128[u]       == lastAccrualBefore
        && ghostMiOnePositionLastLossFactor128[u]    == lastLossFactorBefore,
        "liquidate must not write any position's credit/pendingFee/lastAccrual/lastLossFactor (lazy slash)");
    assert(ghostMiOneMarketTickSpacing               == tickSpacingBefore
        && ghostMiOneMarketContinuousFee32           == continuousFeeBefore
        && ghostMiOneMarketSettlementFeeCbp0_16      == sf0Before
        && ghostMiOneMarketSettlementFeeCbp1_16      == sf1Before
        && ghostMiOneMarketSettlementFeeCbp2_16      == sf2Before
        && ghostMiOneMarketSettlementFeeCbp3_16      == sf3Before
        && ghostMiOneMarketSettlementFeeCbp4_16      == sf4Before
        && ghostMiOneMarketSettlementFeeCbp5_16      == sf5Before
        && ghostMiOneMarketSettlementFeeCbp6_16      == sf6Before,
        "liquidate must not touch the market's fee surface or tickSpacing");
}

// ST-MI-16 (Pattern 7): debt can only shrink through a legitimate repayment channel: a position's
// debt decreases only via the take() trade entry point (a buyer's purchase is netted against the
// buyer's existing debt), repay, or liquidate (the liquidator repays the debt and any shortfall is
// written off as bad debt). Withdrawals, fee claims, collateral operations, flash loans, and admin
// setters can never lower anyone's debt.
// FORMULA: forall f, u. debt[u]' < debt[u] => f in {take, repay, liquidate}
rule debtDecreaseOnlyViaTakeRepayOrLiquidate(env e, method f, calldataarg args, address u)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);

    mathint debtBefore = ghostMiOnePositionDebt128[u];

    f(e, args);

    assert(ghostMiOnePositionDebt128[u] < debtBefore
        => (TAKE_SELECTOR(f) || REPAY_SELECTOR(f) || LIQUIDATE_SELECTOR(f)),
        "debt can only decrease via take's buyer leg, repay, or liquidate");
}

// ST-MI-18 (Pattern 4): governance can only widen the set of enabled LLTV tiers, never shrink it.
// Across every entry point, an LLTV tier that is enabled before a call stays enabled after it
// (enableLltv only flips false -> true; there is no disable path), so markets created against a tier
// can never be invalidated by a later governance action.
// FORMULA: forall f, lltv. isLltvEnabled[lltv] => isLltvEnabled[lltv]'
rule lltvEnabledIsMonotone(env e, method f, calldataarg args, uint256 lltv)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);

    bool before = ghostMiIsLltvEnabled[lltv];

    f(e, args);

    assert(before => ghostMiIsLltvEnabled[lltv],
        "an enabled LLTV tier can never be disabled");
}

// ST-MI-19 (Pattern 4): governance can only widen the set of enabled liquidation cursors, never
// shrink it. Across every entry point, a cursor that is enabled before a call stays enabled after it
// (enableLiquidationCursor only flips false -> true).
// FORMULA: forall f, cursor. isLiquidationCursorEnabled[cursor] => isLiquidationCursorEnabled[cursor]'
rule liquidationCursorEnabledIsMonotone(env e, method f, calldataarg args, uint256 cursor)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);

    bool before = ghostMiIsLiquidationCursorEnabled[cursor];

    f(e, args);

    assert(before => ghostMiIsLiquidationCursorEnabled[cursor],
        "an enabled liquidation cursor can never be disabled");
}
