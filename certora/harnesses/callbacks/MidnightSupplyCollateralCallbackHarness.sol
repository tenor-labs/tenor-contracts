// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";

contract MidnightSupplyCollateralCallbackHarness is MidnightSupplyCollateralCallback {
    constructor(address morphoMidnight)
        MidnightSupplyCollateralCallback(morphoMidnight) {}

    function decodeCallbackMaxBorrowCapacityUsage(bytes memory data) external pure returns (uint256) {
        IMidnightSupplyCollateralCallback.CallbackData memory cbd =
            abi.decode(data, (IMidnightSupplyCollateralCallback.CallbackData));
        return cbd.maxBorrowCapacityUsage;
    }

    function decodeCallbackOfferSellerAssets(bytes memory data) external pure returns (uint256) {
        IMidnightSupplyCollateralCallback.CallbackData memory cbd =
            abi.decode(data, (IMidnightSupplyCollateralCallback.CallbackData));
        return cbd.offerSellerAssets;
    }

    function decodeCallbackAmountsLength(bytes memory data) external pure returns (uint256) {
        IMidnightSupplyCollateralCallback.CallbackData memory cbd =
            abi.decode(data, (IMidnightSupplyCollateralCallback.CallbackData));
        return cbd.amounts.length;
    }

    function decodeCallbackAmount(bytes memory data, uint256 i) external pure returns (uint256) {
        IMidnightSupplyCollateralCallback.CallbackData memory cbd =
            abi.decode(data, (IMidnightSupplyCollateralCallback.CallbackData));
        return cbd.amounts[i];
    }
}
