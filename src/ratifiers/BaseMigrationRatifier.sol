// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Offer, Market} from "@midnight/interfaces/IMidnight.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Id, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {IMigrationRatifier} from "./interfaces/IMigrationRatifier.sol";
import {IInterestRatePolicy} from "@ratifiers/interfaces/IInterestRatePolicy.sol";
import {IRenewalCadence} from "@ratifiers/interfaces/IRenewalCadence.sol";
import {IBorrowMidnightRenewalCallback} from "@callbacks/interfaces/IBorrowMidnightRenewalCallback.sol";
import {IBorrowBlueToMidnightCallback} from "@callbacks/interfaces/IBorrowBlueToMidnightCallback.sol";
import {ILendVaultToMidnightCallback} from "@callbacks/interfaces/ILendVaultToMidnightCallback.sol";
import {IBorrowMidnightToBlueCallback} from "@callbacks/interfaces/IBorrowMidnightToBlueCallback.sol";
import {ILendMidnightToVaultCallback} from "@callbacks/interfaces/ILendMidnightToVaultCallback.sol";
import {PriceLib} from "../libraries/PriceLib.sol";
import {RouterLib} from "../libraries/RouterLib.sol";
import {TenorMarketIdLib} from "../libraries/TenorMarketIdLib.sol";

/// @dev Maximum fee rate for Midnight to Midnight, Vault to Midnight, and Blue to Midnight actions (50% of interest).
uint256 constant MAX_FEE_RATE = 0.5e18;

/// @dev Maximum fee rate for fixed-to-variable exits (Midnight to Blue and Midnight to Vault); fees permanently
/// disabled since the constant is 0.
uint256 constant MAX_FEE_RATE_FIXED_TO_VARIABLE = 0;

