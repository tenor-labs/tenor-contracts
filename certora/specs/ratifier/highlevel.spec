// MigrationRatifier — HIGH-LEVEL: flow/fee-slot gates, window/cadence no-constraint chars, rate-gate binding + fee-monotonicity, params-key isolation, getRate forwarding.
// All rate-gate monotonicity rules pin user == offer.maker (make-on-behalf is the only path), so the Midnight settlement fee is netted at 0 and drops out of the gate.

import "../setup/ratifier/ratifier_setup.spec";

// RTF-HL-01 (ORCH-7): V1→V2 migrations (BBM, LVM) have no renewal window constraint.
// FORMULA: revert(isRatified | renewalWindow=w1) == revert(isRatified | renewalWindow=w2)
rule v1v2migrationsHaveNoRenewalWindowConstraint(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData,
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
    bool r1 = lastReverted;

    setParams(e, offer.maker, offer.callback, iSrc, iTgt, p2) at init;
    isRatified@withrevert(e, offer, ratifierData, taker);
    bool r2 = lastReverted;

    assert(r1 == r2, "the stored renewalWindow does not gate a V1→V2 migration");
}

// RTF-HL-02: V2→V1 exits (BMB, LMV) have no renewal cadence constraint.
// FORMULA: revert(isRatified | renewalCadence=c1) == revert(isRatified | renewalCadence=c2)
rule v2v1ExitsHaveNoRenewalCadenceConstraint(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData,
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
    bool r1 = lastReverted;

    setParams(e, offer.maker, offer.callback, iSrc, iTgt, p2) at init;
    isRatified@withrevert(e, offer, ratifierData, taker);
    bool r2 = lastReverted;

    assert(r1 == r2, "the stored renewalCadence does not gate a V2→V1 exit");
}

// RTF-HL-03 (ORCH-14): only the selected fee slot gates the verdict; any other market's slot is ignored.
// FORMULA: idX != feeMarketId && idX != 0 => revert(isRatified | cfg[cb][idX]=A) == revert(... =B)
rule feeMarketIdIgnoresCrossMarketSlot(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData,
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
    bool r1 = lastReverted;

    setFeeConfig(e, offer.callback, idX, rateB, recipB) at init;
    isRatified@withrevert(e, offer, ratifierData, taker);
    bool r2 = lastReverted;

    assert(r1 == r2, "a cross-market fee-config slot does not gate the verdict");
}

// RTF-HL-04E (decomposition bridge for RTF-HL-04): the real borrower (BBM) rate gate reverts exactly when the reconstructed net-seller threshold fails.
// FORMULA: revert(ratifyRateHarness) <=> !satisfiesRateLimit(false, WAD, netSellerPrice(tickPrice, 0, feeRate), limit, policy, dur)
rule borrowerRateGateMatchesNetSellerThreshold(env e, address callback, address user,
        MigrationRatifierHarness.Offer offer, IMigrationRatifier.UserMigrationParams params,
        IMigrationRatifier.FeeConfig fc, bytes32 srcId, bytes32 tgtId, uint256 rps, uint256 srcMat, uint256 tgtMat) {

    setupMigrationRatifier(e);

    address taker;

    require(user == offer.maker, "SCOPE: make-on-behalf — the migrating user is the offer maker (settlementFee=0)");
    require(callback == _Ratifier.BORROW_BLUE_TO_MIDNIGHT_CALLBACK,
        "SCOPE: BBM borrower enter (sell side; fee enters the gate via netSellerPrice)");
    require(offer.market.collateralParams.length == 0,
        "SAFE: the rate gate never reads collateralParams (idLibToIdCVL drops them); empty array avoids the decoder's address-cleanliness revert, unrelated to the gate");
    require(to_mathint(fc.feeRate) <= WAD(),
        "PROVED: feeRate is a WAD-denominated fraction — stored fee configs are capped at MAX_FEE_RATE (0.5e18) by the setFeeConfig guard (invariant RTF-VS-01), and the fee-match gate (RTF-RV-10) pins callbackData to a stored config");
    require(to_mathint(tgtMat) >= e.block.timestamp && to_mathint(tgtMat) <= e.block.timestamp + max_uint32,
        "SAFE: tgtMat >= now holds on the real path (_validateTargetMaturity runs before _ratifyRate); the now + max_uint32 upper bound keeps rate*duration in the overflow-free domain");

    ratifyRateHarness@withrevert(e, user, taker, callback, offer, params, fc, srcId, tgtId, rps, srcMat, tgtMat);
    bool rev = lastReverted;

    // Reconstruct the gate inputs from the same exposers the real path runs.
    uint256 dur = computeDurationOfHarness(e, callback, srcMat, tgtMat);                // matches _computeDuration
    uint256 policy = myGetRate(srcId, tgtId, rps, user, taker, srcMat, tgtMat, false);  // matches getRate (userIsBuy=false)
    uint256 effPrice = netSellerPriceOfHarness(e, tickPriceOfHarness(e, offer.tick), 0,        // settlementFee=0; fee folded as-is
        fc.feeRate);
    uint256 wad = require_uint256(WAD());                                        // BBM => effUnitsPerWad == WAD

    assert(rev == !satisfiesRateLimitOfHarness(e, false, wad, effPrice, params.limitRatePerSecond, policy, dur),
        "the real borrower rate gate reverts iff the reconstructed net-seller threshold fails");
}

