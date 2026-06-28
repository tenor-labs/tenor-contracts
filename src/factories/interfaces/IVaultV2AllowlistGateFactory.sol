// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IVaultV2AllowlistGateFactory
/// @notice Interface of the CREATE2 factory deploying VaultV2AllowlistGate instances.
interface IVaultV2AllowlistGateFactory {
    event VaultV2AllowlistGateDeployed(address indexed gate, address indexed owner, bytes32 salt);

    /// @notice Deploys a new VaultV2AllowlistGate via CREATE2.
    /// @param owner The initial owner of the deployed gate.
    /// @param salt The CREATE2 salt.
    /// @return gate The address of the deployed gate.
    function deployVaultV2AllowlistGate(address owner, bytes32 salt) external returns (address gate);

    /// @notice Whether `gate` was deployed by this factory.
    function isDeployedGate(address gate) external view returns (bool);
}
