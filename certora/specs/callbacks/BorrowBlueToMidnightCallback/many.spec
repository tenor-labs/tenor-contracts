// BorrowBlueToMidnightCallback: many-market, single make-on-behalf scenario.
import "../../setup/callbacks/BorrowBlueToMidnightCallback/many_setup.spec";

// generic callback guards (bodies in callbacks.spec)
use rule thirdPartyBalanceUnchanged;              // CLB-02
use rule callbackNeverHoldsTokens;                // CLB-03
use rule callbackRevertsForNonMidnightCaller;     // CLB-04
use rule callbackRevertsOnZeroAssetsOrUnits;      // CLB-05
use rule feeRecipientNeverLosesTokens;            // CLB-06
use rule sellerTickFeeNeverExceedsAssets;         // CLB-08
use rule positiveFeeIsPayable;                    // CLB-10

// CLB-BBM-01 (CB-V1-REP-1): migration can only reduce the old debt, never increase it.
// FORMULA: blueBorrowShares[id][u]' <= blueBorrowShares[id][u]
rule migrationOnlyReducesOldBlueDebt(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint sharesBefore = ghostMbBorrowShares128[anyBlueId][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint sharesAfter = ghostMbBorrowShares128[anyBlueId][anyUser];

    assert(sharesAfter <= sharesBefore, "old Blue borrow shares never grow");
}

// CLB-BBM-02 (CB-DIR-1): migration can only withdraw old collateral, never add to it.
// FORMULA: blueCollateral[id][u]' <= blueCollateral[id][u]
rule migrationOnlyWithdrawsOldBlueCollateral(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint colBefore = ghostMbCollateral128[anyBlueId][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint colAfter = ghostMbCollateral128[anyBlueId][anyUser];

    assert(colAfter <= colBefore, "old Blue collateral never grows");
}

// CLB-BBM-03 (CB-DIR-1): one migration can reduce old debt on at most one market.
// FORMULA: NOT( blueBorrowShares[idA][u]' < blueBorrowShares[idA][u] AND blueBorrowShares[idB][u]' < blueBorrowShares[idB][u] )
// Mutation coverage: the permanent-revert satisfy twin only (no direct-CEX mutation can break this assert).
rule migrationReducesOldDebtOnAtMostOneMarket(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id blueIdA, MorphoHarness.Id blueIdB, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(blueIdA != blueIdB, "SAFE: two distinct Blue market ids");

    mathint aBefore = ghostMbBorrowShares128[blueIdA][anyUser];
    mathint bBefore = ghostMbBorrowShares128[blueIdB][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint aAfter = ghostMbBorrowShares128[blueIdA][anyUser];
    mathint bAfter = ghostMbBorrowShares128[blueIdB][anyUser];

    assert(!(aAfter < aBefore && bAfter < bBefore),
        "old debt cannot drop on two Blue markets at once");
}

// CLB-BBM-04 (CB-FINAL-2): clearing the last of the old debt also empties the old collateral.
// FORMULA: blueBorrowShares[id][u] > 0 AND blueBorrowShares[id][u]' == 0 AND blueCollateral[id][u] > 0
// FORMULA:   => blueCollateral[id][u]' == 0
rule clearingOldDebtAlsoEmptiesOldCollateral(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint sharesBefore = ghostMbBorrowShares128[anyBlueId][anyUser];
    mathint colBefore = ghostMbCollateral128[anyBlueId][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint sharesAfter = ghostMbBorrowShares128[anyBlueId][anyUser];
    mathint colAfter = ghostMbCollateral128[anyBlueId][anyUser];

    assert(sharesBefore > 0 && sharesAfter == 0 && colBefore > 0 => colAfter == 0,
        "clearing last debt also drains the collateral");
}

// CLB-BBM-05 (CB-DIR-1): migration only adds new collateral, never removes it.
// FORMULA: mnCollateral[id][u][i]' >= mnCollateral[id][u][i]
rule migrationOnlyAddsNewMidnightCollateral(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint colBefore = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint colAfter = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];

    assert(colAfter >= colBefore, "new Midnight collateral never shrinks");
}

// CLB-BBM-06 (CB-DIR-1): collateral out of old Blue == collateral into new Midnight (1:1).
// FORMULA: blueCollateral[id][u] - blueCollateral[id][u]'  ==  mnCollateral[mnId][u][i]' - mnCollateral[mnId][u][i]
//          (when blueCollateral[id][u]' < blueCollateral[id][u] AND mnCollateral[mnId][u][i]' > mnCollateral[mnId][u][i])
rule migrationConservesMigratedCollateral(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint blueColBefore = ghostMbCollateral128[anyBlueId][anyUser];
    mathint mnColBefore = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint blueColAfter = ghostMbCollateral128[anyBlueId][anyUser];
    mathint mnColAfter = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];

    assert(blueColAfter < blueColBefore && mnColAfter > mnColBefore
        => blueColBefore - blueColAfter == mnColAfter - mnColBefore,
        "collateral out of Blue == collateral into Midnight");
}

// CLB-BBM-07: a migration can actually move collateral from the old position to the new one.
// FORMULA: satisfy(blueCollateral[id][u]' < blueCollateral[id][u] AND mnCollateral[id][u][i]' > mnCollateral[id][u][i])
rule migrationCanMoveCollateralBlueToMidnight(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint blueColBefore = ghostMbCollateral128[anyBlueId][anyUser];
    mathint mnColBefore = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint blueColAfter = ghostMbCollateral128[anyBlueId][anyUser];
    mathint mnColAfter = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];

    satisfy(blueColAfter < blueColBefore && mnColAfter > mnColBefore,
        "migration can actually move collateral Blue->Midnight");
}

// CLB-BBM-08 (CB-CLOSE-1): a migration can fully close the old position (both debt and collateral go to zero).
// FORMULA: satisfy(blueBorrowShares[id][u]' == 0 AND blueCollateral[id][u]' == 0)  (pre: both > 0)
rule migrationCanFullyCloseOldPosition(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(ghostMbBorrowShares128[anyBlueId][anyUser] > 0,
        "SAFE: positive Blue debt before");
    require(ghostMbCollateral128[anyBlueId][anyUser] > 0,
        "SAFE: positive Blue collateral before");

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMbBorrowShares128[anyBlueId][anyUser] == 0
        && ghostMbCollateral128[anyBlueId][anyUser] == 0,
        "old Blue position can be fully closed");
}

