// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IRenewalCadence} from "../interfaces/IRenewalCadence.sol";

/// @title FourWeekCadence
/// @notice Cadence with boundaries every 28 days from the Unix epoch (00:00:00 UTC).
contract FourWeekCadence is IRenewalCadence {
    /// @inheritdoc IRenewalCadence
    function cadencePeriodStart(uint256 timestamp) external pure returns (uint256) {
        return (timestamp / 28 days) * 28 days;
    }
}
