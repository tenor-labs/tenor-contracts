// MidnightSupplyVaultSharesCallback: one-market, single make-on-behalf scenario.

import "../../setup/callbacks/MidnightSupplyVaultSharesCallback/one_setup.spec";

// CLB-MSV-03: supply lands only on the vault slot (0); other collateral slots untouched.
// FORMULA: i != 0 (the pinned vault slot) => collateral[seller][i]' == collateral[seller][i]
rule onlyVaultSlotReceivesSupply(env e,
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

    address seller = offer.buy ? taker : offer.maker;
    mathint collateralBefore = ghostMiOnePositionCollateral128[seller][anyIndex];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostMiOnePositionCollateral128[seller][anyIndex] == collateralBefore,
        "non-vault collateral slot untouched (supply lands only at the vault slot)");
}

// CLB-MSV-04: every newly minted vault share becomes the seller's collateral.
// FORMULA: delta(collateral[seller][0]) == delta(totalSupply[vault])   (deposit mints shares -> supplyCollateral credits them)
// totalSupply is a faithful proxy for the seller's minted shares only under the setup's fee==0 pin (no fee-share
// minting); with vault fees enabled, bind to the deposit() return instead of totalSupply.
rule suppliedSharesMatchMintedShares(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(decodeActiveAdditionalDepositPercent(e, offer) == 0,
        "UNSAFE: percent==0 share-conservation slice -- the percent>0 path is covered by CLB-MSV-11 for the extra-pull amount only");

    address vault  = decodeActiveVault(e, offer);
    address seller = offer.buy ? taker : offer.maker;

    mathint collateralBefore = ghostMiOnePositionCollateral128[seller][0];
    mathint supplyBefore     = ghostERC20TotalSupply256[vault];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint collateralAfter  = ghostMiOnePositionCollateral128[seller][0];
    mathint supplyAfter      = ghostERC20TotalSupply256[vault];

    assert(collateralAfter - collateralBefore == supplyAfter - supplyBefore,
        "every newly minted vault share becomes the seller's collateral (no share leak)");
}

// CLB-MSV-05: only the seller's vault-share collateral can increase.
// FORMULA: collateral[u][0]' > collateral[u][0] => u == seller
rule vaultShareBeneficiaryIsSeller(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    address seller = offer.buy ? taker : offer.maker;
    mathint collateralBefore = ghostMiOnePositionCollateral128[anyUser][0];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint collateralAfter = ghostMiOnePositionCollateral128[anyUser][0];

    assert(collateralAfter > collateralBefore => anyUser == seller,
        "only the seller's vault-share collateral can increase");
}

// CLB-MSV-06: a vault-deposit supply can actually raise the seller's collateral.
// FORMULA: satisfy(collateral[seller][0]' > collateral[seller][0])
rule supplyCanRaiseVaultCollateral(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(decodeActiveAdditionalDepositPercent(e, offer) == 0,
        "UNSAFE: additionalDepositPercent == 0 slice -- the percent>0 extra-pull path is covered by CLB-MSV-11");

    address seller = offer.buy ? taker : offer.maker;
    mathint collateralBefore = ghostMiOnePositionCollateral128[seller][0];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMiOnePositionCollateral128[seller][0] > collateralBefore,
        "the vault-deposit supply path can raise the seller's collateral");
}

// CLB-MSV-11 (user-fund safety): a positive additionalDepositPercent pulls EXACTLY the formula amount of
//   loanToken from the seller -- the additional-deposit branch CLB-MSV-07 (percent==0, many.spec) leaves at zero.
// FORMULA: additionalDepositPercent > 0
//          => sellerLoan - sellerLoan' == mulDivUp(sellerAssets, additionalDepositPercent, WAD)
rule extraPullMatchesPercentFormula(env e,
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

    mathint percent = decodeActiveAdditionalDepositPercent(e, offer);
    require(percent > 0, "SCOPE: the additional-deposit branch (percent>0); percent==0 is CLB-MSV-07");

    mathint sellerLoanBefore = ghostERC20Balances128[offer.market.loanToken][seller];
    uint256 buyerAssets; uint256 sellerAssets;
    buyerAssets, sellerAssets = take(e, offer, ratifierData, units, taker,
                                     receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint sellerLoanAfter = ghostERC20Balances128[offer.market.loanToken][seller];

    // The base take never touches the seller's loanToken, so the whole delta is the extra pull.
    assert(sellerLoanBefore - sellerLoanAfter
             == (to_mathint(sellerAssets) * percent + WAD_CVL() - 1) / WAD_CVL(),
        "extra loanToken pulled from the seller == mulDivUp(sellerAssets, additionalDepositPercent, WAD)");
}
