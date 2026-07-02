// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {PausableBase} from "./PausableBase.sol";
import {StaticRatePolicy} from "./StaticRatePolicy.sol";
import {IInterestRatePolicy} from "../interfaces/IInterestRatePolicy.sol";

/// @title PausableStaticRatePolicy
/// @notice A StaticRatePolicy that can be paused.
/// @dev When paused, getRate reverts with IsPaused and blocks renewals.
/// @dev Pausing does not stop the auction clock; the rate advances on wall-clock elapsed time, pause windows
/// included.
contract PausableStaticRatePolicy is StaticRatePolicy, PausableBase {
    constructor(address _owner, uint128[] memory rates, uint128[] memory durations)
        StaticRatePolicy(rates, durations)
        PausableBase(_owner)
    {}

    /// @inheritdoc StaticRatePolicy
    function getRate(
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        uint256 renewalPeriodStart,
        address user,
        address taker,
        uint256 sourceMaturity,
        uint256 targetMaturity,
        bool userIsBuyer
    ) public view override(StaticRatePolicy, IInterestRatePolicy) whenNotPaused returns (uint256) {
        return super.getRate(
            sourceTenorMarketId,
            targetTenorMarketId,
            renewalPeriodStart,
            user,
            taker,
            sourceMaturity,
            targetMaturity,
            userIsBuyer
        );
    }
}
