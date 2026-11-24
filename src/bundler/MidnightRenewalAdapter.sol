// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {CoreAdapter} from "@bundler3/adapters/CoreAdapter.sol";
import {MidnightRenewalAdapterBase} from "./MidnightRenewalAdapterBase.sol";
import {TenorRouter} from "../router/TenorRouter.sol";

/// @title MidnightRenewalAdapter
/// @notice Standalone Bundler3 adapter for Midnight to Midnight borrow and lend renewals.
contract MidnightRenewalAdapter is MidnightRenewalAdapterBase {
    constructor(address bundler3, address morphoMidnight) CoreAdapter(bundler3) TenorRouter(morphoMidnight) {}
}
