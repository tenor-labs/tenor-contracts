import "../../../callbacks/callbacks.spec";

using MidnightSupplyCollateralCallbackHarness as _Callback;

definition ORACLE_PRICE_SCALE_CVL() returns mathint = 1000000000000000000000000000000000000; // 1e36

methods {
    function _.onSell(bytes32, MidnightHarness.Market, uint256, uint256, uint256, address, address, bytes) external
        => DISPATCHER(true);
}

function setupMigrationRatifier(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    require(offer.buy == false,          "SCOPE: maker-side flow (maker is seller; MSC.onSell fires on maker=seller)");
    require(offer.callback == _Callback, "TRUSTED: MSC is the activated maker(sell)-side callback");
    require(takerCallback == 0,          "SCOPE: single-sided maker scenario excludes taker callback");

    require(_Callback.decodeCallbackOfferSellerAssets(e, offer.callbackData) == offer.maxAssets,
        "TRUSTED: maker-set, not enforced on-chain -- offerSellerAssets == offer.maxAssets (fill-fraction denominator)");
    require(_Callback.decodeCallbackAmountsLength(e, offer.callbackData) == ghostNumCollaterals,
        "SAFE: a length mismatch reverts InvalidCollateral (proven by CLB-MSC-07)");
}

function callbackCallWithRevert(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) returns bool {
    _Callback.onSell@withrevert(e, id, market, assets, units, pendingFee, user, receiver, data);
    return lastReverted;
}

function decodeActiveMaxBorrowCapacityUsage(env e, MidnightHarness.Offer offer) returns uint256 {
    return _Callback.decodeCallbackMaxBorrowCapacityUsage(e, offer.callbackData);
}
function decodeActiveOfferSellerAssets(env e, MidnightHarness.Offer offer) returns uint256 {
    return _Callback.decodeCallbackOfferSellerAssets(e, offer.callbackData);
}
function decodeActiveAmount(env e, MidnightHarness.Offer offer, uint256 i) returns uint256 {
    return _Callback.decodeCallbackAmount(e, offer.callbackData, i);
}

// No-fee helpers (MSC has no fee recipient)
function decodeActiveFeeRecipient(env e, MidnightHarness.Offer offer) returns address {
    return 0;
}
function requireThirdPartyNarrowings(env e, address u,
        MidnightHarness.Offer offer) {
}
function requireCallbackEndpointNarrowings(env e,
        MidnightHarness.Offer offer) {
    address sellerCallback = offer.callback;
    require(sellerCallback == _Callback,
        "SCOPE: take actually invokes MSC.onSell (collateral-supply flow)");
}
function requireReceiverNarrowing(env e,
        MidnightHarness.Offer offer, address receiverIfTakerIsSeller) {
    address receiver = offer.buy ? receiverIfTakerIsSeller : offer.receiverIfMakerIsSeller;
    require(receiver != _Callback,
        "SCOPE: MSC pulls collateral from the seller; the loanToken receiver is pinned off the callback");
}
function requireFeeRecipientNarrowings(env e, address feeRecipient) {
}
