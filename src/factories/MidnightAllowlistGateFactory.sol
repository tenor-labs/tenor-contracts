// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {MidnightAllowlistGate} from "@gates/MidnightAllowlistGate.sol";
import {IMidnightAllowlistGateFactory} from "./interfaces/IMidnightAllowlistGateFactory.sol";

/// @title MidnightAllowlistGateFactory
/// @notice CREATE2 factory deploying MidnightAllowlistGate instances.
contract MidnightAllowlistGateFactory is IMidnightAllowlistGateFactory {
    mapping(address => bool) public isDeployedGate;

    /// @inheritdoc IMidnightAllowlistGateFactory
    function deployMidnightAllowlistGate(address owner, bytes32 salt) external returns (address gate) {
        gate = address(new MidnightAllowlistGate{salt: salt}(owner));

        isDeployedGate[gate] = true;

        emit MidnightAllowlistGateDeployed(gate, owner, salt);
    }
}
