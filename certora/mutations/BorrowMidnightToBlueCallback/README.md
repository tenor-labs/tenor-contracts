# Mutations — `BorrowMidnightToBlueCallback` (`src/callbacks/BorrowMidnightToBlueCallback.sol`)

Each numbered file is the contract above with **one** line broken (#18 instead breaks a line of the shared `src/libraries/CallbackLib.sol`, exercised through this callback's scene); the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [8](#m-borrowmidnighttobluecallback-8) | Commenting out the borrow call prevents Blue debt from being opened, making the satisfy clause impossible to prove (cannot demonstrate that blueSharesAfter > sharesBefore). | [`migrationCanOpenNewBlueDebt`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L136) |
| ✗ [9](#m-borrowmidnighttobluecallback-9) | withdrawCollateral commented out: collateral never leaves Midnight, migration cannot move it | [`migrationCanMoveCollateralMidnightToBlue`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L154) |
| ✗ [10](#m-borrowmidnighttobluecallback-10) | Setting the amount withdrawn from Midnight to zero leaves the borrower's old collateral in place, so no fill can ever fully close the old position and the rule's witness becomes unsatisfiable. | [`migrationCanFullyCloseOldPosition`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L175) (CB-CLOSE-1) |
| ✗ [18](#m-borrowmidnighttobluecallback-18) | fee-cap guard inverted (> -> <): every legal below-cap feeRate now reverts while an above-cap rate is accepted — percentageFeeRateAboveCapReverts (aboveCap => reverted) is violated. | [`percentageFeeRateAboveCapReverts`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L197) |
| ✗ [20](#m-borrowmidnighttobluecallback-20) | Replacing the Midnight withdrawCollateral call with supplyCollateral makes the borrower's old Midnight collateral grow instead of shrink, so the rule that the migration can only reduce old collateral flips to a counterexample. | [`migrationOnlyWithdrawsOldMidnightCollateral`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L15) (CB-DIR-1) |
| ✗ [24](#m-borrowmidnighttobluecallback-24) | Withdrawing one unit less from Midnight than is supplied to Blue makes the amount deposited into Blue exceed the amount withdrawn from Midnight, so the deposit-at-most-withdrawn rule flips to a counterexample. | [`migrationCannotDepositMoreCollateralThanWithdrawn`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L93) (CB-SRC-1) |
| ✗ [25](#m-borrowmidnighttobluecallback-25) | Migrating one unit less than the full source collateral on the final fill leaves a unit of old Midnight collateral behind after the debt is fully repaid, so the rule that the final fill drains all old collateral flips to a counterexample. | [`migrationFinalFillTransfersAllOldMidnightCollateral`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L116) (CB-FINAL-3) |
| ✗ [26](#m-borrowmidnighttobluecallback-26) | Replacing the Blue supplyCollateral call with withdrawCollateral makes the borrower's new Blue collateral shrink instead of grow, so the rule that the migration can only add new Blue collateral flips to a counterexample. | [`migrationOnlyAddsNewBlueCollateral`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L74) (CB-DIR-1) |
| ✗ [27](#m-borrowmidnighttobluecallback-27) | Replacing the Blue borrow call with repay makes the borrower's new Blue debt shares fall instead of rise, so the rule that the migration can only open new Blue debt flips to a counterexample. | [`migrationOnlyOpensNewBlueDebt`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L56) (CB-DIR-1) |
| ✗ [29](#m-borrowmidnighttobluecallback-29) | Inverts the caller guard (!= to ==), so onBuy reverts OnlyMidnight on every take() (which always comes from Midnight) and the reachability witness goes UNSAT. | [`migrationReducesOldDebtOnAtMostOneMarket__satisfy`](../../specs/callbacks/BorrowMidnightToBlueCallback/debug_satisfy/many_satisfy.spec#L88) (CB-DIR-1) |
| ✗ [30](#m-borrowmidnighttobluecallback-30) | Borrowing on behalf of the callback contract instead of the buyer opens new Blue debt for a party whose old Midnight debt did not fall, so the rule coupling old and new debt movements flips to a counterexample. | [`oldMidnightDebtAndNewBlueDebtMoveTogether`](../../specs/callbacks/BorrowMidnightToBlueCallback/one.spec#L9) (CB-DIR-1) |

<a id="m-borrowmidnighttobluecallback-8"></a>
## ✗ #8 — Commenting out the borrow call prevents Blue debt from being opened, making the satisfy clause impossible to prove (cannot demonstrate that blueSharesAfter > sharesBefore).

- **Mutant:** [`8.sol`](8.sol)
- **Caught by:** [`migrationCanOpenNewBlueDebt`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L136)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationCanOpenNewBlueDebt.conf --rule migrationCanOpenNewBlueDebt`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 8`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -81,7 +81,7 @@
         }
 
         uint256 borrowAmount = buyerAssets + fee;
-        MORPHO_BLUE.borrow(callbackData.targetMarketParams, borrowAmount, 0, buyer, address(this));
+        // MORPHO_BLUE.borrow(callbackData.targetMarketParams, borrowAmount, 0, buyer, address(this));  // MUTATION: rebased
 
         if (fee > 0) {
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
```

<a id="m-borrowmidnighttobluecallback-9"></a>
## ✗ #9 — withdrawCollateral commented out: collateral never leaves Midnight, migration cannot move it

- **Mutant:** [`9.sol`](9.sol)
- **Caught by:** [`migrationCanMoveCollateralMidnightToBlue`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L154)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationCanMoveCollateralMidnightToBlue.conf --rule migrationCanMoveCollateralMidnightToBlue`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 9`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -73,7 +73,7 @@
             sourceDebtAfter == 0 ? sourceCollateral : sourceCollateral.mulDivDown(units, sourceDebtBefore);
 
         if (collateralMigrated > 0) {
-            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));
+            // MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));  // MUTATION: rebased
 
             IERC20(callbackData.targetMarketParams.collateralToken)
                 .forceApprove(address(MORPHO_BLUE), collateralMigrated);
```

<a id="m-borrowmidnighttobluecallback-10"></a>
## ✗ #10 — Setting the amount withdrawn from Midnight to zero leaves the borrower's old collateral in place, so no fill can ever fully close the old position and the rule's witness becomes unsatisfiable.

- **Mutant:** [`10.sol`](10.sol)
- **Caught by:** [`migrationCanFullyCloseOldPosition`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L175) (CB-CLOSE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationCanFullyCloseOldPosition.conf --rule migrationCanFullyCloseOldPosition`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 10`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -73,7 +73,7 @@
             sourceDebtAfter == 0 ? sourceCollateral : sourceCollateral.mulDivDown(units, sourceDebtBefore);
 
         if (collateralMigrated > 0) {
-            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));
+            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, 0, buyer, address(this));  // MUTATION: rebased
 
             IERC20(callbackData.targetMarketParams.collateralToken)
                 .forceApprove(address(MORPHO_BLUE), collateralMigrated);
```

<a id="m-borrowmidnighttobluecallback-18"></a>
## ✗ #18 — fee-cap guard inverted (> -> <): every legal below-cap feeRate now reverts while an above-cap rate is accepted — percentageFeeRateAboveCapReverts (aboveCap => reverted) is violated.

- **Mutant:** [`18.sol`](18.sol)
- **Caught by:** [`percentageFeeRateAboveCapReverts`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L197)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/percentageFeeRateAboveCapReverts.conf --rule percentageFeeRateAboveCapReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 18`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -58,7 +58,7 @@
     /// @dev Returns the flat percentage fee assets * feeRate / WAD, rounded down.
     /// @dev Reverts if feeRate > MAX_PERCENTAGE_FEE_RATE (1%).
     function percentageFee(uint256 assets, uint256 feeRate) internal pure returns (uint256 fee) {
-        if (feeRate > MAX_PERCENTAGE_FEE_RATE) revert InvalidFeeConfig();
+        if (feeRate < MAX_PERCENTAGE_FEE_RATE) revert InvalidFeeConfig();  // MUTATION: rebased
         fee = assets.mulDivDown(feeRate, WAD);
     }
 
```

<a id="m-borrowmidnighttobluecallback-20"></a>
## ✗ #20 — Replacing the Midnight withdrawCollateral call with supplyCollateral makes the borrower's old Midnight collateral grow instead of shrink, so the rule that the migration can only reduce old collateral flips to a counterexample.

- **Mutant:** [`20.sol`](20.sol)
- **Caught by:** [`migrationOnlyWithdrawsOldMidnightCollateral`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L15) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/migrationOnlyWithdrawsOldMidnightCollateral.conf --rule migrationOnlyWithdrawsOldMidnightCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 20`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -73,7 +73,7 @@
             sourceDebtAfter == 0 ? sourceCollateral : sourceCollateral.mulDivDown(units, sourceDebtBefore);
 
         if (collateralMigrated > 0) {
-            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));
+            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated, buyer);  // MUTATION: rebased
 
             IERC20(callbackData.targetMarketParams.collateralToken)
                 .forceApprove(address(MORPHO_BLUE), collateralMigrated);
```

<a id="m-borrowmidnighttobluecallback-24"></a>
## ✗ #24 — Withdrawing one unit less from Midnight than is supplied to Blue makes the amount deposited into Blue exceed the amount withdrawn from Midnight, so the deposit-at-most-withdrawn rule flips to a counterexample.

- **Mutant:** [`24.sol`](24.sol)
- **Caught by:** [`migrationCannotDepositMoreCollateralThanWithdrawn`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L93) (CB-SRC-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/migrationCannotDepositMoreCollateralThanWithdrawn.conf --rule migrationCannotDepositMoreCollateralThanWithdrawn`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 24`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -73,7 +73,7 @@
             sourceDebtAfter == 0 ? sourceCollateral : sourceCollateral.mulDivDown(units, sourceDebtBefore);
 
         if (collateralMigrated > 0) {
-            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));
+            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated - 1, buyer, address(this));  // MUTATION: rebased
 
             IERC20(callbackData.targetMarketParams.collateralToken)
                 .forceApprove(address(MORPHO_BLUE), collateralMigrated);
```

<a id="m-borrowmidnighttobluecallback-25"></a>
## ✗ #25 — Migrating one unit less than the full source collateral on the final fill leaves a unit of old Midnight collateral behind after the debt is fully repaid, so the rule that the final fill drains all old collateral flips to a counterexample.

- **Mutant:** [`25.sol`](25.sol)
- **Caught by:** [`migrationFinalFillTransfersAllOldMidnightCollateral`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L116) (CB-FINAL-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/migrationFinalFillTransfersAllOldMidnightCollateral.conf --rule migrationFinalFillTransfersAllOldMidnightCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 25`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -70,7 +70,7 @@
         }
 
         uint256 collateralMigrated =
-            sourceDebtAfter == 0 ? sourceCollateral : sourceCollateral.mulDivDown(units, sourceDebtBefore);
+            sourceDebtAfter == 0 ? sourceCollateral - 1 : sourceCollateral.mulDivDown(units, sourceDebtBefore);  // MUTATION: rebased
 
         if (collateralMigrated > 0) {
             MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));
```

<a id="m-borrowmidnighttobluecallback-26"></a>
## ✗ #26 — Replacing the Blue supplyCollateral call with withdrawCollateral makes the borrower's new Blue collateral shrink instead of grow, so the rule that the migration can only add new Blue collateral flips to a counterexample.

- **Mutant:** [`26.sol`](26.sol)
- **Caught by:** [`migrationOnlyAddsNewBlueCollateral`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L74) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/migrationOnlyAddsNewBlueCollateral.conf --rule migrationOnlyAddsNewBlueCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 26`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -77,7 +77,7 @@
 
             IERC20(callbackData.targetMarketParams.collateralToken)
                 .forceApprove(address(MORPHO_BLUE), collateralMigrated);
-            MORPHO_BLUE.supplyCollateral(callbackData.targetMarketParams, collateralMigrated, buyer, "");
+            MORPHO_BLUE.withdrawCollateral(callbackData.targetMarketParams, collateralMigrated, buyer, address(this));  // MUTATION: rebased
         }
 
         uint256 borrowAmount = buyerAssets + fee;
```

<a id="m-borrowmidnighttobluecallback-27"></a>
## ✗ #27 — Replacing the Blue borrow call with repay makes the borrower's new Blue debt shares fall instead of rise, so the rule that the migration can only open new Blue debt flips to a counterexample.

- **Mutant:** [`27.sol`](27.sol)
- **Caught by:** [`migrationOnlyOpensNewBlueDebt`](../../specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L56) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/migrationOnlyOpensNewBlueDebt.conf --rule migrationOnlyOpensNewBlueDebt`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 27`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -81,7 +81,7 @@
         }
 
         uint256 borrowAmount = buyerAssets + fee;
-        MORPHO_BLUE.borrow(callbackData.targetMarketParams, borrowAmount, 0, buyer, address(this));
+        MORPHO_BLUE.repay(callbackData.targetMarketParams, borrowAmount, 0, buyer, "");  // MUTATION: rebased
 
         if (fee > 0) {
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
```

<a id="m-borrowmidnighttobluecallback-29"></a>
## ✗ #29 — Inverts the caller guard (!= to ==), so onBuy reverts OnlyMidnight on every take() (which always comes from Midnight) and the reachability witness goes UNSAT.

- **Mutant:** [`29.sol`](29.sol)
- **Caught by:** [`migrationReducesOldDebtOnAtMostOneMarket__satisfy`](../../specs/callbacks/BorrowMidnightToBlueCallback/debug_satisfy/many_satisfy.spec#L88) (CB-DIR-1)
- **Channel:** `debug_satisfy` satisfy-twin — the mutation makes `take()` revert, so the witness becomes UNSAT (**VIOLATED** = mutant **Killed**); the clean-`src/` witness is proven **SUCCESS** (two-gate).
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/debug_satisfy/migrationReducesOldDebtOnAtMostOneMarket.conf --rule migrationReducesOldDebtOnAtMostOneMarket__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 29`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -48,7 +48,7 @@
         address buyer,
         bytes memory data
     ) external override returns (bytes32) {
-        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
+        if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();  // MUTATION: rebased
         if (buyerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
```

<a id="m-borrowmidnighttobluecallback-30"></a>
## ✗ #30 — Borrowing on behalf of the callback contract instead of the buyer opens new Blue debt for a party whose old Midnight debt did not fall, so the rule coupling old and new debt movements flips to a counterexample.

- **Mutant:** [`30.sol`](30.sol)
- **Caught by:** [`oldMidnightDebtAndNewBlueDebtMoveTogether`](../../specs/callbacks/BorrowMidnightToBlueCallback/one.spec#L9) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/oldMidnightDebtAndNewBlueDebtMoveTogether.conf --rule oldMidnightDebtAndNewBlueDebtMoveTogether`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 30`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -81,7 +81,7 @@
         }
 
         uint256 borrowAmount = buyerAssets + fee;
-        MORPHO_BLUE.borrow(callbackData.targetMarketParams, borrowAmount, 0, buyer, address(this));
+        MORPHO_BLUE.borrow(callbackData.targetMarketParams, borrowAmount, 0, address(this), address(this));  // MUTATION: rebased
 
         if (fee > 0) {
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
```

