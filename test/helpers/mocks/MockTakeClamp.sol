// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";

contract MockTakeClamp is ITakeClamp {
    uint256 public maxUnitsReturn;

    constructor(uint256 _maxUnits) {
        maxUnitsReturn = _maxUnits;
    }

    function maxUnits(Offer calldata, bytes calldata) external view returns (uint256) {
        return maxUnitsReturn;
    }
}
