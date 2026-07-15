# Mutations — `CallbackLib` (`src/libraries/CallbackLib.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [1](#m-callbacklib-1) | _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes | [`tickFeeVanishesAtPar`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L141) (CB-FEE-4) |
| ✗ [3](#m-callbacklib-3) | transposed mulDivDown args (feeRate,WAD)->(WAD,feeRate): fee share inverse in feeRate breaks net-price fee-monotonicity | [`netSellerPriceMonotoneInFee`](../../specs/ratifier/unit.spec#L188) · [`netBuyerPriceMonotoneInFee`](../../specs/ratifier/unit.spec#L213) |
| ✗ [4](#m-callbacklib-4) | _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes; re-proves the kill for the BMR instance (the CallbackLib #1 kill under the LVM conf is not evidence for this per-(contract,rule) instance). | [`tickFeeVanishesAtPar`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L266) (CB-FEE-4) |
| ✗ [5](#m-callbacklib-5) | _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes; re-proves the kill for the LMR instance (the CallbackLib #1 kill under the LVM conf is not evidence for this per-(contract,rule) instance). | [`tickFeeVanishesAtPar`](../../specs/callbacks/LendMidnightRenewalCallback/many.spec#L183) (CB-FEE-4) |
| ✗ [6](#m-callbacklib-6) | _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes; re-proves the kill for the BBM instance (the CallbackLib #1 kill under the LVM conf is not evidence for this per-(contract,rule) instance). | [`tickFeeVanishesAtPar`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L224) (CB-FEE-4) |

<a id="m-callbacklib-1"></a>
## ✗ #1 — _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes

- **Mutant:** [`1.sol`](1.sol)
- **Caught by:** [`tickFeeVanishesAtPar`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L141) (CB-FEE-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/tickFeeVanishesAtPar.conf --rule tickFeeVanishesAtPar`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh CallbackLib 1`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -67,7 +67,7 @@
     /// @dev The caller must handle feeRate == 0 before calling.
     function _interestFeeComponent(uint256 price, uint256 feeRate) private pure returns (uint256) {
         if (feeRate > WAD) revert InvalidFeeConfig();
-        return (WAD - price).mulDivDown(feeRate, WAD);
+        return (WAD + price).mulDivDown(feeRate, WAD);  // MUTATION: rebased
     }
 
     /// @dev Returns the seller-side effective price, price * WAD / (WAD + feeShareOfInterest), rounded up.
```

<a id="m-callbacklib-3"></a>
## ✗ #3 — transposed mulDivDown args (feeRate,WAD)->(WAD,feeRate): fee share inverse in feeRate breaks net-price fee-monotonicity

- **Mutant:** [`3.sol`](3.sol)
- **Caught by:** [`netSellerPriceMonotoneInFee`](../../specs/ratifier/unit.spec#L188) · [`netBuyerPriceMonotoneInFee`](../../specs/ratifier/unit.spec#L213)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule netSellerPriceMonotoneInFee netBuyerPriceMonotoneInFee`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh CallbackLib 3`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -67,7 +67,7 @@
     /// @dev The caller must handle feeRate == 0 before calling.
     function _interestFeeComponent(uint256 price, uint256 feeRate) private pure returns (uint256) {
         if (feeRate > WAD) revert InvalidFeeConfig();
-        return (WAD - price).mulDivDown(feeRate, WAD);
+        return (WAD - price).mulDivDown(WAD, feeRate);  // MUTATION: rebased
     }
 
     /// @dev Returns the seller-side effective price, price * WAD / (WAD + feeShareOfInterest), rounded up.
```

<a id="m-callbacklib-4"></a>
## ✗ #4 — _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes; re-proves the kill for the BMR instance (the CallbackLib #1 kill under the LVM conf is not evidence for this per-(contract,rule) instance).

- **Mutant:** [`4.sol`](4.sol)
- **Caught by:** [`tickFeeVanishesAtPar`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L266) (CB-FEE-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/tickFeeVanishesAtPar.conf --rule tickFeeVanishesAtPar`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh CallbackLib 4`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -67,7 +67,7 @@
     /// @dev The caller must handle feeRate == 0 before calling.
     function _interestFeeComponent(uint256 price, uint256 feeRate) private pure returns (uint256) {
         if (feeRate > WAD) revert InvalidFeeConfig();
-        return (WAD - price).mulDivDown(feeRate, WAD);
+        return (WAD + price).mulDivDown(feeRate, WAD);  // MUTATION: rebased
     }
 
     /// @dev Returns the seller-side effective price, price * WAD / (WAD + feeShareOfInterest), rounded up.
```

<a id="m-callbacklib-5"></a>
## ✗ #5 — _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes; re-proves the kill for the LMR instance (the CallbackLib #1 kill under the LVM conf is not evidence for this per-(contract,rule) instance).

- **Mutant:** [`5.sol`](5.sol)
- **Caught by:** [`tickFeeVanishesAtPar`](../../specs/callbacks/LendMidnightRenewalCallback/many.spec#L183) (CB-FEE-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/tickFeeVanishesAtPar.conf --rule tickFeeVanishesAtPar`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh CallbackLib 5`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -67,7 +67,7 @@
     /// @dev The caller must handle feeRate == 0 before calling.
     function _interestFeeComponent(uint256 price, uint256 feeRate) private pure returns (uint256) {
         if (feeRate > WAD) revert InvalidFeeConfig();
-        return (WAD - price).mulDivDown(feeRate, WAD);
+        return (WAD + price).mulDivDown(feeRate, WAD);  // MUTATION: rebased
     }
 
     /// @dev Returns the seller-side effective price, price * WAD / (WAD + feeShareOfInterest), rounded up.
```

<a id="m-callbacklib-6"></a>
## ✗ #6 — _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes; re-proves the kill for the BBM instance (the CallbackLib #1 kill under the LVM conf is not evidence for this per-(contract,rule) instance).

- **Mutant:** [`6.sol`](6.sol)
- **Caught by:** [`tickFeeVanishesAtPar`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L224) (CB-FEE-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/tickFeeVanishesAtPar.conf --rule tickFeeVanishesAtPar`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh CallbackLib 6`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -67,7 +67,7 @@
     /// @dev The caller must handle feeRate == 0 before calling.
     function _interestFeeComponent(uint256 price, uint256 feeRate) private pure returns (uint256) {
         if (feeRate > WAD) revert InvalidFeeConfig();
-        return (WAD - price).mulDivDown(feeRate, WAD);
+        return (WAD + price).mulDivDown(feeRate, WAD);  // MUTATION: rebased
     }
 
     /// @dev Returns the seller-side effective price, price * WAD / (WAD + feeShareOfInterest), rounded up.
```

