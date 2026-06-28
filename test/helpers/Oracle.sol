// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025 Morpho Association
pragma solidity ^0.8.0;

contract Oracle {
    uint256 public price = 1e36;

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }
}
