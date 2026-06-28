// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {Offer} from "@midnight/interfaces/IMidnight.sol";

/// @title ITakeClamp
/// @notice Interface of the view-only clamp returning a maximum takeUnits value the router min's with its own.
/// @dev Clamps must not check offer consumption (consumed/remaining capacity); that constraint is enforced
/// structurally by TenorRouter._capTakeUnits() via TakeMathLib.getOfferRemaining() before the clamp is called.
/// @dev Clamps only express domain-specific constraints (balances, allowances, health, etc.).
/// @dev A clamp's output is not an executability guarantee: clamps inspect economic state only, so revoked
/// Midnight authorizations or token approvals can still make a positively-quoted fill revert.
interface ITakeClamp {
    /// @notice Returns the maximum takeUnits for this action given the offer and clamp-specific data.
    /// @param offer The offer being taken.
    /// @param clampData Arbitrary clamp-specific data encoded by the caller.
    /// @return maxUnits The maximum takeUnits allowed by this clamp.
    function maxUnits(Offer calldata offer, bytes calldata clampData) external view returns (uint256 maxUnits);
}
