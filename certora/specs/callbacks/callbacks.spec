// Shared rules for all callbacks

import "../setup/callbacks/callbacks_setup.spec";

// CLB-01 (CB-DUST-1): callback leaves no token approval.
// FORMULA: allowance[t][callback][s] == 0 => allowance[t][callback][s]' == 0
rule callbackHoldsZeroAllowance(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyToken, address anySpender) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(ghostERC20Allowances256[anyToken][_Callback][anySpender] == 0,
        "SAFE: callback holds zero allowance pre-take");

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostERC20Allowances256[anyToken][_Callback][anySpender] == 0,
        "callback leaves no token approval to any spender");
}

// CLB-02: bystander balances unchanged.
// FORMULA: u unrelated to take => balance[t][u]' == balance[t][u]
// Mutation coverage: the permanent-revert satisfy twin only (no direct-CEX mutation can break this assert).
rule thirdPartyBalanceUnchanged(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyUser, address anyToken) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(ghostERC4626Asset[anyToken] == 0 && ghostERC4626Asset[anyUser] == 0,
        "SCOPE: a vault deposit/withdraw would otherwise legitimately move this balance");
    address receiver = offer.buy ? receiverIfTakerIsSeller : offer.receiverIfMakerIsSeller;
    // Tracked Midnight position holders are NOT excluded: the rule also covers leaks to them.
    require(anyUser != _Callback && anyUser != _Midnight && anyUser != e.msg.sender
         && anyUser != offer.maker && anyUser != taker
         && anyUser != offer.callback && anyUser != takerCallback
         && anyUser != receiver,
        "SAFE: anyUser is unrelated to the take");

    requireThirdPartyNarrowings(e, anyUser, offer);

    mathint balBefore = ghostERC20Balances128[anyToken][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint balAfter = ghostERC20Balances128[anyToken][anyUser];

    assert(balAfter == balBefore, "bystander balance untouched by the take");
}

// CLB-03 (CB-DUST-1): a take never leaves the callback holding more tokens than it started (no dust accumulation).
// FORMULA: balance[t][callback]' <= balance[t][callback]
rule callbackNeverHoldsTokens(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyToken) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    requireReceiverNarrowing(e, offer, receiverIfTakerIsSeller);

    requireCallbackEndpointNarrowings(e, offer);

    mathint balanceBefore = ghostERC20Balances128[anyToken][_Callback];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostERC20Balances128[anyToken][_Callback] <= balanceBefore,
        "callback never ends holding more than it started (no dust accumulation; a pre-existing donation may be swept out)");
}

// CLB-04 (CB-AUTH-1): callback rejects non-Midnight callers.
// FORMULA: msg.sender != Midnight => REVERTS
rule callbackRevertsForNonMidnightCaller(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(e.msg.sender != _Midnight => reverted, "callback rejects non-Midnight caller");
}

// CLB-05: callback rejects zero-assets or zero-units.
// FORMULA: (assets == 0 OR units == 0) => REVERTS
rule callbackRevertsOnZeroAssetsOrUnits(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    // onSell is invoked directly, so assets and units are independent -- every zero corner is exercised.
    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert((assets == 0 || units == 0) => reverted,
        "callback rejects a zero-asset or zero-unit invocation");
}

// CLB-06: fee recipient balance never decreases.
// FORMULA: balance[t][feeRecipient]' >= balance[t][feeRecipient]
rule feeRecipientNeverLosesTokens(env e,
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

    mathint balBefore = ghostERC20Balances128[anyToken][feeRecipient];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint balAfter = ghostERC20Balances128[anyToken][feeRecipient];

    assert(balAfter >= balBefore, "fee recipient balance never decreases");
}

// CLB-07 (CB-FEE-3): the flat percentage fee paid never exceeds assets/100 (sharp 1% cap).
// FORMULA: !reverted => 100 * (balance[loanToken][feeRecipient]' - balance) <= assets
rule percentageFeeNeverExceedsAssets(env e,
        MidnightHarness.Offer offer, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    require(feeRecipient != _Callback && feeRecipient != _Midnight && feeRecipient != user,
        "TRUSTED: feeRecipient is isolated, so its loanToken delta equals the fee paid");
    requireFeeRecipientNarrowings(e, feeRecipient);

    mathint feeBefore = ghostERC20Balances128[market.loanToken][feeRecipient];
    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);
    mathint feeAfter  = ghostERC20Balances128[market.loanToken][feeRecipient];

    assert(!reverted => 100 * (feeAfter - feeBefore) <= to_mathint(assets),
        "percentage fee paid <= assets/100 (sharp 1% cap; cannot exceed the principal charged)");
}

// CLB-08 (CB-FEE-1): the seller tick fee paid never exceeds sellerAssets, so the callback's
// `repayBudget = sellerAssets - fee` can never underflow.
// FORMULA: !reverted => balance[loanToken][feeRecipient]' - balance <= sellerAssets
rule sellerTickFeeNeverExceedsAssets(env e,
        MidnightHarness.Offer offer, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    require(feeRecipient != _Callback && feeRecipient != _Midnight && feeRecipient != user,
        "TRUSTED: feeRecipient is isolated, so its loanToken delta equals the fee paid");
    requireFeeRecipientNarrowings(e, feeRecipient);

    mathint feeBefore = ghostERC20Balances128[market.loanToken][feeRecipient];
    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);
    mathint feeAfter  = ghostERC20Balances128[market.loanToken][feeRecipient];

    assert(!reverted => feeAfter - feeBefore <= to_mathint(assets),
        "seller tick fee paid <= sellerAssets (repayBudget = sellerAssets - fee never underflows)");
}

// CLB-09 (CB-FEE-2): the buyer tick fee paid is bounded by the trade size `units`.
// FORMULA: !reverted => balance[loanToken][feeRecipient]' - balance <= units
rule buyerTickFeePaidBoundedByUnits(env e,
        MidnightHarness.Offer offer, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    require(feeRecipient != _Callback && feeRecipient != _Midnight && feeRecipient != user,
        "TRUSTED: feeRecipient is isolated, so its loanToken delta equals the fee paid");
    requireFeeRecipientNarrowings(e, feeRecipient);

    mathint feeBefore = ghostERC20Balances128[market.loanToken][feeRecipient];
    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);
    mathint feeAfter  = ghostERC20Balances128[market.loanToken][feeRecipient];

    assert(!reverted => feeAfter - feeBefore <= to_mathint(units),
        "buyer tick fee paid <= units (carved out of interest, never the full trade)");
}

// CLB-10: a positive fee is actually payable through the callback, so the
// CLB-07/08/09 bounds are not vacuously about a zero fee. Used in every fee-charging callback.
// FORMULA: satisfy( !reverted AND balance[loanToken][feeRecipient]' > balance )
rule positiveFeeIsPayable(env e,
        MidnightHarness.Offer offer, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    require(feeRecipient != _Callback && feeRecipient != _Midnight && feeRecipient != user,
        "TRUSTED: feeRecipient is isolated, so its loanToken delta equals the fee paid");
    requireFeeRecipientNarrowings(e, feeRecipient);

    mathint feeBefore = ghostERC20Balances128[market.loanToken][feeRecipient];
    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);
    mathint feeAfter  = ghostERC20Balances128[market.loanToken][feeRecipient];

    satisfy(!reverted && feeAfter > feeBefore,
        "a positive fee can be charged and paid (CLB-07/08/09 are non-vacuous)");
}
