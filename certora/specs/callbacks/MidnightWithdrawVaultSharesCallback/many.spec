// MidnightWithdrawVaultSharesCallback (MWV): onBuy vault-share withdraw, single-scenario.

import "../../setup/callbacks/MidnightWithdrawVaultSharesCallback/cmn.spec";

use rule callbackHoldsZeroAllowance;              // CLB-01
use rule thirdPartyBalanceUnchanged;              // CLB-02
use rule callbackNeverHoldsTokens;                // CLB-03
use rule callbackRevertsForNonMidnightCaller;     // CLB-04
use rule callbackRevertsOnZeroAssetsOrUnits;      // CLB-05
// CLB-06 N/A: MWV has no fee.

// CLB-MWV-01 (CB-VAULT-WD-1): a withdraw take can reduce a position's collateral.
// FORMULA: satisfy(collateral[id][u][i]' < collateral[id][u][i])
rule takeCanDropCollateralOnNarrowedMarket(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 id, address u, uint256 i) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint collateralBefore = ghostMiPositionCollateral128[id][u][i];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMiPositionCollateral128[id][u][i] < collateralBefore);
}

// CLB-MWV-02 (CB-VAULT-WD-1): a withdraw take leaves the callback's vault-share balance unchanged
// (onBuy nets the withdrawCollateral share-in against the vault.withdraw share-out).
// FORMULA: vaultToken == collateralParams[0].token => bal[vaultToken][_Callback]' == bal[vaultToken][_Callback]
rule takeLeavesVaultShareBalanceUnchanged(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address vaultToken) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    // WV is a conduit, not a settlement destination (load-bearing anti-self-transfer narrowings; see CLB-03)
    requireReceiverNarrowing(e, offer, receiverIfTakerIsSeller);
    requireCallbackEndpointNarrowings(e, offer);

    require(vaultToken == offer.market.collateralParams[0].token,
        "SCOPE: vaultToken is the market's collateral-vault leg, otherwise an untouched bystander vault would pass vacuously");

    mathint balBefore = ghostERC20Balances128[vaultToken][_Callback];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostERC20Balances128[vaultToken][_Callback] == balBefore,
        "WV.onBuy nets share-in (withdrawCollateral) against share-out (vault.withdraw): vault-share balance unchanged (CB-VAULT-WD-1)");
}
