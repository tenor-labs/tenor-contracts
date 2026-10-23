// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {CoreAdapter} from "@bundler3/adapters/CoreAdapter.sol";
import {MarketMakingPolicyAdapterBase} from "./MarketMakingPolicyAdapterBase.sol";

/// @title MarketMakingPolicyAdapter
/// @notice Bundler3 adapter for writing market making curves on behalf of the bundle initiator.
contract MarketMakingPolicyAdapter is MarketMakingPolicyAdapterBase {
    /* CONSTRUCTOR */

    /// @param bundler3 The Bundler3 contract address.
    constructor(address bundler3) CoreAdapter(bundler3) {}
}
