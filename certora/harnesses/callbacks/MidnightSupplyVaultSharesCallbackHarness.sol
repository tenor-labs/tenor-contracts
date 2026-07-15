// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightSupplyVaultSharesCallback} from "@callbacks/MidnightSupplyVaultSharesCallback.sol";
import {IMidnightSupplyVaultSharesCallback} from "@callbacks/interfaces/IMidnightSupplyVaultSharesCallback.sol";

contract MidnightSupplyVaultSharesCallbackHarness is MidnightSupplyVaultSharesCallback {
    constructor(address morphoMidnight)
        MidnightSupplyVaultSharesCallback(morphoMidnight) {}

    function decodeCallbackVault(bytes memory data) external pure returns (address) {
        IMidnightSupplyVaultSharesCallback.CallbackData memory cbd =
            abi.decode(data, (IMidnightSupplyVaultSharesCallback.CallbackData));
        return cbd.vault;
    }

    function decodeCallbackCollateralIndex(bytes memory data) external pure returns (uint256) {
        IMidnightSupplyVaultSharesCallback.CallbackData memory cbd =
            abi.decode(data, (IMidnightSupplyVaultSharesCallback.CallbackData));
        return cbd.collateralIndex;
    }

    function decodeCallbackAdditionalDepositPercent(bytes memory data) external pure returns (uint256) {
        IMidnightSupplyVaultSharesCallback.CallbackData memory cbd =
            abi.decode(data, (IMidnightSupplyVaultSharesCallback.CallbackData));
        return cbd.additionalDepositPercent;
    }
}
