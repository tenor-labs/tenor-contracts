// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IOracle} from "@midnight/interfaces/IOracle.sol";

/// @title MockValidationOracle
/// @notice Mock oracle for testing the OracleWithValidation contracts
contract MockValidationOracle is IOracle {
    uint256 private _price;
    bool private _shouldRevert;

    constructor(uint256 initialPrice) {
        _price = initialPrice;
    }

    function price() external view returns (uint256) {
        if (_shouldRevert) {
            revert("MockValidationOracle: forced revert");
        }
        return _price;
    }

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }

    function setShouldRevert(bool shouldRevert) external {
        _shouldRevert = shouldRevert;
    }
}
