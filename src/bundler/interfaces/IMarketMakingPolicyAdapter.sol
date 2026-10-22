// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {IMarketMakingPolicy} from "../../ratifiers/interfaces/IMarketMakingPolicy.sol";

interface IMarketMakingPolicyAdapter {
    // FUNCTIONS
    /// @notice Overwrites the curve for `tenorMarketId` on `policy` on behalf of the initiator.
    function marketMakingSetCurve(
        address policy,
        bytes32 tenorMarketId,
        IMarketMakingPolicy.CurvePoint[] calldata points
    ) external;

    /// @notice Deletes the curve for `tenorMarketId` on `policy` on behalf of the initiator.
    function marketMakingClearCurve(address policy, bytes32 tenorMarketId) external;
}
