// Route ERC20 ops on vault SHARES to real VaultV2 code: override the CVL wrappers with a
// `token == _VaultV2` branch (real call; other tokens keep the ghost model) so the vault's
// real storage stays in sync (fixes MWV hook-desync / MSV divergence).

import "../../../midnight/specs/setup/erc20/safe_transfer_lib.spec";
import "../../../safe_erc20.spec";

override function safeTransferERC20CVL(address token, address src, address to, uint256 value) {
    if (token == _VaultV2) {
        env eR;
        require(eR.msg.sender == src && eR.msg.value == 0,
            "SAFE: routing env = calling contract (library-call semantics)");
        bool okT = _VaultV2.transfer(eR, to, value);
        require(okT, "SAFE: SafeTransferLib treats false as revert; VaultV2.transfer never returns false");
    } else {
        transferERC20CVL(token, src, to, value);
    }
}

override function safeTransferFromERC20CVL(address token, address spender, address from, address to, uint256 value) {
    if (token == _VaultV2) {
        env eR;
        require(eR.msg.sender == spender && eR.msg.value == 0,
            "SAFE: routing env = spender (library-call semantics)");
        bool okTF = _VaultV2.transferFrom(eR, from, to, value);
        require(okTF, "SAFE: SafeTransferLib treats false as revert");
    } else {
        transferFromERC20CVL(token, spender, from, to, value);
    }
}

override function forceApproveERC20CVL(address token, address owner, address spender, uint256 value) {
    if (token == _VaultV2) {
        env eR;
        require(eR.msg.sender == owner && eR.msg.value == 0,
            "SAFE: routing env = owner (forceApprove semantics)");
        bool okA = _VaultV2.approve(eR, spender, value);
        require(okA, "SAFE: VaultV2.approve is always true");
    } else {
        approveERC20CVL(token, owner, spender, value);
    }
}
