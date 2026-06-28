// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {TenorRouter} from "../../../src/router/TenorRouter.sol";

contract MockTenorRouter is TenorRouter {
    constructor(address morphoMidnight) TenorRouter(morphoMidnight) {}
}
