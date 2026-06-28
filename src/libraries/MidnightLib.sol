// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {IMidnight, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {IOracle} from "@midnight/interfaces/IOracle.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {ORACLE_PRICE_SCALE, WAD} from "@midnight/libraries/ConstantsLib.sol";

/// @title MidnightLib
/// @notice View helpers that extend the Morpho Midnight contract.
/// @dev Intended for using MidnightLib for IMidnight.
library MidnightLib {
    using UtilsLib for uint256;

    /// @dev Returns the LLTV-weighted collateral value (maxDebt) of borrower, rounded down: the maximum debt the
    /// borrower's collateral can support.
    /// @dev Mirrors Morpho Midnight's isHealthy() logic:
    /// maxDebt = sum(collateral * price / ORACLE_PRICE_SCALE * lltv / WAD).
    /// @param collaterals The collateral config array from the market.
    function computeMaxDebt(
        IMidnight morphoMidnight,
        bytes32 marketId,
        address borrower,
        CollateralParams[] memory collaterals
    ) internal view returns (uint256 maxDebt) {
        uint256[] memory amounts = new uint256[](collaterals.length);
        uint256 bitmap = morphoMidnight.collateralBitmap(marketId, borrower);
        for (uint256 i = 0; bitmap != 0; i++) {
            if (bitmap & (1 << i) != 0) {
                amounts[i] = morphoMidnight.collateral(marketId, borrower, i);
                bitmap ^= (1 << i);
            }
        }
        return computeMaxDebtFromAmounts(collaterals, amounts);
    }

    /// @dev Returns the LLTV-weighted collateral value (maxDebt) from explicit amounts, rounded down.
    /// @dev Same math as computeMaxDebt but with caller-supplied amounts instead of onchain balances.
    /// @param amounts The collateral amounts, indexed by collateral slot (same indexing as collaterals).
    function computeMaxDebtFromAmounts(CollateralParams[] memory collaterals, uint256[] memory amounts)
        internal
        view
        returns (uint256 maxDebt)
    {
        return computeMaxDebtFromAmounts(collaterals, amounts, new uint256[](collaterals.length));
    }

    /// @dev Returns maxDebt from explicit amounts, rounded down, lazily fetching and caching oracle prices.
    /// @dev Mutates prices in place: unfetched slots (value 0) are populated on first access.
    /// @dev Callers can pass the same prices array across multiple calls to avoid redundant oracle reads.
    /// @dev Note that 0 is the "not yet fetched" sentinel: if an oracle legitimately returns price 0, it is
    /// re-fetched on every call instead of cached.
    function computeMaxDebtFromAmounts(
        CollateralParams[] memory collaterals,
        uint256[] memory amounts,
        uint256[] memory prices
    ) internal view returns (uint256 maxDebt) {
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] == 0) continue;
            if (prices[i] == 0) prices[i] = IOracle(collaterals[i].oracle).price();
            maxDebt += amounts[i].mulDivDown(prices[i], ORACLE_PRICE_SCALE).mulDivDown(collaterals[i].lltv, WAD);
        }
    }
}
