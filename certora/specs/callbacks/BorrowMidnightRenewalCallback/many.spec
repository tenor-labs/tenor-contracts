// BorrowMidnightRenewalCallback: many-market, single make-on-behalf scenario.
// NOTE: migrating party is the seller (onSell), resolved via migratingSeller().
import "../../setup/callbacks/BorrowMidnightRenewalCallback/many_setup.spec";

// generic callback guards (bodies in callbacks.spec)
use rule callbackHoldsZeroAllowance;              // CLB-01
use rule thirdPartyBalanceUnchanged;              // CLB-02
use rule callbackNeverHoldsTokens;                // CLB-03
use rule callbackRevertsForNonMidnightCaller;     // CLB-04
use rule callbackRevertsOnZeroAssetsOrUnits;      // CLB-05
use rule feeRecipientNeverLosesTokens;            // CLB-06
use rule sellerTickFeeNeverExceedsAssets;         // CLB-08
use rule positiveFeeIsPayable;                    // CLB-10

function migratingSeller(MidnightHarness.Offer offer, address taker) returns address {
    return offer.buy ? taker : offer.maker;
}

// CLB-BMR-01 (CB-DIR-1): one renewal can reduce debt on at most one market.
// FORMULA: NOT( mnDebt[idA][u]' < mnDebt[idA][u] AND mnDebt[idB][u]' < mnDebt[idB][u] )
rule renewalReducesDebtOnAtMostOneMarket(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 idA, bytes32 idB, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(idA != idB, "SAFE: two distinct narrowed markets");
    require(anyUser == migratingSeller(offer, taker), "SAFE: onSell only writes the seller position");

    mathint aBefore = ghostMiPositionDebt128[idA][anyUser];
    mathint bBefore = ghostMiPositionDebt128[idB][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint aAfter = ghostMiPositionDebt128[idA][anyUser];
    mathint bAfter = ghostMiPositionDebt128[idB][anyUser];

    assert(!(aAfter < aBefore && bAfter < bBefore),
        "renewal cannot repay debt on two markets at once");
}

// CLB-BMR-02 (CB-DIR-1): one renewal can add debt on at most one market.
// FORMULA: NOT( mnDebt[idA][u]' > mnDebt[idA][u] AND mnDebt[idB][u]' > mnDebt[idB][u] )
rule renewalAddsDebtOnAtMostOneMarket(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 idA, bytes32 idB, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(idA != idB, "SAFE: two distinct narrowed markets");
    require(anyUser == migratingSeller(offer, taker), "SAFE: onSell only writes the seller position");

    mathint aBefore = ghostMiPositionDebt128[idA][anyUser];
    mathint bBefore = ghostMiPositionDebt128[idB][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint aAfter = ghostMiPositionDebt128[idA][anyUser];
    mathint bAfter = ghostMiPositionDebt128[idB][anyUser];

    assert(!(aAfter > aBefore && bAfter > bBefore),
        "renewal cannot open debt on two markets at once");
}

// CLB-BMR-03 (CB-DIR-1): in a market where renewal reduces debt, collateral cannot rise.
// FORMULA: mnDebt[id][u]' < mnDebt[id][u] => mnCollateral[id][u][i]' <= mnCollateral[id][u][i]
rule renewalCannotAddCollateralWhenReducingDebt(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 id, address u, uint256 i) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(u == migratingSeller(offer, taker), "SAFE: onSell only writes the seller position");
    mathint debtBefore = ghostMiPositionDebt128[id][u];
    mathint colBefore = ghostMiPositionCollateral128[id][u][i];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint debtAfter = ghostMiPositionDebt128[id][u];
    mathint colAfter = ghostMiPositionCollateral128[id][u][i];

    assert(debtAfter < debtBefore => colAfter <= colBefore,
        "repaying debt does not add collateral on the same market");
}

// CLB-BMR-04 (CB-DIR-1): in a market where renewal opens debt, collateral cannot drop.
// FORMULA: mnDebt[id][u]' > mnDebt[id][u] => mnCollateral[id][u][i]' >= mnCollateral[id][u][i]
rule renewalCannotRemoveCollateralWhenOpeningDebt(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 id, address u, uint256 i) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(u == migratingSeller(offer, taker), "SAFE: onSell only writes the seller position");
    mathint debtBefore = ghostMiPositionDebt128[id][u];
    mathint colBefore = ghostMiPositionCollateral128[id][u][i];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint debtAfter = ghostMiPositionDebt128[id][u];
    mathint colAfter = ghostMiPositionCollateral128[id][u][i];

    assert(debtAfter > debtBefore => colAfter >= colBefore,
        "opening debt does not pull collateral out on the same market");
}