// RTF-HL-04 (CB-RATE-1, directional): on a borrower enter (BBM, sell side) a larger fee only tightens the rate gate.
// FORMULA: feeRate_lo <= feeRate_hi  =>  ( revert(ratifyRateHarness | lo) => revert(ratifyRateHarness | hi) )
rule higherFeeOnlyTightensBorrowerRateGate(env e, address callback, address user,
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
    bool rLo = lastReverted;

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
    assert(rLo == reconLo, "binding: the real low-fee gate reverts iff the reconstructed net-seller threshold fails");
    assert(reconLo => reconHi, "a larger borrower fee can only tighten (never loosen) the rate gate");
}

// RTF-HL-05E (decomposition bridge for RTF-HL-05): the real lender (LVM) rate gate reverts exactly when the reconstructed net-buyer threshold fails.
// FORMULA: revert(ratifyRateHarness) <=> !satisfiesRateLimit(true, WAD, netBuyerPrice(tickPrice, 0, feeRate), limit, policy, dur)
rule lenderRateGateMatchesNetBuyerThreshold(env e, address callback, address user,
        MigrationRatifierHarness.Offer offer, IMigrationRatifier.UserMigrationParams params,
        IMigrationRatifier.FeeConfig fc, bytes32 srcId, bytes32 tgtId, uint256 rps, uint256 srcMat, uint256 tgtMat) {

    setupMigrationRatifier(e);

    address taker;

    require(user == offer.maker, "SCOPE: make-on-behalf — the migrating user is the offer maker (settlementFee=0)");
    require(callback == _Ratifier.LEND_VAULT_TO_MIDNIGHT_CALLBACK,
        "SCOPE: LVM lender enter (buy side; fee enters the gate via netBuyerPrice)");
    require(offer.market.collateralParams.length == 0,
        "SAFE: the rate gate never reads collateralParams (idLibToIdCVL drops them); empty array avoids the decoder's address-cleanliness revert, unrelated to the gate");
    require(to_mathint(fc.feeRate) <= MAX_FEE_RATE(),
        "PROVED: stored fee configs are capped at MAX_FEE_RATE (0.5e18) at config time (setFeeConfig guard, invariant RTF-VS-01), and _ratify passes only the storage-derived expectedFee to the gate");
    require(to_mathint(tgtMat) >= e.block.timestamp && to_mathint(tgtMat) <= e.block.timestamp + max_uint32,
        "SAFE: tgtMat >= now holds on the real path (_validateTargetMaturity runs before _ratifyRate); the now + max_uint32 upper bound keeps rate*duration in the overflow-free domain");
    require(ghostContinuousFee[midnightMarketIdOfHarness(e, offer)] == 0,
        "SCOPE: zero continuous fee (LVM effUnitsPerWad is WAD; pins the shared face value)");

    ratifyRateHarness@withrevert(e, user, taker, callback, offer, params, fc, srcId, tgtId, rps, srcMat, tgtMat);
    bool rev = lastReverted;

    // Reconstruct the gate inputs from the same exposers the real path runs.
    uint256 dur = computeDurationOfHarness(e, callback, srcMat, tgtMat);                // matches _computeDuration
    uint256 policy = myGetRate(srcId, tgtId, rps, user, taker, srcMat, tgtMat, true);   // matches getRate (userIsBuy=true)
    uint256 effPrice = netBuyerPriceOfHarness(e, tickPriceOfHarness(e, offer.tick), 0,         // settlementFee=0; fee folded as-is
        fc.feeRate);
    uint256 wad = require_uint256(WAD());                                        // LVM, continuousFee==0 => units == WAD

    assert(rev == !satisfiesRateLimitOfHarness(e, true, wad, effPrice, params.limitRatePerSecond, policy, dur),
        "the real lender rate gate reverts iff the reconstructed net-buyer threshold fails");
}

