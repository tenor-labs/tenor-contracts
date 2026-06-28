// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock ERC4626 vault for testing
/// @dev Simplified implementation with configurable exchange rate
contract MockERC4626 is ERC20, IERC4626 {
    address public immutable override asset;

    // Exchange rate: assetsPerShare = exchangeRate / 1e18
    // e.g., 1.05e18 means 1 share = 1.05 assets (5% yield accrued)
    uint256 public exchangeRate = 1e18;

    uint256 private _maxDepositOverride;
    bool private _maxDepositSet;
    mapping(address => uint256) private _maxWithdrawOverrides;
    mapping(address => bool) private _maxWithdrawSet;

    constructor(address asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        asset = asset_;
    }

    /* ========== ADMIN ========== */

    function setExchangeRate(uint256 newRate) external {
        exchangeRate = newRate;
    }

    function setMaxDepositOverride(uint256 value) external {
        _maxDepositOverride = value;
        _maxDepositSet = true;
    }

    function setMaxWithdrawOverride(address owner, uint256 value) external {
        _maxWithdrawOverrides[owner] = value;
        _maxWithdrawSet[owner] = true;
    }

    /* ========== ERC4626 VIEW FUNCTIONS ========== */

    function totalAssets() public view override returns (uint256) {
        return convertToAssets(totalSupply());
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return (assets * 1e18) / exchangeRate;
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return (shares * exchangeRate) / 1e18;
    }

    function maxDeposit(address receiver) external view override returns (uint256) {
        if (_maxDepositSet) return _maxDepositOverride;
        return type(uint256).max;
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view override returns (uint256) {
        if (_maxWithdrawSet[owner]) return _maxWithdrawOverrides[owner];
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        // Round up shares needed
        return (assets * 1e18 + exchangeRate - 1) / exchangeRate;
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    /* ========== ERC4626 MUTATIVE FUNCTIONS ========== */

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        shares = previewDeposit(assets);
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        assets = previewMint(shares);
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256 shares) {
        shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        _burn(owner, shares);
        IERC20(asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        assets = previewRedeem(shares);
        _burn(owner, shares);
        IERC20(asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }
}
