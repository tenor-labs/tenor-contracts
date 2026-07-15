// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {Market} from "@midnight/interfaces/IMidnight.sol";
import {MarketParams} from "@morphoBlue/interfaces/IMorpho.sol";

interface IBorrowRenewalConfigurationV1Adapter {
    // FUNCTIONS
    /// @notice Writes the borrow renewal configuration v1 on behalf of the initiator, atomically: the
    /// Midnight-to-Blue exit fallback always, plus the same-market Midnight renewal leg and the Blue-to-Midnight
    /// entry leg per their toggles (a disabled leg is cleared).
    /// @dev The market pair must be consistent: same loan token, and the Blue collateral listed on the Midnight
    /// market with the same lltv and oracle.
    /// @param market The Midnight market (maturity ignored): renewal-leg source and target, exit source, entry
    /// target.
    /// @param blueMarketParams The Blue market: exit target, entry source.
    /// @param limitRatePerSecond The initiator's per-second rate ceiling on the renewal and entry legs; must be in
    /// (0, MAX_RENEWAL_RATE_PER_SECOND] when either leg is enabled, and 0 when both are disabled.
    /// @param enableMidnightToMidnight Whether the Midnight renewal leg is enabled.
    /// @param enableBlueToMidnight Whether the Blue-to-Midnight entry leg is enabled.
    function setBorrowRenewalConfigurationV1(
        Market calldata market,
        MarketParams calldata blueMarketParams,
        uint40 limitRatePerSecond,
        bool enableMidnightToMidnight,
        bool enableBlueToMidnight
    ) external;

    /// @notice Clears all legs of the initiator's borrow renewal configuration v1 for the given market pair.
    /// @dev Validates the pair like `setBorrowRenewalConfigurationV1`, so a mismatched clear reverts instead of
    /// silently missing the live tuple.
    function clearBorrowRenewalConfigurationV1(Market calldata market, MarketParams calldata blueMarketParams) external;
}