// CLB-BBM-09 (CB-RATE-1): the borrower's callback fee never exceeds feeRate applied to the interest
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

    // mirrors CLB-06 narrowings
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

    mathint price   = tickToPriceGhost(offer.tick);   // price <= WAD under the tick model
    uint256 feeRate = _Callback.decodeCallbackFeeRate(e, offer.callbackData);   // active payload (takerCallback==0)

    mathint feeBefore = ghostERC20Balances128[loanToken][feeRecipient];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint f = ghostERC20Balances128[loanToken][feeRecipient] - feeBefore;   // == sellerFeeFromTick(...)

    assert(f * WAD_CVL() * WAD_CVL()
             <= to_mathint(units) * (WAD_CVL() - price) * to_mathint(feeRate) + WAD_CVL() * WAD_CVL(),
        "borrower callback fee bounded by feeRate * interest => effective rate <= (1+feeRate) * offer rate");
}

// CLB-BBM-10 (CB-FEE-4): at par (price == WAD) with full-value settlement (assets == units) the
// seller tick fee vanishes.
// FORMULA: price==WAD && assets==units && !reverted => feeRecipient delta == 0
rule tickFeeVanishesAtPar(env e,
        MidnightHarness.Offer offer, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    uint256 tick = _Callback.decodeCallbackTick(e, data);
    require(VALID_TICK(tick) && ghostNumTicks == 5 && tick == ghostTickFive,
        "SAFE: top tick ghostTickFive -- only tick whose price can reach WAD under the monotone model");
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

// CLB-BBM-11 (CB-CLOSE-2): repaying expectedBorrowAssets(seller) clears all V1 borrow shares.
// FORMULA: blueCollateral[id][u] > 0 AND blueCollateral[id][u]' == 0 AND blueBorrowShares[id][u] > 0
// FORMULA:   => blueBorrowShares[id][u]' == 0
// Mutation coverage: contrapositive of Blue's isHealthy guard (unmutated code shields the assert); kill channel is the satisfy twin (BBM#12).
rule fullCollateralMigrationClearsAllOldDebt(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint sharesBefore = ghostMbBorrowShares128[anyBlueId][anyUser];
    mathint colBefore    = ghostMbCollateral128[anyBlueId][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint sharesAfter = ghostMbBorrowShares128[anyBlueId][anyUser];
    mathint colAfter    = ghostMbCollateral128[anyBlueId][anyUser];

    assert(sharesBefore > 0 && colBefore > 0 && colAfter == 0 => sharesAfter == 0,
        "full collateral migration leaves no borrow-share dust (CB-CLOSE-2)");
}

// CLB-BBM-12 (CB-DUST-1, InvalidReceiver): migration onSell rejects any receiver other than the callback itself.
// FORMULA: receiver != address(callback) => REVERTS
rule receiverNotCallbackReverts(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    bool receiverNotCallback = receiver != _Callback;

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(receiverNotCallback => reverted,
        "callback rejects receiver != address(this) (InvalidReceiver)");
}

// CLB-BBM-13 (CB-SRC-1, TokenMismatch): onSell rejects a source Blue market whose loanToken != offer loanToken.
// FORMULA: sourceMarketParams.loanToken != market.loanToken => REVERTS
rule sourceLoanTokenMismatchReverts(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    bool loanTokenMismatch = _Callback.decodeCallbackSourceLoanToken(e, data) != market.loanToken;

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(loanTokenMismatch => reverted,
        "callback rejects a source market whose loanToken != offer loanToken (TokenMismatch)");
}
