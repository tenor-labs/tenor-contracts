// Revert-condition rules for Midnight (one-market regime).
//
// The dual of reachability: each rule uses @withrevert + assert(condition => lastReverted) to prove a
// function MUST revert under a disallowed condition -- access-control (anti-theft), input validation,
// state preconditions. Plus a "views never revert under valid state" rule.
//
// HAVOC-caveat: every rule is SINGLE-CALL (no intermediate state-changing call before @withrevert), and
// all conditions are over hooked ghosts / args -- so the prover cannot havoc an untracked slot into a
// spurious revert. Midnight has no pause (whenNotPaused N/A). MarketNotCreated reverts are NOT covered:
// the one-market setup pins the narrowed market as touched (tickSpacing > 0), so that path is unreachable.

import "midnight_valid_state_one.spec";

//
// Access control -- role-gated admin (unconditional revert for the wrong caller)
//

// RV-MI-01: Only the protocol's role administrator (the configurator) can hand the role-administration
// power to a new account. A call to setConfigurator from any other address is rejected unconditionally,
// so control over all protocol roles cannot be hijacked.
// FORMULA: e.msg.sender != configurator => reverts(setConfigurator(newConfigurator))
rule setConfiguratorRevertsWhenNotConfigurator(env e, address newConfigurator) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender != ghostMiConfigurator, "SAFE: caller is not the configurator");
    setConfigurator@withrevert(e, newConfigurator);
    assert(lastReverted, "setConfigurator must revert for a non-configurator caller (OnlyConfigurator)");
}

// RV-MI-02: Only the protocol's role administrator (the configurator) can appoint the account that
// controls fee parameters (the feeSetter). A call to setFeeSetter from any other address is rejected
// unconditionally.
// FORMULA: e.msg.sender != configurator => reverts(setFeeSetter(newFeeSetter))
rule setFeeSetterRevertsWhenNotConfigurator(env e, address newFeeSetter) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender != ghostMiConfigurator, "SAFE: caller is not the configurator");
    setFeeSetter@withrevert(e, newFeeSetter);
    assert(lastReverted, "setFeeSetter must revert for a non-configurator caller (OnlyConfigurator)");
}

// RV-MI-03: Only the protocol's role administrator (the configurator) can appoint the account entitled
// to collect accrued protocol fees (the feeClaimer). A call to setFeeClaimer from any other address is
// rejected unconditionally, so the right to protocol fee revenue cannot be redirected.
// FORMULA: e.msg.sender != configurator => reverts(setFeeClaimer(newFeeClaimer))
rule setFeeClaimerRevertsWhenNotConfigurator(env e, address newFeeClaimer) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender != ghostMiConfigurator, "SAFE: caller is not the configurator");
    setFeeClaimer@withrevert(e, newFeeClaimer);
    assert(lastReverted, "setFeeClaimer must revert for a non-configurator caller (OnlyConfigurator)");
}

// RV-MI-04: Only the protocol's role administrator (the configurator) can appoint the account that
// controls the price granularity of market offers (the tickSpacingSetter). A call to
// setTickSpacingSetter from any other address is rejected unconditionally.
// FORMULA: e.msg.sender != configurator => reverts(setTickSpacingSetter(newTickSpacingSetter))
rule setTickSpacingSetterRevertsWhenNotConfigurator(env e, address newTickSpacingSetter) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender != ghostMiConfigurator, "SAFE: caller is not the configurator");
    setTickSpacingSetter@withrevert(e, newTickSpacingSetter);
    assert(lastReverted, "setTickSpacingSetter must revert for a non-configurator caller (OnlyConfigurator)");
}

