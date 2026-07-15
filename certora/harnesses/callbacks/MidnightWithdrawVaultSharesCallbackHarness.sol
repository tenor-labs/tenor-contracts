// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightWithdrawVaultSharesCallback} from "@callbacks/MidnightWithdrawVaultSharesCallback.sol";
import {IMidnightWithdrawVaultSharesCallback} from "@callbacks/interfaces/IMidnightWithdrawVaultSharesCallback.sol";

contract MidnightWithdrawVaultSharesCallbackHarness is MidnightWithdrawVaultSharesCallback {
    constructor(address morphoMidnight)
        MidnightWithdrawVaultSharesCallback(morphoMidnight) {}

    function decodeCallbackVault(bytes memory data) external pure returns (address) {
        IMidnightWithdrawVaultSharesCallback.CallbackData memory cbd =
            abi.decode(data, (IMidnightWithdrawVaultSharesCallback.CallbackData));
        return cbd.vault;
    }

    function decodeCallbackCollateralIndex(bytes memory data) external pure returns (uint256) {
        IMidnightWithdrawVaultSharesCallback.CallbackData memory cbd =
            abi.decode(data, (IMidnightWithdrawVaultSharesCallback.CallbackData));
        return cbd.collateralIndex;
    }
}
