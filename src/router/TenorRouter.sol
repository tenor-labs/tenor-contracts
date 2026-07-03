// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {Midnight} from "@midnight/Midnight.sol";
import {IMidnight, Offer, Market} from "@midnight/interfaces/IMidnight.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TakeMathLib} from "../libraries/TakeMathLib.sol";
import {RouterLib} from "../libraries/RouterLib.sol";
import {ITakeClamp} from "./interfaces/ITakeClamp.sol";
import {ITenorRouter} from "./interfaces/ITenorRouter.sol";
import {ICallbackFeeAdjuster} from "./interfaces/ICallbackFeeAdjuster.sol";

/// @notice Dimension `maxFill`/`minFill` apply to.
/// @dev `ASSETS` resolves to the batch's side (buyer or seller).
enum FillAxis {
    ASSETS,
    UNITS
}

/// @notice Parameters for batch execution.
/// @dev `maxFill`/`minFill` = `type(uint256).max` is a renewal/close-out sentinel resolved against onchain state,
/// not the ERC-20 "unlimited" idiom; resolution reverts if it yields 0, so opening flows must pass explicit bounds.
/// @dev `fillAxis == ASSETS` caps and the slippage denominator both pin to the batch's side; see `_initiatorIsBuyer`.
/// @dev `_execute` enforces that all actions share the same market (`InconsistentMarket`) and the same side
/// (`InconsistentSide`). The initiator is always the Midnight taker.
struct ExecuteParams {
    uint256 deadline; // block.timestamp must be <= deadline (0 = no deadline).
    FillAxis fillAxis;
    uint256 maxFill; // Denominated in assets or units depending on fillAxis.
    uint256 minFill; // Denominated in assets or units depending on fillAxis.
    uint256 minPrice; // WAD-scaled assets-per-unit floor on the batch side (0 disables).
    uint256 maxPrice; // WAD-scaled assets-per-unit ceiling on the batch side (MaxUint disables).
    bool reduceOnly; // Crossing protection: reverts if the initiator's wrong side grows.
}

/// @notice The Midnight take parameters carried by each `Action`.
/// @dev If `takerCallback` reenters Bundler3 (e.g. `TenorAdapter`), at most one such action may execute per
/// top-level `Bundler3.multicall` `Call` entry; see `MidnightAdapterBase._midnightCallback`.
/// @dev With `Action.allowRevert = true`, follow-up reentrant actions in the same batch silently no-op with
/// `IncorrectReenterHash` instead of failing the call.
struct MidnightTakeData {
    uint256 takeUnits;
    address takerCallback;
    bytes takerCallbackData;
    address receiverIfTakerIsSeller;
    bytes ratifierData;
}

/// @notice Per-action parameters.
/// @dev `take` carries the Midnight take parameters (`MidnightTakeData`).
/// @dev `allowRevert` only catches reverts from the inner `take` call; other per-action paths still abort the batch.
/// @dev `feeAdjuster`/`feeAdjusterData` are trusted to mirror the callback's actual fee (formula and rate); the
/// router does not cross-check them. Misconfigured fee adjustment params may skew fill/slippage accounting for the
/// whole batch. `feeAdjuster` may be `address(0)` when callbacks charge no initiator fees.
struct Action {
    MidnightTakeData take;
    bool allowRevert;
    Offer offer;
    address clamp;
    bytes clampData;
    address feeAdjuster;
    bytes feeAdjusterData;
}

