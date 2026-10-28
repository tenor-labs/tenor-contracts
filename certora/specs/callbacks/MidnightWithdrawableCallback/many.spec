// MidnightWithdrawableCallback: many-market take scene, one fill of the callback's par BUY offer.
import "../../setup/callbacks/MidnightWithdrawableCallback/many_setup.spec";

// MWC-06 (CB-DUST-1): every fill leaves the callback without credit, pending fee or debt in any market.
// FORMULA: credit[id][callback]' == 0 AND pendingFee[id][callback]' == 0 AND debt[id][callback]' == 0
rule callbackPositionStaysZero(env e,
        MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData,
        bytes32 anyId) {

    withdrawableTakeSetup(e, offer, units, taker, receiverIfTakerIsSeller, takerCallback);

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostMiPositionCredit128[anyId][_Callback] == 0, "callback credit returns to zero");
    assert(ghostMiPositionPendingFee128[anyId][_Callback] == 0, "callback pending fee returns to zero");
    assert(ghostMiPositionDebt128[anyId][_Callback] == 0, "callback never holds debt");
}

// MWC-07 (CB-DUST-1): every fill leaves the callback with no token approval.
// FORMULA: allowance[t][callback][s]' == 0
rule callbackKeepsZeroAllowance(env e,
        MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData,
        address anyToken, address anySpender) {

    withdrawableTakeSetup(e, offer, units, taker, receiverIfTakerIsSeller, takerCallback);

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostERC20Allowances256[anyToken][_Callback][anySpender] == 0,
        "callback approval is fully spent within the fill");
}

// MWC-08 (CB-DUST-1): a fill never changes the callback's token balances: it withdraws exactly what it pays.
// FORMULA: balance[t][callback]' == balance[t][callback]
rule callbackBalanceUnchanged(env e,
        MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData,
        address anyToken) {

    withdrawableTakeSetup(e, offer, units, taker, receiverIfTakerIsSeller, takerCallback);
    require(receiverIfTakerIsSeller != _Callback,
        "SCOPE: a taker routing its proceeds to the callback is a donation");

    mathint balanceBefore = ghostERC20Balances128[anyToken][_Callback];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostERC20Balances128[anyToken][_Callback] == balanceBefore,
        "callback balance unchanged (pre-existing tokens are never spent)");
}

// MWC-09: every fill consumes exactly `units` of the market's withdrawable.
// FORMULA: withdrawable[id]' == withdrawable[id] - units
rule withdrawableDropsByUnits(env e,
        MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) {

    withdrawableTakeSetup(e, offer, units, taker, receiverIfTakerIsSeller, takerCallback);

    bytes32 id = toId(e, offer.market);
    mathint withdrawableBefore = ghostMiMarketWithdrawable128[id];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostMiMarketWithdrawable128[id] == withdrawableBefore - units, "withdrawable drops by exactly units");
}

// MWC-10: the taker's position moves by exactly `units`, credit first then debt.
// FORMULA: (credit[id][taker] - credit[id][taker]') + (debt[id][taker]' - debt[id][taker]) == units
rule takerPositionShiftsByUnits(env e,
        MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) {

    withdrawableTakeSetup(e, offer, units, taker, receiverIfTakerIsSeller, takerCallback);

    bytes32 id = toId(e, offer.market);
    require(ghostMiPositionLastLossFactor128[id][taker] == ghostMiMarketLossFactor128[id],
        "SCOPE: no pending slash (otherwise the credit drop includes the slash)");
    require(ghostMiPositionPendingFee128[id][taker] == 0,
        "SCOPE: no pending continuous fee (otherwise the credit drop includes the accrual)");

    mathint creditBefore = ghostMiPositionCredit128[id][taker];
    mathint debtBefore = ghostMiPositionDebt128[id][taker];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint creditAfter = ghostMiPositionCredit128[id][taker];
    mathint debtAfter = ghostMiPositionDebt128[id][taker];

    assert(creditAfter <= creditBefore && debtAfter >= debtBefore, "the taker only sells: credit down, debt up");
    assert((creditBefore - creditAfter) + (debtAfter - debtBefore) == to_mathint(units),
        "the taker's position shifts by exactly units");
    assert(debtAfter > debtBefore => creditAfter == 0, "debt only opens once the taker's credit is exhausted");
}

// MWC-11: a fill never touches any position other than the taker's and the callback's.
// FORMULA: u != taker AND u != callback => position[id][u]' == position[id][u]
rule bystanderPositionUnchanged(env e,
        MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData,
        bytes32 anyId, address anyUser) {

    withdrawableTakeSetup(e, offer, units, taker, receiverIfTakerIsSeller, takerCallback);
    require(anyUser != taker && anyUser != _Callback, "SCOPE: anyUser is a bystander to the fill");

    mathint creditBefore = ghostMiPositionCredit128[anyId][anyUser];
    mathint pendingFeeBefore = ghostMiPositionPendingFee128[anyId][anyUser];
    mathint debtBefore = ghostMiPositionDebt128[anyId][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostMiPositionCredit128[anyId][anyUser] == creditBefore, "bystander credit unchanged");
    assert(ghostMiPositionPendingFee128[anyId][anyUser] == pendingFeeBefore, "bystander pending fee unchanged");
    assert(ghostMiPositionDebt128[anyId][anyUser] == debtBefore, "bystander debt unchanged");
}

// MWC-12: Midnight pays out exactly the withdrawable consumed minus the settlement fee it keeps, and the
// receiver gets exactly that amount.
// FORMULA: balance[t][Midnight] - balance[t][Midnight]' == (withdrawable - withdrawable') - (claimable' - claimable)
//          == balance[t][receiver]' - balance[t][receiver]
rule sellerPaidWithdrawableMinusSettlementFee(env e,
        MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) {

    withdrawableTakeSetup(e, offer, units, taker, receiverIfTakerIsSeller, takerCallback);
    require(receiverIfTakerIsSeller != _Midnight && receiverIfTakerIsSeller != _Callback,
        "SCOPE: proceeds leave the protocol and the callback");

    bytes32 id = toId(e, offer.market);
    address loanToken = offer.market.loanToken;
    mathint midnightBefore = ghostERC20Balances128[loanToken][_Midnight];
    mathint receiverBefore = ghostERC20Balances128[loanToken][receiverIfTakerIsSeller];
    mathint withdrawableBefore = ghostMiMarketWithdrawable128[id];
    mathint claimableBefore = ghostMiClaimableSettlementFee256[loanToken];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint sellerAssets = (withdrawableBefore - ghostMiMarketWithdrawable128[id])
        - (ghostMiClaimableSettlementFee256[loanToken] - claimableBefore);

    assert(midnightBefore - ghostERC20Balances128[loanToken][_Midnight] == sellerAssets,
        "Midnight's balance drops by the seller's proceeds only");
    assert(ghostERC20Balances128[loanToken][receiverIfTakerIsSeller] - receiverBefore == sellerAssets,
        "the receiver gets withdrawable consumed minus the settlement fee");
}

// MWC-13 (non-vacuity): a positive fill through the callback is reachable.
// FORMULA: satisfy(withdrawable[id]' < withdrawable[id])
rule positiveFillIsReachable(env e,
        MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) {

    withdrawableTakeSetup(e, offer, units, taker, receiverIfTakerIsSeller, takerCallback);

    bytes32 id = toId(e, offer.market);
    mathint withdrawableBefore = ghostMiMarketWithdrawable128[id];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMiMarketWithdrawable128[id] < withdrawableBefore, "a positive fill through the callback succeeds");
}
