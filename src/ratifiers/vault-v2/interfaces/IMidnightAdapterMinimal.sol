// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

/// @dev Mirrors `MarketData` in Morpho vault-v2's `src/adapters/midnight/interfaces/IMidnightAdapter.sol`. The field
/// order must match the adapter's storage struct, since `marketData` returns it ABI-encoded.
struct AdapterMarketData {
    uint128 netCredit;
    /// @dev WAD-scaled simple interest rate per second earned on the net credit, net of Midnight fees.
    uint64 netRate;
    uint40 maturity;
    uint8 index;
    bool forceSellable;
    bool forceRemoved;
    uint256 minForceSellPrice;
}

/// @title IMidnightAdapterMinimal
/// @notice The subset of Morpho Vault V2's MidnightAdapter read by MidnightAdapterCurveRatifier.
/// @dev Declared locally so that this repository does not compile vault-v2's pinned Midnight next to its own.
interface IMidnightAdapterMinimal {
    function parentVault() external view returns (address);
    function midnight() external view returns (address);
    function marketData(bytes32 marketId) external view returns (AdapterMarketData memory);
}

/// @title IVaultV2Roles
/// @notice The role getters of Morpho Vault V2 read by MidnightAdapterCurveRatifier.
interface IVaultV2Roles {
    function isAllocator(address account) external view returns (bool);
    function isSentinel(address account) external view returns (bool);
}
