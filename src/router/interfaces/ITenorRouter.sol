// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {ExecuteParams, Action} from "../TenorRouter.sol";

/// @title ITenorRouter
/// @notice Interface of the router executing Midnight take batches with per-batch fill, price, continuous-fee and
/// crossing protections.
interface ITenorRouter {
    event BatchExecuted(
        address indexed initiator,
        address indexed msgSender,
        ExecuteParams params,
        uint256 actionsCount,
        uint256 buyerAssets,
        uint256 sellerAssets,
        uint256 units
    );

    event ActionReverted(uint256 indexed index, bytes reason);

    error InsufficientFill(uint256 filled, uint256 minFill);
    error PriceSlippageExceeded(uint256 price, uint256 min, uint256 max);
    error ActionFailed(uint256 index, bytes reason);
    error DeadlineExpired(uint256 deadline, uint256 timestamp);
    error FillOvershoot(uint256 filled, uint256 maxFill);
    /// @notice Action `i`'s `_initiatorIsBuyer` result differs from `actions[0]`'s. The bool arg is the expected
    /// batch side (`!offer.buy`, since the initiator is always the taker).
    error InconsistentSide(uint256 index, bool batchIsBuyerSide);
    error InconsistentMarket(uint256 index);
    error ContinuousFeeAboveMax();
    error EmptyActions();
    /// @notice `maxFill` exceeds `type(uint128).max` (after sentinel resolution).
    error MaxFillTooLarge();
    error ReduceOnlyViolated(uint256 wrongSideBefore, uint256 wrongSideAfter);

    /// @notice Executes a batch of direct `midnight.take` actions, accumulating buyer/seller/units totals and
    /// enforcing per-batch fill bounds and price slippage. The initiator is the Midnight taker for every action.
    /// @dev All actions must share `actions[0]`'s market (`offer.market`).
    /// @dev All actions must share `actions[0]`'s side (`_initiatorIsBuyer(action, initiator)`).
    /// @dev `fillAxis == ASSETS` resolves to the batch side; slippage uses the same axis.
    /// @return buyerAssets The total buyer-side asset flow (post-fee).
    /// @return sellerAssets The total seller-side asset flow (post-fee).
    /// @return units The total market units filled.
    function execute(ExecuteParams calldata params, Action[] calldata actions)
        external
        returns (uint256 buyerAssets, uint256 sellerAssets, uint256 units);
}
