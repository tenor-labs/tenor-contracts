// Shared Morpho Blue setup base: methods block, domain constants, and
// non-id-keyed ghosts. Per-id ghosts live in `morpho_many.spec` (full
// quantification) and `morpho_one.spec` (scalar single-market narrowing).
//
// Commented for cross-protocol Tenor scenes: midnight supplies the env /
// ERC20 / oracle models. Re-enable for standalone morpho-blue runs.
// import "libs/helper.spec";
// import "libs/env.spec";
// import "libs/safe_transfer_lib.spec";
// import "morpho_oracle.spec";
import "morpho_shares_math_lib.spec";

using MorphoHarness as _Morpho;

// ========== DOMAIN CONSTANTS ==========
definition MORPHO_WAD_CVL() returns mathint = 1000000000000000000;
definition MAX_FEE_CVL() returns mathint = 250000000000000000;
definition ORACLE_PRICE_SCALE_CVL() returns mathint = 1000000000000000000000000000000000000;
definition VIRTUAL_SHARES_CVL() returns mathint = 1000000;
definition VIRTUAL_ASSETS_CVL() returns mathint = 1;

methods {
    // NOTE: HelperCVL.{toId, fromId, marketId} are auto-detected from the contract.
    // Explicit declarations removed: in parent projects (MetaMorpho), HelperCVL compiles
    // with a different MarketParams/Id source than MorphoHarness, causing type merge errors.
    // envfree is declared via envfreeFuncsStaticCheck instead.

    // View functions -- envfree
    function _Morpho.owner() external returns (address) envfree;
    function _Morpho.feeRecipient() external returns (address) envfree;
    function _Morpho.isIrmEnabled(address) external returns (bool) envfree;
    function _Morpho.isLltvEnabled(uint256) external returns (bool) envfree;
    function _Morpho.isAuthorized(address, address) external returns (bool) envfree;
    function _Morpho.nonce(address) external returns (uint256) envfree;

    // --- Scene Cleanup: Utility ---
    function _Morpho.extSloads(bytes32[]) external returns (bytes32[])
        => NONDET DELETE;

    // --- Scene Cleanup: Cryptographic (ecrecover not verifiable in CVL) ---
    function _Morpho.setAuthorizationWithSig(MorphoHarness.Authorization, MorphoHarness.Signature)
        external => NONDET DELETE;

    // --- Unresolved Calls: IRM ---
    // IIrm.borrowRate(MarketParams, MarketBlue) -> per-IRM-callee ghost.
    // NONDET would let the prover pick a fresh value on every call to the
    // same IRM within a rule (non-deterministic); ghost-keyed on
    // `calledContract` makes the rate deterministic per IRM address so
    // back-to-back reads in `_accrueInterest` see a single value.
    function _.borrowRate(MorphoHarness.MarketParams, MorphoHarness.MarketBlue) external
        => ghostMbIrmBorrowRate[calledContract] expect uint256;
    function _.borrowRateView(MorphoHarness.MarketParams, MorphoHarness.MarketBlue) external
        => ghostMbIrmBorrowRate[calledContract] expect uint256;

    // --- Unresolved Calls: Callbacks (UNTRUSTED, state already updated) ---
    function _.onMorphoSupply(uint256, bytes) external => NONDET;
    function _.onMorphoRepay(uint256, bytes) external => NONDET;
    function _.onMorphoSupplyCollateral(uint256, bytes) external => NONDET;
    function _.onMorphoLiquidate(uint256, bytes) external => NONDET;
    function _.onMorphoFlashLoan(uint256, bytes) external => NONDET;
}

// Parametric filter: view/pure + harness-specific exclusions
definition EXCLUDED_FUNCTION_MB(method f) returns bool =
    f.isView || f.isPure;

// ========== SCALAR STATE ==========

