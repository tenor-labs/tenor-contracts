// MigrationRatifier — CONFIG/WRITE-FIDELITY + RATE MATH: admin write-fidelity (setParams/clearParams/setFeeConfig),
// getEffectiveFeeConfig override, the _userIsBuy directionality map, the PriceLib rate-limit math (PRICE-1..4), and the isRatified CALLBACK_SUCCESS token.

import "../setup/ratifier/ratifier_setup.spec";

// RTF-UT-01 (ORCH-3): getEffectiveFeeConfig returns the market slot when its recipient is set, else the bytes32(0) default.
// FORMULA: cfg[cb][id].recipient != 0 ? cfg[cb][id] : cfg[cb][bytes32(0)]
rule getEffectiveFeeConfigMarketOverridesActionDefault(env e, address cb, bytes32 id) {

    setupMigrationRatifier(e);

    address mRecip; uint96 mRate;
    mRecip, mRate = _Ratifier.feeConfigs(e, cb, id);

    address dRecip; uint96 dRate;
    dRecip, dRate = _Ratifier.feeConfigs(e, cb, to_bytes32(0));

    IMigrationRatifier.FeeConfig eff = getEffectiveFeeConfig(e, cb, id);

    assert(mRecip != 0
        ? (eff.feeRecipient == mRecip && eff.feeRate == mRate)
        : (eff.feeRecipient == dRecip && eff.feeRate == dRate),
        "getEffectiveFeeConfig overrides the action default with a set market slot");
}

// RTF-UT-02 (ORCH-15, REG-2): setParams writes exactly the addressed tuple and leaves every other tuple untouched.
// FORMULA: userParams[u][cb][s][t]' == p  &&  (u2,cb2,s2,t2) != (u,cb,s,t) => userParams[u2][cb2][s2][t2]' unchanged
rule setParamsWritesTupleAndLeavesOthers(env e, address u, address cb, bytes32 s, bytes32 t,
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

    assert(polA == p.interestRatePolicy && winA == p.renewalWindow && minA == p.minDuration
        && maxA == p.maxDuration && cadA == p.renewalCadence && limA == p.limitRatePerSecond,
        "setParams stores every field of the addressed tuple");
    assert(pol2b == pol2a && win2b == win2a && min2b == min2a && max2b == max2a && cad2b == cad2a && lim2b == lim2a,
        "setParams leaves every other tuple byte-identical");
}

// RTF-UT-03 (REG-3): clearParams zeroes the addressed tuple and leaves every other tuple untouched.
// FORMULA: userParams[u][cb][s][t]' == 0  &&  (u2,cb2,s2,t2) != (u,cb,s,t) => userParams[u2][cb2][s2][t2]' unchanged
rule clearParamsZeroesTupleAndLeavesOthers(env e, address u, address cb, bytes32 s, bytes32 t,
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

    assert(polA == 0 && winA == 0 && minA == 0 && maxA == 0 && cadA == 0 && limA == 0,
        "clearParams zeroes every field of the addressed tuple");
    assert(pol2b == pol2a && win2b == win2a && min2b == min2a && max2b == max2a && cad2b == cad2a && lim2b == lim2a,
        "clearParams leaves every other tuple byte-identical");
}

// RTF-UT-04 (DEFAULT-1, RATE-3): the rate-gate buy-side flag is set for exactly the three Midnight-buy callbacks.
// FORMULA: _userIsBuy(cb) <=> cb in { LEND_VAULT_TO_MIDNIGHT, BORROW_MIDNIGHT_TO_BLUE, LEND_MIDNIGHT_RENEWAL }
rule userIsBuyMatchesBuySideCallbacks(env e, address cb) {

    setupMigrationRatifier(e);

    bool isBuy = userIsBuyOfHarness(e, cb);

    assert(isBuy <=> (cb == _Ratifier.LEND_VAULT_TO_MIDNIGHT_CALLBACK
                   || cb == _Ratifier.BORROW_MIDNIGHT_TO_BLUE_CALLBACK
                   || cb == _Ratifier.LEND_MIDNIGHT_RENEWAL_CALLBACK),
        "the buy-side flag is exactly the three Midnight-buy callbacks (rate-gate directionality source)");
}

// === PriceLib — the real rate-limit math the gate runs (asserted directly on the exposed pure functions) ===