// RV-MI-05: Only the fee administrator (the feeSetter) can change a market's settlement fee -- the fee
// charged on trades and paid into the protocol's per-token claimable pot. A call to
// setMarketSettlementFee from any other address is rejected unconditionally.
// FORMULA: e.msg.sender != feeSetter => reverts(setMarketSettlementFee(id, index, newFee))
rule setMarketSettlementFeeRevertsWhenNotFeeSetter(env e, bytes32 id, uint256 index, uint256 newFee) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender != ghostMiFeeSetter, "SAFE: caller is not the feeSetter");
    setMarketSettlementFee@withrevert(e, id, index, newFee);
    assert(lastReverted, "setMarketSettlementFee must revert for a non-feeSetter caller (OnlyFeeSetter)");
}

// RV-MI-06: Only the fee administrator (the feeSetter) can change a market's continuous fee -- the
// rate at which fee units accrue to the protocol on outstanding borrower debt. A call to
// setMarketContinuousFee from any other address is rejected unconditionally.
// FORMULA: e.msg.sender != feeSetter => reverts(setMarketContinuousFee(id, newFee))
rule setMarketContinuousFeeRevertsWhenNotFeeSetter(env e, bytes32 id, uint256 newFee) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender != ghostMiFeeSetter, "SAFE: caller is not the feeSetter");
    setMarketContinuousFee@withrevert(e, id, newFee);
    assert(lastReverted, "setMarketContinuousFee must revert for a non-feeSetter caller (OnlyFeeSetter)");
}

// RV-MI-07: Only the designated tickSpacingSetter can change a market's tick spacing -- the price
// granularity at which offers may be quoted. A call to setMarketTickSpacing from any other address is
// rejected unconditionally.
// FORMULA: e.msg.sender != tickSpacingSetter => reverts(setMarketTickSpacing(id, newTickSpacing))
rule setMarketTickSpacingRevertsWhenNotTickSpacingSetter(env e, bytes32 id, uint256 newTickSpacing) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender != ghostMiTickSpacingSetter, "SAFE: caller is not the tickSpacingSetter");
    setMarketTickSpacing@withrevert(e, id, newTickSpacing);
    assert(lastReverted, "setMarketTickSpacing must revert for a non-tickSpacingSetter caller (OnlyTickSpacingSetter)");
}

// RV-MI-08: Only the designated fee collector (the feeClaimer) can withdraw accumulated settlement
// fees from the protocol's per-token pot. A call to claimSettlementFee from any other address is
// rejected unconditionally, so protocol fee revenue cannot be stolen.
// FORMULA: e.msg.sender != feeClaimer => reverts(claimSettlementFee(token, amount, receiver))
rule claimSettlementFeeRevertsWhenNotFeeClaimer(env e, address token, uint256 amount, address receiver) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender != ghostMiFeeClaimer, "SAFE: caller is not the feeClaimer");
    claimSettlementFee@withrevert(e, token, amount, receiver);
    assert(lastReverted, "claimSettlementFee must revert for a non-feeClaimer caller (OnlyFeeClaimer)");
}

// RV-MI-09: Only the designated fee collector (the feeClaimer) can withdraw the continuous-fee credit
// (cfc) -- fee units accrued to the protocol from interest on borrower debt. A call to
// claimContinuousFee from any other address is rejected unconditionally.
// FORMULA: e.msg.sender != feeClaimer => reverts(claimContinuousFee(market, amount, receiver))
rule claimContinuousFeeRevertsWhenNotFeeClaimer(env e, MidnightHarness.Market market, uint256 amount, address receiver) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender != ghostMiFeeClaimer, "SAFE: caller is not the feeClaimer");
    claimContinuousFee@withrevert(e, market, amount, receiver);
    assert(lastReverted, "claimContinuousFee must revert for a non-feeClaimer caller (OnlyFeeClaimer)");
}

//
// Access control -- onBehalf authorization (anti-theft: cannot act on another's position)
//

