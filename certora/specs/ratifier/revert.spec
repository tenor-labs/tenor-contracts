// MigrationRatifier — REVERT: revert characterizations of the isRatified entry guards and validation gates.

import "../setup/ratifier/ratifier_setup.spec";

// RTF-RV-01 (ORCH-NEW-8, InvalidRatifierData): isRatified rejects ratifierData that is not exactly 64 bytes (the
// abi.encode(bytes32 src, bytes32 tgt) length).
// FORMULA: ratifierData.length != 64 => revert(isRatified)
rule invalidRatifierDataLengthReverts(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert(ratifierData.length != 64 => lastReverted,
        "ratifierData that is not exactly 64 bytes is always rejected");
}

// RTF-RV-02 (ORCH-NEW-6, InvalidReceiver, make-on-behalf settlement pin): isRatified rejects an offer
// whose maker-seller receiver is not pinned — address(0) on a buy, the offer callback on a sell.
// FORMULA: receiverIfMakerIsSeller != (offer.buy ? 0 : offer.callback) => revert(isRatified)
rule makerReceiverMustBePinned(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    isRatified@withrevert(e, offer, ratifierData, taker);

    bool receiverPinned = offer.buy
        ? (offer.receiverIfMakerIsSeller == 0)
        : (offer.receiverIfMakerIsSeller == offer.callback);
    assert(!receiverPinned => lastReverted,
        "an offer whose maker-seller receiver is not pinned to (buy ? 0 : callback) is rejected");
}

// RTF-RV-03 (ORCH-NEW-7, InvalidGroup, reserved-namespace guard): isRatified rejects an offer whose group is outside the
// reserved migration-group namespace (top 6 bytes != MIGRATION_GROUP_HEADER), keeping consumed[maker][group] in a
// namespace disjoint from the maker's own non-migration offers.
// FORMULA: (offer.group & MIGRATION_GROUP_HEADER_MASK) != MIGRATION_GROUP_HEADER => revert(isRatified)
rule migrationGroupNamespaceEnforced(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    // Evaluate the namespace predicate before isRatified: this external call would otherwise reset lastReverted away from the verdict.
    bool inNamespace = groupMatchesNamespaceHarness(e, offer.group);

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert(!inNamespace => lastReverted,
        "an offer whose group is outside the reserved migration namespace is rejected");
}

// RTF-RV-04: isRatified reverts when the stored params tuple is unconfigured or malformed.
// FORMULA: policy==0 || minDuration==0 || maxDuration<minDuration => revert(isRatified)
rule unconfiguredTupleAlwaysReverts(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);

    // the params the flow loads for this offer (same storage isRatified reads: userParams[maker][callback][src][tgt])
    address pol; uint32 win; uint32 minD; uint32 maxD; address cad; uint40 lim;
    pol, win, minD, maxD, cad, lim = _Ratifier.userParams(e, offer.maker, offer.callback, iSrc, iTgt);

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert((pol == 0 || minD == 0 || maxD < minD) => lastReverted,
        "an unconfigured or malformed params tuple is always rejected");
}

// RTF-RV-05 (DEFAULT-4): for V2→V2 (BMR/LMR) and V1→V2 (BBM/LVM) callbacks, callbackData.tick must equal offer.tick (V2→V1 exits exempt).
// FORMULA: (isV2ToV2(cb) || isV1ToV2(cb)) && cd.tick != offer.tick => revert(isRatified)
rule tickMustMatchOffer(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    require(isV2ToV2(offer.callback) || isV1ToV2(offer.callback),
        "SCOPE: a tick-checked callback (V2->V2 renewal or V1->V2 enter)");

    uint256 cdTick = parseRawTickOfHarness(e, offer);

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert(cdTick != offer.tick => lastReverted, "a tick mismatch is always rejected");
}

// RTF-RV-06 (ORCH-9): isRatified rejects a target maturity that does not strictly exceed the source.
// FORMULA: targetMaturity > 0 && targetMaturity <= sourceMaturity => revert(isRatified)
rule targetMaturityMustExceedSource(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 cSrc; bytes32 cTgt; uint256 srcMat; uint256 tgtMat; uint256 cFeeRate; address cFeeRecip;
    cSrc, cTgt, srcMat, tgtMat, cFeeRate, cFeeRecip = parseCallbackContextOfHarness(e, offer);
    require(tgtMat > 0, "SCOPE: a renewal/enter take (target maturity present)");

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert(tgtMat <= srcMat => lastReverted, "a target maturity at or below source is always rejected");
}

