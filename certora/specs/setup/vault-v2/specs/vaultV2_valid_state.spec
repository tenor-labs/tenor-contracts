// VaultV2 valid state — LIBRARY (invariants + setup aggregator).
// Importers call setupValidStateVaultV2(e) / requireInvariant <name>(e) and read
// the ghostTv* mirrors; importing does NOT re-run the invariants. The RUNNER
// (vaultV2_valid_state_run.spec) is what valid_state.conf verifies.

import "setup/vaultV2.spec";

// ─── Setup aggregators ───────────────────────────────────────────────────────

// Env-only premise for preserved blocks (no requireInvariant → no cycles).
function SETUP(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupVaultV2(eFunc);
}

// Full valid state: assume every proven invariant. One-shot "valid state" premise.
function setupValidStateVaultV2(env e) {
    setupVaultV2(e);
    // VS-VA-01 (lastUpdate <= block.timestamp): SAFE premise in setupVaultV2, not
    // a proven invariant — see setup/vaultV2.spec.
    requireInvariant maxRateBounded(e);
    requireInvariant relativeCapBounded(e);
    requireInvariant penaltyBounded(e);
    requireInvariant performanceFeeBounded(e);
    requireInvariant managementFeeBounded(e);
    requireInvariant performanceFeeRecipientConsistency(e);
    requireInvariant managementFeeRecipientConsistency(e);
    requireInvariant sharesZeroAddressEmpty(e);
    requireInvariant zeroCannotApprove(e);
    requireInvariant sharesSolvency(e);
}

// ─── Invariants (VS-VA-NN) ───────────────────────────────────────────────────

// VS-VA-01 (lastUpdate <= block.timestamp): SAFE premise in setupVaultV2, not a
// proven invariant. Inductive step verifies; only the constructor base case is
// unprovable in Certora's per-call time model. See setup/vaultV2.spec.

// VS-VA-02: max interest rate within the protocol ceiling.
// FORMULA: maxRate <= MAX_MAX_RATE
invariant maxRateBounded(env e)
    ghostTvMaxRate <= MAX_MAX_RATE_CVL()
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) }
    { preserved with (env eFunc) { SETUP(e, eFunc); } }

// VS-VA-03: every id's relative cap within one WAD.
// FORMULA: forall id. relativeCap[id] <= WAD
invariant relativeCapBounded(env e)
    forall bytes32 id. ghostTvCapsRelativeCap[id] <= VV_WAD_CVL()
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) }
    { preserved with (env eFunc) { SETUP(e, eFunc); } }

// VS-VA-04: every adapter's force-deallocate penalty within the ceiling.
// FORMULA: forall a. forceDeallocatePenalty[a] <= MAX_FORCE_DEALLOCATE_PENALTY
invariant penaltyBounded(env e)
    forall address a. ghostTvForceDeallocatePenalty[a] <= MAX_FORCE_DEALLOCATE_PENALTY_CVL()
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) }
    { preserved with (env eFunc) { SETUP(e, eFunc); } }

// VS-VA-05: performance fee within the protocol ceiling.
// FORMULA: performanceFee <= MAX_PERFORMANCE_FEE
invariant performanceFeeBounded(env e)
    ghostTvPerformanceFee <= MAX_PERFORMANCE_FEE_CVL()
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) }
    { preserved with (env eFunc) { SETUP(e, eFunc); } }

// VS-VA-06: management fee within the protocol ceiling.
// FORMULA: managementFee <= MAX_MANAGEMENT_FEE
invariant managementFeeBounded(env e)
    ghostTvManagementFee <= MAX_MANAGEMENT_FEE_CVL()
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) }
    { preserved with (env eFunc) { SETUP(e, eFunc); } }

// VS-VA-07: a non-zero performance fee has a recipient set.
// FORMULA: performanceFee != 0 => performanceFeeRecipient != 0
invariant performanceFeeRecipientConsistency(env e)
    ghostTvPerformanceFee != 0 => ghostTvPerformanceFeeRecipient != 0
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) }
    { preserved with (env eFunc) { SETUP(e, eFunc); } }

// VS-VA-08: a non-zero management fee has a recipient set.
// FORMULA: managementFee != 0 => managementFeeRecipient != 0
invariant managementFeeRecipientConsistency(env e)
    ghostTvManagementFee != 0 => ghostTvManagementFeeRecipient != 0
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) }
    { preserved with (env eFunc) { SETUP(e, eFunc); } }

// ─── SAFETY (zero-address / self-approve; analogs of morpho zeroDoesNotAuthorize
//     and midnight noSelfApprove) ───────────────────────────────────────────

// VS-VA-11: vault shares never held by the zero address.
// FORMULA: balanceOf[0] == 0
// (createShares/deleteShares/transfer/transferFrom all require party != 0.)
invariant sharesZeroAddressEmpty(env e)
    ghostERC20Balances128[_VaultV2][0] == 0
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) }
    { preserved with (env eFunc) { SETUP(e, eFunc); } }

// VS-VA-12: the zero address never grants a share allowance.
// FORMULA: forall s. allowance[0][s] == 0
// (approve: msg.sender != 0; permit: recovered owner != 0; transferFrom only
//  decrements an existing allowance of from != 0.)
invariant zeroCannotApprove(env e)
    forall address s. ghostERC20Allowances256[_VaultV2][0][s] == 0
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) }
    { preserved with (env eFunc) { SETUP(e, eFunc); } }

// noSelfApprove `allowance[vault][vault] == 0` is NOT an invariant: `permit` recovers `owner`
// via ecrecover (symbolic under optimistic_hashing), which can equal the vault with spender ==
// the vault, so the vault can self-approve in the model.

// ─── CONSERVATION / SOLVENCY (analog of morpho supplySharesSolvency) ─────────

// VS-VA-09: sum of vault-share balances never exceeds total supply (no
// over-issuance).
// FORMULA: Σ balanceOf (bounded holders) <= totalSupply
invariant sharesSolvency(env e)
    SHARE_SUM() <= ghostERC20TotalSupply256[_VaultV2]
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) }
    { preserved with (env eFunc) { SETUP(e, eFunc); } }

// VS-VA-10 (DEFERRED) adapterSetConsistency: `isAdapter[a] <=> a in adapters[]`.
// NOT proven. Even the forward direction (`forall i<len. isAdapter[adapters[i]]`)
// FAILS on removeAdapter: forward-alone permits a DUPLICATE adapter pre-state, and
// removeAdapter (first-match swap-pop) clears isAdapter[account] while another
// slot still holds it. A sound proof needs the coupled conjunction {forward,
// backward, no-duplicates} with array-membership witnesses, which Certora cannot
// tractably discharge. Reference bundles (morpho-blue, midnight) likewise avoid
// array-membership invariants. Documented UNRESOLVED in the manifest.
