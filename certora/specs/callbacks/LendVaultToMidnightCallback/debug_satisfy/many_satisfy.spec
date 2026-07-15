// LendVaultToMidnightCallback: satisfy-witness twins of the take-based assert rules — each witnesses its parent's assert point reachable (run with rule_sanity:none).

import "../../../setup/callbacks/LendVaultToMidnightCallback/many_setup.spec";
import "../many.spec";

// Shared take-based guards used by LVM (bodies mirror callbacks.spec).

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

// LVM-specific take-based asserts (bodies mirror many.spec CLB-LVM-*).

// CLB-LVM-01 (CB-SRC-1)
rule vaultFundedLendOnlyMovesLoanToken__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyToken) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(anyToken != offer.market.loanToken && ghostERC4626Asset[anyToken] == 0,
        "witness: vaultFundedLendOnlyMovesLoanToken assert-point reachable");
}

// CLB-LVM-02
rule vaultFundedLendLeavesCollateralUnchanged__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true,
        "witness: vaultFundedLendLeavesCollateralUnchanged assert-point reachable");
}

// CLB-LVM-04 (CB-DIR-1)
rule vaultFundedLendNeverTouchesUnrelatedUser__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    bool bystander = anyUser != taker && anyUser != offer.maker;
    mathint debtBefore   = ghostMiPositionDebt128[anyMnId][anyUser];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(bystander,
        "witness: vaultFundedLendNeverTouchesUnrelatedUser assert-point reachable");
}

// CLB-LVM-05 (CB-RATE-2)
rule lenderFeeBoundedByInterestShare__satisfy(env e,
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
        "TRUSTED: feeRecipient is not an ERC-4626 vault (not the source vault either)");
    requireFeeRecipientNarrowings(e, feeRecipient);

    mathint price   = tickToPriceGhost(offer.tick);   // ghostNumTicks==1 => tick == ghostTickOne, price <= WAD
    uint256 feeRate = _Callback.decodeCallbackFeeRate(e, offer.callbackData);   // active payload (takerCallback==0)

    mathint feeBefore = ghostERC20Balances128[loanToken][feeRecipient];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint f = ghostERC20Balances128[loanToken][feeRecipient] - feeBefore;   // == buyerFeeFromTick(...)

    satisfy(true,
        "witness: lenderFeeBoundedByInterestShare assert-point reachable");
}
