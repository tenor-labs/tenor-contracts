// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {CoreAdapter, IERC20, SafeERC20} from "@bundler3/adapters/CoreAdapter.sol";
import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {TenorRouter, ExecuteParams, Action, FillAxis} from "../router/TenorRouter.sol";
import {ITenorRouter} from "../router/interfaces/ITenorRouter.sol";
import {ITenorRouterAdapter} from "./interfaces/ITenorRouterAdapter.sol";
import {RouterLib} from "../libraries/RouterLib.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";
import {CollateralTransferLib} from "../libraries/CollateralTransferLib.sol";

/// @title MidnightRenewalAdapterBase
/// @notice Rolls the initiator's debt or credit from a source to a target Midnight market in one call.
/// @dev Each roll runs two router batches, an exit on the source market and an entry on the target market, and sizes
/// the entry onchain from what the exit did.
/// @dev Slippage is bounded on the roll as a whole, as a forward rate between the two maturities: the new position
/// per unit of source position closed is `1 + forwardRate * (targetMaturity - sourceMaturity)`. That interval is
/// fixed, so the bound does not drift with the time of inclusion. The legs' own price bounds still apply.
/// @dev Forward rates are signed: an exit through discounted offers can close more source position than the new
/// position it opens, and both bounds can require that.
/// @dev The initiator must authorize this adapter on Morpho Midnight.
/// @dev Inherits the bare router rather than `TenorRouterAdapterBase`: this adapter only runs batches as legs of a
/// roll, so the router's own `execute` is disabled. A contract combining both bases must override `_initiator` and
/// `execute` itself.
/// @dev This adapter implements no Midnight callback, so a third party can never make it the payer of a take, repay
/// or flash loan. Its standing loan-token approval to Morpho Midnight relies on that.
abstract contract MidnightRenewalAdapterBase is TenorRouter, CoreAdapter {
    using CollateralTransferLib for IMidnight;
    using UtilsLib for uint256;

    /* ERRORS */

    error WrongMarket();
    error WrongFillAxis();
    error ExitNotReduceOnly();
    error InvalidRepayUnits();
    error InvalidMaturities();
    error ForwardRateAboveMax(uint256 newDebt, uint256 maxNewDebt);
    error ForwardRateBelowMin(uint256 newCredit, uint256 minNewCredit);
    error InvalidForwardRate();
    error LoanBalanceDecreased();
    /// @dev A roll left loan tokens in the adapter: the target leg did not settle exactly the exit amount.
    error LoanBalanceIncreased();
    error ExecuteDisabled();

    /* ROUTER OVERRIDES */

    /// @dev The bundle initiator is the Midnight taker on every leg.
    function _initiator() internal view virtual override returns (address) {
        return initiator();
    }

    /// @inheritdoc ITenorRouter
    /// @dev Disabled: the bare router's `execute` is open to any caller.
    function execute(ExecuteParams calldata, Action[] calldata)
        external
        virtual
        override
        returns (uint256, uint256, uint256)
    {
        revert ExecuteDisabled();
    }

    /* BORROW SIDE */

    /// @notice Rolls `repayUnits` of the initiator's source debt into the target market.
    /// @dev The adapter must hold enough loan tokens to pay for the exit, e.g. from a flash loan wrapping this call.
    /// It ends the call holding exactly what it started with.
    /// @dev Collateral moves pro-rata to the debt closed. The source and target markets must list the same collateral
    /// token set; see CollateralTransferLib.
    /// @param sourceMarket The Midnight market to exit.
    /// @param repayUnits Source debt to roll. `type(uint256).max` rolls all of it.
    /// @param exitParams Batch params for the exit leg; `fillAxis` must be `UNITS`. `maxFill` and `minFill` are
    /// ignored: the leg takes up to `repayUnits` and the rest is repaid at par.
    /// @param exitActions Sell offers on the source market. May be empty: the debt is then repaid at par.
    /// @param borrowParams Batch params for the borrow leg; `fillAxis` must be `ASSETS`. `maxFill` and `minFill` are
    /// ignored: the leg fills exactly what the exit cost.
    /// @param borrowActions Buy offers on the target market, with `receiverIfTakerIsSeller` set to this adapter.
    /// @param maxForwardRate Ceiling on the forward rate of the roll, per second, in WAD. Negative requires less new
    /// debt than the debt closed. `type(int256).max` disables.
    /// @param consumeGroup Group of the initiator's resting roll offer to count the borrow leg against, for mixed
    /// execution. `bytes32(0)` skips it.
    /// @param maxConsumed Cap on that group's consumed amount after the borrow leg.
    function midnightRenew(
        Market calldata sourceMarket,
        uint256 repayUnits,
        ExecuteParams calldata exitParams,
        Action[] calldata exitActions,
        ExecuteParams calldata borrowParams,
        Action[] calldata borrowActions,
        int256 maxForwardRate,
        bytes32 consumeGroup,
        uint128 maxConsumed
    ) external onlyBundler3 {
        require(borrowActions.length != 0, EmptyActions());
        Market calldata targetMarket = borrowActions[0].offer.market;
        require(sourceMarket.loanToken == targetMarket.loanToken, CallbackLib.TokenMismatch());
        require(targetMarket.maturity > sourceMarket.maturity, InvalidMaturities());
        require(borrowParams.fillAxis == FillAxis.ASSETS, WrongFillAxis());

        address borrower = _initiator();
        IERC20 loanToken = IERC20(sourceMarket.loanToken);
        bytes32 sourceId = IdLib.toId(sourceMarket);

        uint256 debtBefore = _MORPHO_MIDNIGHT.debt(sourceId, borrower);
        if (repayUnits == type(uint256).max) repayUnits = debtBefore;
        require(repayUnits != 0 && repayUnits <= debtBefore, InvalidRepayUnits());

        uint256 balanceBefore = loanToken.balanceOf(address(this));

        if (exitActions.length != 0) {
            require(IdLib.toId(exitActions[0].offer.market) == sourceId, WrongMarket());
            require(exitParams.fillAxis == FillAxis.UNITS, WrongFillAxis());
            _execute(exitParams, exitActions, repayUnits, 0);
        }

        // Reverts by underflow if the exit batch was not on the source market's repay side.
        uint256 closed = debtBefore - _MORPHO_MIDNIGHT.debt(sourceId, borrower);
        if (closed < repayUnits) {
            SafeERC20.forceApprove(loanToken, address(_MORPHO_MIDNIGHT), type(uint256).max);
            _MORPHO_MIDNIGHT.repay(sourceMarket, repayUnits - closed, borrower, address(0), "");
        }

        uint256 spent = balanceBefore - loanToken.balanceOf(address(this));

        _MORPHO_MIDNIGHT.transferCollaterals(sourceMarket, targetMarket, borrower, sourceId, debtBefore, repayUnits);

        (uint256[3] memory borrowed, uint256[3] memory borrowedRaw) =
            _execute(borrowParams, borrowActions, spent, spent);
        _consume(consumeGroup, maxConsumed, borrowedRaw[RouterLib.FILL_SELLER_ASSETS]);

        if (maxForwardRate != type(int256).max) {
            uint256 newDebt = borrowed[RouterLib.FILL_UNITS];
            uint256 maxNewDebt = repayUnits.mulDivDown(
                _forwardFactor(maxForwardRate, targetMarket.maturity - sourceMarket.maturity), WAD
            );
            require(newDebt <= maxNewDebt, ForwardRateAboveMax(newDebt, maxNewDebt));
        }

        uint256 balanceAfter = loanToken.balanceOf(address(this));
        require(balanceAfter >= balanceBefore, LoanBalanceDecreased());
        require(balanceAfter <= balanceBefore, LoanBalanceIncreased());
    }

    /* LEND SIDE */

    /// @notice Rolls the initiator's source credit into the target market.
    /// @dev The exit first withdraws from the source pool at par, up to what the pool holds, then sells the rest into
    /// the source market's buy offers. The lend leg spends exactly the combined proceeds, so no outside liquidity is
    /// needed.
    /// @dev The withdrawal is capped onchain because the pool's withdrawable liquidity is shared: another lender
    /// withdrawing first shrinks it, and whatever is missed is left to the exit batch or to a later roll.
    /// @param sourceMarket The Midnight market to exit.
    /// @param withdrawUnits Most source credit to withdraw at par. Capped at the pool's withdrawable liquidity and
    /// at the initiator's credit. Zero skips the withdrawal.
    /// @param exitParams Batch params for the exit batch; `fillAxis` must be `UNITS` and `reduceOnly` true. `maxFill`
    /// and `minFill` bound the credit sold; `type(uint256).max` on either resolves to the credit left after the
    /// withdrawal.
    /// @param exitActions Buy offers on the source market, with `receiverIfTakerIsSeller` set to this adapter. May be
    /// empty: the roll is then funded by the withdrawal alone.
    /// @param lendParams Batch params for the lend leg; `fillAxis` must be `ASSETS`. `maxFill` and `minFill` are
    /// ignored: the leg lends exactly the exit proceeds.
    /// @param lendActions Sell offers on the target market, taken without a taker callback. The adapter must pay
    /// the whole leg from the exit proceeds and end holding no more than it started with (`LoanBalanceIncreased`).
    /// @param minForwardRate Floor on the forward rate of the roll, per second, in WAD. Zero requires at least one unit
    /// of new credit per unit of source credit closed; negative accepts less. `type(int256).min` disables.
    /// @param consumeGroup Group of the initiator's resting roll offer to count the lend leg against, for mixed
    /// execution. `bytes32(0)` skips it.
    /// @param maxConsumed Cap on that group's consumed amount after the lend leg.
    function midnightRenewLend(
        Market calldata sourceMarket,
        uint256 withdrawUnits,
        ExecuteParams calldata exitParams,
        Action[] calldata exitActions,
        ExecuteParams calldata lendParams,
        Action[] calldata lendActions,
        int256 minForwardRate,
        bytes32 consumeGroup,
        uint128 maxConsumed
    ) external onlyBundler3 {
        require(lendActions.length != 0, EmptyActions());
        Market calldata targetMarket = lendActions[0].offer.market;
        require(sourceMarket.loanToken == targetMarket.loanToken, CallbackLib.TokenMismatch());
        require(targetMarket.maturity > sourceMarket.maturity, InvalidMaturities());
        require(lendParams.fillAxis == FillAxis.ASSETS, WrongFillAxis());

        address lender = _initiator();
        IERC20 loanToken = IERC20(sourceMarket.loanToken);
        bytes32 sourceId = IdLib.toId(sourceMarket);
        uint256 balanceBefore = loanToken.balanceOf(address(this));

        // Par is the lender's best exit price, so the pool is drawn before any credit is sold.
        uint256 closed = UtilsLib.min(
            withdrawUnits,
            UtilsLib.min(_MORPHO_MIDNIGHT.withdrawable(sourceId), _updatedCredit(sourceMarket, sourceId, lender))
        );
        if (closed != 0) _MORPHO_MIDNIGHT.withdraw(sourceMarket, closed, lender, address(this));

        if (exitActions.length != 0) {
            require(IdLib.toId(exitActions[0].offer.market) == sourceId, WrongMarket());
            require(exitParams.fillAxis == FillAxis.UNITS, WrongFillAxis());
            require(exitParams.reduceOnly, ExitNotReduceOnly());
            uint256 maxFill = exitParams.maxFill;
            uint256 minFill = exitParams.minFill;
            if (maxFill == type(uint256).max || minFill == type(uint256).max) {
                uint256 credit = _updatedCredit(sourceMarket, sourceId, lender);
                if (maxFill == type(uint256).max) maxFill = credit;
                if (minFill == type(uint256).max) minFill = credit;
            }
            (uint256[3] memory sold,) = _execute(exitParams, exitActions, maxFill, minFill);
            closed += sold[RouterLib.FILL_UNITS];
        }

        require(closed != 0, CallbackLib.ZeroAmount());

        uint256 proceeds = loanToken.balanceOf(address(this)) - balanceBefore;

        (uint256[3] memory lent, uint256[3] memory lentRaw) = _execute(lendParams, lendActions, proceeds, proceeds);
        _consume(consumeGroup, maxConsumed, lentRaw[RouterLib.FILL_BUYER_ASSETS]);

        if (minForwardRate != type(int256).min) {
            uint256 newCredit = lent[RouterLib.FILL_UNITS];
            uint256 minNewCredit =
                closed.mulDivUp(_forwardFactor(minForwardRate, targetMarket.maturity - sourceMarket.maturity), WAD);
            require(newCredit >= minNewCredit, ForwardRateBelowMin(newCredit, minNewCredit));
        }

        require(loanToken.balanceOf(address(this)) <= balanceBefore, LoanBalanceIncreased());
    }

    /* INTERNAL */

    /// @dev Returns `1 + rate * delta` in WAD. Reverts on overflow, and with `InvalidForwardRate` when it is not
    /// positive: a rate that writes off the whole position is a caller error, not a quote, and clamping it would
    /// silently drop the lend floor.
    function _forwardFactor(int256 rate, uint256 delta) internal pure returns (uint256) {
        // Cast safe: the target leg touched the target market, so delta < targetMaturity <= now + 100 years.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 factor = int256(WAD) + rate * int256(delta);
        require(factor > 0, InvalidForwardRate());
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(factor);
    }

    /// @dev Counts a market leg against the initiator's resting offer group, as `executeAndConsume` does, so the
    /// market and limit parts of a mixed roll share one size. Unlike `executeAndConsume`, group zero skips it.
    function _consume(bytes32 group, uint128 maxConsumed, uint256 filled) internal {
        if (group == bytes32(0)) return;
        address initiator = _initiator();
        uint256 newConsumed = _MORPHO_MIDNIGHT.consumed(initiator, group) + filled;
        require(newConsumed <= maxConsumed, ITenorRouterAdapter.ConsumedCapExceeded(newConsumed, maxConsumed));
        // Cast safe: newConsumed <= maxConsumed <= type(uint128).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        _MORPHO_MIDNIGHT.setConsumed(group, uint128(newConsumed), initiator);
    }
}