/// @title BaseMigrationRatifier
/// @notice Abstract migration ratifier implementing callback discrimination, protocol fee config, and the window,
/// cadence, and rate checks.
/// @dev An entry point resolves the migrating `user`, their `callback`/`callbackData`, the migration `offer`,
/// and the declared `(sourceTenorMarketId, targetTenorMarketId)` route, then calls `_ratify`.
/// @dev If the user holds an opposite-side position in the target Midnight market, Midnight nets the positions, which
/// exits the netted position at the offer price, validated by the rate check.
/// @dev offer.start, offer.expiry, offer.reduceOnly, offer.maxUnits and offer.maxAssets are not ratified, so that
/// any offer satisfying the ratified constraints can settle the migration.
/// Settlement-side guards (receiver pinning, reserved-group namespace) are supplied by the concrete entry point.
/// @dev Renewals do not check source health: a liquidatable source position can still be renewed.
/// @dev Fee config (`setFeeConfig`) is owner-only and takes effect immediately, no timelock; the user's rate check runs
/// after the fee, so it cannot weaken rate protection.
abstract contract BaseMigrationRatifier is Ownable2Step, IMigrationRatifier {
    using TenorMarketIdLib for Market;
    using MarketParamsLib for MarketParams;

    /// @inheritdoc IMigrationRatifier
    IMidnight public immutable MORPHO_MIDNIGHT;

    address public immutable BORROW_MIDNIGHT_RENEWAL_CALLBACK;
    address public immutable BORROW_BLUE_TO_MIDNIGHT_CALLBACK;
    address public immutable LEND_VAULT_TO_MIDNIGHT_CALLBACK;
    address public immutable BORROW_MIDNIGHT_TO_BLUE_CALLBACK;
    address public immutable LEND_MIDNIGHT_TO_VAULT_CALLBACK;
    address public immutable LEND_MIDNIGHT_RENEWAL_CALLBACK;

    /// @inheritdoc IMigrationRatifier
    mapping(address callback => mapping(bytes32 tenorMarketId => FeeConfig)) public feeConfigs;

    constructor(
        address morphoMidnight,
        address borrowMidnightRenewalCallback,
        address borrowBlueToMidnightCallback,
        address lendVaultToMidnightCallback,
        address borrowMidnightToBlueCallback,
        address lendMidnightToVaultCallback,
        address lendMidnightRenewalCallback,
        address _owner
    ) Ownable(_owner) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
        BORROW_MIDNIGHT_RENEWAL_CALLBACK = borrowMidnightRenewalCallback;
        BORROW_BLUE_TO_MIDNIGHT_CALLBACK = borrowBlueToMidnightCallback;
        LEND_VAULT_TO_MIDNIGHT_CALLBACK = lendVaultToMidnightCallback;
        BORROW_MIDNIGHT_TO_BLUE_CALLBACK = borrowMidnightToBlueCallback;
        LEND_MIDNIGHT_TO_VAULT_CALLBACK = lendMidnightToVaultCallback;
        LEND_MIDNIGHT_RENEWAL_CALLBACK = lendMidnightRenewalCallback;
    }

    /// @inheritdoc IMigrationRatifier
    function setFeeConfig(address callback, bytes32 tenorMarketId, uint256 _feeRate, address _feeRecipient)
        external
        onlyOwner
    {
        if (_feeRate > _maxFeeRate(callback)) revert InvalidFeeConfig();
        if (_feeRate > 0 && _feeRecipient == address(0)) revert InvalidFeeConfig();
        FeeConfig storage slot = feeConfigs[callback][tenorMarketId];
        slot.feeRecipient = _feeRecipient;
        slot.feeRate = uint96(_feeRate);
        emit FeeConfigSet(callback, tenorMarketId, _feeRate, _feeRecipient);
    }

    /// @inheritdoc IMigrationRatifier
    function getEffectiveFeeConfig(address callback, bytes32 tenorMarketId)
        public
        view
        returns (FeeConfig memory config)
    {
        config = feeConfigs[callback][tenorMarketId];
        if (config.feeRecipient != address(0)) return config;
        return feeConfigs[callback][bytes32(0)];
    }

    /// @dev Max fee rate for `callback`: MAX_FEE_RATE_FIXED_TO_VARIABLE for Midnight exit flows, MAX_FEE_RATE
    /// otherwise.
    function _maxFeeRate(address callback) internal view returns (uint256) {
        if (callback == BORROW_MIDNIGHT_TO_BLUE_CALLBACK || callback == LEND_MIDNIGHT_TO_VAULT_CALLBACK) {
            return MAX_FEE_RATE_FIXED_TO_VARIABLE;
        }
        return MAX_FEE_RATE;
    }

    /// @dev Runs the migration ratification flow for `user` against their resolved `params`, agnostic to make- or
    /// take-on-behalf. `user` is the party whose position migrates; `taker` is the counterparty filling the offer,
    /// forwarded to the interest rate policy for counterparty-aware pricing; `callback`/`callbackData` are the
    /// migration callback and its data on the user's side of the take; `offer` carries the migration market, tick
    /// (price), and maker. `src`/`tgt` are the user-declared source/target Tenor market ids and must match the
    /// callback-derived markets.
    function _ratify(
        address user,
        address taker,
        address callback,
        bytes memory callbackData,
        Offer memory offer,
        bytes32 src,
        bytes32 tgt,
        UserMigrationParams memory params
    ) internal view {
        if (
            params.interestRatePolicy == address(0) || params.minDuration == 0
                || params.maxDuration < params.minDuration
        ) {
            revert InvalidRenewalParams();
        }

        (
            bytes32 callbackSourceMarketId,
            bytes32 callbackTargetMarketId,
            uint256 sourceMaturity,
            uint256 targetMaturity,
            uint256 callbackFeeRate,
            address callbackFeeRecipient
        ) = _extractCallbackContext(callback, callbackData, offer);

        _validateMarketPair(src, tgt, callbackSourceMarketId, callbackTargetMarketId);

        // The fee config is keyed on the Midnight market: the target for entries and renewals, the source for exits.
        bytes32 feeMarketId = targetMaturity == 0 ? callbackSourceMarketId : callbackTargetMarketId;
        FeeConfig memory expectedFee = getEffectiveFeeConfig(callback, feeMarketId);
        if (callbackFeeRate != expectedFee.feeRate || callbackFeeRecipient != expectedFee.feeRecipient) {
            revert InvalidFeeConfig();
        }

        uint256 renewalPeriodStart = _ratifyWindow(params, sourceMaturity, targetMaturity);
        _ratifyRate(
            user,
            taker,
            callback,
            offer,
            params,
            expectedFee,
            callbackSourceMarketId,
            callbackTargetMarketId,
            renewalPeriodStart,
            sourceMaturity,
            targetMaturity
        );
    }

    /// @dev Validates the declared source/target market pair against the markets derived from the callback, binding
    /// the user's params-key route to the callback's actual markets. Subclasses may override to enforce richer policy
    /// (e.g. a governance-curated set of allowed target markets for a given source).
    function _validateMarketPair(
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        bytes32 callbackSourceMarketId,
        bytes32 callbackTargetMarketId
    ) internal view virtual;

    /// @dev Decodes `callbackData` for the given callback and returns the source and target
    /// market context together with the callback's fee parameters.
    /// @dev A zero maturity marks the non-Midnight side of the migration (Blue or vault).
    function _extractCallbackContext(address callback, bytes memory callbackData, Offer memory offer)
        internal
        view
        returns (
            bytes32 sourceTenorMarketId,
            bytes32 targetTenorMarketId,
            uint256 sourceMaturity,
            uint256 targetMaturity,
            uint256 feeRate,
            address feeRecipient
        )
    {
        if (callback == BORROW_MIDNIGHT_RENEWAL_CALLBACK || callback == LEND_MIDNIGHT_RENEWAL_CALLBACK) {
            IBorrowMidnightRenewalCallback.CallbackData memory decoded =
                abi.decode(callbackData, (IBorrowMidnightRenewalCallback.CallbackData));
            if (decoded.tick != offer.tick) revert InvalidCallbackData();
            return (
                decoded.sourceMarket.toTenorMarketId(),
                offer.market.toTenorMarketId(),
                decoded.sourceMarket.maturity,
                offer.market.maturity,
                decoded.feeRate,
                decoded.feeRecipient
            );
        } else if (callback == BORROW_BLUE_TO_MIDNIGHT_CALLBACK) {
            IBorrowBlueToMidnightCallback.CallbackData memory decoded =
                abi.decode(callbackData, (IBorrowBlueToMidnightCallback.CallbackData));
            if (decoded.tick != offer.tick) revert InvalidCallbackData();
            return (
                Id.unwrap(decoded.sourceMarketParams.id()),
                offer.market.toTenorMarketId(),
                0,
                offer.market.maturity,
                decoded.feeRate,
                decoded.feeRecipient
            );
        } else if (callback == LEND_VAULT_TO_MIDNIGHT_CALLBACK) {
            ILendVaultToMidnightCallback.CallbackData memory decoded =
                abi.decode(callbackData, (ILendVaultToMidnightCallback.CallbackData));
            if (decoded.tick != offer.tick) revert InvalidCallbackData();
            return (
                TenorMarketIdLib.vaultToTenorMarketId(decoded.vault),
                offer.market.toTenorMarketId(),
                0,
                offer.market.maturity,
                decoded.feeRate,
                decoded.feeRecipient
            );
        } else if (callback == BORROW_MIDNIGHT_TO_BLUE_CALLBACK) {
            IBorrowMidnightToBlueCallback.CallbackData memory decoded =
                abi.decode(callbackData, (IBorrowMidnightToBlueCallback.CallbackData));
            return (
                offer.market.toTenorMarketId(),
                Id.unwrap(decoded.targetMarketParams.id()),
                offer.market.maturity,
                0,
                decoded.feeRate,
                decoded.feeRecipient
            );
        } else if (callback == LEND_MIDNIGHT_TO_VAULT_CALLBACK) {
            ILendMidnightToVaultCallback.CallbackData memory decoded =
                abi.decode(callbackData, (ILendMidnightToVaultCallback.CallbackData));
            return (
                offer.market.toTenorMarketId(),
                TenorMarketIdLib.vaultToTenorMarketId(decoded.vault),
                offer.market.maturity,
                0,
                decoded.feeRate,
                decoded.feeRecipient
            );
        } else {
            revert InvalidCallback();
        }
    }

    /// @dev Checks that the take falls within the user's renewal window and that the target maturity is valid.
    /// @dev Variable sources (zero sourceMaturity, Blue or vault) have no maturity to renew around, so the window
    /// opens at the nearest past cadence boundary.
    /// @dev Fixed sources (Midnight) open the window renewalWindow seconds before sourceMaturity.
    /// @dev Returns the renewal period start passed to the interest rate policy.
    function _ratifyWindow(UserMigrationParams memory params, uint256 sourceMaturity, uint256 targetMaturity)
        internal
        view
        returns (uint256 renewalPeriodStart)
    {
        if (sourceMaturity == 0) {
            if (params.renewalCadence == address(0)) revert InvalidRenewalParams();
            renewalPeriodStart = IRenewalCadence(params.renewalCadence).cadencePeriodStart(block.timestamp);
            if (renewalPeriodStart > block.timestamp) revert InvalidRenewalParams();
        } else {
            if (params.renewalWindow > sourceMaturity) revert InvalidRenewalParams();
            renewalPeriodStart = sourceMaturity - params.renewalWindow;
            if (block.timestamp < renewalPeriodStart) revert InvalidRenewalWindow();
        }
        if (targetMaturity > 0) _validateTargetMaturity(sourceMaturity, targetMaturity, params);
    }

    /// @dev Reverts unless `targetMaturity` is after `sourceMaturity`, within the user's duration bounds,
    /// and on a cadence boundary when a cadence is set.
    function _validateTargetMaturity(uint256 sourceMaturity, uint256 targetMaturity, UserMigrationParams memory params)
        internal
        view
    {
        if (targetMaturity <= sourceMaturity) revert InvalidTargetMaturity();
        uint256 minTarget = block.timestamp + params.minDuration;
        uint256 maxTarget = block.timestamp + params.maxDuration;
        if (targetMaturity < minTarget || targetMaturity > maxTarget) {
            revert InvalidTargetMaturity();
        }
        if (
            params.renewalCadence != address(0)
                && IRenewalCadence(params.renewalCadence).cadencePeriodStart(targetMaturity) != targetMaturity
        ) revert InvalidTargetMaturity();
    }

    /// @dev Checks the offer price against the policy rate and user's rate limit, net of settlement and protocol fees.
    /// The settlement fee is borne by the taker, so it is netted only when `offer.maker != user`; there is none under
    /// make-on-behalf. The check is continuous, while Midnight's integer settlement rounds against the taker.
    function _ratifyRate(
        address user,
        address taker,
        address callback,
        Offer memory offer,
        UserMigrationParams memory params,
        FeeConfig memory feeConfig,
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        uint256 renewalPeriodStart,
        uint256 sourceMaturity,
        uint256 targetMaturity
    ) internal view {
        uint256 duration = _computeDuration(callback, sourceMaturity, targetMaturity);
        bool userIsBuy = _userIsBuy(callback);
        uint256 policyRate = IInterestRatePolicy(params.interestRatePolicy)
            .getRate(
                sourceTenorMarketId,
                targetTenorMarketId,
                renewalPeriodStart,
                user,
                taker,
                sourceMaturity,
                targetMaturity,
                userIsBuy
            );
        uint256 tickPrice = TickLib.tickToPrice(offer.tick);
        bytes32 marketId = IdLib.toId(offer.market);
        uint256 settlementFee = offer.maker == user
            ? 0
            : MORPHO_MIDNIGHT.settlementFee(marketId, UtilsLib.zeroFloorSub(offer.market.maturity, block.timestamp));
        uint256 effPrice = userIsBuy
            ? RouterLib.netBuyerPrice(tickPrice, settlementFee, feeConfig.feeRate)
            : RouterLib.netSellerPrice(tickPrice, settlementFee, feeConfig.feeRate);
        uint256 effUnitsPerWad = _effectiveUnitsPerWad(callback, marketId, offer);
        if (!PriceLib.satisfiesRateLimit(
                userIsBuy, effUnitsPerWad, effPrice, params.limitRatePerSecond, policyRate, duration
            )) revert InvalidOfferRate();
    }

    /// @dev Returns the interest accrual duration used by the rate check for the given callback, by flow:
    /// - Renewals (Midnight to Midnight): `targetMaturity - max(block.timestamp, sourceMaturity)`. Prices only the
    ///   extension period; the source already pays interest until sourceMaturity.
    /// - Entries (Blue or vault to Midnight): `targetMaturity - block.timestamp`. The full term of the new
    ///   fixed-rate position; `targetMaturity > block.timestamp` is already enforced in `_validateTargetMaturity`.
    /// - Exits (Midnight to Blue or vault): `sourceMaturity - block.timestamp`. The remaining fixed term given up
    ///   (zero at or after maturity).
    /// @dev When source funds become withdrawable before sourceMaturity (e.g. early repayments), a renewal relocks them
    /// until targetMaturity but only pays from sourceMaturity, leaving the lender's realized rate short of the ratified
    /// floor.
    function _computeDuration(address callback, uint256 sourceMaturity, uint256 targetMaturity)
        internal
        view
        returns (uint256)
    {
        if (callback == BORROW_MIDNIGHT_RENEWAL_CALLBACK || callback == LEND_MIDNIGHT_RENEWAL_CALLBACK) {
            uint256 effectiveStart = block.timestamp > sourceMaturity ? block.timestamp : sourceMaturity;
            return targetMaturity - effectiveStart;
        } else if (callback == BORROW_BLUE_TO_MIDNIGHT_CALLBACK || callback == LEND_VAULT_TO_MIDNIGHT_CALLBACK) {
            return targetMaturity - block.timestamp;
        } else {
            return UtilsLib.zeroFloorSub(sourceMaturity, block.timestamp);
        }
    }

    /// @dev Returns true when the user is on the buy side of the Midnight take for the given callback.
    /// @dev The user buys credit on Midnight when entering or renewing a lend position, or exiting a borrow
    /// position; the user sells when entering or renewing a borrow position, or exiting a lend position.
    function _userIsBuy(address callback) internal view returns (bool) {
        return callback == LEND_VAULT_TO_MIDNIGHT_CALLBACK || callback == BORROW_MIDNIGHT_TO_BLUE_CALLBACK
            || callback == LEND_MIDNIGHT_RENEWAL_CALLBACK;
    }

    /// @dev Returns the per-WAD effective face value at maturity after Midnight's continuous fee on
    /// Midnight-target lend flows, and WAD otherwise.
    /// @dev Matches Midnight's fee model: the lifetime fee is fixed at take time as continuousFee * timeToMaturity
    /// and amortized linearly to maturity, so the lender nets units * (WAD - continuousFee * timeToMaturity) / WAD.
    /// @dev Conservative assumption: the fee is charged on the entire fill, though Midnight applies it only to the
    /// credit increase net of the buyer's pre-existing debt (zeroFloorSub(units, debt)). Overstating the fee
    /// understates the effective face, so the check can only tighten: a passing offer always honors the ratified
    /// rate (strictly better when the buyer holds existing debt), and the only failure mode is a conservative
    /// rejection, never a realized rate below ratified.
    function _effectiveUnitsPerWad(address callback, bytes32 marketId, Offer memory offer)
        internal
        view
        returns (uint256)
    {
        if (callback != LEND_VAULT_TO_MIDNIGHT_CALLBACK && callback != LEND_MIDNIGHT_RENEWAL_CALLBACK) return WAD;
        uint256 continuousFee = MORPHO_MIDNIGHT.continuousFee(marketId);
        if (continuousFee == 0) return WAD;
        uint256 timeToMaturity = UtilsLib.zeroFloorSub(offer.market.maturity, block.timestamp);
        uint256 fee = continuousFee * timeToMaturity;
        if (fee >= WAD) revert InvalidTargetMaturity();
        return WAD - fee;
    }
}
