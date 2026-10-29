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
/// @notice Callback that funds a standing par BUY offer from a Midnight market's withdrawable, so lenders can exit and
/// borrowers can borrow at 0% up to that amount.
/// @dev Is the offer's maker, ratifier and callback, so anyone can build and take the offer without a signature.
/// @dev Withdraws units from the market and lets Morpho Midnight pull them through a standing max approval of the loan
/// token. Fills revert above withdrawable(id). Router actions should use MidnightWithdrawableClamp.
/// @dev Takers need no authorization or approval for this contract. It authorizes only itself on Morpho Midnight, to
/// pass take's maker-to-ratifier check.
/// @dev Lender fills pay Midnight's settlement fee, which a direct Morpho Midnight withdraw avoids. The callback path
/// is for flows that can only take offers, such as router batches.
contract MidnightWithdrawableCallback is IMidnightWithdrawableCallback {
    using SafeERC20 for IERC20;

    IMidnight public immutable MORPHO_MIDNIGHT;

    constructor(address morphoMidnight) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
        MORPHO_MIDNIGHT.setIsAuthorized(address(this), true, address(this));
    }

    function isRatified(
        Offer memory offer,
        bytes memory,
        /* ratifierData */
        address /* taker */
    )
        external
        view
        override
        returns (bytes32)
    {
        if (offer.maker != address(this) || offer.callback != address(this) || !offer.buy) {
            revert CallbackLib.NotSelf();
        }
        if (offer.tick != MAX_TICK) revert CallbackLib.NotPar();
        return CALLBACK_SUCCESS;
    }

    function onBuy(
        bytes32,
        /* marketId */
        Market memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256,
        /* pendingFeeIncrease */
        address buyer,
        bytes memory /* data */
    ) external override returns (bytes32) {
        if (msg.sender != address(MORPHO_MIDNIGHT)) {
            revert CallbackLib.OnlyMidnight();
        }
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