// RV-MI-10: Nobody can pull loan tokens out of another lender's position. Withdrawing on behalf of an
// account reverts unless the caller is that account or a delegate it has approved via isAuthorized.
// FORMULA: e.msg.sender != onBehalf AND NOT isAuthorized[onBehalf][e.msg.sender]
//          => reverts(withdraw(market, units, onBehalf, receiver))
rule withdrawRevertsWhenUnauthorized(env e, MidnightHarness.Market market, uint256 units, address onBehalf, address receiver) {
    setupValidStateOneMidnight(e);
    require(onBehalf != e.msg.sender && !ghostMiIsAuthorized[onBehalf][e.msg.sender], "SAFE: caller not authorized for onBehalf");
    withdraw@withrevert(e, market, units, onBehalf, receiver);
    assert(lastReverted, "withdraw must revert when the caller is neither onBehalf nor authorized");
}

// RV-MI-11: Nobody can take collateral a borrower has posted. Withdrawing collateral on behalf of an
// account reverts unless the caller is that account or a delegate it has approved via isAuthorized.
// FORMULA: e.msg.sender != onBehalf AND NOT isAuthorized[onBehalf][e.msg.sender]
//          => reverts(withdrawCollateral(market, collateralIndex, assets, onBehalf, receiver))
rule withdrawCollateralRevertsWhenUnauthorized(env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 assets, address onBehalf, address receiver) {
    setupValidStateOneMidnight(e);
    require(onBehalf != e.msg.sender && !ghostMiIsAuthorized[onBehalf][e.msg.sender], "SAFE: caller not authorized for onBehalf");
    withdrawCollateral@withrevert(e, market, collateralIndex, assets, onBehalf, receiver);
    assert(lastReverted, "withdrawCollateral must revert when the caller is neither onBehalf nor authorized");
}

// RV-MI-12: Repaying a borrower's debt is restricted to the borrower themselves or a delegate they
// have approved via isAuthorized; a repay attempt on behalf of another account by anyone else reverts,
// so third parties cannot manipulate someone else's debt position.
// FORMULA: e.msg.sender != onBehalf AND NOT isAuthorized[onBehalf][e.msg.sender]
//          => reverts(repay(market, units, onBehalf, callback, data))
rule repayRevertsWhenUnauthorized(env e, MidnightHarness.Market market, uint256 units, address onBehalf, address callback, bytes data) {
    setupValidStateOneMidnight(e);
    require(onBehalf != e.msg.sender && !ghostMiIsAuthorized[onBehalf][e.msg.sender], "SAFE: caller not authorized for onBehalf");
    repay@withrevert(e, market, units, onBehalf, callback, data);
    assert(lastReverted, "repay must revert when the caller is neither onBehalf nor authorized");
}

// RV-MI-13: Adding collateral to another user's position requires that user's consent: supplyCollateral
// on behalf of an account reverts unless the caller is that account or a delegate it has approved via
// isAuthorized, so nobody can alter someone else's collateral profile uninvited.
// FORMULA: e.msg.sender != onBehalf AND NOT isAuthorized[onBehalf][e.msg.sender]
//          => reverts(supplyCollateral(market, collateralIndex, assets, onBehalf))
rule supplyCollateralRevertsWhenUnauthorized(env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 assets, address onBehalf) {
    setupValidStateOneMidnight(e);
    require(onBehalf != e.msg.sender && !ghostMiIsAuthorized[onBehalf][e.msg.sender], "SAFE: caller not authorized for onBehalf");
    supplyCollateral@withrevert(e, market, collateralIndex, assets, onBehalf);
    assert(lastReverted, "supplyCollateral must revert when the caller is neither onBehalf nor authorized");
}

// RV-MI-14: Delegation rights cannot be self-granted: only the account itself, or a delegate it has
// already approved via isAuthorized, can change who is authorized to act on its positions. Any other
// caller's attempt to rewrite an account's authorizations reverts, ruling out privilege escalation.
// FORMULA: e.msg.sender != onBehalf AND NOT isAuthorized[onBehalf][e.msg.sender]
//          => reverts(setIsAuthorized(authorized, newIsAuthorized, onBehalf))
rule setIsAuthorizedRevertsWhenUnauthorized(env e, address authorized, bool newIsAuthorized, address onBehalf) {
    setupValidStateOneMidnight(e);
    require(onBehalf != e.msg.sender && !ghostMiIsAuthorized[onBehalf][e.msg.sender], "SAFE: caller not authorized for onBehalf");
    setIsAuthorized@withrevert(e, authorized, newIsAuthorized, onBehalf);
    assert(lastReverted, "setIsAuthorized must revert when the caller is neither onBehalf nor authorized");
}

