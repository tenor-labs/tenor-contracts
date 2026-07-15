// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BorrowMidnightToBlueCallback} from "@callbacks/BorrowMidnightToBlueCallback.sol";
import {IBorrowMidnightToBlueCallback} from "@callbacks/interfaces/IBorrowMidnightToBlueCallback.sol";

contract BorrowMidnightToBlueCallbackHarness is BorrowMidnightToBlueCallback {
    constructor(address morphoMidnight, address morphoBlue)
        BorrowMidnightToBlueCallback(morphoMidnight, morphoBlue) {}

    function decodeCallbackFeeRecipient(bytes memory data) external pure returns (address) {
        IBorrowMidnightToBlueCallback.CallbackData memory cbd =
            abi.decode(data, (IBorrowMidnightToBlueCallback.CallbackData));
        return cbd.feeRecipient;
    }

    function decodeCallbackFeeRate(bytes memory data) external pure returns (uint256) {
        IBorrowMidnightToBlueCallback.CallbackData memory cbd =
            abi.decode(data, (IBorrowMidnightToBlueCallback.CallbackData));
        return cbd.feeRate;
    }
}
