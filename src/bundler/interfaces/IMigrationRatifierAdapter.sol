// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {IMigrationRatifier} from "../../ratifiers/interfaces/IMigrationRatifier.sol";

interface IMigrationRatifierAdapter {
    // FUNCTIONS
    /// @notice Writes migration params on behalf of the initiator for the given tuple.
    function migrationSetParams(
        address callback,
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        IMigrationRatifier.UserMigrationParams calldata params
    ) external;

    /// @notice Clears migration params on the initiator's tuple.
    function migrationClearParams(address callback, bytes32 sourceTenorMarketId, bytes32 targetTenorMarketId) external;
}
