# Mutations — `BaseMigrationRatifier` (`src/ratifiers/BaseMigrationRatifier.sol`)

Each numbered file is the contract above with **one** line broken; the listed rule(s) caught it — they flipped to a counterexample on the mutant. Diffs are computed live against `src/`. Mutant numbers are authoring-time candidate ids and need not be contiguous — gaps are candidates dropped before the final suite; every shipped mutant is listed below.

| # | What we test | Caught by |
|---|---|---|
| ✗ [1](#m-basemigrationratifier-1) | _ratifyWindow guard ==0 -> !=0 | [`v2v1ExitsHaveNoRenewalCadenceConstraint`](../../specs/ratifier/highlevel.spec#L36) (BMB, LMV) |
| ✗ [2](#m-basemigrationratifier-2) | Comment out the onlyOwner modifier to allow non-owners to call setFeeConfig | [`feeConfigChangeRequiresOwner`](../../specs/ratifier/access_control.spec#L8) |
| ✗ [10](#m-basemigrationratifier-10) | Flip || to && to allow single unconfigured field | [`unconfiguredTupleAlwaysReverts`](../../specs/ratifier/revert.spec#L59) |
| ✗ [11](#m-basemigrationratifier-11) | Invert feeMarketId selection (wrong market for fee lookup) | [`callbackFeeMustMatchEffectiveConfig`](../../specs/ratifier/revert.spec#L188) (DEFAULT-2) |
| ✗ [12](#m-basemigrationratifier-12) | Accept fee rate mismatch when recipient matches | [`callbackFeeMustMatchEffectiveConfig`](../../specs/ratifier/revert.spec#L188) (DEFAULT-2) |
| ✗ [13](#m-basemigrationratifier-13) | Allow targetMaturity == sourceMaturity (off-by-one) | [`targetMaturityMustExceedSource`](../../specs/ratifier/revert.spec#L98) (ORCH-9) |
| ✗ [15](#m-basemigrationratifier-15) | cadence-grid guard != -> == : accepts off-grid maturities, rejects on-grid | [`targetMaturityOnCadenceGrid`](../../specs/ratifier/revert.spec#L142) (ORCH-11) |
| ✗ [18](#m-basemigrationratifier-18) | Flip the condition from != to == to invert the override logic; market config is returned even when not set, instead of falling back to default | [`getEffectiveFeeConfigMarketOverridesActionDefault`](../../specs/ratifier/unit.spec#L8) (ORCH-3) |
| ✗ [19](#m-basemigrationratifier-19) | Change the disjunction || to conjunction && so no callback can satisfy the condition, breaking the buy-side flag directionality | [`userIsBuyMatchesBuySideCallbacks`](../../specs/ratifier/unit.spec#L82) (DEFAULT-1, RATE-3) |
| ✗ [20](#m-basemigrationratifier-20) | _maxFeeRate exit-cap removed: cap nonzero (MAX_FEE_RATE) on V2->V1 exits instead of 0 | [`maxFeeRateZeroOnV2ToV1Exits`](../../specs/ratifier/unit.spec#L152) (ORCH-4) |
| ✗ [21](#m-basemigrationratifier-21) | Replace zeroFloorSub with plain subtraction to allow underflow on exits after source maturity, violating the clamping to 0 invariant | [`computeDurationPerCallback`](../../specs/ratifier/unit.spec#L162) (ORCH-13) |
| ✗ [22](#m-basemigrationratifier-22) | Tightens the lower duration-band check from < to <=, so a target maturity exactly at now+minDuration is now rejected; the witness that a boundary target maturity is accepted becomes unreachable because the take reverts. | [`targetMaturityWithinDurationBand_boundaryAccepted`](../../specs/ratifier/revert.spec#L253) (ORCH-10) |
| ✗ [23](#m-basemigrationratifier-23) | Window param guard > -> >= : rejects renewalWindow == sourceMaturity (window opens at time 0), a valid config. Caught by the boundary-accepted satisfy companion. | [`v2SourceWindowEnforcedBeforeOpen_boundaryAccepted`](../../specs/ratifier/revert.spec#L283) (ORCH-8) |
| ✗ [24](#m-basemigrationratifier-24) | Cadence-boundary guard > -> >= : rejects a V1->V2 enter whose nearest boundary is exactly now, a valid config. Caught by the boundary-accepted satisfy companion. | [`variableSourceWindowEnforced_boundaryAccepted`](../../specs/ratifier/revert.spec#L311) (ORCH-7) |
| ✗ [25](#m-basemigrationratifier-25) | tick guard != -> == : reverts on a matching tick, accepts a mismatch | [`tickMustMatchOffer`](../../specs/ratifier/revert.spec#L80) (DEFAULT-4) |
| ✗ [28](#m-basemigrationratifier-28) | Flips the renewal-window guard from < to >=, so every fixed-source take reverts instead of only early ones; the witness that a post-maturity renewal is executable disappears because the take always reverts. | [`postMaturityV2ToV2Executable`](../../specs/ratifier/reachability.spec#L9) (ORCH-5) |
| ✗ [29](#m-basemigrationratifier-29) | Inverts the target-maturity guard from >0 to ==0, so an exit with zero target maturity now runs target-maturity validation and always reverts; the witness that a post-maturity exit is executable disappears because the take reverts. | [`postMaturityV2ToV1Executable`](../../specs/ratifier/reachability.spec#L31) (ORCH-6) |
| ✗ [31](#m-basemigrationratifier-31) | Adds a renewalWindow != 0 revert to the variable-source migration path, so the stored renewal window now gates a V1-to-V2 migration; the assert that such a migration ignores the renewal window flips to a counterexample. | [`v1v2migrationsHaveNoRenewalWindowConstraint`](../../specs/ratifier/highlevel.spec#L8) (ORCH-7) |
| ✗ [32](#m-basemigrationratifier-32) | make-on-behalf check == -> != : real gate uses taker settlementFee, diverging from the fee=0 reconstruction | [`borrowerRateGateMatchesNetSellerThreshold`](../../specs/ratifier/highlevel.spec#L92) (BBM) · [`lenderRateGateMatchesNetBuyerThreshold`](../../specs/ratifier/highlevel.spec#L169) (LVM) |
| ✗ [33](#m-basemigrationratifier-33) | wrong var: rate-limit slot clobbered with policyRate, real gate diverges from reconstruction's real limit | [`lenderRateGateMatchesNetBuyerThreshold`](../../specs/ratifier/highlevel.spec#L169) (LVM) · [`borrowerRateGateMatchesNetSellerThreshold`](../../specs/ratifier/highlevel.spec#L92) (BBM) |
| ✗ [36](#m-basemigrationratifier-36) | cadence-boundary guard > -> < : allows future cadence boundary | [`variableSourceWindowEnforced`](../../specs/ratifier/revert.spec#L231) (ORCH-7) |
| ✗ [39](#m-basemigrationratifier-39) | fee-cap check inverted: over-cap rate can be stored | [`feeRateNeverExceedsCallbackCap`](../../specs/ratifier/valid_state.spec#L7) (ORCH-1) |
| ✗ [40](#m-basemigrationratifier-40) | recipient guard == -> != : nonzero rate with zero recipient stored | [`nonZeroFeeRateImpliesRecipient`](../../specs/ratifier/valid_state.spec#L15) (ORCH-2) |
| ✗ [41](#m-basemigrationratifier-41) | fee-market ternary swapped: consults wrong market slot | [`feeMarketIdIgnoresCrossMarketSlot`](../../specs/ratifier/highlevel.spec#L65) (ORCH-14) |
| ✗ [42](#m-basemigrationratifier-42) | getRate user arg -> address(0): forwards wrong principal owner | [`getRatePrincipalForwardedFaithfully`](../../specs/ratifier/highlevel.spec#L279) |
| ✗ [43](#m-basemigrationratifier-43) | unauthorized-callback revert disabled (if(false)): accepts unknown callback | [`unauthorizedCallbackReverts`](../../specs/ratifier/revert.spec#L339) |
| ✗ [44](#m-basemigrationratifier-44) | duration-band || -> && : out-of-band maturity no longer reverts | [`targetMaturityWithinDurationBand`](../../specs/ratifier/revert.spec#L115) (ORCH-10) |
| ✗ [45](#m-basemigrationratifier-45) | source-window guard < -> > : before-open no longer reverts | [`v2SourceWindowEnforcedBeforeOpen`](../../specs/ratifier/revert.spec#L208) (ORCH-8) |
| ✗ [46](#m-basemigrationratifier-46) | target-maturity guard <= -> >= : V1->V2 (srcMat==0) always reverts, witness unreachable | [`entryV1ToV2Executable`](../../specs/ratifier/reachability.spec#L52) |
| ✗ [47](#m-basemigrationratifier-47) | continuous-fee lifetime * -> + : high fee no longer reaches WAD cap, over-cap offer accepted | [`continuousFeeCapReverts`](../../specs/ratifier/revert.spec#L356) (LVM, LMR) |
| ✗ [48](#m-basemigrationratifier-48) | Comment out the feeRecipient assignment so setFeeConfig stores only the rate, breaking fee-slot write fidelity | [`setFeeConfigWritesSlotAndLeavesOthers`](../../specs/ratifier/unit.spec#L262) |

<a id="m-basemigrationratifier-1"></a>
## ✗ #1 — _ratifyWindow guard ==0 -> !=0

- **Mutant:** [`1.sol`](1.sol)
- **Caught by:** [`v2v1ExitsHaveNoRenewalCadenceConstraint`](../../specs/ratifier/highlevel.spec#L36) (BMB, LMV)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule v2v1ExitsHaveNoRenewalCadenceConstraint`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 1`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -271,7 +271,7 @@
         view
         returns (uint256 renewalPeriodStart)
     {
-        if (sourceMaturity == 0) {
+        if (sourceMaturity != 0) {  // MUTATION: rebased
             if (params.renewalCadence == address(0)) revert InvalidRenewalParams();
             renewalPeriodStart = IRenewalCadence(params.renewalCadence).cadencePeriodStart(block.timestamp);
             // Invariant check: a compliant cadence returns a period start <= the queried timestamp.
```

<a id="m-basemigrationratifier-2"></a>
## ✗ #2 — Comment out the onlyOwner modifier to allow non-owners to call setFeeConfig

- **Mutant:** [`2.sol`](2.sol)
- **Caught by:** [`feeConfigChangeRequiresOwner`](../../specs/ratifier/access_control.spec#L8)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/access_control.conf --rule feeConfigChangeRequiresOwner`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 2`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -84,7 +84,7 @@
     /// @inheritdoc IMigrationRatifier
     function setFeeConfig(address callback, bytes32 tenorMarketId, uint256 _feeRate, address _feeRecipient)
         external
-        onlyOwner
+        // onlyOwner  // MUTATION: rebased
     {
         if (_feeRate > _maxFeeRate(callback)) revert InvalidFeeConfig();
         if (_feeRate > 0 && _feeRecipient == address(0)) revert InvalidFeeConfig();
```

<a id="m-basemigrationratifier-10"></a>
## ✗ #10 — Flip || to && to allow single unconfigured field

- **Mutant:** [`10.sol`](10.sol)
- **Caught by:** [`unconfiguredTupleAlwaysReverts`](../../specs/ratifier/revert.spec#L59)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule unconfiguredTupleAlwaysReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 10`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -131,7 +131,7 @@
         UserMigrationParams memory params
     ) internal view {
         if (
-            params.interestRatePolicy == address(0) || params.minDuration == 0
+            params.interestRatePolicy == address(0) && params.minDuration == 0  // MUTATION: rebased
                 || params.maxDuration < params.minDuration
         ) {
             revert InvalidRenewalParams();
```

<a id="m-basemigrationratifier-11"></a>
## ✗ #11 — Invert feeMarketId selection (wrong market for fee lookup)

- **Mutant:** [`11.sol`](11.sol)
- **Caught by:** [`callbackFeeMustMatchEffectiveConfig`](../../specs/ratifier/revert.spec#L188) (DEFAULT-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule callbackFeeMustMatchEffectiveConfig`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 11`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -149,7 +149,7 @@
         _validateMarketPair(src, tgt, callbackSourceMarketId, callbackTargetMarketId);
 
         // The fee config is keyed on the Midnight market: the target for entries and renewals, the source for exits.
-        bytes32 feeMarketId = targetMaturity == 0 ? callbackSourceMarketId : callbackTargetMarketId;
+        bytes32 feeMarketId = targetMaturity != 0 ? callbackSourceMarketId : callbackTargetMarketId;  // MUTATION: rebased
         FeeConfig memory expectedFee = getEffectiveFeeConfig(callback, feeMarketId);
         if (callbackFeeRate != expectedFee.feeRate || callbackFeeRecipient != expectedFee.feeRecipient) {
             revert InvalidFeeConfig();
```

<a id="m-basemigrationratifier-12"></a>
## ✗ #12 — Accept fee rate mismatch when recipient matches

- **Mutant:** [`12.sol`](12.sol)
- **Caught by:** [`callbackFeeMustMatchEffectiveConfig`](../../specs/ratifier/revert.spec#L188) (DEFAULT-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule callbackFeeMustMatchEffectiveConfig`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 12`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -151,7 +151,7 @@
         // The fee config is keyed on the Midnight market: the target for entries and renewals, the source for exits.
         bytes32 feeMarketId = targetMaturity == 0 ? callbackSourceMarketId : callbackTargetMarketId;
         FeeConfig memory expectedFee = getEffectiveFeeConfig(callback, feeMarketId);
-        if (callbackFeeRate != expectedFee.feeRate || callbackFeeRecipient != expectedFee.feeRecipient) {
+        if (callbackFeeRate == expectedFee.feeRate || callbackFeeRecipient != expectedFee.feeRecipient) {  // MUTATION: rebased
             revert InvalidFeeConfig();
         }
 
```

<a id="m-basemigrationratifier-13"></a>
## ✗ #13 — Allow targetMaturity == sourceMaturity (off-by-one)

- **Mutant:** [`13.sol`](13.sol)
- **Caught by:** [`targetMaturityMustExceedSource`](../../specs/ratifier/revert.spec#L98) (ORCH-9)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule targetMaturityMustExceedSource`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 13`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -290,7 +290,7 @@
         internal
         view
     {
-        if (targetMaturity <= sourceMaturity) revert InvalidTargetMaturity();
+        if (targetMaturity < sourceMaturity) revert InvalidTargetMaturity();  // MUTATION: rebased
         uint256 minTarget = block.timestamp + params.minDuration;
         uint256 maxTarget = block.timestamp + params.maxDuration;
         if (targetMaturity < minTarget || targetMaturity > maxTarget) {
```

<a id="m-basemigrationratifier-15"></a>
## ✗ #15 — cadence-grid guard != -> == : accepts off-grid maturities, rejects on-grid

- **Mutant:** [`15.sol`](15.sol)
- **Caught by:** [`targetMaturityOnCadenceGrid`](../../specs/ratifier/revert.spec#L142) (ORCH-11)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule targetMaturityOnCadenceGrid`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 15`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -298,7 +298,7 @@
         }
         if (
             params.renewalCadence != address(0)
-                && IRenewalCadence(params.renewalCadence).cadencePeriodStart(targetMaturity) != targetMaturity
+                && IRenewalCadence(params.renewalCadence).cadencePeriodStart(targetMaturity) == targetMaturity  // MUTATION: rebased
         ) revert InvalidTargetMaturity();
     }
 
```

<a id="m-basemigrationratifier-18"></a>
## ✗ #18 — Flip the condition from != to == to invert the override logic; market config is returned even when not set, instead of falling back to default

- **Mutant:** [`18.sol`](18.sol)
- **Caught by:** [`getEffectiveFeeConfigMarketOverridesActionDefault`](../../specs/ratifier/unit.spec#L8) (ORCH-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule getEffectiveFeeConfigMarketOverridesActionDefault`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 18`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -101,7 +101,7 @@
         returns (FeeConfig memory config)
     {
         config = feeConfigs[callback][tenorMarketId];
-        if (config.feeRecipient != address(0)) return config;
+        if (config.feeRecipient == address(0)) return config;  // MUTATION: rebased
         return feeConfigs[callback][bytes32(0)];
     }
 
```

<a id="m-basemigrationratifier-19"></a>
## ✗ #19 — Change the disjunction || to conjunction && so no callback can satisfy the condition, breaking the buy-side flag directionality

- **Mutant:** [`19.sol`](19.sol)
- **Caught by:** [`userIsBuyMatchesBuySideCallbacks`](../../specs/ratifier/unit.spec#L82) (DEFAULT-1, RATE-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule userIsBuyMatchesBuySideCallbacks`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 19`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -374,7 +374,7 @@
     /// @dev The user buys credit on Midnight when entering or renewing a lend position, or exiting a borrow
     /// position; the user sells when entering or renewing a borrow position, or exiting a lend position.
     function _userIsBuy(address callback) internal view returns (bool) {
-        return callback == LEND_VAULT_TO_MIDNIGHT_CALLBACK || callback == BORROW_MIDNIGHT_TO_BLUE_CALLBACK
+        return callback == LEND_VAULT_TO_MIDNIGHT_CALLBACK && callback == BORROW_MIDNIGHT_TO_BLUE_CALLBACK  // MUTATION: rebased
             || callback == LEND_MIDNIGHT_RENEWAL_CALLBACK;
     }
 
```

<a id="m-basemigrationratifier-20"></a>
## ✗ #20 — _maxFeeRate exit-cap removed: cap nonzero (MAX_FEE_RATE) on V2->V1 exits instead of 0

- **Mutant:** [`20.sol`](20.sol)
- **Caught by:** [`maxFeeRateZeroOnV2ToV1Exits`](../../specs/ratifier/unit.spec#L152) (ORCH-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule maxFeeRateZeroOnV2ToV1Exits`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 20`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -109,7 +109,7 @@
     /// otherwise.
     function _maxFeeRate(address callback) internal view returns (uint256) {
         if (callback == BORROW_MIDNIGHT_TO_BLUE_CALLBACK || callback == LEND_MIDNIGHT_TO_VAULT_CALLBACK) {
-            return MAX_FEE_RATE_FIXED_TO_VARIABLE;
+            return MAX_FEE_RATE;  // MUTATION: rebased
         }
         return MAX_FEE_RATE;
     }
```

<a id="m-basemigrationratifier-21"></a>
## ✗ #21 — Replace zeroFloorSub with plain subtraction to allow underflow on exits after source maturity, violating the clamping to 0 invariant

- **Mutant:** [`21.sol`](21.sol)
- **Caught by:** [`computeDurationPerCallback`](../../specs/ratifier/unit.spec#L162) (ORCH-13)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule computeDurationPerCallback`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 21`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -366,7 +366,7 @@
         } else if (callback == BORROW_BLUE_TO_MIDNIGHT_CALLBACK || callback == LEND_VAULT_TO_MIDNIGHT_CALLBACK) {
             return targetMaturity - block.timestamp;
         } else {
-            return UtilsLib.zeroFloorSub(sourceMaturity, block.timestamp);
+            return sourceMaturity - block.timestamp;  // MUTATION: rebased
         }
     }
 
```

<a id="m-basemigrationratifier-22"></a>
## ✗ #22 — Tightens the lower duration-band check from < to <=, so a target maturity exactly at now+minDuration is now rejected; the witness that a boundary target maturity is accepted becomes unreachable because the take reverts.

- **Mutant:** [`22.sol`](22.sol)
- **Caught by:** [`targetMaturityWithinDurationBand_boundaryAccepted`](../../specs/ratifier/revert.spec#L253) (ORCH-10)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule targetMaturityWithinDurationBand_boundaryAccepted`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 22`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -293,7 +293,7 @@
         if (targetMaturity <= sourceMaturity) revert InvalidTargetMaturity();
         uint256 minTarget = block.timestamp + params.minDuration;
         uint256 maxTarget = block.timestamp + params.maxDuration;
-        if (targetMaturity < minTarget || targetMaturity > maxTarget) {
+        if (targetMaturity <= minTarget || targetMaturity > maxTarget) {  // MUTATION: rebased
             revert InvalidTargetMaturity();
         }
         if (
```

<a id="m-basemigrationratifier-23"></a>
## ✗ #23 — Window param guard > -> >= : rejects renewalWindow == sourceMaturity (window opens at time 0), a valid config. Caught by the boundary-accepted satisfy companion.

- **Mutant:** [`23.sol`](23.sol)
- **Caught by:** [`v2SourceWindowEnforcedBeforeOpen_boundaryAccepted`](../../specs/ratifier/revert.spec#L283) (ORCH-8)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule v2SourceWindowEnforcedBeforeOpen_boundaryAccepted`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 23`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -277,7 +277,7 @@
             // Invariant check: a compliant cadence returns a period start <= the queried timestamp.
             if (renewalPeriodStart > block.timestamp) revert InvalidRenewalParams();
         } else {
-            if (params.renewalWindow > sourceMaturity) revert InvalidRenewalParams();
+            if (params.renewalWindow >= sourceMaturity) revert InvalidRenewalParams();  // MUTATION: rebased
             renewalPeriodStart = sourceMaturity - params.renewalWindow;
             if (block.timestamp < renewalPeriodStart) revert InvalidRenewalWindow();
         }
```

<a id="m-basemigrationratifier-24"></a>
## ✗ #24 — Cadence-boundary guard > -> >= : rejects a V1->V2 enter whose nearest boundary is exactly now, a valid config. Caught by the boundary-accepted satisfy companion.

- **Mutant:** [`24.sol`](24.sol)
- **Caught by:** [`variableSourceWindowEnforced_boundaryAccepted`](../../specs/ratifier/revert.spec#L311) (ORCH-7)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule variableSourceWindowEnforced_boundaryAccepted`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 24`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -275,7 +275,7 @@
             if (params.renewalCadence == address(0)) revert InvalidRenewalParams();
             renewalPeriodStart = IRenewalCadence(params.renewalCadence).cadencePeriodStart(block.timestamp);
             // Invariant check: a compliant cadence returns a period start <= the queried timestamp.
-            if (renewalPeriodStart > block.timestamp) revert InvalidRenewalParams();
+            if (renewalPeriodStart >= block.timestamp) revert InvalidRenewalParams();  // MUTATION: rebased
         } else {
             if (params.renewalWindow > sourceMaturity) revert InvalidRenewalParams();
             renewalPeriodStart = sourceMaturity - params.renewalWindow;
```

<a id="m-basemigrationratifier-25"></a>
## ✗ #25 — tick guard != -> == : reverts on a matching tick, accepts a mismatch

- **Mutant:** [`25.sol`](25.sol)
- **Caught by:** [`tickMustMatchOffer`](../../specs/ratifier/revert.spec#L80) (DEFAULT-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule tickMustMatchOffer`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 25`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -201,7 +201,7 @@
         if (callback == BORROW_MIDNIGHT_RENEWAL_CALLBACK || callback == LEND_MIDNIGHT_RENEWAL_CALLBACK) {
             IBorrowMidnightRenewalCallback.CallbackData memory decoded =
                 abi.decode(callbackData, (IBorrowMidnightRenewalCallback.CallbackData));
-            if (decoded.tick != offer.tick) revert InvalidCallbackData();
+            if (decoded.tick == offer.tick) revert InvalidCallbackData();  // MUTATION: tick guard != -> == : reverts on a matching tick, accep
             return (
                 decoded.sourceMarket.toTenorMarketId(),
                 offer.market.toTenorMarketId(),
```

<a id="m-basemigrationratifier-28"></a>
## ✗ #28 — Flips the renewal-window guard from < to >=, so every fixed-source take reverts instead of only early ones; the witness that a post-maturity renewal is executable disappears because the take always reverts.

- **Mutant:** [`28.sol`](28.sol)
- **Caught by:** [`postMaturityV2ToV2Executable`](../../specs/ratifier/reachability.spec#L9) (ORCH-5)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/reachability.conf --rule postMaturityV2ToV2Executable`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 28`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -279,7 +279,7 @@
         } else {
             if (params.renewalWindow > sourceMaturity) revert InvalidRenewalParams();
             renewalPeriodStart = sourceMaturity - params.renewalWindow;
-            if (block.timestamp < renewalPeriodStart) revert InvalidRenewalWindow();
+            if (block.timestamp >= renewalPeriodStart) revert InvalidRenewalWindow(); // MUTATION: rebased
         }
         if (targetMaturity > 0) _validateTargetMaturity(sourceMaturity, targetMaturity, params);
     }
```

<a id="m-basemigrationratifier-29"></a>
## ✗ #29 — Inverts the target-maturity guard from >0 to ==0, so an exit with zero target maturity now runs target-maturity validation and always reverts; the witness that a post-maturity exit is executable disappears because the take reverts.

- **Mutant:** [`29.sol`](29.sol)
- **Caught by:** [`postMaturityV2ToV1Executable`](../../specs/ratifier/reachability.spec#L31) (ORCH-6)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/reachability.conf --rule postMaturityV2ToV1Executable`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 29`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -281,7 +281,7 @@
             renewalPeriodStart = sourceMaturity - params.renewalWindow;
             if (block.timestamp < renewalPeriodStart) revert InvalidRenewalWindow();
         }
-        if (targetMaturity > 0) _validateTargetMaturity(sourceMaturity, targetMaturity, params);
+        if (targetMaturity == 0) _validateTargetMaturity(sourceMaturity, targetMaturity, params);  // MUTATION: rebased
     }
 
     /// @dev Reverts unless `targetMaturity` is after `sourceMaturity`, within the user's duration bounds,
```

<a id="m-basemigrationratifier-31"></a>
## ✗ #31 — Adds a renewalWindow != 0 revert to the variable-source migration path, so the stored renewal window now gates a V1-to-V2 migration; the assert that such a migration ignores the renewal window flips to a counterexample.

- **Mutant:** [`31.sol`](31.sol)
- **Caught by:** [`v1v2migrationsHaveNoRenewalWindowConstraint`](../../specs/ratifier/highlevel.spec#L8) (ORCH-7)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule v1v2migrationsHaveNoRenewalWindowConstraint`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 31`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -272,7 +272,7 @@
         returns (uint256 renewalPeriodStart)
     {
         if (sourceMaturity == 0) {
-            if (params.renewalCadence == address(0)) revert InvalidRenewalParams();
+            if (params.renewalCadence == address(0) || params.renewalWindow != 0) revert InvalidRenewalParams();  // MUTATION: rebased
             renewalPeriodStart = IRenewalCadence(params.renewalCadence).cadencePeriodStart(block.timestamp);
             // Invariant check: a compliant cadence returns a period start <= the queried timestamp.
             if (renewalPeriodStart > block.timestamp) revert InvalidRenewalParams();
```

<a id="m-basemigrationratifier-32"></a>
## ✗ #32 — make-on-behalf check == -> != : real gate uses taker settlementFee, diverging from the fee=0 reconstruction

- **Mutant:** [`32.sol`](32.sol)
- **Caught by:** [`borrowerRateGateMatchesNetSellerThreshold`](../../specs/ratifier/highlevel.spec#L92) (BBM) · [`lenderRateGateMatchesNetBuyerThreshold`](../../specs/ratifier/highlevel.spec#L169) (LVM)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule borrowerRateGateMatchesNetSellerThreshold lenderRateGateMatchesNetBuyerThreshold`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 32`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -333,7 +333,7 @@
             );
         uint256 tickPrice = TickLib.tickToPrice(offer.tick);
         bytes32 marketId = IdLib.toId(offer.market);
-        uint256 settlementFee = offer.maker == user
+        uint256 settlementFee = offer.maker != user  // MUTATION: rebased
             ? 0
             : MORPHO_MIDNIGHT.settlementFee(marketId, UtilsLib.zeroFloorSub(offer.market.maturity, block.timestamp));
         uint256 effPrice = userIsBuy
```

<a id="m-basemigrationratifier-33"></a>
## ✗ #33 — wrong var: rate-limit slot clobbered with policyRate, real gate diverges from reconstruction's real limit

- **Mutant:** [`33.sol`](33.sol)
- **Caught by:** [`lenderRateGateMatchesNetBuyerThreshold`](../../specs/ratifier/highlevel.spec#L169) (LVM) · [`borrowerRateGateMatchesNetSellerThreshold`](../../specs/ratifier/highlevel.spec#L92) (BBM)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule lenderRateGateMatchesNetBuyerThreshold borrowerRateGateMatchesNetSellerThreshold`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 33`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -341,7 +341,7 @@
             : RouterLib.netSellerPrice(tickPrice, settlementFee, feeConfig.feeRate);
         uint256 effUnitsPerWad = _effectiveUnitsPerWad(callback, marketId, offer);
         if (!PriceLib.satisfiesRateLimit(
-                userIsBuy, effUnitsPerWad, effPrice, params.limitRatePerSecond, policyRate, duration
+                userIsBuy, effUnitsPerWad, effPrice, policyRate, policyRate, duration  // MUTATION: rebased
             )) revert InvalidOfferRate();
     }
 
```

<a id="m-basemigrationratifier-36"></a>
## ✗ #36 — cadence-boundary guard > -> < : allows future cadence boundary

- **Mutant:** [`36.sol`](36.sol)
- **Caught by:** [`variableSourceWindowEnforced`](../../specs/ratifier/revert.spec#L231) (ORCH-7)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule variableSourceWindowEnforced`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 36`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -275,7 +275,7 @@
             if (params.renewalCadence == address(0)) revert InvalidRenewalParams();
             renewalPeriodStart = IRenewalCadence(params.renewalCadence).cadencePeriodStart(block.timestamp);
             // Invariant check: a compliant cadence returns a period start <= the queried timestamp.
-            if (renewalPeriodStart > block.timestamp) revert InvalidRenewalParams();
+            if (renewalPeriodStart < block.timestamp) revert InvalidRenewalParams();  // MUTATION: rebased
         } else {
             if (params.renewalWindow > sourceMaturity) revert InvalidRenewalParams();
             renewalPeriodStart = sourceMaturity - params.renewalWindow;
```

<a id="m-basemigrationratifier-39"></a>
## ✗ #39 — fee-cap check inverted: over-cap rate can be stored

- **Mutant:** [`39.sol`](39.sol)
- **Caught by:** [`feeRateNeverExceedsCallbackCap`](../../specs/ratifier/valid_state.spec#L7) (ORCH-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/valid_state.conf --rule feeRateNeverExceedsCallbackCap`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 39`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -86,7 +86,7 @@
         external
         onlyOwner
     {
-        if (_feeRate > _maxFeeRate(callback)) revert InvalidFeeConfig();
+        if (_feeRate <= _maxFeeRate(callback)) revert InvalidFeeConfig();  // MUTATION: rebased
         if (_feeRate > 0 && _feeRecipient == address(0)) revert InvalidFeeConfig();
         FeeConfig storage slot = feeConfigs[callback][tenorMarketId];
         slot.feeRecipient = _feeRecipient;
```

<a id="m-basemigrationratifier-40"></a>
## ✗ #40 — recipient guard == -> != : nonzero rate with zero recipient stored

- **Mutant:** [`40.sol`](40.sol)
- **Caught by:** [`nonZeroFeeRateImpliesRecipient`](../../specs/ratifier/valid_state.spec#L15) (ORCH-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/valid_state.conf --rule nonZeroFeeRateImpliesRecipient`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 40`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -87,7 +87,7 @@
         onlyOwner
     {
         if (_feeRate > _maxFeeRate(callback)) revert InvalidFeeConfig();
-        if (_feeRate > 0 && _feeRecipient == address(0)) revert InvalidFeeConfig();
+        if (_feeRate > 0 && _feeRecipient != address(0)) revert InvalidFeeConfig();  // MUTATION: rebased
         FeeConfig storage slot = feeConfigs[callback][tenorMarketId];
         slot.feeRecipient = _feeRecipient;
         slot.feeRate = uint96(_feeRate);
```

<a id="m-basemigrationratifier-41"></a>
## ✗ #41 — fee-market ternary swapped: consults wrong market slot

- **Mutant:** [`41.sol`](41.sol)
- **Caught by:** [`feeMarketIdIgnoresCrossMarketSlot`](../../specs/ratifier/highlevel.spec#L65) (ORCH-14)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule feeMarketIdIgnoresCrossMarketSlot`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 41`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -149,7 +149,7 @@
         _validateMarketPair(src, tgt, callbackSourceMarketId, callbackTargetMarketId);
 
         // The fee config is keyed on the Midnight market: the target for entries and renewals, the source for exits.
-        bytes32 feeMarketId = targetMaturity == 0 ? callbackSourceMarketId : callbackTargetMarketId;
+        bytes32 feeMarketId = targetMaturity == 0 ? callbackTargetMarketId : callbackSourceMarketId;  // MUTATION: rebased
         FeeConfig memory expectedFee = getEffectiveFeeConfig(callback, feeMarketId);
         if (callbackFeeRate != expectedFee.feeRate || callbackFeeRecipient != expectedFee.feeRecipient) {
             revert InvalidFeeConfig();
```

<a id="m-basemigrationratifier-42"></a>
## ✗ #42 — getRate user arg -> address(0): forwards wrong principal owner

- **Mutant:** [`42.sol`](42.sol)
- **Caught by:** [`getRatePrincipalForwardedFaithfully`](../../specs/ratifier/highlevel.spec#L279)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule getRatePrincipalForwardedFaithfully`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 42`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -325,7 +325,7 @@
                 sourceTenorMarketId,
                 targetTenorMarketId,
                 renewalPeriodStart,
-                user,
+                address(0), // MUTATION: pass zero instead of user
                 taker,
                 sourceMaturity,
                 targetMaturity,
```

<a id="m-basemigrationratifier-43"></a>
## ✗ #43 — unauthorized-callback revert disabled (if(false)): accepts unknown callback

- **Mutant:** [`43.sol`](43.sol)
- **Caught by:** [`unauthorizedCallbackReverts`](../../specs/ratifier/revert.spec#L339)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule unauthorizedCallbackReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 43`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -257,7 +257,7 @@
                 decoded.feeRecipient
             );
         } else {
-            revert InvalidCallback();
+            if (false) revert InvalidCallback();  // MUTATION: rebased
         }
     }
 
```

<a id="m-basemigrationratifier-44"></a>
## ✗ #44 — duration-band || -> && : out-of-band maturity no longer reverts

- **Mutant:** [`44.sol`](44.sol)
- **Caught by:** [`targetMaturityWithinDurationBand`](../../specs/ratifier/revert.spec#L115) (ORCH-10)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule targetMaturityWithinDurationBand`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 44`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -293,7 +293,7 @@
         if (targetMaturity <= sourceMaturity) revert InvalidTargetMaturity();
         uint256 minTarget = block.timestamp + params.minDuration;
         uint256 maxTarget = block.timestamp + params.maxDuration;
-        if (targetMaturity < minTarget || targetMaturity > maxTarget) {
+        if (targetMaturity < minTarget && targetMaturity > maxTarget) {  // MUTATION: rebased
             revert InvalidTargetMaturity();
         }
         if (
```

<a id="m-basemigrationratifier-45"></a>
## ✗ #45 — source-window guard < -> > : before-open no longer reverts

- **Mutant:** [`45.sol`](45.sol)
- **Caught by:** [`v2SourceWindowEnforcedBeforeOpen`](../../specs/ratifier/revert.spec#L208) (ORCH-8)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule v2SourceWindowEnforcedBeforeOpen`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 45`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -279,7 +279,7 @@
         } else {
             if (params.renewalWindow > sourceMaturity) revert InvalidRenewalParams();
             renewalPeriodStart = sourceMaturity - params.renewalWindow;
-            if (block.timestamp < renewalPeriodStart) revert InvalidRenewalWindow();
+            if (block.timestamp > renewalPeriodStart) revert InvalidRenewalWindow();  // MUTATION: rebased
         }
         if (targetMaturity > 0) _validateTargetMaturity(sourceMaturity, targetMaturity, params);
     }
```

<a id="m-basemigrationratifier-46"></a>
## ✗ #46 — target-maturity guard <= -> >= : V1->V2 (srcMat==0) always reverts, witness unreachable

- **Mutant:** [`46.sol`](46.sol)
- **Caught by:** [`entryV1ToV2Executable`](../../specs/ratifier/reachability.spec#L52)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/reachability.conf --rule entryV1ToV2Executable`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 46`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -290,7 +290,7 @@
         internal
         view
     {
-        if (targetMaturity <= sourceMaturity) revert InvalidTargetMaturity();
+        if (targetMaturity >= sourceMaturity) revert InvalidTargetMaturity();  // MUTATION: rebased
         uint256 minTarget = block.timestamp + params.minDuration;
         uint256 maxTarget = block.timestamp + params.maxDuration;
         if (targetMaturity < minTarget || targetMaturity > maxTarget) {
```

<a id="m-basemigrationratifier-47"></a>
## ✗ #47 — continuous-fee lifetime * -> + : high fee no longer reaches WAD cap, over-cap offer accepted

- **Mutant:** [`47.sol`](47.sol)
- **Caught by:** [`continuousFeeCapReverts`](../../specs/ratifier/revert.spec#L356) (LVM, LMR)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule continuousFeeCapReverts`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 47`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -396,7 +396,7 @@
         uint256 continuousFee = MORPHO_MIDNIGHT.continuousFee(marketId);
         if (continuousFee == 0) return WAD;
         uint256 timeToMaturity = UtilsLib.zeroFloorSub(offer.market.maturity, block.timestamp);
-        uint256 fee = continuousFee * timeToMaturity;
+        uint256 fee = continuousFee + timeToMaturity;  // MUTATION: rebased
         if (fee >= WAD) revert InvalidTargetMaturity();
         return WAD - fee;
     }
```

<a id="m-basemigrationratifier-48"></a>
## ✗ #48 — Comment out the feeRecipient assignment so setFeeConfig stores only the rate, breaking fee-slot write fidelity

- **Mutant:** [`48.sol`](48.sol)
- **Caught by:** [`setFeeConfigWritesSlotAndLeavesOthers`](../../specs/ratifier/unit.spec#L262)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule setFeeConfigWritesSlotAndLeavesOthers`
- **Run with the mutation (rule `VIOLATED` = mutant Killed):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 48`

```diff
--- a/src/ratifiers/BaseMigrationRatifier.sol
+++ b/src/ratifiers/BaseMigrationRatifier.sol
@@ -89,7 +89,7 @@
         if (_feeRate > _maxFeeRate(callback)) revert InvalidFeeConfig();
         if (_feeRate > 0 && _feeRecipient == address(0)) revert InvalidFeeConfig();
         FeeConfig storage slot = feeConfigs[callback][tenorMarketId];
-        slot.feeRecipient = _feeRecipient;
+        // slot.feeRecipient = _feeRecipient;   // MUTATION: feeRecipient no longer stored
         slot.feeRate = uint96(_feeRate);
         emit FeeConfigSet(callback, tenorMarketId, _feeRate, _feeRecipient);
     }
```

