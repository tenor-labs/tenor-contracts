// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Morpho } from "@morphoBlue/Morpho.sol";

contract MorphoHarness is Morpho {
    constructor(address newOwner) Morpho(newOwner) {}
}
