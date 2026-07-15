// Reachability rules for Midnight (one-market regime).
//
// Each rule uses satisfy() to prove a meaningful, non-reverting execution path EXISTS from a valid
// state. Their value is ANTI-VACUITY: the verification model is heavily narrowed (one market, 3 users,
// 2 collateral slots, 5-tick price, oracle >= 1, empty callbacks, all VS-MI-01..20 loaded), and if that
// narrowing made a critical state unreachable, the ST/HL/bug-hunt rules over that state would pass
// vacuously. A satisfy that the prover CANNOT witness (UNSAT) flags such a hole.
import "midnight_valid_state_one.spec";

//
// take -- credit/debt minting and fee capture must be reachable (else the take-side rules are vacuous)
//

// RC-MI-01: a lender can actually acquire credit through trading: there is a real execution of the
// take() trade entry point (a buyer fills a maker's offer) in which the buyer's interest-bearing
// credit balance strictly increases, proving the credit-minting side of a trade is live.
// FORMULA: satisfy: exists execution of take. credit[buyer]' > credit[buyer]
//          where buyer = offer.maker if the offer is a buy offer, else the taker
rule takeMintsCreditReachable(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    address buyer = offer.buy ? offer.maker : taker;
    require(VALID_POSITION_USER(buyer), "UNSAFE: buyer in the narrowed three-user set");
    mathint creditBefore = ghostMiOnePositionCredit128[buyer];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    satisfy(ghostMiOnePositionCredit128[buyer] > creditBefore, "take can mint credit to the buyer");
}

// RC-MI-02: a borrower can actually take on debt through trading: there is a real execution of the
// take() trade entry point (a buyer fills a maker's offer) in which the seller's debt strictly
// increases, proving the borrow side of a trade is live.
// FORMULA: satisfy: exists execution of take. debt[seller]' > debt[seller]
//          where seller = the taker if the offer is a buy offer, else offer.maker
rule takeMintsDebtReachable(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    address seller = offer.buy ? taker : offer.maker;
    require(VALID_POSITION_USER(seller), "UNSAFE: seller in the narrowed three-user set");
    mathint debtBefore = ghostMiOnePositionDebt128[seller];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    satisfy(ghostMiOnePositionDebt128[seller] > debtBefore, "take can mint debt to the seller");
}

// RC-MI-03: the protocol can actually earn trading fees: there is a real execution of the take()
// trade entry point (a buyer fills a maker's offer) in which the per-token pot of settlement fees
// claimable by the fee claimer strictly grows.
// FORMULA: satisfy: exists execution of take.
//          claimableSettlementFee[loanToken]' > claimableSettlementFee[loanToken]
rule takeCapturesSettlementFeeReachable(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    address loanToken = offer.market.loanToken;
    mathint claimBefore = ghostMiClaimableSettlementFee256[loanToken];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    satisfy(ghostMiClaimableSettlementFee256[loanToken] > claimBefore,
        "take can capture a positive settlement fee into the claimable pot");
}

//
// withdraw / repay -- core exits, including full-position liveness
//

// RC-MI-04: a lender can actually withdraw: there is a real execution of withdraw that strictly
// reduces the lender's interest-bearing credit balance, proving the basic exit path for deposited
// funds is live.
// FORMULA: satisfy: exists execution of withdraw. credit[onBehalf]' < credit[onBehalf]
rule withdrawReachable(env e, MidnightHarness.Market market, uint256 units, address onBehalf, address receiver) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    mathint creditBefore = ghostMiOnePositionCredit128[onBehalf];
    withdraw(e, market, units, onBehalf, receiver);
    satisfy(ghostMiOnePositionCredit128[onBehalf] < creditBefore, "withdraw is reachable and burns credit");
}

// RC-MI-05: full-exit liveness for lenders: a lender holding a positive credit position can withdraw
// it down to exactly zero in a single call, so deposited funds are never structurally trapped in the
// market.
// FORMULA: satisfy: exists execution of withdraw. credit[onBehalf] > 0 AND credit[onBehalf]' == 0
rule withdrawFullCreditExitReachable(env e, MidnightHarness.Market market, uint256 units, address onBehalf, address receiver) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    require(ghostMiOnePositionCredit128[onBehalf] > 0, "SAFE: lender has a credit position");
    withdraw(e, market, units, onBehalf, receiver);
    satisfy(ghostMiOnePositionCredit128[onBehalf] == 0, "a lender can fully exit their credit position");
}

// RC-MI-06: a borrower can actually repay: there is a real execution of repay that strictly reduces
// the borrower's debt, proving the basic debt-reduction path is live.
// FORMULA: satisfy: exists execution of repay. debt[onBehalf]' < debt[onBehalf]
rule repayReachable(env e, MidnightHarness.Market market, uint256 units, address onBehalf, address callback, bytes data) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    mathint debtBefore = ghostMiOnePositionDebt128[onBehalf];
    repay(e, market, units, onBehalf, callback, data);
    satisfy(ghostMiOnePositionDebt128[onBehalf] < debtBefore, "repay is reachable and reduces debt");
}