// Per-IRM-callee borrow rate.
persistent ghost mapping(address => uint256) ghostMbIrmBorrowRate {
    init_state axiom forall address irm. ghostMbIrmBorrowRate[irm] == 0;
    // UNSAFE: borrow rate capped at 2e18/yr for tractability; the canonical
    // AdaptiveCurveIrm curve ceiling is CURVE_STEEPNESS (4) * MAX_RATE_AT_TARGET
    // = 8e18/yr, so rates in (2e18/yr, 8e18/yr] are not explored.
    axiom forall address irm.
        ghostMbIrmBorrowRate[irm] <= (2 * 1000000000000000000) / (365 * 86400);
}

// address owner
persistent ghost address ghostMbOwner {
    init_state axiom ghostMbOwner != 0;
}
hook Sload address val _Morpho.owner {
    require(ghostMbOwner == val, "SAFE: ghost sync owner");
}
hook Sstore _Morpho.owner address val {
    ghostMbOwner = val;
}

// address feeRecipient
persistent ghost address ghostMbFeeRecipient {
    init_state axiom ghostMbFeeRecipient == 0;
}
hook Sload address val _Morpho.feeRecipient {
    require(ghostMbFeeRecipient == val, "SAFE: ghost sync feeRecipient");
}
hook Sstore _Morpho.feeRecipient address val {
    ghostMbFeeRecipient = val;
}

// ========== BOOLEAN MAPPINGS ==========

// mapping(address => bool) isIrmEnabled
persistent ghost mapping(address => bool) ghostMbIsIrmEnabled {
    init_state axiom forall address irm. ghostMbIsIrmEnabled[irm] == false;
}
hook Sload bool val _Morpho.isIrmEnabled[KEY address irm] {
    require(ghostMbIsIrmEnabled[irm] == val, "SAFE: ghost sync isIrmEnabled");
}
hook Sstore _Morpho.isIrmEnabled[KEY address irm] bool val {
    ghostMbIsIrmEnabled[irm] = val;
}

// mapping(uint256 => bool) isLltvEnabled
persistent ghost mapping(uint256 => bool) ghostMbIsLltvEnabled {
    init_state axiom forall uint256 lltv. ghostMbIsLltvEnabled[lltv] == false;
}
hook Sload bool val _Morpho.isLltvEnabled[KEY uint256 lltv] {
    require(ghostMbIsLltvEnabled[lltv] == val, "SAFE: ghost sync isLltvEnabled");
}
hook Sstore _Morpho.isLltvEnabled[KEY uint256 lltv] bool val {
    ghostMbIsLltvEnabled[lltv] = val;
}

// ========== AUTHORIZATION ==========

// mapping(address => mapping(address => bool)) isAuthorized
persistent ghost mapping(address => mapping(address => bool)) ghostMbIsAuthorized {
    init_state axiom forall address a. forall address b.
        ghostMbIsAuthorized[a][b] == false;
}
hook Sload bool val _Morpho.isAuthorized[KEY address authorizer][KEY address authorized] {
    require(ghostMbIsAuthorized[authorizer][authorized] == val,
        "SAFE: ghost sync isAuthorized");
}
hook Sstore _Morpho.isAuthorized[KEY address authorizer][KEY address authorized] bool val {
    ghostMbIsAuthorized[authorizer][authorized] = val;
}

// ========== NONCE ==========

// mapping(address => uint256) nonce
persistent ghost mapping(address => mathint) ghostMbNonce256 {
    init_state axiom forall address user. ghostMbNonce256[user] == 0;
    axiom forall address user.
        ghostMbNonce256[user] >= 0 && ghostMbNonce256[user] <= max_uint256;
}
hook Sload uint256 val _Morpho.nonce[KEY address user] {
    require(require_uint256(ghostMbNonce256[user]) == val, "SAFE: ghost sync nonce");
}
hook Sstore _Morpho.nonce[KEY address user] uint256 val {
    ghostMbNonce256[user] = val;
}
