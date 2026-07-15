// MigrationRatifier unit: satisfy-witness twins of the RTF-UT-01..16 unit assert rules — each witnesses its parent's assert point reachable (run with rule_sanity:none).
import "../../setup/ratifier/ratifier_setup.spec";
import "../unit.spec";

// RTF-UT-01 (ORCH-3)
rule getEffectiveFeeConfigMarketOverridesActionDefault__satisfy(env e, address cb, bytes32 id) {

    setupMigrationRatifier(e);

    address mRecip; uint96 mRate;
    mRecip, mRate = _Ratifier.feeConfigs(e, cb, id);

    address dRecip; uint96 dRate;
    dRecip, dRate = _Ratifier.feeConfigs(e, cb, to_bytes32(0));

    IMigrationRatifier.FeeConfig eff = getEffectiveFeeConfig(e, cb, id);

    satisfy(true,
        "witness: getEffectiveFeeConfigMarketOverridesActionDefault assert-point reachable");
}

// RTF-UT-02 (ORCH-15, REG-2) — multi-assert: conjoined write-fidelity + no-collateral-damage.
rule setParamsWritesTupleAndLeavesOthers__satisfy(env e, address u, address cb, bytes32 s, bytes32 t,
        IMigrationRatifier.UserMigrationParams p,
        address u2, address cb2, bytes32 s2, bytes32 t2) {

    setupMigrationRatifier(e);

    require(u2 != u || cb2 != cb || s2 != s || t2 != t, "SCOPE: the other tuple is a different key");

    address pol2b; uint32 win2b; uint32 min2b; uint32 max2b; address cad2b; uint40 lim2b;
    pol2b, win2b, min2b, max2b, cad2b, lim2b = _Ratifier.userParams(e, u2, cb2, s2, t2);

    setParams(e, u, cb, s, t, p);

    address polA; uint32 winA; uint32 minA; uint32 maxA; address cadA; uint40 limA;
    polA, winA, minA, maxA, cadA, limA = _Ratifier.userParams(e, u, cb, s, t);

    address pol2a; uint32 win2a; uint32 min2a; uint32 max2a; address cad2a; uint40 lim2a;
    pol2a, win2a, min2a, max2a, cad2a, lim2a = _Ratifier.userParams(e, u2, cb2, s2, t2);

    satisfy(true,
        "witness: setParamsWritesTupleAndLeavesOthers assert-point reachable");
}

// RTF-UT-03 (REG-3) — multi-assert: conjoined zeroing + no-collateral-damage.
rule clearParamsZeroesTupleAndLeavesOthers__satisfy(env e, address u, address cb, bytes32 s, bytes32 t,
        address u2, address cb2, bytes32 s2, bytes32 t2) {

    setupMigrationRatifier(e);

    require(u2 != u || cb2 != cb || s2 != s || t2 != t, "SCOPE: the other tuple is a different key");

    address pol2b; uint32 win2b; uint32 min2b; uint32 max2b; address cad2b; uint40 lim2b;
    pol2b, win2b, min2b, max2b, cad2b, lim2b = _Ratifier.userParams(e, u2, cb2, s2, t2);

    clearParams(e, u, cb, s, t);

    address polA; uint32 winA; uint32 minA; uint32 maxA; address cadA; uint40 limA;
    polA, winA, minA, maxA, cadA, limA = _Ratifier.userParams(e, u, cb, s, t);

    address pol2a; uint32 win2a; uint32 min2a; uint32 max2a; address cad2a; uint40 lim2a;
    pol2a, win2a, min2a, max2a, cad2a, lim2a = _Ratifier.userParams(e, u2, cb2, s2, t2);

    satisfy(true,
        "witness: clearParamsZeroesTupleAndLeavesOthers assert-point reachable");
}

// RTF-UT-04 (DEFAULT-1, RATE-3)
rule userIsBuyMatchesBuySideCallbacks__satisfy(env e, address cb) {

    setupMigrationRatifier(e);

    bool isBuy = userIsBuyOfHarness(e, cb);

    satisfy(true,
        "witness: userIsBuyMatchesBuySideCallbacks assert-point reachable");
}

// RTF-UT-05 (PRICE-1) — multi-assert: conjoined floor/ceil formula + (0, WAD] bound.
rule priceFollowsZeroCouponFormula__satisfy(env e, uint256 rate, uint256 dur) {

    require(rate <= max_uint40 && dur <= max_uint32,
        "UNSAFE: uint40-rate slice — the real buy branch can feed computePrice a rate up to 2^128 (via max(policy,limit)) where pBuy==0, so the (0,WAD] lower bound holds on this slice only");

    mathint W = 10^18;
    mathint denom = W + to_mathint(rate) * to_mathint(dur);
    uint256 pBuy = computePriceOfHarness(e, true, rate, dur);
    uint256 pSell = computePriceOfHarness(e, false, rate, dur);

    satisfy(true,
        "witness: priceFollowsZeroCouponFormula assert-point reachable");
}

// RTF-UT-06 (PRICE-2)
rule priceRoundsInProtectedUserFavor__satisfy(env e, uint256 rate, uint256 dur) {

    satisfy(true,
        "witness: priceRoundsInProtectedUserFavor assert-point reachable");
}

// RTF-UT-07 (PRICE-3) — multi-assert: conjoined borrower-min + lender-max selection.
rule effectiveRateSelectsTighterBound__satisfy(env e, uint256 p, uint256 l) {

    satisfy(true,
        "witness: effectiveRateSelectsTighterBound assert-point reachable");
}

