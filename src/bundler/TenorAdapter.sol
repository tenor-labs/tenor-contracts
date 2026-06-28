// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {CoreAdapter} from "@bundler3/adapters/CoreAdapter.sol";
import {MidnightAdapterBase} from "./MidnightAdapterBase.sol";
import {MigrationRatifierAdapterBase} from "./MigrationRatifierAdapterBase.sol";
import {TenorRouterAdapterBase} from "./TenorRouterAdapterBase.sol";
import {TenorRouter} from "../router/TenorRouter.sol";

/// @title TenorAdapter
/// @notice Bundler3 adapter composing Midnight ops, ratifier params config, and TenorRouter batches.
contract TenorAdapter is MidnightAdapterBase, MigrationRatifierAdapterBase, TenorRouterAdapterBase {
    constructor(address bundler3, address morphoMidnight, address ratifier)
        CoreAdapter(bundler3)
        MidnightAdapterBase(morphoMidnight)
        MigrationRatifierAdapterBase(ratifier)
        TenorRouter(morphoMidnight)
    {}
}
