// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

/// @title IMidnightAllowlistGateFactory
/// @notice Interface of the CREATE2 factory deploying MidnightAllowlistGate instances.
interface IMidnightAllowlistGateFactory {
    event MidnightAllowlistGateDeployed(address indexed gate, address indexed owner, bytes32 salt);

    /// @notice Deploys a new MidnightAllowlistGate via CREATE2.
    /// @param owner The initial owner of the deployed gate.
    /// @param salt The CREATE2 salt.
    /// @return gate The address of the deployed gate.
    function deployMidnightAllowlistGate(address owner, bytes32 salt) external returns (address gate);

    /// @notice Whether `gate` was deployed by this factory.
    function isDeployedGate(address gate) external view returns (bool);
}
