// ========== SafeTransferLib CVL Summaries ==========
// Morpho uses SafeTransferLib (Solmate) for all token interactions.
// SafeTransferLib.safeTransfer/safeTransferFrom use low-level .call()
// which the Prover cannot inline. We redirect to the ERC20 CVL model.

import "erc20.spec";

methods {
    function SafeTransferLib.safeTransfer(address token, address to, uint256 value) internal
        => safeTransferLibCVL(token, calledContract, to, value);
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 value) internal
        => safeTransferFromLibCVL(token, calledContract, from, to, value);
}

function safeTransferLibCVL(address token, address src, address to, uint256 amount) {
    ASSERT(transferERC20CVL(token, src, to, amount), "safeTransfer must succeed");
}

function safeTransferFromLibCVL(address token, address spender, address from, address to, uint256 amount) {
    ASSERT(transferFromERC20CVL(token, spender, from, to, amount), "safeTransferFrom must succeed");
}
