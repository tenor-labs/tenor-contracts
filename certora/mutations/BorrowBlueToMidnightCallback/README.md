# Mutations — `BorrowBlueToMidnightCallback` (`src/callbacks/BorrowBlueToMidnightCallback.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [1](#m-borrowbluetomidnightcallback-1) | auth guard flipped (!= -> ==) | [`callbackRevertsForNonMidnightCaller`](../../specs/callbacks/callbacks.spec#L80) (CB-AUTH-1) |
| ✗ [2](#m-borrowbluetomidnightcallback-2) | supplyCollateral amount forced to 0: collateral never lands on Midnight, migration cannot move it | [`migrationCanMoveCollateralBlueToMidnight`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L137) |
| ✗ [3](#m-borrowbluetomidnightcallback-3) | onSell final-fill collateral blueCollateral -1 : debt fully clears but 1 wei collateral remains (coupling broken) | [`clearingOldDebtAlsoEmptiesOldCollateral`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L75) (CB-FINAL-2) |
| ✗ [4](#m-borrowbluetomidnightcallback-4) | onSell Midnight supply amount collateralMigrated -1 : mnIn = blueOut-1, breaks 1:1 conservation | [`migrationConservesMigratedCollateral`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L115) (CB-DIR-1) |
| ✗ [9](#m-borrowbluetomidnightcallback-9) | Supplying collateral to the new Midnight market is replaced by withdrawing it, so the Midnight collateral shrinks instead of growing and the rule requiring migration to only add new-market collateral produces a counterexample. | [`migrationOnlyAddsNewMidnightCollateral`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L96) (CB-DIR-1) |
| ✗ [12](#m-borrowbluetomidnightcallback-12) | Changing the excess-repayment check from greater-than to greater-or-equal makes the final fill (where repayBudget equals the debt) revert, so the witness showing all Blue collateral fully withdrawn can no longer be produced. | [`fullCollateralMigrationClearsAllOldDebt__satisfy`](../../specs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/many_satisfy.spec#L220) (CB-CLOSE-2) |
| ✗ [14](#m-borrowbluetomidnightcallback-14) | Flipping the source-market loan-token check from not-equal to equal accepts a source market whose loan token differs from the offer's, so the rule requiring a mismatched loan token to revert produces a counterexample. | [`sourceLoanTokenMismatchReverts`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L286) |
| ✗ [15](#m-borrowbluetomidnightcallback-15) | Replacing the Blue repay with a borrow makes the seller's old Blue debt increase instead of decrease, so the rule requiring migration to only reduce the old Blue debt produces a counterexample. | [`migrationOnlyReducesOldBlueDebt`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L15) (CB-V1-REP-1) |
| ✗ [16](#m-borrowbluetomidnightcallback-16) | Replacing the Blue collateral withdrawal with a supply makes the seller's old Blue collateral grow instead of shrink, so the rule requiring migration to only withdraw old Blue collateral produces a counterexample. | [`migrationOnlyWithdrawsOldBlueCollateral`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L33) (CB-DIR-1) |
| ✗ [18](#m-borrowbluetomidnightcallback-18) | Doubling the amount transferred to the fee recipient makes the borrower pay twice the intended fee, so the rule bounding the borrower fee by its interest share produces a counterexample. | [`borrowerFeeBoundedByInterestShare`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L181) (CB-RATE-1) |
| ✗ [20](#m-borrowbluetomidnightcallback-20) | Flipping the caller check from not-equal to equal makes onSell revert whenever Midnight (its only legitimate caller) invokes it, so take() always reverts and the witness that migration reduces old debt on at most one market can no longer be produced. | [`migrationReducesOldDebtOnAtMostOneMarket__satisfy`](../../specs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/many_satisfy.spec#L115) (CB-DIR-1) |
| ✗ [21](#m-borrowbluetomidnightcallback-21) | Migrating one wei less than the full Blue collateral on the final fill always leaves a wei behind, so the seller's collateral never reaches zero and the witness showing the old position can be fully closed can no longer be produced. | [`migrationCanFullyCloseOldPosition`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L158) (CB-CLOSE-1) |
| ✗ [22](#m-borrowbluetomidnightcallback-22) | onSell receiver guard flipped (!= -> ==): receiver!=callback no longer reverts. Caught by receiverNotCallbackReverts (CLB-BBM-22, receiverNotCallback => reverted via callbackCallWithRevert) — the flip leaves a non-reverting receiver!=callback trace, assert violated. | [`receiverNotCallbackReverts`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L272) |

<a id="m-borrowbluetomidnightcallback-1"></a>
## ✗ #1 — auth guard flipped (!= -> ==)

- **Mutant:** [`1.sol`](1.sol)
- **Caught by:** [`callbackRevertsForNonMidnightCaller`](../../specs/callbacks/callbacks.spec#L80) (CB-AUTH-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/callbackRevertsForNonMidnightCaller.conf --rule callbackRevertsForNonMidnightCaller`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 1`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -52,7 +52,7 @@
         address receiver,
         bytes memory data
     ) external override returns (bytes32) {
-        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
+        if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();  // MUTATION: rebased
         if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
```

<a id="m-borrowbluetomidnightcallback-2"></a>
## ✗ #2 — supplyCollateral amount forced to 0: collateral never lands on Midnight, migration cannot move it

- **Mutant:** [`2.sol`](2.sol)
- **Caught by:** [`migrationCanMoveCollateralBlueToMidnight`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L137)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/migrationCanMoveCollateralBlueToMidnight.conf --rule migrationCanMoveCollateralBlueToMidnight`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 2`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -89,7 +89,7 @@
         if (collateralMigrated > 0) {
             MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
             IERC20(sourceMarketParams.collateralToken).forceApprove(address(MORPHO_MIDNIGHT), collateralMigrated);
-            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated, seller);
+            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, 0, seller);  // MUTATION: rebased
         }
 
         emit BorrowMigratedBlueToMidnight(
```

<a id="m-borrowbluetomidnightcallback-3"></a>
## ✗ #3 — onSell final-fill collateral blueCollateral -1 : debt fully clears but 1 wei collateral remains (coupling broken)

- **Mutant:** [`3.sol`](3.sol)
- **Caught by:** [`clearingOldDebtAlsoEmptiesOldCollateral`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L75) (CB-FINAL-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/clearingOldDebtAlsoEmptiesOldCollateral.conf --rule clearingOldDebtAlsoEmptiesOldCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 3`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -84,7 +84,7 @@
             MORPHO_BLUE.repay(sourceMarketParams, repayBudget, 0, seller, "");
         }
 
-        uint256 collateralMigrated = isFinalFill ? blueCollateral : blueCollateral.mulDivDown(repayBudget, blueDebt);
+        uint256 collateralMigrated = isFinalFill ? blueCollateral - 1 : blueCollateral.mulDivDown(repayBudget, blueDebt);  // MUTATION: rebased
 
         if (collateralMigrated > 0) {
             MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
```

<a id="m-borrowbluetomidnightcallback-4"></a>
## ✗ #4 — onSell Midnight supply amount collateralMigrated -1 : mnIn = blueOut-1, breaks 1:1 conservation

- **Mutant:** [`4.sol`](4.sol)
- **Caught by:** [`migrationConservesMigratedCollateral`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L115) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/migrationConservesMigratedCollateral.conf --rule migrationConservesMigratedCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 4`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -89,7 +89,7 @@
         if (collateralMigrated > 0) {
             MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
             IERC20(sourceMarketParams.collateralToken).forceApprove(address(MORPHO_MIDNIGHT), collateralMigrated);
-            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated, seller);
+            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated - 1, seller);  // MUTATION: rebased
         }
 
         emit BorrowMigratedBlueToMidnight(
```

<a id="m-borrowbluetomidnightcallback-9"></a>
## ✗ #9 — Supplying collateral to the new Midnight market is replaced by withdrawing it, so the Midnight collateral shrinks instead of growing and the rule requiring migration to only add new-market collateral produces a counterexample.

- **Mutant:** [`9.sol`](9.sol)
- **Caught by:** [`migrationOnlyAddsNewMidnightCollateral`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L96) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/perf/migrationOnlyAddsNewMidnightCollateral.conf --rule migrationOnlyAddsNewMidnightCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 9`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -89,7 +89,7 @@
         if (collateralMigrated > 0) {
             MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
             IERC20(sourceMarketParams.collateralToken).forceApprove(address(MORPHO_MIDNIGHT), collateralMigrated);
-            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated, seller);
+            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, seller, address(this));  // MUTATION: rebased
         }
 
         emit BorrowMigratedBlueToMidnight(
```

<a id="m-borrowbluetomidnightcallback-12"></a>
## ✗ #12 — Changing the excess-repayment check from greater-than to greater-or-equal makes the final fill (where repayBudget equals the debt) revert, so the witness showing all Blue collateral fully withdrawn can no longer be produced.

- **Mutant:** [`12.sol`](12.sol)
- **Caught by:** [`fullCollateralMigrationClearsAllOldDebt__satisfy`](../../specs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/many_satisfy.spec#L220) (CB-CLOSE-2)
- **Channel:** `debug_satisfy` satisfy-twin — the mutation makes `take()` revert, so the witness becomes UNSAT (**VIOLATED** = mutant **Killed**); the clean-`src/` witness is proven **SUCCESS** (two-gate).
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/perf_kill_satisfy/fullCollateralMigrationClearsAllOldDebt.conf --rule fullCollateralMigrationClearsAllOldDebt__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 12`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -74,7 +74,7 @@
         }
         uint256 repayBudget = sellerAssets - fee;
 
-        if (repayBudget > blueDebt) revert CallbackLib.ExcessRepayment();
+        if (repayBudget >= blueDebt) revert CallbackLib.ExcessRepayment();  // MUTATION: rebased
         IERC20(loanToken).forceApprove(address(MORPHO_BLUE), repayBudget);
 
         bool isFinalFill = repayBudget == blueDebt;
```

<a id="m-borrowbluetomidnightcallback-14"></a>
## ✗ #14 — Flipping the source-market loan-token check from not-equal to equal accepts a source market whose loan token differs from the offer's, so the rule requiring a mismatched loan token to revert produces a counterexample.

- **Mutant:** [`14.sol`](14.sol)
- **Caught by:** [`sourceLoanTokenMismatchReverts`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L286)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/sourceLoanTokenMismatchReverts.conf --rule sourceLoanTokenMismatchReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 14`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -59,7 +59,7 @@
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
         MarketParams memory sourceMarketParams = callbackData.sourceMarketParams;
         address loanToken = market.loanToken;
-        if (sourceMarketParams.loanToken != loanToken) revert CallbackLib.TokenMismatch();
+        if (sourceMarketParams.loanToken == loanToken) revert CallbackLib.TokenMismatch();  // MUTATION: rebased
         (bool found, uint256 collateralIndex) = market.findCollateral(sourceMarketParams.collateralToken);
         if (!found) revert CallbackLib.TokenMismatch();
 
```

<a id="m-borrowbluetomidnightcallback-15"></a>
## ✗ #15 — Replacing the Blue repay with a borrow makes the seller's old Blue debt increase instead of decrease, so the rule requiring migration to only reduce the old Blue debt produces a counterexample.

- **Mutant:** [`15.sol`](15.sol)
- **Caught by:** [`migrationOnlyReducesOldBlueDebt`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L15) (CB-V1-REP-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/perf/migrationOnlyReducesOldBlueDebt.conf --rule migrationOnlyReducesOldBlueDebt`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 15`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -81,7 +81,7 @@
         if (isFinalFill) {
             MORPHO_BLUE.repay(sourceMarketParams, 0, bluePosition.borrowShares, seller, "");
         } else {
-            MORPHO_BLUE.repay(sourceMarketParams, repayBudget, 0, seller, "");
+            MORPHO_BLUE.borrow(sourceMarketParams, repayBudget, 0, seller, seller); // MUTATION: rebased
         }
 
         uint256 collateralMigrated = isFinalFill ? blueCollateral : blueCollateral.mulDivDown(repayBudget, blueDebt);
```

<a id="m-borrowbluetomidnightcallback-16"></a>
## ✗ #16 — Replacing the Blue collateral withdrawal with a supply makes the seller's old Blue collateral grow instead of shrink, so the rule requiring migration to only withdraw old Blue collateral produces a counterexample.

- **Mutant:** [`16.sol`](16.sol)
- **Caught by:** [`migrationOnlyWithdrawsOldBlueCollateral`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L33) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/perf/migrationOnlyWithdrawsOldBlueCollateral.conf --rule migrationOnlyWithdrawsOldBlueCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 16`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -87,7 +87,7 @@
         uint256 collateralMigrated = isFinalFill ? blueCollateral : blueCollateral.mulDivDown(repayBudget, blueDebt);
 
         if (collateralMigrated > 0) {
-            MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
+            MORPHO_BLUE.supplyCollateral(sourceMarketParams, collateralMigrated, seller, ""); // MUTATION: rebased
             IERC20(sourceMarketParams.collateralToken).forceApprove(address(MORPHO_MIDNIGHT), collateralMigrated);
             MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated, seller);
         }
```

<a id="m-borrowbluetomidnightcallback-18"></a>
## ✗ #18 — Doubling the amount transferred to the fee recipient makes the borrower pay twice the intended fee, so the rule bounding the borrower fee by its interest share produces a counterexample.

- **Mutant:** [`18.sol`](18.sol)
- **Caught by:** [`borrowerFeeBoundedByInterestShare`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L181) (CB-RATE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/perf/borrowerFeeBoundedByInterestShare.conf --rule borrowerFeeBoundedByInterestShare`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 18`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -70,7 +70,7 @@
 
         uint256 fee = CallbackLib.sellerFeeFromTick(callbackData.tick, callbackData.feeRate, units, sellerAssets);
         if (fee > 0) {
-            SafeTransferLib.safeTransfer(loanToken, callbackData.feeRecipient, fee);
+            SafeTransferLib.safeTransfer(loanToken, callbackData.feeRecipient, fee * 2); // MUTATION: rebased
         }
         uint256 repayBudget = sellerAssets - fee;
 
```

<a id="m-borrowbluetomidnightcallback-20"></a>
## ✗ #20 — Flipping the caller check from not-equal to equal makes onSell revert whenever Midnight (its only legitimate caller) invokes it, so take() always reverts and the witness that migration reduces old debt on at most one market can no longer be produced.

- **Mutant:** [`20.sol`](20.sol)
- **Caught by:** [`migrationReducesOldDebtOnAtMostOneMarket__satisfy`](../../specs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/many_satisfy.spec#L115) (CB-DIR-1)
- **Channel:** `debug_satisfy` satisfy-twin — the mutation makes `take()` revert, so the witness becomes UNSAT (**VIOLATED** = mutant **Killed**); the clean-`src/` witness is proven **SUCCESS** (two-gate).
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/migrationReducesOldDebtOnAtMostOneMarket.conf --rule migrationReducesOldDebtOnAtMostOneMarket__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 20`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -52,7 +52,7 @@
         address receiver,
         bytes memory data
     ) external override returns (bytes32) {
-        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
+        if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();  // MUTATION: rebased
         if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
```

<a id="m-borrowbluetomidnightcallback-21"></a>
## ✗ #21 — Migrating one wei less than the full Blue collateral on the final fill always leaves a wei behind, so the seller's collateral never reaches zero and the witness showing the old position can be fully closed can no longer be produced.

- **Mutant:** [`21.sol`](21.sol)
- **Caught by:** [`migrationCanFullyCloseOldPosition`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L158) (CB-CLOSE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/perf_kill/migrationCanFullyCloseOldPosition.conf --rule migrationCanFullyCloseOldPosition`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 21`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -84,7 +84,7 @@
             MORPHO_BLUE.repay(sourceMarketParams, repayBudget, 0, seller, "");
         }
 
-        uint256 collateralMigrated = isFinalFill ? blueCollateral : blueCollateral.mulDivDown(repayBudget, blueDebt);
+        uint256 collateralMigrated = isFinalFill ? blueCollateral - 1 : blueCollateral.mulDivDown(repayBudget, blueDebt);  // MUTATION: rebased
 
         if (collateralMigrated > 0) {
             MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
```

<a id="m-borrowbluetomidnightcallback-22"></a>
## ✗ #22 — onSell receiver guard flipped (!= -> ==): receiver!=callback no longer reverts. Caught by receiverNotCallbackReverts (CLB-BBM-22, receiverNotCallback => reverted via callbackCallWithRevert) — the flip leaves a non-reverting receiver!=callback trace, assert violated.

- **Mutant:** [`22.sol`](22.sol)
- **Caught by:** [`receiverNotCallbackReverts`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L272)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/receiverNotCallbackReverts.conf --rule receiverNotCallbackReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 22`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -53,7 +53,7 @@
         bytes memory data
     ) external override returns (bytes32) {
         if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
-        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
+        if (receiver == address(this)) revert CallbackLib.InvalidReceiver();  // MUTATION: rebased
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
```

