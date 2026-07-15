# Mutations — `RouterLib` (`src/libraries/RouterLib.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [1](#m-routerlib-1) | net-seller min -> max : breaks fee-monotone-decreasing | [`netSellerPriceMonotoneInFee`](../../specs/ratifier/unit.spec#L188) |
| ✗ [2](#m-routerlib-2) | net-buyer max -> min : breaks fee-monotone-increasing | [`netBuyerPriceMonotoneInFee`](../../specs/ratifier/unit.spec#L213) |

<a id="m-routerlib-1"></a>
## ✗ #1 — net-seller min -> max : breaks fee-monotone-decreasing

- **Mutant:** [`1.sol`](1.sol)
- **Caught by:** [`netSellerPriceMonotoneInFee`](../../specs/ratifier/unit.spec#L188)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule netSellerPriceMonotoneInFee`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh RouterLib 1`

```diff
--- a/src/libraries/RouterLib.sol
+++ b/src/libraries/RouterLib.sol
@@ -74,6 +74,6 @@
         uint256 midnightPrice = offerPrice > settlementFee ? offerPrice - settlementFee : 0;
         if (feeRate == 0) return midnightPrice;
         uint256 tenorPrice = CallbackLib.sellerEffectivePrice(offerPrice, feeRate);
-        return midnightPrice < tenorPrice ? midnightPrice : tenorPrice;
+        return midnightPrice > tenorPrice ? midnightPrice : tenorPrice;  // MUTATION: rebased
     }
 }
```

<a id="m-routerlib-2"></a>
## ✗ #2 — net-buyer max -> min : breaks fee-monotone-increasing

- **Mutant:** [`2.sol`](2.sol)
- **Caught by:** [`netBuyerPriceMonotoneInFee`](../../specs/ratifier/unit.spec#L213)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule netBuyerPriceMonotoneInFee`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh RouterLib 2`

```diff
--- a/src/libraries/RouterLib.sol
+++ b/src/libraries/RouterLib.sol
@@ -55,7 +55,7 @@
         uint256 midnightPrice = offerPrice + settlementFee;
         if (feeRate == 0) return midnightPrice;
         uint256 tenorPrice = CallbackLib.buyerEffectivePrice(offerPrice, feeRate);
-        return midnightPrice > tenorPrice ? midnightPrice : tenorPrice;
+        return midnightPrice < tenorPrice ? midnightPrice : tenorPrice;  // MUTATION: rebased
     }
 
     /// @dev Returns the net per-unit price the seller-as-taker receives onchain, used to invert remainingBudget to
```

