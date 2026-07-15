import "./setup/morpho_many.spec";

// ========== SETUP ==========

function setupValidStateManyBlue(env e) {
    setupManyBlue(e);
    requireInvariant feeBounded(e);
    requireInvariant feeRequiresMarket(e);
    requireInvariant lastUpdateBoundedByTimestamp(e);
    requireInvariant lastUpdateMinBound(e);
    requireInvariant liquidityInvariant(e);
    requireInvariant supplySharesSolvency(e);
    requireInvariant borrowSharesSolvency(e);
    requireInvariant nonExistentMarketIsZero(e);
    requireInvariant nonExistentMarketParamsAreZero(e);
    requireInvariant marketIrmIsEnabled(e);
    requireInvariant marketLltvIsEnabled(e);
    requireInvariant enabledLltvBelowWad(e);
    requireInvariant marketLltvBelowWad(e);
    requireInvariant supplySharesRequiresMarket(e);
    requireInvariant borrowSharesRequiresMarket(e);
    requireInvariant collateralRequiresMarket(e);
    requireInvariant supplyAssetsRequiresMarket(e);
    requireInvariant supplySharesTotalRequiresMarket(e);
    requireInvariant borrowAssetsRequiresMarket(e);
    requireInvariant borrowSharesTotalRequiresMarket(e);
    requireInvariant nonExistentMarketPositionsZero(e);
    requireInvariant alwaysCollateralized(e);
    requireInvariant zeroDoesNotAuthorize(e);
}

function SETUP_MANY_BLUE(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupValidStateManyBlue(e);
}

// ========== INVARIANTS ==========

