// BorrowBlueToMidnightCallback: satisfy-witness twins of the take-based assert rules — each witnesses its parent's assert point reachable (run with rule_sanity:none).

import "../../../setup/callbacks/BorrowBlueToMidnightCallback/many_setup.spec";
import "../many.spec";

// Shared take-based guards used by BBM (bodies mirror callbacks.spec).

// CLB-02: bystander balances unchanged.
rule thirdPartyBalanceUnchanged__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyUser, address anyToken) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(ghostERC4626Asset[anyToken] == 0 && ghostERC4626Asset[anyUser] == 0,
        "SCOPE: a vault deposit/withdraw would otherwise legitimately move this balance");
    address receiver = offer.buy ? receiverIfTakerIsSeller : offer.receiverIfMakerIsSeller;
    require(anyUser != _Callback && anyUser != _Midnight && anyUser != e.msg.sender
         && anyUser != offer.maker && anyUser != taker
         && anyUser != offer.callback && anyUser != takerCallback
         && anyUser != receiver,
        "SAFE: anyUser is unrelated to the take");

    requireThirdPartyNarrowings(e, anyUser, offer);
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true, "witness: thirdPartyBalanceUnchanged assert-point reachable");
}

// CLB-03 (CB-DUST-1): callback retains no tokens after take.
rule callbackNeverHoldsTokens__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyToken) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    requireReceiverNarrowing(e, offer, receiverIfTakerIsSeller);

    requireCallbackEndpointNarrowings(e, offer);

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true,
        "witness: callbackNeverHoldsTokens assert-point reachable");
}

// CLB-06: fee recipient balance never decreases.
rule feeRecipientNeverLosesTokens__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyToken) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    address feeRecipient = decodeActiveFeeRecipient(e, offer);

    address takeBuyer  = offer.buy ? offer.maker : taker;
    address takeSeller = offer.buy ? taker : offer.maker;
    require(feeRecipient != takeBuyer
         && feeRecipient != takeSeller
         && feeRecipient != offer.callback
         && feeRecipient != takerCallback
         && feeRecipient != _Midnight,
        "TRUSTED: feeRecipient is not a take participant nor Midnight");
    require(feeRecipient != e.msg.sender,
        "TRUSTED: feeRecipient != msg.sender (buyer-payment flow is orthogonal to fee accrual)");
    require(ghostERC4626Asset[feeRecipient] == 0,
        "TRUSTED: feeRecipient is not an ERC-4626 vault");

    requireFeeRecipientNarrowings(e, feeRecipient);
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true, "witness: feeRecipientNeverLosesTokens assert-point reachable");
}

// BBM-specific take-based asserts (bodies mirror many.spec CLB-BBM-*).

// CLB-BBM-01 (CB-V1-REP-1)
rule migrationOnlyReducesOldBlueDebt__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true, "witness: migrationOnlyReducesOldBlueDebt assert-point reachable");
}

// CLB-BBM-02 (CB-DIR-1)
rule migrationOnlyWithdrawsOldBlueCollateral__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true, "witness: migrationOnlyWithdrawsOldBlueCollateral assert-point reachable");
}

// CLB-BBM-03 (CB-DIR-1)
rule migrationReducesOldDebtOnAtMostOneMarket__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id blueIdA, MorphoHarness.Id blueIdB, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(blueIdA != blueIdB, "SAFE: two distinct Blue market ids");
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true,
        "witness: migrationReducesOldDebtOnAtMostOneMarket assert-point reachable");
}

// CLB-BBM-04 (CB-FINAL-2)
rule clearingOldDebtAlsoEmptiesOldCollateral__satisfy(env e,
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

    satisfy(sharesBefore > 0 && sharesAfter == 0 && colBefore > 0,
        "witness: clearingOldDebtAlsoEmptiesOldCollateral assert-point reachable");
}

// CLB-BBM-05 (CB-DIR-1)
rule migrationOnlyAddsNewMidnightCollateral__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true, "witness: migrationOnlyAddsNewMidnightCollateral assert-point reachable");
}

// CLB-BBM-06 (CB-DIR-1)
rule migrationConservesMigratedCollateral__satisfy(env e,
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
        "witness: migrationConservesMigratedCollateral assert-point reachable");
}

// CLB-BBM-09 (CB-RATE-1)
rule borrowerFeeBoundedByInterestShare__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    address loanToken    = offer.market.loanToken;

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

    mathint price   = tickToPriceGhost(offer.tick);
    uint256 feeRate = _Callback.decodeCallbackFeeRate(e, offer.callbackData);
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true,
        "witness: borrowerFeeBoundedByInterestShare assert-point reachable");
}

// CLB-BBM-11 (CB-CLOSE-2)
rule fullCollateralMigrationClearsAllOldDebt__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint sharesBefore = ghostMbBorrowShares128[anyBlueId][anyUser];
    mathint colBefore    = ghostMbCollateral128[anyBlueId][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint colAfter    = ghostMbCollateral128[anyBlueId][anyUser];

    satisfy(sharesBefore > 0 && colBefore > 0 && colAfter == 0,
        "witness: fullCollateralMigrationClearsAllOldDebt assert-point reachable");
}
