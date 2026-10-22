// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {CoreAdapter} from "@bundler3/adapters/CoreAdapter.sol";
import {IMarketMakingPolicy} from "../ratifiers/interfaces/IMarketMakingPolicy.sol";

/// @title MarketMakingPolicyAdapter
/// @notice Bundler3 adapter for writing market making curves on behalf of the bundle initiator.
contract MarketMakingPolicyAdapter is CoreAdapter {
    /* CONSTRUCTOR */

    /// @param bundler3 The Bundler3 contract address.
    constructor(address bundler3) CoreAdapter(bundler3) {}

    /* ACTIONS */

    /// @notice Overwrites the curve for `tenorMarketId` on `policy` on behalf of the bundle initiator.
    function marketMakingSetCurve(
        address policy,
        bytes32 tenorMarketId,
        IMarketMakingPolicy.CurvePoint[] calldata points
    ) external onlyBundler3 {
        IMarketMakingPolicy(policy).setCurve(initiator(), tenorMarketId, points);
    }

    /// @notice Deletes the curve for `tenorMarketId` on `policy` on behalf of the bundle initiator.
    function marketMakingClearCurve(address policy, bytes32 tenorMarketId) external onlyBundler3 {
        IMarketMakingPolicy(policy).clearCurve(initiator(), tenorMarketId);
    }
}
