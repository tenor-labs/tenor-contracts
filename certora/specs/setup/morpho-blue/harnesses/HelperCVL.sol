// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Id, MarketParams } from "@morphoBlue/interfaces/IMorpho.sol";
import { MarketParamsLib } from "@morphoBlue/libraries/MarketParamsLib.sol";

contract HelperCVL {
    using MarketParamsLib for MarketParams;

    function assertOnFailure(bool success) external pure {
        require(success);
    }

    // UDVT wrapper: convert bytes32 to Id
    function toId(bytes32 raw) external pure returns (Id) {
        return Id.wrap(raw);
    }

    // UDVT wrapper: unwrap Id to bytes32
    function fromId(Id id) external pure returns (bytes32) {
        return Id.unwrap(id);
    }

    // Compute market Id from params
    function marketId(MarketParams memory marketParams) external pure returns (Id) {
        return marketParams.id();
    }
}
