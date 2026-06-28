// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {DelayedLiquidationGate} from "@gates/DelayedLiquidationGate.sol";
import {IDelayedLiquidationGateFactory} from "./interfaces/IDelayedLiquidationGateFactory.sol";

/// @title DelayedLiquidationGateFactory
/// @notice CREATE2 factory deploying DelayedLiquidationGate instances.
/// @dev Only factory deployments guarantee the period bounds; the gate constructor does not validate them.
contract DelayedLiquidationGateFactory is IDelayedLiquidationGateFactory {
    mapping(address gate => bool) public isDeployedGate;

    uint256 public constant MAX_PERIOD = 3 days;
    uint256 public constant MIN_PERIOD = 1 minutes;

    address public immutable MORPHO_MIDNIGHT;

    constructor(address morphoMidnight) {
        MORPHO_MIDNIGHT = morphoMidnight;
    }

    /// @inheritdoc IDelayedLiquidationGateFactory
    function deployDelayedLiquidationGate(
        uint256 gracePeriod,
        uint256 liquidationPeriod,
        uint256 priorityPeriod,
        bytes32 salt
    ) external returns (address gate) {
        if (
            gracePeriod < MIN_PERIOD || gracePeriod > MAX_PERIOD || liquidationPeriod > MAX_PERIOD
                || priorityPeriod > MIN_PERIOD || liquidationPeriod < priorityPeriod + MIN_PERIOD
        ) {
            revert InvalidPeriod();
        }
        gate = address(
            new DelayedLiquidationGate{salt: salt}(MORPHO_MIDNIGHT, gracePeriod, liquidationPeriod, priorityPeriod)
        );

        isDeployedGate[gate] = true;

        emit DelayedLiquidationGateDeployed(gate, gracePeriod, liquidationPeriod, priorityPeriod, msg.sender);
    }
}