// RTF-UT-05 (PRICE-1): computePrice == WAD^2/(WAD + rate*dur), in (0, WAD], floored for the buyer / ceiled for the seller.
// FORMULA: buy == floor(WAD^2/denom) && sell == ceil(WAD^2/denom) && 0 < price <= WAD   (denom = WAD + rate*dur)
rule priceFollowsZeroCouponFormula(env e, uint256 rate, uint256 dur) {

    require(rate <= max_uint40 && dur <= max_uint32,
        "UNSAFE: uint40-rate slice — the real buy branch can feed computePrice a rate up to 2^128 (via max(policy,limit)) where pBuy==0, so the (0,WAD] lower bound holds on this slice only");

    mathint W = 10^18;
    mathint denom = W + to_mathint(rate) * to_mathint(dur);
    uint256 pBuy = computePriceOfHarness(e, true, rate, dur);
    uint256 pSell = computePriceOfHarness(e, false, rate, dur);

    assert(to_mathint(pBuy) == (W * W) / denom, "buyer price = floor(WAD^2 / (WAD + rate*dur))");
    assert(to_mathint(pSell) == (W * W + denom - 1) / denom, "seller price = ceil(WAD^2 / (WAD + rate*dur))");
    assert(pBuy > 0 && to_mathint(pBuy) <= W && pSell > 0 && to_mathint(pSell) <= W, "price stays in (0, WAD]");
}

// RTF-UT-06 (PRICE-2): rounding favors each side — the buyer's (floor) price never exceeds the seller's (ceil) price.
// FORMULA: computePrice(true, rate, dur) <= computePrice(false, rate, dur)
rule priceRoundsInProtectedUserFavor(env e, uint256 rate, uint256 dur) {

    assert(computePriceOfHarness(e, true, rate, dur) <= computePriceOfHarness(e, false, rate, dur),
        "buyer (floor) price <= seller (ceil) price — rounding favors each protected side");
}

// RTF-UT-07 (PRICE-3): computeEffectiveRate selects the tighter bound — min for the borrower, max for the lender.
// FORMULA: computeEffectiveRate(false,p,l) == min(p,l) && computeEffectiveRate(true,p,l) == max(p,l)
rule effectiveRateSelectsTighterBound(env e, uint256 p, uint256 l) {

    assert(computeEffectiveRateOfHarness(e, false, p, l) == (p < l ? p : l),
        "borrower effective rate is min(policy, limit) — the tighter ceiling");
    assert(computeEffectiveRateOfHarness(e, true, p, l) == (p > l ? p : l),
        "lender effective rate is max(policy, limit) — the tighter floor");
}

// RTF-UT-08 (PRICE-4): satisfiesRateLimit enforces the borrower ceiling (assets*WAD >= units*price) and the lender floor (<=).
// FORMULA: satisfies(false,..) <=> a*WAD >= u*priceBorrow && satisfies(true,..) <=> a*WAD <= u*priceLend
rule satisfiesRateLimitComparisonDirection(env e, uint256 u, uint256 a, uint256 lim, uint256 pol, uint256 dur) {

    require(u <= max_uint128 && a <= max_uint128 && lim <= max_uint40 && to_mathint(pol) <= 2^128 && dur <= max_uint32,
        "SAFE: Midnight uint128 units/assets, uint40 limit, policy in the getRate ghost range (<=2^128) and realistic duration — no overflow in the WAD-scaled compare");

    mathint W = 10^18;
    uint256 priceB = computePriceOfHarness(e, false, computeEffectiveRateOfHarness(e, false, pol, lim), dur);
    uint256 priceL = computePriceOfHarness(e, true, computeEffectiveRateOfHarness(e, true, pol, lim), dur);

    assert(satisfiesRateLimitOfHarness(e, false, u, a, lim, pol, dur) <=> (to_mathint(a) * W >= to_mathint(u) * to_mathint(priceB)),
        "borrower gate accepts iff assets*WAD >= units*price (ceiling)");
    assert(satisfiesRateLimitOfHarness(e, true, u, a, lim, pol, dur) <=> (to_mathint(a) * W <= to_mathint(u) * to_mathint(priceL)),
        "lender gate accepts iff assets*WAD <= units*price (floor)");
}

// === Per-callback rate-check helpers (direct characterization) ===

