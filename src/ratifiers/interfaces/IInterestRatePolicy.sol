// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

/// @title IInterestRatePolicy
/// @notice Interface of interest rate policies that compute rates for renewal pricing.
/// @dev Rate values are rates per second in WAD (1e18 = 100% per second). Policies receive the source and target
/// market ids for collateral-sensitive pricing, the renewal period start timestamp to compute elapsed time
/// internally, the user address (the position owner being renewed), the taker filling the offer for
/// counterparty-aware pricing, the source and target maturities for context, and the user's side for
/// direction-aware pricing.
/// @dev Policies are user-supplied and untrusted by the protocol; integrators and keepers must treat
/// getRate as potentially reverting or gas-expensive.
interface IInterestRatePolicy {
    /// @notice Returns the interest rate for the given renewal context.
    /// @param sourceTenorMarketId The id of the source side of the renewal (the position being closed).
    /// @param targetTenorMarketId The id of the target side of the renewal (the position being entered).
    /// @param renewalPeriodStart The renewal period start timestamp (the policy computes the elapsed time internally).
    /// @param user The position owner being renewed (the offer maker in the make-on-behalf flow).
    /// @param taker The counterparty filling the offer (Midnight's `take` caller), forwarded from
    ///        `isRatified`. Policies may quote taker-dependent rates (e.g. preferred counterparties);
    ///        policies that don't discriminate must ignore it.
    /// @param sourceMaturity The source market maturity (0 for Blue to Midnight migrations).
    /// @param targetMaturity The target market maturity (0 for Midnight to Blue exits).
    /// @param userIsBuyer The renewed user's side in the trade, derived from the migration direction.
    /// @return rate The interpolated rate per second in WAD at the given elapsed time.
    function getRate(
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        uint256 renewalPeriodStart,
        address user,
        address taker,
        uint256 sourceMaturity,
        uint256 targetMaturity,
        bool userIsBuyer
    ) external view returns (uint256 rate);
}
