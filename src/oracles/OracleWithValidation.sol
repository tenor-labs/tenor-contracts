// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IOracle} from "@midnight/interfaces/IOracle.sol";
import {IOracleWithValidation} from "./interfaces/IOracleWithValidation.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title OracleWithValidation
/// @notice Oracle that checks the deviation between a primary and a validation oracle.
/// @dev Conforms to the Morpho IOracle interface.
/// @dev The primary oracle is always used for the price, but price() reverts if the
/// deviation from the validation oracle exceeds the threshold.
/// @dev The deployer must ensure VALIDATION_ORACLE returns a well-formed (uint256) payload. Malformed returndata
/// (length != 32) bypasses try/catch and reverts price(); excess returndata is truncated to the first 32 bytes.
/// @dev Pausing validation and then renouncing ownership permanently locks the wrapper into primary-only mode.
/// To make the validated configuration immutable, renounce ownership while validationCheckPaused is false.
/// @dev The deviation is scaled by the primary price, so a threshold d allows up to d / (1 - d) overpricing
/// relative to the validation oracle (e.g. 5% configured allows ~5.26% effective).
/// @dev A validation oracle that returns 0 instead of reverting is not caught by the try/catch: against a nonzero
/// primary price the deviation check fails, so price() reverts even when REVERT_ON_VALIDATION_ORACLE_FAILURE is false.
/// @dev price() can return 0 to Morpho Markets: the primary oracle returns 0 while the validation check is paused,
/// the validation price is also 0, or the validation call reverts while REVERT_ON_VALIDATION_ORACLE_FAILURE is false.
/// @dev When REVERT_ON_VALIDATION_ORACLE_FAILURE is true, pausing the validation check is the only way to keep
/// price() working if the validation oracle permanently breaks; renouncing ownership removes that option.
contract OracleWithValidation is IOracleWithValidation, Ownable2Step {
    using UtilsLib for uint256;

    /* IMMUTABLES */

    IOracle public immutable PRIMARY_ORACLE;
    IOracle public immutable VALIDATION_ORACLE;

    uint256 public immutable MAX_ORACLE_DEVIATION;

    /// @notice Whether price() reverts when the validation oracle call reverts.
    /// @dev When false, the primary price is returned unchecked instead.
    bool public immutable REVERT_ON_VALIDATION_ORACLE_FAILURE;

    /* STORAGE */

    bool public validationCheckPaused;

    /* CONSTRUCTOR */

    /// @param maxOracleDeviation Max deviation between the two oracle prices, as a WAD fraction (1e18 = 100%).
    constructor(
        IOracle primaryOracle,
        IOracle validationOracle,
        uint256 maxOracleDeviation,
        bool revertOnValidationOracleFailure,
        address initialOwner
    ) Ownable(initialOwner) {
        PRIMARY_ORACLE = primaryOracle;
        VALIDATION_ORACLE = validationOracle;
        MAX_ORACLE_DEVIATION = maxOracleDeviation;
        REVERT_ON_VALIDATION_ORACLE_FAILURE = revertOnValidationOracleFailure;
    }

    /* PRICE FUNCTION */

    /// @inheritdoc IOracle
    function price() external view returns (uint256) {
        uint256 primaryPrice = PRIMARY_ORACLE.price();
        if (validationCheckPaused) return primaryPrice;

        try VALIDATION_ORACLE.price() returns (uint256 validationPrice) {
            uint256 absoluteDeviation =
                primaryPrice > validationPrice ? primaryPrice - validationPrice : validationPrice - primaryPrice;
            uint256 maxAllowedDeviation = primaryPrice.mulDivDown(MAX_ORACLE_DEVIATION, 1e18);

            if (absoluteDeviation > maxAllowedDeviation) revert ExcessiveOracleDeviation();
        } catch {
            if (REVERT_ON_VALIDATION_ORACLE_FAILURE) revert ValidationOracleFailure();
        }

        return primaryPrice;
    }

    /* OWNER FUNCTIONS */

    /// @inheritdoc IOracleWithValidation
    function pauseValidationCheck() external onlyOwner {
        if (validationCheckPaused) revert NotAllowed();
        validationCheckPaused = true;
        emit ValidationCheckPaused();
    }

    /// @inheritdoc IOracleWithValidation
    function unpauseValidationCheck() external onlyOwner {
        if (!validationCheckPaused) revert NotAllowed();
        validationCheckPaused = false;
        emit ValidationCheckUnpaused();
    }
}