// RTF-UT-09 (ORCH-4): the per-callback fee-rate cap is zero on the V2->V1 exits (BMB/LMV), MAX_FEE_RATE otherwise.
// FORMULA: _maxFeeRate(cb) == (isV2ToV1(cb) ? 0 : MAX_FEE_RATE)   [MAX_FEE_RATE = 0.5e18]
rule maxFeeRateZeroOnV2ToV1Exits(env e, address cb) {

    setupMigrationRatifier(e);

    assert(to_mathint(maxFeeRateOfHarness(e, cb)) == (isV2ToV1(cb) ? 0 : 5 * 10^17),
        "the per-callback fee-rate cap is 0 on V2->V1 exits, MAX_FEE_RATE (0.5e18) otherwise");
}

// RTF-UT-10 (ORCH-13): per-callback accrual duration; the V2->V1 exit clamps to 0 once the source has matured.
// FORMULA: renewal: tgt - max(now,src) ; enter: tgt - now ; exit: now>=src ? 0 : src-now
rule computeDurationPerCallback(env e, address cb, uint256 src, uint256 tgt) {

    setupMigrationRatifier(e);

    mathint now = e.block.timestamp;
    uint256 d = computeDurationOfHarness@withrevert(e, cb, src, tgt);
    bool rev = lastReverted;

    if (cb == _Ratifier.BORROW_MIDNIGHT_RENEWAL_CALLBACK || cb == _Ratifier.LEND_MIDNIGHT_RENEWAL_CALLBACK) {
        mathint effStart = now > to_mathint(src) ? now : to_mathint(src);
        assert(rev <=> to_mathint(tgt) < effStart, "renewal: reverts iff target < effectiveStart = max(now, source)");
        assert(!rev => to_mathint(d) == to_mathint(tgt) - effStart, "renewal duration = target - max(now, source)");
    } else if (cb == _Ratifier.BORROW_BLUE_TO_MIDNIGHT_CALLBACK || cb == _Ratifier.LEND_VAULT_TO_MIDNIGHT_CALLBACK) {
        assert(rev <=> to_mathint(tgt) < now, "V1->V2 enter: reverts iff target < now");
        assert(!rev => to_mathint(d) == to_mathint(tgt) - now, "enter duration = target - now");
    } else {
        assert(!rev, "exit / other: total — zeroFloorSub never underflows");
        assert(to_mathint(d) == (now >= to_mathint(src) ? 0 : to_mathint(src) - now),
            "exit duration = zeroFloorSub(source, now); clamps to 0 once the source has matured (ORCH-13)");
    }
}

// === Effective-price / rate-gate monotone lemmas (decomposition support for RTF-HL-04/06; RTF-UT-12/14 carry the gate's limit-monotonicity, RATE-1/2) ===

// RTF-UT-11: the net seller price is non-increasing in the fee rate (borrower enter prices the offer down as the fee grows).
// FORMULA: feeLo <= feeHi => netSellerPrice(p, sf, feeLo) >= netSellerPrice(p, sf, feeHi)
rule netSellerPriceMonotoneInFee(env e, uint256 p, uint256 sf, uint256 feeLo, uint256 feeHi) {

    require(to_mathint(p) <= WAD() && to_mathint(feeHi) <= WAD() && to_mathint(sf) <= WAD(),
        "SAFE: offer price, fee rate and settlement fee are WAD-denominated fractions in [0, WAD]");
    require(feeLo <= feeHi, "SCOPE: feeLo is the smaller fee");

    assert(netSellerPriceOfHarness(e, p, sf, feeLo) >= netSellerPriceOfHarness(e, p, sf, feeHi),
        "a larger fee never raises the net seller price (non-increasing in fee)");
}

// RTF-UT-12: the borrower rate gate is monotone in the limit — a higher limit only loosens it (acceptance is monotone).
// FORMULA: limLo <= limHi => ( satisfies(false,u,a,limLo,pol,dur) => satisfies(false,u,a,limHi,pol,dur) )
rule satisfiesRateLimitMonotoneInBorrowerLimit(env e, uint256 u, uint256 a,
        uint256 limLo, uint256 limHi, uint256 pol, uint256 dur) {

    require(u <= max_uint128 && a <= max_uint128 && limHi <= max_uint40 && to_mathint(pol) <= 2^128 && dur <= max_uint32,
        "SAFE: Midnight uint128 units/assets, uint40 limit, policy in the getRate ghost range (<=2^128), realistic duration — no overflow");
    require(limLo <= limHi, "SCOPE: limLo is the tighter (smaller) limit");

    assert(satisfiesRateLimitOfHarness(e, false, u, a, limLo, pol, dur) => satisfiesRateLimitOfHarness(e, false, u, a, limHi, pol, dur),
        "borrower: a higher limit only loosens the gate (acceptance is monotone in the limit)");
}