// RTF-RV-07 (ORCH-10): isRatified rejects a target maturity outside the stored [now+minDuration, now+maxDuration] band.
// FORMULA: tgtMat>0 && (tgtMat < now+minDuration || tgtMat > now+maxDuration) => revert(isRatified)
rule targetMaturityWithinDurationBand(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);

    address pol; uint32 win; uint32 minD; uint32 maxD; address cad; uint40 lim;
    pol, win, minD, maxD, cad, lim = _Ratifier.userParams(e, offer.maker, offer.callback, iSrc, iTgt);

    bytes32 cSrc; bytes32 cTgt; uint256 srcMat; uint256 tgtMat; uint256 cFeeRate; address cFeeRecip;
    cSrc, cTgt, srcMat, tgtMat, cFeeRate, cFeeRecip = parseCallbackContextOfHarness(e, offer);

    mathint minTarget = e.block.timestamp + minD;
    mathint maxTarget = e.block.timestamp + maxD;
    require(tgtMat > 0, "SCOPE: a renewal/enter take (target maturity present)");

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert((to_mathint(tgtMat) < minTarget || to_mathint(tgtMat) > maxTarget) => lastReverted,
        "a target maturity outside the duration band is rejected");
}

// RTF-RV-08 (ORCH-11): with a cadence configured, isRatified rejects a target maturity off the cadence grid.
// FORMULA: tgtMat>0 && renewalCadence != 0 && cadencePeriodStart(tgtMat) != tgtMat => revert(isRatified)
rule targetMaturityOnCadenceGrid(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);

    address pol; uint32 win; uint32 minD; uint32 maxD; address cad; uint40 lim;
    pol, win, minD, maxD, cad, lim = _Ratifier.userParams(e, offer.maker, offer.callback, iSrc, iTgt);

    bytes32 cSrc; bytes32 cTgt; uint256 srcMat; uint256 tgtMat; uint256 cFeeRate; address cFeeRecip;
    cSrc, cTgt, srcMat, tgtMat, cFeeRate, cFeeRecip = parseCallbackContextOfHarness(e, offer);

    require(tgtMat > 0, "SCOPE: a renewal/enter take (target maturity present)");
    require(cad != 0, "SCOPE: a cadence is configured");

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert(ghostCadencePeriodStart[tgtMat] != tgtMat => lastReverted,
        "a target maturity off the cadence grid is rejected when a cadence is set");
}

// RTF-RV-09 (DEFAULT-3): isRatified rejects an offer whose ratifierData markets disagree with the callback-derived markets.
// FORMULA: (cSrc, cTgt) != (ratifierSrc, ratifierTgt) => revert(isRatified)
rule ratifierDataMustMatchCallbackMarkets(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 cSrc; bytes32 cTgt; uint256 srcMat; uint256 tgtMat; uint256 cFeeRate; address cFeeRecip;
    cSrc, cTgt, srcMat, tgtMat, cFeeRate, cFeeRecip = parseCallbackContextOfHarness(e, offer);

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert((cSrc != iSrc || cTgt != iTgt) => lastReverted,
        "ratifierData whose markets disagree with the callback is rejected");
}

// RTF-RV-10 (DEFAULT-2): isRatified rejects callbackData whose fee fields disagree with the effective fee config.
// FORMULA: (cFeeRate, cFeeRecip) != getEffectiveFeeConfig(cb, feeMarketId) => revert(isRatified)
rule callbackFeeMustMatchEffectiveConfig(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 cSrc; bytes32 cTgt; uint256 srcMat; uint256 tgtMat; uint256 cFeeRate; address cFeeRecip;
    cSrc, cTgt, srcMat, tgtMat, cFeeRate, cFeeRecip = parseCallbackContextOfHarness(e, offer);

    bytes32 feeMarketId = tgtMat == 0 ? cSrc : cTgt;
    IMigrationRatifier.FeeConfig eff = getEffectiveFeeConfig(e, offer.callback, feeMarketId);

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert((to_mathint(cFeeRate) != to_mathint(eff.feeRate) || cFeeRecip != eff.feeRecipient) => lastReverted,
        "callbackData fee fields disagreeing with the effective config are rejected");
}

