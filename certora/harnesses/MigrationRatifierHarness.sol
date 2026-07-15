// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MigrationRatifier} from "@src/ratifiers/MigrationRatifier.sol";
import {IMigrationRatifier} from "@src/ratifiers/interfaces/IMigrationRatifier.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {PriceLib} from "@src/libraries/PriceLib.sol";
import {RouterLib} from "@src/libraries/RouterLib.sol";
import {IBorrowMidnightRenewalCallback} from "@callbacks/interfaces/IBorrowMidnightRenewalCallback.sol";
import {IBorrowBlueToMidnightCallback} from "@callbacks/interfaces/IBorrowBlueToMidnightCallback.sol";
import {ILendVaultToMidnightCallback} from "@callbacks/interfaces/ILendVaultToMidnightCallback.sol";

// Harness for the single-entry ratifier specs: rules drive the real isRatified (make-on-behalf) and read the
// decoded values back from the same offer/ratifierData via the parsers below. ratifyRateHarness is exposed for the
// rate-gate monotonicity lattice.
contract MigrationRatifierHarness is MigrationRatifier {
    constructor(
        address morphoMidnight,
        address borrowMidnightRenewalCallback,
        address borrowBlueToMidnightCallback,
        address lendVaultToMidnightCallback,
        address borrowMidnightToBlueCallback,
        address lendMidnightToVaultCallback,
        address lendMidnightRenewalCallback,
        address owner_
    )
        MigrationRatifier(
            morphoMidnight,
            borrowMidnightRenewalCallback,
            borrowBlueToMidnightCallback,
            lendVaultToMidnightCallback,
            borrowMidnightToBlueCallback,
            lendMidnightToVaultCallback,
            lendMidnightRenewalCallback,
            owner_
        )
    {}

    // === Parsers (decode the same bytes/offer the flow decodes) ===

    // Callback context the flow derives from the offer (reverts on tick mismatch / unknown callback). Mirrors the
    // real isRatified call _extractCallbackContext(offer.callback, offer.callbackData, offer); takes the whole offer
    // so CVL never has to pass the dynamic offer.callbackData member directly.
    function parseCallbackContextOfHarness(Offer calldata offer)
        external
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
        return _extractCallbackContext(offer.callback, offer.callbackData, offer);
    }

    // ratifierData = abi.encode(src, tgt); reverts if shorter than 64 bytes — trailing bytes are tolerated here. The exact-64 requirement is isRatified's own length guard (verified by RTF-RV-01).
    function parseRatifierDataHarness(bytes calldata ratifierData) external pure returns (bytes32 src, bytes32 tgt) {
        return abi.decode(ratifierData, (bytes32, bytes32));
    }

    // Raw cd.tick (no tick-equality check) from the offer's own callbackData schema, for the tick-mismatch rule.
    function parseRawTickOfHarness(Offer calldata offer) external view returns (uint256) {
        if (offer.callback == BORROW_BLUE_TO_MIDNIGHT_CALLBACK) {
            return abi.decode(offer.callbackData, (IBorrowBlueToMidnightCallback.CallbackData)).tick;
        }
        if (offer.callback == LEND_VAULT_TO_MIDNIGHT_CALLBACK) {
            return abi.decode(offer.callbackData, (ILendVaultToMidnightCallback.CallbackData)).tick;
        }
        return abi.decode(offer.callbackData, (IBorrowMidnightRenewalCallback.CallbackData)).tick;
    }

    // === Pure extractors for assert hypotheses ===

    // True iff `group` carries the reserved migration-group namespace header in its top 6 bytes (InvalidGroup guard).
    function groupMatchesNamespaceHarness(bytes32 group) external pure returns (bool) {
        return (group & MIGRATION_GROUP_HEADER_MASK) == MIGRATION_GROUP_HEADER;
    }

    // tickToPrice primitive (monotonicity hypotheses).
    function tickPriceOfHarness(uint256 tick) external pure returns (uint256) {
        return TickLib.tickToPrice(tick);
    }

    // Midnight market-id key (continuous-/settlement-fee slot).
    function midnightMarketIdOfHarness(Offer calldata offer) external view returns (bytes32) {
        return IdLib.toId(offer.market);
    }

    // Buy-side flag the rate gate derives from the callback (direction of the Midnight take).
    function userIsBuyOfHarness(address callback) external view returns (bool) {
        return _userIsBuy(callback);
    }

    // === Rate-gate exposer (rate-gate monotonicity lattice only) ===
    // The RATE-1/2 + CB-RATE-1/2 + ORCH-4 monotonicity rules (highlevel.spec) drive this exposer instead of the
    // full isRatified: a two-call differential through the whole flow does not converge locally, so the
    // rate gate is isolated here. Thin zero-logic passthrough to _ratifyRate.
    function ratifyRateHarness(
        address user,
        address taker,
        address callback,
        Offer calldata offer,
        IMigrationRatifier.UserMigrationParams memory params,
        IMigrationRatifier.FeeConfig memory feeConfig,
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        uint256 renewalPeriodStart,
        uint256 sourceMaturity,
        uint256 targetMaturity
    ) external view {
        _ratifyRate(
            user,
            taker,
            callback,
            offer,
            params,
            feeConfig,
            sourceTenorMarketId,
            targetTenorMarketId,
            renewalPeriodStart,
            sourceMaturity,
            targetMaturity
        );
    }

    // === PriceLib exposers (verify the real rate-limit math the gate runs — PRICE-1..4) ===
    function computePriceOfHarness(bool isBuy, uint256 ratePerSecond, uint256 durationSeconds)
        external pure returns (uint256)
    {
        return PriceLib.computePrice(isBuy, ratePerSecond, durationSeconds);
    }

    function computeEffectiveRateOfHarness(bool isBuy, uint256 policyRate, uint256 limitRate)
        external pure returns (uint256)
    {
        return PriceLib.computeEffectiveRate(isBuy, policyRate, limitRate);
    }

    function satisfiesRateLimitOfHarness(
        bool isBuy,
        uint256 units,
        uint256 assets,
        uint256 limitRate,
        uint256 policyRate,
        uint256 duration
    ) external pure returns (bool) {
        return PriceLib.satisfiesRateLimit(isBuy, units, assets, limitRate, policyRate, duration);
    }

    // === Rate-check helper exposers (direct characterization of the per-callback helpers) ===

    // Max fee rate cap per callback: 0 (MAX_FEE_RATE_FIXED_TO_VARIABLE) on the V2->V1 exits, MAX_FEE_RATE otherwise.
    // (The gate uses feeConfig.feeRate directly, capped at config time.)
    function maxFeeRateOfHarness(address callback) external view returns (uint256) {
        return _maxFeeRate(callback);
    }

    // Interest-accrual duration the rate check uses, per callback (ORCH-13 helper).
    function computeDurationOfHarness(address callback, uint256 sourceMaturity, uint256 targetMaturity)
        external view returns (uint256)
    {
        return _computeDuration(callback, sourceMaturity, targetMaturity);
    }

    // === Effective-price exposers (rate-gate decomposition: net price the seller/buyer faces after both fees) ===

    // Seller-as-taker net per-unit price (the borrower-enter effPrice the gate runs): min(midnight, tenor).
    function netSellerPriceOfHarness(uint256 offerPrice, uint256 settlementFee, uint256 feeRate)
        external pure returns (uint256)
    {
        return RouterLib.netSellerPrice(offerPrice, settlementFee, feeRate);
    }

    // Buyer-as-taker net per-unit price (the lender-enter effPrice the gate runs): max(midnight, tenor).
    function netBuyerPriceOfHarness(uint256 offerPrice, uint256 settlementFee, uint256 feeRate)
        external pure returns (uint256)
    {
        return RouterLib.netBuyerPrice(offerPrice, settlementFee, feeRate);
    }

}