// CLB-BMR-05 (CB-SRC-1): renewal only uses take-delivered loanToken, never external.
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
        "no external loanToken pulled into BMR");
}

// CLB-BMR-06 (CB-FINAL-4): collateral moved to new position bounded by what old released.
// FORMULA: srcColOut > 0 AND tgtColIn > 0 => tgtColIn <= srcColOut  (same collateral token)
// FORMULA:   (srcColOut = collateral[src] - collateral[src]', tgtColIn = collateral[tgt]' - collateral[tgt])
rule renewalCannotMoveMoreCollateralThanWithdrawn(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 idSrc, bytes32 idTgt, uint256 i, uint256 j) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(idSrc != idTgt, "SAFE: distinct source/target markets");
    require(ghostMiMarketCollateralToken[idSrc][i] == ghostMiMarketCollateralToken[idTgt][j],
        "SAFE: same-token slot pair (CTL routes per-token via findCollateral)");

    address migratingUser = migratingSeller(offer, taker);
    mathint srcColBefore = ghostMiPositionCollateral128[idSrc][migratingUser][i];
    mathint tgtColBefore = ghostMiPositionCollateral128[idTgt][migratingUser][j];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint srcColAfter = ghostMiPositionCollateral128[idSrc][migratingUser][i];
    mathint tgtColAfter = ghostMiPositionCollateral128[idTgt][migratingUser][j];

    assert(srcColAfter < srcColBefore && tgtColAfter > tgtColBefore
        => srcColBefore - srcColAfter >= tgtColAfter - tgtColBefore,
        "new collateral inflow bounded by old collateral outflow (same token)");
}

// CLB-BMR-07: renewal can move debt source->target.
// FORMULA: satisfy(mnDebt[src][u]' < mnDebt[src][u] AND mnDebt[tgt][u]' > mnDebt[tgt][u])
rule renewalCanMoveDebtBetweenMarkets(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 idSrc, bytes32 idTgt, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(idSrc != idTgt, "SAFE: distinct source/target markets");

    mathint srcBefore = ghostMiPositionDebt128[idSrc][anyUser];
    mathint tgtBefore = ghostMiPositionDebt128[idTgt][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMiPositionDebt128[idSrc][anyUser] < srcBefore
        && ghostMiPositionDebt128[idTgt][anyUser] > tgtBefore,
        "renewal can actually roll debt source->target");
}

// CLB-BMR-08: renewal can migrate collateral source->target.
// FORMULA: satisfy(mnCollateral[src][u][i]' < mnCollateral[src][u][i] AND mnCollateral[tgt][u][j]' > mnCollateral[tgt][u][j])
rule renewalCanMigrateCollateralBetweenMarkets(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 idSrc, bytes32 idTgt, address anyUser, uint256 i, uint256 j) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(idSrc != idTgt, "SAFE: distinct source/target markets");

    mathint srcColBefore = ghostMiPositionCollateral128[idSrc][anyUser][i];
    mathint tgtColBefore = ghostMiPositionCollateral128[idTgt][anyUser][j];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint srcColAfter = ghostMiPositionCollateral128[idSrc][anyUser][i];
    mathint tgtColAfter = ghostMiPositionCollateral128[idTgt][anyUser][j];

    satisfy(srcColAfter < srcColBefore && tgtColAfter > tgtColBefore,
        "renewal can actually move collateral source->target");
}

