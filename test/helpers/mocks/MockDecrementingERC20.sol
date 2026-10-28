// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {MockERC20} from "./MockERC20.sol";

/**
 * @title MockDecrementingERC20
 * @dev MockERC20 that spends even a max allowance, like USDC (OZ ERC20 leaves type(uint256).max untouched). Same
 * storage layout as MockERC20, so its code can be etched over one.
 */
contract MockDecrementingERC20 is MockERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals_) MockERC20(name, symbol, decimals_) {}

    function _spendAllowance(address owner, address spender, uint256 value) internal override {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < value) revert ERC20InsufficientAllowance(spender, currentAllowance, value);
        unchecked {
            _approve(owner, spender, currentAllowance - value, false);
        }
    }
}
