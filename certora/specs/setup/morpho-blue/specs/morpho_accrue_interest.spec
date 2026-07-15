// ========== Accrue Interest Idempotency Rules ==========
//
// Verifies that explicitly calling accrueInterest() before an operation
// (supply/withdraw/borrow/repay) produces identical state to letting the
// operation call _accrueInterest() internally.
//
// This spec is SELF-CONTAINED and does NOT import setup/morpho.spec.
// Reason: the setup uses NONDET for IIrm.borrowRate and a full ERC20 CVL
// model for transfer/transferFrom. With NONDET, each path through
// lastStorage gets an independent arbitrary borrow rate, breaking the
// storage comparison. The official Morpho Labs AccrueInterest.spec solves
// this by using deterministic ghost function summaries for borrowRate,
// transfer, and transferFrom, plus ghost-based math summaries.
//
// We follow the official approach: ghost summaries for borrowRate, price,
// transfer, transferFrom, and math (mulDivDown, mulDivUp, wTaylorCompounded).
// This ensures both execution paths produce identical results given the
// same inputs, making the storage comparison valid.

import "setup/libs/env.spec";
import "setup/libs/helper.spec";

using MorphoHarness as _Morpho;

// ========== GHOST DECLARATIONS ==========

// Deterministic ghost functions for math operations.
// Unlike the concrete CVL implementations in morpho_math_lib.spec, these
// return arbitrary but CONSISTENT values: same inputs always yield same output.
// This is sufficient for the storage equality proof and avoids potential
// issues with concrete math interacting with ghost borrowRate values.
ghost ghostMulDivDown(uint256, uint256, uint256) returns uint256;
ghost ghostMulDivUp(uint256, uint256, uint256) returns uint256;
ghost ghostTaylorCompounded(uint256, uint256) returns uint256;

// Deterministic ghost for borrow rate: same IRM address + same timestamp
// always returns the same rate. This is the KEY fix: with NONDET each call
// could return a different value, but with this ghost both lastStorage paths
// get identical interest amounts.
ghost ghostBorrowRate(address, uint256) returns uint256;

// Deterministic ghost for oracle price: same timestamp => same price.
ghost ghostOraclePrice(uint256) returns uint256;

// Deterministic ghost for token transfers: same (to, amount) => same result.
// These replace the full ERC20 CVL model. For storage equality proofs we
// only need consistency, not faithful balance tracking.
ghost ghostTransfer(address, uint256) returns bool;
ghost ghostTransferFrom(address, address, uint256) returns bool;

// ========== METHOD SUMMARIES ==========

methods {
    // --- Math summaries (ghost-based for determinism) ---
    function MathLib.mulDivDown(uint256 a, uint256 b, uint256 c) internal
        returns uint256 => ghostMulDivDown(a, b, c);
    function MathLib.mulDivUp(uint256 a, uint256 b, uint256 c) internal
        returns uint256 => ghostMulDivUp(a, b, c);
    function MathLib.wTaylorCompounded(uint256 a, uint256 b) internal
        returns uint256 => ghostTaylorCompounded(a, b);

    // --- IRM summaries (deterministic ghost keyed on irm address + timestamp) ---
    // We assume all external functions will not access storage, since we
    // cannot show commutativity otherwise. We also need the borrow rate to
    // return the same value for the same inputs, so we use a ghost function.
    function _.borrowRate(
        MorphoHarness.MarketParams marketParams,
        MorphoHarness.Market market
    ) external with (env e)
        => ghostBorrowRate(marketParams.irm, e.block.timestamp) expect uint256;

    function _.borrowRateView(
        MorphoHarness.MarketParams marketParams,
        MorphoHarness.Market market
    ) external with (env e)
        => ghostBorrowRate(marketParams.irm, e.block.timestamp) expect uint256;

    // --- Oracle summary (deterministic ghost keyed on timestamp) ---
    function _.price() external with (env e)
        => ghostOraclePrice(e.block.timestamp) expect uint256;

    // --- Token transfer summaries (deterministic ghost) ---
    // These override the ERC20 CVL model's stateful transfer functions.
    // For storage equality proofs we only need the same inputs to produce
    // the same result, not actual balance accounting.
    function _.transfer(address to, uint256 amount) external
        => ghostTransfer(to, amount) expect bool;
    function _.transferFrom(address from, address to, uint256 amount) external
        => ghostTransferFrom(from, to, amount) expect bool;

    // --- Callbacks (NONDET -- same as setup, these are UNTRUSTED) ---
    function _.onMorphoSupply(uint256, bytes) external => NONDET;
    function _.onMorphoRepay(uint256, bytes) external => NONDET;
    function _.onMorphoSupplyCollateral(uint256, bytes) external => NONDET;
    function _.onMorphoLiquidate(uint256, bytes) external => NONDET;
    function _.onMorphoFlashLoan(uint256, bytes) external => NONDET;

    // --- Scene cleanup ---
    function MorphoHarness.extSloads(bytes32[]) external returns (bytes32[])
        => NONDET DELETE;
    function MorphoHarness.setAuthorizationWithSig(
        MorphoHarness.Authorization,
        MorphoHarness.Signature
    ) external => NONDET DELETE;
}

