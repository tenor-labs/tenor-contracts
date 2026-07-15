// BorrowMidnightToBlueCallback: one-market, single make-on-behalf scenario.

import "../../setup/callbacks/BorrowMidnightToBlueCallback/one_setup.spec";

use rule feeRecipientNeverLosesTokens;            // CLB-06

// CLB-BMB-06 (CB-DIR-1): new Blue debt implies old Midnight debt drops.
// FORMULA: delta(blueBorrowShares) > 0 => delta(mnDebt) < 0
rule oldMidnightDebtAndNewBlueDebtMoveTogether(env e,
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

    assert(blueSharesAfter > blueSharesBefore => mnDebtAfter < mnDebtBefore,
        "new Blue debt opening implies old Midnight debt drop");
}
