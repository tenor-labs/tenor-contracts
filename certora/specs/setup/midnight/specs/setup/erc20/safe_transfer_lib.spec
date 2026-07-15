// Midnight SafeTransferLib CVL summaries.

import "erc20.spec";

methods {
    function SafeTransferLib.safeTransfer(address token, address to, uint256 value) internal
        => safeTransferERC20CVL(token, calledContract, to, value);

    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 value) internal
        => safeTransferFromERC20CVL(token, calledContract, from, to, value);
}

function safeTransferERC20CVL(address token, address src, address to, uint256 value) {
    transferERC20CVL(token, src, to, value);
}

function safeTransferFromERC20CVL(address token, address spender, address from, address to, uint256 value) {
    transferFromERC20CVL(token, spender, from, to, value);
}
