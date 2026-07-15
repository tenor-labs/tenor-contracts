// ========== Adapter / AdapterRegistry CVL Summaries ==========
// VaultV2's external calls to adapters / registry (allocate, deallocate,
// realAssets, isInRegistry). Adapters are untrusted ("loosely specified"), so:
//   - allocate / deallocate: NONDET (returned ids/change havoced, array length
//     bounded by optimistic_loop + loop_iter). Adversarial adapter model.
//   - realAssets(): per-adapter ghost keyed on calledContract, <= max_uint128 so
//     the accrueInterestView accumulation stays in-range over the bounded loop.
//   - isInRegistry(): per-(registry, account) ghost keyed on calledContract
//     (add-only registries). Matches the official VaultV2 `Invariants.spec`.

methods {
    function _.allocate(bytes data, uint256 assets, bytes4 selector, address sender) external
        => NONDET;
    function _.deallocate(bytes data, uint256 assets, bytes4 selector, address sender) external
        => NONDET;

    function _.realAssets() external
        => realAssetsAdapterCVL(calledContract) expect uint256;

    function _.isInRegistry(address account) external
        => ghostTvIsInRegistry[calledContract][account] expect bool;
}

// Per-adapter reported investment value (in underlying asset).
persistent ghost mapping(address => mathint) ghostTvRealAssets {
    init_state axiom forall address adapter. ghostTvRealAssets[adapter] == 0;
    // SAFE: bounded so the accrueInterestView accumulation stays within uint256.
    axiom forall address adapter.
        ghostTvRealAssets[adapter] >= 0 && ghostTvRealAssets[adapter] <= max_uint128;
}

// Per-(registry, account) membership. Add-only registries in practice.
persistent ghost mapping(address => mapping(address => bool)) ghostTvIsInRegistry {
    init_state axiom forall address registry. forall address account.
        ghostTvIsInRegistry[registry][account] == false;
}

function realAssetsAdapterCVL(address adapter) returns uint256 {
    return require_uint256(ghostTvRealAssets[adapter]);
}
