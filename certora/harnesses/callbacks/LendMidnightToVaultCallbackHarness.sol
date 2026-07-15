// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LendMidnightToVaultCallback} from "@callbacks/LendMidnightToVaultCallback.sol";
import {ILendMidnightToVaultCallback} from "@callbacks/interfaces/ILendMidnightToVaultCallback.sol";

contract LendMidnightToVaultCallbackHarness is LendMidnightToVaultCallback {
    constructor(address morphoMidnight)
        LendMidnightToVaultCallback(morphoMidnight) {}

    function decodeCallbackFeeRecipient(bytes memory data) external pure returns (address) {
        ILendMidnightToVaultCallback.CallbackData memory cbd =
            abi.decode(data, (ILendMidnightToVaultCallback.CallbackData));
        return cbd.feeRecipient;
    }

    function decodeCallbackFeeRate(bytes memory data) external pure returns (uint256) {
        ILendMidnightToVaultCallback.CallbackData memory cbd =
            abi.decode(data, (ILendMidnightToVaultCallback.CallbackData));
        return cbd.feeRate;
    }

    function decodeCallbackVault(bytes memory data) external pure returns (address) {
        ILendMidnightToVaultCallback.CallbackData memory cbd =
            abi.decode(data, (ILendMidnightToVaultCallback.CallbackData));
        return cbd.vault;
    }
}
