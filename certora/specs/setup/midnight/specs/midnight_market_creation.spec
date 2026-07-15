// Market-creation rules for Midnight (MC-MI-01..06).
//
// This spec imports setup/midnight.spec WITHOUT setup/touch_market_summary.spec, so the real
// touchMarket body (src/Midnight.sol L755-791) executes here — the ONLY conf in the suite where
// the creation branch is live (the public-function internal summary makes
// creation dead code everywhere else). IdLib.toId/storeInCode stay summarized (id_lib.spec), so
// the verified content is the creation-branch VALIDATION and STATE WRITES, not the id hashing.
//
// The id-keyed ghost mirrors of midnight.spec (tickSpacing, defaults, consumed, ...) are active;
// marketState fee/aggregate fields have no hooks in this regime and are read via direct storage
// access (hook-free by design).

import "setup/midnight.spec";

definition MAX_MATURITY_HORIZON() returns mathint = 3153600000; // 100 * 365 days (src L758)

// MC-MI-01 (satisfy): market creation is reachable — calling touchMarket on a market that has never
// been created can bring it into existence, with its tick spacing (the granularity of price ticks
// at which offers can be placed and filled) set to the protocol default of 4.
// FORMULA: satisfy: exists execution of touchMarket(market) with tickSpacing[market] == 0.
//          tickSpacing[market]' == 4
rule touchMarketCreatesReachable(env e, MidnightHarness.Market market) {
    setupMidnight(e);
    bytes32 id = toId(e, market);
    require(ghostMiMarketTickSpacing[id] == 0, "untouched market");

    touchMarket(e, market);

    satisfy(ghostMiMarketTickSpacing[id] == 4);
}

// MC-MI-02: a market can only be created with sound parameters — if creation succeeds, every
// validation gate held: the maturity date is at most 100 years away, the collateral list is
// non-empty and within the protocol bound, collateral tokens are non-zero and strictly ascending,
// each collateral's loan-to-liquidation-value threshold (lltv) is a governance-enabled tier, each
// collateral's liquidation cursor (which fixes its maxLif) is a governance-enabled cursor, and the
// resulting maximum liquidation incentive factor (maxLif, the cap on the collateral bonus a
// liquidator can earn) stays within bounds (maxLif <= 2*WAD, and lltv*maxLif <= 0.999e18*WAD unless
// lltv == WAD). Checked over the two modeled collateral slots.
// FORMULA: tickSpacing[market] == 0 AND touchMarket(market) succeeds =>
//          maturity <= now + 100 years
//          AND 1 <= len(collateralParams) <= MAX_COLLATERALS
//          AND collateralParams[0].token != 0
//          AND isLltvEnabled(collateralParams[0].lltv)
//          AND isLiquidationCursorEnabled(collateralParams[0].liquidationCursor)
//          AND maxLif(lltv[0], cursor[0]) <= 2*WAD
//          AND (lltv[0] == WAD OR lltv[0]*maxLif(lltv[0], cursor[0]) <= 0.999e18*WAD)
//          AND (len(collateralParams) > 1 => the same for slot 1 with token[1] > token[0])
rule creationValidatesMarketParams(env e, MidnightHarness.Market market) {
    setupMidnight(e);
    bytes32 id = toId(e, market);
    require(ghostMiMarketTickSpacing[id] == 0, "untouched: the call exercises the creation branch");

    touchMarket(e, market);

    assert(to_mathint(market.maturity) <= e.block.timestamp + MAX_MATURITY_HORIZON(),
        "creation enforces maturity <= now + 100 years (MaturityTooFar)");
    assert(market.collateralParams.length >= 1
        && to_mathint(market.collateralParams.length) <= MAX_COLLATERALS_CVL(),
        "creation enforces 1 <= collateralParams.length <= MAX_COLLATERALS");
    assert(market.collateralParams[0].token != 0,
        "creation enforces ascending collateral tokens from non-zero");
    assert(ghostMiIsLltvEnabled[market.collateralParams[0].lltv],
        "creation enforces a governance-enabled lltv tier for slot 0 (LltvNotEnabled)");
    assert(ghostMiIsLiquidationCursorEnabled[market.collateralParams[0].liquidationCursor],
        "creation enforces a governance-enabled liquidation cursor for slot 0 (LiquidationCursorNotEnabled)");
    assert(to_mathint(maxLifCVL(market.collateralParams[0].lltv, market.collateralParams[0].liquidationCursor))
            <= 2 * WAD_CVL(),
        "creation enforces maxLif <= 2*WAD for slot 0 (InvalidMaxLif)");
    assert(market.collateralParams[0].lltv == require_uint256(WAD_CVL())
        || to_mathint(market.collateralParams[0].lltv)
             * to_mathint(maxLifCVL(market.collateralParams[0].lltv, market.collateralParams[0].liquidationCursor))
           <= MAXLIF_LLTV_PRODUCT_CAP_CVL() * WAD_CVL(),
        "creation enforces lltv*maxLif <= 0.999e18*WAD when lltv < WAD for slot 0 (MaxLifTooHigh)");
    assert(market.collateralParams.length > 1 => (
        market.collateralParams[1].token > market.collateralParams[0].token
        && ghostMiIsLltvEnabled[market.collateralParams[1].lltv]
        && ghostMiIsLiquidationCursorEnabled[market.collateralParams[1].liquidationCursor]
        && to_mathint(maxLifCVL(market.collateralParams[1].lltv, market.collateralParams[1].liquidationCursor))
             <= 2 * WAD_CVL()
        && (market.collateralParams[1].lltv == require_uint256(WAD_CVL())
            || to_mathint(market.collateralParams[1].lltv)
                 * to_mathint(maxLifCVL(market.collateralParams[1].lltv, market.collateralParams[1].liquidationCursor))
               <= MAXLIF_LLTV_PRODUCT_CAP_CVL() * WAD_CVL())
    ), "creation enforces sorted tokens / enabled lltv & cursor / valid maxLif bounds for slot 1");
}

