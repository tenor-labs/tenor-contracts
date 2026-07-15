# Mutations — `PriceLib` (`src/libraries/PriceLib.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [1](#m-pricelib-1) | swapped buyer/seller rounding (mulDivDown<->mulDivUp) | [`priceFollowsZeroCouponFormula`](../../specs/ratifier/unit.spec#L98) (PRICE-1) · [`priceRoundsInProtectedUserFavor`](../../specs/ratifier/unit.spec#L115) (PRICE-2) |
| ✗ [2](#m-pricelib-2) | denominator rate*dur -> rate+dur (formula broken, rounding intact) | [`priceFollowsZeroCouponFormula`](../../specs/ratifier/unit.spec#L98) (PRICE-1) |
| ✗ [3](#m-pricelib-3) | computeEffectiveRate buy-side max->min (> to <) | [`effectiveRateSelectsTighterBound`](../../specs/ratifier/unit.spec#L123) (PRICE-3) |
| ✗ [4](#m-pricelib-4) | satisfiesRateLimit lender <= to >= [same diff as PriceLib#9, re-proven under highlevel.conf] | [`satisfiesRateLimitComparisonDirection`](../../specs/ratifier/unit.spec#L133) (PRICE-4) · [`satisfiesRateLimitMonotoneInLenderLimit`](../../specs/ratifier/unit.spec#L225) |
| ✗ [7](#m-pricelib-7) | borrower compare >= -> <= (copy-paste of lender branch): inverts limit-monotonicity [same diff as PriceLib#8, re-proven under highlevel.conf] | [`satisfiesRateLimitMonotoneInBorrowerLimit`](../../specs/ratifier/unit.spec#L200) · [`satisfiesRateLimitComparisonDirection`](../../specs/ratifier/unit.spec#L133) (PRICE-4) |
| ✗ [8](#m-pricelib-8) | borrower rate-limit compare >= -> <= : breaks gate-vs-reconstruction binding [same diff as PriceLib#7, re-proven under unit.conf] | [`higherFeeOnlyTightensBorrowerRateGate`](../../specs/ratifier/highlevel.spec#L126) |
| ✗ [9](#m-pricelib-9) | lender rate-limit compare <= -> >= : breaks gate-vs-reconstruction binding [same diff as PriceLib#4, re-proven under unit.conf] | [`higherFeeOnlyTightensLenderRateGate`](../../specs/ratifier/highlevel.spec#L205) |

<a id="m-pricelib-1"></a>
## ✗ #1 — swapped buyer/seller rounding (mulDivDown<->mulDivUp)

- **Mutant:** [`1.sol`](1.sol)
- **Caught by:** [`priceFollowsZeroCouponFormula`](../../specs/ratifier/unit.spec#L98) (PRICE-1) · [`priceRoundsInProtectedUserFavor`](../../specs/ratifier/unit.spec#L115) (PRICE-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule priceFollowsZeroCouponFormula priceRoundsInProtectedUserFavor`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh PriceLib 1`

```diff
--- a/src/libraries/PriceLib.sol
+++ b/src/libraries/PriceLib.sol
@@ -24,7 +24,7 @@
     /// @return price The unit price (assets per unit), in WAD.
     function computePrice(bool isBuy, uint256 ratePerSecond, uint256 durationSeconds) internal pure returns (uint256) {
         uint256 denominator = WAD + ratePerSecond * durationSeconds;
-        return isBuy ? WAD.mulDivDown(WAD, denominator) : WAD.mulDivUp(WAD, denominator);
+        return isBuy ? WAD.mulDivUp(WAD, denominator) : WAD.mulDivDown(WAD, denominator);  // MUTATION: rebased
     }
 
     /// @dev Returns the effective rate for the position side: max(policyRate, limitRate) for lenders (isBuy == true,
```

<a id="m-pricelib-2"></a>
## ✗ #2 — denominator rate*dur -> rate+dur (formula broken, rounding intact)

- **Mutant:** [`2.sol`](2.sol)
- **Caught by:** [`priceFollowsZeroCouponFormula`](../../specs/ratifier/unit.spec#L98) (PRICE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule priceFollowsZeroCouponFormula`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh PriceLib 2`

```diff
--- a/src/libraries/PriceLib.sol
+++ b/src/libraries/PriceLib.sol
@@ -23,7 +23,7 @@
     /// @param durationSeconds The duration in seconds.
     /// @return price The unit price (assets per unit), in WAD.
     function computePrice(bool isBuy, uint256 ratePerSecond, uint256 durationSeconds) internal pure returns (uint256) {
-        uint256 denominator = WAD + ratePerSecond * durationSeconds;
+        uint256 denominator = WAD + ratePerSecond + durationSeconds;  // MUTATION: rebased
         return isBuy ? WAD.mulDivDown(WAD, denominator) : WAD.mulDivUp(WAD, denominator);
     }
 
```

<a id="m-pricelib-3"></a>
## ✗ #3 — computeEffectiveRate buy-side max->min (> to <)

- **Mutant:** [`3.sol`](3.sol)
- **Caught by:** [`effectiveRateSelectsTighterBound`](../../specs/ratifier/unit.spec#L123) (PRICE-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule effectiveRateSelectsTighterBound`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh PriceLib 3`

```diff
--- a/src/libraries/PriceLib.sol
+++ b/src/libraries/PriceLib.sol
@@ -35,7 +35,7 @@
     function computeEffectiveRate(bool isBuy, uint256 policyRate, uint256 limitRate) internal pure returns (uint256) {
         return
             isBuy
-                ? (policyRate > limitRate ? policyRate : limitRate)
+                ? (policyRate < limitRate ? policyRate : limitRate)  // MUTATION: rebased
                 : (policyRate < limitRate ? policyRate : limitRate);
     }
 
```

<a id="m-pricelib-4"></a>
## ✗ #4 — satisfiesRateLimit lender <= to >= [same diff as PriceLib#9, re-proven under highlevel.conf]

- **Mutant:** [`4.sol`](4.sol)
- **Caught by:** [`satisfiesRateLimitComparisonDirection`](../../specs/ratifier/unit.spec#L133) (PRICE-4) · [`satisfiesRateLimitMonotoneInLenderLimit`](../../specs/ratifier/unit.spec#L225)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule satisfiesRateLimitComparisonDirection satisfiesRateLimitMonotoneInLenderLimit`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh PriceLib 4`

```diff
--- a/src/libraries/PriceLib.sol
+++ b/src/libraries/PriceLib.sol
@@ -63,7 +63,7 @@
         uint256 effectiveRate = computeEffectiveRate(isBuy, policyRate, limitRate);
         uint256 price = computePrice(isBuy, effectiveRate, duration);
         if (isBuy) {
-            return assets * WAD <= units * price;
+            return assets * WAD >= units * price;  // MUTATION: rebased
         } else {
             return assets * WAD >= units * price;
         }
```

<a id="m-pricelib-7"></a>
## ✗ #7 — borrower compare >= -> <= (copy-paste of lender branch): inverts limit-monotonicity [same diff as PriceLib#8, re-proven under highlevel.conf]

- **Mutant:** [`7.sol`](7.sol)
- **Caught by:** [`satisfiesRateLimitMonotoneInBorrowerLimit`](../../specs/ratifier/unit.spec#L200) · [`satisfiesRateLimitComparisonDirection`](../../specs/ratifier/unit.spec#L133) (PRICE-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule satisfiesRateLimitMonotoneInBorrowerLimit satisfiesRateLimitComparisonDirection`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh PriceLib 7`

```diff
--- a/src/libraries/PriceLib.sol
+++ b/src/libraries/PriceLib.sol
@@ -65,7 +65,7 @@
         if (isBuy) {
             return assets * WAD <= units * price;
         } else {
-            return assets * WAD >= units * price;
+            return assets * WAD <= units * price;  // MUTATION: rebased
         }
     }
 }
```

<a id="m-pricelib-8"></a>
## ✗ #8 — borrower rate-limit compare >= -> <= : breaks gate-vs-reconstruction binding [same diff as PriceLib#7, re-proven under unit.conf]

- **Mutant:** [`8.sol`](8.sol)
- **Caught by:** [`higherFeeOnlyTightensBorrowerRateGate`](../../specs/ratifier/highlevel.spec#L126)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule higherFeeOnlyTightensBorrowerRateGate`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh PriceLib 8`

```diff
--- a/src/libraries/PriceLib.sol
+++ b/src/libraries/PriceLib.sol
@@ -65,7 +65,7 @@
         if (isBuy) {
             return assets * WAD <= units * price;
         } else {
-            return assets * WAD >= units * price;
+            return assets * WAD <= units * price;  // MUTATION: rebased
         }
     }
 }
```

<a id="m-pricelib-9"></a>
## ✗ #9 — lender rate-limit compare <= -> >= : breaks gate-vs-reconstruction binding [same diff as PriceLib#4, re-proven under unit.conf]

- **Mutant:** [`9.sol`](9.sol)
- **Caught by:** [`higherFeeOnlyTightensLenderRateGate`](../../specs/ratifier/highlevel.spec#L205)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule higherFeeOnlyTightensLenderRateGate`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh PriceLib 9`

```diff
--- a/src/libraries/PriceLib.sol
+++ b/src/libraries/PriceLib.sol
@@ -63,7 +63,7 @@
         uint256 effectiveRate = computeEffectiveRate(isBuy, policyRate, limitRate);
         uint256 price = computePrice(isBuy, effectiveRate, duration);
         if (isBuy) {
-            return assets * WAD <= units * price;
+            return assets * WAD >= units * price;  // MUTATION: rebased
         } else {
             return assets * WAD >= units * price;
         }
```