/// @title TenorRouter
/// @notice Executes batches of Midnight takes with per-batch fill, price and crossing protections.
/// @dev The initiator (`msg.sender` here, `Bundler3.initiator()` in the adapter) drives the batch and is always the
/// Midnight taker; `offer.maker` is the counterparty providing liquidity for a given action.
/// @dev Without a feeAdjuster, maxFill, minFill and the price band bound raw Midnight amounts, not net-taker amounts.
/// @dev Takes from nested callbacks are invisible to the batch's maxFill/minFill accounting and BatchExecuted totals.
/// @dev Maker-supplied policies, resolvers and clamps are untrusted code; quoting and dispatch may revert or burn gas.
abstract contract TenorRouter is ITenorRouter {
    /* IMMUTABLES */

    Midnight internal immutable _MORPHO_MIDNIGHT;

    /* CONSTRUCTOR */

    constructor(address morphoMidnight) {
        _MORPHO_MIDNIGHT = Midnight(morphoMidnight);
    }

    /* VIRTUAL */

    function _initiator() internal view virtual returns (address) {
        return msg.sender;
    }

    /* EXTERNAL */

    function execute(ExecuteParams calldata params, Action[] calldata actions)
        external
        virtual
        override
        returns (uint256, uint256, uint256)
    {
        (uint256[3] memory totals,) = _execute(params, actions);
        return (totals[0], totals[1], totals[2]);
    }

    /* INTERNAL: EXECUTE */

    function _execute(ExecuteParams calldata params, Action[] calldata actions)
        internal
        returns (uint256[3] memory totals, uint256[3] memory rawTotals)
    {
        return _execute(params, actions, params.maxFill, params.minFill);
    }

    /// @dev `totals` holds the initiator-facing amounts after `feeAdjuster.afterDispatch()` has tilted them in the
    /// initiator-worsening direction, across all fills.
    /// @dev `rawTotals` holds the amounts Midnight actually matched onchain (pre-adjustment), accumulated
    /// unconditionally. The initiator is always the taker here, so these are exclusively its taker-side fills,
    /// disjoint from its maker-side fills that Midnight already counts under `consumed[initiator][group]`: resting
    /// offers filled during the batch, e.g. via reentrancy.
    /// @dev To reconcile the initiator's consumption, add `rawTotals` to `consumed[initiator][group]`: the two never
    /// overlap, so the sum does not double-count.
    function _execute(ExecuteParams calldata params, Action[] calldata actions, uint256 maxFill, uint256 minFill)
        internal
        returns (uint256[3] memory totals, uint256[3] memory rawTotals)
    {
        if (actions.length == 0) revert EmptyActions();
        if (params.deadline != 0 && block.timestamp > params.deadline) {
            revert DeadlineExpired(params.deadline, block.timestamp);
        }

        address initiator = _initiator();

        bool initiatorIsBuyer = _initiatorIsBuyer(actions[0], initiator);
        uint8 sideAssetsIndex = initiatorIsBuyer ? RouterLib.FILL_BUYER_ASSETS : RouterLib.FILL_SELLER_ASSETS;
        uint8 fillIndex = params.fillAxis == FillAxis.UNITS ? RouterLib.FILL_UNITS : sideAssetsIndex;

        bytes32 expectedMarketId = IdLib.toId(actions[0].offer.market);

        uint256 wrongSideBefore;
        if (params.reduceOnly) {
            wrongSideBefore = initiatorIsBuyer
                ? _updatedCredit(actions[0].offer.market, expectedMarketId, initiator)
                : _MORPHO_MIDNIGHT.debt(expectedMarketId, initiator);
        }

        for (uint256 i; i < actions.length; i++) {
            Action calldata action = actions[i];
            if (_initiatorIsBuyer(action, initiator) != initiatorIsBuyer) revert InconsistentSide(i, initiatorIsBuyer);

            if (totals[fillIndex] >= maxFill) break;
            uint256 remaining = maxFill - totals[fillIndex];

            // Treat offers outside their start/expiry window as reverted without dispatching, to save gas.
            if (action.allowRevert) {
                if (block.timestamp < action.offer.start) {
                    emit ActionReverted(i, abi.encodeWithSelector(IMidnight.OfferNotStarted.selector));
                    continue;
                }
                if (block.timestamp > action.offer.expiry) {
                    emit ActionReverted(i, abi.encodeWithSelector(IMidnight.OfferExpired.selector));
                    continue;
                }
            }

            (
                bool success,
                uint256 buyerAssets,
                uint256 sellerAssets,
                uint256 units,
                bytes32 marketId,
                bytes memory reason
            ) = _dispatchMidnightTake(action, initiator, fillIndex, remaining);

            if (marketId != expectedMarketId) revert InconsistentMarket(i);

            if (!success) {
                if (!action.allowRevert) revert ActionFailed(i, reason);
                emit ActionReverted(i, reason);
                continue;
            }

            rawTotals[RouterLib.FILL_BUYER_ASSETS] += buyerAssets;
            rawTotals[RouterLib.FILL_SELLER_ASSETS] += sellerAssets;
            rawTotals[RouterLib.FILL_UNITS] += units;

            if (action.feeAdjuster != address(0)) {
                // The fee lands on the initiator's (taker's) own asset side.
                uint256 feeAmount = ICallbackFeeAdjuster(action.feeAdjuster)
                    .afterDispatch(
                        action.offer, initiatorIsBuyer, buyerAssets, sellerAssets, units, action.feeAdjusterData
                    );
                if (initiatorIsBuyer) {
                    buyerAssets += feeAmount;
                } else {
                    sellerAssets -= feeAmount;
                }
            }

            totals[RouterLib.FILL_BUYER_ASSETS] += buyerAssets;
            totals[RouterLib.FILL_SELLER_ASSETS] += sellerAssets;
            totals[RouterLib.FILL_UNITS] += units;

            if (totals[fillIndex] > maxFill) {
                revert FillOvershoot(totals[fillIndex], maxFill);
            }
        }

        if (totals[fillIndex] < minFill) {
            revert InsufficientFill(totals[fillIndex], minFill);
        }

        uint256 units = totals[RouterLib.FILL_UNITS];
        uint256 assets = totals[sideAssetsIndex];
        if (units > 0) {
            uint256 priceCeil = UtilsLib.mulDivUp(assets, WAD, units);
            if (priceCeil > params.maxPrice) {
                revert PriceSlippageExceeded(priceCeil, params.minPrice, params.maxPrice);
            }
            uint256 priceFloor = UtilsLib.mulDivDown(assets, WAD, units);
            if (priceFloor < params.minPrice) {
                revert PriceSlippageExceeded(priceFloor, params.minPrice, params.maxPrice);
            }
        } else if (assets > 0 && params.maxPrice != type(uint256).max) {
            revert PriceSlippageExceeded(type(uint256).max, params.minPrice, params.maxPrice);
        }

        if (params.reduceOnly) {
            uint256 wrongSideAfter = initiatorIsBuyer
                ? _updatedCredit(actions[0].offer.market, expectedMarketId, initiator)
                : _MORPHO_MIDNIGHT.debt(expectedMarketId, initiator);
            if (wrongSideAfter > wrongSideBefore) {
                revert ReduceOnlyViolated(wrongSideBefore, wrongSideAfter);
            }
        }

        emit BatchExecuted(
            initiator,
            msg.sender,
            params,
            actions.length,
            totals[RouterLib.FILL_BUYER_ASSETS],
            totals[RouterLib.FILL_SELLER_ASSETS],
            totals[RouterLib.FILL_UNITS]
        );
    }

    function _dispatchMidnightTake(Action calldata action, address initiator, uint8 fillIndex, uint256 remaining)
        internal
        returns (bool, uint256, uint256, uint256, bytes32, bytes memory)
    {
        MidnightTakeData calldata d = action.take;

        bytes32 marketId = _MORPHO_MIDNIGHT.touchMarket(action.offer.market);

        uint256 takeUnits = _capTakeUnits(action, d.takeUnits, fillIndex, remaining, marketId);
        if (takeUnits == 0) return (true, 0, 0, 0, marketId, "");

        address loanToken = action.offer.market.loanToken;
        // Lender path with no takerCallback: Midnight resolves payer to msg.sender (this contract),
        // so give it a temporary allowance for the in-flight take.
        bool routerIsPayer = d.takerCallback == address(0) && !action.offer.buy;
        if (routerIsPayer) {
            SafeERC20.forceApprove(IERC20(loanToken), address(_MORPHO_MIDNIGHT), type(uint256).max);
        }

        try _MORPHO_MIDNIGHT.take(
            action.offer,
            d.ratifierData,
            takeUnits,
            initiator,
            d.receiverIfTakerIsSeller,
            d.takerCallback,
            d.takerCallbackData
        ) returns (
            uint256 r0, uint256 r1
        ) {
            if (routerIsPayer) SafeERC20.forceApprove(IERC20(loanToken), address(_MORPHO_MIDNIGHT), 0);
            return (true, r0, r1, takeUnits, marketId, "");
        } catch (bytes memory reason) {
            if (routerIsPayer) SafeERC20.forceApprove(IERC20(loanToken), address(_MORPHO_MIDNIGHT), 0);
            return (false, 0, 0, 0, marketId, reason);
        }
    }

    /// @dev Anchors the same-side check and the slippage denominator.
    /// @dev The initiator is always the Midnight taker, so the result is `!offer.buy`.
    function _initiatorIsBuyer(Action calldata action, address) internal pure returns (bool) {
        return !action.offer.buy;
    }

    /// @dev Maps the batch's side to its loan-token axis.
    /// @dev Single source of truth for the `FillAxis.ASSETS` to `BUYER_ASSETS`/`SELLER_ASSETS` resolution shared
    /// between `_execute` and `TenorRouterAdapterBase` (sentinel and consume paths).
    /// @dev Callers must ensure `actions.length > 0`; both `_execute` and the adapter reject empty batches
    /// with `EmptyActions` before reaching this helper.
    function _sideAssetsIndex(Action[] calldata actions, address initiator) internal pure returns (uint8) {
        return _initiatorIsBuyer(actions[0], initiator) ? RouterLib.FILL_BUYER_ASSETS : RouterLib.FILL_SELLER_ASSETS;
    }

    /// @dev Resolves a `FillAxis` to its uint8 fill index: `UNITS` maps to `FILL_UNITS`, and
    /// `ASSETS` maps to the batch side via `_sideAssetsIndex`.
    function _fillIndex(FillAxis fillAxis, Action[] calldata actions, address initiator) internal pure returns (uint8) {
        if (fillAxis == FillAxis.UNITS) return RouterLib.FILL_UNITS;
        return _sideAssetsIndex(actions, initiator);
    }

    /// @dev Returns `user`'s up-to-date credit via `updatePositionView`, the value
    /// `Midnight.take` will internally see and mutate.
    /// @dev `credit` is not used because it does not include pending continuous-fee accrual or slashing.
    function _updatedCredit(Market calldata market, bytes32 id, address user) internal view returns (uint256) {
        (uint128 newCredit,,) = _MORPHO_MIDNIGHT.updatePositionView(market, id, user);
        return newCredit;
    }

    /* INTERNAL: CLAMPING */

    /// @dev Returns `takeUnits` capped by the remaining fill budget (`remaining`, denominated in assets or units
    /// depending on `fillIndex`), the offer's remaining capacity, and the optional `clamp`.
    function _capTakeUnits(
        Action calldata action,
        uint256 takeUnits,
        uint8 fillIndex,
        uint256 remaining,
        bytes32 marketId
    ) internal view returns (uint256) {
        if (remaining < type(uint256).max / WAD) {
            uint256 cap = action.feeAdjuster != address(0)
                ? ICallbackFeeAdjuster(action.feeAdjuster)
                    .beforeDispatch(action.offer, fillIndex, remaining, action.feeAdjusterData)
                : RouterLib.budgetToUnits(_MORPHO_MIDNIGHT, marketId, action.offer, fillIndex, remaining);
            takeUnits = UtilsLib.min(takeUnits, cap);
        }
        if (takeUnits == 0) return 0;

        takeUnits =
            UtilsLib.min(takeUnits, TakeMathLib.getOfferRemaining(IMidnight(_MORPHO_MIDNIGHT), action.offer, marketId));

        if (takeUnits == 0 || action.clamp == address(0)) return takeUnits;
        return UtilsLib.min(takeUnits, ITakeClamp(action.clamp).maxUnits(action.offer, action.clampData));
    }
}
