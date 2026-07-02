// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {CoreAdapter} from "@bundler3/adapters/CoreAdapter.sol";
import {TenorRouter, ExecuteParams, Action} from "../router/TenorRouter.sol";
import {RouterLib} from "../libraries/RouterLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {UtilsLib as MidnightUtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITenorRouter} from "../router/interfaces/ITenorRouter.sol";
import {ITenorRouterAdapter} from "./interfaces/ITenorRouterAdapter.sol";

/// @title TenorRouterAdapterBase
/// @notice Bundler3 adapter for TenorRouter batch execution. Overrides `_initiator` to return
///         `Bundler3.initiator()` and adds sentinel resolution + `executeAndConsume`.
abstract contract TenorRouterAdapterBase is TenorRouter, CoreAdapter, ITenorRouterAdapter {
    function _initiator() internal view override returns (address) {
        return initiator();
    }

    /// @inheritdoc ITenorRouter
    /// @dev Adapter override: callable only by Bundler3, and resolves `type(uint256).max`
    ///      `maxFill`/`minFill` sentinels against onchain state before executing.
    function execute(ExecuteParams calldata params, Action[] calldata actions)
        external
        override(TenorRouter, ITenorRouter)
        onlyBundler3
        returns (uint256, uint256, uint256)
    {
        (uint256[3] memory totals,) = _executeResolvingSentinels(params, actions);
        return (totals[0], totals[1], totals[2]);
    }

    /// @inheritdoc ITenorRouterAdapter
    function executeAndConsume(
        ExecuteParams calldata params,
        Action[] calldata actions,
        bytes32 consumeGroup,
        uint256 maxConsumed
    ) external override onlyBundler3 returns (uint256, uint256, uint256) {
        address initiator = _initiator();

        (uint256[3] memory totals, uint256[3] memory rawTotals) = _executeResolvingSentinels(params, actions);

        uint8 fillIndex = _fillIndex(params.fillAxis, actions, initiator);
        uint256 newConsumed = _MORPHO_MIDNIGHT.consumed(initiator, consumeGroup) + rawTotals[fillIndex];
        if (newConsumed > maxConsumed) revert ConsumedCapExceeded(newConsumed, maxConsumed);
        _MORPHO_MIDNIGHT.setConsumed(consumeGroup, MidnightUtilsLib.toUint128(newConsumed), initiator);
        return (totals[0], totals[1], totals[2]);
    }

    function _executeResolvingSentinels(ExecuteParams calldata params, Action[] calldata actions)
        internal
        returns (uint256[3] memory totals, uint256[3] memory rawTotals)
    {
        uint256 maxFill = params.maxFill;
        uint256 minFill = params.minFill;

        if (actions.length > 0 && (maxFill == type(uint256).max || minFill == type(uint256).max)) {
            address initiator = _initiator();
            uint8 fillIndex = _fillIndex(params.fillAxis, actions, initiator);
            uint256 resolved = _resolveSentinel(fillIndex, initiator, actions);
            if (resolved == 0) revert SentinelResolvedToZero(fillIndex);
            if (maxFill == type(uint256).max) maxFill = resolved;
            if (minFill == type(uint256).max) minFill = resolved;
        }

        return _execute(params, actions, maxFill, minFill);
    }

    /// @dev `FILL_UNITS` resolves to the initiator's debt (buyer-side) or credit (seller-side); side-aware so the
    /// resolved cap matches the existing position the action would close, preventing overshoot.
    /// `FILL_BUYER_ASSETS` resolves to `loanToken.balanceOf(adapter)`.
    /// `FILL_SELLER_ASSETS` is unsupported; it would cap borrower output by the adapter loan balance.
    function _resolveSentinel(uint8 fillIndex, address initiator, Action[] calldata actions)
        internal
        view
        returns (uint256)
    {
        if (fillIndex == RouterLib.FILL_UNITS) {
            bytes32 id = IdLib.toId(actions[0].offer.market);
            if (_initiatorIsBuyer(actions[0], initiator)) {
                return _MORPHO_MIDNIGHT.debt(id, initiator);
            }
            if (_MORPHO_MIDNIGHT.tickSpacing(id) == 0) return 0;
            (uint128 initiatorCredit,,) = _MORPHO_MIDNIGHT.updatePositionView(actions[0].offer.market, id, initiator);
            return initiatorCredit;
        } else if (fillIndex == RouterLib.FILL_BUYER_ASSETS) {
            return IERC20(actions[0].offer.market.loanToken).balanceOf(address(this));
        } else {
            revert SentinelNotSupported(fillIndex);
        }
    }
}
