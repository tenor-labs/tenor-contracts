/* ── MUTATION CollateralTransferLib #4 ──────────────────────────────
 * @desc:   Supplying zero to the target market leaves the borrower's target collateral unchanged while the source is still drained, so the renewalCanMigrateCollateralBetweenMarkets witness requiring the target collateral to rise becomes unsatisfiable.
 * @rules:  renewalCanMigrateCollateralBetweenMarkets
 * @conf:   certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_kill/renewalCanMigrateCollateralBetweenMarkets.conf
 * @status: killed
 * @target: src/libraries/CollateralTransferLib.sol
 * Was:     morphoMidnight.supplyCollateral(targetMarket, targetCollateralIndex, collateralToTransfer, borrower);
 * Now:     morphoMidnight.supplyCollateral(targetMarket, targetCollateralIndex, 0, borrower);
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {Market, IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {CallbackLib} from "./CallbackLib.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CollateralTransferLib
/// @notice Shared Midnight to Midnight collateral transfer logic for callback contracts.
/// @dev The calling callback must be authorized on Morpho Midnight by the borrower for both collateral withdrawal
/// (source market) and collateral supply (target market).
library CollateralTransferLib {
    using UtilsLib for uint256;
    using SafeERC20 for IERC20;
    using CallbackLib for Market;

    /// @dev Transfers collateral from the source to the target market, pro-rata to the repaid debt, rounded down;
    /// all on the final fill to avoid dust.
    /// @dev The final fill is detected by exact equality repaidUnits == sourceDebtBefore; with a nonzero
    /// fee, fills sized to the remaining offer capacity may never satisfy it, leaving residual debt and collateral
    /// on the source market until an exact-repayment fill occurs.
    /// @dev Only transfers tokens listed in both markets; source-only tokens are silently skipped and left on source.
    /// @return collateralTokens Token addresses, mirroring sourceMarket.collateralParams order.
    /// @return collateralAmounts Amount transferred per token; 0 if skipped, no source balance, or rounded to zero.
    function transferCollaterals(
        IMidnight morphoMidnight,
        Market memory sourceMarket,
        Market memory targetMarket,
        address borrower,
        bytes32 sourceMarketId,
        uint256 sourceDebtBefore,
        uint256 repaidUnits
    ) internal returns (address[] memory collateralTokens, uint256[] memory collateralAmounts) {
        uint256 collateralsLength = sourceMarket.collateralParams.length;
        collateralTokens = new address[](collateralsLength);
        collateralAmounts = new uint256[](collateralsLength);

        for (uint256 i = 0; i < collateralsLength;) {
            collateralTokens[i] = sourceMarket.collateralParams[i].token;
            (bool found, uint256 targetCollateralIndex) = targetMarket.findCollateral(collateralTokens[i]);

            if (found) {
                uint256 collateralToTransfer = morphoMidnight.collateral(sourceMarketId, borrower, i);
                if (sourceDebtBefore != repaidUnits) {
                    collateralToTransfer = collateralToTransfer.mulDivDown(repaidUnits, sourceDebtBefore);
                }
                if (collateralToTransfer > 0) {
                    morphoMidnight.withdrawCollateral(sourceMarket, i, collateralToTransfer, borrower, address(this));
                    IERC20(collateralTokens[i]).forceApprove(address(morphoMidnight), collateralToTransfer);
                    morphoMidnight.supplyCollateral(targetMarket, targetCollateralIndex, 0, borrower);  // MUTATION: rebased
                }
                collateralAmounts[i] = collateralToTransfer;
            }

            unchecked {
                ++i;
            }
        }
    }
}
