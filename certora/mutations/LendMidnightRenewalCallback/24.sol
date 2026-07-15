/* ── MUTATION LendMidnightRenewalCallback #24 ──────────────────────────────
 * @desc:   Flips the same-market guard from == to !=, so the callback no longer reverts when the source and target markets are identical, and the rule requiring a revert in that case flips to a counterexample.
 * @rules:  callbackRevertsForSameSourceMarket
 * @conf:   certora/confs/callbacks/LendMidnightRenewalCallback/perf/callbackRevertsForSameSourceMarket.conf
 * @status: killed
 * @target: src/callbacks/LendMidnightRenewalCallback.sol
 * Was:     if (sourceMarketId == marketId) revert CallbackLib.SameMarket();
 * Now:     if (sourceMarketId != marketId) revert CallbackLib.SameMarket();
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {ILendMidnightRenewalCallback} from "./interfaces/ILendMidnightRenewalCallback.sol";
import {SafeTransferLib} from "@midnight/libraries/SafeTransferLib.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {CallbackLib} from "../libraries/CallbackLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LendMidnightRenewalCallback
/// @notice Callback that renews a lender position from a source to the target Midnight market when that market's
/// BUY offer is taken.
/// @dev Withdraws buyerAssets + fee from the source market, transfers the fee to the recipient, and
/// approves Morpho Midnight to pull buyerAssets.
/// @dev The lender must authorize this contract on Morpho Midnight.
/// @dev No health check is run on the target market during the renewal (only loan-token equality is validated), so
/// the migration can result in loss if that market has pending bad debt or depegged collateral. Lenders should only
/// allow renewals into markets they trust.
contract LendMidnightRenewalCallback is ILendMidnightRenewalCallback {
    using SafeERC20 for IERC20;

    IMidnight public immutable MORPHO_MIDNIGHT;

    constructor(address morphoMidnight) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
    }

    function onBuy(
        bytes32 marketId,
        Market memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256, /* pendingFeeIncrease */
        address buyer,
        bytes memory data
    ) external override returns (bytes32) {
        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
        if (buyerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();

        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        if (callbackData.sourceMarket.loanToken != market.loanToken) revert CallbackLib.TokenMismatch();

        bytes32 sourceMarketId = IdLib.toId(callbackData.sourceMarket);
        if (sourceMarketId != marketId) revert CallbackLib.SameMarket();  // MUTATION: rebased
        (uint128 sourceCredit,,) = MORPHO_MIDNIGHT.updatePositionView(callbackData.sourceMarket, sourceMarketId, buyer);
        if (sourceCredit == 0) revert CallbackLib.ZeroAmount();

        uint256 fee = CallbackLib.buyerFeeFromTick(callbackData.tick, callbackData.feeRate, units, buyerAssets);

        uint256 withdrawAssets = buyerAssets + fee;
        if (withdrawAssets > sourceCredit) revert CallbackLib.InsufficientCredit();

        MORPHO_MIDNIGHT.withdraw(callbackData.sourceMarket, withdrawAssets, buyer, address(this));

        if (fee > 0) {
            SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
        }

        IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);

        emit LendRenewed(buyer, sourceMarketId, marketId, buyerAssets, fee);

        return CALLBACK_SUCCESS;
    }
}