// ========== ACCRUE INTEREST IDEMPOTENCY RULES ==========

// AI-01: accrueInterest before supply is idempotent
// FORMULA: storage(accrueInterest + supply) == storage(supply alone)
//
// supply() internally calls _accrueInterest(). Calling accrueInterest()
// explicitly first should produce identical final state because the second
// _accrueInterest() inside supply() becomes a no-op (lastUpdate == timestamp).
rule supplyAccruesInterest(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupEnv(e);

    storage init = lastStorage;

    // Path 1: explicit accrueInterest + supply
    accrueInterest(e, marketParams);
    supply(e, marketParams, assets, shares, onBehalf, data);
    storage afterBoth = lastStorage;

    // Path 2: supply alone (which calls _accrueInterest internally)
    supply(e, marketParams, assets, shares, onBehalf, data) at init;
    storage afterOne = lastStorage;

    assert(afterBoth == afterOne,
        "Supply with or without explicit accrueInterest must produce identical state");
}

// AI-02: accrueInterest before withdraw is idempotent
// FORMULA: storage(accrueInterest + withdraw) == storage(withdraw alone)
//
// withdraw() internally calls _accrueInterest(). The explicit call is a no-op.
rule withdrawAccruesInterest(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) {
    setupEnv(e);

    storage init = lastStorage;

    accrueInterest(e, marketParams);
    withdraw(e, marketParams, assets, shares, onBehalf, receiver);
    storage afterBoth = lastStorage;

    withdraw(e, marketParams, assets, shares, onBehalf, receiver) at init;
    storage afterOne = lastStorage;

    assert(afterBoth == afterOne,
        "Withdraw with or without explicit accrueInterest must produce identical state");
}

// AI-03: accrueInterest before borrow is idempotent
// FORMULA: storage(accrueInterest + borrow) == storage(borrow alone)
//
// borrow() internally calls _accrueInterest(). The explicit call is a no-op.
rule borrowAccruesInterest(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) {
    setupEnv(e);

    storage init = lastStorage;

    accrueInterest(e, marketParams);
    borrow(e, marketParams, assets, shares, onBehalf, receiver);
    storage afterBoth = lastStorage;

    borrow(e, marketParams, assets, shares, onBehalf, receiver) at init;
    storage afterOne = lastStorage;

    assert(afterBoth == afterOne,
        "Borrow with or without explicit accrueInterest must produce identical state");
}

// AI-04: accrueInterest before repay is idempotent
// FORMULA: storage(accrueInterest + repay) == storage(repay alone)
//
// repay() internally calls _accrueInterest(). The explicit call is a no-op.
rule repayAccruesInterest(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupEnv(e);

    storage init = lastStorage;

    accrueInterest(e, marketParams);
    repay(e, marketParams, assets, shares, onBehalf, data);
    storage afterBoth = lastStorage;

    repay(e, marketParams, assets, shares, onBehalf, data) at init;
    storage afterOne = lastStorage;

    assert(afterBoth == afterOne,
        "Repay with or without explicit accrueInterest must produce identical state");
}