// RC-MI-07: full-exit liveness for borrowers: a borrower with positive debt can repay it down to
// exactly zero in a single call, so a debt position can always be fully closed.
// FORMULA: satisfy: exists execution of repay. debt[onBehalf] > 0 AND debt[onBehalf]' == 0
rule repayFullDebtReachable(env e, MidnightHarness.Market market, uint256 units, address onBehalf, address callback, bytes data) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    require(ghostMiOnePositionDebt128[onBehalf] > 0, "SAFE: borrower has a debt position");
    repay(e, market, units, onBehalf, callback, data);
    satisfy(ghostMiOnePositionDebt128[onBehalf] == 0, "a borrower can fully repay their debt");
}

//
// collateral
//

// RC-MI-08: collateral posting is live: a borrower can deposit collateral into a slot that currently
// holds nothing, turning it into an active (non-zero) collateral balance.
// FORMULA: satisfy: exists execution of supplyCollateral. collateral[onBehalf][i] == 0
//          AND collateral[onBehalf][i]' > 0
rule supplyCollateralActivatesSlotReachable(env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 assets, address onBehalf) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    require(ghostMiOnePositionCollateral128[onBehalf][collateralIndex] == 0, "SAFE: slot starts empty");
    supplyCollateral(e, market, collateralIndex, assets, onBehalf);
    satisfy(ghostMiOnePositionCollateral128[onBehalf][collateralIndex] > 0,
        "supplyCollateral can activate a fresh collateral slot");
}

// RC-MI-09: collateral recovery is live: a borrower can execute withdrawCollateral and strictly
// reduce one of their collateral balances (the call only succeeds while the borrower remains
// healthy, so this also shows the health check is not blanket-blocking withdrawals).
// FORMULA: satisfy: exists execution of withdrawCollateral.
//          collateral[onBehalf][i]' < collateral[onBehalf][i]
rule withdrawCollateralReachable(env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 assets, address onBehalf, address receiver) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(onBehalf), "UNSAFE: onBehalf in the narrowed three-user set");
    require(collateralIndex == 0 || collateralIndex == 1, "UNSAFE: two-collateral model");
    mathint collBefore = ghostMiOnePositionCollateral128[onBehalf][collateralIndex];
    withdrawCollateral(e, market, collateralIndex, assets, onBehalf, receiver);
    satisfy(ghostMiOnePositionCollateral128[onBehalf][collateralIndex] < collBefore,
        "withdrawCollateral is reachable and removes collateral");
}

//
// liquidation -- ANTI-VACUITY: the unhealthy / bad-debt / post-maturity paths must be reachable
//

// RC-MI-10: pre-maturity liquidation is live: a liquidator can execute a normal-mode liquidation
// (postMaturityMode = false) that strictly reduces an unhealthy borrower's debt, repaying it in
// exchange for seized collateral.
// FORMULA: satisfy: exists execution of liquidate(postMaturityMode = false).
//          debt[borrower]' < debt[borrower]
rule liquidateNormalModeReachable(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    mathint debtBefore = ghostMiOnePositionDebt128[borrower];
    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, false, receiver, callback, data);
    satisfy(ghostMiOnePositionDebt128[borrower] < debtBefore,
        "a normal-mode liquidation reducing the borrower's debt is reachable");
}

// RC-MI-11: post-maturity liquidation is live: once the market's maturity has passed, a liquidator
// can execute a post-maturity-mode liquidation that strictly reduces the borrower's debt.
// FORMULA: satisfy: exists execution of liquidate(postMaturityMode = true)
//          with block.timestamp > maturity. debt[borrower]' < debt[borrower]
rule liquidatePostMaturityReachable(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    require(e.block.timestamp > market.maturity, "SAFE: post-maturity");
    mathint debtBefore = ghostMiOnePositionDebt128[borrower];
    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, true, receiver, callback, data);
    satisfy(ghostMiOnePositionDebt128[borrower] < debtBefore,
        "a post-maturity liquidation is reachable");
}

// RC-MI-12: bad-debt realization is live: a liquidation can exhaust the borrower's collateral and
// leave a shortfall, strictly increasing the cumulative bad-debt socialization factor (lossFactor)
// that spreads the loss across lenders.
// FORMULA: satisfy: exists execution of liquidate. lossFactor' > lossFactor
rule liquidateRealizesBadDebtReachable(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode, address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    mathint lossFactorBefore = ghostMiOneMarketLossFactor128;
    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);
    satisfy(ghostMiOneMarketLossFactor128 > lossFactorBefore,
        "bad-debt realisation (lossFactor increase) via liquidate must be reachable");
}

