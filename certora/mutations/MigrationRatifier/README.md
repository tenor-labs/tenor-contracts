# Mutations — `MigrationRatifier` (`src/ratifiers/MigrationRatifier.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [2](#m-migrationratifier-2) | Comment out the assignment so setParams does not actually write the tuple, breaking the storage fidelity invariant | [`setParamsWritesTupleAndLeavesOthers`](../../specs/ratifier/unit.spec#L28) (ORCH-15, REG-2) |
| ✗ [3](#m-migrationratifier-3) | Comment out the delete statement so clearParams does not actually zero the tuple, breaking the clear invariant | [`clearParamsZeroesTupleAndLeavesOthers`](../../specs/ratifier/unit.spec#L56) (REG-3) |
| ✗ [5](#m-migrationratifier-5) | ratifierData market-match guard flipped != to == : accepts a source-market mismatch | [`ratifierDataMustMatchCallbackMarkets`](../../specs/ratifier/revert.spec#L168) (DEFAULT-3) |
| ✗ [8](#m-migrationratifier-8) | auth guard short-circuited to false: caller can change params on behalf of an unauthorizing owner | [`userParamsChangeRequiresAuthorization`](../../specs/ratifier/access_control.spec#L26) (REG-1) |
| ✗ [9](#m-migrationratifier-9) | invalid-length guard != -> == : accepts non-64-byte ratifierData | [`invalidRatifierDataLengthReverts`](../../specs/ratifier/revert.spec#L8) |
| ✗ [10](#m-migrationratifier-10) | pinned-receiver guard != -> == : accepts unpinned receiver | [`makerReceiverMustBePinned`](../../specs/ratifier/revert.spec#L23) |
| ✗ [11](#m-migrationratifier-11) | group-namespace guard != -> == : accepts out-of-namespace group | [`migrationGroupNamespaceEnforced`](../../specs/ratifier/revert.spec#L42) |
| ✗ [12](#m-migrationratifier-12) | isRatified key swap [src][tgt]->[tgt][src]: reads a non-addressed tuple | [`isRatifiedReadsOnlyAddressedParams`](../../specs/ratifier/highlevel.spec#L252) |
| ✗ [13](#m-migrationratifier-13) | Replace the success-token return with bytes32(0) so an accepting isRatified no longer produces the CALLBACK_SUCCESS value take() requires | [`isRatifiedReturnsCallbackSuccess`](../../specs/ratifier/unit.spec#L247) |

<a id="m-migrationratifier-2"></a>
## ✗ #2 — Comment out the assignment so setParams does not actually write the tuple, breaking the storage fidelity invariant

- **Mutant:** [`2.sol`](2.sol)
- **Caught by:** [`setParamsWritesTupleAndLeavesOthers`](../../specs/ratifier/unit.spec#L28) (ORCH-15, REG-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule setParamsWritesTupleAndLeavesOthers`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MigrationRatifier 2`

```diff
--- a/src/ratifiers/MigrationRatifier.sol
+++ b/src/ratifiers/MigrationRatifier.sol
@@ -88,7 +88,7 @@
         if (msg.sender != onBehalf && !MORPHO_MIDNIGHT.isAuthorized(onBehalf, msg.sender)) {
             revert Unauthorized();
         }
-        userParams[onBehalf][callback][sourceTenorMarketId][targetTenorMarketId] = params;
+        // userParams[onBehalf][callback][sourceTenorMarketId][targetTenorMarketId] = params;  // MUTATION: rebased
         emit ParamsSet(onBehalf, callback, sourceTenorMarketId, targetTenorMarketId, params);
     }
 
```

<a id="m-migrationratifier-3"></a>
## ✗ #3 — Comment out the delete statement so clearParams does not actually zero the tuple, breaking the clear invariant

- **Mutant:** [`3.sol`](3.sol)
- **Caught by:** [`clearParamsZeroesTupleAndLeavesOthers`](../../specs/ratifier/unit.spec#L56) (REG-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule clearParamsZeroesTupleAndLeavesOthers`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MigrationRatifier 3`

```diff
--- a/src/ratifiers/MigrationRatifier.sol
+++ b/src/ratifiers/MigrationRatifier.sol
@@ -99,7 +99,7 @@
         if (msg.sender != onBehalf && !MORPHO_MIDNIGHT.isAuthorized(onBehalf, msg.sender)) {
             revert Unauthorized();
         }
-        delete userParams[onBehalf][callback][sourceTenorMarketId][targetTenorMarketId];
+        // delete userParams[onBehalf][callback][sourceTenorMarketId][targetTenorMarketId];  // MUTATION: rebased
         emit ParamsCleared(onBehalf, callback, sourceTenorMarketId, targetTenorMarketId);
     }
 
```

<a id="m-migrationratifier-5"></a>
## ✗ #5 — ratifierData market-match guard flipped != to == : accepts a source-market mismatch

- **Mutant:** [`5.sol`](5.sol)
- **Caught by:** [`ratifierDataMustMatchCallbackMarkets`](../../specs/ratifier/revert.spec#L168) (DEFAULT-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule ratifierDataMustMatchCallbackMarkets`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MigrationRatifier 5`

```diff
--- a/src/ratifiers/MigrationRatifier.sol
+++ b/src/ratifiers/MigrationRatifier.sol
@@ -133,7 +133,7 @@
         bytes32 callbackSourceMarketId,
         bytes32 callbackTargetMarketId
     ) internal pure override {
-        if (callbackSourceMarketId != sourceTenorMarketId || callbackTargetMarketId != targetTenorMarketId) {
+        if (callbackSourceMarketId == sourceTenorMarketId || callbackTargetMarketId != targetTenorMarketId) {  // MUTATION: rebased
             revert InvalidCallbackData();
         }
     }
```

<a id="m-migrationratifier-8"></a>
## ✗ #8 — auth guard short-circuited to false: caller can change params on behalf of an unauthorizing owner

- **Mutant:** [`8.sol`](8.sol)
- **Caught by:** [`userParamsChangeRequiresAuthorization`](../../specs/ratifier/access_control.spec#L26) (REG-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/access_control.conf --rule userParamsChangeRequiresAuthorization`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MigrationRatifier 8`

```diff
--- a/src/ratifiers/MigrationRatifier.sol
+++ b/src/ratifiers/MigrationRatifier.sol
@@ -85,7 +85,7 @@
         bytes32 targetTenorMarketId,
         UserMigrationParams calldata params
     ) external override {
-        if (msg.sender != onBehalf && !MORPHO_MIDNIGHT.isAuthorized(onBehalf, msg.sender)) {
+        if (false && msg.sender != onBehalf && !MORPHO_MIDNIGHT.isAuthorized(onBehalf, msg.sender)) {  // MUTATION: auth guard short-circuited to false: caller can change 
             revert Unauthorized();
         }
         userParams[onBehalf][callback][sourceTenorMarketId][targetTenorMarketId] = params;
```

<a id="m-migrationratifier-9"></a>
## ✗ #9 — invalid-length guard != -> == : accepts non-64-byte ratifierData

- **Mutant:** [`9.sol`](9.sol)
- **Caught by:** [`invalidRatifierDataLengthReverts`](../../specs/ratifier/revert.spec#L8)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule invalidRatifierDataLengthReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MigrationRatifier 9`

```diff
--- a/src/ratifiers/MigrationRatifier.sol
+++ b/src/ratifiers/MigrationRatifier.sol
@@ -115,7 +115,7 @@
         virtual
         returns (bytes32)
     {
-        if (ratifierData.length != 64) revert InvalidRatifierData();
+        if (ratifierData.length == 64) revert InvalidRatifierData();  // MUTATION: rebased
         (bytes32 src, bytes32 tgt) = abi.decode(ratifierData, (bytes32, bytes32));
         if (offer.receiverIfMakerIsSeller != (offer.buy ? address(0) : offer.callback)) revert InvalidReceiver();
         if ((offer.group & MIGRATION_GROUP_HEADER_MASK) != MIGRATION_GROUP_HEADER) revert InvalidGroup();
```

<a id="m-migrationratifier-10"></a>
## ✗ #10 — pinned-receiver guard != -> == : accepts unpinned receiver

- **Mutant:** [`10.sol`](10.sol)
- **Caught by:** [`makerReceiverMustBePinned`](../../specs/ratifier/revert.spec#L23)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule makerReceiverMustBePinned`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MigrationRatifier 10`

```diff
--- a/src/ratifiers/MigrationRatifier.sol
+++ b/src/ratifiers/MigrationRatifier.sol
@@ -117,7 +117,7 @@
     {
         if (ratifierData.length != 64) revert InvalidRatifierData();
         (bytes32 src, bytes32 tgt) = abi.decode(ratifierData, (bytes32, bytes32));
-        if (offer.receiverIfMakerIsSeller != (offer.buy ? address(0) : offer.callback)) revert InvalidReceiver();
+        if (offer.receiverIfMakerIsSeller == (offer.buy ? address(0) : offer.callback)) revert InvalidReceiver();  // MUTATION: rebased
         if ((offer.group & MIGRATION_GROUP_HEADER_MASK) != MIGRATION_GROUP_HEADER) revert InvalidGroup();
         UserMigrationParams memory params = userParams[offer.maker][offer.callback][src][tgt];
         _ratify(offer.maker, taker, offer.callback, offer.callbackData, offer, src, tgt, params);
```

<a id="m-migrationratifier-11"></a>
## ✗ #11 — group-namespace guard != -> == : accepts out-of-namespace group

- **Mutant:** [`11.sol`](11.sol)
- **Caught by:** [`migrationGroupNamespaceEnforced`](../../specs/ratifier/revert.spec#L42)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule migrationGroupNamespaceEnforced`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MigrationRatifier 11`

```diff
--- a/src/ratifiers/MigrationRatifier.sol
+++ b/src/ratifiers/MigrationRatifier.sol
@@ -118,7 +118,7 @@
         if (ratifierData.length != 64) revert InvalidRatifierData();
         (bytes32 src, bytes32 tgt) = abi.decode(ratifierData, (bytes32, bytes32));
         if (offer.receiverIfMakerIsSeller != (offer.buy ? address(0) : offer.callback)) revert InvalidReceiver();
-        if ((offer.group & MIGRATION_GROUP_HEADER_MASK) != MIGRATION_GROUP_HEADER) revert InvalidGroup();
+        if ((offer.group & MIGRATION_GROUP_HEADER_MASK) == MIGRATION_GROUP_HEADER) revert InvalidGroup();  // MUTATION: rebased
         UserMigrationParams memory params = userParams[offer.maker][offer.callback][src][tgt];
         _ratify(offer.maker, taker, offer.callback, offer.callbackData, offer, src, tgt, params);
         return CALLBACK_SUCCESS;
```

<a id="m-migrationratifier-12"></a>
## ✗ #12 — isRatified key swap [src][tgt]->[tgt][src]: reads a non-addressed tuple

- **Mutant:** [`12.sol`](12.sol)
- **Caught by:** [`isRatifiedReadsOnlyAddressedParams`](../../specs/ratifier/highlevel.spec#L252)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule isRatifiedReadsOnlyAddressedParams`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MigrationRatifier 12`

```diff
--- a/src/ratifiers/MigrationRatifier.sol
+++ b/src/ratifiers/MigrationRatifier.sol
@@ -119,7 +119,7 @@
         (bytes32 src, bytes32 tgt) = abi.decode(ratifierData, (bytes32, bytes32));
         if (offer.receiverIfMakerIsSeller != (offer.buy ? address(0) : offer.callback)) revert InvalidReceiver();
         if ((offer.group & MIGRATION_GROUP_HEADER_MASK) != MIGRATION_GROUP_HEADER) revert InvalidGroup();
-        UserMigrationParams memory params = userParams[offer.maker][offer.callback][src][tgt];
+        UserMigrationParams memory params = userParams[offer.maker][offer.callback][tgt][src];  // MUTATION: rebased
         _ratify(offer.maker, taker, offer.callback, offer.callbackData, offer, src, tgt, params);
         return CALLBACK_SUCCESS;
     }
```

<a id="m-migrationratifier-13"></a>
## ✗ #13 — Replace the success-token return with bytes32(0) so an accepting isRatified no longer produces the CALLBACK_SUCCESS value take() requires

- **Mutant:** [`13.sol`](13.sol)
- **Caught by:** [`isRatifiedReturnsCallbackSuccess`](../../specs/ratifier/unit.spec#L247)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule isRatifiedReturnsCallbackSuccess`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh MigrationRatifier 13`

```diff
--- a/src/ratifiers/MigrationRatifier.sol
+++ b/src/ratifiers/MigrationRatifier.sol
@@ -121,7 +121,7 @@
         if ((offer.group & MIGRATION_GROUP_HEADER_MASK) != MIGRATION_GROUP_HEADER) revert InvalidGroup();
         UserMigrationParams memory params = userParams[offer.maker][offer.callback][src][tgt];
         _ratify(offer.maker, taker, offer.callback, offer.callbackData, offer, src, tgt, params);
-        return CALLBACK_SUCCESS;
+        return bytes32(0);   // MUTATION: accepting path no longer returns CALLBACK_SUCCESS
     }
 
     /// @dev Requires the maker-declared route to equal the callback-derived markets. The params lookup is already
```

