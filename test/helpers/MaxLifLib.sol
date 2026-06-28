// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

/// @dev Default liquidationCursor used to build CollateralParams in tests.
/// Midnight #992 made the LIF modular: markets now store a liquidationCursor (enabled by the
/// configurator) and Midnight derives maxLif = maxLif(lltv, liquidationCursor) internally, instead
/// of taking a precomputed maxLif field. 0.25e18 matches the former LIQUIDATION_CURSOR_LOW, so the
/// resulting maxLif (and every liquidation-amount assertion derived from it) is unchanged.
uint256 constant LIQUIDATION_CURSOR = 0.25e18;
