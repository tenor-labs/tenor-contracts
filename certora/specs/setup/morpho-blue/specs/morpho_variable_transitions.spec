import "./morpho_valid_state.spec";

// ========== SKIPPED GHOSTS ==========
//
// Free-changing config (admin-settable, no transition constraint):
//   ghostMbOwner -- admin can setOwner to any non-zero address (TRUSTED non-zero is a valid_state concern)
//   ghostMbFeeRecipient -- admin can setFeeRecipient to any address including 0
//   ghostMbFee128[id] -- admin can setFee to any value <= MAX_FEE (bounded by valid_state invariant)
//
// Free-changing accounting (no monotonicity or latch constraint):
//   ghostMbSupplyShares256[id][user] -- increases on supply, decreases on withdraw
//   ghostMbBorrowShares128[id][user] -- increases on borrow, decreases on repay/liquidate
//   ghostMbCollateral128[id][user] -- increases on supplyCollateral, decreases on withdrawCollateral/liquidate
//   ghostMbTotalSupplyAssets128[id] -- increases on supply/accrueInterest, decreases on withdraw/liquidate(bad debt)
//   ghostMbTotalSupplyShares128[id] -- increases on supply/accrueInterest(fees), decreases on withdraw
//   ghostMbTotalBorrowAssets128[id] -- increases on borrow/accrueInterest, decreases on repay/liquidate
//   ghostMbTotalBorrowShares128[id] -- increases on borrow, decreases on repay/liquidate
//
// Free-changing authorization (user-settable, no latch constraint):
//   ghostMbIsAuthorized[a][b] -- users can freely set/unset authorization via setAuthorization
//
// NONDET DELETE'd (effectively constant at init value):
//   ghostMbNonce256[user] -- setAuthorizationWithSig is NONDET DELETE'd, no function modifies nonce
//
// ERC20 model (CVL synthetic state, free-changing):
//   ghostERC20Balances128, ghostERC20Allowances256, ghostERC20TotalSupply256,
//   ghostERC20Decimals8, ghostErc20Accounts, ghostErc20AccountsValues,
//   ghostERC20AccountAccessed
//

// ========== VT DEFINITIONS ==========

// One-way latch: once non-zero, stays non-zero (value may change between non-zero values)
definition VALID_ZERO_NONZERO_LATCH(mathint before, mathint after) returns bool =
    before == 0 || after != 0;

//
// Boolean Enablement Flags
//

// VT-01: IRM enablement is permanent (boolean latch true)
// FORMULA: ghostMbIsIrmEnabled[irm] before => ghostMbIsIrmEnabled[irm] after
//
// enableIrm sets to true and requires !isIrmEnabled[irm]. No function sets it
// to false. Once an IRM is enabled, it remains enabled forever.
rule irmEnablementIsPermanent(env e, method f, calldataarg args, address irm)
    filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    bool enabledBefore = ghostMbIsIrmEnabled[irm];

    f(e, args);

    bool enabledAfter = ghostMbIsIrmEnabled[irm];

    assert(enabledBefore => enabledAfter,
        "IRM enablement cannot be revoked once set");
}

// VT-02: LLTV enablement is permanent (boolean latch true)
// FORMULA: ghostMbIsLltvEnabled[lltv] before => ghostMbIsLltvEnabled[lltv] after
//
// enableLltv sets to true and requires !isLltvEnabled[lltv]. No function sets
// it to false. Once an LLTV is enabled, it remains enabled forever.
rule lltvEnablementIsPermanent(env e, method f, calldataarg args, uint256 lltv)
    filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    bool enabledBefore = ghostMbIsLltvEnabled[lltv];

    f(e, args);

    bool enabledAfter = ghostMbIsLltvEnabled[lltv];

    assert(enabledBefore => enabledAfter,
        "LLTV enablement cannot be revoked once set");
}

//
// Market Params (idToMarketParams)
//

