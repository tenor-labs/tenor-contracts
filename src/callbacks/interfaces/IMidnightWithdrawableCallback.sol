// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {IBuyCallback} from "@midnight/interfaces/ICallbacks.sol";
import {IRatifier} from "@midnight/interfaces/IRatifier.sol";

/// @title IMidnightWithdrawableCallback
/// @notice Interface of the standing par BUY offer filled from a Morpho Midnight market's withdrawable.
/// @dev Offer to take: maker = ratifier = callback = this contract, buy = true, tick = MAX_TICK, reduceOnly = false
/// (the buyer's credit always increases) and receiverIfMakerIsSeller = address(0) (enforced by Midnight). The taker
/// picks the other fields (market, group, start, expiry, maxUnits or maxAssets, continuousFeeCap); callbackData is
/// ignored.
/// @dev Par is the gross price: the seller receives units minus Midnight's settlement fee.
/// @dev consumed[this][group] is shared by every taker of a group and can never be reset, so takers should use
/// maxUnits = type(uint128).max or a taker-unique group, so that other fills in the group cannot exhaust their offer.
/// @dev In a gated market, every fill (lender exits included) needs the enterGate to let this contract increase
/// credit, and borrowers must be allowed to increase debt. Lender exits are never gated on debt.
interface IMidnightWithdrawableCallback is IBuyCallback, IRatifier {}
