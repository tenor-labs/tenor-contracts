/* ── MUTATION MidnightWithdrawableCallback #2 ──────────────────────────────
 * @desc:   callback check dropped: own offers without the onBuy withdraw are ratified
 * @rules:  isRatifiedOnlyAcceptsOwnParBuyOffer
 * @conf:   certora/confs/callbacks/MidnightWithdrawableCallback/standalone.conf
 * @status: killed
 * @target: src/callbacks/MidnightWithdrawableCallback.sol
 * Was:     if (offer.maker != address(this) || offer.callback != address(this) || !offer.buy) { revert CallbackLib.NotSelf(); }
 * Now:     if (offer.maker != address(this) || !offer.buy) revert CallbackLib.NotSelf();
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {IMidnightWithdrawableCallback} from "./interfaces/IMidnightWithdrawableCallback.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MidnightWithdrawableCallback
/// @notice Standing par (price 1) BUY offer over any Morpho Midnight market's withdrawable. This contract is the
/// offer's maker, ratifier and callback, so anyone can build the offer and take it without a signature.
/// @dev Lenders resell credit at par, and borrowers borrow at 0%, gross of Midnight's settlement fee, up to
/// MORPHO_MIDNIGHT.withdrawable(id). Router actions should use MidnightWithdrawableClamp to cap fills at that amount.
/// @dev With a nonzero settlement fee, a lender is always better off calling MORPHO_MIDNIGHT.withdraw directly: same
/// par exit, no settlement fee. The lender path is for flows that can only take offers, like router batches.
/// @dev Each fill credits this contract units and withdraws them right back, so it never holds a position.
/// @dev Borrower fills replace withdrawable assets with new debt, whose bad debt is socialized among the market's
/// lenders.
/// @dev The self-authorization only satisfies take's maker-to-ratifier check: no other account is ever authorized
/// for this contract.
/// @dev Midnight holds a standing max approval for each loan token, which saves an approve and its refund-capped
/// reset on every fill. Midnight only pulls from this contract after onBuy accepts one of its own fills, for exactly
/// the units just withdrawn: this contract must never implement onSell, onRepay, onLiquidate or onFlashLoan, which
/// would let Midnight pull from it as their payer.
/// @dev No event: Midnight's Take and Withdraw events fully describe each fill.
/// @dev Tokens sent to this contract are not recoverable, including a take's proceeds when receiverIfTakerIsSeller is
/// this contract.
contract MidnightWithdrawableCallback is IMidnightWithdrawableCallback {
    using SafeERC20 for IERC20;

    IMidnight public immutable MORPHO_MIDNIGHT;

    constructor(address morphoMidnight) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
        MORPHO_MIDNIGHT.setIsAuthorized(address(this), true, address(this));
    }

    function isRatified(
        Offer memory offer,
        bytes memory, /* ratifierData */
        address /* taker */
    )
        external
        view
        override
        returns (bytes32)
    {
        if (offer.maker != address(this) || !offer.buy) revert CallbackLib.NotSelf();  // MUTATION: callback check dropped: own offers without the onBuy withdraw are ratified
        if (offer.tick != MAX_TICK) revert CallbackLib.NotPar();
        return CALLBACK_SUCCESS;
    }

    function onBuy(
        bytes32, /* marketId */
        Market memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256, /* pendingFeeIncrease */
        address buyer,
        bytes memory /* data */
    ) external override returns (bytes32) {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
        if (buyerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
        if (buyer != address(this)) revert CallbackLib.NotSelf();

        // isRatified pins the price to 1, so buyerAssets == units. Reverts if withdrawable(id) < units.
        MORPHO_MIDNIGHT.withdraw(market, units, address(this), address(this));
        IERC20 loanToken = IERC20(market.loanToken);
        if (loanToken.allowance(address(this), msg.sender) < units) {
            loanToken.forceApprove(msg.sender, type(uint256).max);
        }

        return CALLBACK_SUCCESS;
    }
}
