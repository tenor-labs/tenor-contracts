# Mutations — `CollateralTransferLib` (`src/libraries/CollateralTransferLib.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [1](#m-collateraltransferlib-1) | Subtracts 1 from the source collateral amount read on the closing fill, so the source position can never be fully drained; the renewalCanFullyCloseOldPosition witness requiring collateral to reach zero becomes unsatisfiable. | [`renewalCanFullyCloseOldPosition`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L200) (CB-CLOSE-1) |
| ✗ [3](#m-collateraltransferlib-3) | the inlined collateral loop withdraws collateralToTransfer-1 from source but supplies the full amount to target : moves MORE collateral than withdrawn (callback seed funds +1) | [`renewalCannotMoveMoreCollateralThanWithdrawn`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L131) (CB-FINAL-4) |
| ✗ [4](#m-collateraltransferlib-4) | Supplying zero to the target market leaves the borrower's target collateral unchanged while the source is still drained, so the renewalCanMigrateCollateralBetweenMarkets witness requiring the target collateral to rise becomes unsatisfiable. | [`renewalCanMigrateCollateralBetweenMarkets`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L178) |

<a id="m-collateraltransferlib-1"></a>
## ✗ #1 — Subtracts 1 from the source collateral amount read on the closing fill, so the source position can never be fully drained; the renewalCanFullyCloseOldPosition witness requiring collateral to reach zero becomes unsatisfiable.

- **Mutant:** [`1.sol`](1.sol)
- **Caught by:** [`renewalCanFullyCloseOldPosition`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L200) (CB-CLOSE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_kill/renewalCanFullyCloseOldPosition.conf --rule renewalCanFullyCloseOldPosition`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh CollateralTransferLib 1`

```diff
--- a/src/libraries/CollateralTransferLib.sol
+++ b/src/libraries/CollateralTransferLib.sol
@@ -42,7 +42,7 @@
             (bool found, uint256 targetCollateralIndex) = targetMarket.findCollateral(collateralTokens[i]);
 
             if (found) {
-                uint256 collateralToTransfer = morphoMidnight.collateral(sourceMarketId, borrower, i);
+                uint256 collateralToTransfer = morphoMidnight.collateral(sourceMarketId, borrower, i) - 1;  // MUTATION: under-read closing collateral
                 if (sourceDebtBefore != repaidUnits) {
                     collateralToTransfer = collateralToTransfer.mulDivDown(repaidUnits, sourceDebtBefore);
                 }
```

<a id="m-collateraltransferlib-3"></a>
## ✗ #3 — the inlined collateral loop withdraws collateralToTransfer-1 from source but supplies the full amount to target : moves MORE collateral than withdrawn (callback seed funds +1)

- **Mutant:** [`3.sol`](3.sol)
- **Caught by:** [`renewalCannotMoveMoreCollateralThanWithdrawn`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L131) (CB-FINAL-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_kill/renewalCannotMoveMoreCollateralThanWithdrawn.conf --rule renewalCannotMoveMoreCollateralThanWithdrawn`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh CollateralTransferLib 3`

```diff
--- a/src/libraries/CollateralTransferLib.sol
+++ b/src/libraries/CollateralTransferLib.sol
@@ -47,7 +47,7 @@
                     collateralToTransfer = collateralToTransfer.mulDivDown(repaidUnits, sourceDebtBefore);
                 }
                 if (collateralToTransfer > 0) {
-                    morphoMidnight.withdrawCollateral(sourceMarket, i, collateralToTransfer, borrower, address(this));
+                    morphoMidnight.withdrawCollateral(sourceMarket, i, collateralToTransfer - 1, borrower, address(this));  // MUTATION: rebased
                     IERC20(collateralTokens[i]).forceApprove(address(morphoMidnight), collateralToTransfer);
                     morphoMidnight.supplyCollateral(targetMarket, targetCollateralIndex, collateralToTransfer, borrower);
                 }
```

<a id="m-collateraltransferlib-4"></a>
## ✗ #4 — Supplying zero to the target market leaves the borrower's target collateral unchanged while the source is still drained, so the renewalCanMigrateCollateralBetweenMarkets witness requiring the target collateral to rise becomes unsatisfiable.

- **Mutant:** [`4.sol`](4.sol)
- **Caught by:** [`renewalCanMigrateCollateralBetweenMarkets`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L178)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_kill/renewalCanMigrateCollateralBetweenMarkets.conf --rule renewalCanMigrateCollateralBetweenMarkets`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh CollateralTransferLib 4`

```diff
--- a/src/libraries/CollateralTransferLib.sol
+++ b/src/libraries/CollateralTransferLib.sol
@@ -49,7 +49,7 @@
                 if (collateralToTransfer > 0) {
                     morphoMidnight.withdrawCollateral(sourceMarket, i, collateralToTransfer, borrower, address(this));
                     IERC20(collateralTokens[i]).forceApprove(address(morphoMidnight), collateralToTransfer);
-                    morphoMidnight.supplyCollateral(targetMarket, targetCollateralIndex, collateralToTransfer, borrower);
+                    morphoMidnight.supplyCollateral(targetMarket, targetCollateralIndex, 0, borrower);  // MUTATION: rebased
                 }
                 collateralAmounts[i] = collateralToTransfer;
             }
```

