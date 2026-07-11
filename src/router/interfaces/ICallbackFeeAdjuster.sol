// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {Offer} from "@midnight/interfaces/IMidnight.sol";

/// @title ICallbackFeeAdjuster
/// @notice Interface of the router-side view hooks consulted by `TenorRouter` before and after each dispatch to bridge
/// raw Midnight amounts and the effective, fee-adjusted amounts the initiator experiences.
/// @dev Both hooks tighten the router's accounting toward the initiator. The callback fee always lands on the
/// initiator's own asset side (`initiatorIsBuyer`): the initiator is always the taker, so
/// `initiatorIsBuyer == !offer.buy`.
/// @dev `afterDispatch()` returns a non-negative fee the router books in the initiator-worsening direction (buyer pays
/// more / seller receives less). The sign is fixed at the router, so an adjuster can only tighten accounting, never
/// weaken it.
interface ICallbackFeeAdjuster {
    /// @notice Pre-dispatch sizer: caps `takeUnits` so the effective `fillIndex` fill stays within `remainingBudget`.
    /// @dev The cap is conservative: it may underfill by a rounding tolerance but never overshoots.
    /// @param offer The offer about to be taken.
    /// @param fillIndex The fill dimension (0=BUYER_ASSETS, 1=SELLER_ASSETS, 2=UNITS).
    /// @param remainingBudget The remaining fill budget in the `fillIndex` dimension; at most `type(uint128).max`.
    /// @param data Arbitrary adjuster-specific data encoded by the caller.
    /// @return takeUnits The maximum market units to take.
    function beforeDispatch(Offer calldata offer, uint8 fillIndex, uint256 remainingBudget, bytes calldata data)
        external
        view
        returns (uint256 takeUnits);
    /// @notice Post-dispatch reporter: the fee the callback charges on the initiator's side of the raw amounts.
    /// @param offer The offer that was taken.
    /// @param initiatorIsBuyer The initiator's asset side: true means the fee lands on `buyerAssets`, false on
    /// `sellerAssets`.
    /// @param buyerAssets The raw buyer assets returned by the dispatch.
    /// @param sellerAssets The raw seller assets returned by the dispatch.
    /// @param units The market units returned by the dispatch.
    /// @param data Arbitrary adjuster-specific data encoded by the caller.
    /// @return feeAmount The fee charged by the callback, in asset terms.
    function afterDispatch(
        Offer calldata offer,
        bool initiatorIsBuyer,
        uint256 buyerAssets,
        uint256 sellerAssets,
        uint256 units,
        bytes calldata data
    ) external view returns (uint256 feeAmount);
}
