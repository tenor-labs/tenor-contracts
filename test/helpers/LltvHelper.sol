// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {LIQUIDATION_CURSOR} from "./MaxLifLib.sol";

/// @dev Registers the standard Morpho Blue LLTV tiers and the default liquidationCursor on a freshly
/// deployed Midnight. Midnight made both modular: an LLTV tier must be enabled via `enableLltv` and a
/// liquidationCursor via `enableLiquidationCursor` (configurator only) before a market using them can be
/// created. Must be called by the deployer (the configurator) right after `new Midnight()`.
/// @dev The cursor is `LIQUIDATION_CURSOR` (0.25e18, see MaxLifLib), deliberately NOT Midnight's own
/// BaseTest value (0.3e18): 0.25e18 keeps the derived maxLif identical to the pre-#992 value so the
/// migrated liquidation-amount assertions stay numerically unchanged. Do not "align" it to BaseTest.
function enableDefaultLltvs(IMidnight midnight) {
    uint256[9] memory tiers =
        [uint256(0.385e18), 0.625e18, 0.77e18, 0.86e18, 0.915e18, 0.945e18, 0.965e18, 0.98e18, 1e18];
    for (uint256 i = 0; i < tiers.length; i++) {
        midnight.enableLltv(tiers[i]);
    }
    midnight.enableLiquidationCursor(LIQUIDATION_CURSOR);
}
