// LendMidnightRenewalCallback: many-market, single make-on-behalf scenario.
import "../../setup/callbacks/LendMidnightRenewalCallback/many_setup.spec";

// generic callback guards (bodies in callbacks.spec)
use rule callbackHoldsZeroAllowance;              // CLB-01
use rule thirdPartyBalanceUnchanged;              // CLB-02
use rule callbackNeverHoldsTokens;                // CLB-03
use rule callbackRevertsForNonMidnightCaller;     // CLB-04
use rule callbackRevertsOnZeroAssetsOrUnits;      // CLB-05
use rule feeRecipientNeverLosesTokens;            // CLB-06
use rule buyerTickFeePaidBoundedByUnits;          // CLB-09
use rule positiveFeeIsPayable;                    // CLB-10

// CLB-LMR-01 (CB-DIR-1): a renewal can add credit on at most one market.
// FORMULA: NOT( credit[idA][u]' > credit[idA][u] AND credit[idB][u]' > credit[idB][u] )
// Mutation coverage: the permanent-revert satisfy twin only (no direct-CEX mutation can break this assert).
rule renewalAddsCreditOnAtMostOneMarket(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 idA, bytes32 idB, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(idA != idB, "SAFE: two distinct narrowed markets");

    mathint aBefore = ghostMiPositionCredit128[idA][anyUser];
    mathint bBefore = ghostMiPositionCredit128[idB][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint aAfter = ghostMiPositionCredit128[idA][anyUser];
    mathint bAfter = ghostMiPositionCredit128[idB][anyUser];

    assert(!(aAfter > aBefore && bAfter > bBefore),
        "renewal cannot deposit credit on two markets at once");
}

// CLB-LMR-02 (CB-DIR-1): a renewal can reduce credit on at most one market.
// FORMULA: NOT( credit[idA][u]' < credit[idA][u] AND credit[idB][u]' < credit[idB][u] )
rule renewalReducesCreditOnAtMostOneMarket(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 idA, bytes32 idB, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(idA != idB, "SAFE: two distinct narrowed markets");
    require(VALID_MARKET_MANY(idA) && VALID_MARKET_MANY(idB),
        "SAFE: out-of-scope market id unreachable via Midnight hooks (pin only prunes the solver)");
    require(VALID_POSITION_USER(anyUser),
        "SAFE: out-of-scope position user unreachable via Midnight hooks (pin only prunes the solver)");

    require(ghostMiPositionLastLossFactor128[idA][anyUser] == ghostMiMarketLossFactor128[idA]
        && ghostMiPositionLastLossFactor128[idB][anyUser] == ghostMiMarketLossFactor128[idB],
        "SCOPE: no pending slash (excludes slashing-only credit drop)");
    require(ghostMiPositionPendingFee128[idA][anyUser] == 0
        && ghostMiPositionPendingFee128[idB][anyUser] == 0,
        "SCOPE: no pending continuous-fee accrual");

    mathint aBefore = ghostMiPositionCredit128[idA][anyUser];
    mathint bBefore = ghostMiPositionCredit128[idB][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint aAfter = ghostMiPositionCredit128[idA][anyUser];
    mathint bAfter = ghostMiPositionCredit128[idB][anyUser];

    assert(!(aAfter < aBefore && bAfter < bBefore),
        "renewal cannot redeem credit from two markets at once");
}

// CLB-LMR-03 (CB-SRC-1): a renewal only uses loanToken delivered by the take, never external liquidity.
// FORMULA: delta(balance[loanToken][callback]) <= units
rule renewalCallbackNeverPullsExternalLoanToken(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    address loanToken = offer.market.loanToken;
    mathint cbBalBefore = ghostERC20Balances128[loanToken][_Callback];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint cbBalAfter = ghostERC20Balances128[loanToken][_Callback];

    assert(cbBalAfter - cbBalBefore <= to_mathint(units),
        "callback loanToken inflow bounded by rolled units (no external pull)");
}

// CLB-LMR-04 (CB-DIR-1): a renewal never touches the credit of an unrelated lender.
// FORMULA: u bystander => credit[id][u]' == 0
rule renewalNeverTouchesUnrelatedLenderCredit(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(ghostMiPositionDebt128[anyMnId][anyUser] > 0,
        "SCOPE: anyUser is a real borrower on anyMnId (debt > 0) but a bystander to this lend, so its credit must stay zero");

    bool bystander = anyUser != taker && anyUser != offer.maker;

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(bystander => ghostMiPositionCredit128[anyMnId][anyUser] == 0,
        "bystander lender's credit remains zero");
}

// CLB-LMR-05 (CB-CLOSE-1): a renewal can fully close the migrating lender's old credit position.
// FORMULA: satisfy(credit[srcId][maker]' == 0)  (pre: credit[srcId][maker] > 0, srcId = callbackData.sourceMarket)
rule renewalCanFullyCloseOldCredit(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    bytes32 srcId = _Callback.decodeCallbackSourceMarketId(e, offer.callbackData);
    require(ghostMiPositionCredit128[srcId][offer.maker] > 0,
        "SAFE: the migrating lender holds credit on the source market before the take");

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMiPositionCredit128[srcId][offer.maker] == 0,
        "the renewal can fully close the lender's source-market credit");
}

// CLB-LMR-06: a renewal can roll a lender's credit to a new market while paying a positive fee to the
// feeRecipient -- witnessed by the feeRecipient's loanToken inflow (the real safeTransfer), NOT by a
// credit imbalance (which is fee-blind: tgtGain = zeroFloorSub(units, debt) never exposes the fee).
// FORMULA: satisfy(credit[src]' < credit[src] AND credit[tgt]' > credit[tgt]
//                  AND balance[loanToken][feeRecipient]' > balance[loanToken][feeRecipient])
rule renewalCanMoveCreditWithPositiveFee(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 idSrc, bytes32 idTgt, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(idSrc != idTgt, "SAFE: distinct source/target markets");

    require(ghostMiPositionLastLossFactor128[idSrc][anyUser] == ghostMiMarketLossFactor128[idSrc]
        && ghostMiPositionLastLossFactor128[idTgt][anyUser] == ghostMiMarketLossFactor128[idTgt],
        "SCOPE: no pending slash (otherwise the src credit drop could be a slashing artifact, not the roll)");

    // feeRecipient is the sole sink of the callback fee on loanToken (mirror CLB-06 narrowings).
    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    address loanToken    = offer.market.loanToken;
    address takeBuyer    = offer.buy ? offer.maker : taker;
    address takeSeller   = offer.buy ? taker : offer.maker;
    require(feeRecipient != takeBuyer
         && feeRecipient != takeSeller
         && feeRecipient != offer.callback
         && feeRecipient != takerCallback
         && feeRecipient != _Midnight
         && feeRecipient != receiverIfTakerIsSeller
         && feeRecipient != offer.receiverIfMakerIsSeller,
        "TRUSTED: feeRecipient is neither a take participant/seller-proceeds receiver nor Midnight -- settlement flows would otherwise mix into its loanToken delta");
    require(feeRecipient != e.msg.sender,
        "TRUSTED: feeRecipient != msg.sender -- the buyer-payment flow would otherwise move its balance");
    require(ghostERC4626Asset[feeRecipient] == 0,
        "TRUSTED: feeRecipient is not an ERC-4626 vault -- a share-mint would otherwise move its balance");
    requireFeeRecipientNarrowings(e, feeRecipient);

    mathint srcBefore = ghostMiPositionCredit128[idSrc][anyUser];
    mathint tgtBefore = ghostMiPositionCredit128[idTgt][anyUser];
    mathint feeBefore = ghostERC20Balances128[loanToken][feeRecipient];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint srcAfter = ghostMiPositionCredit128[idSrc][anyUser];
    mathint tgtAfter = ghostMiPositionCredit128[idTgt][anyUser];
    mathint feeAfter = ghostERC20Balances128[loanToken][feeRecipient];

    satisfy(srcAfter < srcBefore && tgtAfter > tgtBefore && feeAfter > feeBefore,
        "renewal can roll a lender's credit to a new market while paying a positive fee to the feeRecipient");
}

// CLB-LMR-07 (CB-FEE-4): at par (price == WAD) with full-value settlement (assets == units) the
// buyer tick fee vanishes (carved from interest, not principal).
// FORMULA: price==WAD && assets==units && !reverted => feeRecipient delta == 0
rule tickFeeVanishesAtPar(env e,
        MidnightHarness.Offer offer, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    require(e.msg.sender == _Midnight, "PROVED: CLB-04 owns the non-Midnight-caller revert");

    uint256 tick = _Callback.decodeCallbackTick(e, data);
    require(VALID_TICK(tick) && ghostNumTicks == 5 && tick == ghostTickFive,
        "SAFE: par tick = top tick ghostTickFive -- only tick whose price can reach WAD under the monotone model (ghostTickOne<...<ghostTickFive<=WAD)");
    require(tickToPriceGhost(tick) == WAD_MATH(), "SCOPE: par tick -- zero discount (price == WAD)");
    require(to_mathint(assets) == to_mathint(units), "SCOPE: full-value settlement at par (no interest)");

    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    require(feeRecipient != _Callback && feeRecipient != _Midnight && feeRecipient != user,
        "TRUSTED: feeRecipient is isolated, so its loanToken delta equals the fee paid");
    requireFeeRecipientNarrowings(e, feeRecipient);

    mathint feeBefore = ghostERC20Balances128[market.loanToken][feeRecipient];
    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);
    mathint feeAfter  = ghostERC20Balances128[market.loanToken][feeRecipient];

    assert(!reverted => feeAfter == feeBefore,
        "no tick fee at par with full-value settlement (fee is purely from interest)");
}

// CLB-LMR-08 (CB-SAME-1): a renewal into the same Midnight market is rejected.
// FORMULA: toId(callbackData.sourceMarket) == marketId => REVERTS (SameMarket)
rule callbackRevertsForSameSourceMarket(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    bytes32 srcId = _Callback.decodeCallbackSourceMarketId(e, data);

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(srcId == id => reverted, "renewal into the same market (sourceMarketId == marketId) is rejected");
}
