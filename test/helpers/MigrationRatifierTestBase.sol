// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {BoundaryTestBase} from "../unit/boundary/BoundaryTestBase.sol";
import {IMigrationRatifier} from "../../src/ratifiers/interfaces/IMigrationRatifier.sol";
import {MigrationRatifier} from "../../src/ratifiers/MigrationRatifier.sol";
import {IBorrowMidnightRenewalCallback} from "@callbacks/interfaces/IBorrowMidnightRenewalCallback.sol";
import {IBorrowBlueToMidnightCallback} from "@callbacks/interfaces/IBorrowBlueToMidnightCallback.sol";
import {ILendVaultToMidnightCallback} from "@callbacks/interfaces/ILendVaultToMidnightCallback.sol";
import {IBorrowMidnightToBlueCallback} from "@callbacks/interfaces/IBorrowMidnightToBlueCallback.sol";
import {ILendMidnightToVaultCallback} from "@callbacks/interfaces/ILendMidnightToVaultCallback.sol";
import {ILendMidnightRenewalCallback} from "@callbacks/interfaces/ILendMidnightRenewalCallback.sol";
import {Market, Offer, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {Id, MarketParams} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {MockRenewalCadence} from "./MockRenewalCadence.sol";
import {StaticRatePolicy} from "../../src/ratifiers/policies/StaticRatePolicy.sol";

/// @title MigrationRatifierTestBase
/// @notice Shared fixture for migration-ratifier integration tests in the maker-on-behalf model: the migrating user
///         is the offer MAKER, the offer's `ratifier` is `MigrationRatifier`, and the migration callback is the
///         MAKER's `offer.callback`. A counterparty takes the offer via `midnight.take`, which invokes the ratifier's
///         `isRatified`. The user opts in by authorizing the ratifier on Midnight and storing per-tuple params.
abstract contract MigrationRatifierTestBase is BoundaryTestBase {
    using TenorMarketIdLib for Market;
    using TenorMarketIdLib for address;
    using TenorMarketIdLib for bytes32;
    using MarketParamsLib for MarketParams;

    /* ═══════ Additional State ═══════ */

    MigrationRatifier internal defaultRatifier;
    MockRenewalCadence internal mockCadence;
    StaticRatePolicy internal permissiveLendPolicy;
    address internal feeRecipient;
    address internal keeper;
    uint256 internal keeperSK;

    /* ═══════ Default Test Params ═══════ */

    // Prices ~0.5398 (price-equivalent to the old-grid tick 2940; re-derived after the MAX_TICK 5820->6744 /
    // PRICE_ROUNDING_STEP 1e12->1e11 grid change so the rate/slippage harness keeps its ~0.53 reference price).
    // Must stay a multiple of DEFAULT_TICK_SPACING (4) so offers are tick-accessible.
    uint16 internal constant DEFAULT_TICK = 3404;
    uint256 internal constant DEFAULT_FEE_RATE = 0.01e18;
    uint128 internal constant DEFAULT_BORROW_AMOUNT = 1000e18;
    uint128 internal constant DEFAULT_COLLATERAL_AMOUNT = 5000e18;
    uint128 internal constant DEFAULT_LEND_AMOUNT = 1000e18;

    /* ═══════ setUp ═══════ */

    function setUp() public virtual override {
        super.setUp();

        feeRecipient = makeAddr("feeRecipient");
        (keeper, keeperSK) = makeAddrAndKey("keeper");

        mockCadence = new MockRenewalCadence();

        {
            uint128[] memory lendRates = new uint128[](1);
            lendRates[0] = 0;
            uint128[] memory lendDurations = new uint128[](1);
            lendDurations[0] = 0;
            permissiveLendPolicy = new StaticRatePolicy(lendRates, lendDurations);
        }

        // Deploy the canonical migration ratifier (owns fee config).
        defaultRatifier = new MigrationRatifier(
            address(midnight),
            address(borrowMidnightRenewalCallback),
            address(borrowBlueToMidnightCallback),
            address(lendVaultToMidnightCallback),
            address(borrowMidnightToBlueCallback),
            address(lendMidnightToVaultCallback),
            address(lendMidnightRenewalCallback),
            address(this) // owner
        );

        // Action-level defaults (tenorMarketId == bytes32(0)) on the ratifier.
        defaultRatifier.setFeeConfig(address(borrowMidnightRenewalCallback), bytes32(0), DEFAULT_FEE_RATE, feeRecipient);
        defaultRatifier.setFeeConfig(address(lendMidnightRenewalCallback), bytes32(0), DEFAULT_FEE_RATE, feeRecipient);
        defaultRatifier.setFeeConfig(address(borrowBlueToMidnightCallback), bytes32(0), DEFAULT_FEE_RATE, feeRecipient);
        defaultRatifier.setFeeConfig(address(lendVaultToMidnightCallback), bytes32(0), DEFAULT_FEE_RATE, feeRecipient);

        // Token approvals.
        vm.startPrank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);
        collateralToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Each user authorizes the migration callbacks (which act on their position) on Midnight.
        vm.startPrank(borrower);
        midnight.setIsAuthorized(address(borrowMidnightRenewalCallback), true, borrower);
        midnight.setIsAuthorized(address(lendMidnightRenewalCallback), true, borrower);
        midnight.setIsAuthorized(address(borrowBlueToMidnightCallback), true, borrower);
        midnight.setIsAuthorized(address(lendVaultToMidnightCallback), true, borrower);
        midnight.setIsAuthorized(address(borrowMidnightToBlueCallback), true, borrower);
        midnight.setIsAuthorized(address(lendMidnightToVaultCallback), true, borrower);
        vm.stopPrank();

        vm.startPrank(lender);
        midnight.setIsAuthorized(address(borrowMidnightRenewalCallback), true, lender);
        midnight.setIsAuthorized(address(lendMidnightRenewalCallback), true, lender);
        midnight.setIsAuthorized(address(borrowBlueToMidnightCallback), true, lender);
        midnight.setIsAuthorized(address(lendVaultToMidnightCallback), true, lender);
        midnight.setIsAuthorized(address(borrowMidnightToBlueCallback), true, lender);
        midnight.setIsAuthorized(address(lendMidnightToVaultCallback), true, lender);
        vm.stopPrank();

        vm.startPrank(borrower);
        morphoBlue.setAuthorization(address(borrowBlueToMidnightCallback), true);
        morphoBlue.setAuthorization(address(borrowMidnightToBlueCallback), true);
        vm.stopPrank();

        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ═══════ Market Helpers ═══════ */

    /// @dev A single-collateral target market cloned from `sourceMarket` with the given maturity. Target tenor market
    ///      id excludes maturity (ID-1), so params keyed by the target's tenor id apply to any maturity-clone.
    function _cloneTarget(uint256 maturity) internal view returns (Market memory) {
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = sourceMarket.collateralParams[0];
        return Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: maturity,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    /* ═══════ Param Helpers ═══════ */

    function _defaultBorrowParams() internal view returns (IMigrationRatifier.UserMigrationParams memory) {
        return IMigrationRatifier.UserMigrationParams({
            interestRatePolicy: address(permissiveRatePolicy),
            renewalWindow: uint32(7 days),
            minDuration: uint32(7 days),
            maxDuration: uint32(365 days),
            renewalCadence: address(0),
            limitRatePerSecond: type(uint40).max
        });
    }

    function _defaultLendParams() internal view returns (IMigrationRatifier.UserMigrationParams memory) {
        return IMigrationRatifier.UserMigrationParams({
            interestRatePolicy: address(permissiveLendPolicy),
            renewalWindow: uint32(7 days),
            minDuration: uint32(7 days),
            maxDuration: uint32(365 days),
            renewalCadence: address(0),
            limitRatePerSecond: 0
        });
    }

    function _defaultMidnightParams() internal view returns (IMigrationRatifier.UserMigrationParams memory) {
        return _defaultBorrowParams();
    }

    function _defaultBlueToMidnightParams() internal view returns (IMigrationRatifier.UserMigrationParams memory) {
        IMigrationRatifier.UserMigrationParams memory params = _defaultBorrowParams();
        params.renewalCadence = address(mockCadence);
        return params;
    }

    function _defaultVaultToMidnightLendParams() internal view returns (IMigrationRatifier.UserMigrationParams memory) {
        IMigrationRatifier.UserMigrationParams memory params = _defaultLendParams();
        params.renewalCadence = address(mockCadence);
        return params;
    }

    /// @notice Writes the user's params to `defaultRatifier` AND authorizes the ratifier on Midnight for the user
    ///         (so Midnight's `isAuthorized[maker][ratifier]` gate passes). Idempotent.
    function _setParams(
        address onBehalf,
        address callback,
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        IMigrationRatifier.UserMigrationParams memory params
    ) internal {
        vm.startPrank(onBehalf);
        defaultRatifier.setParams(onBehalf, callback, sourceTenorMarketId, targetTenorMarketId, params);
        midnight.setIsAuthorized(address(defaultRatifier), true, onBehalf);
        vm.stopPrank();
    }

    /* ═══════ Migration Offer Builder ═══════ */

    /// @notice Builds the user's migration offer (user = maker). `buy` is the user's Midnight side. The receiver is
    ///         pinned: address(0) on buys, the callback on sells.
    function _migrationOffer(
        address user,
        Market memory targetObl,
        bool buy,
        uint16 tick,
        address callback,
        bytes memory callbackData
    ) internal view returns (Offer memory) {
        return Offer({
            market: targetObl,
            buy: buy,
            maker: user,
            maxUnits: type(uint128).max,
            start: block.timestamp,
            expiry: block.timestamp + 365 days,
            tick: tick,
            group: _migrationGroup(),
            callback: callback,
            callbackData: callbackData,
            receiverIfMakerIsSeller: buy ? address(0) : callback,
            ratifier: address(defaultRatifier),
            reduceOnly: false,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    /// @notice Takes the user's migration `offer` as `counterparty`. `ratifierData = abi.encode(src, tgt)`.
    function _takeMigration(Offer memory offer, bytes32 src, bytes32 tgt, address counterparty, uint256 takeUnits)
        internal
        returns (uint256 buyerAssets, uint256 sellerAssets, uint256 units)
    {
        // counterparty takes the opposite of the maker: buyer if maker sells, seller if maker buys.
        address receiverIfTakerIsSeller = offer.buy ? counterparty : address(0);
        vm.prank(counterparty);
        (buyerAssets, sellerAssets) = midnight.take(
            offer, abi.encode(src, tgt), takeUnits, counterparty, receiverIfTakerIsSeller, address(0), ""
        );
        units = takeUnits;
    }

    /* ═══════ CallbackData Builders ═══════ */

    function _encodeBorrowMidnightRenewalCallbackData(Market memory sourceMarket, uint256 tick)
        internal
        view
        returns (bytes memory)
    {
        IMigrationRatifier.FeeConfig memory fee = defaultRatifier.getEffectiveFeeConfig(
            address(borrowMidnightRenewalCallback), sourceMarket.toTenorMarketId()
        );
        return abi.encode(
            IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: fee.feeRate, feeRecipient: fee.feeRecipient, tick: tick
            })
        );
    }

    function _encodeBorrowBlueToMidnightCallbackData(
        bytes32 sourceBlueMarketId,
        bytes32 targetTenorMarketId,
        uint256 tick
    ) internal view returns (bytes memory) {
        IMigrationRatifier.FeeConfig memory fee = defaultRatifier.getEffectiveFeeConfig(
            address(borrowBlueToMidnightCallback), targetTenorMarketId
        );
        MarketParams memory srcParams = morphoBlue.idToMarketParams(Id.wrap(sourceBlueMarketId));
        return abi.encode(
            IBorrowBlueToMidnightCallback.CallbackData({
                sourceMarketParams: srcParams, feeRate: fee.feeRate, feeRecipient: fee.feeRecipient, tick: tick
            })
        );
    }

    function _encodeLendVaultToMidnightCallbackData(address sourceVault, bytes32 targetTenorMarketId, uint256 tick)
        internal
        view
        returns (bytes memory)
    {
        IMigrationRatifier.FeeConfig memory fee =
            defaultRatifier.getEffectiveFeeConfig(address(lendVaultToMidnightCallback), targetTenorMarketId);
        return abi.encode(
            ILendVaultToMidnightCallback.CallbackData({
                vault: sourceVault,
                feeRate: fee.feeRate,
                feeRecipient: fee.feeRecipient,
                tick: tick,
                morphoBlueMarketId: bytes32(0)
            })
        );
    }

    function _encodeBorrowMidnightToBlueCallbackData(bytes32 sourceTenorMarketId, bytes32 targetBlueMarketId)
        internal
        view
        returns (bytes memory)
    {
        IMigrationRatifier.FeeConfig memory fee =
            defaultRatifier.getEffectiveFeeConfig(address(borrowMidnightToBlueCallback), sourceTenorMarketId);
        MarketParams memory tgtParams = morphoBlue.idToMarketParams(Id.wrap(targetBlueMarketId));
        return abi.encode(
            IBorrowMidnightToBlueCallback.CallbackData({
                targetMarketParams: tgtParams, feeRate: fee.feeRate, feeRecipient: fee.feeRecipient
            })
        );
    }

    function _encodeLendMidnightToVaultCallbackData(bytes32 sourceTenorMarketId, address targetVault)
        internal
        view
        returns (bytes memory)
    {
        IMigrationRatifier.FeeConfig memory fee =
            defaultRatifier.getEffectiveFeeConfig(address(lendMidnightToVaultCallback), sourceTenorMarketId);
        return abi.encode(
            ILendMidnightToVaultCallback.CallbackData({
                vault: targetVault, feeRate: fee.feeRate, feeRecipient: fee.feeRecipient
            })
        );
    }

    function _encodeLendMidnightRenewalCallbackData(Market memory sourceMarket, uint256 tick)
        internal
        view
        returns (bytes memory)
    {
        IMigrationRatifier.FeeConfig memory fee = defaultRatifier.getEffectiveFeeConfig(
            address(lendMidnightRenewalCallback), sourceMarket.toTenorMarketId()
        );
        return abi.encode(
            ILendMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: fee.feeRate, feeRecipient: fee.feeRecipient, tick: tick
            })
        );
    }

    /* ═══════ Per-flow take wrappers (maker-on-behalf) ═══════ */

    /// @dev Borrow renewal: user is the maker-seller (buy=false); `counterparty` is the buyer (supplies loan).
    function _takeBorrowMidnightRenewal(
        address user,
        address counterparty,
        uint256 takeUnits,
        Market memory sourceMarket,
        Market memory targetObl,
        uint16 tick
    ) internal returns (uint256 buyerAssets, uint256 sellerAssets, uint256 units) {
        bytes memory cbd = _encodeBorrowMidnightRenewalCallbackData(sourceMarket, tick);
        Offer memory offer = _migrationOffer(user, targetObl, false, tick, address(borrowMidnightRenewalCallback), cbd);
        return
            _takeMigration(offer, sourceMarket.toTenorMarketId(), targetObl.toTenorMarketId(), counterparty, takeUnits);
    }

    /// @dev Lend renewal: user is the maker-buyer (buy=true); `counterparty` is the seller.
    function _takeLendMidnightRenewal(
        address user,
        address counterparty,
        uint256 takeUnits,
        Market memory sourceMarket,
        Market memory targetObl,
        uint16 tick
    ) internal returns (uint256 buyerAssets, uint256 sellerAssets, uint256 units) {
        bytes memory cbd = _encodeLendMidnightRenewalCallbackData(sourceMarket, tick);
        Offer memory offer = _migrationOffer(user, targetObl, true, tick, address(lendMidnightRenewalCallback), cbd);
        return
            _takeMigration(offer, sourceMarket.toTenorMarketId(), targetObl.toTenorMarketId(), counterparty, takeUnits);
    }

    /// @dev Blue→Midnight borrow entry: user is the maker-seller (buy=false); `counterparty` is the buyer.
    function _takeBorrowBlueToMidnight(
        address user,
        address counterparty,
        bytes32 sourceBlueMarketId,
        uint256 takeUnits,
        Market memory targetObl,
        uint16 tick
    ) internal returns (uint256 buyerAssets, uint256 sellerAssets, uint256 units) {
        bytes32 tgt = targetObl.toTenorMarketId();
        bytes memory cbd = _encodeBorrowBlueToMidnightCallbackData(sourceBlueMarketId, tgt, tick);
        Offer memory offer = _migrationOffer(user, targetObl, false, tick, address(borrowBlueToMidnightCallback), cbd);
        return _takeMigration(offer, sourceBlueMarketId, tgt, counterparty, takeUnits);
    }

    /// @dev Vault→Midnight lend entry: user is the maker-buyer (buy=true); `counterparty` is the seller.
    function _takeLendVaultToMidnight(
        address user,
        address counterparty,
        bytes32 sourceTenorMarketId,
        uint256 takeUnits,
        Market memory targetObl,
        uint16 tick
    ) internal returns (uint256 buyerAssets, uint256 sellerAssets, uint256 units) {
        bytes32 tgt = targetObl.toTenorMarketId();
        address sourceVault = sourceTenorMarketId.tenorMarketIdToVault();
        bytes memory cbd = _encodeLendVaultToMidnightCallbackData(sourceVault, tgt, tick);
        Offer memory offer = _migrationOffer(user, targetObl, true, tick, address(lendVaultToMidnightCallback), cbd);
        return _takeMigration(offer, sourceTenorMarketId, tgt, counterparty, takeUnits);
    }

    /// @dev Midnight→Blue borrow exit: user is the maker-buyer (buy=true); `counterparty` is the seller.
    function _takeBorrowMidnightToBlue(
        address user,
        address counterparty,
        bytes32 targetBlueMarketId,
        uint256 takeUnits,
        Market memory sourceObl,
        uint16 tick
    ) internal returns (uint256 buyerAssets, uint256 sellerAssets, uint256 units) {
        bytes32 src = sourceObl.toTenorMarketId();
        bytes memory cbd = _encodeBorrowMidnightToBlueCallbackData(src, targetBlueMarketId);
        Offer memory offer = _migrationOffer(user, sourceObl, true, tick, address(borrowMidnightToBlueCallback), cbd);
        return _takeMigration(offer, src, targetBlueMarketId, counterparty, takeUnits);
    }

    /// @dev Midnight→Vault lend exit: user is the maker-seller (buy=false); `counterparty` is the buyer.
    function _takeLendMidnightToVault(
        address user,
        address counterparty,
        bytes32 targetTenorMarketId,
        uint256 takeUnits,
        Market memory sourceObl,
        uint16 tick
    ) internal returns (uint256 buyerAssets, uint256 sellerAssets, uint256 units) {
        bytes32 src = sourceObl.toTenorMarketId();
        address targetVault = targetTenorMarketId.tenorMarketIdToVault();
        bytes memory cbd = _encodeLendMidnightToVaultCallbackData(src, targetVault);
        Offer memory offer = _migrationOffer(user, sourceObl, false, tick, address(lendMidnightToVaultCallback), cbd);
        return _takeMigration(offer, src, targetTenorMarketId, counterparty, takeUnits);
    }

    /* ═══════ Time Helpers ═══════ */

    function _warpToRenewalWindow(Market memory sourceObl) internal {
        vm.warp(sourceObl.maturity - 1 days);
    }

    /* ═══════ Utility ═══════ */

    function _freshGroup() internal view returns (bytes32) {
        return keccak256(abi.encodePacked("orch-test", block.timestamp, gasleft()));
    }

    /// @dev A fresh group stamped with the reserved migration-group header, as required of every maker-on-behalf
    ///      migration offer.
    function _migrationGroup() internal view returns (bytes32) {
        bytes32 mask = defaultRatifier.MIGRATION_GROUP_HEADER_MASK();
        return (_freshGroup() & ~mask) | defaultRatifier.MIGRATION_GROUP_HEADER();
    }
}