// VT-03: Market params addresses are immutable after creation
// FORMULA: forall id. ghostMbLoanToken[id] != 0 => ghostMbLoanToken[id] unchanged
//                     (and same for collateralToken, oracle, irm)
//
// createMarket is the only function that writes idToMarketParams. It requires
// lastUpdate == 0 (market not yet created), so a second write is impossible.
// Once set, these addresses never change.
rule marketParamsAddressesImmutableAfterCreation(
    env e, method f, calldataarg args, MorphoHarness.Id id
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    address loanTokenBefore = ghostMbLoanToken[id];
    address collateralTokenBefore = ghostMbCollateralToken[id];
    address oracleBefore = ghostMbOracle[id];
    address irmBefore = ghostMbIrm[id];

    f(e, args);

    address loanTokenAfter = ghostMbLoanToken[id];
    address collateralTokenAfter = ghostMbCollateralToken[id];
    address oracleAfter = ghostMbOracle[id];
    address irmAfter = ghostMbIrm[id];

    assert(loanTokenBefore != 0 => loanTokenAfter == loanTokenBefore,
        "loanToken must be immutable once set");
    assert(collateralTokenBefore != 0 => collateralTokenAfter == collateralTokenBefore,
        "collateralToken must be immutable once set");
    assert(oracleBefore != 0 => oracleAfter == oracleBefore,
        "oracle must be immutable once set");
    assert(irmBefore != 0 => irmAfter == irmBefore,
        "irm must be immutable once set");
}

// VT-04: Market lltv is immutable after creation
// FORMULA: ghostMbLltv256[id] != 0 => ghostMbLltv256[id] unchanged
//
// Same reasoning as VT-MO-03. lltv is a uint256 field in idToMarketParams,
// written once by createMarket, never modified afterward.
rule marketLltvImmutableAfterCreation(
    env e, method f, calldataarg args, MorphoHarness.Id id
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    mathint lltvBefore = ghostMbLltv256[id];

    f(e, args);

    mathint lltvAfter = ghostMbLltv256[id];

    assert(lltvBefore != 0 => lltvAfter == lltvBefore,
        "lltv must be immutable once set");
}

//
// Market Timestamp
//

// VT-05: Market lastUpdate only increases (monotonic)
// FORMULA: ghostMbLastUpdate128[id] after >= ghostMbLastUpdate128[id] before
//
// createMarket sets lastUpdate = block.timestamp. _accrueInterest sets
// lastUpdate = block.timestamp. Since block.timestamp is non-decreasing and
// these are the only writers, lastUpdate can only increase or stay the same.
rule lastUpdateOnlyIncreases(
    env e, method f, calldataarg args, MorphoHarness.Id id
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    mathint lastUpdateBefore = ghostMbLastUpdate128[id];

    f(e, args);

    mathint lastUpdateAfter = ghostMbLastUpdate128[id];

    assert(lastUpdateAfter >= lastUpdateBefore,
        "lastUpdate must only increase or stay the same");
}

// VT-06: Market lastUpdate is a zero-nonzero latch (once created, stays created)
// FORMULA: ghostMbLastUpdate128[id] != 0 before => ghostMbLastUpdate128[id] != 0 after
//
// Once a market is created (lastUpdate set to block.timestamp > 0), no function
// resets lastUpdate to 0. createMarket requires lastUpdate == 0 and only creates
// new markets. _accrueInterest updates to current block.timestamp (always > 0
// given env constraints).
rule lastUpdateNonZeroLatch(
    env e, method f, calldataarg args, MorphoHarness.Id id
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    mathint lastUpdateBefore = ghostMbLastUpdate128[id];

    f(e, args);

    mathint lastUpdateAfter = ghostMbLastUpdate128[id];

    assert(VALID_ZERO_NONZERO_LATCH(lastUpdateBefore, lastUpdateAfter),
        "once a market is created (lastUpdate non-zero), it cannot be uncreated");
}
