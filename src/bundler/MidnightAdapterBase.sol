// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {CoreAdapter, ErrorsLib, IERC20, SafeERC20} from "@bundler3/adapters/CoreAdapter.sol";
import {IBundler3} from "@bundler3/interfaces/IBundler3.sol";
import {UtilsLib} from "@bundler3/libraries/UtilsLib.sol";
import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {IMidnightAdapter} from "./interfaces/IMidnightAdapter.sol";

/// @title MidnightAdapterBase
/// @notice Base adapter for Morpho Midnight operations via Bundler3.
/// @dev Inherit this in any adapter that needs Morpho Midnight support.
abstract contract MidnightAdapterBase is CoreAdapter, IMidnightAdapter {
    /* IMMUTABLES */

    /// @notice The Morpho Midnight contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    /* CONSTRUCTOR */

    /// @param morphoMidnight The Morpho Midnight contract address.
    constructor(address morphoMidnight) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
    }

    /* MORPHO_MIDNIGHT */

    /// @inheritdoc IMidnightAdapter
    function midnightRepay(
        Market calldata market,
        uint256 assets,
        uint256 debt,
        address callbackAddr,
        bytes calldata callbackData
    ) external onlyBundler3 {
        require(assets == 0 || debt == 0, InconsistentInput());
        require(assets != type(uint256).max || callbackAddr == address(0), InconsistentInput());

        address onBehalf = initiator();
        uint256 units;

        if (debt == type(uint256).max) {
            units = MORPHO_MIDNIGHT.debt(IdLib.toId(market), onBehalf);
        } else if (debt != 0) {
            units = debt;
        } else if (assets == type(uint256).max) {
            units = IERC20(market.loanToken).balanceOf(address(this));
        } else if (assets != 0) {
            units = assets;
        }

        if (units == 0) return;

        SafeERC20.forceApprove(IERC20(market.loanToken), address(MORPHO_MIDNIGHT), type(uint256).max);
        MORPHO_MIDNIGHT.repay(market, units, onBehalf, callbackAddr, callbackData);
    }

    /// @inheritdoc IMidnightAdapter
    function midnightSupplyCollateral(Market calldata market, uint256 collateralIndex, uint256 assets)
        external
        onlyBundler3
    {
        address onBehalf = initiator();

        address collateralToken = market.collateralParams[collateralIndex].token;

        if (assets == type(uint256).max) {
            assets = IERC20(collateralToken).balanceOf(address(this));
        }

        require(assets != 0, ErrorsLib.ZeroAmount());

        SafeERC20.forceApprove(IERC20(collateralToken), address(MORPHO_MIDNIGHT), type(uint256).max);
        MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, assets, onBehalf);
    }

    /// @inheritdoc IMidnightAdapter
    function midnightWithdrawCollateral(
        Market calldata market,
        uint256 collateralIndex,
        uint256 assets,
        address receiver
    ) external onlyBundler3 {
        address onBehalf = initiator();
        if (assets == type(uint256).max) {
            bytes32 id = IdLib.toId(market);
            assets = MORPHO_MIDNIGHT.collateral(id, onBehalf, collateralIndex);
        }

        require(assets != 0, ErrorsLib.ZeroAmount());

        MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, assets, onBehalf, receiver);
    }

    /// @inheritdoc IMidnightAdapter
    function midnightWithdraw(Market calldata market, uint256 units, address receiver) external onlyBundler3 {
        address onBehalf = initiator();
        if (units == type(uint256).max) {
            bytes32 id = IdLib.toId(market);
            (units,,) = MORPHO_MIDNIGHT.updatePositionView(market, id, onBehalf);
        }

        require(units != 0, ErrorsLib.ZeroAmount());

        MORPHO_MIDNIGHT.withdraw(market, units, onBehalf, receiver);
    }

    /// @inheritdoc IMidnightAdapter
    function midnightSetConsumed(bytes32 group, uint128 amount) external onlyBundler3 {
        MORPHO_MIDNIGHT.setConsumed(group, amount, initiator());
    }

    /// @inheritdoc IMidnightAdapter
    function midnightFlashLoan(address[] calldata tokens, uint256[] calldata assets, bytes calldata data)
        external
        onlyBundler3
    {
        require(tokens.length == assets.length, InconsistentInput());

        for (uint256 i = 0; i < tokens.length; i++) {
            require(assets[i] != 0, ErrorsLib.ZeroAmount());
            if (IERC20(tokens[i]).allowance(address(this), address(MORPHO_MIDNIGHT)) != type(uint256).max) {
                SafeERC20.forceApprove(IERC20(tokens[i]), address(MORPHO_MIDNIGHT), type(uint256).max);
            }
        }

        MORPHO_MIDNIGHT.flashLoan(tokens, assets, address(this), data);
    }

    /* CALLBACKS */

    /// @notice Callback from Morpho Midnight during flash loan.
    /// @dev Allows reentering bundler during Morpho Midnight.flashLoan
    /// @dev `caller` must be this adapter. Legitimate flash loans originate from `midnightFlashLoan`
    ///      (which calls `Midnight.flashLoan` as `msg.sender = adapter`). Rejecting other callers
    ///      blocks an external party from forcing the adapter onto a `flashLoan` payer slot,
    ///      where any token with a residual max allowance (set by a prior `midnightFlashLoan`)
    ///      would otherwise let them consume the bundle's reenter slot at no cost.
    /// @param data Bytes containing an abi-encoded `Call[]` (must be `memory` per `IFlashLoanCallback` interface).
    function onFlashLoan(address caller, address[] memory, uint256[] memory, bytes memory data)
        external
        returns (bytes32)
    {
        require(msg.sender == address(MORPHO_MIDNIGHT), ErrorsLib.UnauthorizedSender());
        require(caller == address(this), ErrorsLib.UnauthorizedSender());
        _midnightCallback(data);
        return CALLBACK_SUCCESS;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Handles callbacks from Morpho Midnight (which use `bytes memory`).
    /// @dev Sender validation already done in caller.
    /// @dev Manual call needed because CoreAdapter.reenterBundler3 expects calldata, but Morpho Midnight callbacks
    /// provide memory
    /// @dev Bundler3 allows at most one reentry per top-level multicall slot; a second `Bundler3.reenter` inside
    ///      the same slot reverts with `IncorrectReenterHash`. Bundles where more than one inner action triggers
    ///      a Midnight callback that reenters here (e.g. multiple Midnight `take` actions with a reentrant
    ///      `takerCallback` dispatched by `TenorRouter`) must split those actions across separate top-level
    ///      `Bundler3.multicall` `Call` entries; each entry gets its own `reenterHash`.
    function _midnightCallback(bytes memory data) internal {
        (bool success, bytes memory returnData) =
            BUNDLER3.call(abi.encodePacked(IBundler3(BUNDLER3).reenter.selector, data));
        if (!success) UtilsLib.lowLevelRevert(returnData);
    }
}
