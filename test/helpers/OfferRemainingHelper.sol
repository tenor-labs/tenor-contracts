// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IMidnight, Offer} from "@midnight/interfaces/IMidnight.sol";
import {TakeMathLib} from "../../src/libraries/TakeMathLib.sol";

/// @notice Test helper: wraps TakeMathLib.getOfferRemaining (which requires calldata Offer)
///         with an external function so fuzz tests can call it with memory Offers.
contract OfferRemainingHelper {
    function getOfferRemaining(IMidnight morphoMidnight, Offer calldata offer, bytes32 marketId)
        external
        view
        returns (uint256)
    {
        return TakeMathLib.getOfferRemaining(morphoMidnight, offer, marketId);
    }
}
