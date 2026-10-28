// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {ITakeClamp} from "../interfaces/ITakeClamp.sol";
import {IMidnight, Offer} from "@midnight/interfaces/IMidnight.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";

/// @title MidnightWithdrawableClamp
/// @notice Clamp that bounds takeUnits for MidnightWithdrawableCallback's par BUY offer.
/// @dev Bounds units by the market's withdrawable, which the callback withdraws on every fill.
/// @dev Derives the market id from offer.market instead of a pre-computed clampData marketId, so the bound can never
/// be read from the wrong market. clampData is unused.
/// @dev No zero-amount guard: the callback accepts zero-unit fills as no-ops.
/// @dev The taker (seller) is responsible for constraining on their own health and debt; borrows after maturity
/// revert at Midnight.
/// @dev Offer consumption is checked structurally by TenorRouter.
contract MidnightWithdrawableClamp is ITakeClamp {
    /// @notice The Morpho Midnight protocol contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    constructor(IMidnight morphoMidnight) {
        MORPHO_MIDNIGHT = morphoMidnight;
    }

    /// @inheritdoc ITakeClamp
    function maxUnits(
        Offer calldata offer,
        bytes calldata /* clampData */
    )
        external
        view
        override
        returns (uint256 maxUnits)
    {
        // BUY-only: the paired callback is onBuy.
        if (!offer.buy) return 0;

        maxUnits = MORPHO_MIDNIGHT.withdrawable(IdLib.toId(offer.market));
    }
}
