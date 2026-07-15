// Gate-enforcement rules for Midnight (GT-MI-01..04, one-market regime).
//
// The enterGate / liquidatorGate / ratifier checks are runtime protections that would otherwise be
// invisible to the suite (the gates are summarized as plain NONDET). setup/gates.spec records each
// gate call (callee, account, verdict) into persistent ghosts; these rules assert the source
// requires (src L355-356, L397-406, L597-600) actually fire on every relevant success path.
//
// The recording summary is NONDET-equivalent for every other spec: each gate is consulted at
// most once per external entry, so a single unconstrained ghost verdict per gate is
// adversarially identical to a fresh NONDET return (see setup/gates.spec).

import "midnight_valid_state_one.spec";

// keccak256("morpho.midnight.callbackSuccess") — mirror of ConstantsLib.CALLBACK_SUCCESS
// (src/libraries/ConstantsLib.sol L25). GT-MI-04 cross-checks the literal: a wrong hash
// could not coincide with the value the source require pins on the success path.
definition CALLBACK_SUCCESS_CVL() returns bytes32 =
    to_bytes32(0x7f87788ea698181ea4d28d1576d0ba4fc92c0dbe5bf75b43692af2ce91dbaea2);

// GT-MI-01: on a market protected by an enter gate, the take() trade entry point (a buyer fills
// a maker's offer) can increase the buyer's lender credit only if the gate contract was consulted
// for that buyer and approved — no one can enter a gated market on the lending side without the
// gate's consent. The credit increase is measured net of the lazy fee accrual and bad-debt
// slashing that take() first realizes into the buyer's position.
// FORMULA: credit[buyer]' > creditAfterAccrualAndSlash[buyer] AND enterGate != 0
//          => enterGate.canIncreaseCredit(buyer) was called AND returned true
rule takeBuyerCreditIncreaseRequiresGateApproval(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units,
    address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    address buyer = offer.buy ? offer.maker : taker;
    require(VALID_POSITION_USER(buyer), "UNSAFE: buyer in the narrowed three-user set");
    require(!ghostGateCanIncreaseCreditCalled, "SAFE: clean call recorder at entry");
    bytes32 id = toId(e, offer.market);

    uint128 vc; uint128 vp; uint128 vf;
    vc, vp, vf = updatePositionView(e, offer.market, id, buyer); // post-slash/accrual pre-image

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostMiOnePositionCredit128[buyer] > to_mathint(vc) && offer.market.enterGate != 0 => (
        ghostGateCanIncreaseCreditCalled
        && ghostGateCanIncreaseCreditCallee == offer.market.enterGate
        && ghostGateCanIncreaseCreditAccount == buyer
        && ghostGateCanIncreaseCreditVerdict
    ), "take: a buyer credit increase on a gated market implies canIncreaseCredit(buyer) approved (src L397-400)");
}

// GT-MI-02: on a market protected by an enter gate, take() can increase the seller's debt (open
// or grow a borrow position) only if the gate contract was consulted for that seller and
// approved — no one can take on new debt in a gated market without the gate's consent.
// FORMULA: debt[seller]' > debt[seller] AND enterGate != 0
//          => enterGate.canIncreaseDebt(seller) was called AND returned true
rule takeSellerDebtIncreaseRequiresGateApproval(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units,
    address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    address seller = offer.buy ? taker : offer.maker;
    require(VALID_POSITION_USER(seller), "UNSAFE: seller in the narrowed three-user set");
    require(!ghostGateCanIncreaseDebtCalled, "SAFE: clean call recorder at entry");

    mathint sellerDebtBefore = ghostMiOnePositionDebt128[seller];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostMiOnePositionDebt128[seller] > sellerDebtBefore && offer.market.enterGate != 0 => (
        ghostGateCanIncreaseDebtCalled
        && ghostGateCanIncreaseDebtCallee == offer.market.enterGate
        && ghostGateCanIncreaseDebtAccount == seller
        && ghostGateCanIncreaseDebtVerdict
    ), "take: a seller debt increase on a gated market implies canIncreaseDebt(seller) approved (src L402-406)");
}

// GT-MI-03: on a market protected by a liquidator gate, a liquidation (the liquidator repays a
// borrower's debt and seizes collateral) can succeed only if the gate contract was consulted for
// the caller and approved — unapproved liquidators cannot seize collateral on gated markets.
// FORMULA: liquidate succeeds AND liquidatorGate != 0
//          => liquidatorGate.canLiquidate(msg.sender) was called AND returned true
rule liquidateRequiresLiquidatorGateApproval(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode, address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(!ghostGateCanLiquidateCalled, "SAFE: clean call recorder at entry");

    liquidate(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);

    assert(market.liquidatorGate != 0 => (
        ghostGateCanLiquidateCalled
        && ghostGateCanLiquidateCallee == market.liquidatorGate
        && ghostGateCanLiquidateAccount == e.msg.sender
        && ghostGateCanLiquidateVerdict
    ), "liquidate on a gated market implies canLiquidate(msg.sender) approved (src L597-600)");
}

// GT-MI-04: every trade settled through take() must first be ratified: the offer's designated
// ratifier contract is consulted, and the trade succeeds only when that contract returns the
// protocol's CALLBACK_SUCCESS magic value — no take() path can fill an offer while skipping the
// ratifier check.
// FORMULA: take succeeds => offer.ratifier.isRatified(offer, ratifierData, taker)
//                           == keccak256("morpho.midnight.callbackSuccess")
rule takeRequiresRatifierSuccess(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units,
    address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(ghostCallbackSuccess == CALLBACK_SUCCESS_CVL(),
        "take succeeds only when the ratifier returned CALLBACK_SUCCESS (src L387)");
}
