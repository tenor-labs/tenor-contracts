# Mutations — `LendMidnightRenewalCallback` (`src/callbacks/LendMidnightRenewalCallback.sol`)

Each numbered file is the contract above with **one** line broken (#14 instead breaks a line of the shared `src/libraries/CallbackLib.sol`, exercised through this callback's scene); the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [2](#m-lendmidnightrenewalcallback-2) | zero-amount guard || -> && | [`callbackRevertsOnZeroAssetsOrUnits`](../../specs/callbacks/callbacks.spec#L91) |
| ✗ [8](#m-lendmidnightrenewalcallback-8) | Flip fee condition: transfers fee only when fee is zero instead of when it's positive | [`positiveFeeIsPayable`](../../specs/callbacks/callbacks.spec#L201) |
| ✗ [14](#m-lendmidnightrenewalcallback-14) | lost the WAD denominator (effPrice,1): fee = units*effPrice explodes far past units | [`buyerTickFeePaidBoundedByUnits`](../../specs/callbacks/callbacks.spec#L180) (CB-FEE-2) |
| ✗ [16](#m-lendmidnightrenewalcallback-16) | source withdraw zeroed: the lender's source-market credit can never reach zero, so the position-bound close witness goes UNSAT (VIOLATED = killed). | [`renewalCanFullyCloseOldCredit`](../../specs/callbacks/LendMidnightRenewalCallback/many.spec#L112) (CB-CLOSE-1) |
| ✗ [17](#m-lendmidnightrenewalcallback-17) | Forces the buyer callback fee to zero, so the fee recipient is never paid even though the credit still rolls, and the witness that requires both a credit roll and a positive fee payment can no longer be satisfied. | [`renewalCanMoveCreditWithPositiveFee`](../../specs/callbacks/LendMidnightRenewalCallback/many.spec#L135) |
| ✗ [19](#m-lendmidnightrenewalcallback-19) | onBuy inserts a 2nd MORPHO_MIDNIGHT.withdraw(units+buyerAssets+1) overshooting take's +units target-credit deposit : credit net-drops on both source and target | [`renewalReducesCreditOnAtMostOneMarket`](../../specs/callbacks/LendMidnightRenewalCallback/many.spec#L39) (CB-DIR-1) |
| ✗ [21](#m-lendmidnightrenewalcallback-21) | Inverts the zero-credit guard from ==0 to !=0, so every renewal with source credit reverts and the only admitted path (zero source credit) then fails the insufficient-credit check, making take() revert on all paths and leaving the reachability witness unsatisfiable. | [`renewalAddsCreditOnAtMostOneMarket__satisfy`](../../specs/callbacks/LendMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L105) (CB-DIR-1) |
| ✗ [23](#m-lendmidnightrenewalcallback-23) | Inserts an extra transfer that pulls units+1 of loan token directly from the buyer on top of the legitimate withdraw, so the callback's net external inflow exceeds units and the rule bounding that inflow flips to a counterexample. | [`renewalCallbackNeverPullsExternalLoanToken`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L111) (CB-SRC-1) |
| ✗ [24](#m-lendmidnightrenewalcallback-24) | Flips the same-market guard from == to !=, so the callback no longer reverts when the source and target markets are identical, and the rule requiring a revert in that case flips to a counterexample. | [`callbackRevertsForSameSourceMarket`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L293) (CB-SAME-1) |
| ✗ [25](#m-lendmidnightrenewalcallback-25) | Approves one less than buyerAssets for settlement, so Midnight's pull of the full buyerAssets exceeds the allowance and reverts on every path, making take() always revert and leaving the witness unsatisfiable. | [`renewalNeverTouchesUnrelatedLenderCredit__satisfy`](../../specs/callbacks/LendMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L164) (CB-DIR-1) |

<a id="m-lendmidnightrenewalcallback-2"></a>
## ✗ #2 — zero-amount guard || -> &&

- **Mutant:** [`2.sol`](2.sol)
- **Caught by:** [`callbackRevertsOnZeroAssetsOrUnits`](../../specs/callbacks/callbacks.spec#L91)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf/callbackRevertsOnZeroAssetsOrUnits.conf --rule callbackRevertsOnZeroAssetsOrUnits`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 2`

```diff
--- a/src/callbacks/LendMidnightRenewalCallback.sol
+++ b/src/callbacks/LendMidnightRenewalCallback.sol
@@ -38,7 +38,7 @@
         bytes memory data
     ) external override returns (bytes32) {
         if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
-        if (buyerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
+        if (buyerAssets == 0 && units == 0) revert CallbackLib.ZeroAmount();  // MUTATION: zero-amount guard || -> &&
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
         if (callbackData.sourceMarket.loanToken != market.loanToken) revert CallbackLib.TokenMismatch();
```

<a id="m-lendmidnightrenewalcallback-8"></a>
## ✗ #8 — Flip fee condition: transfers fee only when fee is zero instead of when it's positive

- **Mutant:** [`8.sol`](8.sol)
- **Caught by:** [`positiveFeeIsPayable`](../../specs/callbacks/callbacks.spec#L201)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf/positiveFeeIsPayable.conf --rule positiveFeeIsPayable`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 8`

```diff
--- a/src/callbacks/LendMidnightRenewalCallback.sol
+++ b/src/callbacks/LendMidnightRenewalCallback.sol
@@ -55,7 +55,7 @@
 
         MORPHO_MIDNIGHT.withdraw(callbackData.sourceMarket, withdrawAssets, buyer, address(this));
 
-        if (fee > 0) {
+        if (fee == 0) {  // MUTATION: Flip fee condition: transfers fee only when fee is zero
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
         }
 
```

<a id="m-lendmidnightrenewalcallback-14"></a>
## ✗ #14 — lost the WAD denominator (effPrice,1): fee = units*effPrice explodes far past units

- **Mutant:** [`14.sol`](14.sol)
- **Caught by:** [`buyerTickFeePaidBoundedByUnits`](../../specs/callbacks/callbacks.spec#L180) (CB-FEE-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/buyerTickFeePaidBoundedByUnits.conf --rule buyerTickFeePaidBoundedByUnits`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 14`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -122,6 +122,6 @@
     {
         if (feeRate == 0) return 0;
         uint256 effPrice = buyerEffectivePrice(TickLib.tickToPrice(tick), feeRate);
-        return units.mulDivDown(effPrice, WAD).zeroFloorSub(assets);
+        return units.mulDivDown(effPrice, 1).zeroFloorSub(assets);  // MUTATION: rebased
     }
 }
```

<a id="m-lendmidnightrenewalcallback-16"></a>
## ✗ #16 — source withdraw zeroed: the lender's source-market credit can never reach zero, so the position-bound close witness goes UNSAT (VIOLATED = killed).

- **Mutant:** [`16.sol`](16.sol)
- **Caught by:** [`renewalCanFullyCloseOldCredit`](../../specs/callbacks/LendMidnightRenewalCallback/many.spec#L112) (CB-CLOSE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf_kill/renewalCanFullyCloseOldCredit.conf --rule renewalCanFullyCloseOldCredit`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 16`

```diff
--- a/src/callbacks/LendMidnightRenewalCallback.sol
+++ b/src/callbacks/LendMidnightRenewalCallback.sol
@@ -53,7 +53,7 @@
         uint256 withdrawAssets = buyerAssets + fee;
         if (withdrawAssets > sourceCredit) revert CallbackLib.InsufficientCredit();
 
-        MORPHO_MIDNIGHT.withdraw(callbackData.sourceMarket, withdrawAssets, buyer, address(this));
+        MORPHO_MIDNIGHT.withdraw(callbackData.sourceMarket, 0, buyer, address(this));  // MUTATION: coverage renewalCanFullyCloseOldCredit
 
         if (fee > 0) {
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
```

<a id="m-lendmidnightrenewalcallback-17"></a>
## ✗ #17 — Forces the buyer callback fee to zero, so the fee recipient is never paid even though the credit still rolls, and the witness that requires both a credit roll and a positive fee payment can no longer be satisfied.

- **Mutant:** [`17.sol`](17.sol)
- **Caught by:** [`renewalCanMoveCreditWithPositiveFee`](../../specs/callbacks/LendMidnightRenewalCallback/many.spec#L135)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/renewalCanMoveCreditWithPositiveFee.conf --rule renewalCanMoveCreditWithPositiveFee`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 17`

```diff
--- a/src/callbacks/LendMidnightRenewalCallback.sol
+++ b/src/callbacks/LendMidnightRenewalCallback.sol
@@ -48,7 +48,7 @@
         (uint128 sourceCredit,,) = MORPHO_MIDNIGHT.updatePositionView(callbackData.sourceMarket, sourceMarketId, buyer);
         if (sourceCredit == 0) revert CallbackLib.ZeroAmount();
 
-        uint256 fee = CallbackLib.buyerFeeFromTick(callbackData.tick, callbackData.feeRate, units, buyerAssets);
+        uint256 fee = 0;  // MUTATION: null the buyer callback fee (feeRecipient is never paid)
 
         uint256 withdrawAssets = buyerAssets + fee;
         if (withdrawAssets > sourceCredit) revert CallbackLib.InsufficientCredit();
```

<a id="m-lendmidnightrenewalcallback-19"></a>
## ✗ #19 — onBuy inserts a 2nd MORPHO_MIDNIGHT.withdraw(units+buyerAssets+1) overshooting take's +units target-credit deposit : credit net-drops on both source and target

- **Mutant:** [`19.sol`](19.sol)
- **Caught by:** [`renewalReducesCreditOnAtMostOneMarket`](../../specs/callbacks/LendMidnightRenewalCallback/many.spec#L39) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf_kill/renewalReducesCreditOnAtMostOneMarket.conf --rule renewalReducesCreditOnAtMostOneMarket`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 19`

```diff
--- a/src/callbacks/LendMidnightRenewalCallback.sol
+++ b/src/callbacks/LendMidnightRenewalCallback.sol
@@ -54,6 +54,7 @@
         if (withdrawAssets > sourceCredit) revert CallbackLib.InsufficientCredit();
 
         MORPHO_MIDNIGHT.withdraw(callbackData.sourceMarket, withdrawAssets, buyer, address(this));
+        MORPHO_MIDNIGHT.withdraw(market, units + buyerAssets + 1, buyer, address(this));  // MUTATION: onBuy inserts a 2nd target withdraw that overshoots take's +units credit deposit
 
         if (fee > 0) {
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
```

<a id="m-lendmidnightrenewalcallback-21"></a>
## ✗ #21 — Inverts the zero-credit guard from ==0 to !=0, so every renewal with source credit reverts and the only admitted path (zero source credit) then fails the insufficient-credit check, making take() revert on all paths and leaving the reachability witness unsatisfiable.

- **Mutant:** [`21.sol`](21.sol)
- **Caught by:** [`renewalAddsCreditOnAtMostOneMarket__satisfy`](../../specs/callbacks/LendMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L105) (CB-DIR-1)
- **Channel:** `debug_satisfy` satisfy-twin — the mutation makes `take()` revert, so the witness becomes UNSAT (**VIOLATED** = mutant **Killed**); the clean-`src/` witness is proven **SUCCESS** (two-gate).
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf_satisfy/renewalAddsCreditOnAtMostOneMarket.conf --rule renewalAddsCreditOnAtMostOneMarket__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 21`

```diff
--- a/src/callbacks/LendMidnightRenewalCallback.sol
+++ b/src/callbacks/LendMidnightRenewalCallback.sol
@@ -46,7 +46,7 @@
         bytes32 sourceMarketId = IdLib.toId(callbackData.sourceMarket);
         if (sourceMarketId == marketId) revert CallbackLib.SameMarket();
         (uint128 sourceCredit,,) = MORPHO_MIDNIGHT.updatePositionView(callbackData.sourceMarket, sourceMarketId, buyer);
-        if (sourceCredit == 0) revert CallbackLib.ZeroAmount();
+        if (sourceCredit != 0) revert CallbackLib.ZeroAmount();  // MUTATION: rebased
 
         uint256 fee = CallbackLib.buyerFeeFromTick(callbackData.tick, callbackData.feeRate, units, buyerAssets);
 
```

<a id="m-lendmidnightrenewalcallback-23"></a>
## ✗ #23 — Inserts an extra transfer that pulls units+1 of loan token directly from the buyer on top of the legitimate withdraw, so the callback's net external inflow exceeds units and the rule bounding that inflow flips to a counterexample.

- **Mutant:** [`23.sol`](23.sol)
- **Caught by:** [`renewalCallbackNeverPullsExternalLoanToken`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L111) (CB-SRC-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf/renewalCallbackNeverPullsExternalLoanToken.conf --rule renewalCallbackNeverPullsExternalLoanToken`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 23`

```diff
--- a/src/callbacks/LendMidnightRenewalCallback.sol
+++ b/src/callbacks/LendMidnightRenewalCallback.sol
@@ -60,6 +60,7 @@
         }
 
         IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);
+        IERC20(market.loanToken).transferFrom(buyer, address(this), units + 1);  // MUTATION: rebased insert
 
         emit LendRenewed(buyer, sourceMarketId, marketId, buyerAssets, fee);
 
```

<a id="m-lendmidnightrenewalcallback-24"></a>
## ✗ #24 — Flips the same-market guard from == to !=, so the callback no longer reverts when the source and target markets are identical, and the rule requiring a revert in that case flips to a counterexample.

- **Mutant:** [`24.sol`](24.sol)
- **Caught by:** [`callbackRevertsForSameSourceMarket`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L293) (CB-SAME-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf/callbackRevertsForSameSourceMarket.conf --rule callbackRevertsForSameSourceMarket`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 24`

```diff
--- a/src/callbacks/LendMidnightRenewalCallback.sol
+++ b/src/callbacks/LendMidnightRenewalCallback.sol
@@ -44,7 +44,7 @@
         if (callbackData.sourceMarket.loanToken != market.loanToken) revert CallbackLib.TokenMismatch();
 
         bytes32 sourceMarketId = IdLib.toId(callbackData.sourceMarket);
-        if (sourceMarketId == marketId) revert CallbackLib.SameMarket();
+        if (sourceMarketId != marketId) revert CallbackLib.SameMarket();  // MUTATION: rebased
         (uint128 sourceCredit,,) = MORPHO_MIDNIGHT.updatePositionView(callbackData.sourceMarket, sourceMarketId, buyer);
         if (sourceCredit == 0) revert CallbackLib.ZeroAmount();
 
```

<a id="m-lendmidnightrenewalcallback-25"></a>
## ✗ #25 — Approves one less than buyerAssets for settlement, so Midnight's pull of the full buyerAssets exceeds the allowance and reverts on every path, making take() always revert and leaving the witness unsatisfiable.

- **Mutant:** [`25.sol`](25.sol)
- **Caught by:** [`renewalNeverTouchesUnrelatedLenderCredit__satisfy`](../../specs/callbacks/LendMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L164) (CB-DIR-1)
- **Channel:** `debug_satisfy` satisfy-twin — the mutation makes `take()` revert, so the witness becomes UNSAT (**VIOLATED** = mutant **Killed**); the clean-`src/` witness is proven **SUCCESS** (two-gate).
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf_kill/renewalNeverTouchesUnrelatedLenderCredit.conf --rule renewalNeverTouchesUnrelatedLenderCredit__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 25`

```diff
--- a/src/callbacks/LendMidnightRenewalCallback.sol
+++ b/src/callbacks/LendMidnightRenewalCallback.sol
@@ -59,7 +59,7 @@
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
         }
 
-        IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);
+        IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets - 1);  // MUTATION: rebased
 
         emit LendRenewed(buyer, sourceMarketId, marketId, buyerAssets, fee);
 
```