// RTF-HL-05 (CB-RATE-2, directional): on a lender enter (LVM, buy side) a larger fee only tightens the rate gate.
// FORMULA: feeRate_lo <= feeRate_hi  =>  ( revert(ratifyRateHarness | lo) => revert(ratifyRateHarness | hi) )
rule higherFeeOnlyTightensLenderRateGate(env e, address callback, address user,
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
    require(ghostContinuousFee[midnightMarketIdOfHarness(e, offer)] == 0,
        "SCOPE: zero continuous fee -- effUnitsPerWad == WAD, so the reconstruction binds with units = WAD");
    require(to_mathint(fcHi.feeRate) <= MAX_FEE_RATE(),
        "PROVED: stored fee configs are capped at MAX_FEE_RATE (0.5e18) at config time (setFeeConfig guard, invariant RTF-VS-01), and _ratify passes only the storage-derived expectedFee to the gate");
    require(to_mathint(tgtMat) >= e.block.timestamp && to_mathint(tgtMat) <= e.block.timestamp + max_uint32,
        "SAFE: tgtMat >= now holds on the real path (_validateTargetMaturity runs before _ratifyRate); the now + max_uint32 upper bound keeps rate*duration in the overflow-free domain");

    // Bind the real rate gate once on the low-fee run; only the net-buyer price moves with the fee, so both verdicts reconstruct against one shared threshold price.
    ratifyRateHarness@withrevert(e, user, taker, callback, offer, params, fcLo, srcId, tgtId, rps, srcMat, tgtMat);
    bool rLo = lastReverted;

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
    assert(rLo == reconLo, "binding: the real low-fee gate reverts iff the reconstructed net-buyer threshold fails");
    assert(reconLo => reconHi, "a larger lender fee can only tighten (never loosen) the rate gate");
}

// RTF-HL-06: only the addressed userParams[offer.maker][offer.callback][src][tgt] tuple gates the
// verdict; any other tuple cannot.
// FORMULA: (u2,cb2,s2,t2) != (offer.maker,offer.callback,iSrc,iTgt) => revert(isRatified | set other tuple) == revert(...)
rule isRatifiedReadsOnlyAddressedParams(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData,
        IMigrationRatifier.UserMigrationParams pOther, address u2, address cb2, bytes32 s2, bytes32 t2) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);
    require(u2 != offer.maker || cb2 != offer.callback || s2 != iSrc || t2 != iTgt,
        "SCOPE: the mutated tuple is a different key than the addressed one");

    storage init = lastStorage;

    isRatified@withrevert(e, offer, ratifierData, taker);
    bool r1 = lastReverted;

    setParams(e, u2, cb2, s2, t2, pOther) at init;
    isRatified@withrevert(e, offer, ratifierData, taker);
    bool r2 = lastReverted;

    assert(r1 == r2, "a non-addressed userParams tuple never moves the verdict");
}

// RTF-HL-07: the rate policy is consulted for the right principal — offer.maker as the policy user
// (make-on-behalf always prices the migration for the offer maker).
// FORMULA: !revert(isRatified) => recorded getRate user == offer.maker
rule getRatePrincipalForwardedFaithfully(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert(!lastReverted => gGetRateUserArg == offer.maker,
        "an accepted offer consults the rate policy for the offer maker");
}