// RTF-RV-11 (ORCH-8): a V2 (Midnight) source taken before its renewal window opens is rejected.
// FORMULA: now < srcMat - renewalWindow (over mathint) => revert(isRatified)   [antecedent vacuous when srcMat==0 or renewalWindow>srcMat]
rule v2SourceWindowEnforcedBeforeOpen(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);

    address pol; uint32 win; uint32 minD; uint32 maxD; address cad; uint40 lim;
    pol, win, minD, maxD, cad, lim = _Ratifier.userParams(e, offer.maker, offer.callback, iSrc, iTgt);

    bytes32 cSrc; bytes32 cTgt; uint256 srcMat; uint256 tgtMat; uint256 cFeeRate; address cFeeRecip;
    cSrc, cTgt, srcMat, tgtMat, cFeeRate, cFeeRecip = parseCallbackContextOfHarness(e, offer);

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert((to_mathint(e.block.timestamp) < to_mathint(srcMat) - to_mathint(win)) => lastReverted,
        "a V2 source taken before its window opens is rejected");
}

// RTF-RV-12 (ORCH-7): a V1->V2 enter (variable source, sourceMaturity==0) needs a configured cadence whose nearest boundary is not in the future.
// FORMULA: isV1ToV2(cb) && (cad==0 || cadencePeriodStart(now) > now) => revert(isRatified)
rule variableSourceWindowEnforced(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);

    address pol; uint32 win; uint32 minD; uint32 maxD; address cad; uint40 lim;
    pol, win, minD, maxD, cad, lim = _Ratifier.userParams(e, offer.maker, offer.callback, iSrc, iTgt);

    require(isV1ToV2(offer.callback), "SCOPE: a V1->V2 enter (variable source, sourceMaturity==0)");

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert((cad == 0 || ghostCadencePeriodStart[e.block.timestamp] > e.block.timestamp) => lastReverted,
        "a V1->V2 enter with no cadence or a future cadence boundary is rejected");
}

// RTF-RV-13 (ORCH-10): companion to targetMaturityWithinDurationBand — the lower band edge (now+minDuration) is
// INCLUSIVE: an in-band boundary target must be acceptable (satisfy-companion to the one-directional revert rule).
rule targetMaturityWithinDurationBand_boundaryAccepted(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);
    require(to_mathint(offer.tick) <= MAX_TICK(), "ASSERT: the real tickToPrice domain (TickLib reverts above MAX_TICK)");

    address taker;

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);

    address pol; uint32 win; uint32 minD; uint32 maxD; address cad; uint40 lim;
    pol, win, minD, maxD, cad, lim = _Ratifier.userParams(e, offer.maker, offer.callback, iSrc, iTgt);

    bytes32 cSrc; bytes32 cTgt; uint256 srcMat; uint256 tgtMat; uint256 cFeeRate; address cFeeRecip;
    cSrc, cTgt, srcMat, tgtMat, cFeeRate, cFeeRecip = parseCallbackContextOfHarness(e, offer);

    mathint minTarget = e.block.timestamp + minD;
    mathint maxTarget = e.block.timestamp + maxD;
    require(tgtMat > 0, "SCOPE: a renewal/enter take (target maturity present)");
    require(to_mathint(tgtMat) == minTarget, "SCOPE: target maturity at the inclusive lower band edge");

    isRatified@withrevert(e, offer, ratifierData, taker);

    satisfy(!lastReverted);
}

// RTF-RV-14 (ORCH-8) companion: a fixed V2 source whose renewalWindow == sourceMaturity (window opens at time 0)
// must be ACCEPTABLE — pins the renewalWindow <= sourceMaturity param-guard edge of _ratifyWindow.
// (Scope: the now == renewalPeriodStart time edge of the window guard is not witnessed here.)
// FORMULA: srcMat>0 && win==srcMat => some ratify succeeds (!revert)
rule v2SourceWindowEnforcedBeforeOpen_boundaryAccepted(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);
    require(to_mathint(offer.tick) <= MAX_TICK(), "ASSERT: the real tickToPrice domain (TickLib reverts above MAX_TICK)");

    address taker;

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);

    address pol; uint32 win; uint32 minD; uint32 maxD; address cad; uint40 lim;
    pol, win, minD, maxD, cad, lim = _Ratifier.userParams(e, offer.maker, offer.callback, iSrc, iTgt);

    bytes32 cSrc; bytes32 cTgt; uint256 srcMat; uint256 tgtMat; uint256 cFeeRate; address cFeeRecip;
    cSrc, cTgt, srcMat, tgtMat, cFeeRate, cFeeRecip = parseCallbackContextOfHarness(e, offer);

    require(srcMat > 0, "SCOPE: a fixed V2 (Midnight) source");
    require(to_mathint(win) == to_mathint(srcMat), "SCOPE: renewalWindow == sourceMaturity");

    isRatified@withrevert(e, offer, ratifierData, taker);

    satisfy(!lastReverted,
        "a fixed V2 source with renewalWindow == sourceMaturity can be accepted (window opens at time 0)");
}

