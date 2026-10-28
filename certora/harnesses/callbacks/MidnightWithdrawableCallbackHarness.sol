// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightWithdrawableCallback} from "@callbacks/MidnightWithdrawableCallback.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";

contract MidnightWithdrawableCallbackHarness is MidnightWithdrawableCallback {
    constructor(address morphoMidnight) MidnightWithdrawableCallback(morphoMidnight) {}

    function callbackSuccess() external pure returns (bytes32) {
        return CALLBACK_SUCCESS;
    }

    // Real (unsummarized) price of the only tick isRatified accepts. Only meaningful in the standalone scene:
    // the take scene summarizes TickLib.
    function parTickPrice() external pure returns (uint256) {
        return TickLib.tickToPrice(MAX_TICK);
    }
}
