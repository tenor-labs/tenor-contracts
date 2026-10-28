// MidnightWithdrawableCallback: standalone scene (the callback alone, no Midnight model).
// Proves the gates the take scene cannot see: the take scene summarizes every isRatified call
// (ratifier.spec) and TickLib (tick_lib.spec), so many_setup.spec assumes these results as PROVED.

import "../../setup/constants.spec";

methods {
    function MORPHO_MIDNIGHT() external returns (address) envfree;
    function callbackSuccess() external returns (bytes32) envfree;
    function parTickPrice() external returns (uint256) envfree;
}

// MWC-01 (ratifier soundness): isRatified only accepts this contract's own par BUY offer, called back here.
// FORMULA: !reverted => maker == this AND callback == this AND buy AND tick == MAX_TICK AND ret == CALLBACK_SUCCESS
rule isRatifiedOnlyAcceptsOwnParBuyOffer(env e,
        MidnightWithdrawableCallbackHarness.Offer offer, bytes ratifierData, address taker) {

    bytes32 ret = isRatified@withrevert(e, offer, ratifierData, taker);
    bool reverted = lastReverted;

    assert(!reverted => (
        offer.maker == currentContract
        && offer.callback == currentContract
        && offer.buy
        && to_mathint(offer.tick) == MAX_TICK()
        && ret == callbackSuccess()
    ), "isRatified accepts only this contract's own par BUY offer");
}

// MWC-02 (ratifier liveness): every offer of that shape is accepted, whatever the taker-chosen fields.
// FORMULA: maker == this AND callback == this AND buy AND tick == MAX_TICK => !reverted AND ret == CALLBACK_SUCCESS
rule isRatifiedAcceptsOwnParBuyOffer(env e,
        MidnightWithdrawableCallbackHarness.Offer offer, bytes ratifierData, address taker) {

    require(e.msg.value == 0, "SAFE: isRatified is non-payable");
    require(offer.maker == currentContract && offer.callback == currentContract && offer.buy
        && to_mathint(offer.tick) == MAX_TICK(),
        "SCOPE: this contract's own par BUY offer");
    require(offer.market.collateralParams.length == 0,
        "SAFE: isRatified never reads offer.market; a CVL-passed struct array has an unconstrained raw encoding whose dirty address bits trip Solidity's ABI decoder, which Midnight's real encoding never produces");

    bytes32 ret = isRatified@withrevert(e, offer, ratifierData, taker);
    bool reverted = lastReverted;

    assert(!reverted && ret == callbackSuccess(), "own par BUY offer is always ratified");
}

// MWC-03 (CB-AUTH-1): onBuy rejects non-Midnight callers.
// FORMULA: msg.sender != MORPHO_MIDNIGHT => REVERTS
rule onBuyRevertsForNonMidnightCaller(env e, bytes32 id, MidnightWithdrawableCallbackHarness.Market market,
        uint256 buyerAssets, uint256 units, uint256 pendingFeeIncrease, address buyer, bytes data) {

    onBuy@withrevert(e, id, market, buyerAssets, units, pendingFeeIncrease, buyer, data);
    bool reverted = lastReverted;

    assert(e.msg.sender != MORPHO_MIDNIGHT() => reverted, "onBuy rejects non-Midnight callers");
}

// MWC-04: onBuy rejects fills where this contract is not the buyer, i.e. offers made by anyone else that
// point their callback here.
// FORMULA: buyer != this => REVERTS
rule onBuyRevertsForOtherBuyer(env e, bytes32 id, MidnightWithdrawableCallbackHarness.Market market,
        uint256 buyerAssets, uint256 units, uint256 pendingFeeIncrease, address buyer, bytes data) {

    onBuy@withrevert(e, id, market, buyerAssets, units, pendingFeeIncrease, buyer, data);
    bool reverted = lastReverted;

    assert(buyer != currentContract => reverted, "onBuy rejects fills for any other buyer");
}

// MWC-05: the only tick isRatified accepts prices at exactly 1, so buyerAssets == units on every fill.
// FORMULA: tickToPrice(MAX_TICK) == WAD
rule parTickPriceIsWad() {
    assert(to_mathint(parTickPrice()) == WAD(), "tickToPrice(MAX_TICK) == 1e18");
}

// MWC-14 (CLB-05): onBuy rejects zero-assets or zero-units fills.
// FORMULA: (buyerAssets == 0 OR units == 0) => REVERTS
rule onBuyRevertsOnZeroAssetsOrUnits(env e, bytes32 id, MidnightWithdrawableCallbackHarness.Market market,
        uint256 buyerAssets, uint256 units, uint256 pendingFeeIncrease, address buyer, bytes data) {

    // onBuy is invoked directly, so buyerAssets and units are independent -- every zero corner is exercised.
    onBuy@withrevert(e, id, market, buyerAssets, units, pendingFeeIncrease, buyer, data);
    bool reverted = lastReverted;

    assert((buyerAssets == 0 || units == 0) => reverted, "onBuy rejects a zero-asset or zero-unit fill");
}
