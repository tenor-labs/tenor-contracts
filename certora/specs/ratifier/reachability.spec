// MigrationRatifier — REACHABILITY: satisfy()-witnesses that an accept path is reachable from a valid
// state. Pure existence rules (never assert, never test reverts).
// Witnesses establish executability modulo the ghost summaries (tick price, cadence, getRate are model-chosen).

import "../setup/ratifier/ratifier_setup.spec";

// RTF-RC-01 (ORCH-5): a V2->V2 renewal taken at or after source maturity still has an accepting execution
// (existence witness at some post-maturity instant; not a universal claim over all post-maturity states).
rule postMaturityV2ToV2Executable(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;
    require(to_mathint(offer.tick) <= MAX_TICK(), "ASSERT: the real tickToPrice domain (TickLib reverts above MAX_TICK)");

    bytes32 cSrc; bytes32 cTgt; uint256 srcMat; uint256 tgtMat; uint256 cFeeRate; address cFeeRecip;
    cSrc, cTgt, srcMat, tgtMat, cFeeRate, cFeeRecip = parseCallbackContextOfHarness(e, offer);

    require(offer.callback == _Ratifier.BORROW_MIDNIGHT_RENEWAL_CALLBACK
         || offer.callback == _Ratifier.LEND_MIDNIGHT_RENEWAL_CALLBACK, "SCOPE: a V2->V2 renewal callback");
    require(srcMat > 0 && tgtMat > 0, "SCOPE: both legs are live Midnight markets (V2->V2)");
    require(to_mathint(e.block.timestamp) >= to_mathint(srcMat), "SCOPE: taken at or after source maturity");

    isRatified@withrevert(e, offer, ratifierData, taker);

    satisfy(!lastReverted, "a post-maturity V2->V2 renewal has an accepting execution (timing alone never blocks)");
}

// RTF-RC-02 (ORCH-6): a V2->V1 exit taken at or after source maturity still has an accepting execution
// (existence witness: the window passes there and target-maturity validation is skipped — V1 has no maturity).
rule postMaturityV2ToV1Executable(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;
    require(to_mathint(offer.tick) <= MAX_TICK(), "ASSERT: the real tickToPrice domain (TickLib reverts above MAX_TICK)");

    bytes32 cSrc; bytes32 cTgt; uint256 srcMat; uint256 tgtMat; uint256 cFeeRate; address cFeeRecip;
    cSrc, cTgt, srcMat, tgtMat, cFeeRate, cFeeRecip = parseCallbackContextOfHarness(e, offer);

    require(isV2ToV1(offer.callback), "SCOPE: a V2->V1 exit callback (BMB / LMV)");
    require(srcMat > 0 && tgtMat == 0, "SCOPE: V2 source, V1 target (no target maturity)");
    require(to_mathint(e.block.timestamp) >= to_mathint(srcMat), "SCOPE: taken at or after source maturity");

    isRatified@withrevert(e, offer, ratifierData, taker);

    satisfy(!lastReverted, "a post-maturity V2->V1 exit has an accepting execution (window passes; only target-maturity validation is skipped)");
}

// RTF-RC-03 (RTF-RC-V1V2 [net-new]): a V1->V2 enter (Blue/vault source, live Midnight target) has an accepting
// execution — the variable-source window is satisfied once the cadence boundary is at or before now.
rule entryV1ToV2Executable(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;
    require(to_mathint(offer.tick) <= MAX_TICK(), "ASSERT: the real tickToPrice domain (TickLib reverts above MAX_TICK)");

    bytes32 cSrc; bytes32 cTgt; uint256 srcMat; uint256 tgtMat; uint256 cFeeRate; address cFeeRecip;
    cSrc, cTgt, srcMat, tgtMat, cFeeRate, cFeeRecip = parseCallbackContextOfHarness(e, offer);

    require(isV1ToV2(offer.callback), "SCOPE: a V1->V2 enter callback (BBM / LVM)");
    require(srcMat == 0 && tgtMat > 0, "SCOPE: V1 source (no maturity), live Midnight target");

    isRatified@withrevert(e, offer, ratifierData, taker);

    satisfy(!lastReverted, "a V1->V2 enter has an accepting execution (variable-source window satisfied at the cadence boundary)");
}
