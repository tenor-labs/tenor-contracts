// LendMidnightRenewalCallback: satisfy-witness twins of the take-based assert rules — each witnesses its parent's assert point reachable (run with rule_sanity:none).

import "../../../setup/callbacks/LendMidnightRenewalCallback/many_setup.spec";
import "../many.spec";

// Shared take-based guards used by LMR (bodies mirror callbacks.spec).

// CLB-01 (CB-DUST-1): callback leaves no token approval.
rule callbackHoldsZeroAllowance__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyToken, address anySpender) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(ghostERC20Allowances256[anyToken][_Callback][anySpender] == 0,
        "SAFE: callback holds zero allowance pre-take");

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true,
        "witness: callbackHoldsZeroAllowance assert-point reachable");
}

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

// LMR-specific take-based asserts (bodies mirror many.spec CLB-LMR-*).

// CLB-LMR-01 (CB-DIR-1)
rule renewalAddsCreditOnAtMostOneMarket__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 idA, bytes32 idB, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(idA != idB, "SAFE: two distinct narrowed markets");
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true,
        "witness: renewalAddsCreditOnAtMostOneMarket assert-point reachable");
}

// CLB-LMR-02 (CB-DIR-1)
rule renewalReducesCreditOnAtMostOneMarket__satisfy(env e,
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
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true,
        "witness: renewalReducesCreditOnAtMostOneMarket assert-point reachable");
}

// CLB-LMR-03 (CB-SRC-1)
rule renewalCallbackNeverPullsExternalLoanToken__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    address loanToken = offer.market.loanToken;
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true,
        "witness: renewalCallbackNeverPullsExternalLoanToken assert-point reachable");
}

// CLB-LMR-04 (CB-DIR-1)
rule renewalNeverTouchesUnrelatedLenderCredit__satisfy(env e,
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

    satisfy(bystander,
        "witness: renewalNeverTouchesUnrelatedLenderCredit assert-point reachable");
}

