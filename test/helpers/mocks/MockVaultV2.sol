// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Mock that replicates VaultV2's exact previewWithdraw / previewRedeem / redeem rounding.
/// previewWithdraw rounds shares UP, previewRedeem rounds assets DOWN — so redeem(previewWithdraw(x))
/// can return strictly more than x, which is the source of the dust leak fixed in L-01.
contract MockVaultV2 is ERC20, IERC4626 {
    using Math for uint256;

    address public immutable override asset;
    uint256 public immutable virtualShares;
    uint128 internal _totalAssets;

    constructor(address _asset, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        asset = _asset;
        virtualShares = 1;
    }

    function totalAssets() public view override returns (uint256) {
        return _totalAssets;
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return previewDeposit(assets);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return previewRedeem(shares);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return assets.mulDiv(totalSupply() + virtualShares, _totalAssets + 1, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return shares.mulDiv(_totalAssets + 1, totalSupply() + virtualShares, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return assets.mulDiv(totalSupply() + virtualShares, _totalAssets + 1, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return shares.mulDiv(_totalAssets + 1, totalSupply() + virtualShares, Math.Rounding.Floor);
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view override returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return balanceOf(owner);
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        shares = previewDeposit(assets);
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        _totalAssets += uint128(assets);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        assets = previewMint(shares);
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        _totalAssets += uint128(assets);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        _totalAssets -= uint128(assets);
        IERC20(asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        assets = previewRedeem(shares);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        _totalAssets -= uint128(assets);
        IERC20(asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function setTotalAssets(uint128 newTotalAssets) external {
        _totalAssets = newTotalAssets;
    }
}
