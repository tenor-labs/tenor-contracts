// ========== SafeERC20Lib CVL Summaries ==========
// VaultV2 moves the underlying asset only through SafeERC20Lib, whose
// safeTransfer / safeTransferFrom do a low-level `token.call(...)` (after a
// code-length check) and decode returndata. The Prover can't inline that, so we
// summarize the INTERNAL library functions and redirect to the bounded ERC20 CVL
// model, bypassing the call/code-check/decode (asset treated as a well-behaved
// token with code). Mirrors the reference `libs/safe_transfer_lib.spec`.

// Commented for cross-protocol Tenor scenes: midnight supplies the ERC20 model
// (identical ghost names). Re-enable for standalone vault-v2 runs.
// import "erc20.spec";

methods {
    function SafeERC20Lib.safeTransfer(address token, address to, uint256 value) internal
        => safeTransferLibCVL(token, calledContract, to, value);

    function SafeERC20Lib.safeTransferFrom(address token, address from, address to, uint256 value) internal
        => safeTransferFromLibCVL(token, calledContract, from, to, value);
}

// `calledContract` inside an internal library summary = the contract executing
// the library code (VaultV2), i.e. the token's `from` / spender for the model.
function safeTransferLibCVL(address token, address src, address to, uint256 amount) {
    transferERC20CVL(token, src, to, amount);
}

function safeTransferFromLibCVL(address token, address spender, address from, address to, uint256 amount) {
    transferFromERC20CVL(token, spender, from, to, amount);
}