// MC-MI-03: market creation copies the fee schedule configured for the market's loan token into the
// new market verbatim — all seven breakpoints of the settlement fee (the fee charged on trades and
// collected into a per-token claimable pot) and the continuous fee rate charged on outstanding
// debt. The protocol therefore cannot create a market with fees other than the defaults set by the
// fee setter.
// FORMULA: tickSpacing[market] == 0 AND touchMarket(market) succeeds =>
//          (forall k in 0..6. settlementFeeCbp[market][k]' == defaultSettlementFeeCbp[loanToken][k])
//          AND continuousFee[market]' == defaultContinuousFee[loanToken]
rule creationCopiesDefaultFees(env e, MidnightHarness.Market market) {
    setupMidnight(e);
    bytes32 id = toId(e, market);
    require(ghostMiMarketTickSpacing[id] == 0, "untouched: the call exercises the creation branch");

    mathint d0 = ghostMiDefaultSettlementFeeCbp16[market.loanToken][0];
    mathint d1 = ghostMiDefaultSettlementFeeCbp16[market.loanToken][1];
    mathint d2 = ghostMiDefaultSettlementFeeCbp16[market.loanToken][2];
    mathint d3 = ghostMiDefaultSettlementFeeCbp16[market.loanToken][3];
    mathint d4 = ghostMiDefaultSettlementFeeCbp16[market.loanToken][4];
    mathint d5 = ghostMiDefaultSettlementFeeCbp16[market.loanToken][5];
    mathint d6 = ghostMiDefaultSettlementFeeCbp16[market.loanToken][6];
    mathint dcf = ghostMiDefaultContinuousFee32[market.loanToken];

    touchMarket(e, market);

    assert(to_mathint(currentContract.marketState[id].settlementFeeCbp0) == d0
        && to_mathint(currentContract.marketState[id].settlementFeeCbp1) == d1
        && to_mathint(currentContract.marketState[id].settlementFeeCbp2) == d2
        && to_mathint(currentContract.marketState[id].settlementFeeCbp3) == d3
        && to_mathint(currentContract.marketState[id].settlementFeeCbp4) == d4
        && to_mathint(currentContract.marketState[id].settlementFeeCbp5) == d5
        && to_mathint(currentContract.marketState[id].settlementFeeCbp6) == d6,
        "creation copies the seven default settlement-fee breakpoints verbatim (src L777-784)");
    assert(to_mathint(currentContract.marketState[id].continuousFee) == dcf,
        "creation copies the default continuous fee verbatim (src L785)");
}

// MC-MI-04: market creation initializes the tick spacing (the granularity of price ticks at which
// offers can be placed and filled) to exactly the protocol default of 4. A wrong initial spacing
// would silently change which prices lenders and borrowers can trade at.
// FORMULA: tickSpacing[market] == 0 AND touchMarket(market) succeeds => tickSpacing[market]' == 4
rule creationSetsTickSpacingDefault(env e, MidnightHarness.Market market) {
    setupMidnight(e);
    bytes32 id = toId(e, market);
    require(ghostMiMarketTickSpacing[id] == 0, "untouched: the call exercises the creation branch");

    touchMarket(e, market);

    assert(ghostMiMarketTickSpacing[id] == 4,
        "creation sets tickSpacing := DEFAULT_TICK_SPACING (4) exactly (src L776)");
}