// RV-MI-15: Nobody can execute a trade in someone else's name through the take() trade entry point
// (a buyer fills a maker's offer): a call naming an account as the taker reverts unless the caller is
// that account or a delegate it has approved via isAuthorized.
// FORMULA: e.msg.sender != taker AND NOT isAuthorized[taker][e.msg.sender] => reverts(take(offer, ..., taker, ...))
rule takeRevertsWhenTakerUnauthorized(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    require(taker != e.msg.sender && !ghostMiIsAuthorized[taker][e.msg.sender], "SAFE: caller not authorized for taker");
    take@withrevert(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    assert(lastReverted, "take must revert when the caller is neither the taker nor authorized by the taker");
}

//
// Input / state validation (conditional revert)
//

// RV-MI-16: A user who owes nothing cannot be liquidated: any liquidate call targeting a borrower with
// zero outstanding debt reverts, so a liquidator can never seize collateral from a debt-free account.
// FORMULA: debt[borrower] == 0 => reverts(liquidate(market, ..., borrower, ...))
rule liquidateRevertsWhenNotBorrower(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode, address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    bool noDebt = ghostMiOnePositionDebt128[borrower] == 0;
    liquidate@withrevert(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);
    assert(noDebt => lastReverted, "liquidate must revert when the borrower has no debt (NotBorrower)");
}

// RV-MI-17: A liquidator must name the trade by exactly one side: either the amount of collateral to
// seize (seizedAssets) or the amount of debt to repay (repaidUnits) -- the other is derived by the
// protocol. Specifying both at once is ambiguous and the call reverts.
// FORMULA: seizedAssets != 0 AND repaidUnits != 0 => reverts(liquidate(market, collateralIndex, seizedAssets, repaidUnits, ...))
rule liquidateRevertsOnInconsistentInput(
    env e, MidnightHarness.Market market, uint256 collateralIndex, uint256 seizedAssets,
    uint256 repaidUnits, address borrower, bool postMaturityMode, address receiver, address callback, bytes data
) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(borrower), "UNSAFE: borrower in the narrowed three-user set");
    bool bothNonZero = seizedAssets != 0 && repaidUnits != 0;
    liquidate@withrevert(e, market, collateralIndex, seizedAssets, repaidUnits, borrower, postMaturityMode, receiver, callback, data);
    assert(bothNonZero => lastReverted, "liquidate must revert when both seizedAssets and repaidUnits are non-zero");
}