// RTF-RV-15 (ORCH-7): acceptance-side companion to variableSourceWindowEnforced — the on-time boundary
// cadencePeriodStart(now)==now is ratifiable.
// FORMULA: exists run. isV1ToV2(cb) && cad!=0 && cadencePeriodStart(now)==now && !revert(isRatified)
rule variableSourceWindowEnforced_boundaryAccepted(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);
    require(to_mathint(offer.tick) <= MAX_TICK(), "ASSERT: the real tickToPrice domain (TickLib reverts above MAX_TICK)");

    address taker;

    bytes32 iSrc; bytes32 iTgt;
    iSrc, iTgt = parseRatifierDataHarness(e, ratifierData);

    address pol; uint32 win; uint32 minD; uint32 maxD; address cad; uint40 lim;
    pol, win, minD, maxD, cad, lim = _Ratifier.userParams(e, offer.maker, offer.callback, iSrc, iTgt);

    require(isV1ToV2(offer.callback), "SCOPE: a V1->V2 enter (variable source, sourceMaturity==0)");

    require(cad != 0, "SCOPE: a configured renewal cadence");
    require(ghostCadencePeriodStart[e.block.timestamp] == e.block.timestamp,
        "SCOPE: nearest cadence boundary lands exactly on now");

    isRatified@withrevert(e, offer, ratifierData, taker);

    satisfy(!lastReverted,
        "a V1->V2 enter whose nearest cadence boundary is exactly now can be ratified");
}

// RTF-RV-16 (RTF-WL-1 [net-new], InvalidCallback): isRatified rejects an offer whose callback is not one of the
// six authorized migration callbacks (the route whitelist; the callback-context decoder's final else-branch).
// FORMULA: callback not in {BMR,LMR,BBM,LVM,BMB,LMV} => revert(isRatified)
rule unauthorizedCallbackReverts(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    bool authorizedCallback = isV2ToV2(offer.callback) || isV1ToV2(offer.callback) || isV2ToV1(offer.callback);

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert(!authorizedCallback => lastReverted,
        "an offer whose callback is not one of the six authorized migration callbacks is rejected (InvalidCallback)");
}

// RTF-RV-17 (RTF-CFEE-1 [net-new], InvalidTargetMaturity): on the two Midnight-target lend flows (LVM, LMR)
// isRatified rejects a target whose lifetime continuous fee would consume the whole WAD face value.
// FORMULA: callback in {LVM,LMR} && continuousFee != 0 && continuousFee * zeroFloorSub(maturity, now) >= WAD => revert
rule continuousFeeCapReverts(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    require(offer.callback == _Ratifier.LEND_VAULT_TO_MIDNIGHT_CALLBACK
         || offer.callback == _Ratifier.LEND_MIDNIGHT_RENEWAL_CALLBACK,
        "SCOPE: a Midnight-target lend flow (the only flows that read the continuous-fee cap)");

    // mId is the target-market id the cap reads; compute it before isRatified so its external read does not reset lastReverted.
    bytes32 mId = midnightMarketIdOfHarness(e, offer);
    uint256 cFee = ghostContinuousFee[mId];
    mathint ttm = to_mathint(e.block.timestamp) >= to_mathint(offer.market.maturity)
        ? 0
        : offer.market.maturity - e.block.timestamp;

    isRatified@withrevert(e, offer, ratifierData, taker);

    assert(cFee != 0 && to_mathint(cFee) * ttm >= WAD() => lastReverted,
        "a continuous fee that would consume the whole WAD over the target lifetime is rejected (InvalidTargetMaturity)");
}
