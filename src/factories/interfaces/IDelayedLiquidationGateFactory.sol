// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

/// @title IDelayedLiquidationGateFactory
/// @notice Interface of the CREATE2 factory deploying DelayedLiquidationGate instances.
interface IDelayedLiquidationGateFactory {
    event DelayedLiquidationGateDeployed(
        address indexed gate,
        uint256 gracePeriod,
        uint256 liquidationPeriod,
        uint256 priorityPeriod,
        address indexed deployer
    );

    error InvalidPeriod();

    /// @notice The maximum value accepted for gracePeriod and liquidationPeriod.
    function MAX_PERIOD() external view returns (uint256);

    /// @notice The minimum value accepted for gracePeriod.
    /// @dev Also the maximum value accepted for priorityPeriod.
    function MIN_PERIOD() external view returns (uint256);

    /// @notice The Morpho Midnight protocol the deployed gates are bound to.
    function MORPHO_MIDNIGHT() external view returns (address);

    /// @notice Deploys a new DelayedLiquidationGate via CREATE2.
    /// @dev Reverts if gracePeriod is outside [MIN_PERIOD, MAX_PERIOD], liquidationPeriod is above MAX_PERIOD or
    /// below priorityPeriod + MIN_PERIOD, or priorityPeriod is above MIN_PERIOD.
    /// @param gracePeriod The seconds borrowers have to cure before liquidation opens.
    /// @param liquidationPeriod The seconds during which liquidation is permitted.
    /// @param priorityPeriod The seconds at the start of the liquidation window reserved for the priority
    /// liquidator recorded at startGracePeriod time.
    /// @param salt The CREATE2 salt.
    /// @return gate The address of the deployed gate.
    function deployDelayedLiquidationGate(
        uint256 gracePeriod,
        uint256 liquidationPeriod,
        uint256 priorityPeriod,
        bytes32 salt
    ) external returns (address gate);

    /// @notice Whether `gate` was deployed by this factory.
    function isDeployedGate(address gate) external view returns (bool);
}
