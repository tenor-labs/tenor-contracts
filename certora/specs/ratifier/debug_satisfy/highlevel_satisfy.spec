// MigrationRatifier highlevel: satisfy-witness twins of the RTF-HL highlevel assert rules — each witnesses its parent's assert point reachable (run with rule_sanity:none).
import "../../setup/ratifier/ratifier_setup.spec";
import "../highlevel.spec";

// RTF-HL-01 (ORCH-7)
rule v1v2migrationsHaveNoRenewalWindowConstraint__satisfy(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData,
        IMigrationRatifier.UserMigrationParams p1, IMigrationRatifier.UserMigrationParams p2) {

    setupMigrationRatifier(e);

    address taker;

    require(isV1ToV2(offer.callback), "SCOPE: pin a V1→V2 enter (BBM or LVM)");
    require(paramsDifferOnlyInRenewalWindow(p1, p2), "SCOPE: stored params differ only in renewalWindow");

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);

    storage init = lastStorage;

    setParams(e, offer.maker, offer.callback, iSrc, iTgt, p1) at init;
    isRatified@withrevert(e, offer, ratifierData, taker);

    setParams(e, offer.maker, offer.callback, iSrc, iTgt, p2) at init;
    isRatified@withrevert(e, offer, ratifierData, taker);

    satisfy(true, "witness: v1v2migrationsHaveNoRenewalWindowConstraint assert-point reachable");
}

// RTF-HL-02
rule v2v1ExitsHaveNoRenewalCadenceConstraint__satisfy(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData,
        IMigrationRatifier.UserMigrationParams p1, IMigrationRatifier.UserMigrationParams p2) {

    setupMigrationRatifier(e);

    address taker;
    require(offer.market.maturity != 0, "SCOPE: live Midnight source only -- maturity==0 is _extractCallbackContext's non-Midnight sentinel");

    require(isV2ToV1(offer.callback), "SCOPE: pin a V2→V1 exit (BMB or LMV)");
    require(paramsDifferOnlyInRenewalCadence(p1, p2), "SCOPE: stored params differ only in renewalCadence");

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);

    storage init = lastStorage;

    setParams(e, offer.maker, offer.callback, iSrc, iTgt, p1) at init;
    isRatified@withrevert(e, offer, ratifierData, taker);

    setParams(e, offer.maker, offer.callback, iSrc, iTgt, p2) at init;
    isRatified@withrevert(e, offer, ratifierData, taker);

    satisfy(true, "witness: v2v1ExitsHaveNoRenewalCadenceConstraint assert-point reachable");
}

// RTF-HL-03 (ORCH-14)
rule feeMarketIdIgnoresCrossMarketSlot__satisfy(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData,
        bytes32 idX, uint256 rateA, address recipA, uint256 rateB, address recipB) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 cSrc; bytes32 cTgt; uint256 srcMat; uint256 tgtMat; uint256 cFeeRate; address cFeeRecip;
    cSrc, cTgt, srcMat, tgtMat, cFeeRate, cFeeRecip = parseCallbackContextOfHarness(e, offer);
    bytes32 feeMarketId = tgtMat == 0 ? cSrc : cTgt;
    require(idX != feeMarketId && idX != to_bytes32(0), "SCOPE: idX is a cross (non-selected, non-default) slot");

    storage init = lastStorage;

    setFeeConfig(e, offer.callback, idX, rateA, recipA) at init;
    isRatified@withrevert(e, offer, ratifierData, taker);

    setFeeConfig(e, offer.callback, idX, rateB, recipB) at init;
    isRatified@withrevert(e, offer, ratifierData, taker);

    satisfy(true, "witness: feeMarketIdIgnoresCrossMarketSlot assert-point reachable");
}

