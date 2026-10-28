/* ── MUTATION MidnightWithdrawableCallback #7 ──────────────────────────────
 * @desc:   approves one unit extra: the callback keeps a standing approval to Midnight
 * @rules:  callbackKeepsZeroAllowance
 * @conf:   certora/confs/callbacks/MidnightWithdrawableCallback/callbackKeepsZeroAllowance.conf
 * @status: killed
 * @target: src/callbacks/MidnightWithdrawableCallback.sol
 * Was:     IERC20(market.loanToken).forceApprove(msg.sender, units);
 * Now:     IERC20(market.loanToken).forceApprove(msg.sender, units + 1);
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
/// @dev Zero-unit fills succeed as no-ops: unlike the other callbacks, there is no ZeroAmount guard.
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
        if (offer.maker != address(this) || offer.callback != address(this) || !offer.buy) revert NotSelf();
        if (offer.tick != MAX_TICK) revert NotPar();
        return CALLBACK_SUCCESS;
    }

    function onBuy(
        bytes32, /* marketId */
        Market memory market,
        uint256, /* buyerAssets */
        uint256 units,
        uint256, /* pendingFeeIncrease */
        address buyer,
        bytes memory /* data */
    )
        external
        override
        returns (bytes32)
    {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
        if (buyer != address(this)) revert NotSelf();

        // isRatified pins the price to 1, so buyerAssets == units. Reverts if withdrawable(id) < units.
        MORPHO_MIDNIGHT.withdraw(market, units, address(this), address(this));
        IERC20(market.loanToken).forceApprove(msg.sender, units + 1);  // MUTATION: approves one unit extra: the callback keeps a standing approval to Midnight

        return CALLBACK_SUCCESS;
    }
}
