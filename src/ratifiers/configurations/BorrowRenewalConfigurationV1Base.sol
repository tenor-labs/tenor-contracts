// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {Market, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {Id, MarketParams} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";
import {IMigrationRatifier} from "../interfaces/IMigrationRatifier.sol";
import {CallbackLib} from "../../libraries/CallbackLib.sol";
import {TenorMarketIdLib} from "../../libraries/TenorMarketIdLib.sol";

/// @title BorrowRenewalConfigurationV1Base
/// @notice Canonical three-leg borrow renewal params bundle written to a migration ratifier. Entry-point
/// agnostic; inheritors expose the internal writes and are responsible for authorization and batching.
/// @dev Every ratifier param except the market pair, the entry/renewal rate ceiling, and the two leg toggles is
/// fixed at construction, so any other tuple is unreachable through this configuration.
/// @dev Contract does not prevent a user from manually modifying ratification parameters outside this contract. Such
/// usage is outside this contract's guarantees, and the user is responsible for ensuring that the configuration
/// remains valid.
/// @dev The configuration never reads or writes lend-side tuples and performs no lend-side checks by design.
/// Lend-side configurations are outside the scope of this contract. Borrow migrations may net out existing credit.
/// @dev MigrationRatifier ROUTE LOOP SAFETY requirements are enforced given user operates ratification params
/// exclusively through this contract.
abstract contract BorrowRenewalConfigurationV1Base {
    using CallbackLib for Market;
    using MarketParamsLib for MarketParams;
    using TenorMarketIdLib for Market;

    error InvalidLimitRate();
    error InvalidRenewalConfig();
    error LoanTokenMismatch();
    error CollateralMismatch();

    /// @notice Hard cap on the caller-supplied renewal rate ceiling, per second: 15% APR (0.15e18 / 365 days).
    uint40 public constant MAX_RENEWAL_RATE_PER_SECOND = 4_756_468_797;

    /// @notice The ratifier whose per-user params this configuration writes.
    IMigrationRatifier public immutable RATIFIER;

    /// @notice The borrow Midnight-to-Midnight renewal callback, read from the ratifier.
    address public immutable BORROW_MIDNIGHT_RENEWAL_CALLBACK;

    /// @notice The borrow Midnight-to-Blue exit callback, read from the ratifier.
    address public immutable BORROW_MIDNIGHT_TO_BLUE_CALLBACK;

    /// @notice The borrow Blue-to-Midnight entry callback, read from the ratifier.
    address public immutable BORROW_BLUE_TO_MIDNIGHT_CALLBACK;

    /// @notice The rate policy written on the entry and renewal legs.
    address public immutable ENTRY_RATE_POLICY;

    /// @notice The rate policy written on the exit leg.
    address public immutable EXIT_RATE_POLICY;

    /// @notice The cadence contract written on all legs.
    address public immutable RENEWAL_CADENCE;

    /// @notice The renewal window written on the renewal leg.
    uint32 public immutable RENEWAL_WINDOW;

    /// @notice The renewal window written on the exit leg.
    uint32 public immutable EXIT_WINDOW;

    /// @notice The minimum target-position duration written on the entry and renewal legs.
    uint32 public immutable MIN_DURATION;

    /// @notice The maximum target-position duration written on all legs.
    uint32 public immutable MAX_DURATION;

    /// @param ratifier The migration ratifier the configuration writes to.
    /// @param entryRatePolicy The rate policy for the renewal and Blue-entry legs.
    /// @param exitRatePolicy The rate policy for the Blue-exit leg.
    /// @param renewalCadence The cadence contract target maturities must land on.
    /// @param renewalWindow Seconds before source maturity the renewal leg opens.
    /// @param exitWindow Seconds before source maturity the exit leg opens.
    /// @param minDuration The minimum duration of a renewed or entered position (the exit leg pins 1).
    /// @param maxDuration The maximum duration of a renewed or entered position.
    constructor(
        address ratifier,
        address entryRatePolicy,
        address exitRatePolicy,
        address renewalCadence,
        uint32 renewalWindow,
        uint32 exitWindow,
        uint32 minDuration,
        uint32 maxDuration
    ) {
        require(
            minDuration > renewalWindow && minDuration > exitWindow && maxDuration >= minDuration,
            InvalidRenewalConfig()
        );

        RATIFIER = IMigrationRatifier(ratifier);
        BORROW_MIDNIGHT_RENEWAL_CALLBACK = RATIFIER.BORROW_MIDNIGHT_RENEWAL_CALLBACK();
        BORROW_MIDNIGHT_TO_BLUE_CALLBACK = RATIFIER.BORROW_MIDNIGHT_TO_BLUE_CALLBACK();
        BORROW_BLUE_TO_MIDNIGHT_CALLBACK = RATIFIER.BORROW_BLUE_TO_MIDNIGHT_CALLBACK();

        ENTRY_RATE_POLICY = entryRatePolicy;
        EXIT_RATE_POLICY = exitRatePolicy;
        RENEWAL_CADENCE = renewalCadence;
        RENEWAL_WINDOW = renewalWindow;
        EXIT_WINDOW = exitWindow;
        MIN_DURATION = minDuration;
        MAX_DURATION = maxDuration;
    }

    /// @dev Writes the configuration for `onBehalf`; the caller binds `onBehalf` to its own authorization model.
    function _setBorrowRenewalConfigurationV1(
        address onBehalf,
        Market calldata market,
        MarketParams calldata blueMarketParams,
        uint40 limitRatePerSecond,
        bool enableMidnightToMidnight,
        bool enableBlueToMidnight
    ) internal {
        require(
            enableMidnightToMidnight || enableBlueToMidnight
                ? limitRatePerSecond != 0 && limitRatePerSecond <= MAX_RENEWAL_RATE_PER_SECOND
                : limitRatePerSecond == 0,
            InvalidLimitRate()
        );
        (bytes32 tenorMarketId, bytes32 blueMarketId) = _validateMarkets(market, blueMarketParams);

        if (enableMidnightToMidnight) {
            RATIFIER.setParams(
                onBehalf,
                BORROW_MIDNIGHT_RENEWAL_CALLBACK,
                tenorMarketId,
                tenorMarketId,
                IMigrationRatifier.UserMigrationParams({
                    interestRatePolicy: ENTRY_RATE_POLICY,
                    renewalWindow: RENEWAL_WINDOW,
                    minDuration: MIN_DURATION,
                    maxDuration: MAX_DURATION,
                    renewalCadence: RENEWAL_CADENCE,
                    limitRatePerSecond: limitRatePerSecond
                })
            );
        } else {
            RATIFIER.clearParams(onBehalf, BORROW_MIDNIGHT_RENEWAL_CALLBACK, tenorMarketId, tenorMarketId);
        }
        RATIFIER.setParams(
            onBehalf,
            BORROW_MIDNIGHT_TO_BLUE_CALLBACK,
            tenorMarketId,
            blueMarketId,
            IMigrationRatifier.UserMigrationParams({
                interestRatePolicy: EXIT_RATE_POLICY,
                renewalWindow: EXIT_WINDOW,
                minDuration: 1,
                maxDuration: MAX_DURATION,
                renewalCadence: RENEWAL_CADENCE,
                limitRatePerSecond: 0
            })
        );
        if (enableBlueToMidnight) {
            RATIFIER.setParams(
                onBehalf,
                BORROW_BLUE_TO_MIDNIGHT_CALLBACK,
                blueMarketId,
                tenorMarketId,
                IMigrationRatifier.UserMigrationParams({
                    interestRatePolicy: ENTRY_RATE_POLICY,
                    renewalWindow: 0, // unused for Blue sources
                    minDuration: MIN_DURATION,
                    maxDuration: MAX_DURATION,
                    renewalCadence: RENEWAL_CADENCE,
                    limitRatePerSecond: limitRatePerSecond
                })
            );
        } else {
            RATIFIER.clearParams(onBehalf, BORROW_BLUE_TO_MIDNIGHT_CALLBACK, blueMarketId, tenorMarketId);
        }
    }

    /// @dev Clears all three legs of `onBehalf`'s configuration for the given market pair.
    function _clearBorrowRenewalConfigurationV1(
        address onBehalf,
        Market calldata market,
        MarketParams calldata blueMarketParams
    ) internal {
        (bytes32 tenorMarketId, bytes32 blueMarketId) = _validateMarkets(market, blueMarketParams);

        RATIFIER.clearParams(onBehalf, BORROW_MIDNIGHT_RENEWAL_CALLBACK, tenorMarketId, tenorMarketId);
        RATIFIER.clearParams(onBehalf, BORROW_MIDNIGHT_TO_BLUE_CALLBACK, tenorMarketId, blueMarketId);
        RATIFIER.clearParams(onBehalf, BORROW_BLUE_TO_MIDNIGHT_CALLBACK, blueMarketId, tenorMarketId);
    }

    /// @dev Validates the market pair — same loan token, Blue collateral listed on the Midnight market with the
    /// same lltv and oracle — and returns their ids.
    function _validateMarkets(Market calldata market, MarketParams calldata blueMarketParams)
        internal
        pure
        returns (bytes32 tenorMarketId, bytes32 blueMarketId)
    {
        require(market.loanToken != address(0) && blueMarketParams.loanToken == market.loanToken, LoanTokenMismatch());
        (bool found, uint256 index) = market.findCollateral(blueMarketParams.collateralToken);
        require(found && blueMarketParams.collateralToken != address(0), CollateralMismatch());
        CollateralParams calldata collateral = market.collateralParams[index];
        require(
            collateral.lltv == blueMarketParams.lltv && collateral.oracle == blueMarketParams.oracle,
            CollateralMismatch()
        );
        tenorMarketId = market.toTenorMarketId();
        blueMarketId = Id.unwrap(blueMarketParams.id());
    }
}
