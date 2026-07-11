// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {MigrationRatifierTestBase} from "../helpers/MigrationRatifierTestBase.sol";
import {TenorRouter, ExecuteParams, FillAxis, Action, MidnightTakeData} from "../../src/router/TenorRouter.sol";
import {RouterLib} from "../../src/libraries/RouterLib.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {MockTenorRouter} from "../helpers/mocks/MockTenorRouter.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";

/// @title MixedExecutionDCOFIntegration
/// @notice Pins DCOF behavior for the mixed-execution borrow flow shipped in
///         tenor-app. Two patterns are locked:
///
///         (A) Single-side, multi-leg take: borrower as taker sweeps multiple
///             lender BUY offers in one TenorRouter batch, with DCOF as
///             `takerCallback` on every leg. Per-leg pulls auto-pro-rata via
///             `supplyAmount = amounts[i] * legSellerAssets / offerSellerAssets`.
///
///         (B) Cross-side via shared `consumeGroup`: borrower posts a limit
///             SELL offer carrying DCOF as `offer.callback`, then takes lender
///             BUY offers crediting the same group. The `consumed[maker][group]`
///             counter caps total cumulative fill at the borrower's
///             commitment, bounding total collateral pulled at
///             `collateralAmount`.
///
/// @dev Sides differ on `maxBorrowCapacityUsage`: take side ships `0` (no per-leg gate — the
///      borrower simulates pre-tx and pads `amounts[]` for drift); limit side
///      carries the resolved maxBorrowCapacityUsage as a safety gate against state drift
///      between sign-time and a stranger taking the offer later.
///
/// @dev Implicitly locked invariants from `MidnightSupplyCollateralCallback`:
///      - `msg.sender == MORPHO_MIDNIGHT` (callback line 39): every test
///        invokes the callback through `midnight.take`, never directly.
///      - `safeTransferFrom(token, seller, callback)` then `supplyCollateral`
///        leaves zero token residue in the callback (asserted in test 1).
contract MixedExecutionDCOFIntegrationTest is MigrationRatifierTestBase {
    MidnightSupplyCollateralCallback internal dcofCallback;
    TenorRouter internal router;

    /// @dev 0.945 lltv on the target market; cap debt at 90% of borrowing capacity for comfortable headroom.
    uint256 internal constant TARGET_MAX_BORROW_CAPACITY_USAGE = 0.9e18;

    /// @dev Deterministic counter shadowing the gas-keyed `_freshGroup` in
    ///      `MigrationRatifierTestBase` so traces are reproducible.
    uint256 internal _groupCounter;

    function setUp() public override {
        super.setUp();

        dcofCallback = new MidnightSupplyCollateralCallback(address(midnight));
        router = new MockTenorRouter(address(midnight));

        // Borrower wiring: approve DCOF for collateral pulls, authorize on
        // Midnight, fund collateral. (Lender wiring comes from base setUp.)
        collateralToken.mint(borrower, type(uint128).max);
        vm.startPrank(borrower);
        collateralToken.approve(address(dcofCallback), type(uint256).max);
        midnight.setIsAuthorized(address(dcofCallback), true, borrower);
        midnight.setIsAuthorized(address(router), true, borrower);
        vm.stopPrank();

        // `_dcofData` builds `expectedSellerAssets = units * tickPrice / WAD`,
        // which only matches Midnight's actual `sellerAssets` math when the
        // settlement fee is zero. Lock that invariant here so a future fixture
        // change doesn't silently break the assertions.
        require(midnight.settlementFee(targetMarketId, 0) == 0, "settlement fee must be zero");
    }

    /* ═══════════════════════════════════════════════════════════════
       Helpers
       ═══════════════════════════════════════════════════════════════ */

    function _nextGroup() internal returns (bytes32) {
        unchecked {
            _groupCounter++;
        }
        return keccak256(abi.encodePacked("dcof-mix", _groupCounter));
    }

    function _buyOffer(uint16 tick) internal returns (Offer memory, Signature memory, bytes32) {
        return _buyOfferFull(tick, _nextGroup(), type(uint128).max);
    }

    function _buyOfferFull(uint16 tick, bytes32 group, uint128 maxUnits)
        internal
        view
        returns (Offer memory, Signature memory, bytes32)
    {
        Offer memory offer = Offer({
            market: targetMarket,
            buy: true, // lender (maker) buys debt = lends; taker (borrower) sells = borrows
            maker: lender,
            maxUnits: maxUnits,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory sig = _signOffer(offer, lenderSK);
        bytes32 root = HashLib.hashOffer(offer);
        return (offer, sig, root);
    }

    /// @dev Borrower's limit SELL offer, capped on `maxSellerAssets` (the
    ///      shipped pattern), with DCOF wired as `offer.callback`.
    function _borrowerSellOffer(uint16 tick, bytes32 group, uint128 maxSellerAssets, bytes memory callbackData)
        internal
        view
        returns (Offer memory, Signature memory, bytes32)
    {
        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: borrower,
            maxUnits: 0,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(dcofCallback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: borrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxAssets: maxSellerAssets,
            continuousFeeCap: type(uint256).max
        });
        Signature memory sig = _signOffer(offer, borrowerSK);
        bytes32 root = HashLib.hashOffer(offer);
        return (offer, sig, root);
    }

    /// @dev Build CallbackData where the pro-rata denominator equals the leg's
    ///      expected sellerAssets at full fill of `units` units at `tick`.
    ///      Assumes settlement fee == 0 (locked in setUp). Oracle is set to
    ///      10e36 in BoundaryTestBase (1 col = 10 loan).
    function _dcofData(uint256 units, uint16 tick, uint256 collateralAmount, uint256 maxBorrowCapacityUsage)
        internal
        pure
        returns (bytes memory, uint256)
    {
        uint256 sellerPrice = TickLib.tickToPrice(tick);
        uint256 expectedSellerAssets = (units * sellerPrice) / WAD;
        return (_encodeCb(collateralAmount, expectedSellerAssets, maxBorrowCapacityUsage), expectedSellerAssets);
    }

    function _encodeCb(uint256 collateralAmount, uint256 offerSellerAssets, uint256 maxBorrowCapacityUsage)
        internal
        pure
        returns (bytes memory)
    {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = collateralAmount;
        return abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: amounts, offerSellerAssets: offerSellerAssets, maxBorrowCapacityUsage: maxBorrowCapacityUsage
            })
        );
    }

    /// @dev mulDivDown — the onchain pro-rata identity these tests lock.
    function _expectedDcofPull(uint256 collConfigured, uint256 actualSA, uint256 commitSA)
        internal
        pure
        returns (uint256)
    {
        return (collConfigured * actualSA) / commitSA;
    }

    function _midnightTakeAction(
        Offer memory offer,
        uint256 units,
        bytes memory cbData,
        Signature memory sig,
        bytes32 root
    ) internal view returns (Action memory) {
        return Action({
            take: MidnightTakeData({
                takeUnits: units,
                takerCallback: address(dcofCallback),
                takerCallbackData: cbData,
                receiverIfTakerIsSeller: borrower,
                ratifierData: abi.encode(sig, root, uint256(0), new bytes32[](0))
            }),
            allowRevert: false,
            offer: offer,
            clamp: address(0),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });
    }

    function _executeParams(address) internal pure returns (ExecuteParams memory) {
        return ExecuteParams({
            deadline: 0,
            fillAxis: FillAxis.UNITS,
            maxFill: type(uint128).max,
            minFill: 0,
            minPrice: 0,
            maxPrice: type(uint256).max,
            maxContinuousFee: type(uint256).max,
            reduceOnly: false
        });
    }

    /* ═══════════════════════════════════════════════════════════════
       1 — Single-leg take-side DCOF, full fill
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Borrower hits a lender BUY offer directly (no router). Midnight
    ///         wires `seller = taker = borrower`, `sellerCallback =
    ///         takerCallback = DCOF` (Midnight.sol:300-308). Same callback as
    ///         the maker-side flow, no contract change.
    function test_takerSide_DCOF_singleLeg_fullFill() public {
        uint256 takeUnits = 100e18;
        uint256 collateralAmount = 200e18; // 200 * 10 oracle = 2000 value; debt ~100; debt/capacity ~5%
        (Offer memory offer, Signature memory sig, bytes32 root) = _buyOffer(DEFAULT_TICK);
        (bytes memory cbData, uint256 expectedSA) =
            _dcofData(takeUnits, DEFAULT_TICK, collateralAmount, TARGET_MAX_BORROW_CAPACITY_USAGE);

        uint256 colBefore = collateralToken.balanceOf(borrower);
        uint256 loanBefore = loanToken.balanceOf(borrower);

        vm.prank(borrower);
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            takeUnits,
            borrower,
            borrower,
            address(dcofCallback),
            cbData
        );

        assertEq(
            collateralToken.balanceOf(borrower), colBefore - collateralAmount, "DCOF pulled wrong amount on full fill"
        );
        assertEq(
            loanToken.balanceOf(borrower), loanBefore + expectedSA, "Borrower didn't receive expected sellerAssets"
        );
        assertEq(midnight.collateral(targetMarketId, borrower, 0), collateralAmount, "Collateral not supplied");
        assertEq(midnight.debt(targetMarketId, borrower), takeUnits, "Debt not recorded");
        assertEq(collateralToken.balanceOf(address(dcofCallback)), 0, "Callback retained collateral");
    }

    /* ═══════════════════════════════════════════════════════════════
       2 — Single-leg take-side DCOF, partial fill (commitment > capacity)
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Borrower's `cbData` was built committing to a hypothetical
    ///         100e18 fill, but the maker's offer caps at 60e18 of capacity.
    ///         Borrower requests 60e18 (the offer's full remaining); the
    ///         actual fill is 60% of the commitment, so DCOF pulls 60% of
    ///         the configured collateral via `mulDivDown` pro-rata.
    function test_takerSide_DCOF_partialFill_proRata() public {
        bytes32 group = _nextGroup();
        (Offer memory offer, Signature memory sig, bytes32 root) = _buyOfferFull(DEFAULT_TICK, group, 60e18);

        uint256 commitUnits = 100e18;
        uint256 collateralAmount = 200e18;
        (bytes memory cbData,) =
            _dcofData(commitUnits, DEFAULT_TICK, collateralAmount, TARGET_MAX_BORROW_CAPACITY_USAGE);

        uint256 colBefore = collateralToken.balanceOf(borrower);

        vm.prank(borrower);
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            60e18,
            borrower,
            borrower,
            address(dcofCallback),
            cbData
        );

        uint256 expectedPull = _expectedDcofPull(collateralAmount, 60e18, commitUnits);
        assertEq(
            collateralToken.balanceOf(borrower), colBefore - expectedPull, "Pro-rata pull mismatch on partial fill"
        );
        assertEq(midnight.collateral(targetMarketId, borrower, 0), expectedPull, "Collateral position mismatch");
        assertEq(midnight.debt(targetMarketId, borrower), 60e18, "Debt mismatch on partial fill");
    }

    /* ═══════════════════════════════════════════════════════════════
       3 — TenorRouter batch, two legs, per-leg cbData
       ═══════════════════════════════════════════════════════════════ */

    function test_routerBatch_DCOF_twoLegs_takerSide() public {
        uint16 tickA = DEFAULT_TICK;
        uint16 tickB = DEFAULT_TICK + 200;

        uint256 unitsA = 60e18;
        uint256 unitsB = 40e18;
        uint256 collA = 130e18;
        uint256 collB = 80e18;

        (Offer memory offerA, Signature memory sigA, bytes32 rootA) = _buyOffer(tickA);
        (Offer memory offerB, Signature memory sigB, bytes32 rootB) = _buyOffer(tickB);

        (bytes memory cbDataA, uint256 saA) = _dcofData(unitsA, tickA, collA, TARGET_MAX_BORROW_CAPACITY_USAGE);
        (bytes memory cbDataB, uint256 saB) = _dcofData(unitsB, tickB, collB, TARGET_MAX_BORROW_CAPACITY_USAGE);

        Action[] memory actions = new Action[](2);
        actions[0] = _midnightTakeAction(offerA, unitsA, cbDataA, sigA, rootA);
        actions[1] = _midnightTakeAction(offerB, unitsB, cbDataB, sigB, rootB);

        uint256 colBefore = collateralToken.balanceOf(borrower);
        uint256 loanBefore = loanToken.balanceOf(borrower);

        vm.prank(borrower);
        (, uint256 sellerAssets, uint256 units) = router.execute(_executeParams(borrower), actions);

        assertEq(collateralToken.balanceOf(borrower), colBefore - (collA + collB), "Aggregate collateral pulled wrong");
        assertEq(midnight.collateral(targetMarketId, borrower, 0), collA + collB, "Aggregate collateral not supplied");
        assertEq(midnight.debt(targetMarketId, borrower), unitsA + unitsB, "Aggregate debt wrong");
        assertEq(loanToken.balanceOf(borrower), loanBefore + saA + saB, "Aggregate sellerAssets wrong");
        assertEq(units, unitsA + unitsB, "Returned units wrong");
        assertEq(sellerAssets, saA + saB, "Returned sellerAssets wrong");
    }

    function test_routerBatch_DCOF_maxFillCapsSecondLeg() public {
        uint16 tickA = DEFAULT_TICK;
        uint16 tickB = DEFAULT_TICK + 200;

        uint256 unitsA = 60e18;
        uint256 unitsB = 40e18;
        uint256 collA = 130e18;
        uint256 collB = 80e18;

        (Offer memory offerA, Signature memory sigA, bytes32 rootA) = _buyOffer(tickA);
        (Offer memory offerB, Signature memory sigB, bytes32 rootB) = _buyOffer(tickB);

        (bytes memory cbDataA,) = _dcofData(unitsA, tickA, collA, TARGET_MAX_BORROW_CAPACITY_USAGE);
        (bytes memory cbDataB,) = _dcofData(unitsB, tickB, collB, TARGET_MAX_BORROW_CAPACITY_USAGE);

        Action[] memory actions = new Action[](2);
        actions[0] = _midnightTakeAction(offerA, unitsA, cbDataA, sigA, rootA);
        actions[1] = _midnightTakeAction(offerB, unitsB, cbDataB, sigB, rootB);

        ExecuteParams memory params = _executeParams(borrower);
        params.maxFill = 80e18;

        uint256 colBefore = collateralToken.balanceOf(borrower);

        vm.prank(borrower);
        (,, uint256 units) = router.execute(params, actions);

        // Leg A: fully fills 60e18. Leg B: capped at 80 - 60 = 20e18 of 40e18 commitment.
        uint256 expectedPullB = _expectedDcofPull(collB, 20e18, unitsB);
        uint256 expectedTotalPull = collA + expectedPullB;

        assertEq(
            collateralToken.balanceOf(borrower),
            colBefore - expectedTotalPull,
            "Pro-rata across batch (max-fill cap) wrong"
        );
        assertEq(
            midnight.collateral(targetMarketId, borrower, 0), expectedTotalPull, "Aggregate collateral position wrong"
        );
        assertEq(midnight.debt(targetMarketId, borrower), 80e18, "Capped debt wrong");
        assertEq(units, 80e18, "Capped units wrong");
    }

    /* ═══════════════════════════════════════════════════════════════
       4 — SHIPPED PATTERN: shared cbData with `offerSellerAssets =
       totalCommit`, two legs aggregate to `collateralAmount`
       ═══════════════════════════════════════════════════════════════ */

    /// @notice The actual SDK pattern (actions.ts:2179-2196): ONE callbackData
    ///         object reused across all legs, with `offerSellerAssets =
    ///         totalCommit`. Per-leg pulls auto-pro-rata
    ///         `collateralAmount * legSA / totalCommit`. Sum of per-leg pulls
    ///         when fills sum to `totalCommit` = `collateralAmount` exactly
    ///         (modulo per-leg `mulDivDown` rounding ≤ 1 wei/leg).
    function test_takerSide_DCOF_sharedDenominator_aggregatesToCollateralAmount() public {
        uint256 collateralAmount = 200e18;

        uint16 tickA = DEFAULT_TICK;
        uint16 tickB = DEFAULT_TICK + 200;
        uint256 unitsA = 60e18;
        uint256 unitsB = 40e18;
        uint256 saA = (unitsA * TickLib.tickToPrice(tickA)) / WAD;
        uint256 saB = (unitsB * TickLib.tickToPrice(tickB)) / WAD;
        uint256 totalCommit = saA + saB;

        bytes memory sharedCbData = _encodeCb(
            collateralAmount,
            /* offerSellerAssets= */
            totalCommit,
            /* maxBorrowCapacityUsage= */
            0
        );

        (Offer memory offerA, Signature memory sigA, bytes32 rootA) = _buyOffer(tickA);
        (Offer memory offerB, Signature memory sigB, bytes32 rootB) = _buyOffer(tickB);

        Action[] memory actions = new Action[](2);
        actions[0] = _midnightTakeAction(offerA, unitsA, sharedCbData, sigA, rootA);
        actions[1] = _midnightTakeAction(offerB, unitsB, sharedCbData, sigB, rootB);

        uint256 colBefore = collateralToken.balanceOf(borrower);

        vm.prank(borrower);
        router.execute(_executeParams(borrower), actions);

        uint256 expectedPullA = _expectedDcofPull(collateralAmount, saA, totalCommit);
        uint256 expectedPullB = _expectedDcofPull(collateralAmount, saB, totalCommit);
        uint256 totalPulled = colBefore - collateralToken.balanceOf(borrower);

        // Key invariant: when fills sum to `totalCommit`, total pulled == `collateralAmount`
        // (within at most 2 wei of rounding noise — one per mulDivDown).
        assertApproxEqAbs(
            totalPulled, collateralAmount, 2, "Total pull != collateralAmount when fills sum to totalCommit"
        );
        assertEq(totalPulled, expectedPullA + expectedPullB, "Per-leg sum mismatch");
        assertEq(midnight.collateral(targetMarketId, borrower, 0), totalPulled, "Position != total pulled");
    }

    /* ═══════════════════════════════════════════════════════════════
       5 — SHIPPED PATTERN: cross-side mix via shared `consumeGroup`
       ═══════════════════════════════════════════════════════════════ */

    /// @notice True cross-side: borrower posts a limit SELL offer with
    ///         `group = X` carrying DCOF as `offer.callback`, then takes a
    ///         lender BUY offer and explicitly consumes `group X` (mirroring
    ///         what `TenorRouterAdapterBase.executeAndConsume` does in the
    ///         bundler — see `TenorRouterAdapterBase.sol:46-48`). The shared
    ///         counter caps total cumulative fill across both sides at
    ///         `totalCommit`, bounding total collateral pulled at
    ///         `collateralAmount`.
    ///
    /// @dev TenorRouter's caller is one identity per execute, so we can't
    ///      put a borrower-as-maker leg + borrower-as-taker leg in one
    ///      `router.execute`. Two sequential takes against the shared group
    ///      is the actual SDK shape: the limit offer sits posted; the
    ///      spot-side `executeAndConsume` runs immediately and increments
    ///      `consumed[borrower][X]`.
    function test_mixedSides_DCOF_sharedGroup_capsAggregatePull() public {
        uint16 tick = DEFAULT_TICK;
        uint256 collateralAmount = 200e18;
        uint256 totalCommit = 100e18; // sellerAssets denominator
        bytes32 group = _nextGroup();

        // Shared cbData: offerSellerAssets = totalCommit so per-leg pulls
        // pro-rate against the combined commitment. maxBorrowCapacityUsage = 0 on both sides
        // for simplicity (test 6/7 cover the debt/capacity gate explicitly).
        bytes memory sharedCbData = _encodeCb(
            collateralAmount,
            totalCommit,
            /* maxBorrowCapacityUsage= */
            0
        );

        // (a) Borrower posts limit SELL with the shared group, capped at totalCommit.
        (Offer memory limitOffer, Signature memory limitSig, bytes32 limitRoot) =
            _borrowerSellOffer(tick, group, uint128(totalCommit), sharedCbData);

        // (b) Borrower-as-taker hits a lender BUY offer for half the commitment.
        (Offer memory buyOffer, Signature memory buySig, bytes32 buyRoot) = _buyOffer(tick);
        uint256 spotSA = totalCommit / 2;
        // sellerAssets = units * price / WAD ⇒ units = spotSA * WAD / price (round up).
        uint256 spotUnits = (spotSA * WAD + TickLib.tickToPrice(tick) - 1) / TickLib.tickToPrice(tick);

        uint256 colBefore = collateralToken.balanceOf(borrower);

        vm.prank(borrower);
        midnight.take(
            buyOffer,
            abi.encode(buySig, buyRoot, uint256(0), new bytes32[](0)),
            spotUnits,
            borrower,
            borrower,
            address(dcofCallback),
            sharedCbData
        );

        // Mimic `executeAndConsume(group)` from the bundler: increment
        // `consumed[borrower][group]` by the spot-side raw fill in seller
        // assets. (See TenorRouterAdapterBase.sol:46-48.)
        uint256 actualSpotSA = (spotUnits * TickLib.tickToPrice(tick)) / WAD;
        uint256 nextConsumed = midnight.consumed(borrower, group) + actualSpotSA;
        vm.prank(borrower);
        midnight.setConsumed(group, uint128(nextConsumed), borrower);

        // Spot-side pull pro-rated against the SHARED denominator.
        uint256 spotPull = _expectedDcofPull(collateralAmount, actualSpotSA, totalCommit);
        assertEq(colBefore - collateralToken.balanceOf(borrower), spotPull, "Spot leg: pro-rata pull wrong");
        assertEq(midnight.consumed(borrower, group), actualSpotSA, "consumed[borrower][group] not updated");

        // (c) Lender (acting as a third party) takes the borrower's limit SELL
        // offer for the remaining capacity. The `consumed` counter caps it at
        // `totalCommit - actualSpotSA`. Maker-side DCOF pulls the remaining
        // collateral, also pro-rated against `totalCommit`.
        uint256 colMid = collateralToken.balanceOf(borrower);
        uint256 remainingSA = totalCommit - actualSpotSA;
        uint256 remainingUnits = (remainingSA * WAD) / TickLib.tickToPrice(tick);

        vm.prank(lender);
        (, uint256 limitSA) = midnight.take(
            limitOffer,
            abi.encode(limitSig, limitRoot, uint256(0), new bytes32[](0)),
            remainingUnits,
            lender,
            address(0),
            address(0),
            ""
        );

        // SELL-offer side: `sellerAssets = mulDivUp(units, price, WAD)` per
        // Midnight.sol:316 — using Midnight's returned value avoids restating
        // its rounding direction here. Pull pro-rated against the SHARED
        // denominator just like the spot side.
        uint256 limitPull = _expectedDcofPull(collateralAmount, limitSA, totalCommit);
        assertEq(colMid - collateralToken.balanceOf(borrower), limitPull, "Limit leg: pro-rata pull wrong");

        // Aggregate invariant: total pull across both sides ~= collateralAmount.
        uint256 totalPull = colBefore - collateralToken.balanceOf(borrower);
        assertApproxEqAbs(totalPull, collateralAmount, 2, "Cross-side aggregate pull != collateralAmount");
    }

    /* ═══════════════════════════════════════════════════════════════
       6 — `maxBorrowCapacityUsage = 0` skips the per-leg debt/capacity gate (taker-side default)
       ═══════════════════════════════════════════════════════════════ */

    /// @notice The shipped pattern: take side hardcodes `maxBorrowCapacityUsage = 0`. Locks
    ///         that the callback's `if (maxBorrowCapacityUsage > 0)` branch is skipped and
    ///         the take succeeds even when post-fill debt/capacity would breach a
    ///         user-tightening cap. (Midnight's own `isLiquidatable` check
    ///         after the take still gates against LLTV — safety preserved.)
    function test_takerSide_DCOF_maxBorrowCapacityUsage_zero_skipsCheck() public {
        // 100e18 debt / (15e18 col * 10 oracle * 0.945 lltv = 141.75e18 capacity) ~70.6% debt/capacity.
        // > 50% (a tight gate the user might pick) but < 100% (not yet at liquidation).
        uint256 takeUnits = 100e18;
        uint256 collateralAmount = 15e18;
        (Offer memory offer, Signature memory sig, bytes32 root) = _buyOffer(DEFAULT_TICK);
        (bytes memory cbData,) =
            _dcofData(
                takeUnits,
                DEFAULT_TICK,
                collateralAmount,
                /* maxBorrowCapacityUsage= */
                0
            );

        vm.prank(borrower);
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            takeUnits,
            borrower,
            borrower,
            address(dcofCallback),
            cbData
        );

        assertEq(
            midnight.debt(targetMarketId, borrower), takeUnits, "Take should succeed with maxBorrowCapacityUsage=0"
        );
        assertEq(midnight.collateral(targetMarketId, borrower, 0), collateralAmount, "Collateral not supplied");
    }

    /* ═══════════════════════════════════════════════════════════════
       7 — Non-zero `maxBorrowCapacityUsage` reverts under-collateralized fill
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Mirror of test 6 but with a tight `maxBorrowCapacityUsage`: callback rejects
    ///         the take with `InvalidBorrowCapacityUsage`. Locks the arithmetic in
    ///         `MidnightSupplyCollateralCallback._borrowCapacityUsage`.
    function test_takerSide_DCOF_maxBorrowCapacityUsage_revert() public {
        uint256 takeUnits = 100e18;
        uint256 collateralAmount = 15e18; // post-fill debt/capacity ~70.6% > maxBorrowCapacityUsage 50%
        (Offer memory offer, Signature memory sig, bytes32 root) = _buyOffer(DEFAULT_TICK);
        (bytes memory cbData,) =
            _dcofData(
                takeUnits,
                DEFAULT_TICK,
                collateralAmount,
                /* maxBorrowCapacityUsage= */
                0.5e18
            );

        vm.prank(borrower);
        vm.expectRevert(CallbackLib.InvalidBorrowCapacityUsage.selector);
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            takeUnits,
            borrower,
            borrower,
            address(dcofCallback),
            cbData
        );
    }
}
