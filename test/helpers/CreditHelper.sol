// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";

/// @dev Test helper that computes credit-after-slashing via updatePositionView.
/// Safe to use in tests where no continuous fee is configured.
/// Returns 0 if the market hasn't been created yet.
function creditAfterSlashing(IMidnight morphoMidnight, bytes32 id, address user) view returns (uint256) {
    if (morphoMidnight.tickSpacing(id) == 0) return 0;
    Market memory market = morphoMidnight.toMarket(id);
    (uint128 newCredit,,) = morphoMidnight.updatePositionView(market, id, user);
    return uint256(newCredit);
}
