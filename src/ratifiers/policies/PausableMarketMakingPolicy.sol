// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {MarketMakingPolicy} from "./MarketMakingPolicy.sol";
import {PausableBase} from "./PausableBase.sol";
import {IInterestRatePolicy} from "../interfaces/IInterestRatePolicy.sol";

/// @title PausableMarketMakingPolicy
/// @notice A MarketMakingPolicy that can be paused for all users of this policy instance.
/// @dev Pausers (configured by the owner) can halt all getRate quotes across every user; only the owner can unpause.
/// @dev Curve writes (setCurve and clearCurve) are unaffected by the paused state; only the quote path reverts.
/// Per-user pausing is already available via clearCurve.
contract PausableMarketMakingPolicy is MarketMakingPolicy, PausableBase {
    constructor(address _owner, address morphoMidnight) MarketMakingPolicy(morphoMidnight) PausableBase(_owner) {}

    /// @inheritdoc MarketMakingPolicy
    function getRate(
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        uint256 renewalPeriodStart,
        address user,
        address taker,
        uint256 sourceMaturity,
        uint256 targetMaturity,
        bool userIsBuyer
    ) public view override(MarketMakingPolicy, IInterestRatePolicy) whenNotPaused returns (uint256) {
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
