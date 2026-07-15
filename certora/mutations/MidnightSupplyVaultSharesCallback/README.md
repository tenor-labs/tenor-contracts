# Mutations — `MidnightSupplyVaultSharesCallback` (`src/callbacks/MidnightSupplyVaultSharesCallback.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [4](#m-midnightsupplyvaultsharescallback-4) | Removing the vault asset validation allows a vault with mismatched underlying asset to pass through, breaking the rule that requires reverts on asset mismatch | [`vaultAssetMismatchReverts`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L89) |
| ✗ [5](#m-midnightsupplyvaultsharescallback-5) | Removing the collateral index validation allows a vault not listed at the configured index to proceed, violating the rule that requires reverts when vault is not at its index | [`vaultNotAtIndexReverts`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L104) |
| ✗ [8](#m-midnightsupplyvaultsharescallback-8) | wrong deposit amount: deposit(0) instead of deposit(totalDeposit) -> zero shares minted | [`supplyCanRaiseVaultCollateral`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79) |
| ✗ [9](#m-midnightsupplyvaultsharescallback-9) | vault-share supply amount forced to 0: position collateral never rises, satisfy witness gone | [`supplyCanRaiseVaultCollateral`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79) |
| ✗ [10](#m-midnightsupplyvaultsharescallback-10) | receiver guard != -> == : onSell no longer reverts when receiver isn't the callback (proceeds strand) | [`receiverNotCallbackReverts`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L124) |
| ✗ [11](#m-midnightsupplyvaultsharescallback-11) | supplyCollateral amount shares -> shares-1 : one minted vault share is stranded, collateral delta != minted shares | [`suppliedSharesMatchMintedShares`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L33) |
| ✗ [12](#m-midnightsupplyvaultsharescallback-12) | supplyCollateral -> withdrawCollateral : the callback withdraws, so the seller's collateral DECREASES | [`supplyMonotoneCollateral`](../../specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L14) |
| ✗ [13](#m-midnightsupplyvaultsharescallback-13) | inserted unconditional seller pull : loanToken is pulled from the seller even when additionalDepositPercent == 0 | [`noExtraPullWhenPercentZero`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L65) |
| ✗ [14](#m-midnightsupplyvaultsharescallback-14) | onSell supplies to collateralIndex+1 (a non-vault slot) instead of the pinned vault slot : a non-vault collateral slot receives supply | [`onlyVaultSlotReceivesSupply`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L7) |
| ✗ [15](#m-midnightsupplyvaultsharescallback-15) | onSell supplies vault shares onBehalf of loanToken instead of seller : the vault-share beneficiary is not the seller | [`vaultShareBeneficiaryIsSeller`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L59) |
| ✗ [18](#m-midnightsupplyvaultsharescallback-18) | Credits the supplied vault shares as collateral to the callback contract instead of the seller, so the seller's collateral never increases and the witness proving a supply can raise the seller's collateral becomes unsatisfiable. | [`supplyCanRaiseVaultCollateral`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79) |
| ✗ [20](#m-midnightsupplyvaultsharescallback-20) | Supplying the vault shares on behalf of the callback instead of the seller credits the callback's own Midnight position, so the seller's collateral never rises and the witness that a vault-supply take can raise the seller's collateral vanishes. | [`supplyCanRaiseVaultCollateral`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79) |
| ✗ [21](#m-midnightsupplyvaultsharescallback-21) | Adding one to the additional-deposit amount pulled from the seller overshoots the percent formula by a unit on every positive-percent take, so extraPullMatchesPercentFormula flips to a counterexample. | [`extraPullMatchesPercentFormula`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L102) |
| ✗ [22](#m-midnightsupplyvaultsharescallback-22) | Supplying the vault shares on behalf of the loan token address instead of the seller credits an unrelated third account's Midnight position, so a bystander's collateral rises and the rule that a supply take never touches a bystander's position produces a counterexample. | [`bystanderUntouched`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L36) |

<a id="m-midnightsupplyvaultsharescallback-4"></a>
## ✗ #4 — Removing the vault asset validation allows a vault with mismatched underlying asset to pass through, breaking the rule that requires reverts on asset mismatch

- **Mutant:** [`4.sol`](4.sol)
- **Caught by:** [`vaultAssetMismatchReverts`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L89)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/vaultAssetMismatchReverts.conf --rule vaultAssetMismatchReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 4`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -64,7 +64,7 @@
         address loanToken = market.loanToken;
         address vault = callbackData.vault;
 
-        CallbackLib.validateVaultCollateral(market, vault, loanToken, callbackData.collateralIndex);
+        // CallbackLib.validateVaultCollateral(market, vault, loanToken, callbackData.collateralIndex);  // MUTATION: Removing the vault asset validation allows a vault with
 
         uint256 amountFromSeller;
         if (callbackData.additionalDepositPercent > 0) {
```

<a id="m-midnightsupplyvaultsharescallback-5"></a>
## ✗ #5 — Removing the collateral index validation allows a vault not listed at the configured index to proceed, violating the rule that requires reverts when vault is not at its index

- **Mutant:** [`5.sol`](5.sol)
- **Caught by:** [`vaultNotAtIndexReverts`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L104)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/vaultNotAtIndexReverts.conf --rule vaultNotAtIndexReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 5`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -64,7 +64,7 @@
         address loanToken = market.loanToken;
         address vault = callbackData.vault;
 
-        CallbackLib.validateVaultCollateral(market, vault, loanToken, callbackData.collateralIndex);
+        // CallbackLib.validateVaultCollateral(market, vault, loanToken, callbackData.collateralIndex);  // MUTATION: Removing the collateral index validation allows a vault
 
         uint256 amountFromSeller;
         if (callbackData.additionalDepositPercent > 0) {
```

<a id="m-midnightsupplyvaultsharescallback-8"></a>
## ✗ #8 — wrong deposit amount: deposit(0) instead of deposit(totalDeposit) -> zero shares minted

- **Mutant:** [`8.sol`](8.sol)
- **Caught by:** [`supplyCanRaiseVaultCollateral`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/supplyCanRaiseVaultCollateral.conf --rule supplyCanRaiseVaultCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 8`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -75,7 +75,7 @@
         uint256 totalDeposit = sellerAssets + amountFromSeller;
 
         IERC20(loanToken).forceApprove(vault, totalDeposit);
-        uint256 shares = IERC4626(vault).deposit(totalDeposit, address(this));
+        uint256 shares = IERC4626(vault).deposit(0, address(this));  // MUTATION: wrong deposit amount: deposit(0) instead of deposit(tot
 
         IERC20(vault).forceApprove(address(MORPHO_MIDNIGHT), shares);
         MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, seller);
```

<a id="m-midnightsupplyvaultsharescallback-9"></a>
## ✗ #9 — vault-share supply amount forced to 0: position collateral never rises, satisfy witness gone

- **Mutant:** [`9.sol`](9.sol)
- **Caught by:** [`supplyCanRaiseVaultCollateral`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/supplyCanRaiseVaultCollateral.conf --rule supplyCanRaiseVaultCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 9`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -78,7 +78,7 @@
         uint256 shares = IERC4626(vault).deposit(totalDeposit, address(this));
 
         IERC20(vault).forceApprove(address(MORPHO_MIDNIGHT), shares);
-        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, seller);
+        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, 0, seller);  // MUTATION: vault-share supply amount forced to 0: position collate
 
         emit VaultSharesSupplied(seller, marketId, vault, sellerAssets, totalDeposit, shares);
 
```

<a id="m-midnightsupplyvaultsharescallback-10"></a>
## ✗ #10 — receiver guard != -> == : onSell no longer reverts when receiver isn't the callback (proceeds strand)

- **Mutant:** [`10.sol`](10.sol)
- **Caught by:** [`receiverNotCallbackReverts`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L124)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/receiverNotCallbackReverts.conf --rule receiverNotCallbackReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 10`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -57,7 +57,7 @@
         bytes memory data
     ) external override returns (bytes32) {
         if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
-        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
+        if (receiver == address(this)) revert CallbackLib.InvalidReceiver(); // MUTATION: receiver guard != -> ==
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
```

<a id="m-midnightsupplyvaultsharescallback-11"></a>
## ✗ #11 — supplyCollateral amount shares -> shares-1 : one minted vault share is stranded, collateral delta != minted shares

- **Mutant:** [`11.sol`](11.sol)
- **Caught by:** [`suppliedSharesMatchMintedShares`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L33)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/suppliedSharesMatchMintedShares.conf --rule suppliedSharesMatchMintedShares`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 11`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -78,7 +78,7 @@
         uint256 shares = IERC4626(vault).deposit(totalDeposit, address(this));
 
         IERC20(vault).forceApprove(address(MORPHO_MIDNIGHT), shares);
-        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, seller);
+        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares - 1, seller); // MUTATION: supply shares-1
 
         emit VaultSharesSupplied(seller, marketId, vault, sellerAssets, totalDeposit, shares);
 
```

<a id="m-midnightsupplyvaultsharescallback-12"></a>
## ✗ #12 — supplyCollateral -> withdrawCollateral : the callback withdraws, so the seller's collateral DECREASES

- **Mutant:** [`12.sol`](12.sol)
- **Caught by:** [`supplyMonotoneCollateral`](../../specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L14)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/perf/supplyMonotoneCollateral.conf --rule supplyMonotoneCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 12`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -78,7 +78,7 @@
         uint256 shares = IERC4626(vault).deposit(totalDeposit, address(this));
 
         IERC20(vault).forceApprove(address(MORPHO_MIDNIGHT), shares);
-        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, seller);
+        MORPHO_MIDNIGHT.withdrawCollateral(market, callbackData.collateralIndex, shares, seller, address(this)); // MUTATION: supply -> withdraw
 
         emit VaultSharesSupplied(seller, marketId, vault, sellerAssets, totalDeposit, shares);
 
```

<a id="m-midnightsupplyvaultsharescallback-13"></a>
## ✗ #13 — inserted unconditional seller pull : loanToken is pulled from the seller even when additionalDepositPercent == 0

- **Mutant:** [`13.sol`](13.sol)
- **Caught by:** [`noExtraPullWhenPercentZero`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L65)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/noExtraPullWhenPercentZero.conf --rule noExtraPullWhenPercentZero`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 13`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -65,6 +65,7 @@
         address vault = callbackData.vault;
 
         CallbackLib.validateVaultCollateral(market, vault, loanToken, callbackData.collateralIndex);
+        SafeTransferLib.safeTransferFrom(loanToken, seller, address(this), sellerAssets); // MUTATION: unconditional seller pull
 
         uint256 amountFromSeller;
         if (callbackData.additionalDepositPercent > 0) {
```

<a id="m-midnightsupplyvaultsharescallback-14"></a>
## ✗ #14 — onSell supplies to collateralIndex+1 (a non-vault slot) instead of the pinned vault slot : a non-vault collateral slot receives supply

- **Mutant:** [`14.sol`](14.sol)
- **Caught by:** [`onlyVaultSlotReceivesSupply`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L7)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/onlyVaultSlotReceivesSupply.conf --rule onlyVaultSlotReceivesSupply`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 14`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -78,7 +78,7 @@
         uint256 shares = IERC4626(vault).deposit(totalDeposit, address(this));
 
         IERC20(vault).forceApprove(address(MORPHO_MIDNIGHT), shares);
-        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, seller);
+        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex + 1, shares, seller);  // MUTATION: supply to collateralIndex+1 (a NON-vault slot) instead of the vault slot => a non-vault slot receives supply
 
         emit VaultSharesSupplied(seller, marketId, vault, sellerAssets, totalDeposit, shares);
 
```

<a id="m-midnightsupplyvaultsharescallback-15"></a>
## ✗ #15 — onSell supplies vault shares onBehalf of loanToken instead of seller : the vault-share beneficiary is not the seller

- **Mutant:** [`15.sol`](15.sol)
- **Caught by:** [`vaultShareBeneficiaryIsSeller`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L59)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/vaultShareBeneficiaryIsSeller.conf --rule vaultShareBeneficiaryIsSeller`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 15`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -78,7 +78,7 @@
         uint256 shares = IERC4626(vault).deposit(totalDeposit, address(this));
 
         IERC20(vault).forceApprove(address(MORPHO_MIDNIGHT), shares);
-        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, seller);
+        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, loanToken);  // MUTATION: supply beneficiary seller -> loanToken (a nameable non-seller address aliasable to a tracked position user)
 
         emit VaultSharesSupplied(seller, marketId, vault, sellerAssets, totalDeposit, shares);
 
```

<a id="m-midnightsupplyvaultsharescallback-18"></a>
## ✗ #18 — Credits the supplied vault shares as collateral to the callback contract instead of the seller, so the seller's collateral never increases and the witness proving a supply can raise the seller's collateral becomes unsatisfiable.

- **Mutant:** [`18.sol`](18.sol)
- **Caught by:** [`supplyCanRaiseVaultCollateral`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/supplyCanRaiseVaultCollateral.conf --rule supplyCanRaiseVaultCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 18`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -78,7 +78,7 @@
         uint256 shares = IERC4626(vault).deposit(totalDeposit, address(this));
 
         IERC20(vault).forceApprove(address(MORPHO_MIDNIGHT), shares);
-        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, seller);
+        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, receiver); // MUTATION: rebased
 
         emit VaultSharesSupplied(seller, marketId, vault, sellerAssets, totalDeposit, shares);
 
```

<a id="m-midnightsupplyvaultsharescallback-20"></a>
## ✗ #20 — Supplying the vault shares on behalf of the callback instead of the seller credits the callback's own Midnight position, so the seller's collateral never rises and the witness that a vault-supply take can raise the seller's collateral vanishes.

- **Mutant:** [`20.sol`](20.sol)
- **Caught by:** [`supplyCanRaiseVaultCollateral`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/supplyCanRaiseVaultCollateral.conf --rule supplyCanRaiseVaultCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 20`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -78,7 +78,7 @@
         uint256 shares = IERC4626(vault).deposit(totalDeposit, address(this));
 
         IERC20(vault).forceApprove(address(MORPHO_MIDNIGHT), shares);
-        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, seller);
+        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, address(this));  // MUTATION: rebased
 
         emit VaultSharesSupplied(seller, marketId, vault, sellerAssets, totalDeposit, shares);
 
```

<a id="m-midnightsupplyvaultsharescallback-21"></a>
## ✗ #21 — Adding one to the additional-deposit amount pulled from the seller overshoots the percent formula by a unit on every positive-percent take, so extraPullMatchesPercentFormula flips to a counterexample.

- **Mutant:** [`21.sol`](21.sol)
- **Caught by:** [`extraPullMatchesPercentFormula`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L102)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/perf/extraPullMatchesPercentFormula.conf --rule extraPullMatchesPercentFormula`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 21`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -68,7 +68,7 @@
 
         uint256 amountFromSeller;
         if (callbackData.additionalDepositPercent > 0) {
-            amountFromSeller = sellerAssets.mulDivUp(callbackData.additionalDepositPercent, WAD);
+            amountFromSeller = sellerAssets.mulDivUp(callbackData.additionalDepositPercent, WAD) + 1;  // MUTATION: rebased
             SafeTransferLib.safeTransferFrom(loanToken, seller, address(this), amountFromSeller);
         }
 
```

<a id="m-midnightsupplyvaultsharescallback-22"></a>
## ✗ #22 — Supplying the vault shares on behalf of the loan token address instead of the seller credits an unrelated third account's Midnight position, so a bystander's collateral rises and the rule that a supply take never touches a bystander's position produces a counterexample.

- **Mutant:** [`22.sol`](22.sol)
- **Caught by:** [`bystanderUntouched`](../../specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L36)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/bystanderUntouched.conf --rule bystanderUntouched`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 22`

```diff
--- a/src/callbacks/MidnightSupplyVaultSharesCallback.sol
+++ b/src/callbacks/MidnightSupplyVaultSharesCallback.sol
@@ -78,7 +78,7 @@
         uint256 shares = IERC4626(vault).deposit(totalDeposit, address(this));
 
         IERC20(vault).forceApprove(address(MORPHO_MIDNIGHT), shares);
-        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, seller);
+        MORPHO_MIDNIGHT.supplyCollateral(market, callbackData.collateralIndex, shares, loanToken); // MUTATION: onBehalf redirected from the seller to the loanToken address (an unrelated third account)
 
         emit VaultSharesSupplied(seller, marketId, vault, sellerAssets, totalDeposit, shares);
 
```