// RTF-HL-04 (CB-RATE-1, directional)
rule higherFeeOnlyTightensBorrowerRateGate__satisfy(env e, address callback, address user,
        MigrationRatifierHarness.Offer offer, IMigrationRatifier.UserMigrationParams params,
        IMigrationRatifier.FeeConfig fcLo, IMigrationRatifier.FeeConfig fcHi,
        bytes32 srcId, bytes32 tgtId, uint256 rps, uint256 srcMat, uint256 tgtMat) {

    setupMigrationRatifier(e);

    address taker;

    require(user == offer.maker, "SCOPE: make-on-behalf — the migrating user is the offer maker (settlementFee=0)");
    require(callback == _Ratifier.BORROW_BLUE_TO_MIDNIGHT_CALLBACK,
        "SCOPE: BBM borrower enter (sell side; fee enters the gate via netSellerPrice)");
    require(offer.market.collateralParams.length == 0,
        "SAFE: the rate gate never reads collateralParams (idLibToIdCVL drops them); empty array avoids the decoder's address-cleanliness revert, unrelated to the gate");
    require(fcLo.feeRate <= fcHi.feeRate, "SCOPE: fcHi is the larger fee");
    require(to_mathint(fcHi.feeRate) <= WAD(),
        "PROVED: feeRate is a WAD-denominated fraction — stored fee configs are capped at MAX_FEE_RATE (0.5e18) by the setFeeConfig guard (invariant RTF-VS-01), and the fee-match gate (RTF-RV-10) pins callbackData to a stored config");
    require(to_mathint(tgtMat) >= e.block.timestamp && to_mathint(tgtMat) <= e.block.timestamp + max_uint32,
        "SAFE: tgtMat >= now holds on the real path (_validateTargetMaturity runs before _ratifyRate); the now + max_uint32 upper bound keeps rate*duration in the overflow-free domain");
    // Bind the real rate gate once on the low-fee run; only the net-seller price moves with the fee, so both verdicts reconstruct against one shared threshold price.
    ratifyRateHarness@withrevert(e, user, taker, callback, offer, params, fcLo, srcId, tgtId, rps, srcMat, tgtMat);

    uint256 dur = computeDurationOfHarness(e, callback, srcMat, tgtMat);
    uint256 policy = myGetRate(srcId, tgtId, rps, user, taker, srcMat, tgtMat, false);
    uint256 tickP = tickPriceOfHarness(e, offer.tick);
    // Single shared zero-coupon threshold price (RTF-UT-08: borrower reverts iff effPrice*WAD < units*priceB, units=WAD).
    uint256 priceB = computePriceOfHarness(e, false, computeEffectiveRateOfHarness(e, false, policy, params.limitRatePerSecond), dur);
    uint256 effPriceLo = netSellerPriceOfHarness(e, tickP, 0, fcLo.feeRate);
    uint256 effPriceHi = netSellerPriceOfHarness(e, tickP, 0, fcHi.feeRate);

    require(effPriceHi <= effPriceLo, "PROVED: RTF-UT-11 net seller price is non-increasing in the fee (proven separately)");

    bool reconLo = to_mathint(effPriceLo) * WAD() < WAD() * to_mathint(priceB);
    bool reconHi = to_mathint(effPriceHi) * WAD() < WAD() * to_mathint(priceB);

    // borrowerRateGateMatchesNetSellerThreshold makes reconHi the real high-fee verdict; with the lemma, reconLo => reconHi.
    satisfy(reconLo,
        "witness: higherFeeOnlyTightensBorrowerRateGate assert-point reachable");
}

