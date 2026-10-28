// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {IRatifier} from "@midnight/interfaces/IRatifier.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";

/// @dev Ratifier that accepts every offer.
contract MockAcceptAllRatifier is IRatifier {
    function isRatified(Offer memory, bytes memory, address) external pure returns (bytes32) {
        return CALLBACK_SUCCESS;
    }
}
