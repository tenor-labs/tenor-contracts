// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Real ERC4626 vault for testing, extends OpenZeppelin's implementation.
/// @dev Only override: configurable maxDeposit cap (many production vaults have deposit caps).
///      All other behavior (convertToAssets, maxWithdraw, etc.) uses the real OZ math.
contract TestERC4626 is ERC4626 {
    uint256 private _maxDepositCap;
    bool private _maxDepositCapSet;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC4626(asset_) ERC20(name_, symbol_) {}

    /// @notice Set a deposit cap (simulates production vaults with caps)
    function setMaxDepositCap(uint256 cap) external {
        _maxDepositCap = cap;
        _maxDepositCapSet = true;
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (_maxDepositCapSet) {
            uint256 totalDeposited = totalAssets();
            return totalDeposited >= _maxDepositCap ? 0 : _maxDepositCap - totalDeposited;
        }
        return super.maxDeposit(receiver);
    }
}
