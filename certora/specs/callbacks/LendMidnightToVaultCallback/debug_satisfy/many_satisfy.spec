// LendMidnightToVaultCallback: satisfy-witness twins of the take-based assert rules — each witnesses its parent's assert point reachable (run with rule_sanity:none).

import "../../../setup/callbacks/LendMidnightToVaultCallback/many_setup.spec";
import "../many.spec";

// Shared take-based guards used by LMV (bodies mirror callbacks.spec).

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

// LMV-specific take-based asserts (bodies mirror many.spec CLB-LMV-*).

// CLB-LMV-01 (CB-SRC-1)
rule vaultExitConservesMidnightBalanceMinusFee__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyToken) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(anyToken != offer.market.loanToken,
        "SAFE: loanToken excluded -- it is the asset the take settles, so Midnight's loanToken balance is not a fee-only quantity; the equality is proven for every other token");

    mathint balBefore = ghostERC20Balances128[anyToken][_Midnight];
    mathint feeBefore = ghostMiClaimableSettlementFee256[anyToken];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint balAfter = ghostERC20Balances128[anyToken][_Midnight];
    mathint feeAfter = ghostMiClaimableSettlementFee256[anyToken];

    satisfy(ghostERC4626Asset[anyToken] == 0,
        "witness: vaultExitConservesMidnightBalanceMinusFee assert-point reachable");
}

// CLB-LMV-02
rule vaultExitLeavesCollateralUnchanged__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint collateralBefore = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint collateralAfter = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];

    satisfy(true,
        "witness: vaultExitLeavesCollateralUnchanged assert-point reachable");
}

// CLB-LMV-03 (CB-DIR-1)
rule vaultExitNeverTouchesUnrelatedUser__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    bool bystander = anyUser != taker && anyUser != offer.maker;

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(bystander,
        "witness: vaultExitNeverTouchesUnrelatedUser assert-point reachable");
}
