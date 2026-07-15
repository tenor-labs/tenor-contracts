// OZ SafeERC20 CVL summaries (import only where the scene has SafeERC20).

import "midnight/specs/setup/erc20/erc20.spec";

methods {
    // Redirect forceApprove to ERC20 CVL model: its inline-asm .call breaks points-to analysis.
    function SafeERC20.forceApprove(address token, address spender, uint256 value) internal
        => forceApproveERC20CVL(token, calledContract, spender, value);
}

function forceApproveERC20CVL(address token, address owner, address spender, uint256 value) {
    approveERC20CVL(token, owner, spender, value);
}
