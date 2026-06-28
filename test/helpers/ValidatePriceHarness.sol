// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {PriceLib} from "../../src/libraries/PriceLib.sol";

/// @title ValidatePriceHarness
/// @notice Exposes PriceLib.satisfiesRateLimit with InvalidOfferRate-style revert semantics
///         for use by ValidatePrice unit + fuzz tests. Rate validation lives in the migration ratifier
/// (BaseMigrationRatifier).
contract ValidatePriceHarness {
    error InvalidOfferRate();

    function validatePrice(
        bool isBuy,
        uint256 units,
        uint256 assets,
        uint256 limitRate,
        uint256 policyRate,
        uint256 duration
    ) external pure {
        if (assets == 0) revert InvalidOfferRate();
        if (!PriceLib.satisfiesRateLimit(isBuy, units, assets, limitRate, policyRate, duration)) {
            revert InvalidOfferRate();
        }
    }
}