// RTF-HL-05 (CB-RATE-2, directional)
rule higherFeeOnlyTightensLenderRateGate__satisfy(env e, address callback, address user,
        MigrationRatifierHarness.Offer offer, IMigrationRatifier.UserMigrationParams params,
        IMigrationRatifier.FeeConfig fcLo, IMigrationRatifier.FeeConfig fcHi,
        bytes32 srcId, bytes32 tgtId, uint256 rps, uint256 srcMat, uint256 tgtMat) {

    setupMigrationRatifier(e);

    address taker;

    require(user == offer.maker, "SCOPE: make-on-behalf — the migrating user is the offer maker (settlementFee=0)");
    require(callback == _Ratifier.LEND_VAULT_TO_MIDNIGHT_CALLBACK,
        "SCOPE: LVM lender enter (buy side; fee enters the gate via netBuyerPrice)");
    require(offer.market.collateralParams.length == 0,
        "SAFE: the rate gate never reads collateralParams (idLibToIdCVL drops them); empty array avoids the decoder's address-cleanliness revert, unrelated to the gate");
    require(fcLo.feeRate <= fcHi.feeRate, "SCOPE: fcHi is the larger fee");
    require(to_mathint(fcHi.feeRate) <= MAX_FEE_RATE(),
        "PROVED: stored fee configs are capped at MAX_FEE_RATE (0.5e18) at config time (setFeeConfig guard, invariant RTF-VS-01), and _ratify passes only the storage-derived expectedFee to the gate");
    require(to_mathint(tgtMat) >= e.block.timestamp && to_mathint(tgtMat) <= e.block.timestamp + max_uint32,
        "SAFE: tgtMat >= now holds on the real path (_validateTargetMaturity runs before _ratifyRate); the now + max_uint32 upper bound keeps rate*duration in the overflow-free domain");
    require(ghostContinuousFee[midnightMarketIdOfHarness(e, offer)] == 0,
        "SCOPE: zero continuous fee -- effUnitsPerWad == WAD, so the reconstruction binds with units = WAD");

    // Bind the real rate gate once on the low-fee run; only the net-buyer price moves with the fee, so both verdicts reconstruct against one shared threshold price.
    ratifyRateHarness@withrevert(e, user, taker, callback, offer, params, fcLo, srcId, tgtId, rps, srcMat, tgtMat);

    uint256 dur = computeDurationOfHarness(e, callback, srcMat, tgtMat);
    uint256 policy = myGetRate(srcId, tgtId, rps, user, taker, srcMat, tgtMat, true);
    uint256 tickP = tickPriceOfHarness(e, offer.tick);
    // Single shared zero-coupon threshold price (RTF-UT-08: lender reverts iff effPrice*WAD > units*priceL, units=WAD).
    uint256 priceL = computePriceOfHarness(e, true, computeEffectiveRateOfHarness(e, true, policy, params.limitRatePerSecond), dur);
    uint256 effPriceLo = netBuyerPriceOfHarness(e, tickP, 0, fcLo.feeRate);
    uint256 effPriceHi = netBuyerPriceOfHarness(e, tickP, 0, fcHi.feeRate);

    require(effPriceLo <= effPriceHi, "PROVED: RTF-UT-13 net buyer price is non-decreasing in the fee (proven separately)");

    bool reconLo = to_mathint(effPriceLo) * WAD() > WAD() * to_mathint(priceL);
    bool reconHi = to_mathint(effPriceHi) * WAD() > WAD() * to_mathint(priceL);

    // lenderRateGateMatchesNetBuyerThreshold makes reconHi the real high-fee verdict; with the lemma, reconLo => reconHi.
    satisfy(reconLo,
        "witness: higherFeeOnlyTightensLenderRateGate assert-point reachable");
}

// RTF-HL-06
rule isRatifiedReadsOnlyAddressedParams__satisfy(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData,
        IMigrationRatifier.UserMigrationParams pOther, address u2, address cb2, bytes32 s2, bytes32 t2) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);
    require(u2 != offer.maker || cb2 != offer.callback || s2 != iSrc || t2 != iTgt,
        "SCOPE: the mutated tuple is a different key than the addressed one");

    storage init = lastStorage;

    isRatified@withrevert(e, offer, ratifierData, taker);

    setParams(e, u2, cb2, s2, t2, pOther) at init;
    isRatified@withrevert(e, offer, ratifierData, taker);

    satisfy(true, "witness: isRatifiedReadsOnlyAddressedParams assert-point reachable");
}

// RTF-HL-07
rule getRatePrincipalForwardedFaithfully__satisfy(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    isRatified@withrevert(e, offer, ratifierData, taker);

    satisfy(!lastReverted,
        "witness: getRatePrincipalForwardedFaithfully assert-point reachable");
}
