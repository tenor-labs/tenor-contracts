// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {CoreAdapter, ErrorsLib} from "@bundler3/adapters/CoreAdapter.sol";
import {IMigrationRatifier} from "../ratifiers/interfaces/IMigrationRatifier.sol";
import {IMigrationRatifierAdapter} from "./interfaces/IMigrationRatifierAdapter.sol";

/// @title MigrationRatifierAdapterBase
/// @notice Bundler3 adapter for per-tuple ratifier params config. Pins `onBehalf` to `initiator()`.
abstract contract MigrationRatifierAdapterBase is CoreAdapter, IMigrationRatifierAdapter {
    /// @notice The ratifier whose per-user params this adapter writes.
    IMigrationRatifier public immutable RATIFIER;

    constructor(address ratifier) {
        require(ratifier != address(0), ErrorsLib.ZeroAddress());
        RATIFIER = IMigrationRatifier(ratifier);
    }

    /// @inheritdoc IMigrationRatifierAdapter
    function migrationSetParams(
        address callback,
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        IMigrationRatifier.UserMigrationParams calldata params
    ) external onlyBundler3 {
        RATIFIER.setParams(initiator(), callback, sourceTenorMarketId, targetTenorMarketId, params);
    }

    /// @inheritdoc IMigrationRatifierAdapter
    function migrationClearParams(address callback, bytes32 sourceTenorMarketId, bytes32 targetTenorMarketId)
        external
        onlyBundler3
    {
        RATIFIER.clearParams(initiator(), callback, sourceTenorMarketId, targetTenorMarketId);
    }
}
