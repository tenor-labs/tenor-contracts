// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {CoreAdapter} from "@bundler3/adapters/CoreAdapter.sol";
import {IMarketMakingPolicy} from "../ratifiers/interfaces/IMarketMakingPolicy.sol";
import {IMarketMakingPolicyAdapter} from "./interfaces/IMarketMakingPolicyAdapter.sol";

/// @title MarketMakingPolicyAdapterBase
/// @notice Bundler3 adapter for market making curve config. Pins `onBehalf` to `initiator()`.
abstract contract MarketMakingPolicyAdapterBase is CoreAdapter, IMarketMakingPolicyAdapter {
    /// @inheritdoc IMarketMakingPolicyAdapter
    function marketMakingSetCurve(
        address policy,
        bytes32 tenorMarketId,
        IMarketMakingPolicy.CurvePoint[] calldata points
    ) external onlyBundler3 {
        IMarketMakingPolicy(policy).setCurve(initiator(), tenorMarketId, points);
    }

    /// @inheritdoc IMarketMakingPolicyAdapter
    function marketMakingClearCurve(address policy, bytes32 tenorMarketId) external onlyBundler3 {
        IMarketMakingPolicy(policy).clearCurve(initiator(), tenorMarketId);
    }
}
