import "../../../callbacks/callbacks.spec";

using BorrowBlueToMidnightCallbackHarness as _Callback;

methods {
    function _.onSell(bytes32, MidnightHarness.Market, uint256, uint256, uint256, address, address, bytes) external
        => DISPATCHER(true);

    function _.repay(MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares,
        address onBehalf, bytes data) external => DISPATCHER(true);
    function _.withdrawCollateral(MorphoHarness.MarketParams marketParams, uint256 assets,
        address onBehalf, address receiver) external => DISPATCHER(true);
}

function setupMigrationRatifier(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    require(offer.buy == false,          "SCOPE: maker-side flow (BBM onSell fires on maker=seller)");
    require(offer.callback == _Callback, "TRUSTED: BBM is the activated maker(sell)-side callback");
    require(takerCallback == 0,          "SCOPE: single-sided maker scenario excludes taker callback");

    require(_Callback.decodeCallbackTick(e, offer.callbackData) == offer.tick, "TRUSTED: ratifier pins callback tick to offer.tick");

    uint256 cbFeeRate = _Callback.decodeCallbackFeeRate(e, offer.callbackData);
    require(to_mathint(cbFeeRate) <= MAX_FEE_RATE(), "TRUSTED: ratifier caps the callback fee rate at MAX_FEE_RATE");

    address cbFeeRecipient = _Callback.decodeCallbackFeeRecipient(e, offer.callbackData);
    require(cbFeeRate > 0 => cbFeeRecipient != 0, "TRUSTED: ratifier rejects a zero fee recipient when a fee is charged");
    require(cbFeeRecipient != _Callback, "TRUSTED: fee recipient is not the callback itself (no self-payment aliasing)");
    require(cbFeeRecipient != _Midnight, "TRUSTED: fee recipient is not Midnight (fee leaves the protocol)");
    require(cbFeeRecipient != _Morpho,   "TRUSTED: fee recipient is not Morpho Blue (cross-protocol; Blue is never a Tenor fee recipient)");

    requireSourceMarketIrmBinding(e, offer.callbackData);
}

function callbackCallWithRevert(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) returns bool {
    _Callback.onSell@withrevert(e, id, market, assets, units, pendingFee, user, receiver, data);
    return lastReverted;
}

function decodeActiveFeeRecipient(env e, MidnightHarness.Offer offer) returns address {
    return _Callback.decodeCallbackFeeRecipient(e, offer.callbackData);
}

function requireThirdPartyNarrowings(env e, address u,
        MidnightHarness.Offer offer) {
    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    require(u != feeRecipient, "SAFE: u != active feeRecipient");
    require(u != _Morpho, "SAFE: u != Morpho Blue (cross-protocol)");
}

function requireCallbackEndpointNarrowings(env e,
        MidnightHarness.Offer offer) {
    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    require(feeRecipient != _Callback, "TRUSTED: fee recipient is not the callback itself (no self-payment aliasing)");
}

function requireReceiverNarrowing(env e,
        MidnightHarness.Offer offer, address receiverIfTakerIsSeller) {
    require(offer.receiverIfMakerIsSeller == _Callback,
        "TRUSTED: BBM maker-side flow -- sellerAssets land on the callback for Blue repay");
}

function requireFeeRecipientNarrowings(env e, address feeRecipient) {
    require(feeRecipient != _Morpho,
        "TRUSTED: feeRecipient != _Morpho (cross-protocol; Morpho Blue is never a Tenor fee recipient)");
}
