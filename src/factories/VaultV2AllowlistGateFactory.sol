// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {VaultV2AllowlistGate} from "@gates/VaultV2AllowlistGate.sol";
import {IVaultV2AllowlistGateFactory} from "./interfaces/IVaultV2AllowlistGateFactory.sol";

/// @title VaultV2AllowlistGateFactory
/// @notice CREATE2 factory deploying VaultV2AllowlistGate instances.
contract VaultV2AllowlistGateFactory is IVaultV2AllowlistGateFactory {
    mapping(address => bool) public isDeployedGate;

    /// @inheritdoc IVaultV2AllowlistGateFactory
    function deployVaultV2AllowlistGate(address owner, bytes32 salt) external returns (address gate) {
        gate = address(new VaultV2AllowlistGate{salt: salt}(owner));

        isDeployedGate[gate] = true;

        emit VaultV2AllowlistGateDeployed(gate, owner, salt);
    }
}
