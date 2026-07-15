// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {CoreAdapter} from "@bundler3/adapters/CoreAdapter.sol";
import {Market} from "@midnight/interfaces/IMidnight.sol";
import {MarketParams} from "@morphoBlue/interfaces/IMorpho.sol";
import {BorrowRenewalConfigurationV1Base} from "../ratifiers/configurations/BorrowRenewalConfigurationV1Base.sol";
import {IBorrowRenewalConfigurationV1Adapter} from "./interfaces/IBorrowRenewalConfigurationV1Adapter.sol";

/// @title BorrowRenewalConfigurationV1AdapterBase
/// @notice Bundler3 adapter exposing the borrow renewal configuration v1 writes. Pins `onBehalf` to
/// `initiator()`; the configuration's guarantees are documented on `BorrowRenewalConfigurationV1Base`.
abstract contract BorrowRenewalConfigurationV1AdapterBase is
    CoreAdapter,
    BorrowRenewalConfigurationV1Base,
    IBorrowRenewalConfigurationV1Adapter
{
    /// @inheritdoc IBorrowRenewalConfigurationV1Adapter
    function setBorrowRenewalConfigurationV1(
        Market calldata market,
        MarketParams calldata blueMarketParams,
        uint40 limitRatePerSecond,
        bool enableMidnightToMidnight,
        bool enableBlueToMidnight
    ) external onlyBundler3 {
        _setBorrowRenewalConfigurationV1(
            initiator(), market, blueMarketParams, limitRatePerSecond, enableMidnightToMidnight, enableBlueToMidnight
        );
    }

    /// @inheritdoc IBorrowRenewalConfigurationV1Adapter
    function clearBorrowRenewalConfigurationV1(Market calldata market, MarketParams calldata blueMarketParams)
        external
        onlyBundler3
    {
        _clearBorrowRenewalConfigurationV1(initiator(), market, blueMarketParams);
    }
}
