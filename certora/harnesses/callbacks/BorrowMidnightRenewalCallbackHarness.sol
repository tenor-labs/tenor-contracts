// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BorrowMidnightRenewalCallback} from "@callbacks/BorrowMidnightRenewalCallback.sol";
import {IBorrowMidnightRenewalCallback} from "@callbacks/interfaces/IBorrowMidnightRenewalCallback.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";

contract BorrowMidnightRenewalCallbackHarness is BorrowMidnightRenewalCallback {
    constructor(address morphoMidnight)
        BorrowMidnightRenewalCallback(morphoMidnight) {}

    // The sourceMarketId onSell derives from callbackData (CB-SAME-1 gate input).
    function decodeCallbackSourceMarketId(bytes memory data) external pure returns (bytes32) {
        IBorrowMidnightRenewalCallback.CallbackData memory cbd =
            abi.decode(data, (IBorrowMidnightRenewalCallback.CallbackData));
        return IdLib.toId(cbd.sourceMarket);
    }

    function decodeCallbackFeeRecipient(bytes memory data) external pure returns (address) {
        IBorrowMidnightRenewalCallback.CallbackData memory cbd =
            abi.decode(data, (IBorrowMidnightRenewalCallback.CallbackData));
        return cbd.feeRecipient;
    }

    function decodeCallbackFeeRate(bytes memory data) external pure returns (uint256) {
        IBorrowMidnightRenewalCallback.CallbackData memory cbd =
            abi.decode(data, (IBorrowMidnightRenewalCallback.CallbackData));
        return cbd.feeRate;
    }

    function decodeCallbackTick(bytes memory data) external pure returns (uint256) {
        IBorrowMidnightRenewalCallback.CallbackData memory cbd =
            abi.decode(data, (IBorrowMidnightRenewalCallback.CallbackData));
        return cbd.tick;
    }
}
