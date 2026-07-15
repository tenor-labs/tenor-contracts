import "../../midnight/specs/midnight_valid_state_many.spec";
import "../../../callbacks/callbacks.spec";

using LendMidnightRenewalCallbackHarness as _Callback;

methods {
    function _.onBuy(bytes32, MidnightHarness.Market, uint256, uint256, uint256, address, bytes) external
        => DISPATCHER(true);
}

function setupCallbackState(env e) {
    setupValidStateManyMidnight(e);
}

function setupMigrationRatifier(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    require(offer.buy == true,           "SCOPE: maker-side flow (LMR onBuy fires on maker=buyer)");
    require(offer.callback == _Callback, "TRUSTED: LMR is the activated maker(buy)-side callback");
    require(takerCallback == 0,          "SCOPE: single-sided maker scenario excludes taker callback");

    bytes activeCbData = offer.callbackData;

    require(_Callback.decodeCallbackTick(e, activeCbData) == offer.tick, "TRUSTED: ratifier pins callback tick to offer.tick");
    require(ghostNumTicks == 1, "SAFE: single take consumes one tick (offer.tick)");

    uint256 cbFeeRate = _Callback.decodeCallbackFeeRate(e, activeCbData);
    require(to_mathint(cbFeeRate) <= MAX_FEE_RATE(), "TRUSTED: ratifier caps the callback fee rate at MAX_FEE_RATE");

    address cbFeeRecipient = _Callback.decodeCallbackFeeRecipient(e, activeCbData);
    require(cbFeeRate > 0 => cbFeeRecipient != 0, "TRUSTED: ratifier rejects a zero fee recipient when a fee is charged");
    require(cbFeeRecipient != _Callback, "TRUSTED: fee recipient is not the callback itself (no self-payment aliasing)");
    require(cbFeeRecipient != _Midnight, "TRUSTED: fee recipient is not Midnight (fee leaves the protocol)");
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
}

function requireCallbackEndpointNarrowings(env e,
        MidnightHarness.Offer offer) {
    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    require(feeRecipient != _Callback, "TRUSTED: fee recipient is not the callback itself (no self-payment aliasing)");
}

// no extra fee-recipient narrowing
function requireFeeRecipientNarrowings(env e, address feeRecipient) {
}

function requireReceiverNarrowing(env e,
        MidnightHarness.Offer offer, address receiverIfTakerIsSeller) {
    address receiver = offer.buy ? receiverIfTakerIsSeller : offer.receiverIfMakerIsSeller;
    require(receiver != _Callback, "SCOPE: sellerAssets land on the trader, not the buy-side callback");
}
