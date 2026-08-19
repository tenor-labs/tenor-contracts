// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMarketMakingPolicy} from "../interfaces/IMarketMakingPolicy.sol";

/// @title CurveOperator
/// @notice Scoped delegate for MarketMakingPolicy curve writes. MAKER authorizes this contract on Midnight; OPERATOR
/// is the only key that can use it.
/// @dev The Midnight grant is unscoped. The scoping comes from this contract having no code path that reaches
/// Midnight, so deploy it non-upgradeable, never behind a proxy, and never add an arbitrary-call, delegatecall, or
/// fallback path.
/// @dev Holds no storage: the blast radius of MAKER's Midnight grant is fully readable from the three immutables.
contract CurveOperator {
    IMarketMakingPolicy public immutable POLICY;
    address public immutable MAKER;
    address public immutable OPERATOR;

    error Unauthorized();

    constructor(address policy, address maker, address operator) {
        POLICY = IMarketMakingPolicy(policy);
        MAKER = maker;
        OPERATOR = operator;
    }

    /// @notice Write MAKER's curve for `tenorMarketId`.
    function setCurve(bytes32 tenorMarketId, IMarketMakingPolicy.CurvePoint[] calldata points) external {
        if (msg.sender != OPERATOR) revert Unauthorized();
        POLICY.setCurve(MAKER, tenorMarketId, points);
    }

    /// @notice Clear MAKER's curve for `tenorMarketId`.
    function clearCurve(bytes32 tenorMarketId) external {
        if (msg.sender != OPERATOR) revert Unauthorized();
        POLICY.clearCurve(MAKER, tenorMarketId);
    }
}
