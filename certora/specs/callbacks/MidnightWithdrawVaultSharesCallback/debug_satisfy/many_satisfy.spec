// MidnightWithdrawVaultSharesCallback: satisfy-witness twins of the take-based assert rules — each witnesses its parent's assert point reachable (run with rule_sanity:none).

import "../../../setup/callbacks/MidnightWithdrawVaultSharesCallback/cmn.spec";
import "../many.spec";

// Shared take-based guards used by MWV (bodies mirror callbacks.spec).

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

// MWV-specific take-based assert (body mirrors many.spec CLB-MWV-02).

// CLB-MWV-02 (CB-VAULT-WD-1)
rule takeLeavesVaultShareBalanceUnchanged__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address vaultToken) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    requireReceiverNarrowing(e, offer, receiverIfTakerIsSeller);
    requireCallbackEndpointNarrowings(e, offer);

    require(vaultToken == offer.market.collateralParams[0].token,
        "SCOPE: vaultToken is the market's collateral-vault leg, otherwise an untouched bystander vault would pass vacuously");
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true,
        "witness: takeLeavesVaultShareBalanceUnchanged assert-point reachable");
}
