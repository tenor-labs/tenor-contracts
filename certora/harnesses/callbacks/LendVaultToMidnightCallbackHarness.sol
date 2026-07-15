// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LendVaultToMidnightCallback} from "@callbacks/LendVaultToMidnightCallback.sol";
import {ILendVaultToMidnightCallback} from "@callbacks/interfaces/ILendVaultToMidnightCallback.sol";

contract LendVaultToMidnightCallbackHarness is LendVaultToMidnightCallback {
    constructor(address morphoMidnight)
        LendVaultToMidnightCallback(morphoMidnight) {}

    function decodeCallbackFeeRecipient(bytes memory data) external pure returns (address) {
        ILendVaultToMidnightCallback.CallbackData memory cbd =
            abi.decode(data, (ILendVaultToMidnightCallback.CallbackData));
        return cbd.feeRecipient;
    }

    function decodeCallbackFeeRate(bytes memory data) external pure returns (uint256) {
        ILendVaultToMidnightCallback.CallbackData memory cbd =
            abi.decode(data, (ILendVaultToMidnightCallback.CallbackData));
        return cbd.feeRate;
    }

    function decodeCallbackVault(bytes memory data) external pure returns (address) {
        ILendVaultToMidnightCallback.CallbackData memory cbd =
            abi.decode(data, (ILendVaultToMidnightCallback.CallbackData));
        return cbd.vault;
    }

    function decodeCallbackTick(bytes memory data) external pure returns (uint256) {
        ILendVaultToMidnightCallback.CallbackData memory cbd =
            abi.decode(data, (ILendVaultToMidnightCallback.CallbackData));
        return cbd.tick;
    }
}
