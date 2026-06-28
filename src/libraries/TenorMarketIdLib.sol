// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {Market} from "@midnight/interfaces/IMidnight.sol";

/// @title TenorMarketIdLib
/// @notice Encodes the Tenor market ID, the identity of a lending Tenor market that survives renewal.
/// @dev A Tenor market is a (chainId, midnight, loanToken, collateralParams, rcfThreshold, enterGate, liquidatorGate)
/// tuple.
/// @dev Many Midnight markets (one per maturity) can share the same Tenor market.
/// @dev Vault-wrapped Tenor markets are identified by the vault address packed into the same slot.
library TenorMarketIdLib {
    /// @dev Returns the hash of a Midnight market with maturity excluded.
    function toTenorMarketId(Market memory market) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                market.chainId,
                market.midnight,
                market.loanToken,
                market.collateralParams,
                market.rcfThreshold,
                market.enterGate,
                market.liquidatorGate
            )
        );
    }

    /// @dev Encodes a vault address as a Tenor market ID (vault address in the high 20 bytes).
    function vaultToTenorMarketId(address vault) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(vault)) << 96);
    }

    /// @dev Recovers a vault address from a Tenor market ID created by vaultToTenorMarketId.
    function tenorMarketIdToVault(bytes32 tenorMarketId) internal pure returns (address) {
        return address(uint160(uint256(tenorMarketId) >> 96));
    }
}