// VS-01: Fee bounded by MAX_FEE
// FORMULA: forall id. ghostMbFee128[id] <= MAX_FEE_CVL()
//
// setFee enforces require(newFee <= MAX_FEE). createMarket leaves fee at 0.
// No other function writes to fee.
invariant feeBounded(env e)
    forall MorphoHarness.Id id.
        ghostMbFee128[id] <= MAX_FEE_CVL()
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-02: Fee requires market existence
// FORMULA: forall id. ghostMbFee128[id] != 0 => ghostMbLastUpdate128[id] != 0
//
// setFee requires market[id].lastUpdate != 0. createMarket leaves fee at 0.
invariant feeRequiresMarket(env e)
    forall MorphoHarness.Id id.
        ghostMbFee128[id] != 0 => ghostMbLastUpdate128[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-03: Last update bounded by block timestamp
// FORMULA: forall id. ghostMbLastUpdate128[id] != 0 => ghostMbLastUpdate128[id] <= to_mathint(e.block.timestamp)
//
// lastUpdate is always set to uint128(block.timestamp). Since block.timestamp
// is non-decreasing, the stored value never exceeds the current timestamp.
invariant lastUpdateBoundedByTimestamp(env e)
    forall MorphoHarness.Id id.
        ghostMbLastUpdate128[id] != 0
        => ghostMbLastUpdate128[id] <= to_mathint(e.block.timestamp)
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-04: Last update minimum bound
// FORMULA: forall id. ghostMbLastUpdate128[id] != 0 => ghostMbLastUpdate128[id] >= MIN_BLOCK_TIMESTAMP()
//
// lastUpdate is set to block.timestamp, and env constraints ensure
// block.timestamp >= MIN_BLOCK_TIMESTAMP (= max_uint16 = 65535).
invariant lastUpdateMinBound(env e)
    forall MorphoHarness.Id id.
        ghostMbLastUpdate128[id] != 0
        => ghostMbLastUpdate128[id] >= MIN_BLOCK_TIMESTAMP()
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-05: Liquidity invariant -- total borrow <= total supply
// FORMULA: forall id. ghostMbLastUpdate128[id] != 0
//                  => ghostMbTotalBorrowAssets128[id] <= ghostMbTotalSupplyAssets128[id]
//
// borrow() and withdraw() enforce totalBorrowAssets <= totalSupplyAssets after
// state changes. supply increases totalSupplyAssets. repay decreases
// totalBorrowAssets. _accrueInterest adds equal interest to both.
// liquidate bad debt decreases both by equal badDebtAssets.
invariant liquidityInvariant(env e)
    forall MorphoHarness.Id id.
        ghostMbLastUpdate128[id] != 0
        => ghostMbTotalBorrowAssets128[id] <= ghostMbTotalSupplyAssets128[id]
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-06: Supply shares solvency -- total >= sum of individual positions
// FORMULA: forall id. ghostMbTotalSupplyShares128[id] >= sum(ghostMbSupplyShares256[id][user])
//
// supply adds equal shares to position and total. withdraw subtracts equal.
// _accrueInterest adds feeShares to both feeRecipient position and total.
// Uses bounded ERC20 account set (5 users) for tractability.
invariant supplySharesSolvency(env e)
    forall MorphoHarness.Id id.
        ghostMbTotalSupplyShares128[id] >= SUPPLY_SHARES_SUM(id)
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-07: Borrow shares solvency -- total >= sum of individual positions
// FORMULA: forall id. ghostMbTotalBorrowShares128[id] >= sum(ghostMbBorrowShares128[id][user])
//
// borrow adds equal shares to position and total. repay subtracts equal.
// liquidate bad debt sets individual to 0 and subtracts from total.
// Uses bounded ERC20 account set (5 users) for tractability.
invariant borrowSharesSolvency(env e)
    forall MorphoHarness.Id id.
        ghostMbTotalBorrowShares128[id] >= BORROW_SHARES_SUM(id)
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-08: Non-existent market has zero accounting
// FORMULA: forall id. ghostMbLastUpdate128[id] == 0
//                  => (totalSupplyAssets == 0 && totalSupplyShares == 0
//                      && totalBorrowAssets == 0 && totalBorrowShares == 0 && fee == 0)
//
// createMarket only sets lastUpdate and idToMarketParams. All other market
// fields remain at zero. All accounting functions require lastUpdate != 0.
invariant nonExistentMarketIsZero(env e)
    forall MorphoHarness.Id id.
        ghostMbLastUpdate128[id] == 0
        => (ghostMbTotalSupplyAssets128[id] == 0
            && ghostMbTotalSupplyShares128[id] == 0
            && ghostMbTotalBorrowAssets128[id] == 0
            && ghostMbTotalBorrowShares128[id] == 0
            && ghostMbFee128[id] == 0)
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-09: Non-existent market has zero market params
// FORMULA: forall id. ghostMbLastUpdate128[id] == 0
//                  => (loanToken == 0 && collateralToken == 0 && oracle == 0
//                      && irm == 0 && lltv == 0)
//
// Only createMarket writes idToMarketParams, and it atomically sets lastUpdate.
// createMarket requires lastUpdate == 0 (market not yet created).
invariant nonExistentMarketParamsAreZero(env e)
    forall MorphoHarness.Id id.
        ghostMbLastUpdate128[id] == 0
        => (ghostMbLoanToken[id] == 0
            && ghostMbCollateralToken[id] == 0
            && ghostMbOracle[id] == 0
            && ghostMbIrm[id] == 0
            && ghostMbLltv256[id] == 0)
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-10: Market IRM is enabled
// FORMULA: forall id. ghostMbLastUpdate128[id] != 0 => ghostMbIsIrmEnabled[ghostMbIrm[id]]
//
// createMarket requires isIrmEnabled[marketParams.irm]. Once enabled, IRM
// cannot be disabled (enableIrm is monotonic: false -> true only).
invariant marketIrmIsEnabled(env e)
    forall MorphoHarness.Id id.
        ghostMbLastUpdate128[id] != 0
        => ghostMbIsIrmEnabled[ghostMbIrm[id]]
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-11: Market LLTV is enabled
// FORMULA: forall id, lltv. (lastUpdate != 0 && lltv == ghostMbLltv256[id]) => isLltvEnabled[lltv]
//
// createMarket requires isLltvEnabled[marketParams.lltv]. Once enabled, LLTV
// cannot be disabled (enableLltv is monotonic: false -> true only).
// Uses forall uint256 binding to avoid require_uint256 in quantified context.
invariant marketLltvIsEnabled(env e)
    forall MorphoHarness.Id id. forall uint256 lltv.
        (ghostMbLastUpdate128[id] != 0 && ghostMbLltv256[id] == to_mathint(lltv))
        => ghostMbIsLltvEnabled[lltv]
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-12: Enabled LLTV is below WAD
// FORMULA: forall uint256 lltv. ghostMbIsLltvEnabled[lltv] => to_mathint(lltv) < MORPHO_WAD_CVL()
//
// enableLltv enforces require(lltv < WAD). Once set, LLTV cannot be modified.
invariant enabledLltvBelowWad(env e)
    forall uint256 lltv.
        ghostMbIsLltvEnabled[lltv] => to_mathint(lltv) < MORPHO_WAD_CVL()
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-13: Market LLTV below WAD
// FORMULA: forall id. ghostMbLastUpdate128[id] != 0 => ghostMbLltv256[id] < MORPHO_WAD_CVL()
//
// Derived from marketLltvIsEnabled + enabledLltvBelowWad. Kept for
// defense-in-depth; the direct invariant is simpler for the prover.
invariant marketLltvBelowWad(env e)
    forall MorphoHarness.Id id.
        ghostMbLastUpdate128[id] != 0
        => ghostMbLltv256[id] < MORPHO_WAD_CVL()
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-14: Supply shares require market existence
// FORMULA: forall id, user. ghostMbSupplyShares256[id][user] > 0 => ghostMbLastUpdate128[id] != 0
//
// supply() requires market[id].lastUpdate != 0. _accrueInterest fee minting
// also requires market existence.
invariant supplySharesRequiresMarket(env e)
    forall MorphoHarness.Id id. forall address user.
        ghostMbSupplyShares256[id][user] > 0
        => ghostMbLastUpdate128[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-15: Borrow shares require market existence
// FORMULA: forall id, user. ghostMbBorrowShares128[id][user] > 0 => ghostMbLastUpdate128[id] != 0
//
// borrow() requires market[id].lastUpdate != 0. liquidate only operates
// on existing markets.
invariant borrowSharesRequiresMarket(env e)
    forall MorphoHarness.Id id. forall address user.
        ghostMbBorrowShares128[id][user] > 0
        => ghostMbLastUpdate128[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-16: Collateral requires market existence
// FORMULA: forall id, user. ghostMbCollateral128[id][user] > 0 => ghostMbLastUpdate128[id] != 0
//
// supplyCollateral() requires market[id].lastUpdate != 0. No path creates
// collateral in a non-existent market.
invariant collateralRequiresMarket(env e)
    forall MorphoHarness.Id id. forall address user.
        ghostMbCollateral128[id][user] > 0
        => ghostMbLastUpdate128[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-17: Total supply assets require market existence
// FORMULA: forall id. ghostMbTotalSupplyAssets128[id] > 0 => ghostMbLastUpdate128[id] != 0
//
// All writers (supply, _accrueInterest, liquidate bad debt) operate on
// markets with lastUpdate != 0.
invariant supplyAssetsRequiresMarket(env e)
    forall MorphoHarness.Id id.
        ghostMbTotalSupplyAssets128[id] > 0
        => ghostMbLastUpdate128[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-18: Total supply shares require market existence
// FORMULA: forall id. ghostMbTotalSupplyShares128[id] > 0 => ghostMbLastUpdate128[id] != 0
//
// All writers (supply, _accrueInterest fee minting) check market existence.
invariant supplySharesTotalRequiresMarket(env e)
    forall MorphoHarness.Id id.
        ghostMbTotalSupplyShares128[id] > 0
        => ghostMbLastUpdate128[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-19: Total borrow assets require market existence
// FORMULA: forall id. ghostMbTotalBorrowAssets128[id] > 0 => ghostMbLastUpdate128[id] != 0
//
// Writers: borrow, _accrueInterest, repay, liquidate -- all operate on
// existing markets.
invariant borrowAssetsRequiresMarket(env e)
    forall MorphoHarness.Id id.
        ghostMbTotalBorrowAssets128[id] > 0
        => ghostMbLastUpdate128[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-20: Total borrow shares require market existence
// FORMULA: forall id. ghostMbTotalBorrowShares128[id] > 0 => ghostMbLastUpdate128[id] != 0
//
// Same reasoning as totalBorrowAssets.
invariant borrowSharesTotalRequiresMarket(env e)
    forall MorphoHarness.Id id.
        ghostMbTotalBorrowShares128[id] > 0
        => ghostMbLastUpdate128[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-21: Non-existent market has zero positions
// FORMULA: forall id, user. ghostMbLastUpdate128[id] == 0
//                         => (supplyShares == 0 && borrowShares == 0 && collateral == 0)
//
// All position-modifying functions require market existence (lastUpdate != 0).
invariant nonExistentMarketPositionsZero(env e)
    forall MorphoHarness.Id id. forall address user.
        ghostMbLastUpdate128[id] == 0
        => (ghostMbSupplyShares256[id][user] == 0
            && ghostMbBorrowShares128[id][user] == 0
            && ghostMbCollateral128[id][user] == 0)
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-22: Borrower always has collateral
// FORMULA: forall id, user. ghostMbBorrowShares128[id][user] != 0 => ghostMbCollateral128[id][user] != 0
//
// borrow() requires sufficient collateral via _isHealthy check. liquidate()
// seizes collateral proportionally to repaid debt. Bad debt realization only
// happens when collateral reaches 0, at which point borrowShares are also zeroed.
invariant alwaysCollateralized(env e)
    forall MorphoHarness.Id id. forall address user.
        ghostMbBorrowShares128[id][user] != 0
        => ghostMbCollateral128[id][user] != 0
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }

// VS-23: Zero address does not authorize
// FORMULA: forall authorized. !ghostMbIsAuthorized[0][authorized]
//
// setAuthorization is called by msg.sender which is always != 0 (from setupEnv).
// setAuthorizationWithSig uses ecrecover which returns 0 on invalid sig,
// but the code requires authorizer != address(0).
invariant zeroDoesNotAuthorize(env e)
    forall address authorized.
        !ghostMbIsAuthorized[0][authorized]
filtered { f -> !EXCLUDED_FUNCTION_MB(f) }
    { preserved with (env eFunc) { SETUP_MANY_BLUE(e, eFunc); } }