// RTF-UT-13: the net buyer price is non-decreasing in the fee rate (lender enter prices the offer up as the fee grows).
// FORMULA: feeLo <= feeHi => netBuyerPrice(p, sf, feeLo) <= netBuyerPrice(p, sf, feeHi)
rule netBuyerPriceMonotoneInFee(env e, uint256 p, uint256 sf, uint256 feeLo, uint256 feeHi) {

    require(to_mathint(p) <= WAD() && to_mathint(feeHi) <= WAD() && to_mathint(sf) <= WAD(),
        "SAFE: offer price, fee rate and settlement fee are WAD-denominated fractions in [0, WAD]");
    require(feeLo <= feeHi, "SCOPE: feeLo is the smaller fee");

    assert(netBuyerPriceOfHarness(e, p, sf, feeLo) <= netBuyerPriceOfHarness(e, p, sf, feeHi),
        "a larger fee never lowers the net buyer price (non-decreasing in fee)");
}

// RTF-UT-14: the lender rate gate is monotone in the limit — a higher limit only tightens it (acceptance is non-increasing).
// FORMULA: limLo <= limHi => ( satisfies(true,u,a,limHi,pol,dur) => satisfies(true,u,a,limLo,pol,dur) )
rule satisfiesRateLimitMonotoneInLenderLimit(env e, uint256 u, uint256 a,
        uint256 limLo, uint256 limHi, uint256 pol, uint256 dur) {

    require(u <= max_uint128 && a <= max_uint128 && limHi <= max_uint40 && to_mathint(pol) <= 2^128 && dur <= max_uint32,
        "SAFE: Midnight uint128 units/assets, uint40 limit, policy in the getRate ghost range (<=2^128), realistic duration — no overflow");
    require(limLo <= limHi, "SCOPE: limLo is the tighter (smaller) limit");

    assert(satisfiesRateLimitOfHarness(e, true, u, a, limHi, pol, dur) => satisfiesRateLimitOfHarness(e, true, u, a, limLo, pol, dur),
        "lender: a higher limit only tightens the gate (acceptance is non-increasing in the limit)");
}

// === Entry-point success token & fee-config write-fidelity ===

// keccak256("morpho.midnight.callbackSuccess") — mirror of ConstantsLib.CALLBACK_SUCCESS
// (lib/midnight/src/libraries/ConstantsLib.sol L23), the magic value Midnight take() pins on the success path.
definition CALLBACK_SUCCESS_CVL() returns bytes32 =
    to_bytes32(0x7f87788ea698181ea4d28d1576d0ba4fc92c0dbe5bf75b43692af2ce91dbaea2);

// RTF-UT-15: isRatified returns the Midnight success token on every accepting path — the producer side of
// the take() handshake; the midnight suite proves the consumer side against an untrusted-ratifier summary,
// here the real MigrationRatifier is proven to produce the token.
// FORMULA: !revert(isRatified) => isRatified(offer, ratifierData, taker) == keccak256("morpho.midnight.callbackSuccess")
rule isRatifiedReturnsCallbackSuccess(env e, MigrationRatifierHarness.Offer offer, bytes ratifierData) {

    setupMigrationRatifier(e);

    address taker;

    bytes32 ret = isRatified(e, offer, ratifierData, taker);

    assert(ret == CALLBACK_SUCCESS_CVL(),
        "every accepting isRatified path returns the CALLBACK_SUCCESS magic value");
}

// RTF-UT-16: setFeeConfig stores exactly the addressed (callback, tenorMarketId) fee slot and leaves every
// other fee slot untouched.
// FORMULA: feeConfigs[cb][id]' == (recipient, rate)  &&  (cb2,id2) != (cb,id) => feeConfigs[cb2][id2]' unchanged
rule setFeeConfigWritesSlotAndLeavesOthers(env e, address cb, bytes32 id, uint256 rate, address recipient,
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

    assert(recipA == recipient && to_mathint(rateA) == to_mathint(rate),
        "setFeeConfig stores both fields of the addressed slot (rate <= maxFeeRate(cb) <= 0.5e18 < 2^96 on any accepting path, so the uint96 narrowing is lossless)");
    assert(recip2b == recip2a && rate2b == rate2a,
        "setFeeConfig leaves every other fee slot byte-identical");
}
