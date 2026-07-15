import "../../../callbacks/callbacks.spec";

using MidnightSupplyVaultSharesCallbackHarness as _Callback;

methods {
    function _.onSell(bytes32, MidnightHarness.Market, uint256, uint256, uint256, address, address, bytes) external
        => DISPATCHER(true);
}

function setupMigrationRatifier(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    require(offer.buy == false,          "SCOPE: maker-side flow (maker is seller; MSV.onSell fires on maker=seller)");
    require(offer.callback == _Callback, "TRUSTED: MSV is the activated maker(sell)-side callback");
    require(takerCallback == 0,          "SCOPE: single-sided maker scenario excludes taker callback");

    require(offer.receiverIfMakerIsSeller == _Callback,
        "TRUSTED: receiver pinned to the callback (sellerAssets fund the vault deposit)");

    require(ghostNumTicks == 1, "SAFE: single take consumes one tick (offer.tick)");

    // validateVaultCollateral reconstruction; vault pinned to slot 0.
    address vault = _Callback.decodeCallbackVault(e, offer.callbackData);
    require(_Callback.decodeCallbackCollateralIndex(e, offer.callbackData) == 0,
        "SAFE: vault pinned to collateral slot 0 (single-write narrowing)");
    require(offer.market.collateralParams.length == ghostNumCollaterals,
        "UNSAFE: offer market collateral count matches the model");
    require(ghostERC4626Asset[vault] == offer.market.loanToken,
        "ASSERT: vault.asset() == loanToken (validateVaultCollateral reverts on mismatch)");
    require(offer.market.collateralParams[0].token == vault,
        "ASSERT: vault listed at collateral slot 0 (validateVaultCollateral reverts on mismatch)");
    require(vault != offer.market.loanToken,
        "SAFE: vault is an ERC4626 share token, never its own underlying loanToken");
    require(vault != _Callback && vault != _Midnight,
        "SAFE: vault is a distinct deployed contract");
    require(vault != ghostMiPositionUserOne && vault != ghostMiPositionUserTwo && vault != ghostMiPositionUserThree,
        "SAFE: vault is not a tracked Midnight position user");
    require(vault == _VaultV2,
        "SAFE: the decoded vault is the on-scene VaultV2 instance (link-analog for a decoded address)");
}

// onSell wrapper returning lastReverted.
function callbackCallWithRevert(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) returns bool {
    _Callback.onSell@withrevert(e, id, market, assets, units, pendingFee, user, receiver, data);
    return lastReverted;
}

// Active-payload decoders (maker leg: offer.callbackData).
function decodeActiveVault(env e, MidnightHarness.Offer offer) returns address {
    return _Callback.decodeCallbackVault(e, offer.callbackData);
}
function decodeActiveCollateralIndex(env e, MidnightHarness.Offer offer) returns uint256 {
    return _Callback.decodeCallbackCollateralIndex(e, offer.callbackData);
}
function decodeActiveAdditionalDepositPercent(env e, MidnightHarness.Offer offer) returns uint256 {
    return _Callback.decodeCallbackAdditionalDepositPercent(e, offer.callbackData);
}

// No-fee stubs required by callbacks.spec (MSV has no fee).
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
        "SCOPE: take actually invokes MSV.onSell (vault-supply flow)");
}
function requireReceiverNarrowing(env e,
        MidnightHarness.Offer offer, address receiverIfTakerIsSeller) {
    address receiver = offer.buy ? receiverIfTakerIsSeller : offer.receiverIfMakerIsSeller;
    require(receiver == _Callback,
        "TRUSTED: MSV normal flow -- sellerAssets land on the callback for the vault deposit");
}
function requireFeeRecipientNarrowings(env e, address feeRecipient) {
}