// RV-MI-18: A maker cannot trade with themselves: the take() trade entry point (a buyer fills a
// maker's offer) rejects any fill in which the taker is the same account as the offer's maker,
// preventing self-dealing wash trades.
// FORMULA: offer.maker == taker => reverts(take(offer, ..., taker, ...))
rule takeRevertsOnSelfTake(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    bool selfTake = offer.maker == taker;
    take@withrevert(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    assert(selfTake => lastReverted, "take must revert on a self-take (offer.maker == taker)");
}

// RV-MI-19: An offer must bound its size in exactly one denomination -- either a cap in loan-token
// assets (maxAssets) or a cap in loan units (maxUnits). The take() trade entry point (a buyer fills a
// maker's offer) reverts on any offer that sets both caps at once.
// FORMULA: offer.maxAssets != 0 AND offer.maxUnits != 0 => reverts(take(offer, ...))
rule takeRevertsOnBothCapsNonZero(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    bool bothCaps = offer.maxAssets != 0 && offer.maxUnits != 0;
    take@withrevert(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    assert(bothCaps => lastReverted, "take must revert when the offer sets both maxAssets and maxUnits (InvalidOfferCaps)");
}

// RV-MI-20: The per-group consumed counter -- which tracks how much of a maker's signed offer quota has
// already been filled -- can only move forward. Even an account's owner or approved delegate cannot
// rewind it below its current value: such a call reverts, so spent offer capacity can never be restored.
// FORMULA: amount < consumed[onBehalf][group] => reverts(setConsumed(group, amount, onBehalf))
rule setConsumedRevertsOnNonMonotone(env e, bytes32 group, uint128 amount, address onBehalf) {
    setupValidStateOneMidnight(e);
    require(onBehalf == e.msg.sender || ghostMiIsAuthorized[onBehalf][e.msg.sender], "SAFE: caller authorized (isolate the monotonicity guard)");
    bool nonMonotone = to_mathint(amount) < ghostMiConsumed256[onBehalf][group];
    setConsumed@withrevert(e, group, amount, onBehalf);
    assert(nonMonotone => lastReverted, "setConsumed must revert when amount < current consumed (monotonicity)");
}

//
// Views never revert under a valid state (P11)
//

// RV-MI-21: The core read-only getters always answer: in any valid protocol state, querying a lender's
// credit units, a borrower's debt, the market's total loan units (totalUnits), or the loan tokens
// currently available for withdrawal from the market (withdrawable) can never revert, so off-chain
// integrators and on-chain callers can always read positions and market totals.
// FORMULA: NOT reverts(credit(id, user)) AND NOT reverts(debt(id, user))
//          AND NOT reverts(totalUnits(id)) AND NOT reverts(withdrawable(id))
rule coreViewsNeverRevert(env e, MidnightHarness.Market market, address user) {
    setupValidStateOneMidnight(e);
    require(VALID_POSITION_USER(user), "UNSAFE: user in the narrowed three-user set");
    bytes32 id = toId(e, market);

    credit@withrevert(e, id, user);
    assert(!lastReverted, "credit must never revert under a valid state");

    debt@withrevert(e, id, user);
    assert(!lastReverted, "debt must never revert under a valid state");

    totalUnits@withrevert(e, id);
    assert(!lastReverted, "totalUnits must never revert under a valid state");

    withdrawable@withrevert(e, id);
    assert(!lastReverted, "withdrawable must never revert under a valid state");
}

//
// Governance enable-functions and new take gates (3836155)
//

// RV-MI-22: Only the configurator can enable a new LLTV tier; enableLltv from any other address is
// rejected unconditionally, so the set of borrowable loan-to-liquidation thresholds cannot be widened
// by an unauthorized caller.
// FORMULA: e.msg.sender != configurator => reverts(enableLltv(lltv))
rule enableLltvRevertsWhenNotConfigurator(env e, uint256 lltv) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender != ghostMiConfigurator, "SAFE: caller is not the configurator");
    enableLltv@withrevert(e, lltv);
    assert(lastReverted, "enableLltv must revert for a non-configurator caller (OnlyConfigurator)");
}

// RV-MI-23: Only the configurator can enable a new liquidation cursor; enableLiquidationCursor from
// any other address is rejected unconditionally.
// FORMULA: e.msg.sender != configurator => reverts(enableLiquidationCursor(liquidationCursor))
rule enableLiquidationCursorRevertsWhenNotConfigurator(env e, uint256 liquidationCursor) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender != ghostMiConfigurator, "SAFE: caller is not the configurator");
    enableLiquidationCursor@withrevert(e, liquidationCursor);
    assert(lastReverted, "enableLiquidationCursor must revert for a non-configurator caller (OnlyConfigurator)");
}