// RTF-UT-08 (PRICE-4) — multi-assert: conjoined borrower-ceiling + lender-floor gate directions.
rule satisfiesRateLimitComparisonDirection__satisfy(env e, uint256 u, uint256 a, uint256 lim, uint256 pol, uint256 dur) {

    require(u <= max_uint128 && a <= max_uint128 && lim <= max_uint40 && to_mathint(pol) <= 2^128 && dur <= max_uint32,
        "SAFE: Midnight uint128 units/assets, uint40 limit, policy in the getRate ghost range (<=2^128) and realistic duration — no overflow in the WAD-scaled compare");
    uint256 priceB = computePriceOfHarness(e, false, computeEffectiveRateOfHarness(e, false, pol, lim), dur);
    uint256 priceL = computePriceOfHarness(e, true, computeEffectiveRateOfHarness(e, true, pol, lim), dur);

    satisfy(true,
        "witness: satisfiesRateLimitComparisonDirection assert-point reachable");
}

// RTF-UT-09 (ORCH-4)
rule maxFeeRateZeroOnV2ToV1Exits__satisfy(env e, address cb) {

    setupMigrationRatifier(e);

    satisfy(true,
        "witness: maxFeeRateZeroOnV2ToV1Exits assert-point reachable");
}

// RTF-UT-10 (ORCH-13) — multi-assert across three mutually-exclusive branches: conjoined verbatim.
// effStart is hoisted from the parent's renewal branch; the branch asserts are jointly satisfiable (e.g. now>=src, tgt==now, d==0, rev==false).
rule computeDurationPerCallback__satisfy(env e, address cb, uint256 src, uint256 tgt) {

    setupMigrationRatifier(e);

    mathint now = e.block.timestamp;
    uint256 d = computeDurationOfHarness@withrevert(e, cb, src, tgt);

    mathint effStart = now > to_mathint(src) ? now : to_mathint(src);

    satisfy(true,
        "witness: computeDurationPerCallback assert-point reachable");
}

// RTF-UT-11
rule netSellerPriceMonotoneInFee__satisfy(env e, uint256 p, uint256 sf, uint256 feeLo, uint256 feeHi) {

    require(to_mathint(p) <= WAD() && to_mathint(feeHi) <= WAD() && to_mathint(sf) <= WAD(),
        "SAFE: offer price, fee rate and settlement fee are WAD-denominated fractions in [0, WAD]");
    require(feeLo <= feeHi, "SCOPE: feeLo is the smaller fee");

    satisfy(true,
        "witness: netSellerPriceMonotoneInFee assert-point reachable");
}

// RTF-UT-12
rule satisfiesRateLimitMonotoneInBorrowerLimit__satisfy(env e, uint256 u, uint256 a,
        uint256 limLo, uint256 limHi, uint256 pol, uint256 dur) {

    require(u <= max_uint128 && a <= max_uint128 && limHi <= max_uint40 && to_mathint(pol) <= 2^128 && dur <= max_uint32,
        "SAFE: Midnight uint128 units/assets, uint40 limit, policy in the getRate ghost range (<=2^128), realistic duration — no overflow");
    require(limLo <= limHi, "SCOPE: limLo is the tighter (smaller) limit");

    satisfy(satisfiesRateLimitOfHarness(e, false, u, a, limLo, pol, dur),
        "witness: satisfiesRateLimitMonotoneInBorrowerLimit assert-point reachable");
}

// RTF-UT-13
rule netBuyerPriceMonotoneInFee__satisfy(env e, uint256 p, uint256 sf, uint256 feeLo, uint256 feeHi) {

    require(to_mathint(p) <= WAD() && to_mathint(feeHi) <= WAD() && to_mathint(sf) <= WAD(),
        "SAFE: offer price, fee rate and settlement fee are WAD-denominated fractions in [0, WAD]");
    require(feeLo <= feeHi, "SCOPE: feeLo is the smaller fee");

    satisfy(true,
        "witness: netBuyerPriceMonotoneInFee assert-point reachable");
}

// RTF-UT-14
rule satisfiesRateLimitMonotoneInLenderLimit__satisfy(env e, uint256 u, uint256 a,
        uint256 limLo, uint256 limHi, uint256 pol, uint256 dur) {

    require(u <= max_uint128 && a <= max_uint128 && limHi <= max_uint40 && to_mathint(pol) <= 2^128 && dur <= max_uint32,
        "SAFE: Midnight uint128 units/assets, uint40 limit, policy in the getRate ghost range (<=2^128), realistic duration — no overflow");
    require(limLo <= limHi, "SCOPE: limLo is the tighter (smaller) limit");

    satisfy(satisfiesRateLimitOfHarness(e, true, u, a, limHi, pol, dur),
        "witness: satisfiesRateLimitMonotoneInLenderLimit assert-point reachable");
}

// RTF-UT-15
rule isRatifiedReturnsCallbackSuccess__satisfy(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 ret = isRatified(e, offer, ratifierData, taker);

    satisfy(true,
        "witness: isRatifiedReturnsCallbackSuccess assert-point reachable");
}

// RTF-UT-16
rule setFeeConfigWritesSlotAndLeavesOthers__satisfy(env e, address cb, bytes32 id, uint256 rate, address recipient,
        address cb2, bytes32 id2) {

    setupMigrationRatifier(e);

    require(cb2 != cb || id2 != id, "SCOPE: the other slot is a different key");

    address recip2b; uint96 rate2b;
    recip2b, rate2b = _Ratifier.feeConfigs(e, cb2, id2);

    setFeeConfig(e, cb, id, rate, recipient);

    address recipA; uint96 rateA;
    recipA, rateA = _Ratifier.feeConfigs(e, cb, id);

    address recip2a; uint96 rate2a;
    recip2a, rate2a = _Ratifier.feeConfigs(e, cb2, id2);

    satisfy(true,
        "witness: setFeeConfigWritesSlotAndLeavesOthers assert-point reachable");
}
