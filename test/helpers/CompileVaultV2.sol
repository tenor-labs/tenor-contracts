// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultV2} from "@vault-v2/VaultV2.sol";
import {VaultV2Factory} from "@vault-v2/VaultV2Factory.sol";

/// @dev Compile-only shim to ensure `out/VaultV2.sol/VaultV2.json` and
///      `out/VaultV2Factory.sol/VaultV2Factory.json` exist for `deployCode(...)`-based tests.
contract CompileVaultV2 {
    function _unused(VaultV2, VaultV2Factory) external pure {}
}
