// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Midnight } from "@midnight/Midnight.sol";
import { Market } from "@midnight/interfaces/IMidnight.sol";
import { IdLib } from "@midnight/libraries/IdLib.sol";

contract MidnightHarness is Midnight {
    // Minimal harness -- add wrappers only when needed.

    // Re-exposes market-id derivation for the `toId(e, market)` call sites in the specs.
    // IdLib.toId is summarized in setup/id_lib.spec, so this returns idLibToIdCVL.
    function toId(Market memory market) external view returns (bytes32) {
        return IdLib.toId(market);
    }

    // Exposes block.chainid for specs (CVL's env has no block.chainid field). Used by MC-MI-07 to
    // assert touchMarket's InvalidChainId gate (market.chainId == block.chainid). Called with the same
    // env as touchMarket, so it observes the same chain id.
    function blockChainId() external view returns (uint256) {
        return block.chainid;
    }
}
