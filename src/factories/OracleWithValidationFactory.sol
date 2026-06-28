// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {OracleWithValidation} from "@oracles/OracleWithValidation.sol";
import {IOracle} from "@midnight/interfaces/IOracle.sol";
import {IOracleWithValidationFactory} from "./interfaces/IOracleWithValidationFactory.sol";

/// @title OracleWithValidationFactory
/// @notice CREATE2 factory deploying OracleWithValidation instances.
/// @dev The factory rejects zero addresses, identical oracles, and maxOracleDeviation >= 1e18.
/// @dev The overpricing maxOracleDeviation permits must stay within the buffer the market allows, which is
/// (1 - LLTV * maxLif), where maxLif is the max Morpho liquidation incentive factor of any market consuming the
/// oracle. A liquidation seizes collateral worth repaidDebt * maxLif, so once overpricing exceeds this buffer a
/// liquidation no longer covers the debt and bad debt accrues. The deviation is scaled by the primary price, so a
/// threshold d allows up to d / (1 - d) effective overpricing (e.g. 5% allows ~5.26%); leave headroom below the
/// buffer for both this and natural oracle drift. Setting the threshold too tight can also reject valid prices
/// during routine drift, blocking price() and halting liquidations, which can let bad debt accumulate.
contract OracleWithValidationFactory is IOracleWithValidationFactory {
    mapping(address => bool) public isDeployedOracle;

    /// @inheritdoc IOracleWithValidationFactory
    function createOracleWithValidation(
        IOracle primaryOracle,
        IOracle validationOracle,
        uint256 maxOracleDeviation,
        bool revertOnValidationOracleFailure,
        address owner,
        bytes32 salt
    ) external returns (address oracle) {
        if (address(primaryOracle) == address(0)) revert NotAllowed();
        if (address(validationOracle) == address(0)) revert NotAllowed();
        if (address(primaryOracle) == address(validationOracle)) revert NotAllowed();
        if (maxOracleDeviation >= 1e18) revert NotAllowed();

        oracle = address(
            new OracleWithValidation{salt: salt}(
                primaryOracle, validationOracle, maxOracleDeviation, revertOnValidationOracleFailure, owner
            )
        );

        isDeployedOracle[oracle] = true;

        emit OracleWithValidationDeployed(
            oracle,
            address(primaryOracle),
            address(validationOracle),
            maxOracleDeviation,
            revertOnValidationOracleFailure,
            owner,
            salt
        );
    }
}
