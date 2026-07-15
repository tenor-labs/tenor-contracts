// MidnightSupplyCollateralCallback: many-market, single make-on-behalf scenario.
import "../../setup/callbacks/MidnightSupplyCollateralCallback/many_setup.spec";

// generic callback guards (bodies in callbacks.spec)
use rule callbackHoldsZeroAllowance;              // CLB-01
use rule thirdPartyBalanceUnchanged;              // CLB-02
use rule callbackNeverHoldsTokens;                // CLB-03
use rule callbackRevertsForNonMidnightCaller;     // CLB-04
use rule callbackRevertsOnZeroAssetsOrUnits;      // CLB-05
// CLB-06 N/A (MSC has no fee recipient).

// CLB-MSC-01: supply take never decreases anyone's collateral.
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

// CLB-MSC-02: supply take leaves bystander collateral/debt/credit untouched.
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

// CLB-MSC-07: callback reverts on amounts[] length mismatching market collaterals.
// FORMULA: amounts.length != market.collateralParams.length => REVERTS
rule collateralLengthMismatchReverts(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    bool differentLength = _Callback.decodeCallbackAmountsLength(e, data) != market.collateralParams.length;

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(differentLength => reverted,
        "callback rejects an amounts[] length mismatch under any caller/inputs (InvalidCollateral)");
}

// CLB-MSC-08: callback reverts on zero offerSellerAssets (fill-fraction denominator).
// FORMULA: offerSellerAssets == 0 => REVERTS
rule offerSellerAssetsZeroReverts(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    bool zeroOfferSellerAssets = _Callback.decodeCallbackOfferSellerAssets(e, data) == 0;

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(zeroOfferSellerAssets => reverted,
        "callback rejects a zero offerSellerAssets under any caller/inputs (ZeroAmount)");
}

// CLB-MSC-09 (CB-DUST-2, InvalidReceiver): supply onSell rejects receiver == the callback itself (proceeds would lock).
// FORMULA: receiver == address(callback) => REVERTS
rule receiverIsCallbackReverts(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    bool receiverIsCallback = receiver == _Callback;

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(receiverIsCallback => reverted,
        "callback rejects receiver == address(this) under any caller/inputs (InvalidReceiver)");
}
