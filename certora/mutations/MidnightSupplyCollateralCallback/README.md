# Mutations — `MidnightSupplyCollateralCallback` (`src/callbacks/MidnightSupplyCollateralCallback.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [1](#m-midnightsupplycollateralcallback-1) | auth guard flipped (!= -> ==) | [`callbackRevertsForNonMidnightCaller`](../../specs/callbacks/callbacks.spec#L80) (CB-AUTH-1) |
| ✗ [2](#m-midnightsupplycollateralcallback-2) | zero-amount guard || -> && | [`callbackRevertsOnZeroAssetsOrUnits`](../../specs/callbacks/callbacks.spec#L91) |
| ✗ [4](#m-midnightsupplycollateralcallback-4) | Removes the length mismatch check, allowing amounts[] array with wrong length to bypass validation | [`collateralLengthMismatchReverts`](../../specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L65) |
| ✗ [9](#m-midnightsupplycollateralcallback-9) | supplyCollateral amount forced to 0: position collateral never rises, satisfy witness gone | [`supplyCanRaiseCollateral`](../../specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L88) |
| ✗ [10](#m-midnightsupplycollateralcallback-10) | onSell receiver guard flipped (routing check inverted) | [`receiverIsCallbackReverts`](../../specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L93) |
| ✗ [13](#m-midnightsupplycollateralcallback-13) | supply amount zeroed: no collateral ever reaches the seller, so the max-capacity fill witness goes UNSAT (VIOLATED = killed). | [`maxBorrowCapacityUsageFillReachable`](../../specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L63) |
| ✗ [14](#m-midnightsupplycollateralcallback-14) | Changes the zero-amount guard to reject 1 instead of 0, so a zero offerSellerAssets denominator is now accepted; the rule requiring a zero offerSellerAssets to revert is violated. | [`offerSellerAssetsZeroReverts`](../../specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L79) |
| ✗ [18](#m-midnightsupplycollateralcallback-18) | pro-rata supplyAmount operands swapped (fill/cap inverted) : partial fill supplies MORE than the configured per-slot amount | [`proRataUpperBound`](../../specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L8) |
| ✗ [20](#m-midnightsupplycollateralcallback-20) | supplyCollateral beneficiary seller -> receiver : a bystander's collateral is credited by the supply | [`bystanderUntouched`](../../specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L36) |
| ✗ [21](#m-midnightsupplycollateralcallback-21) | supplyCollateral -> withdrawCollateral : the callback withdraws, so the seller's collateral DECREASES | [`supplyMonotoneCollateral`](../../specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L14) |
| ✗ [23](#m-midnightsupplycollateralcallback-23) | Flips the cap check from greater-than to less-than, so a borrow-capacity usage above the maximum no longer reverts; the rule asserting usage stays within the cap is violated on the non-reverting path. | [`borrowCapacityUsageWithinCap`](../../specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L34) (CB-SC-CAP-1) |

<a id="m-midnightsupplycollateralcallback-1"></a>
## ✗ #1 — auth guard flipped (!= -> ==)

- **Mutant:** [`1.sol`](1.sol)
- **Caught by:** [`callbackRevertsForNonMidnightCaller`](../../specs/callbacks/callbacks.spec#L80) (CB-AUTH-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/callbackRevertsForNonMidnightCaller.conf --rule callbackRevertsForNonMidnightCaller`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 1`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -37,7 +37,7 @@
         address receiver,
         bytes memory data
     ) external override returns (bytes32) {
-        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
+        if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();  // MUTATION: auth guard flipped (!= -> ==)
         if (receiver == address(this)) revert CallbackLib.InvalidReceiver();
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
```

<a id="m-midnightsupplycollateralcallback-2"></a>
## ✗ #2 — zero-amount guard || -> &&

- **Mutant:** [`2.sol`](2.sol)
- **Caught by:** [`callbackRevertsOnZeroAssetsOrUnits`](../../specs/callbacks/callbacks.spec#L91)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/callbackRevertsOnZeroAssetsOrUnits.conf --rule callbackRevertsOnZeroAssetsOrUnits`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 2`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -39,7 +39,7 @@
     ) external override returns (bytes32) {
         if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
         if (receiver == address(this)) revert CallbackLib.InvalidReceiver();
-        if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
+        if (sellerAssets == 0 && units == 0) revert CallbackLib.ZeroAmount();  // MUTATION: zero-amount guard || -> &&
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
 
```

<a id="m-midnightsupplycollateralcallback-4"></a>
## ✗ #4 — Removes the length mismatch check, allowing amounts[] array with wrong length to bypass validation

- **Mutant:** [`4.sol`](4.sol)
- **Caught by:** [`collateralLengthMismatchReverts`](../../specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L65)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/collateralLengthMismatchReverts.conf --rule collateralLengthMismatchReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 4`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -46,7 +46,7 @@
         if (callbackData.offerSellerAssets == 0) revert CallbackLib.ZeroAmount();
 
         uint256 collateralsLength = market.collateralParams.length;
-        if (callbackData.amounts.length != collateralsLength) revert CallbackLib.InvalidCollateral();
+        // if (callbackData.amounts.length != collateralsLength) revert CallbackLib.InvalidCollateral();  // MUTATION: Removes the length mismatch check, allowing amounts[] a
 
         uint256[] memory collateralAmounts = new uint256[](collateralsLength);
 
```

<a id="m-midnightsupplycollateralcallback-9"></a>
## ✗ #9 — supplyCollateral amount forced to 0: position collateral never rises, satisfy witness gone

- **Mutant:** [`9.sol`](9.sol)
- **Caught by:** [`supplyCanRaiseCollateral`](../../specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L88)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/supplyCanRaiseCollateral.conf --rule supplyCanRaiseCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 9`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -59,7 +59,7 @@
                     address token = market.collateralParams[i].token;
                     SafeTransferLib.safeTransferFrom(token, seller, address(this), supplyAmount);
                     IERC20(token).forceApprove(address(MORPHO_MIDNIGHT), supplyAmount);
-                    MORPHO_MIDNIGHT.supplyCollateral(market, i, supplyAmount, seller);
+                    MORPHO_MIDNIGHT.supplyCollateral(market, i, 0, seller);  // MUTATION: supplyCollateral amount forced to 0: position collatera
                 }
                 collateralAmounts[i] = supplyAmount;
             }
```

<a id="m-midnightsupplycollateralcallback-10"></a>
## ✗ #10 — onSell receiver guard flipped (routing check inverted)

- **Mutant:** [`10.sol`](10.sol)
- **Caught by:** [`receiverIsCallbackReverts`](../../specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L93)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/receiverIsCallbackReverts.conf --rule receiverIsCallbackReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 10`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -38,7 +38,7 @@
         bytes memory data
     ) external override returns (bytes32) {
         if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
-        if (receiver == address(this)) revert CallbackLib.InvalidReceiver();
+        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();  // MUTATION: onSell receiver guard flipped (routing check inverted)
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
```

<a id="m-midnightsupplycollateralcallback-13"></a>
## ✗ #13 — supply amount zeroed: no collateral ever reaches the seller, so the max-capacity fill witness goes UNSAT (VIOLATED = killed).

- **Mutant:** [`13.sol`](13.sol)
- **Caught by:** [`maxBorrowCapacityUsageFillReachable`](../../specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L63)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/maxBorrowCapacityUsageFillReachable.conf --rule maxBorrowCapacityUsageFillReachable`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 13`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -59,7 +59,7 @@
                     address token = market.collateralParams[i].token;
                     SafeTransferLib.safeTransferFrom(token, seller, address(this), supplyAmount);
                     IERC20(token).forceApprove(address(MORPHO_MIDNIGHT), supplyAmount);
-                    MORPHO_MIDNIGHT.supplyCollateral(market, i, supplyAmount, seller);
+                    MORPHO_MIDNIGHT.supplyCollateral(market, i, 0, seller);  // MUTATION: coverage maxBorrowCapacityUsageFillReachable
                 }
                 collateralAmounts[i] = supplyAmount;
             }
```

<a id="m-midnightsupplycollateralcallback-14"></a>
## ✗ #14 — Changes the zero-amount guard to reject 1 instead of 0, so a zero offerSellerAssets denominator is now accepted; the rule requiring a zero offerSellerAssets to revert is violated.

- **Mutant:** [`14.sol`](14.sol)
- **Caught by:** [`offerSellerAssetsZeroReverts`](../../specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L79)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/offerSellerAssetsZeroReverts.conf --rule offerSellerAssetsZeroReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 14`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -43,7 +43,7 @@
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
 
-        if (callbackData.offerSellerAssets == 0) revert CallbackLib.ZeroAmount();
+        if (callbackData.offerSellerAssets == 1) revert CallbackLib.ZeroAmount();  // MUTATION: coverage offerSellerAssetsZeroReverts
 
         uint256 collateralsLength = market.collateralParams.length;
         if (callbackData.amounts.length != collateralsLength) revert CallbackLib.InvalidCollateral();
```

<a id="m-midnightsupplycollateralcallback-18"></a>
## ✗ #18 — pro-rata supplyAmount operands swapped (fill/cap inverted) : partial fill supplies MORE than the configured per-slot amount

- **Mutant:** [`18.sol`](18.sol)
- **Caught by:** [`proRataUpperBound`](../../specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L8)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/proRataUpperBound.conf --rule proRataUpperBound`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 18`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -54,7 +54,7 @@
             uint256 configAmount = callbackData.amounts[i];
 
             if (configAmount > 0) {
-                uint256 supplyAmount = configAmount.mulDivDown(sellerAssets, callbackData.offerSellerAssets);
+                uint256 supplyAmount = configAmount.mulDivDown(callbackData.offerSellerAssets, sellerAssets); // MUTATION: pro-rata operands swapped
                 if (supplyAmount > 0) {
                     address token = market.collateralParams[i].token;
                     SafeTransferLib.safeTransferFrom(token, seller, address(this), supplyAmount);
```

<a id="m-midnightsupplycollateralcallback-20"></a>
## ✗ #20 — supplyCollateral beneficiary seller -> receiver : a bystander's collateral is credited by the supply

- **Mutant:** [`20.sol`](20.sol)
- **Caught by:** [`bystanderUntouched`](../../specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L36)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/bystanderUntouched.conf --rule bystanderUntouched`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 20`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -59,7 +59,7 @@
                     address token = market.collateralParams[i].token;
                     SafeTransferLib.safeTransferFrom(token, seller, address(this), supplyAmount);
                     IERC20(token).forceApprove(address(MORPHO_MIDNIGHT), supplyAmount);
-                    MORPHO_MIDNIGHT.supplyCollateral(market, i, supplyAmount, seller);
+                    MORPHO_MIDNIGHT.supplyCollateral(market, i, supplyAmount, receiver); // MUTATION: supply beneficiary seller -> receiver
                 }
                 collateralAmounts[i] = supplyAmount;
             }
```

<a id="m-midnightsupplycollateralcallback-21"></a>
## ✗ #21 — supplyCollateral -> withdrawCollateral : the callback withdraws, so the seller's collateral DECREASES

- **Mutant:** [`21.sol`](21.sol)
- **Caught by:** [`supplyMonotoneCollateral`](../../specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L14)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/supplyMonotoneCollateral.conf --rule supplyMonotoneCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 21`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -59,7 +59,7 @@
                     address token = market.collateralParams[i].token;
                     SafeTransferLib.safeTransferFrom(token, seller, address(this), supplyAmount);
                     IERC20(token).forceApprove(address(MORPHO_MIDNIGHT), supplyAmount);
-                    MORPHO_MIDNIGHT.supplyCollateral(market, i, supplyAmount, seller);
+                    MORPHO_MIDNIGHT.withdrawCollateral(market, i, supplyAmount, seller, address(this)); // MUTATION: supply -> withdraw
                 }
                 collateralAmounts[i] = supplyAmount;
             }
```

<a id="m-midnightsupplycollateralcallback-23"></a>
## ✗ #23 — Flips the cap check from greater-than to less-than, so a borrow-capacity usage above the maximum no longer reverts; the rule asserting usage stays within the cap is violated on the non-reverting path.

- **Mutant:** [`23.sol`](23.sol)
- **Caught by:** [`borrowCapacityUsageWithinCap`](../../specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L34) (CB-SC-CAP-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/borrowCapacityUsageWithinCap.conf --rule borrowCapacityUsageWithinCap`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 23`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -70,7 +70,7 @@
 
         if (callbackData.maxBorrowCapacityUsage > 0) {
             uint256 borrowCapacityUsage = _borrowCapacityUsage(market, seller, marketId);
-            if (borrowCapacityUsage > callbackData.maxBorrowCapacityUsage) {
+            if (borrowCapacityUsage < callbackData.maxBorrowCapacityUsage) { // MUTATION: rebased
                 revert CallbackLib.InvalidBorrowCapacityUsage();
             }
         }
```

