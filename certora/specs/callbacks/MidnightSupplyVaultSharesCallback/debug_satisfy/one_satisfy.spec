// MidnightSupplyVaultSharesCallback (one-market): satisfy-witness twins of the take-based assert rules — each witnesses its parent's assert point reachable (run with rule_sanity:none).

import "../../../setup/callbacks/MidnightSupplyVaultSharesCallback/one_setup.spec";
import "../one.spec";

// CLB-MSV-03
rule onlyVaultSlotReceivesSupply__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(ghostNumCollaterals == 2,
        "UNSAFE: two-collateral model to exercise a non-vault slot (vault pinned at slot 0)");
    require(anyIndex != 0 && VALID_COLLATERAL_BIT(anyIndex),
        "SAFE: a non-vault collateral slot");
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true,
        "witness: onlyVaultSlotReceivesSupply assert-point reachable");
}

// CLB-MSV-04
rule suppliedSharesMatchMintedShares__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(decodeActiveAdditionalDepositPercent(e, offer) == 0,
        "SAFE: no extra pull -- clean headline; share conservation also survives additionalDepositPercent > 0");

    address vault  = decodeActiveVault(e, offer);
    address seller = offer.buy ? taker : offer.maker;
    mathint supplyBefore     = ghostERC20TotalSupply256[vault];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint collateralAfter  = ghostMiOnePositionCollateral128[seller][0];
    mathint supplyAfter      = ghostERC20TotalSupply256[vault];

    satisfy(true,
        "witness: suppliedSharesMatchMintedShares assert-point reachable");
}

// CLB-MSV-05
rule vaultShareBeneficiaryIsSeller__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    mathint collateralBefore = ghostMiOnePositionCollateral128[anyUser][0];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint collateralAfter = ghostMiOnePositionCollateral128[anyUser][0];

    satisfy(collateralAfter > collateralBefore,
        "witness: vaultShareBeneficiaryIsSeller assert-point reachable");
}

// CLB-MSV-11
rule extraPullMatchesPercentFormula__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    address seller = offer.buy ? taker : offer.maker;
    require(e.msg.sender != seller,
        "SAFE: isolate the callback's pull from take's own payer leg (seller is not the take caller)");
    require(seller != _Callback && seller != _VaultV2 && seller != _Midnight,
        "SAFE: seller is a plain external account (no self-transfer aliasing of the extra pull)");
    require(decodeActiveAdditionalDepositPercent(e, offer) > 0,
        "SCOPE: witness the additional-deposit branch (percent>0)");

    mathint sellerLoanBefore = ghostERC20Balances128[offer.market.loanToken][seller];
    uint256 buyerAssets; uint256 sellerAssets;
    buyerAssets, sellerAssets = take(e, offer, ratifierData, units, taker,
                                     receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint sellerLoanAfter = ghostERC20Balances128[offer.market.loanToken][seller];

    satisfy(sellerLoanBefore > sellerLoanAfter,
        "witness: a positive additionalDepositPercent actually pulls loanToken from the seller");
}
