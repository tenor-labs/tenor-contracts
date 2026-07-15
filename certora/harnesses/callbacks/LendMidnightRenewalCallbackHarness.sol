// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LendMidnightRenewalCallback} from "@callbacks/LendMidnightRenewalCallback.sol";
import {ILendMidnightRenewalCallback} from "@callbacks/interfaces/ILendMidnightRenewalCallback.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";

contract LendMidnightRenewalCallbackHarness is LendMidnightRenewalCallback {
    constructor(address morphoMidnight)
        LendMidnightRenewalCallback(morphoMidnight) {}

    // The sourceMarketId onBuy derives from callbackData (CB-SAME-1 gate input).
    function decodeCallbackSourceMarketId(bytes memory data) external pure returns (bytes32) {
        ILendMidnightRenewalCallback.CallbackData memory cbd =
            abi.decode(data, (ILendMidnightRenewalCallback.CallbackData));
        return IdLib.toId(cbd.sourceMarket);
    }

    function decodeCallbackFeeRate(bytes memory data) external pure returns (uint256) {
        ILendMidnightRenewalCallback.CallbackData memory cbd =
            abi.decode(data, (ILendMidnightRenewalCallback.CallbackData));
        return cbd.feeRate;
    }

    function decodeCallbackFeeRecipient(bytes memory data) external pure returns (address) {
        ILendMidnightRenewalCallback.CallbackData memory cbd =
            abi.decode(data, (ILendMidnightRenewalCallback.CallbackData));
        return cbd.feeRecipient;
    }

    function decodeCallbackTick(bytes memory data) external pure returns (uint256) {
        ILendMidnightRenewalCallback.CallbackData memory cbd =
            abi.decode(data, (ILendMidnightRenewalCallback.CallbackData));
        return cbd.tick;
    }
}