// RV-MI-24: An LLTV tier above 100% (WAD) is nonsensical and cannot be enabled: even the configurator's
// enableLltv reverts when lltv > WAD, so maxLif's denominator stays well-defined for every tier.
// FORMULA: lltv > WAD => reverts(enableLltv(lltv))
rule enableLltvRevertsOnLltvAboveWad(env e, uint256 lltv) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender == ghostMiConfigurator, "SAFE: configurator caller (isolate the bound gate)");
    bool lltvAboveWad = to_mathint(lltv) > WAD_CVL();
    enableLltv@withrevert(e, lltv);
    assert(lltvAboveWad => lastReverted, "enableLltv must revert when lltv > WAD (InvalidLltv)");
}

// RV-MI-25: A liquidation cursor must be strictly below 100% (WAD) so that maxLif's denominator
// (WAD - cursor*(WAD - lltv)/WAD) stays positive for every enabled lltv: even the configurator's
// enableLiquidationCursor reverts when liquidationCursor >= WAD.
// FORMULA: liquidationCursor >= WAD => reverts(enableLiquidationCursor(liquidationCursor))
rule enableLiquidationCursorRevertsOnCursorAtOrAboveWad(env e, uint256 liquidationCursor) {
    setupValidStateOneMidnight(e);
    require(e.msg.sender == ghostMiConfigurator, "SAFE: configurator caller (isolate the bound gate)");
    bool cursorGteWad = to_mathint(liquidationCursor) >= WAD_CVL();
    enableLiquidationCursor@withrevert(e, liquidationCursor);
    assert(cursorGteWad => lastReverted,
        "enableLiquidationCursor must revert when liquidationCursor >= WAD (InvalidLiquidationCursor)");
}

// RV-MI-26: A maker buyer is protected against future continuous-fee increases: the take() trade entry
// point reverts when the market's current continuous fee exceeds the offer's continuousFeeCap, so an
// offer can never be filled at a continuous fee higher than the maker agreed to.
// FORMULA: continuousFee(toId(offer.market)) > offer.continuousFeeCap => reverts(take(offer, ...))
rule takeRevertsOnContinuousFeeAboveOfferCap(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    bytes32 id = toId(e, offer.market);
    bool feeAboveCap = to_mathint(offer.continuousFeeCap) < to_mathint(continuousFee(e, id));
    take@withrevert(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    assert(feeAboveCap => lastReverted,
        "take must revert when market continuousFee > offer.continuousFeeCap (ContinuousFeeAboveOfferCap)");
}

// RV-MI-27: The unused settlement receiver must be left zero: take() reverts if the offer is a buy and
// offer.receiverIfMakerIsSeller is non-zero, or if the offer is a sell and receiverIfTakerIsSeller is
// non-zero — guarding against silently mis-routed seller proceeds.
// FORMULA: (offer.buy ? offer.receiverIfMakerIsSeller != 0 : receiverIfTakerIsSeller != 0)
//          => reverts(take(offer, ..., receiverIfTakerIsSeller, ...))
rule takeRevertsOnUnusedReceiverNonZero(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    bool unusedReceiverNonZero = offer.buy
        ? offer.receiverIfMakerIsSeller != 0
        : receiverIfTakerIsSeller != 0;
    take@withrevert(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    assert(unusedReceiverNonZero => lastReverted,
        "take must revert when the unused receiver is non-zero (UnusedReceiverMustBeZero)");
}

// RV-MI-28: An offer must bound its size in exactly one denomination — leaving BOTH maxAssets and
// maxUnits at zero is rejected by take() (the complement of RV-MI-19's both-non-zero case).
// FORMULA: offer.maxAssets == 0 AND offer.maxUnits == 0 => reverts(take(offer, ...))
rule takeRevertsOnBothCapsZero(
    env e, MidnightHarness.Offer offer, bytes ratifierData, uint256 units, address taker,
    address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData
) {
    setupValidStateOneMidnight(e);
    bool bothCapsZero = offer.maxAssets == 0 && offer.maxUnits == 0;
    take@withrevert(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    assert(bothCapsZero => lastReverted, "take must revert when neither maxAssets nor maxUnits is set (InvalidOfferCaps)");
}