// CLB-BMR-09 (CB-CLOSE-1): renewal can fully close the old position.
// FORMULA: satisfy(mnDebt[src][u]' == 0 AND mnCollateral[src][u][i]' == 0)  (pre: both > 0)
rule renewalCanFullyCloseOldPosition(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 idSrc, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(ghostMiPositionDebt128[idSrc][anyUser] > 0,
        "SAFE: positive source debt before");
    require(ghostMiPositionCollateral128[idSrc][anyUser][anyIndex] > 0,
        "SAFE: positive source collateral slot before");

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMiPositionDebt128[idSrc][anyUser] == 0
        && ghostMiPositionCollateral128[idSrc][anyUser][anyIndex] == 0,
        "source position can be fully closed (debt + slot collateral)");
}

// CLB-BMR-10 (CB-RATE-1): the borrower's callback fee never exceeds feeRate applied to the interest
// portion of the trade, so the effective seller rate stays within (1 + feeRate/WAD) of the offer rate.
// FORMULA: f*WAD^2 <= units*(WAD - price)*feeRate (+ one-unit ceil/mulDivUp rounding slack)
rule borrowerFeeBoundedByInterestShare(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    address loanToken    = offer.market.loanToken;

    // feeRecipient is the sole sink of the callback fee on loanToken (mirror CLB-06 narrowings).
    address takeBuyer  = offer.buy ? offer.maker : taker;
    address takeSeller = offer.buy ? taker : offer.maker;
    require(feeRecipient != takeBuyer
         && feeRecipient != takeSeller
         && feeRecipient != offer.callback
         && feeRecipient != takerCallback
         && feeRecipient != _Midnight
         && feeRecipient != receiverIfTakerIsSeller
         && feeRecipient != offer.receiverIfMakerIsSeller,
        "TRUSTED: feeRecipient is neither a take participant/seller-proceeds receiver nor Midnight (isolates the fee on loanToken)");
    require(feeRecipient != e.msg.sender,
        "TRUSTED: feeRecipient != msg.sender (buyer-payment flow is orthogonal to fee accrual)");
    require(ghostERC4626Asset[feeRecipient] == 0,
        "TRUSTED: feeRecipient is not an ERC-4626 vault");
    requireFeeRecipientNarrowings(e, feeRecipient);

    mathint price   = tickToPriceGhost(offer.tick);   // ghostNumTicks==1 => tick == ghostTickOne, price <= WAD
    uint256 feeRate = _Callback.decodeCallbackFeeRate(e, offer.callbackData);   // active payload (takerCallback==0)

    mathint feeBefore = ghostERC20Balances128[loanToken][feeRecipient];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint f = ghostERC20Balances128[loanToken][feeRecipient] - feeBefore;   // == sellerFeeFromTick(...)

    assert(f * WAD_CVL() * WAD_CVL()
             <= to_mathint(units) * (WAD_CVL() - price) * to_mathint(feeRate) + WAD_CVL() * WAD_CVL(),
        "borrower callback fee bounded by feeRate * interest => effective rate <= (1+feeRate) * offer rate");
}

// CLB-BMR-11 (CB-FEE-4): at par (price == WAD) with full-value settlement (assets == units) the
// seller tick fee vanishes (carved from interest, not principal).
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
        "no tick fee at par with full-value settlement (fee is purely from interest)");}

// CLB-BMR-12 (CB-SAME-1): a renewal into the same Midnight market is rejected.
// FORMULA: toId(callbackData.sourceMarket) == marketId => REVERTS (SameMarket)
rule callbackRevertsForSameSourceMarket(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    bytes32 srcId = _Callback.decodeCallbackSourceMarketId(e, data);

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(srcId == id => reverted, "renewal into the same market (sourceMarketId == marketId) is rejected");
}

// CLB-BMR-13 (CB-DUST-1, InvalidReceiver): renewal onSell rejects any receiver other than the callback itself.
// FORMULA: receiver != address(callback) => REVERTS
rule receiverNotCallbackReverts(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    bool receiverNotCallback = receiver != _Callback;

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(receiverNotCallback => reverted,
        "callback unconditionally rejects receiver != address(this) (InvalidReceiver)");
}
