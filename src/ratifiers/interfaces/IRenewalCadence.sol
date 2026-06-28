// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

/// @title IRenewalCadence
/// @notice Interface of cadences defining the domain of valid maturity timestamps.
/// @dev If renewalCadence is address(0), cadence validation is skipped entirely.
interface IRenewalCadence {
    /// @notice Returns the start of the cadence period at or before a timestamp.
    /// @param timestamp The reference timestamp.
    /// @return boundary The largest cadence point <= timestamp.
    function cadencePeriodStart(uint256 timestamp) external view returns (uint256 boundary);
}
