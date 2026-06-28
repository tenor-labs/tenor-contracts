// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IRenewalCadence} from "../../src/ratifiers/interfaces/IRenewalCadence.sol";

/// @title MockRenewalCadence
/// @notice Permissive cadence for testing: returns timestamp unchanged (identity function).
/// @dev Every maturity passes cadence validation since cadencePeriodStart(m) == m.
///      For Blue to Midnight paths, renewalPeriodStart = block.timestamp (boundary == now).
contract MockRenewalCadence is IRenewalCadence {
    function cadencePeriodStart(uint256 timestamp) external pure returns (uint256) {
        return timestamp;
    }
}
