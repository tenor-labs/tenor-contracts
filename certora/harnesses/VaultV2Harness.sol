// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { VaultV2 } from "@vault-v2/VaultV2.sol";

contract VaultV2Harness is VaultV2 {
    constructor(address _owner, address _asset) VaultV2(_owner, _asset) {}

    // Minimal harness -- add wrappers only when needed

    /// Real immutable, bypassing the wildcard `_.asset()` summary (harness-exposer).
    function assetHarness() external view returns (address) {
        return asset;
    }
}
