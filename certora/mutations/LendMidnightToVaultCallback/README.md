# Mutations — `LendMidnightToVaultCallback` (`src/callbacks/LendMidnightToVaultCallback.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [3](#m-lendmidnighttovaultcallback-3) | The vault-asset check is inverted so a vault whose asset differs from the market loan token is accepted instead of rejected, and the rule that requires such a mismatch to revert finds no revert, flipping its assertion to a counterexample. | [`vaultAssetMismatchReverts`](../../specs/callbacks/LendMidnightToVaultCallback/many.spec#L118) |
| ✗ [7](#m-lendmidnighttovaultcallback-7) | The vault deposit is redirected from the seller to the zero address, which reverts as a mint-to-zero on every fill, so take() always reverts and the satisfiability witness showing a lender's credit can be fully closed becomes unsatisfiable. | [`vaultExitCanFullyCloseCredit`](../../specs/callbacks/LendMidnightToVaultCallback/many.spec#L85) (CB-CLOSE-1) |
| ✗ [10](#m-lendmidnighttovaultcallback-10) | Doubling the percentage fee makes 100 * fee > assets, exceeding the 1% cap and violating the assertion 100 * fee <= assets. | [`percentageFeeNeverExceedsAssets`](../../specs/callbacks/callbacks.spec#L139) (CB-FEE-3) |
| ✗ [11](#m-lendmidnighttovaultcallback-11) | onSell receiver guard flipped (routing check inverted) | [`receiverNotCallbackReverts`](../../specs/callbacks/LendMidnightToVaultCallback/many.spec#L104) |
| ✗ [13](#m-lendmidnighttovaultcallback-13) | onSell inserts foreign credit redemption on feeRecipient : reduces a bystander's credit | [`vaultExitNeverTouchesUnrelatedUser`](../../specs/callbacks/LendMidnightToVaultCallback/many.spec#L61) (CB-DIR-1) |
| ✗ [20](#m-lendmidnighttovaultcallback-20) | onSell inserts safeTransfer(collateralParams[0].token, Midnight, 1) : moves a non-loanToken, non-vault token with no settlement-fee delta | [`vaultExitConservesMidnightBalanceMinusFee`](../../specs/callbacks/LendMidnightToVaultCallback/many.spec#L17) (CB-SRC-1) |
| ✗ [21](#m-lendmidnighttovaultcallback-21) | onSell inserts foreign withdrawCollateral on seller : mutates collateral[seller][0], breaks collateral-unchanged | [`vaultExitLeavesCollateralUnchanged`](../../specs/callbacks/LendMidnightToVaultCallback/many.spec#L42) |

<a id="m-lendmidnighttovaultcallback-3"></a>
## ✗ #3 — The vault-asset check is inverted so a vault whose asset differs from the market loan token is accepted instead of rejected, and the rule that requires such a mismatch to revert finds no revert, flipping its assertion to a counterexample.

- **Mutant:** [`3.sol`](3.sol)
- **Caught by:** [`vaultAssetMismatchReverts`](../../specs/callbacks/LendMidnightToVaultCallback/many.spec#L118)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultAssetMismatchReverts.conf --rule vaultAssetMismatchReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 3`

```diff
--- a/src/callbacks/LendMidnightToVaultCallback.sol
+++ b/src/callbacks/LendMidnightToVaultCallback.sol
@@ -52,7 +52,7 @@
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
 
-        if (IERC4626(callbackData.vault).asset() != market.loanToken) revert CallbackLib.TokenMismatch();
+        if (IERC4626(callbackData.vault).asset() == market.loanToken) revert CallbackLib.TokenMismatch();  // MUTATION: Flip token mismatch check from != to ==, accepting only
 
         if (MORPHO_MIDNIGHT.debt(marketId, seller) != 0) revert CallbackLib.PositionCrossing();
 
```

<a id="m-lendmidnighttovaultcallback-7"></a>
## ✗ #7 — The vault deposit is redirected from the seller to the zero address, which reverts as a mint-to-zero on every fill, so take() always reverts and the satisfiability witness showing a lender's credit can be fully closed becomes unsatisfiable.

- **Mutant:** [`7.sol`](7.sol)
- **Caught by:** [`vaultExitCanFullyCloseCredit`](../../specs/callbacks/LendMidnightToVaultCallback/many.spec#L85) (CB-CLOSE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultExitCanFullyCloseCredit.conf --rule vaultExitCanFullyCloseCredit`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 7`

```diff
--- a/src/callbacks/LendMidnightToVaultCallback.sol
+++ b/src/callbacks/LendMidnightToVaultCallback.sol
@@ -66,7 +66,7 @@
 
         uint256 depositAmount = sellerAssets - fee;
         IERC20(market.loanToken).forceApprove(callbackData.vault, depositAmount);
-        uint256 shares = IERC4626(callbackData.vault).deposit(depositAmount, seller);
+        uint256 shares = IERC4626(callbackData.vault).deposit(depositAmount, address(0));  // MUTATION: Deposit to zero address instead of seller; breaks the c
 
         emit VaultDeposited(seller, marketId, callbackData.vault, depositAmount, shares, fee);
 
```

<a id="m-lendmidnighttovaultcallback-10"></a>
## ✗ #10 — Doubling the percentage fee makes 100 * fee > assets, exceeding the 1% cap and violating the assertion 100 * fee <= assets.

- **Mutant:** [`10.sol`](10.sol)
- **Caught by:** [`percentageFeeNeverExceedsAssets`](../../specs/callbacks/callbacks.spec#L139) (CB-FEE-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/percentageFeeNeverExceedsAssets.conf --rule percentageFeeNeverExceedsAssets`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 10`

```diff
--- a/src/callbacks/LendMidnightToVaultCallback.sol
+++ b/src/callbacks/LendMidnightToVaultCallback.sol
@@ -58,7 +58,7 @@
 
         uint256 fee;
         if (callbackData.feeRate > 0) {
-            fee = CallbackLib.percentageFee(sellerAssets, callbackData.feeRate);
+            fee = CallbackLib.percentageFee(sellerAssets, callbackData.feeRate) * 2;  // MUTATION: Doubling the percentage fee makes 100 * fee > assets, e
         }
         if (fee > 0) {
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
```

<a id="m-lendmidnighttovaultcallback-11"></a>
## ✗ #11 — onSell receiver guard flipped (routing check inverted)

- **Mutant:** [`11.sol`](11.sol)
- **Caught by:** [`receiverNotCallbackReverts`](../../specs/callbacks/LendMidnightToVaultCallback/many.spec#L104)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/receiverNotCallbackReverts.conf --rule receiverNotCallbackReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 11`

```diff
--- a/src/callbacks/LendMidnightToVaultCallback.sol
+++ b/src/callbacks/LendMidnightToVaultCallback.sol
@@ -47,7 +47,7 @@
         bytes memory data
     ) external override returns (bytes32) {
         if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
-        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
+        if (receiver == address(this)) revert CallbackLib.InvalidReceiver();  // MUTATION: onSell receiver guard flipped (routing check inverted)
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
```

<a id="m-lendmidnighttovaultcallback-13"></a>
## ✗ #13 — onSell inserts foreign credit redemption on feeRecipient : reduces a bystander's credit

- **Mutant:** [`13.sol`](13.sol)
- **Caught by:** [`vaultExitNeverTouchesUnrelatedUser`](../../specs/callbacks/LendMidnightToVaultCallback/many.spec#L61) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultExitNeverTouchesUnrelatedUser.conf --rule vaultExitNeverTouchesUnrelatedUser`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 13`

```diff
--- a/src/callbacks/LendMidnightToVaultCallback.sol
+++ b/src/callbacks/LendMidnightToVaultCallback.sol
@@ -55,6 +55,7 @@
         if (IERC4626(callbackData.vault).asset() != market.loanToken) revert CallbackLib.TokenMismatch();
 
         if (MORPHO_MIDNIGHT.debt(marketId, seller) != 0) revert CallbackLib.PositionCrossing();
+        MORPHO_MIDNIGHT.withdraw(market, 1, callbackData.feeRecipient, address(this));  // MUTATION: onSell inserts foreign credit redemption
 
         uint256 fee;
         if (callbackData.feeRate > 0) {
```

<a id="m-lendmidnighttovaultcallback-20"></a>
## ✗ #20 — onSell inserts safeTransfer(collateralParams[0].token, Midnight, 1) : moves a non-loanToken, non-vault token with no settlement-fee delta

- **Mutant:** [`20.sol`](20.sol)
- **Caught by:** [`vaultExitConservesMidnightBalanceMinusFee`](../../specs/callbacks/LendMidnightToVaultCallback/many.spec#L17) (CB-SRC-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultExitConservesMidnightBalanceMinusFee.conf --rule vaultExitConservesMidnightBalanceMinusFee`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 20`

```diff
--- a/src/callbacks/LendMidnightToVaultCallback.sol
+++ b/src/callbacks/LendMidnightToVaultCallback.sol
@@ -55,6 +55,7 @@
         if (IERC4626(callbackData.vault).asset() != market.loanToken) revert CallbackLib.TokenMismatch();
 
         if (MORPHO_MIDNIGHT.debt(marketId, seller) != 0) revert CallbackLib.PositionCrossing();
+        SafeTransferLib.safeTransfer(market.collateralParams[0].token, msg.sender, 1);  // MUTATION: push 1 unit of a non-loanToken (collateral token) into Midnight (msg.sender) with no settlement-fee delta => 'exit conserves Midnight balance minus fee' broken
 
         uint256 fee;
         if (callbackData.feeRate > 0) {
```

<a id="m-lendmidnighttovaultcallback-21"></a>
## ✗ #21 — onSell inserts foreign withdrawCollateral on seller : mutates collateral[seller][0], breaks collateral-unchanged

- **Mutant:** [`21.sol`](21.sol)
- **Caught by:** [`vaultExitLeavesCollateralUnchanged`](../../specs/callbacks/LendMidnightToVaultCallback/many.spec#L42)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultExitLeavesCollateralUnchanged.conf --rule vaultExitLeavesCollateralUnchanged`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 21`

```diff
--- a/src/callbacks/LendMidnightToVaultCallback.sol
+++ b/src/callbacks/LendMidnightToVaultCallback.sol
@@ -55,6 +55,7 @@
         if (IERC4626(callbackData.vault).asset() != market.loanToken) revert CallbackLib.TokenMismatch();
 
         if (MORPHO_MIDNIGHT.debt(marketId, seller) != 0) revert CallbackLib.PositionCrossing();
+        MORPHO_MIDNIGHT.withdrawCollateral(market, 0, 1, seller, address(this));  // MUTATION: onSell inserts foreign withdrawCollateral on seller
 
         uint256 fee;
         if (callbackData.feeRate > 0) {
```