// MC-MI-05: market creation can only happen once — touching an already-existing market is a no-op,
// so a repeat call can never re-run creation and overwrite the market's tick spacing, fee schedule,
// or aggregate accounting (the market's total loan units, the cumulative bad-debt socialization
// factor, the loan tokens available for withdrawal, and the continuous-fee credit owed to the
// protocol).
// FORMULA: after touchMarket(market), a second touchMarket(market) satisfies X' == X for X in
//          {tickSpacing[market], settlementFeeCbp0[market], settlementFeeCbp6[market],
//          continuousFee[market], totalUnits, lossFactor, withdrawable, continuousFeeCredit}
rule touchMarketIdempotent(env e, MidnightHarness.Market market) {
    setupMidnight(e);
    bytes32 id = toId(e, market);

    touchMarket(e, market);

    mathint ts1   = ghostMiMarketTickSpacing[id];
    mathint cbp0  = currentContract.marketState[id].settlementFeeCbp0;
    mathint cbp6  = currentContract.marketState[id].settlementFeeCbp6;
    mathint cf1   = currentContract.marketState[id].continuousFee;
    mathint tu1   = currentContract.marketState[id].totalUnits;
    mathint lf1   = currentContract.marketState[id].lossFactor;
    mathint w1    = currentContract.marketState[id].withdrawable;
    mathint cfc1  = currentContract.marketState[id].continuousFeeCredit;

    touchMarket(e, market);

    assert(ghostMiMarketTickSpacing[id] == ts1
        && to_mathint(currentContract.marketState[id].settlementFeeCbp0) == cbp0
        && to_mathint(currentContract.marketState[id].settlementFeeCbp6) == cbp6
        && to_mathint(currentContract.marketState[id].continuousFee) == cf1
        && to_mathint(currentContract.marketState[id].totalUnits) == tu1
        && to_mathint(currentContract.marketState[id].lossFactor) == lf1
        && to_mathint(currentContract.marketState[id].withdrawable) == w1
        && to_mathint(currentContract.marketState[id].continuousFeeCredit) == cfc1,
        "a second touchMarket on a touched market is a no-op");
}

// MC-MI-06: market creation writes only configuration and never moves money — no lender's credit
// units, no borrower's debt, no fee accrued on a position but not yet collected (pendingFee), none
// of the market aggregates (the market's total loan units (totalUnits), the cumulative bad-debt
// socialization factor (lossFactor), the loan tokens available for withdrawal (withdrawable), and
// the continuous-fee credit (cfc) owed to the protocol), and no token's claimable settlement-fee
// pot changes when a market is created.
// FORMULA: tickSpacing[market] == 0 AND touchMarket(market) succeeds =>
//          forall u, token.
//          credit[u]' == credit[u] AND debt[u]' == debt[u] AND pendingFee[u]' == pendingFee[u]
//          AND totalUnits' == totalUnits AND lossFactor' == lossFactor
//          AND withdrawable' == withdrawable AND continuousFeeCredit' == continuousFeeCredit
//          AND claimableSettlementFee[token]' == claimableSettlementFee[token]
rule creationDoesNotTouchPositionsOrPots(
    env e, MidnightHarness.Market market, address u, address token
) {
    setupMidnight(e);
    bytes32 id = toId(e, market);
    require(ghostMiMarketTickSpacing[id] == 0, "untouched: the call exercises the creation branch");

    mathint credit0 = currentContract.position[id][u].credit;
    mathint debt0   = currentContract.position[id][u].debt;
    mathint pf0     = currentContract.position[id][u].pendingFee;
    mathint tu0     = currentContract.marketState[id].totalUnits;
    mathint lf0     = currentContract.marketState[id].lossFactor;
    mathint w0      = currentContract.marketState[id].withdrawable;
    mathint cfc0    = currentContract.marketState[id].continuousFeeCredit;
    mathint claim0  = ghostMiClaimableSettlementFee256[token];

    touchMarket(e, market);

    assert(to_mathint(currentContract.position[id][u].credit) == credit0
        && to_mathint(currentContract.position[id][u].debt) == debt0
        && to_mathint(currentContract.position[id][u].pendingFee) == pf0,
        "creation never touches positions");
    assert(to_mathint(currentContract.marketState[id].totalUnits) == tu0
        && to_mathint(currentContract.marketState[id].lossFactor) == lf0
        && to_mathint(currentContract.marketState[id].withdrawable) == w0
        && to_mathint(currentContract.marketState[id].continuousFeeCredit) == cfc0,
        "creation never touches the market aggregates");
    assert(ghostMiClaimableSettlementFee256[token] == claim0,
        "creation never touches the settlement-fee pot");
}

// MC-MI-07: a market can only be created with a self-consistent identity — its embedded chainId must
// match the live chain and its embedded midnight address must be this contract. This binds every
// created market's id to the deploying chain and instance (the replacement for the old
// INITIAL_CHAIN_ID immutable), so a market struct minted for another chain or another Midnight
// instance can never be brought into existence here.
// FORMULA: tickSpacing[market] == 0 AND touchMarket(market) succeeds =>
//          market.chainId == block.chainid AND market.midnight == address(this)
rule creationValidatesChainIdAndMidnight(env e, MidnightHarness.Market market) {
    setupMidnight(e);
    bytes32 id = toId(e, market);
    require(ghostMiMarketTickSpacing[id] == 0, "untouched: the call exercises the creation branch");

    touchMarket(e, market);

    assert(to_mathint(market.chainId) == to_mathint(blockChainId(e)),
        "creation enforces market.chainId == block.chainid (InvalidChainId)");
    assert(market.midnight == _Midnight,
        "creation enforces market.midnight == address(this) (InvalidMidnight)");
}
