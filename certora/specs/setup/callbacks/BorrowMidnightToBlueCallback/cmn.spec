import "../../../callbacks/callbacks.spec";

using BorrowMidnightToBlueCallbackHarness as _Callback;

methods {
    function _.onBuy(bytes32, MidnightHarness.Market, uint256, uint256, uint256, address, bytes) external
        => DISPATCHER(true);

    function _.supplyCollateral(MorphoHarness.MarketParams marketParams, uint256 assets,
        address onBehalf, bytes data) external => DISPATCHER(true);
    function _.borrow(MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares,
        address onBehalf, address receiver) external => DISPATCHER(true);
}

function setupMigrationRatifier(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    require(offer.buy == true,           "SCOPE: maker-side flow (BMB onBuy fires on maker=buyer)");
    require(offer.callback == _Callback, "TRUSTED: BMB is the activated maker(buy)-side callback");
    require(takerCallback == 0,          "SCOPE: single-sided maker scenario excludes taker callback");

    uint256 cbFeeRate = _Callback.decodeCallbackFeeRate(e, offer.callbackData);
    require(to_mathint(cbFeeRate) <= MAX_PERCENTAGE_FEE_RATE(),
        "ASSERT: percentageFee reverts above the 1% contract cap (standalone make/take)");
    address cbFeeRecipient = _Callback.decodeCallbackFeeRecipient(e, offer.callbackData);
    require(cbFeeRate > 0 => cbFeeRecipient != 0,
        "TRUSTED: ratifier/maker rejects a zero fee recipient when a fee is charged");
}

function callbackCallWithRevert(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) returns bool {
    _Callback.onBuy@withrevert(e, id, market, assets, units, pendingFee, user, data);
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

function requireFeeRecipientNarrowings(env e, address feeRecipient) {
    require(feeRecipient != _Morpho,
        "TRUSTED: feeRecipient != _Morpho (cross-protocol; Morpho Blue is never a Tenor fee recipient)");
}

function requireReceiverNarrowing(env e,
        MidnightHarness.Offer offer, address receiverIfTakerIsSeller) {
    address receiver = offer.buy ? receiverIfTakerIsSeller : offer.receiverIfMakerIsSeller;
    require(receiver != _Callback, "SCOPE: sellerAssets land on the trader, not the buy-side callback");
}
