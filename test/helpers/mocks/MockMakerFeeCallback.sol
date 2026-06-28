// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IBuyCallback} from "@midnight/interfaces/ICallbacks.sol";
import {Market} from "@midnight/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {CallbackLib} from "../../../src/libraries/CallbackLib.sol";
import {IBorrowMidnightRenewalCallback} from "@callbacks/interfaces/IBorrowMidnightRenewalCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Test-only maker-side fee callback. Attached to a BUY offer (maker = buyer) it becomes
///         Midnight's `payer`: `onBuy` sources `buyerAssets + fee` from the maker, forwards the fee
///         to the recipient, and approves Midnight to pull settlement from this contract. Fee terms
///         are encoded as `IBorrowMidnightRenewalCallback.CallbackData` (INTEREST formula, tick
///         bound) so the canonical `CallbackFeeAdjuster` decodes them when this address occupies a
///         renewal fee-callback slot.
contract MockMakerFeeCallback is IBuyCallback {
    using SafeERC20 for IERC20;

    address internal immutable MIDNIGHT;

    constructor(address midnight) {
        MIDNIGHT = midnight;
    }

    function onBuy(
        bytes32,
        Market memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256,
        address buyer,
        bytes memory data
    ) external override returns (bytes32) {
        require(msg.sender == MIDNIGHT, "only midnight");
        IBorrowMidnightRenewalCallback.CallbackData memory d =
            abi.decode(data, (IBorrowMidnightRenewalCallback.CallbackData));
        uint256 fee = CallbackLib.buyerFeeFromTick(d.tick, d.feeRate, units, buyerAssets);
        IERC20(market.loanToken).safeTransferFrom(buyer, address(this), buyerAssets + fee);
        if (fee > 0) IERC20(market.loanToken).safeTransfer(d.feeRecipient, fee);
        IERC20(market.loanToken).forceApprove(MIDNIGHT, buyerAssets);
        return CALLBACK_SUCCESS;
    }
}
