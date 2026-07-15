# Mutations — `MidnightWithdrawVaultSharesCallback` (`src/callbacks/MidnightWithdrawVaultSharesCallback.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [1](#m-midnightwithdrawvaultsharescallback-1) | off-by-one over-withdraw: sharesToWithdraw + 1 leaves a residual vault share in the callback | [`takeLeavesVaultShareBalanceUnchanged`](../../specs/callbacks/MidnightWithdrawVaultSharesCallback/many.spec#L32) (CB-VAULT-WD-1) |
| ✗ [2](#m-midnightwithdrawvaultsharescallback-2) | leave 1 wei allowance to Midnight (approve buyerAssets+1) | [`callbackHoldsZeroAllowance`](../../specs/callbacks/callbacks.spec#L7) (CB-DUST-1) |
| ✗ [5](#m-midnightwithdrawvaultsharescallback-5) | Withdrawing 0 collateral instead of the computed amount prevents collateral reduction; the assertion that collateral < collateralBefore fails. | [`takeCanDropCollateralOnNarrowedMarket`](../../specs/callbacks/MidnightWithdrawVaultSharesCallback/many.spec#L14) (CB-VAULT-WD-1) |
| ✗ [6](#m-midnightwithdrawvaultsharescallback-6) | Withdrawing only half the assets leaves the callback holding half of the vault shares; the assertion that callback balance == 0 fails. | [`callbackNeverHoldsTokens`](../../specs/callbacks/callbacks.spec#L57) (CB-DUST-1) |
| ✗ [8](#m-midnightwithdrawvaultsharescallback-8) | The callback approves Midnight for zero loanToken instead of buyerAssets, so Midnight cannot pull the funds and take() reverts, leaving the rule unable to witness a successful withdraw fill. | [`takeLeavesVaultShareBalanceUnchanged__satisfy`](../../specs/callbacks/MidnightWithdrawVaultSharesCallback/debug_satisfy/many_satisfy.spec#L74) (CB-VAULT-WD-1) |

<a id="m-midnightwithdrawvaultsharescallback-1"></a>
## ✗ #1 — off-by-one over-withdraw: sharesToWithdraw + 1 leaves a residual vault share in the callback

- **Mutant:** [`1.sol`](1.sol)
- **Caught by:** [`takeLeavesVaultShareBalanceUnchanged`](../../specs/callbacks/MidnightWithdrawVaultSharesCallback/many.spec#L32) (CB-VAULT-WD-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/takeLeavesVaultShareBalanceUnchanged.conf --rule takeLeavesVaultShareBalanceUnchanged`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightWithdrawVaultSharesCallback 1`

```diff
--- a/src/callbacks/MidnightWithdrawVaultSharesCallback.sol
+++ b/src/callbacks/MidnightWithdrawVaultSharesCallback.sol
@@ -55,7 +55,7 @@
 
         uint256 sharesToWithdraw = IERC4626(callbackData.vault).previewWithdraw(buyerAssets);
 
-        MORPHO_MIDNIGHT.withdrawCollateral(market, callbackData.collateralIndex, sharesToWithdraw, buyer, address(this));
+        MORPHO_MIDNIGHT.withdrawCollateral(market, callbackData.collateralIndex, sharesToWithdraw + 1, buyer, address(this));  // MUTATION: off-by-one over-withdraw: sharesToWithdraw + 1 leaves a
 
         IERC4626(callbackData.vault).withdraw(buyerAssets, address(this), address(this));
 
```

<a id="m-midnightwithdrawvaultsharescallback-2"></a>
## ✗ #2 — leave 1 wei allowance to Midnight (approve buyerAssets+1)

- **Mutant:** [`2.sol`](2.sol)
- **Caught by:** [`callbackHoldsZeroAllowance`](../../specs/callbacks/callbacks.spec#L7) (CB-DUST-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/callbackHoldsZeroAllowance.conf --rule callbackHoldsZeroAllowance`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightWithdrawVaultSharesCallback 2`

```diff
--- a/src/callbacks/MidnightWithdrawVaultSharesCallback.sol
+++ b/src/callbacks/MidnightWithdrawVaultSharesCallback.sol
@@ -59,7 +59,7 @@
 
         IERC4626(callbackData.vault).withdraw(buyerAssets, address(this), address(this));
 
-        IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);
+        IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets + 1);  // MUTATION: leave 1 wei allowance to Midnight (approve buyerAssets+
 
         emit VaultSharesWithdrawn(buyer, marketId, callbackData.vault, buyerAssets, sharesToWithdraw);
 
```

<a id="m-midnightwithdrawvaultsharescallback-5"></a>
## ✗ #5 — Withdrawing 0 collateral instead of the computed amount prevents collateral reduction; the assertion that collateral < collateralBefore fails.

- **Mutant:** [`5.sol`](5.sol)
- **Caught by:** [`takeCanDropCollateralOnNarrowedMarket`](../../specs/callbacks/MidnightWithdrawVaultSharesCallback/many.spec#L14) (CB-VAULT-WD-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/takeCanDropCollateralOnNarrowedMarket.conf --rule takeCanDropCollateralOnNarrowedMarket`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightWithdrawVaultSharesCallback 5`

```diff
--- a/src/callbacks/MidnightWithdrawVaultSharesCallback.sol
+++ b/src/callbacks/MidnightWithdrawVaultSharesCallback.sol
@@ -55,7 +55,7 @@
 
         uint256 sharesToWithdraw = IERC4626(callbackData.vault).previewWithdraw(buyerAssets);
 
-        MORPHO_MIDNIGHT.withdrawCollateral(market, callbackData.collateralIndex, sharesToWithdraw, buyer, address(this));
+        MORPHO_MIDNIGHT.withdrawCollateral(market, callbackData.collateralIndex, 0, buyer, address(this));  // MUTATION: Withdrawing 0 collateral instead of the computed amount
 
         IERC4626(callbackData.vault).withdraw(buyerAssets, address(this), address(this));
 
```

<a id="m-midnightwithdrawvaultsharescallback-6"></a>
## ✗ #6 — Withdrawing only half the assets leaves the callback holding half of the vault shares; the assertion that callback balance == 0 fails.

- **Mutant:** [`6.sol`](6.sol)
- **Caught by:** [`callbackNeverHoldsTokens`](../../specs/callbacks/callbacks.spec#L57) (CB-DUST-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/callbackNeverHoldsTokens.conf --rule callbackNeverHoldsTokens`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightWithdrawVaultSharesCallback 6`

```diff
--- a/src/callbacks/MidnightWithdrawVaultSharesCallback.sol
+++ b/src/callbacks/MidnightWithdrawVaultSharesCallback.sol
@@ -57,7 +57,7 @@
 
         MORPHO_MIDNIGHT.withdrawCollateral(market, callbackData.collateralIndex, sharesToWithdraw, buyer, address(this));
 
-        IERC4626(callbackData.vault).withdraw(buyerAssets, address(this), address(this));
+        IERC4626(callbackData.vault).withdraw(buyerAssets / 2, address(this), address(this));  // MUTATION: Withdrawing only half the assets leaves the callback ho
 
         IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);
 
```

<a id="m-midnightwithdrawvaultsharescallback-8"></a>
## ✗ #8 — The callback approves Midnight for zero loanToken instead of buyerAssets, so Midnight cannot pull the funds and take() reverts, leaving the rule unable to witness a successful withdraw fill.

- **Mutant:** [`8.sol`](8.sol)
- **Caught by:** [`takeLeavesVaultShareBalanceUnchanged__satisfy`](../../specs/callbacks/MidnightWithdrawVaultSharesCallback/debug_satisfy/many_satisfy.spec#L74) (CB-VAULT-WD-1)
- **Channel:** `debug_satisfy` satisfy-twin — the mutation makes `take()` revert, so the witness becomes UNSAT (**VIOLATED** = mutant **Killed**); the clean-`src/` witness is proven **SUCCESS** (two-gate).
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/debug_satisfy/takeLeavesVaultShareBalanceUnchanged.conf --rule takeLeavesVaultShareBalanceUnchanged__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightWithdrawVaultSharesCallback 8`

```diff
--- a/src/callbacks/MidnightWithdrawVaultSharesCallback.sol
+++ b/src/callbacks/MidnightWithdrawVaultSharesCallback.sol
@@ -59,7 +59,7 @@
 
         IERC4626(callbackData.vault).withdraw(buyerAssets, address(this), address(this));
 
-        IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);
+        IERC20(market.loanToken).forceApprove(msg.sender, 0); // MUTATION: approve 0 -> Midnight cannot pull loanToken -> take reverts
 
         emit VaultSharesWithdrawn(buyer, marketId, callbackData.vault, buyerAssets, sharesToWithdraw);
 
```

