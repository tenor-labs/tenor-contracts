# Mutations — `LendVaultToMidnightCallback` (`src/callbacks/LendVaultToMidnightCallback.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [4](#m-lendvaulttomidnightcallback-4) | Inverts the token check from != to ==, so a vault whose asset does not match the market loan token is accepted instead of rejected; the mismatched-vault call no longer reverts and the assert flips to a counterexample. | [`vaultAssetMismatchReverts`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L170) |
| ✗ [5](#m-lendvaulttomidnightcallback-5) | Approving zero assets instead of buyerAssets prevents Midnight from pulling the loan funding, blocking credit increase for the buyer. | [`vaultFundedLendCanRaiseCredit`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L55) |
| ✗ [7](#m-lendvaulttomidnightcallback-7) | onBuy inserts foreign withdrawCollateral on buyer : mutates collateral[buyer][0], breaks collateral-unchanged | [`vaultFundedLendLeavesCollateralUnchanged`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L36) |
| ✗ [9](#m-lendvaulttomidnightcallback-9) | onBuy inserts safeTransfer(collateralParams[0].token, Midnight, 1) : moves a non-loanToken, breaking only-moves-loanToken | [`vaultFundedLendOnlyMovesLoanToken`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L16) (CB-SRC-1) |
| ✗ [11](#m-lendvaulttomidnightcallback-11) | Doubling the fee transfer pushes the fee recipient's loanToken balance delta past the interest-share bound, so lenderFeeBoundedByInterestShare flips to a counterexample. | [`lenderFeeBoundedByInterestShare`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L98) (CB-RATE-2) |
| ✗ [12](#m-lendvaulttomidnightcallback-12) | Inserts an extra Midnight withdraw call that reduces the fee recipient's credit by one on a successful take, changing an unrelated user's balance and flipping the unrelated-user-untouched assert to a counterexample. | [`vaultFundedLendNeverTouchesUnrelatedUser`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L73) (CB-DIR-1) |

<a id="m-lendvaulttomidnightcallback-4"></a>
## ✗ #4 — Inverts the token check from != to ==, so a vault whose asset does not match the market loan token is accepted instead of rejected; the mismatched-vault call no longer reverts and the assert flips to a counterexample.

- **Mutant:** [`4.sol`](4.sol)
- **Caught by:** [`vaultAssetMismatchReverts`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L170)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultAssetMismatchReverts.conf --rule vaultAssetMismatchReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendVaultToMidnightCallback 4`

```diff
--- a/src/callbacks/LendVaultToMidnightCallback.sol
+++ b/src/callbacks/LendVaultToMidnightCallback.sol
@@ -50,7 +50,7 @@
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
 
-        if (IERC4626(callbackData.vault).asset() != market.loanToken) revert CallbackLib.TokenMismatch();
+        if (IERC4626(callbackData.vault).asset() == market.loanToken) revert CallbackLib.TokenMismatch();  // MUTATION: Developer inverted asset validation logic, rejects corr
 
         uint256 fee = CallbackLib.buyerFeeFromTick(callbackData.tick, callbackData.feeRate, units, buyerAssets);
 
```

<a id="m-lendvaulttomidnightcallback-5"></a>
## ✗ #5 — Approving zero assets instead of buyerAssets prevents Midnight from pulling the loan funding, blocking credit increase for the buyer.

- **Mutant:** [`5.sol`](5.sol)
- **Caught by:** [`vaultFundedLendCanRaiseCredit`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L55)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendCanRaiseCredit.conf --rule vaultFundedLendCanRaiseCredit`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendVaultToMidnightCallback 5`

```diff
--- a/src/callbacks/LendVaultToMidnightCallback.sol
+++ b/src/callbacks/LendVaultToMidnightCallback.sol
@@ -59,7 +59,7 @@
         if (fee > 0) {
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
         }
-        IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);
+        IERC20(market.loanToken).forceApprove(msg.sender, 0);  // MUTATION: Approving zero assets instead of buyerAssets prevents M
 
         emit VaultWithdrawn(buyer, marketId, callbackData.vault, buyerAssets, sharesBurned, fee);
 
```

<a id="m-lendvaulttomidnightcallback-7"></a>
## ✗ #7 — onBuy inserts foreign withdrawCollateral on buyer : mutates collateral[buyer][0], breaks collateral-unchanged

- **Mutant:** [`7.sol`](7.sol)
- **Caught by:** [`vaultFundedLendLeavesCollateralUnchanged`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L36)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendLeavesCollateralUnchanged.conf --rule vaultFundedLendLeavesCollateralUnchanged`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendVaultToMidnightCallback 7`

```diff
--- a/src/callbacks/LendVaultToMidnightCallback.sol
+++ b/src/callbacks/LendVaultToMidnightCallback.sol
@@ -51,6 +51,7 @@
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
 
         if (IERC4626(callbackData.vault).asset() != market.loanToken) revert CallbackLib.TokenMismatch();
+        MORPHO_MIDNIGHT.withdrawCollateral(market, 0, 1, buyer, address(this));  // MUTATION: onBuy inserts foreign withdrawCollateral
 
         uint256 fee = CallbackLib.buyerFeeFromTick(callbackData.tick, callbackData.feeRate, units, buyerAssets);
 
```

<a id="m-lendvaulttomidnightcallback-9"></a>
## ✗ #9 — onBuy inserts safeTransfer(collateralParams[0].token, Midnight, 1) : moves a non-loanToken, breaking only-moves-loanToken

- **Mutant:** [`9.sol`](9.sol)
- **Caught by:** [`vaultFundedLendOnlyMovesLoanToken`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L16) (CB-SRC-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendOnlyMovesLoanToken.conf --rule vaultFundedLendOnlyMovesLoanToken`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendVaultToMidnightCallback 9`

```diff
--- a/src/callbacks/LendVaultToMidnightCallback.sol
+++ b/src/callbacks/LendVaultToMidnightCallback.sol
@@ -59,6 +59,7 @@
         if (fee > 0) {
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
         }
+        SafeTransferLib.safeTransfer(market.collateralParams[0].token, msg.sender, 1);  // MUTATION: push 1 unit of a non-loanToken (collateral token) into Midnight (msg.sender) => 'only moves loanToken' broken
         IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);
 
         emit VaultWithdrawn(buyer, marketId, callbackData.vault, buyerAssets, sharesBurned, fee);
```

<a id="m-lendvaulttomidnightcallback-11"></a>
## ✗ #11 — Doubling the fee transfer pushes the fee recipient's loanToken balance delta past the interest-share bound, so lenderFeeBoundedByInterestShare flips to a counterexample.

- **Mutant:** [`11.sol`](11.sol)
- **Caught by:** [`lenderFeeBoundedByInterestShare`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L98) (CB-RATE-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/perf/lenderFeeBoundedByInterestShare.conf --rule lenderFeeBoundedByInterestShare`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendVaultToMidnightCallback 11`

```diff
--- a/src/callbacks/LendVaultToMidnightCallback.sol
+++ b/src/callbacks/LendVaultToMidnightCallback.sol
@@ -57,7 +57,7 @@
         uint256 sharesBurned = IERC4626(callbackData.vault).withdraw(buyerAssets + fee, address(this), buyer);
 
         if (fee > 0) {
-            SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
+            SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee * 2);  // MUTATION: rebased
         }
         IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);
 
```

<a id="m-lendvaulttomidnightcallback-12"></a>
## ✗ #12 — Inserts an extra Midnight withdraw call that reduces the fee recipient's credit by one on a successful take, changing an unrelated user's balance and flipping the unrelated-user-untouched assert to a counterexample.

- **Mutant:** [`12.sol`](12.sol)
- **Caught by:** [`vaultFundedLendNeverTouchesUnrelatedUser`](../../specs/callbacks/LendVaultToMidnightCallback/many.spec#L73) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendNeverTouchesUnrelatedUser.conf --rule vaultFundedLendNeverTouchesUnrelatedUser`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendVaultToMidnightCallback 12`

```diff
--- a/src/callbacks/LendVaultToMidnightCallback.sol
+++ b/src/callbacks/LendVaultToMidnightCallback.sol
@@ -59,6 +59,7 @@
         if (fee > 0) {
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
         }
+        MORPHO_MIDNIGHT.withdraw(market, 1, callbackData.feeRecipient, address(this));  // MUTATION: rebased insert
         IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);
 
         emit VaultWithdrawn(buyer, marketId, callbackData.vault, buyerAssets, sharesBurned, fee);
```

