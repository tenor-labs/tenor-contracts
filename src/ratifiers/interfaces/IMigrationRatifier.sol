// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {IRatifier} from "@midnight/interfaces/IRatifier.sol";

/// @title IMigrationRatifier
/// @notice Interface of migration ratifiers.
/// @dev Migration and renewal takes are validated against per-user params and a protocol fee config.
interface IMigrationRatifier is IRatifier {
    /// @notice Per-user policy bundle the ratifier reads when validating a take, keyed by
    /// (callback, sourceTenorMarketId, targetTenorMarketId) and stored on the implementing ratifier.
    /// @param interestRatePolicy The policy contract supplying the user's rate ceiling/floor for this tuple.
    /// @param renewalWindow The number of seconds before source maturity within which a Midnight source becomes
    /// eligible. Must not exceed source maturity, and seeds the renewal period start (sourceMaturity - renewalWindow).
    /// Ignored for non-Midnight sources and non-binding for Midnight sources past maturity.
    /// @param minDuration The minimum duration the user accepts: block.timestamp + minDuration <= targetMaturity.
    /// @param maxDuration The maximum duration the user accepts: targetMaturity <= block.timestamp + maxDuration.
    /// @param renewalCadence The cadence contract. If non-zero, targetMaturity must land on a cadence boundary.
    /// Required for Blue and vault entry flows (zero source maturity), where it also seeds the renewal period start;
    /// omitting it there reverts InvalidRenewalParams.
    /// @param limitRatePerSecond The user-supplied rate cap per second, combined with the policy rate (min for
    /// borrowers, max for lenders) before validation.
    struct UserMigrationParams {
        address interestRatePolicy;
        uint32 renewalWindow;
        uint32 minDuration;
        uint32 maxDuration;
        address renewalCadence;
        uint40 limitRatePerSecond;
    }

    /// @notice Protocol fee config for a (callback, tenorMarketId) pair.
    /// @dev tenorMarketId = bytes32(0) holds the action-level default; specific market ids override it.
    /// @param feeRecipient Receives the fee. address(0) marks the config as unset, falling back to the default.
    /// @param feeRate The fee rate in WAD, at most the callback's maximum fee rate.
    struct FeeConfig {
        address feeRecipient;
        uint96 feeRate;
    }

    event FeeConfigSet(address indexed callback, bytes32 indexed tenorMarketId, uint256 feeRate, address feeRecipient);

    event ParamsSet(
        address indexed user,
        address indexed callback,
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        UserMigrationParams params
    );

    event ParamsCleared(
        address indexed user, address indexed callback, bytes32 sourceTenorMarketId, bytes32 targetTenorMarketId
    );

    error InvalidRenewalParams();
    error Unauthorized();
    error InvalidFeeConfig();
    error InvalidRenewalWindow();
    error InvalidTargetMaturity();
    error InvalidOfferRate();
    error InvalidCallback();
    error InvalidCallbackData();
    error InvalidRatifierData();
    error InvalidReceiver();
    error InvalidGroup();

    /// @notice Reserved marker that every ratified offer's `group` must carry in its top 6 bytes: the
    /// "tenor" domain prefix plus the reserved schema version byte, so the migration path can only ever write
    /// Midnight's `consumed[offer.maker][group]` in a namespace disjoint from `offer.maker`'s own non-migration offers
    /// (which carry a different version). The low 208 bits stay free to vary per offer.
    function MIGRATION_GROUP_HEADER() external view returns (bytes32);

    /// @notice Mask selecting the top 6 bytes of `group` that `MIGRATION_GROUP_HEADER` occupies.
    function MIGRATION_GROUP_HEADER_MASK() external view returns (bytes32);

    /// @notice The Morpho Midnight protocol the ratifier reads from.
    function MORPHO_MIDNIGHT() external view returns (IMidnight);

    /// @notice Returns the effective fee config for (callback, tenorMarketId): the market-specific override if set
    /// (feeRecipient != address(0)), otherwise the action-level default keyed by tenorMarketId = bytes32(0).
    function getEffectiveFeeConfig(address callback, bytes32 tenorMarketId) external view returns (FeeConfig memory);

    /// @notice The raw fee config for (callback, tenorMarketId), without fallback to the default.
    function feeConfigs(address callback, bytes32 tenorMarketId)
        external
        view
        returns (address feeRecipient, uint96 feeRate);

    /// @notice The per-user migration params for the (callback, sourceTenorMarketId, targetTenorMarketId) tuple.
    function userParams(address user, address callback, bytes32 sourceTenorMarketId, bytes32 targetTenorMarketId)
        external
        view
        returns (
            address interestRatePolicy,
            uint32 renewalWindow,
            uint32 minDuration,
            uint32 maxDuration,
            address renewalCadence,
            uint40 limitRatePerSecond
        );

    /// @notice Sets the protocol fee config for (callback, tenorMarketId).
    /// @dev Only callable by the ratifier owner.
    /// @dev Use tenorMarketId = bytes32(0) to write the action-level default.
    function setFeeConfig(address callback, bytes32 tenorMarketId, uint256 feeRate, address feeRecipient) external;

    /// @notice Sets onBehalf's migration params for the (callback, sourceTenorMarketId, targetTenorMarketId) tuple.
    /// @dev Callable by onBehalf itself or anyone they have authorized on Midnight.
    function setParams(
        address onBehalf,
        address callback,
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        UserMigrationParams calldata params
    ) external;

    /// @notice Clears onBehalf's migration params for the (callback, sourceTenorMarketId, targetTenorMarketId) tuple.
    /// @dev Callable by onBehalf itself or anyone they have authorized on Midnight.
    function clearParams(address onBehalf, address callback, bytes32 sourceTenorMarketId, bytes32 targetTenorMarketId)
        external;
}
