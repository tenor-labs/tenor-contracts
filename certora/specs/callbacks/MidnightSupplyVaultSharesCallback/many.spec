// MidnightSupplyVaultSharesCallback: many-market, single make-on-behalf scenario.
import "../../setup/callbacks/MidnightSupplyVaultSharesCallback/many_setup.spec";

// generic callback guards (bodies in callbacks.spec)
use rule callbackHoldsZeroAllowance;              // CLB-01
use rule thirdPartyBalanceUnchanged;              // CLB-02
use rule callbackNeverHoldsTokens;                // CLB-03
use rule callbackRevertsForNonMidnightCaller;     // CLB-04
use rule callbackRevertsOnZeroAssetsOrUnits;      // CLB-05
// CLB-06 N/A (MSV has no fee recipient).

// CLB-MSV-01: a supply take never decreases anyone's collateral.
// FORMULA: collateral[id][u][i]' >= collateral[id][u][i]
rule supplyMonotoneCollateral(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(VALID_COLLATERAL_BIT(anyIndex),
        "SAFE: collateral slot within the two-collateral narrowing");

    mathint collateralBefore = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint collateralAfter = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];

    assert(collateralAfter >= collateralBefore,
        "supply take never withdraws collateral");
}

// CLB-MSV-02: a supply take never touches a bystander's collateral, debt, or credit.
// FORMULA: u != taker AND u != maker => collateral/debt/credit[id][u]' == ..[id][u]
rule bystanderUntouched(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(VALID_COLLATERAL_BIT(anyIndex),
        "SAFE: collateral slot within the two-collateral narrowing");

    bool bystander = anyUser != taker && anyUser != offer.maker;

    mathint collateralBefore = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    mathint debtBefore       = ghostMiPositionDebt128[anyMnId][anyUser];
    mathint creditBefore     = ghostMiPositionCredit128[anyMnId][anyUser];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(bystander =>
           (ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex] == collateralBefore
        && ghostMiPositionDebt128[anyMnId][anyUser] == debtBefore
        && ghostMiPositionCredit128[anyMnId][anyUser] == creditBefore),
        "bystander collateral, debt, and credit untouched by the supply take");
}

// CLB-MSV-07 (user-fund safety): zero additionalDepositPercent pulls no loanToken from the seller.
// FORMULA: additionalDepositPercent == 0 => balance[loanToken][seller]' == balance[loanToken][seller]
rule noExtraPullWhenPercentZero(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    address seller = offer.buy ? taker : offer.maker;
    require(e.msg.sender != seller,
        "SAFE: isolate the callback's pull from take's own payer leg (seller is not the take caller)");

    bool zeroPercent = decodeActiveAdditionalDepositPercent(e, offer) == 0;

    mathint sellerLoanBefore = ghostERC20Balances128[offer.market.loanToken][seller];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint sellerLoanAfter = ghostERC20Balances128[offer.market.loanToken][seller];

    assert(zeroPercent => sellerLoanAfter == sellerLoanBefore,
        "callback pulls no extra loanToken from the seller when additionalDepositPercent == 0");
}

// CLB-MSV-08: rejects a vault whose asset() != loanToken.
// FORMULA: vault.asset() != loanToken => REVERTS
rule vaultAssetMismatchReverts(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    address vault = _Callback.decodeCallbackVault(e, data);
    bool assetMismatch = ghostERC4626Asset[vault] != market.loanToken;

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(assetMismatch => reverted,
        "callback unconditionally rejects a vault whose asset() != loanToken (TokenMismatch)");
}

// CLB-MSV-09: rejects a vault not listed at the configured collateral index.
// FORMULA: collateralParams[collateralIndex].token != vault => REVERTS
rule vaultNotAtIndexReverts(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    require(_Callback.decodeCallbackCollateralIndex(e, data) == 0,
        "SAFE: pin the configured slot to index 0 (representative)");
    require(market.collateralParams.length >= 1,
        "SAFE: slot 0 in bounds (define the slot-0 token, not array OOB)");

    address vault = _Callback.decodeCallbackVault(e, data);
    bool slotMismatch = market.collateralParams[0].token != vault;

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(slotMismatch => reverted,
        "callback unconditionally rejects a vault not listed at the collateral index (TokenMismatch)");
}

// CLB-MSV-10 (CB-DUST-1, InvalidReceiver): vault-share supply onSell rejects any receiver other than the callback itself.
// FORMULA: receiver != address(callback) => REVERTS
rule receiverNotCallbackReverts(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    bool receiverNotCallback = receiver != _Callback;

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(receiverNotCallback => reverted,
        "callback unconditionally rejects receiver != address(this) (InvalidReceiver)");
}
