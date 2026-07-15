// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {CoreAdapter} from "@bundler3/adapters/CoreAdapter.sol";
import {MidnightAdapterBase} from "./MidnightAdapterBase.sol";
import {BorrowRenewalConfigurationV1AdapterBase} from "./BorrowRenewalConfigurationV1AdapterBase.sol";
import {BorrowRenewalConfigurationV1Base} from "../ratifiers/configurations/BorrowRenewalConfigurationV1Base.sol";
import {TenorRouterAdapterBase} from "./TenorRouterAdapterBase.sol";
import {TenorRouter} from "../router/TenorRouter.sol";

/// @title TenorAdapter
/// @notice Bundler3 adapter composing Midnight ops, canonical renewal params config, and TenorRouter batches.
contract TenorAdapter is MidnightAdapterBase, BorrowRenewalConfigurationV1AdapterBase, TenorRouterAdapterBase {
    constructor(
        address bundler3,
        address morphoMidnight,
        address ratifier,
        address entryRatePolicy,
        address exitRatePolicy,
        address renewalCadence,
        uint32 renewalWindow,
        uint32 exitWindow,
        uint32 minDuration,
        uint32 maxDuration
    )
        CoreAdapter(bundler3)
        MidnightAdapterBase(morphoMidnight)
        BorrowRenewalConfigurationV1Base(
            ratifier,
            entryRatePolicy,
            exitRatePolicy,
            renewalCadence,
            renewalWindow,
            exitWindow,
            minDuration,
            maxDuration
        )
        TenorRouter(morphoMidnight)
    {}
}
