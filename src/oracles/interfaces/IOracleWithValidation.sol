// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {IOracle} from "@midnight/interfaces/IOracle.sol";

/// @title IOracleWithValidation
/// @notice Interface of the oracle that checks the deviation between a primary and a validation oracle.
interface IOracleWithValidation is IOracle {
    event ValidationCheckPaused();
    event ValidationCheckUnpaused();

    error ExcessiveOracleDeviation();
    error ValidationOracleFailure();
    error NotAllowed();

    /// @notice The primary oracle whose price is always returned.
    function PRIMARY_ORACLE() external view returns (IOracle);
    /// @notice The validation oracle used to bound-check the primary's price.
    function VALIDATION_ORACLE() external view returns (IOracle);
    /// @notice The maximum allowed |primary - validation| / primary deviation, in WAD (e.g. 5e16 = 5%).
    function MAX_ORACLE_DEVIATION() external view returns (uint256);

    /// @notice Whether the deviation check against the validation oracle is paused.
    /// @dev When true, price() returns the primary price without validation.
    function validationCheckPaused() external view returns (bool);

    /// @notice Pauses validation: price() returns the primary price unchecked until unpauseValidationCheck is called.
    /// @dev Only callable by the owner. Reverts if already paused.
    function pauseValidationCheck() external;

    /// @notice Unpauses the validation check.
    /// @dev Only callable by the owner. Reverts if not paused.
    function unpauseValidationCheck() external;
}
