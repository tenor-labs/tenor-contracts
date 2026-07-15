# Mutations — `BorrowMidnightRenewalCallback` (`src/callbacks/BorrowMidnightRenewalCallback.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [1](#m-borrowmidnightrenewalcallback-1) | onlyMidnight guard flipped != -> == : the legitimate Midnight caller reverts, so renewal can never roll debt | [`renewalCanMoveDebtBetweenMarkets`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L157) |
| ✗ [3](#m-borrowmidnightrenewalcallback-3) | Allow renewal into the same market by flipping equality check; violates CLB-BMR-12 | [`callbackRevertsForSameSourceMarket`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L293) (CB-SAME-1) |
| ✗ [8](#m-borrowmidnightrenewalcallback-8) | Changing repayBudget to 0 prevents any debt repayment on the source market, making it impossible to satisfy the goal of moving debt from source to target market. | [`renewalCanMoveDebtBetweenMarkets`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L157) |
| ✗ [13](#m-borrowmidnightrenewalcallback-13) | onSell receiver guard flipped (!= -> ==): receiver!=callback no longer reverts. Caught by receiverNotCallbackReverts (CLB-BMR-13, receiverNotCallback => reverted via callbackCallWithRevert) — the flip leaves a non-reverting receiver!=callback trace, assert violated. | [`receiverNotCallbackReverts`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L306) |
| ✗ [22](#m-borrowmidnightrenewalcallback-22) | fee transfer doubled: the fee recipient receives fee*2, pushing the paid tick fee past the sellerAssets bound on a non-reverting take — sellerTickFeeNeverExceedsAssets is violated. | [`sellerTickFeeNeverExceedsAssets`](../../specs/callbacks/callbacks.spec#L160) (CB-FEE-1) |
| ✗ [23](#m-borrowmidnightrenewalcallback-23) | onSell transferCollaterals source/target markets swapped : collateral flows target->source (BMR-03 add-while-reduce, BMR-04 remove-while-open) | [`renewalCannotAddCollateralWhenReducingDebt`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L67) (CB-DIR-1) · [`renewalCannotRemoveCollateralWhenOpeningDebt`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L89) (CB-DIR-1) |
| ✗ [24](#m-borrowmidnightrenewalcallback-24) | The callback inserts an extra self-funded repayment on the target market, so debt drops on both the source and target markets, and the rule requiring at most one market's debt to fall reports a counterexample. | [`renewalReducesDebtOnAtMostOneMarket`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L21) (CB-DIR-1) |
| ✗ [25](#m-borrowmidnightrenewalcallback-25) | onSell inserts safeTransferFrom(units+1) into the callback : loanToken inflow exceeds units bound | [`renewalCallbackNeverPullsExternalLoanToken`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L111) (CB-SRC-1) |
| ✗ [31](#m-borrowmidnightrenewalcallback-31) | The loan-token match check is inverted so that matching source and target tokens revert, which every real renewal needs, so take() always reverts and the witness opening new target debt without removing collateral can no longer be produced. | [`renewalCannotRemoveCollateralWhenOpeningDebt__satisfy`](../../specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L158) (CB-DIR-1) |
| ✗ [33](#m-borrowmidnightrenewalcallback-33) | onSell receiver guard inverted (!= to ==) so every take-driven onSell reverts and the receiver-narrowed callbackNeverHoldsTokens__satisfy witness becomes UNSAT. | [`callbackNeverHoldsTokens__satisfy`](../../specs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/many_satisfy.spec#L34) (CB-DUST-1) |
| ✗ [34](#m-borrowmidnightrenewalcallback-34) | Flipping the Midnight-caller guard to == makes onSell revert on its first instruction whenever the caller is Midnight, which it always is inside take(), so the renewalAddsDebtOnAtMostOneMarket satisfy witness can never reach its assert point and turns unsatisfiable. | [`renewalAddsDebtOnAtMostOneMarket__satisfy`](../../specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L122) (CB-DIR-1) |
| ✗ [35](#m-borrowmidnightrenewalcallback-35) | Flipping the Midnight-caller guard to == makes onSell revert immediately on every in-model take because the caller is always Midnight, so the thirdPartyBalanceUnchanged, callbackHoldsZeroAllowance, and feeRecipientNeverLosesTokens satisfy witnesses become unsatisfiable. | [`thirdPartyBalanceUnchanged__satisfy`](../../specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L27) · [`callbackHoldsZeroAllowance__satisfy`](../../specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L9) (CB-DUST-1) · [`feeRecipientNeverLosesTokens__satisfy`](../../specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L72) |
| ✗ [36](#m-borrowmidnightrenewalcallback-36) | Doubling the seller fee transfer pushes the fee recipient's loanToken balance delta past the interest-share bound, so borrowerFeeBoundedByInterestShare flips to a counterexample. | [`borrowerFeeBoundedByInterestShare`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L181) (CB-RATE-1) |

<a id="m-borrowmidnightrenewalcallback-1"></a>
## ✗ #1 — onlyMidnight guard flipped != -> == : the legitimate Midnight caller reverts, so renewal can never roll debt

- **Mutant:** [`1.sol`](1.sol)
- **Caught by:** [`renewalCanMoveDebtBetweenMarkets`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L157)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalCanMoveDebtBetweenMarkets.conf --rule renewalCanMoveDebtBetweenMarkets`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 1`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -45,7 +45,7 @@
         address receiver,
         bytes memory data
     ) external override returns (bytes32) {
-        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
+        if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();  // MUTATION: rebased
         if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
```

<a id="m-borrowmidnightrenewalcallback-3"></a>
## ✗ #3 — Allow renewal into the same market by flipping equality check; violates CLB-BMR-12

- **Mutant:** [`3.sol`](3.sol)
- **Caught by:** [`callbackRevertsForSameSourceMarket`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L293) (CB-SAME-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/callbackRevertsForSameSourceMarket.conf --rule callbackRevertsForSameSourceMarket`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 3`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -60,7 +60,7 @@
         }
         uint256 repayBudget = sellerAssets - fee;
         bytes32 sourceMarketId = IdLib.toId(callbackData.sourceMarket);
-        if (sourceMarketId == marketId) revert CallbackLib.SameMarket();
+        if (sourceMarketId != marketId) revert CallbackLib.SameMarket();  // MUTATION: rebased
         uint256 sourceDebtBefore = MORPHO_MIDNIGHT.debt(sourceMarketId, seller);
 
         if (sourceDebtBefore == 0) revert CallbackLib.ZeroAmount();
```

<a id="m-borrowmidnightrenewalcallback-8"></a>
## ✗ #8 — Changing repayBudget to 0 prevents any debt repayment on the source market, making it impossible to satisfy the goal of moving debt from source to target market.

- **Mutant:** [`8.sol`](8.sol)
- **Caught by:** [`renewalCanMoveDebtBetweenMarkets`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L157)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalCanMoveDebtBetweenMarkets.conf --rule renewalCanMoveDebtBetweenMarkets`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 8`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -67,7 +67,7 @@
         if (repayBudget > sourceDebtBefore) revert CallbackLib.ExcessRepayment();
 
         IERC20(market.loanToken).forceApprove(address(MORPHO_MIDNIGHT), repayBudget);
-        MORPHO_MIDNIGHT.repay(callbackData.sourceMarket, repayBudget, seller, address(0), "");
+        MORPHO_MIDNIGHT.repay(callbackData.sourceMarket, 0, seller, address(0), "");  // MUTATION: rebased
 
         (address[] memory collateralTokens, uint256[] memory collateralAmounts) = MORPHO_MIDNIGHT.transferCollaterals(
             callbackData.sourceMarket, market, seller, sourceMarketId, sourceDebtBefore, repayBudget
```

<a id="m-borrowmidnightrenewalcallback-13"></a>
## ✗ #13 — onSell receiver guard flipped (!= -> ==): receiver!=callback no longer reverts. Caught by receiverNotCallbackReverts (CLB-BMR-13, receiverNotCallback => reverted via callbackCallWithRevert) — the flip leaves a non-reverting receiver!=callback trace, assert violated.

- **Mutant:** [`13.sol`](13.sol)
- **Caught by:** [`receiverNotCallbackReverts`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L306)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/receiverNotCallbackReverts.conf --rule receiverNotCallbackReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 13`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -46,7 +46,7 @@
         bytes memory data
     ) external override returns (bytes32) {
         if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
-        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
+        if (receiver == address(this)) revert CallbackLib.InvalidReceiver();  // MUTATION: rebased
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
```

<a id="m-borrowmidnightrenewalcallback-22"></a>
## ✗ #22 — fee transfer doubled: the fee recipient receives fee*2, pushing the paid tick fee past the sellerAssets bound on a non-reverting take — sellerTickFeeNeverExceedsAssets is violated.

- **Mutant:** [`22.sol`](22.sol)
- **Caught by:** [`sellerTickFeeNeverExceedsAssets`](../../specs/callbacks/callbacks.spec#L160) (CB-FEE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/sellerTickFeeNeverExceedsAssets.conf --rule sellerTickFeeNeverExceedsAssets`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 22`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -56,7 +56,7 @@
         uint256 fee = CallbackLib.sellerFeeFromTick(callbackData.tick, callbackData.feeRate, units, sellerAssets);
 
         if (fee > 0) {
-            SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
+            SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee * 2);  // MUTATION: rebased
         }
         uint256 repayBudget = sellerAssets - fee;
         bytes32 sourceMarketId = IdLib.toId(callbackData.sourceMarket);
```

<a id="m-borrowmidnightrenewalcallback-23"></a>
## ✗ #23 — onSell transferCollaterals source/target markets swapped : collateral flows target->source (BMR-03 add-while-reduce, BMR-04 remove-while-open)

- **Mutant:** [`23.sol`](23.sol)
- **Caught by:** [`renewalCannotAddCollateralWhenReducingDebt`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L67) (CB-DIR-1) · [`renewalCannotRemoveCollateralWhenOpeningDebt`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L89) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_kill/renewalCannotAddCollateralWhenReducingDebt.conf --rule renewalCannotAddCollateralWhenReducingDebt renewalCannotRemoveCollateralWhenOpeningDebt`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 23`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -70,7 +70,7 @@
         MORPHO_MIDNIGHT.repay(callbackData.sourceMarket, repayBudget, seller, address(0), "");
 
         (address[] memory collateralTokens, uint256[] memory collateralAmounts) = MORPHO_MIDNIGHT.transferCollaterals(
-            callbackData.sourceMarket, market, seller, sourceMarketId, sourceDebtBefore, repayBudget
+            market, callbackData.sourceMarket, seller, sourceMarketId, sourceDebtBefore, repayBudget  // MUTATION: rebased
         );
 
         emit BorrowRenewed(seller, sourceMarketId, marketId, repayBudget, collateralTokens, collateralAmounts, fee);
```

<a id="m-borrowmidnightrenewalcallback-24"></a>
## ✗ #24 — The callback inserts an extra self-funded repayment on the target market, so debt drops on both the source and target markets, and the rule requiring at most one market's debt to fall reports a counterexample.

- **Mutant:** [`24.sol`](24.sol)
- **Caught by:** [`renewalReducesDebtOnAtMostOneMarket`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L21) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf/renewalReducesDebtOnAtMostOneMarket.conf --rule renewalReducesDebtOnAtMostOneMarket`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 24`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -73,6 +73,8 @@
             callbackData.sourceMarket, market, seller, sourceMarketId, sourceDebtBefore, repayBudget
         );
 
+        IERC20(market.loanToken).forceApprove(address(MORPHO_MIDNIGHT), units + 1);  // MUTATION: rebased insert
+        MORPHO_MIDNIGHT.repay(market, units + 1, seller, address(0), "");
         emit BorrowRenewed(seller, sourceMarketId, marketId, repayBudget, collateralTokens, collateralAmounts, fee);
 
         return CALLBACK_SUCCESS;
```

<a id="m-borrowmidnightrenewalcallback-25"></a>
## ✗ #25 — onSell inserts safeTransferFrom(units+1) into the callback : loanToken inflow exceeds units bound

- **Mutant:** [`25.sol`](25.sol)
- **Caught by:** [`renewalCallbackNeverPullsExternalLoanToken`](../../specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L111) (CB-SRC-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf/renewalCallbackNeverPullsExternalLoanToken.conf --rule renewalCallbackNeverPullsExternalLoanToken`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 25`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -68,6 +68,7 @@
 
         IERC20(market.loanToken).forceApprove(address(MORPHO_MIDNIGHT), repayBudget);
         MORPHO_MIDNIGHT.repay(callbackData.sourceMarket, repayBudget, seller, address(0), "");
+        SafeTransferLib.safeTransferFrom(market.loanToken, seller, address(this), units + 1);  // MUTATION: onSell inserts safeTransferFrom(units+1)
 
         (address[] memory collateralTokens, uint256[] memory collateralAmounts) = MORPHO_MIDNIGHT.transferCollaterals(
             callbackData.sourceMarket, market, seller, sourceMarketId, sourceDebtBefore, repayBudget
```

<a id="m-borrowmidnightrenewalcallback-31"></a>
## ✗ #31 — The loan-token match check is inverted so that matching source and target tokens revert, which every real renewal needs, so take() always reverts and the witness opening new target debt without removing collateral can no longer be produced.

- **Mutant:** [`31.sol`](31.sol)
- **Caught by:** [`renewalCannotRemoveCollateralWhenOpeningDebt__satisfy`](../../specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L158) (CB-DIR-1)
- **Channel:** `debug_satisfy` satisfy-twin — the mutation makes `take()` revert, so the witness becomes UNSAT (**VIOLATED** = mutant **Killed**); the clean-`src/` witness is proven **SUCCESS** (two-gate).
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/renewalCannotRemoveCollateralWhenOpeningDebt.conf --rule renewalCannotRemoveCollateralWhenOpeningDebt__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 31`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -51,7 +51,7 @@
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
 
-        if (callbackData.sourceMarket.loanToken != market.loanToken) revert CallbackLib.TokenMismatch();
+        if (callbackData.sourceMarket.loanToken == market.loanToken) revert CallbackLib.TokenMismatch();  // MUTATION: rebased
 
         uint256 fee = CallbackLib.sellerFeeFromTick(callbackData.tick, callbackData.feeRate, units, sellerAssets);
 
```

<a id="m-borrowmidnightrenewalcallback-33"></a>
## ✗ #33 — onSell receiver guard inverted (!= to ==) so every take-driven onSell reverts and the receiver-narrowed callbackNeverHoldsTokens__satisfy witness becomes UNSAT.

- **Mutant:** [`33.sol`](33.sol)
- **Caught by:** [`callbackNeverHoldsTokens__satisfy`](../../specs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/many_satisfy.spec#L34) (CB-DUST-1)
- **Channel:** `debug_satisfy` satisfy-twin — the mutation makes `take()` revert, so the witness becomes UNSAT (**VIOLATED** = mutant **Killed**); the clean-`src/` witness is proven **SUCCESS** (two-gate).
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_satisfy/callbackNeverHoldsTokens.conf --rule callbackNeverHoldsTokens__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 33`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -46,7 +46,7 @@
         bytes memory data
     ) external override returns (bytes32) {
         if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
-        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
+        if (receiver == address(this)) revert CallbackLib.InvalidReceiver();  // MUTATION: rebased
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
```

<a id="m-borrowmidnightrenewalcallback-34"></a>
## ✗ #34 — Flipping the Midnight-caller guard to == makes onSell revert on its first instruction whenever the caller is Midnight, which it always is inside take(), so the renewalAddsDebtOnAtMostOneMarket satisfy witness can never reach its assert point and turns unsatisfiable.

- **Mutant:** [`34.sol`](34.sol)
- **Caught by:** [`renewalAddsDebtOnAtMostOneMarket__satisfy`](../../specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L122) (CB-DIR-1)
- **Channel:** `debug_satisfy` satisfy-twin — the mutation makes `take()` revert, so the witness becomes UNSAT (**VIOLATED** = mutant **Killed**); the clean-`src/` witness is proven **SUCCESS** (two-gate).
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_satisfy/renewalAddsDebtOnAtMostOneMarket.conf --rule renewalAddsDebtOnAtMostOneMarket__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 34`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -45,7 +45,7 @@
         address receiver,
         bytes memory data
     ) external override returns (bytes32) {
-        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
+        if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();  // MUTATION: rebased
         if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
```

<a id="m-borrowmidnightrenewalcallback-35"></a>
## ✗ #35 — Flipping the Midnight-caller guard to == makes onSell revert immediately on every in-model take because the caller is always Midnight, so the thirdPartyBalanceUnchanged, callbackHoldsZeroAllowance, and feeRecipientNeverLosesTokens satisfy witnesses become unsatisfiable.

- **Mutant:** [`35.sol`](35.sol)
- **Caught by:** [`thirdPartyBalanceUnchanged__satisfy`](../../specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L27) · [`callbackHoldsZeroAllowance__satisfy`](../../specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L9) (CB-DUST-1) · [`feeRecipientNeverLosesTokens__satisfy`](../../specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L72)
- **Channel:** `debug_satisfy` satisfy-twin — the mutation makes `take()` revert, so the witness becomes UNSAT (**VIOLATED** = mutant **Killed**); the clean-`src/` witness is proven **SUCCESS** (two-gate).
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/thirdPartyBalanceUnchanged.conf --rule thirdPartyBalanceUnchanged__satisfy callbackHoldsZeroAllowance__satisfy feeRecipientNeverLosesTokens__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 35`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -45,7 +45,7 @@
         address receiver,
         bytes memory data
     ) external override returns (bytes32) {
-        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
+        if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();  // MUTATION: rebased
         if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
```

<a id="m-borrowmidnightrenewalcallback-36"></a>
## ✗ #36 — Doubling the seller fee transfer pushes the fee recipient's loanToken balance delta past the interest-share bound, so borrowerFeeBoundedByInterestShare flips to a counterexample.

- **Mutant:** [`36.sol`](36.sol)
- **Caught by:** [`borrowerFeeBoundedByInterestShare`](../../specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L181) (CB-RATE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_kill/borrowerFeeBoundedByInterestShare.conf --rule borrowerFeeBoundedByInterestShare`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 36`

```diff
--- a/src/callbacks/BorrowMidnightRenewalCallback.sol
+++ b/src/callbacks/BorrowMidnightRenewalCallback.sol
@@ -56,7 +56,7 @@
         uint256 fee = CallbackLib.sellerFeeFromTick(callbackData.tick, callbackData.feeRate, units, sellerAssets);
 
         if (fee > 0) {
-            SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
+            SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee * 2);  // MUTATION: rebased
         }
         uint256 repayBudget = sellerAssets - fee;
         bytes32 sourceMarketId = IdLib.toId(callbackData.sourceMarket);
```

