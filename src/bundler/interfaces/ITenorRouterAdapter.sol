// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {ExecuteParams, Action} from "../../router/TenorRouter.sol";
import {ITenorRouter} from "../../router/interfaces/ITenorRouter.sol";

interface ITenorRouterAdapter is ITenorRouter {
    // ERRORS
    /// @notice Raised when a sentinel `maxFill`/`minFill` is supplied for a fill index the adapter
    ///         doesn't know how to resolve (e.g. `FILL_SELLER_ASSETS`).
    error SentinelNotSupported(uint8 fillIndex);

    /// @notice Raised when the adapter resolves a sentinel `maxFill`/`minFill` to zero,
    ///         e.g. no prior position to size against, or an empty adapter balance.
    error SentinelResolvedToZero(uint8 fillIndex);

    /// @notice Raised when the post-execution group counter would exceed the caller-supplied cap.
    error ConsumedCapExceeded(uint256 newConsumed, uint256 maxConsumed);

    // FUNCTIONS

    /// @notice Executes a batch then increments the caller's consumed counter for `consumeGroup`
    ///         by the filled amount in the `params.fillAxis` dimension; enables mixed-execution
    ///         limit orders in one tx.
    /// @dev `consumeGroup` is the caller's self-limit group, independent of each offer's own `group`.
    ///      Midnight's auth on `setConsumed` enforces that the caller has authorized this adapter to
    ///      write into their namespace.
    /// @dev `consumeGroup` and `params.fillAxis` must match the group and dimension (units vs assets) the
    ///      caller's resting offers consume against, or the shared counter is corrupted.
    /// @dev Only taker-side fills advance the counter; maker-side fills are already tracked by
    ///      Midnight under the offer's own group.
    /// @dev Only top-level taker fills are counted; taker fills settled inside a callback are excluded, so the
    ///      self-limit is not atomic against nested fills.
    /// @param params Batch execution parameters (fill index, max/min fill, deadline, slippage).
    /// @param actions Per-action payloads (`MidnightTakeData`).
    /// @param consumeGroup Caller's self-limit group to increment.
    /// @param maxConsumed Final cap on `consumed[initiator][consumeGroup]` after the write;
    ///        `type(uint256).max` disables.
    /// @return buyerAssets Total buyer-side asset flow across the batch (post-fee).
    /// @return sellerAssets Total seller-side asset flow across the batch (post-fee).
    /// @return units Total market units filled across the batch.
    function executeAndConsume(
        ExecuteParams calldata params,
        Action[] calldata actions,
        bytes32 consumeGroup,
        uint256 maxConsumed
    ) external returns (uint256 buyerAssets, uint256 sellerAssets, uint256 units);
}