// RC-MI-13: insolvency risk is representable: from a valid market state there exists a borrower
// whose collateral value no longer covers their debt, i.e. the protocol's health check can actually
// fail. Without this, no borrower could ever qualify for liquidation and every liquidation property
// would hold trivially.
// FORMULA: satisfy: exists valid state. isHealthy(market, borrower) == false
rule positionCanBeUnhealthy(env e, MidnightHarness.Market market, address borrower) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    bytes32 id = toId(e, market);
    satisfy(!isHealthy(e, market, id, borrower),
        "an unhealthy borrower must be reachable from a valid state (else liquidation rules are vacuous)");
}

//
// fee claims / flash loan / accrual
//

// RC-MI-14: the settlement-fee pot can actually be paid out: the fee claimer can execute
// claimSettlementFee and strictly reduce the per-token pot of trading fees accumulated by the
// protocol.
// FORMULA: satisfy: exists execution of claimSettlementFee.
//          claimableSettlementFee[token]' < claimableSettlementFee[token]
rule claimSettlementFeeReachable(env e, address token, uint256 amount, address receiver) {
    setupValidStateOneMidnight(e);
    mathint claimBefore = ghostMiClaimableSettlementFee256[token];
    claimSettlementFee(e, token, amount, receiver);
    satisfy(ghostMiClaimableSettlementFee256[token] < claimBefore, "claimSettlementFee is reachable and drains the pot");
}

// RC-MI-15: the continuous-fee pot can actually be paid out: the fee claimer can execute
// claimContinuousFee and strictly reduce the continuous-fee credit (cfc), the fee units accrued to
// the protocol from outstanding debt.
// FORMULA: satisfy: exists execution of claimContinuousFee. continuousFeeCredit' < continuousFeeCredit
rule claimContinuousFeeReachable(env e, MidnightHarness.Market market, uint256 amount, address receiver) {
    setupValidStateOneMidnight(e);
    mathint cfcBefore = ghostMiOneMarketContinuousFeeCredit128;
    claimContinuousFee(e, market, amount, receiver);
    satisfy(ghostMiOneMarketContinuousFeeCredit128 < cfcBefore, "claimContinuousFee is reachable and drains the continuous-fee pot");
}

// RC-MI-16: flash loans are live: a flashLoan call can complete with the protocol's token balance
// exactly restored, confirming the zero-fee borrow-and-return path works end to end.
// FORMULA: satisfy: exists execution of flashLoan.
//          balance[token][Midnight]' == balance[token][Midnight]
rule flashLoanReachable(env e, address[] tokens, uint256[] assets, address callback, bytes data, address token) {
    setupValidStateOneMidnight(e);
    mathint balBefore = ghostERC20Balances128[token][_Midnight];
    flashLoan(e, tokens, assets, callback, data);
    satisfy(ghostERC20Balances128[token][_Midnight] == balBefore, "flashLoan is reachable (balances restored, zero fee)");
}

// RC-MI-17: lazy loss socialization is live: touching a position via updatePosition can strictly
// reduce the holder's credit, i.e. bad debt that was previously socialized through the cumulative
// bad-debt socialization factor (lossFactor) can actually be charged to a lender's position when it
// is next touched.
// FORMULA: satisfy: exists execution of updatePosition. credit[user]' < credit[user]
rule updatePositionSlashesCreditReachable(env e, MidnightHarness.Market market, address user) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");
    mathint creditBefore = ghostMiOnePositionCredit128[user];
    updatePosition(e, market, user);
    satisfy(ghostMiOnePositionCredit128[user] < creditBefore,
        "the lazy slash/accrual reducing a position's credit must be reachable");
}

//
// operation chain
//

// RC-MI-18: the full borrow-to-liquidation lifecycle is live end to end: a single scenario exists in
// which a seller takes on positive debt through the take() trade entry point (a buyer fills a
// maker's offer) and that same debt is then strictly reduced by a subsequent liquidation of the
// seller.
// FORMULA: satisfy: exists execution of take; liquidate(borrower = seller).
//          debt[seller]_mid > 0 AND debt[seller]' < debt[seller]_mid
//          where debt[seller]_mid is the seller's debt after take and ' is the state after liquidate
rule borrowThenLiquidateReachable(
    env e,
    MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData,
    uint256 collateralIndex, uint256 seizedAssets, uint256 repaidUnits, bool postMaturityMode,
    address liqReceiver, address liqCallback, bytes liqData
) {
    setupValidStateOneMidnight(e);
    address seller = offer.buy ? taker : offer.maker;
    require(VALID_POSITION_USER(seller), "UNSAFE: seller in the narrowed three-user set");

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint debtAfterTake = ghostMiOnePositionDebt128[seller];

    liquidate(e, offer.market, collateralIndex, seizedAssets, repaidUnits, seller, postMaturityMode, liqReceiver, liqCallback, liqData);

    satisfy(debtAfterTake > 0 && ghostMiOnePositionDebt128[seller] < debtAfterTake,
        "borrow via take then liquidate the resulting debt is reachable end-to-end");
}
