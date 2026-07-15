// ========== Gate CVL Summaries ==========
// The four VaultV2 gates are external, untrusted view callbacks
// (canReceiveShares / canSendShares / canReceiveAssets / canSendAssets), reached
// from the vault's helpers only when the gate address is non-zero (the `gate==0`
// short-circuit runs the real body and returns true, no external call).
//
// Modeled as recorder stubs: a per-account boolean verdict ghost + a "called"
// flag for future gate rules. Adapted from midnight `gates.spec`; account-keyed
// form matches the official VaultV2 `Gates.spec`.
//
// NOTE: these `_.canX(address)` wildcards intercept only EXTERNAL gate sub-calls.
// The vault's own public canX are inlined and run their real bodies, so the
// `gate==0` short-circuit is preserved.

methods {
    function _.canReceiveShares(address account) external
        => canReceiveSharesGateCVL(account) expect bool;
    function _.canSendShares(address account) external
        => canSendSharesGateCVL(account) expect bool;
    function _.canReceiveAssets(address account) external
        => canReceiveAssetsGateCVL(account) expect bool;
    function _.canSendAssets(address account) external
        => canSendAssetsGateCVL(account) expect bool;
}

// Per-account verdicts (deterministic per account within a rule).
persistent ghost mapping(address => bool) ghostTvGateCanReceiveShares;
persistent ghost mapping(address => bool) ghostTvGateCanSendShares;
persistent ghost mapping(address => bool) ghostTvGateCanReceiveAssets;
persistent ghost mapping(address => bool) ghostTvGateCanSendAssets;

// Recorder flags (were the gates consulted during the call).
persistent ghost bool ghostTvGateCanReceiveSharesCalled;
persistent ghost bool ghostTvGateCanSendSharesCalled;
persistent ghost bool ghostTvGateCanReceiveAssetsCalled;
persistent ghost bool ghostTvGateCanSendAssetsCalled;

function canReceiveSharesGateCVL(address account) returns bool {
    ghostTvGateCanReceiveSharesCalled = true;
    return ghostTvGateCanReceiveShares[account];
}

function canSendSharesGateCVL(address account) returns bool {
    ghostTvGateCanSendSharesCalled = true;
    return ghostTvGateCanSendShares[account];
}

function canReceiveAssetsGateCVL(address account) returns bool {
    ghostTvGateCanReceiveAssetsCalled = true;
    return ghostTvGateCanReceiveAssets[account];
}

function canSendAssetsGateCVL(address account) returns bool {
    ghostTvGateCanSendAssetsCalled = true;
    return ghostTvGateCanSendAssets[account];
}
