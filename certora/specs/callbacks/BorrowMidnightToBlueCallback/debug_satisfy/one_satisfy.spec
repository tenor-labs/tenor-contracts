// BorrowMidnightToBlueCallback (one-market): satisfy-witness twins of the take-based assert rules — each witnesses its parent's assert point reachable (run with rule_sanity:none).

import "../../../setup/callbacks/BorrowMidnightToBlueCallback/one_setup.spec";
import "../one.spec";

// CLB-BMB-06 (CB-DIR-1): new Blue debt implies old Midnight debt drops.
rule oldMidnightDebtAndNewBlueDebtMoveTogether__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint mnDebtBefore     = ghostMiOnePositionDebt128[anyUser];
    mathint blueSharesBefore = ghostMbOneBorrowShares128[anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint mnDebtAfter      = ghostMiOnePositionDebt128[anyUser];
    mathint blueSharesAfter  = ghostMbOneBorrowShares128[anyUser];

    satisfy(blueSharesAfter > blueSharesBefore,
        "witness: oldMidnightDebtAndNewBlueDebtMoveTogether assert-point reachable");
}
