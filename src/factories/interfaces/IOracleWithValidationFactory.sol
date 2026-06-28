// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {IOracle} from "@midnight/interfaces/IOracle.sol";

/// @title IOracleWithValidationFactory
/// @notice Interface of the CREATE2 factory deploying OracleWithValidation instances.
interface IOracleWithValidationFactory {
    event OracleWithValidationDeployed(
        address indexed oracle,
        address primaryOracle,
        address validationOracle,
        uint256 maxOracleDeviation,
        bool revertOnValidationOracleFailure,
        address owner,
        bytes32 salt
    );

    error NotAllowed();

    /// @notice Deploys a new OracleWithValidation via CREATE2.
    /// @dev Reverts if an oracle address is zero, the two oracles are identical, or maxOracleDeviation >= 1e18.
    /// @param primaryOracle The primary oracle, always used for the price.
    /// @param validationOracle The validation oracle used to bound-check the primary's price.
    /// @param maxOracleDeviation The maximum allowed deviation, in WAD.
    /// @param revertOnValidationOracleFailure Whether price() reverts when the validation oracle call reverts.
    /// @param owner The initial owner of the deployed oracle.
    /// @param salt The CREATE2 salt.
    /// @return oracle The address of the deployed oracle.
    function createOracleWithValidation(
        IOracle primaryOracle,
        IOracle validationOracle,
        uint256 maxOracleDeviation,
        bool revertOnValidationOracleFailure,
        address owner,
        bytes32 salt
    ) external returns (address oracle);

    /// @notice Whether `oracle` was deployed by this factory.
    function isDeployedOracle(address oracle) external view returns (bool);
}
