// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

/// @title ClampFuzzFixtures
/// @notice Base contract with common fuzzing utilities for clamp tests
/// @dev Provides helpers for fuzzing callback fees and other common clamp test patterns
/// @dev For efficient fuzzing, use smaller types for bounded parameters in test function signatures:
///      - uint8 for percentages (0-100) and TTM seeds (0-7)
///      - uint16 for ticks (1-1046)
///      - uint256 for fee rates (need full WAD precision)
///      This reduces the search space and improves fuzzer efficiency without losing coverage
abstract contract ClampFuzzFixtures is Test {
    /// @notice Maximum fee rate for most callbacks (50%)
    uint256 internal constant MAX_FEE_RATE = 0.5e18;

    /// @notice Callback-level flat percentage fee cap for Midnight-to-Blue/Vault exit callbacks (1%)
    uint256 internal constant MAX_PERCENTAGE_FEE_RATE = 0.01e18;

    /// @notice Seed amount for liquidity seeding operations
    uint256 internal constant SEED_AMOUNT = 100e18;

    /// @notice Max offer capacity: type(uint128).max minus SEED_AMOUNT to avoid seeding overflow
    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 internal constant MAX_OFFER_CAPACITY = type(uint128).max - uint128(SEED_AMOUNT);

    /// @notice Max offer capacity for asset-denominated offers (maxAssets).
    /// @dev Capped to uint64 because converting large asset capacities to units at low ticks
    ///      can exceed uint128 (Midnight's unit type), causing spurious overflows.
    uint128 internal constant MAX_ASSET_DENOMINATED_CAPACITY = uint128(type(uint64).max);

    /// @notice Denomination modes for offer capacity. Post-midnight-collapse, the offer's `buy`
    ///         flag fixes which side `maxAssets` is interpreted as (buy ⇒ buyerAssets,
    ///         sell ⇒ sellerAssets), so there is no separate buyer/seller mode.
    uint8 internal constant DENOM_UNITS = 0;
    uint8 internal constant DENOM_ASSETS = 1;

    /// @notice Bound denomination seed to one of the two modes (units vs assets).
    function _boundDenomination(uint256 seed) internal pure returns (uint8) {
        return uint8(bound(seed, 0, 1));
    }

    /// @notice Bound offer capacity based on denomination mode.
    /// @dev Asset-denominated capacities are capped lower to avoid uint128 overflow on conversion to units.
    function _boundOfferCapacity(uint128 rawCapacity, uint8 denom) internal pure returns (uint128) {
        if (denom == DENOM_UNITS) {
            return uint128(bound(rawCapacity, 1, MAX_OFFER_CAPACITY));
        }
        return uint128(bound(rawCapacity, 1, MAX_ASSET_DENOMINATED_CAPACITY));
    }

    /// @notice Build the (maxUnits, maxAssets) tuple for an Offer.
    /// @dev Whether `maxAssets` is interpreted as buyer- or seller-side is determined by the
    ///      offer's `buy` flag at call site, not encoded here.
    function _denomFields(uint128 capacity, uint8 denom) internal pure returns (uint256 maxUnits, uint256 maxAssets) {
        if (denom == DENOM_ASSETS) return (0, capacity);
        return (capacity, 0);
    }

    /// @notice Bound and generate a valid callback fee rate for most callbacks
    /// @param feeRateSeed Raw fuzzer input
    /// @return feeRate Bounded fee rate in range [0, MAX_FEE_RATE]
    function _boundCallbackFeeRate(uint256 feeRateSeed) internal pure returns (uint256 feeRate) {
        return bound(feeRateSeed, 0, MAX_FEE_RATE);
    }

    /// @notice Bound and generate a valid callback fee rate for MidnightToBlue callbacks
    /// @param feeRateSeed Raw fuzzer input
    /// @return feeRate Bounded fee rate in range [0, MAX_PERCENTAGE_FEE_RATE]
    function _boundCallbackFeeRateMidnightToBlue(uint256 feeRateSeed) internal pure returns (uint256 feeRate) {
        return bound(feeRateSeed, 0, MAX_PERCENTAGE_FEE_RATE);
    }

    /// @notice Bound tick to valid range [1, 1046]
    /// @param tickSeed Raw fuzzer input
    /// @return tick Bounded tick value
    function _boundTick(uint256 tickSeed) internal pure returns (uint16 tick) {
        return uint16(bound(tickSeed, 1, 1455)) * 4;
    }

    /// @notice Bound percent to [0, 100] range
    /// @param percentSeed Raw fuzzer input
    /// @return percent Bounded percentage
    function _boundPercent(uint256 percentSeed) internal pure returns (uint8 percent) {
        return uint8(bound(percentSeed, 0, 100));
    }

    /// @notice Generate time-to-maturity seed for settlement fee testing
    /// @dev Maps to 8 breakpoints: 1s, 1d, 7d, 30d, 90d, 180d, 360d, >360d
    /// @param ttmSeed Raw fuzzer input
    /// @return ttm Time-to-maturity in seconds
    function _boundTimeToMaturity(uint256 ttmSeed) internal pure returns (uint256 ttm) {
        uint8 bucket = uint8(bound(ttmSeed, 0, 7));

        // Map to settlement fee breakpoints
        // Note: bucket 0 returns 1 second (not 0) to ensure maturity > block.timestamp
        if (bucket == 0) return 1; // ~0 days (but future maturity)
        if (bucket == 1) return 1 days; // 1 day
        if (bucket == 2) return 7 days; // 7 days
        if (bucket == 3) return 30 days; // 30 days
        if (bucket == 4) return 90 days; // 90 days
        if (bucket == 5) return 180 days; // 180 days
        if (bucket == 6) return 360 days; // 360 days
        return 365 days; // >360 days
    }
}
