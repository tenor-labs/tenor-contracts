# Formal Verification Report: Tenor (Migration & Renewal Callbacks, Migration Ratifier)

- Date: July 5th, 2026
- Audit Repo: https://github.com/alexzoid-eth/tenor-contracts-fv
- Client Repo: https://github.com/tenor-labs/tenor-contracts
- Audit Commit: d2cb2ebe3d15ec37aeaf9a5aa19081d53394d8ca (July 5th, 2026)
- Author: [AlexZoid](https://x.com/alexzoid)
- Certora Prover version: 8.16.2

---

## Table of Contents

1. [About Tenor Migration Callbacks](#about-tenor-migration-callbacks)
2. [Formal Verification Methodology](#formal-verification-methodology)
   - [Verification Approach](#verification-approach)
   - [Types of Properties](#types-of-properties)
   - [Verification Process](#verification-process)
   - [Assumptions](#assumptions)
3. [Verification Properties](#verification-properties)
   - [Callbacks](#callbacks)
   - [Migration Ratifier](#migration-ratifier)
4. [Verification Results](#verification-results)
5. [Mutation Testing](#mutation-testing)
6. [Setup and Execution](#setup-and-execution)
   - [Common Setup (Steps 1-5)](#common-setup-steps-1-5)
   - [Remote Execution](#remote-execution)
   - [Local Execution](#local-execution)
   - [Running Verification](#running-verification)
7. [Resources](#resources)

---

## About Tenor Migration Callbacks

Tenor extends the Morpho lending stack with **Morpho Midnight**, a zero-coupon, fixed-rate trading market that sits alongside the variable-rate **Morpho Blue** markets and the yield-bearing **Morpho Vault V2**. Positions are opened and closed through Midnight's `take()` settlement: an off-chain maker offer is matched against an on-chain taker, an intent ratifier validates the trade, and Midnight then invokes an `onBuy` or `onSell` callback that moves the assets and positions atomically. The callbacks in scope let users migrate borrows and lends between Blue, Midnight, and the Vault and roll fixed-rate positions from a maturing market into a new one, without leaving an unsafe intermediate state.

The verification covers the six migration and renewal callbacks and the three supply/withdraw collateral callbacks as independent targets:

1. **BorrowBlueToMidnightCallback (BBM)** — V1 → V2 borrow migration: repays the Blue debt, withdraws the freed collateral, and reopens the borrow on Midnight.

2. **BorrowMidnightToBlueCallback (BMB)** — V2 → V1 borrow migration, the mirror of BBM: withdraws Midnight collateral and opens a Blue borrow.

3. **BorrowMidnightRenewalCallback (BMR)** — V2 → V2 borrow renewal: rolls a borrower's debt and collateral into a fresh Midnight market.

4. **LendVaultToMidnightCallback (LVM)** — vault-funded lend entry: redeems Vault V2 shares and supplies the loan token as Midnight lender credit.

5. **LendMidnightToVaultCallback (LMV)** — lend exit into the vault: withdraws a lender's Midnight credit and deposits it into the vault.

6. **LendMidnightRenewalCallback (LMR)** — V2 → V2 lend renewal: rolls a lender's credit into a fresh Midnight market, charging the renewal fee.

7. **MidnightSupplyCollateralCallback (MSC)** — supplies extra collateral into the seller's Midnight position during a take, pro-rata to the fill and guarded by an optional borrow-capacity cap.

8. **MidnightSupplyVaultSharesCallback (MSV)** — deposits the loan token into an ERC-4626 vault and supplies the minted shares as the seller's collateral.

9. **MidnightWithdrawVaultSharesCallback (MWV)** — the withdraw-side twin of MSV: redeems vault-share collateral out of a position during a take.

Beyond the callbacks, one standalone target covers the intent-validation layer:

10. **MigrationRatifier** — the on-chain gatekeeper that validates every migration before Midnight settles it.

<div style="page-break-before: always;"></div>

---

## Formal Verification Methodology

Certora Formal Verification (FV) proves smart-contract correctness against a formal specification, examining all reachable states rather than the specific paths testing and fuzzing sample. Properties are written in CVL (Certora Verification Language) and submitted with the compiled contracts to the prover, which turns bytecode and rules into a mathematical model and decides each rule's validity.

### Verification Approach

Each of the nine callbacks is verified as its own independent target, each with its own configuration file, harness, and rule set. Because every callback executes only as a sub-call of Midnight's settlement, the verified contract is the `MidnightHarness` model and the callback under test is linked in via Midnight's `MORPHO_MIDNIGHT` / `MORPHO_BLUE` slots; every rule invokes `take()` on that model and asserts before/after deltas over ghost state captured around the single settlement, so each proof isolates one callback's cross-protocol effect while running Midnight's real `onBuy` / `onSell` dispatch.

- The **Midnight** market state is modelled in CVL with ghost mappings and storage hooks, narrowed to a tractable set of touched markets and users ([`midnight.spec`](./specs/setup/midnight/specs/setup/midnight.spec), [`midnight_one.spec`](./specs/setup/midnight/specs/setup/midnight_one.spec), [`midnight_many.spec`](./specs/setup/midnight/specs/setup/midnight_many.spec)). Coupling rules that must reason about two markets at once run in a single-market scalar regime via the `_one` spec variants.
- The **Morpho Blue** market state (borrow shares and collateral) is linked as a second model for the two Blue-touching callbacks (BBM, BMB) via the `MorphoHarness` ([`morpho-blue/`](./specs/setup/morpho-blue)). Blue's own valid-state invariants are reused as preconditions so the migration starts from a well-formed Blue position. On these scenes the Blue sources are compiled from the Certora-only fork [`certora/harnesses/morpho-blue/`](./harnesses/morpho-blue) — upstream code with the `Market` struct renamed to `MarketBlue` to avoid a scene-wide type-name collision with Midnight's own `Market` struct (see the fork's [README](./harnesses/morpho-blue/README.md)); `lib/morpho-blue` stays the faithful upstream mirror used by the Foundry build.
- The four vault-touching callbacks (LVM, LMV, MSV, MWV) run against the **real Morpho Vault V2** contract ([`lib/vault-v2`](../lib/vault-v2)), linked on the scene as `VaultV2Harness`; the vault's share ledger is mirrored into the shared ERC-20 ghost infrastructure and its ERC-20 share operations are routed to the real code (its first-stage fee/adapter pins are listed under Scope Assumptions). The callbacks' vault behaviour is not summarised in CVL; only the global `asset()` ghost remains, supplied by [`erc4626_asset.spec`](./specs/setup/erc4626_asset.spec).
- External token movements use a CVL **ERC-20** model ([`erc20.spec`](./specs/setup/midnight/specs/setup/erc20/erc20.spec)) with ghost balances/allowances and a conserved total supply; the **oracle** ([`oracle.spec`](./specs/setup/midnight/specs/setup/oracle.spec)), **ratifier** ([`ratifier.spec`](./specs/setup/midnight/specs/setup/ratifier.spec)), and **gates** ([`gates.spec`](./specs/setup/midnight/specs/setup/gates.spec)) are summarised so that a settlement is reachable without modelling the off-chain intent machinery.

Together the runs prove that each callback can only move debt, collateral, and credit in the protocol-intended directions and amounts, never strands tokens or approvals, never touches an unrelated user, and never lets the fee recipient lose value.

The MigrationRatifier standalone target is verified directly against its own harness rather than through a `take()`. It summarizes its external dependencies (`getRate`, `settlementFee`, `continuousFee`, `cadencePeriodStart`, `isAuthorized`, `TickLib.tickToPrice`) with deterministic CVL ghosts — stable across calls within a rule, which is what the two-call monotonicity lifts over the full rate gate require — and exposes the internal helpers, the window/cadence machinery, the full rate gate, and typed production-entry bridges via [`MigrationRatifierHarness`](./harnesses/MigrationRatifierHarness.sol).

### Types of Properties

Each callback's rule set combines several property categories:

**State-Transition / Direction properties** — The bulk of the per-callback rules. They capture a ghost value before `take()`, run the settlement, and assert the value changed only in the permitted direction or magnitude: old debt and collateral only shrink, new debt and collateral only grow, a reduction can land on at most one market, debt and collateral move together, and a migrated inflow is bounded by the matching outflow.

**Unit / Conservation properties** — Direct effects and non-effects of a single settlement: Midnight's balance changes only by the trading fee on non-settled tokens, collateral is left untouched by the lend callbacks, and an unrelated bystander's credit, debt, and balances are unchanged.

**Reachability properties** — `satisfy()` rules proving the intended outcomes are actually achievable (non-vacuous verification): a migration can move collateral across protocols, fully close an old position, open new debt, roll credit while charging a fee.

**Reverts / Authorization properties** — `@withrevert` rules confirming the callback rejects any caller other than Midnight and rejects invocations with zero assets or zero units.

### Verification Process

1. **Setup phase**: Define ghost variables, storage hooks, and helper definitions to model Midnight, Morpho Blue, Morpho Vault V2, ERC-20 tokens, the oracle, the ratifier, and the gates in CVL. Establish the per-callback harness and configuration. This phase also addresses several prover limitations:
   - ERC-20 token model ([`erc20.spec`](./specs/setup/midnight/specs/setup/erc20/erc20.spec)): the account set is bounded, so transfers stay tractable and free of spurious reentrancy.
   - Morpho Vault V2 model (see [Verification Approach](#verification-approach)): the real `lib/vault-v2` is pinned to a first-stage config so its interest-accrual loop is dead and `loop_iter: 2` suffices; the only ERC-4626 CVL residue is the global `asset()` ghost ([`erc4626_asset.spec`](./specs/setup/erc4626_asset.spec)).
   - Midnight library summaries — tick ([`tick_lib.spec`](./specs/setup/midnight/specs/setup/tick_lib.spec)), id ([`id_lib.spec`](./specs/setup/midnight/specs/setup/id_lib.spec)), and arithmetic ([`utils_lib.spec`](./specs/setup/midnight/specs/setup/utils_lib.spec)) — alongside the scalar single-/three-market narrowings of position and market state.
   - Oracle, ratifier, and gate summaries (same specs as in the Approach): a well-behaved positive oracle price and empty ratifier/callback payloads, so a single `take()` stays within the run budget.
   - Per-callback setup ([`certora/specs/setup/callbacks/`](./specs/setup/callbacks)): pins the realistic make-on-behalf activation of each callback (see the Scope and Trusted Assumptions below) and the disjointness of the fee recipient, bystanders, and the callback address.
2. **Crafting Properties**: Write the shared safety layer first ([`callbacks.spec`](./specs/callbacks/callbacks.spec)), reuse Midnight and Morpho Blue valid-state invariants as preconditions, then express each callback's direction, conservation, reachability, and revert properties as deltas around `take()`.
3. **Non-vacuity checks**: Because each property runs under several `require` narrowings, an `assert` rule could pass simply because its guarded case is unreachable under those narrowings (a vacuous proof). To rule this out, every rule has a debug-only "satisfy twin" (under each callback's `specs/callbacks/<Callback>/debug_satisfy/`) that keeps the rule body and its narrowings verbatim but swaps the final `assert(...)` for a `satisfy(...)` witnessing the exact scenario the rule guards (a monotone bound `after <= before` becomes `satisfy(after < before)`, an implication `A => B` becomes `satisfy(A)`, a revert rule becomes `satisfy(A && reverted)`, and so on). A reachable witness confirms the rule constrains a real execution rather than an empty set of states. These twins are a sanity aid only — committed alongside the production specs but excluded from the proof suite and the property counts in this report.

**Performance overlay channel (research).** To shorten SMT time on the heaviest callback rules, a research channel adds per-rule *profile overlay* specs under [`certora/specs/callbacks/<Callback>/perf/`](./specs/callbacks) that `import` the production spec and summarise the code branches a given rule provably never reads (each stub backed by a per-rule footprint analysis — the branch's write-set disjoint from the rule's read-set — and an adversarial skeptic pass). They drive parallel `perf` / `perf_satisfy` / `perf_kill` / `perf_kill_satisfy` / `perf_heavy` conf channels plus a B9-lite `override function` variant. Like the satisfy twins, the overlays are excluded from the proof suite and the property counts. Each overlay header records its stub set (STUBS) and the rules it serves (RULES).

### Assumptions

Assumptions address prover timeouts, tool limitations, and state consistency, but incorrect ones can mask bugs by excluding reachable states. Each falls into one of six groups: SAFE (real-world constraints that don't reduce security coverage), UNSAFE (tractability narrowings that exclude reachable, valid scenarios not covered by a sibling rule), SCOPE (regime pins that fix which scenario a rule claims about, where the excluded region is covered elsewhere or is immaterial), PROVED (formally verified invariants or separately-proven rule-lemmas reused as preconditions), ASSERT (facts a real in-scene contract check or revert already enforces, assumed as a precondition), and TRUSTED (activation, fee-recipient configuration, settlement routing, and initialization state assumed correct because the off-chain intent, ratifier, and market-creation logic are excluded from verification). Each such `require` carries a matching `"<CATEGORY>: ..."` message string in the code.

#### Safe Assumptions

Environment Constraints ([`env.spec`](./specs/setup/midnight/specs/setup/env.spec)):
EVM environment constraints that hold for all realistic transactions, and that are kept stable across the two environments of before/after rules.

- Transactions carry no ETH value (`msg.value == 0`)
- The sender is non-zero and is not the contract itself
- Block timestamp is bounded to a realistic range, and the block number is non-zero
- Block number, timestamp, sender, and value are preserved across paired before/after environments

ERC-20 Token Model ([`erc20.spec`](./specs/setup/midnight/specs/setup/erc20/erc20.spec)):
The token model reflects well-behaved ERC-20 tokens used by the protocol.

- Total supply equals the sum of all balances
- Token decimals are realistic (between 6 and 18)
- The called token contract is not the zero address

ERC-4626 `asset()` ghost ([`erc4626_asset.spec`](./specs/setup/erc4626_asset.spec)):
The four vault-touching callbacks (LVM, LMV, MSV, MWV) run against the real Morpho Vault V2 contract, not a CVL model: its valid-state invariants are reused as preconditions under Proved Assumptions, and its first-stage fee/adapter pins are listed under Scope Assumptions. The only ERC-4626 CVL residue is a single global `asset()` ghost — each vault's underlying-asset accessor — with no deposit/redeem/preview/convert modelling.

Bystander and Settlement Constraints ([`callbacks_setup.spec`](./specs/setup/callbacks/callbacks_setup.spec), [`*_cmn.spec`](./specs/setup/callbacks), [`*_setup.spec`](./specs/setup/callbacks)):
Real-world disjointness and environment facts that hold for any honest settlement, independent of how the intent was configured.

- The chosen bystander user is not the active fee recipient
- For BBM and BMB, the bystander user is not Morpho Blue (the cross-protocol partner never holds a Tenor bystander position in these flows)
- The callback is not itself an ERC-4626 vault (LMV, LVM), and the take receiver is not the callback in the default flow
- The take participants (`msg.sender`, the tracked Midnight position users, `offer.maker`, `taker`) are real externally-owned accounts, each distinct from the callback and from Midnight, which are themselves distinct deployed addresses
- The renewal callbacks run with `block.chainid == INITIAL_CHAIN_ID`

#### Proved Assumptions

Reused as preconditions (via `requireInvariant`, or `setupValidStateVaultV2` for the vault) so each migration starts from a well-formed Midnight (and, for BBM/BMB, Morpho Blue; for the four vault-touching callbacks, Morpho Vault V2) position.

Midnight Valid State ([`midnight_valid_state_one.spec`](./specs/setup/midnight/specs/midnight_valid_state_one.spec)):

- A collateral slot is activated in the bitmap iff its balance is non-zero — VS-MI-04 (`collateralBitmapMatchesSlot`)
- A position with any non-zero field implies the market has been touched — VS-MI-05 (`nonEmptyPositionImpliesTouched`)
- A user is either a lender (credit) or a borrower (debt), never both — VS-MI-06 (`creditAndDebtMutuallyExclusive`)

Morpho Blue Valid State ([`morpho_valid_state_one.spec`](./specs/setup/morpho-blue/specs/morpho_valid_state_one.spec)), reused by the cross-protocol borrow callbacks (BBM, BMB):

- A non-existent market has zero positions — VS-21 (`nonExistentMarketPositionsZero`)
- A borrower always has collateral — VS-22 (`alwaysCollateralized`)

Morpho Vault V2 Valid State ([`vaultV2_valid_state.spec`](./specs/setup/vault-v2/specs/vaultV2_valid_state.spec)), reused by the four vault-touching callbacks (LVM, LMV, MSV, MWV) via `setupValidStateVaultV2`:

- The ten Morpho Vault V2 valid-state invariants (share-ledger solvency, accounting coherence, and configuration well-formedness) ported from [alexzoid's morpho-vault-v2-fv](https://github.com/alexzoid-eth/morpho-vault-v2-fv), proven standalone (10/10) on the ported VaultV2 target and reused here as preconditions (via `setupValidStateVaultV2`)

MigrationRatifier ([`ratifier/highlevel.spec`](./specs/ratifier/highlevel.spec), [`unit.spec`](./specs/ratifier/unit.spec)):

- The stored fee rate is capped at `MAX_FEE_RATE` by the `setFeeConfig` guard — invariant RTF-VS-01 — reused where the fee-match gate reads it
- Net seller/buyer price is monotone in the fee — rule-lemmas RTF-UT-11 / RTF-UT-13 — imported by the high-level gate-binding rules (`PROVED` now covers both invariants and separately-proven rule-lemmas)

> Note: The full Morpho Blue, Midnight, and Morpho Vault V2 valid-state suites were verified separately; only the invariants needed as preconditions are reused here (Morpho Blue model: see [`certora/specs/setup/morpho-blue/README.md`](./specs/setup/morpho-blue/README.md)).

#### Scope Assumptions

These pin a rule to its target scenario (e.g. a particular take direction, at-par settlement, or a present source position).

Make-on-behalf Callback Activation ([`cmn.spec`](./specs/setup/callbacks), [`*_setup.spec`](./specs/setup/callbacks)):
Make-on-behalf is the only modeled migration path: the migrating user is the offer **maker**, and `takerCallback` is pinned to zero (the single-sided maker scenario excludes the taker-side callback). [`MigrationRatifier.isRatified`](../src/ratifiers/MigrationRatifier.sol) validates only `offer.maker`, and `TenorRouter` only takes — so a two-sided activation or a taker-side migration callback is not a production-reachable path. The activated callback address and settlement side are trusted activation facts (see Trusted Assumptions).

Market and Position Narrowing ([`midnight_one.spec`](./specs/setup/midnight/specs/setup/midnight_one.spec), [`midnight_many.spec`](./specs/setup/midnight/specs/setup/midnight_many.spec), [`midnight.spec`](./specs/setup/midnight/specs/setup/midnight.spec)):
Midnight's unbounded market and user maps are narrowed to a small, fixed scope; state outside the scope is pinned to zero. The prover then reasons only about the in-scope markets and users.

- At most one market (scalar `_one` regime) or three markets (`_many` regime) are touched; market state outside the scope is zero
- Positions are narrowed to a three-user set; per-user position fields outside the set are zero
- A two-collateral model with the collateral bitmap kept consistent with the per-slot balances and length

ERC-20 Account Bounding ([`erc20.spec`](./specs/setup/midnight/specs/setup/erc20/erc20.spec)):

- Accounts (sender, from, to, owner, spender) are drawn from a predefined, pairwise-distinct bounded set
- Per-account balances are bounded by `max_uint128` to avoid overflow in downstream arithmetic

Tick Narrowing ([`tick_lib.spec`](./specs/setup/midnight/specs/setup/tick_lib.spec)):

- The market tick is restricted to a small fixed set of representative values

Empty Callback / Ratifier Payloads ([`callbacks.spec`](./specs/setup/midnight/specs/setup/callbacks.spec), [`ratifier.spec`](./specs/setup/midnight/specs/setup/ratifier.spec)):

- `take`/`buy`/`sell`/`repay`/`liquidate`/`flash` are invoked with empty callback and ratifier data, so a single settlement stays within the run budget

Morpho Vault V2 First-Stage Pinning ([`*_setup.spec`](./specs/setup/callbacks), [`*_cmn.spec`](./specs/setup/callbacks)):
The real Vault V2 is pinned to a first-stage configuration so its interest-accrual loop is dead and `loop_iter: 2` suffices.

- `performanceFee == managementFee == 0`, `adaptersLength == 0`, and `liquidityAdapter == 0`

Prover Configuration:
- Loop unrolling is capped at 2 iterations across all callback configurations (`loop_iter: 2` with `optimistic_loop`), and each rule is given a 4-hour SMT timeout (`smt_timeout: 14400`).
- Hashing of dynamically-sized data is optimistic (`optimistic_hashing: true`, `hashing_length_bound: 2048` in both callback base confs): hashed dynamic data is assumed at most 2048 bytes long; executions hashing longer data are excluded.
- Unresolved external calls in the ratifier confs are optimistic (`optimistic_fallback: true`): a call dispatching to an unknown function or fallback is assumed not to havoc the verified state; only its return data is nondeterministic.

#### Unsafe Assumptions

A bug hiding only in the excluded region would be missed.

- **Performance overlays** ([`<Callback>/perf*`](./specs/callbacks)): the branch-stub perf overlays disable individual code branches purely for speed, so every assumption they add is Unsafe by construction
- **MSC fill-fraction denominator** ([`MidnightSupplyCollateralCallback/cmn.spec`](./specs/setup/callbacks)): the shared balance / fee-recipient / rate-distortion rules now range over both the `maxAssets` and `maxUnits` legs, but the `MidnightSupplyCollateralCallback` scene keeps a TRUSTED pin `offerSellerAssets == offer.maxAssets` (`cmn.spec:21-22`) that ties that scene's fill-fraction denominator to the `maxAssets` leg
- **Rate-domain slices** ([`ratifier/unit.spec`](./specs/ratifier/unit.spec)): the price-monotonicity rules run on a `uint40`-rate slice even though the production buy branch can reach the full policy-rate range
- **IRM borrow-rate cap** ([`morpho-blue/specs/setup/morpho.spec`](./specs/setup/morpho-blue/specs/setup)): the per-IRM rate ghost is capped at 2e18/yr for tractability, while the canonical AdaptiveCurveIrm curve ceiling is `CURVE_STEEPNESS (4) * MAX_RATE_AT_TARGET` = 8e18/yr — rates in `(2e18/yr, 8e18/yr]` are not explored on the Blue scenes

#### Assert Assumptions

- **Vault-collateral validity** ([`MidnightSupplyVaultShares/cmn.spec`](./specs/setup/callbacks), [`MidnightWithdrawVaultShares/cmn.spec`](./specs/setup/callbacks)): `validateVaultCollateral` reverts unless `vault.asset() == loanToken` and the vault is listed at its collateral slot
- **Percentage-fee cap** ([`callbacks.spec`](./specs/callbacks/callbacks.spec)): `percentageFee` reverts above the 1% contract cap
- **Ratifier real-path facts** ([`reachability.spec`](./specs/ratifier/reachability.spec)): the `tickToPrice` domain (`TickLib` reverts above `MAX_TICK`)

#### Trusted Assumptions

Admin/ratifier-controlled values — the activated callback and its settlement side (`offer.callback`, `offer.buy`) — are Trusted; pure scenario slices excluded from the model (e.g. the taker-side `takerCallback == 0`) are Scope instead.

Callback Activation and Side Pinning ([`*_cmn.spec`](./specs/setup/callbacks), [`*_setup.spec`](./specs/setup/callbacks)):
Each callback's setup pins the single realistic activation the ratified intent produces — the settlement side and the activated callback address.

- BBM, BMR, LMV, MSC, MSV are activated on the sell side (`offer.buy == false`, `onSell`); BMB, LMR, LVM, MWV on the buy side (`offer.buy == true`, `onBuy`)
- `offer.callback` is the callback under test (the activated make-on-behalf callback); that a take actually invokes the callback's `onSell`/`onBuy` is a Scope regime pin

Ratifier-Enforced Intent Constraints ([`*_cmn.spec`](./specs/setup/callbacks), [`*_setup.spec`](./specs/setup/callbacks)):
The ratifier validates each intent before Midnight settles it; because the ratifier is summarised rather than executed, these validations are taken on trust.

- The callback tick equals the offer tick (`decodeCallbackTick(offer.callbackData) == offer.tick`) — for the tick-carrying callbacks (BBM, BMR, LMR, LVM); MidnightSupplyVaultShares and MidnightSupplyCollateral carry no tick field
- The callback fee rate is capped at `MAX_FEE_RATE` for BBM, BMR, LMR, and LVM, and a positive fee requires a non-zero fee recipient
- The BMB and LMV main flows are verified with the callback fee disabled (`cbFeeRate == 0`); the exception is CLB-BMB-10, which varies the rate to characterize the percentage-fee 1% cap guard (`feeRate > MAX_PERCENTAGE_FEE_RATE => revert`)

Fee Recipient Configuration ([`callbacks.spec`](./specs/callbacks/callbacks.spec), [`*_cmn.spec`](./specs/setup/callbacks), [`*_setup.spec`](./specs/setup/callbacks)):
The fee recipient is an admin/ratifier-configured address, so its disjointness from the take participants is trusted rather than a free real-world fact.

- The fee recipient is not the callback, not a take participant, not Midnight, not `msg.sender`, and not an ERC-4626 vault
- For BBM and BMB, the fee recipient is not Morpho Blue (the cross-protocol partner is never a Tenor fee recipient)

Settlement Funding Flow ([`*_cmn.spec`](./specs/setup/callbacks), [`*_setup.spec`](./specs/setup/callbacks)):
For the seller-funded flows, the ratified intent routes the seller assets to the callback so it can perform the repay or deposit; this routing is taken on trust.

- The seller assets land on the callback for BBM (Blue repay), BMR (Midnight repay), and LMV (vault deposit)

Market Initialization ([`midnight.spec`](./specs/setup/midnight/specs/setup/midnight.spec), [`midnight_one.spec`](./specs/setup/midnight/specs/setup/midnight_one.spec)):

- The market's loan token and collateral token were set by a prior `touchMarket` (post-initialization state)
- The loan token and the collateral token are not the lending contract itself

#### Standalone-Target Model (Ratifier)

The MigrationRatifier target adds its own model assumptions, annotated in-spec with the full six-category scheme; here PROVED covers invariant RTF-VS-01 and rule-lemmas RTF-UT-11 / RTF-UT-13, and no `TRUSTED` is used because the ratifier is the verified target rather than excluded code:

- **Deterministic ghost summaries** (MigrationRatifier): `getRate` is an uninterpreted function bounded by `2^128` (the ASSUME-POLICY-1 boundary); `settlementFee` and `TickLib.tickToPrice` are bounded by `WAD`, the tick price additionally monotone (the ASSUME-TICK-1 trust boundary — TickLib is audited with Midnight and only monotonicity and the bound are relied on); `continuousFee` is bounded by `uint32` (its return type); `isAuthorized` and `cadencePeriodStart` are free ghost tables. Safe.
- **Rate-gate scope slices** (MigrationRatifier): the four rate-gate monotonicity rules run on the `ratifyRate` exposer (the full two-call `isRatified` differential does not converge locally); the lender-limit rule additionally pins `continuousFee == 0` (a Scope regime pin; the haircut is a common factor of both runs), and both limit rules carry a `SAFE:` target-maturity date bound (`now <= tgtMat <= now + max_uint32`, a ~136-year window that admits every realistic maturity — the lower edge is anyway enforced on the real path by `_validateTargetMaturity`) so `rate * duration` cannot overflow. All four rules (and their two satisfy twins) also pin `offer.market.collateralParams.length == 0` — Safe: the rate gate never reads `collateralParams` (`idLibToIdCVL` drops them from the summarized market id), so the pin only removes a gate-unrelated calldata address-decode revert from the harness call. The `uint40`-rate domain slice used by the price-monotonicity lemmas is Unsafe. The window/cadence/target gates are characterized on the full `isRatified` flow without these slices.
- **Live-source exit pin** (MigrationRatifier): RTF-HL-02 (`v2v1ExitsHaveNoRenewalCadenceConstraint`) requires `offer.market.maturity != 0` on a V2→V1 exit — a live Midnight source has maturity>0 by construction (`maturity==0` is the V1/non-Midnight sentinel), so the excluded corner is a malformed offer, not a real scenario. Safe.

<div style="page-break-before: always;"></div>

---

## Verification Properties

Links to specific CVL spec files are provided for each property. **Status** (production run): ✅ verified · ⏱️ timed out (4-hour SMT budget exhausted) · ❌ violated.

**Mutations** ([diffs](#mutation-testing)): **❌** caught · **❓** not caught. **ˢ** = caught via satisfy-twin.

Migration Ratifier ✅ and ❌ icons link to the corresponding runs on the Certora cloud prover (anonymous links).

### Callbacks

All properties exercise Midnight's `take()` settlement. The **Shared Safety Rules** are re-verified under every applicable callback's setup; each callback's own properties and the per-callback status follow in the tables below.

#### Shared Safety Rules

| Property | Name | Description | Mutations |
|----------|------|-------------|----|
| [CLB-01](./specs/callbacks/callbacks.spec#L5-L22) (CB-DUST-1) | `callbackHoldsZeroAllowance` | The callback never leaves token approvals to anyone.<br>`allowance[t][callback][s] == 0 => allowance[t][callback][s]' == 0` | ❌ [BorrowMidnightRenewalCallback#35](#m-borrowmidnightrenewalcallback-35)ˢ ❌ [MidnightWithdrawVaultSharesCallback#2](#m-midnightwithdrawvaultsharescallback-2) |
| [CLB-02](./specs/callbacks/callbacks.spec#L24-L53) | `thirdPartyBalanceUnchanged` | An operation never changes balances of bystanders (users unrelated to it).<br>`u unrelated to take => balance[t][u]' == balance[t][u]` | ❌ [BorrowMidnightRenewalCallback#35](#m-borrowmidnightrenewalcallback-35)ˢ |
| [CLB-03](./specs/callbacks/callbacks.spec#L55-L76) (CB-DUST-1) | `callbackNeverHoldsTokens` | The callback never ends holding more tokens than it started — it can sweep pre-existing funds out but cannot leave new dust.<br>`balance[t][callback]' <= balance[t][callback]` | ❌ [BorrowMidnightRenewalCallback#33](#m-borrowmidnightrenewalcallback-33)ˢ ❌ [MidnightWithdrawVaultSharesCallback#6](#m-midnightwithdrawvaultsharescallback-6) |
| [CLB-04](./specs/callbacks/callbacks.spec#L78-L87) (CB-AUTH-1) | `callbackRevertsForNonMidnightCaller` | The callback rejects calls from anyone other than Midnight.<br>`msg.sender != Midnight => REVERTS` | ❌ [BorrowBlueToMidnightCallback#1](#m-borrowbluetomidnightcallback-1) ❌ [MidnightSupplyCollateralCallback#1](#m-midnightsupplycollateralcallback-1) |
| [CLB-05](./specs/callbacks/callbacks.spec#L89-L100) | `callbackRevertsOnZeroAssetsOrUnits` | The callback rejects operations with zero assets or zero units.<br>`(assets == 0 OR units == 0) => REVERTS` | ❌ [LendMidnightRenewalCallback#2](#m-lendmidnightrenewalcallback-2) ❌ [MidnightSupplyCollateralCallback#2](#m-midnightsupplycollateralcallback-2) |
| [CLB-06](./specs/callbacks/callbacks.spec#L102-L135) | `feeRecipientNeverLosesTokens` | The fee recipient's balance never decreases during an operation.<br>`balance[t][feeRecipient]' >= balance[t][feeRecipient]` | ❌ [BorrowMidnightRenewalCallback#35](#m-borrowmidnightrenewalcallback-35)ˢ |
| [CLB-07](./specs/callbacks/callbacks.spec#L137-L155) (CB-FEE-3) | `percentageFeeNeverExceedsAssets` | The flat percentage fee paid never exceeds assets/100 (sharp 1% cap; cannot exceed the principal charged).<br>`!reverted => 100 * delta(claimableFee) <= assets` | ❌ [LendMidnightToVaultCallback#10](#m-lendmidnighttovaultcallback-10) |
| [CLB-08](./specs/callbacks/callbacks.spec#L157-L176) (CB-FEE-1) | `sellerTickFeeNeverExceedsAssets` | The seller tick fee paid never exceeds sellerAssets, so the callback's `repayBudget = sellerAssets - fee` never underflows.<br>`!reverted => delta(balance[loanToken][feeRecipient]) <= sellerAssets` | ❌ [BorrowMidnightRenewalCallback#22](#m-borrowmidnightrenewalcallback-22) |
| [CLB-09](./specs/callbacks/callbacks.spec#L178-L196) (CB-FEE-2) | `buyerTickFeePaidBoundedByUnits` | The buyer tick fee paid is bounded by the trade size `units`.<br>`!reverted => delta(balance[loanToken][feeRecipient]) <= units` | ❌ [LendMidnightRenewalCallback#14](#m-lendmidnightrenewalcallback-14) |
| [CLB-10](./specs/callbacks/callbacks.spec#L198-L217) | `positiveFeeIsPayable` | A positive fee is actually payable through the callback, so the CLB-07/08/09 bounds are not vacuously about a zero fee.<br>`satisfy(delta(claimableFee) > 0)` | ❌ [LendMidnightRenewalCallback#8](#m-lendmidnightrenewalcallback-8) |

**Per-callback re-verification.** Statuses per the legend above; **·** = rule not applicable to that callback.

| Rule | BBM | BMB | BMR | LMR | LMV | LVM | MSC | MSV | MWV |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| CLB-01 `callbackHoldsZeroAllowance` | ⏱️ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| CLB-02 `thirdPartyBalanceUnchanged` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| CLB-03 `callbackNeverHoldsTokens` | ⏱️ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| CLB-04 `callbackRevertsForNonMidnightCaller` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| CLB-05 `callbackRevertsOnZeroAssetsOrUnits` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| CLB-06 `feeRecipientNeverLosesTokens` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | · | · | · |
| CLB-07 `percentageFeeNeverExceedsAssets` | · | ✅ | · | · | ✅ | · | · | · | · |
| CLB-08 `sellerTickFeeNeverExceedsAssets` | ✅ | · | ✅ | · | · | · | · | · | · |
| CLB-09 `buyerTickFeePaidBoundedByUnits` | · | · | · | ⏱️ | · | ⏱️ | · | · | · |
| CLB-10 `positiveFeeIsPayable` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | · | · | · |

#### BorrowBlueToMidnightCallback (BBM)

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [CLB-BBM-01](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L13-L29) (CB-V1-REP-1) | `migrationOnlyReducesOldBlueDebt` | Migration can only reduce the old Blue debt, never increase it.<br>`blueBorrowShares[id][u]' <= blueBorrowShares[id][u]` | ✅ | ❌ [BorrowBlueToMidnightCallback#15](#m-borrowbluetomidnightcallback-15) |
| [CLB-BBM-02](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L31-L47) (CB-DIR-1) | `migrationOnlyWithdrawsOldBlueCollateral` | Migration can only withdraw old Blue collateral, never add to it.<br>`blueCollateral[id][u]' <= blueCollateral[id][u]` | ✅ | ❌ [BorrowBlueToMidnightCallback#16](#m-borrowbluetomidnightcallback-16) |
| [CLB-BBM-03](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L49-L70) (CB-DIR-1) | `migrationReducesOldDebtOnAtMostOneMarket` | One migration can reduce old debt on at most one Blue market.<br>`NOT( blueBorrowShares[idA][u]' < blueBorrowShares[idA][u] AND blueBorrowShares[idB][u]' < blueBorrowShares[idB][u] )` | ✅ | ❌ [BorrowBlueToMidnightCallback#20](#m-borrowbluetomidnightcallback-20)ˢ ❌ [BorrowMidnightToBlueCallback#29](#m-borrowmidnighttobluecallback-29)ˢ |
| [CLB-BBM-04](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L72-L92) (CB-FINAL-2) | `clearingOldDebtAlsoEmptiesOldCollateral` | Clearing the last of the old debt also empties the old collateral.<br>`blueBorrowShares[id][u] > 0 AND blueBorrowShares[id][u]' == 0 AND blueCollateral[id][u] > 0 => blueCollateral[id][u]' == 0` | ⏱️ | ❌ [BorrowBlueToMidnightCallback#3](#m-borrowbluetomidnightcallback-3) |
| [CLB-BBM-05](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L94-L110) (CB-DIR-1) | `migrationOnlyAddsNewMidnightCollateral` | Migration only adds new Midnight collateral, never removes it.<br>`mnCollateral[id][u][i]' >= mnCollateral[id][u][i]` | ✅ | ❌ [BorrowBlueToMidnightCallback#9](#m-borrowbluetomidnightcallback-9) |
| [CLB-BBM-06](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L112-L133) (CB-DIR-1) | `migrationConservesMigratedCollateral` | Collateral withdrawn from the old Blue position equals the collateral deposited into the new Midnight position — conserved 1:1 during migration.<br>`blueCollateral[id][u] - blueCollateral[id][u]' == mnCollateral[mnId][u][i]' - mnCollateral[mnId][u][i] (when both sides move)` | ✅ | ❌ [BorrowBlueToMidnightCallback#4](#m-borrowbluetomidnightcallback-4) |
| [CLB-BBM-07](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L135-L154) | `migrationCanMoveCollateralBlueToMidnight` | A migration can actually move collateral from the old position to the new one.<br>`satisfy(blueCollateral[id][u]' < blueCollateral[id][u] AND mnCollateral[id][u][i]' > mnCollateral[id][u][i])` | ✅ | ❌ [BorrowBlueToMidnightCallback#2](#m-borrowbluetomidnightcallback-2) |
| [CLB-BBM-08](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L156-L176) (CB-CLOSE-1) | `migrationCanFullyCloseOldPosition` | A migration can fully close the old position (both debt and collateral go to zero).<br>`satisfy(blueBorrowShares[id][u]' == 0 AND blueCollateral[id][u]' == 0) (pre: both > 0)` | ✅ | ❌ [BorrowBlueToMidnightCallback#21](#m-borrowbluetomidnightcallback-21) ❌ [BorrowMidnightToBlueCallback#10](#m-borrowmidnighttobluecallback-10) |
| [CLB-BBM-09](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L178-L219) (CB-RATE-1) | `borrowerFeeBoundedByInterestShare` | The borrower's callback fee never exceeds feeRate applied to the interest portion of the trade, so the effective seller rate stays within (1 + feeRate/WAD) of the offer rate.<br>`f*WAD^2 <= units*(WAD - price)*feeRate (+ one-unit ceil rounding slack)` | ⏱️ | ❌ [BorrowBlueToMidnightCallback#18](#m-borrowbluetomidnightcallback-18) ❌ [BorrowMidnightRenewalCallback#36](#m-borrowmidnightrenewalcallback-36) |
| [CLB-BBM-10](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L221-L245) (CB-FEE-4) | `tickFeeVanishesAtPar` | At par (price == WAD) with full-value settlement (assets == units) the seller tick fee vanishes (carved from interest, not principal).<br>`price==WAD && assets==units && !reverted => feeRecipient delta == 0` | ✅ | ❌ [CallbackLib#1](#m-callbacklib-1) ❌ [CallbackLib#4](#m-callbacklib-4) ❌ [CallbackLib#5](#m-callbacklib-5) ❌ [CallbackLib#6](#m-callbacklib-6) |
| [CLB-BBM-11](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L247-L268) (CB-CLOSE-2) | `fullCollateralMigrationClearsAllOldDebt` | Repaying expectedBorrowAssets(seller) clears all V1 borrow shares — full collateral migration empties the old debt.<br>`blueCollateral[id][u] > 0 AND blueCollateral[id][u]' == 0 AND blueBorrowShares[id][u] > 0 => blueBorrowShares[id][u]' == 0` | ✅ | ❌ [BorrowBlueToMidnightCallback#12](#m-borrowbluetomidnightcallback-12)ˢ |
| [CLB-BBM-12](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L270-L282) (CB-DUST-1) | `receiverNotCallbackReverts` | The migration onSell requires the sale proceeds to route to the callback itself (else the sellerAssets it needs to repay the old Blue debt are stranded).<br>`receiver != address(callback) => REVERTS (InvalidReceiver)` | ✅ | ❌ [BorrowBlueToMidnightCallback#22](#m-borrowbluetomidnightcallback-22) ❌ [BorrowMidnightRenewalCallback#13](#m-borrowmidnightrenewalcallback-13) ❌ [LendMidnightToVaultCallback#11](#m-lendmidnighttovaultcallback-11) ❌ [MidnightSupplyVaultSharesCallback#10](#m-midnightsupplyvaultsharescallback-10) |
| [CLB-BBM-13](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L284-L296) (CB-SRC-1) | `sourceLoanTokenMismatchReverts` | onSell rejects a source Blue market whose loanToken differs from the offer loanToken.<br>`sourceMarketParams.loanToken != market.loanToken => REVERTS (TokenMismatch)` | ✅ | ❌ [BorrowBlueToMidnightCallback#14](#m-borrowbluetomidnightcallback-14) |

#### BorrowMidnightToBlueCallback (BMB)

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [CLB-BMB-01](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L13-L29) (CB-DIR-1) | `migrationOnlyWithdrawsOldMidnightCollateral` | Migration can only withdraw old Midnight collateral, never add to it.<br>`mnCollateral[id][u][i]' <= mnCollateral[id][u][i]` | ✅ | ❌ [BorrowMidnightToBlueCallback#20](#m-borrowmidnighttobluecallback-20) |
| [CLB-BMB-02](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L31-L52) (CB-DIR-1) | `migrationReducesOldDebtOnAtMostOneMarket` | One migration can reduce old debt on at most one Midnight market.<br>`NOT( mnDebt[idA][u]' < mnDebt[idA][u] AND mnDebt[idB][u]' < mnDebt[idB][u] )` | ✅ | ❌ [BorrowBlueToMidnightCallback#20](#m-borrowbluetomidnightcallback-20)ˢ ❌ [BorrowMidnightToBlueCallback#29](#m-borrowmidnighttobluecallback-29)ˢ |
| [CLB-BMB-03](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L54-L70) (CB-DIR-1) | `migrationOnlyOpensNewBlueDebt` | Migration only opens new Blue debt, never reduces it.<br>`blueBorrowShares[id][u]' >= blueBorrowShares[id][u]` | ✅ | ❌ [BorrowMidnightToBlueCallback#27](#m-borrowmidnighttobluecallback-27) |
| [CLB-BMB-04](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L72-L88) (CB-DIR-1) | `migrationOnlyAddsNewBlueCollateral` | Migration only adds new Blue collateral, never removes it.<br>`blueCollateral[id][u]' >= blueCollateral[id][u]` | ✅ | ❌ [BorrowMidnightToBlueCallback#26](#m-borrowmidnighttobluecallback-26) |
| [CLB-BMB-05](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L90-L111) (CB-SRC-1) | `migrationCannotDepositMoreCollateralThanWithdrawn` | Migration cannot deposit more new collateral than it withdrew from the old position.<br>`mnColOut > 0 AND blueColIn > 0 => blueColIn <= mnColOut (mnColOut = mnCollateral[id][u][i] - mnCollateral', blueColIn = blueCollateral' - blueCollateral)` | ✅ | ❌ [BorrowMidnightToBlueCallback#24](#m-borrowmidnighttobluecallback-24) |
| [CLB-BMB-06](./specs/callbacks/BorrowMidnightToBlueCallback/one.spec#L7-L26) (CB-DIR-1) | `oldMidnightDebtAndNewBlueDebtMoveTogether` | Opening new Blue debt always implies the source Midnight debt drops (forward direction only; the reverse need not hold because a partial-redeem path can close Midnight debt without engaging Blue migration).<br>`delta(blueBorrowShares) > 0 => delta(mnDebt) < 0` | ✅ | ❌ [BorrowMidnightToBlueCallback#30](#m-borrowmidnighttobluecallback-30) |
| [CLB-BMB-07](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L134-L150) | `migrationCanOpenNewBlueDebt` | A migration can actually open new Blue debt.<br>`satisfy(blueBorrowShares[id][u]' > blueBorrowShares[id][u])` | ⏱️ | ❌ [BorrowMidnightToBlueCallback#8](#m-borrowmidnighttobluecallback-8) |
| [CLB-BMB-08](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L152-L171) | `migrationCanMoveCollateralMidnightToBlue` | A migration can actually move collateral from the old position to the new one.<br>`satisfy(mnCollateral[id][u][i]' < mnCollateral[id][u][i] AND blueCollateral[id][u]' > blueCollateral[id][u])` | ⏱️ | ❌ [BorrowMidnightToBlueCallback#9](#m-borrowmidnighttobluecallback-9) |
| [CLB-BMB-09](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L173-L193) (CB-CLOSE-1) | `migrationCanFullyCloseOldPosition` | A migration can fully close the old position (both debt and collateral go to zero).<br>`satisfy(mnDebt[id][u]' == 0 AND mnCollateral[id][u][i]' == 0) (pre: both > 0)` | ✅ | ❌ [BorrowBlueToMidnightCallback#21](#m-borrowbluetomidnightcallback-21) ❌ [BorrowMidnightToBlueCallback#10](#m-borrowmidnighttobluecallback-10) |
| [CLB-BMB-10](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L195-L207) (CL-2, InvalidFeeConfig) | `percentageFeeRateAboveCapReverts` | A callback fee rate above the 1% cap (MAX_PERCENTAGE_FEE_RATE = 0.01e18) is rejected by `CallbackLib.percentageFee`, verified through the BMB onBuy entry point.<br>`decodeCallbackFeeRate(data) > MAX_PERCENTAGE_FEE_RATE => REVERTS` | ✅ | ❌ [BorrowMidnightToBlueCallback#18](#m-borrowmidnighttobluecallback-18) |
| [CLB-BMB-11](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L113-L132) (CB-FINAL-3) | `migrationFinalFillTransfersAllOldMidnightCollateral` | A final fill (old Midnight debt fully cleared) transfers ALL the old Midnight collateral, never a pro-rata fraction.<br>`mnCollateral[id][u][i] > mnCollateral[id][u][i]' AND mnDebt[id][u]' == 0 => mnCollateral[id][u][i]' == 0` | ✅ | ❌ [BorrowMidnightToBlueCallback#25](#m-borrowmidnighttobluecallback-25) |

#### BorrowMidnightRenewalCallback (BMR)

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [CLB-BMR-01](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L19-L40) (CB-DIR-1) | `renewalReducesDebtOnAtMostOneMarket` | One renewal can reduce debt on at most one market.<br>`NOT( mnDebt[idA][u]' < mnDebt[idA][u] AND mnDebt[idB][u]' < mnDebt[idB][u] )` | ✅ | ❌ [BorrowMidnightRenewalCallback#24](#m-borrowmidnightrenewalcallback-24) |
| [CLB-BMR-02](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L42-L63) (CB-DIR-1) | `renewalAddsDebtOnAtMostOneMarket` | One renewal can add debt on at most one market.<br>`NOT( mnDebt[idA][u]' > mnDebt[idA][u] AND mnDebt[idB][u]' > mnDebt[idB][u] )` | ✅ | ❌ [BorrowMidnightRenewalCallback#34](#m-borrowmidnightrenewalcallback-34)ˢ |
| [CLB-BMR-03](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L65-L85) (CB-DIR-1) | `renewalCannotAddCollateralWhenReducingDebt` | In a market where renewal reduces debt, collateral cannot rise.<br>`mnDebt[id][u]' < mnDebt[id][u] => mnCollateral[id][u][i]' <= mnCollateral[id][u][i]` | ✅ | ❌ [BorrowMidnightRenewalCallback#23](#m-borrowmidnightrenewalcallback-23) |
| [CLB-BMR-04](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L87-L107) (CB-DIR-1) | `renewalCannotRemoveCollateralWhenOpeningDebt` | In a market where renewal opens debt, collateral cannot drop.<br>`mnDebt[id][u]' > mnDebt[id][u] => mnCollateral[id][u][i]' >= mnCollateral[id][u][i]` | ✅ | ❌ [BorrowMidnightRenewalCallback#23](#m-borrowmidnightrenewalcallback-23) ❌ [BorrowMidnightRenewalCallback#31](#m-borrowmidnightrenewalcallback-31)ˢ |
| [CLB-BMR-05](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L109-L126) (CB-SRC-1) | `renewalCallbackNeverPullsExternalLoanToken` | A borrow renewal only uses loanToken delivered by the take, never external liquidity.<br>`delta(balance[loanToken][callback]) <= units` | ✅ | ❌ [BorrowMidnightRenewalCallback#25](#m-borrowmidnightrenewalcallback-25) ❌ [LendMidnightRenewalCallback#23](#m-lendmidnightrenewalcallback-23) |
| [CLB-BMR-06](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L128-L153) (CB-FINAL-4) | `renewalCannotMoveMoreCollateralThanWithdrawn` | Renewing cannot move more collateral to the new position than was withdrawn from the old one.<br>`srcColOut > 0 AND tgtColIn > 0 => tgtColIn <= srcColOut (same collateral token) (srcColOut = collateral[src] - collateral[src]', tgtColIn = collateral[tgt]' - collateral[tgt])` | ✅ | ❌ [CollateralTransferLib#3](#m-collateraltransferlib-3) |
| [CLB-BMR-07](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L155-L174) | `renewalCanMoveDebtBetweenMarkets` | A renewal can actually move debt from one market to another.<br>`satisfy(mnDebt[src][u]' < mnDebt[src][u] AND mnDebt[tgt][u]' > mnDebt[tgt][u])` | ✅ | ❌ [BorrowMidnightRenewalCallback#1](#m-borrowmidnightrenewalcallback-1) ❌ [BorrowMidnightRenewalCallback#8](#m-borrowmidnightrenewalcallback-8) |
| [CLB-BMR-08](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L176-L196) | `renewalCanMigrateCollateralBetweenMarkets` | A renewal can actually migrate collateral between two markets.<br>`satisfy(mnCollateral[src][u][i]' < mnCollateral[src][u][i] AND mnCollateral[tgt][u][j]' > mnCollateral[tgt][u][j])` | ✅ | ❌ [CollateralTransferLib#4](#m-collateraltransferlib-4) |
| [CLB-BMR-09](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L198-L218) (CB-CLOSE-1) | `renewalCanFullyCloseOldPosition` | A renewal can fully close the old position (both debt and collateral go to zero).<br>`satisfy(mnDebt[src][u]' == 0 AND mnCollateral[src][u][i]' == 0) (pre: both > 0)` | ✅ | ❌ [CollateralTransferLib#1](#m-collateraltransferlib-1) |
| [CLB-BMR-10](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L220-L261) (CB-RATE-1) | `borrowerFeeBoundedByInterestShare` | The borrower's callback fee never exceeds feeRate applied to the interest portion of the trade, so the effective seller rate stays within (1 + feeRate/WAD) of the offer rate.<br>`f*WAD^2 <= units*(WAD - price)*feeRate (+ one-unit ceil rounding slack)` | ⏱️ | ❌ [BorrowBlueToMidnightCallback#18](#m-borrowbluetomidnightcallback-18) ❌ [BorrowMidnightRenewalCallback#36](#m-borrowmidnightrenewalcallback-36) |
| [CLB-BMR-11](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L263-L289) (CB-FEE-4) | `tickFeeVanishesAtPar` | At par (price == WAD) with full-value settlement (assets == units) the seller tick fee vanishes (carved from interest, not principal).<br>`price==WAD && assets==units && !reverted => feeRecipient delta == 0` | ✅ | ❌ [CallbackLib#1](#m-callbacklib-1) ❌ [CallbackLib#4](#m-callbacklib-4) ❌ [CallbackLib#5](#m-callbacklib-5) ❌ [CallbackLib#6](#m-callbacklib-6) |
| [CLB-BMR-12](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L291-L302) (CB-SAME-1) | `callbackRevertsForSameSourceMarket` | A renewal into the same Midnight market is rejected.<br>`toId(callbackData.sourceMarket) == marketId => REVERTS (SameMarket)` | ✅ | ❌ [BorrowMidnightRenewalCallback#3](#m-borrowmidnightrenewalcallback-3) ❌ [LendMidnightRenewalCallback#24](#m-lendmidnightrenewalcallback-24) |
| [CLB-BMR-13](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L304-L316) (CB-DUST-1) | `receiverNotCallbackReverts` | The renewal onSell requires the sale proceeds to route to the callback itself (else the sellerAssets it needs to repay the source debt are stranded).<br>`receiver != address(callback) => REVERTS (InvalidReceiver)` | ✅ | ❌ [BorrowBlueToMidnightCallback#22](#m-borrowbluetomidnightcallback-22) ❌ [BorrowMidnightRenewalCallback#13](#m-borrowmidnightrenewalcallback-13) ❌ [LendMidnightToVaultCallback#11](#m-lendmidnighttovaultcallback-11) ❌ [MidnightSupplyVaultSharesCallback#10](#m-midnightsupplyvaultsharescallback-10) |

#### LendVaultToMidnightCallback (LVM)

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [CLB-LVM-01](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L14-L32) (CB-SRC-1) | `vaultFundedLendOnlyMovesLoanToken` | A vault-funded lend moves Midnight's balance of any non-vault, non-loanToken asset only by the trading fee it accrues.<br>`t != loanToken AND ERC4626asset[t] == 0 => delta(balance[t][Midnight]) == delta(claimableSettlementFee[t])` | ⏱️ | ❌ [LendVaultToMidnightCallback#9](#m-lendvaulttomidnightcallback-9) |
| [CLB-LVM-02](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L34-L51) | `vaultFundedLendLeavesCollateralUnchanged` | Lending funded from a vault never touches anyone's collateral.<br>`collateral[id][u][i]' == collateral[id][u][i]` | ✅ | ❌ [LendVaultToMidnightCallback#7](#m-lendvaulttomidnightcallback-7) |
| [CLB-LVM-03](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L53-L69) | `vaultFundedLendCanRaiseCredit` | A vault-funded lend can actually increase a lender's credit.<br>`satisfy(credit[id][u]' > credit[id][u])` | ✅ | ❌ [LendVaultToMidnightCallback#5](#m-lendvaulttomidnightcallback-5) |
| [CLB-LVM-04](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L71-L93) (CB-DIR-1) | `vaultFundedLendNeverTouchesUnrelatedUser` | A vault-funded lend never touches an unrelated user's credit or debt.<br>`u bystander => credit[id][u]' == credit[id][u] AND debt[id][u]' == debt[id][u]` | ✅ | ❌ [LendVaultToMidnightCallback#12](#m-lendvaulttomidnightcallback-12) |
| [CLB-LVM-05](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L95-L136) (CB-RATE-2) | `lenderFeeBoundedByInterestShare` | The lender's callback overcharge never exceeds feeRate on the trade's interest portion, so the effective lender rate stays within (1 - feeRate/WAD) of the offer rate.<br>`f*WAD^2 <= units*(WAD - price)*feeRate (+ one-unit floor rounding slack)` | ⏱️ | ❌ [LendVaultToMidnightCallback#11](#m-lendvaulttomidnightcallback-11) |
| [CLB-LVM-06](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L138-L166) (CB-FEE-4) | `tickFeeVanishesAtPar` | At par (price == WAD) with full-value settlement (assets == units) the buyer tick fee vanishes (carved from interest, not principal).<br>`price==WAD && assets==units && !reverted => feeRecipient delta == 0` | ✅ | ❌ [CallbackLib#1](#m-callbacklib-1) ❌ [CallbackLib#4](#m-callbacklib-4) ❌ [CallbackLib#5](#m-callbacklib-5) ❌ [CallbackLib#6](#m-callbacklib-6) |
| [CLB-LVM-07](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L168-L181) (CB-DUST-1) | `vaultAssetMismatchReverts` | Vault-funded onBuy rejects any vault whose asset() differs from the market loanToken.<br>`vault.asset() != loanToken => REVERTS (TokenMismatch)` | ✅ | ❌ [LendMidnightToVaultCallback#3](#m-lendmidnighttovaultcallback-3) ❌ [LendVaultToMidnightCallback#4](#m-lendvaulttomidnightcallback-4) ❌ [MidnightSupplyVaultSharesCallback#4](#m-midnightsupplyvaultsharescallback-4) |

#### LendMidnightToVaultCallback (LMV)

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [CLB-LMV-01](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L14-L38) (CB-SRC-1) | `vaultExitConservesMidnightBalanceMinusFee` | Exiting credit into a vault moves Midnight's balance of any non-vault, non-loanToken asset only by the trading fee it accrues.<br>`t != loanToken AND ERC4626asset[t] == 0 => delta(balance[t][Midnight]) == delta(claimableSettlementFee[t])` | ⏱️ | ❌ [LendMidnightToVaultCallback#20](#m-lendmidnighttovaultcallback-20) |
| [CLB-LMV-02](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L40-L57) | `vaultExitLeavesCollateralUnchanged` | Exiting a credit position into a vault never touches anyone's collateral.<br>`collateral[id][u][i]' == collateral[id][u][i]` | ✅ | ❌ [LendMidnightToVaultCallback#21](#m-lendmidnighttovaultcallback-21) |
| [CLB-LMV-03](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L59-L81) (CB-DIR-1) | `vaultExitNeverTouchesUnrelatedUser` | A vault exit never touches the credit or debt of an unrelated user.<br>`u bystander => credit[id][u]' == credit[id][u] AND debt[id][u]' == debt[id][u]` | ✅ | ❌ [LendMidnightToVaultCallback#13](#m-lendmidnighttovaultcallback-13) |
| [CLB-LMV-04](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L83-L100) (CB-CLOSE-1) | `vaultExitCanFullyCloseCredit` | An exit-to-vault can fully close a lender's source credit (zero remaining).<br>`satisfy(credit[id][u]' == 0) (pre: credit[id][u] > 0)` | ✅ | ❌ [LendMidnightToVaultCallback#7](#m-lendmidnighttovaultcallback-7) |
| [CLB-LMV-05](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L102-L114) (CB-DUST-1) | `receiverNotCallbackReverts` | The vault-exit onSell requires the sale proceeds to route to the callback itself (else the sellerAssets it needs to fund the vault deposit are stranded).<br>`receiver != address(callback) => REVERTS (InvalidReceiver)` | ✅ | ❌ [BorrowBlueToMidnightCallback#22](#m-borrowbluetomidnightcallback-22) ❌ [BorrowMidnightRenewalCallback#13](#m-borrowmidnightrenewalcallback-13) ❌ [LendMidnightToVaultCallback#11](#m-lendmidnighttovaultcallback-11) ❌ [MidnightSupplyVaultSharesCallback#10](#m-midnightsupplyvaultsharescallback-10) |
| [CLB-LMV-06](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L116-L129) (CB-DUST-1) | `vaultAssetMismatchReverts` | Vault-exit onSell rejects any vault whose asset() differs from the market loanToken.<br>`vault.asset() != loanToken => REVERTS (TokenMismatch)` | ✅ | ❌ [LendMidnightToVaultCallback#3](#m-lendmidnighttovaultcallback-3) ❌ [LendVaultToMidnightCallback#4](#m-lendvaulttomidnightcallback-4) ❌ [MidnightSupplyVaultSharesCallback#4](#m-midnightsupplyvaultsharescallback-4) |

#### LendMidnightRenewalCallback (LMR)

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [CLB-LMR-01](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L14-L35) (CB-DIR-1) | `renewalAddsCreditOnAtMostOneMarket` | A renewal can add credit on at most one market.<br>`NOT( credit[idA][u]' > credit[idA][u] AND credit[idB][u]' > credit[idB][u] )` | ✅ | ❌ [LendMidnightRenewalCallback#21](#m-lendmidnightrenewalcallback-21)ˢ |
| [CLB-LMR-02](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L37-L68) (CB-DIR-1) | `renewalReducesCreditOnAtMostOneMarket` | A renewal can reduce credit on at most one market.<br>`NOT( credit[idA][u]' < credit[idA][u] AND credit[idB][u]' < credit[idB][u] )` | ⏱️ | ❌ [LendMidnightRenewalCallback#19](#m-lendmidnightrenewalcallback-19) |
| [CLB-LMR-03](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L70-L87) (CB-SRC-1) | `renewalCallbackNeverPullsExternalLoanToken` | A renewal only uses loanToken delivered by the take, never external liquidity.<br>`delta(balance[loanToken][callback]) <= units` | ✅ | ❌ [BorrowMidnightRenewalCallback#25](#m-borrowmidnightrenewalcallback-25) ❌ [LendMidnightRenewalCallback#23](#m-lendmidnightrenewalcallback-23) |
| [CLB-LMR-04](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L89-L108) (CB-DIR-1) | `renewalNeverTouchesUnrelatedLenderCredit` | A renewal never touches the credit of an unrelated lender.<br>`u bystander => credit[id][u]' == 0` | ✅ | ❌ [LendMidnightRenewalCallback#25](#m-lendmidnightrenewalcallback-25)ˢ |
| [CLB-LMR-05](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L110-L128) | `renewalCanFullyCloseOldCredit` | A renewal can fully close an old credit position.<br>`satisfy(credit[id][u]' == 0) (pre: credit[id][u] > 0)` | ✅ | ❌ [LendMidnightRenewalCallback#16](#m-lendmidnightrenewalcallback-16) |
| [CLB-LMR-06](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L130-L178) | `renewalCanMoveCreditWithPositiveFee` | A renewal can move credit and charge a positive fee at the same time.<br>`satisfy(credit[src]' < credit[src] AND credit[tgt]' > credit[tgt] AND srcLoss > tgtGain)` | ✅ | ❌ [LendMidnightRenewalCallback#17](#m-lendmidnightrenewalcallback-17) |
| [CLB-LMR-07](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L180-L207) (CB-FEE-4) | `tickFeeVanishesAtPar` | At par (price == WAD) with full-value settlement (assets == units) the buyer tick fee vanishes (carved from interest, not principal).<br>`price==WAD && assets==units && !reverted => feeRecipient delta == 0` | ✅ | ❌ [CallbackLib#1](#m-callbacklib-1) ❌ [CallbackLib#4](#m-callbacklib-4) ❌ [CallbackLib#5](#m-callbacklib-5) ❌ [CallbackLib#6](#m-callbacklib-6) |
| [CLB-LMR-08](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L209-L220) (CB-SAME-1) | `callbackRevertsForSameSourceMarket` | A renewal into the same Midnight market is rejected.<br>`toId(callbackData.sourceMarket) == marketId => REVERTS (SameMarket)` | ✅ | ❌ [BorrowMidnightRenewalCallback#3](#m-borrowmidnightrenewalcallback-3) ❌ [LendMidnightRenewalCallback#24](#m-lendmidnightrenewalcallback-24) |

#### MidnightSupplyCollateralCallback (MSC)

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [CLB-MSC-01](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L12-L32) | `supplyMonotoneCollateral` | A supply take never decreases anyone's collateral (the callback only supplies, never withdraws).<br>`collateral[id][u][i]' >= collateral[id][u][i]` | ✅ | ❌ [MidnightSupplyCollateralCallback#21](#m-midnightsupplycollateralcallback-21) ❌ [MidnightSupplyVaultSharesCallback#12](#m-midnightsupplyvaultsharescallback-12) |
| [CLB-MSC-02](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L34-L61) | `bystanderUntouched` | A supply take never touches a non-participant's collateral, debt, or credit.<br>`u != taker AND u != maker => collateral/debt/credit[id][u]' == ..[id][u]` | ✅ | ❌ [MidnightSupplyCollateralCallback#20](#m-midnightsupplycollateralcallback-20) ❌ [MidnightSupplyVaultSharesCallback#22](#m-midnightsupplyvaultsharescallback-22) |
| [CLB-MSC-03](./specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L6-L29) | `proRataUpperBound` | A partial fill never supplies more collateral than the configured per-slot amount.<br>`collateral[seller][i]' - collateral[seller][i] <= amounts[i]` | ⏱️ | ❌ [MidnightSupplyCollateralCallback#18](#m-midnightsupplycollateralcallback-18) |
| [CLB-MSC-04](./specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L31-L59) (CB-SC-CAP-1) | `borrowCapacityUsageWithinCap` | After a supply fill, the borrower's borrow-capacity usage stays within maxBorrowCapacityUsage — debt over lltv-weighted borrowing capacity (Midnight's isHealthy() ratio), not raw LTV (the health gate). The on-chain `ceil(debt'*WAD / capacity') <= maxBCU` is asserted as the equivalent product form.<br>`maxBCU > 0 AND debt' > 0 => debt' * WAD <= maxBCU * capacity'`  (capacity' = mulDivDown(mulDivDown(col0', price0, ORACLE_PRICE_SCALE), lltv0, WAD)) | ⏱️ | ❌ [MidnightSupplyCollateralCallback#23](#m-midnightsupplycollateralcallback-23) |
| [CLB-MSC-05](./specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L61-L84) (CB-SC-CAP-1 liveness) | `maxBorrowCapacityUsageFillReachable` | A maxBorrowCapacityUsage-guarded supply fill can succeed with rising collateral and live debt.<br>`satisfy(maxBCU > 0 AND collateral[seller][0]' > collateral[seller][0] AND debt[seller]' > 0)` | ✅ | ❌ [MidnightSupplyCollateralCallback#13](#m-midnightsupplycollateralcallback-13) |
| [CLB-MSC-06](./specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L86-L102) | `supplyCanRaiseCollateral` | A supply fill can actually raise the borrower's collateral.<br>`satisfy(collateral[seller][0]' > collateral[seller][0])` | ✅ | ❌ [MidnightSupplyCollateralCallback#9](#m-midnightsupplycollateralcallback-9) |
| [CLB-MSC-07](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L63-L75) | `collateralLengthMismatchReverts` | The callback rejects an amounts[] array whose length mismatches the market collaterals.<br>`amounts.length != market.collateralParams.length => REVERTS` | ✅ | ❌ [MidnightSupplyCollateralCallback#4](#m-midnightsupplycollateralcallback-4) |
| [CLB-MSC-08](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L77-L89) | `offerSellerAssetsZeroReverts` | The callback rejects a zero offerSellerAssets (the fill-fraction denominator).<br>`offerSellerAssets == 0 => REVERTS` | ✅ | ❌ [MidnightSupplyCollateralCallback#14](#m-midnightsupplycollateralcallback-14) |
| [CLB-MSC-09](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L91-L103) (CB-DUST-2) | `receiverIsCallbackReverts` | The supply onSell rejects routing the sale proceeds to the callback itself — they would be permanently locked.<br>`receiver == address(callback) => REVERTS (InvalidReceiver)` | ✅ | ❌ [MidnightSupplyCollateralCallback#10](#m-midnightsupplycollateralcallback-10) |

#### MidnightSupplyVaultSharesCallback (MSV)

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [CLB-MSV-01](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L12-L32) | `supplyMonotoneCollateral` | A supply take never decreases anyone's collateral (the callback only supplies, never withdraws).<br>`collateral[id][u][i]' >= collateral[id][u][i]` | ✅ | ❌ [MidnightSupplyCollateralCallback#21](#m-midnightsupplycollateralcallback-21) ❌ [MidnightSupplyVaultSharesCallback#12](#m-midnightsupplyvaultsharescallback-12) |
| [CLB-MSV-02](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L34-L61) | `bystanderUntouched` | A supply take never touches a non-participant's collateral, debt, or credit.<br>`u != taker AND u != maker => collateral/debt/credit[id][u]' == ..[id][u]` | ✅ | ❌ [MidnightSupplyCollateralCallback#20](#m-midnightsupplycollateralcallback-20) ❌ [MidnightSupplyVaultSharesCallback#22](#m-midnightsupplyvaultsharescallback-22) |
| [CLB-MSV-03](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L5-L27) | `onlyVaultSlotReceivesSupply` | Supply lands only on the configured vault slot (slot 0); other collateral slots are untouched.<br>`i != 0 => collateral[seller][i]' == collateral[seller][i]` | ✅ | ❌ [MidnightSupplyVaultSharesCallback#14](#m-midnightsupplyvaultsharescallback-14) |
| [CLB-MSV-04](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L29-L55) | `suppliedSharesMatchMintedShares` | Every newly minted vault share becomes the seller's collateral.<br>`delta(collateral[seller][0]) == delta(totalSupply[vault])` | ✅ | ❌ [MidnightSupplyVaultSharesCallback#11](#m-midnightsupplyvaultsharescallback-11) |
| [CLB-MSV-05](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L57-L75) | `vaultShareBeneficiaryIsSeller` | Only the seller's vault-share collateral can increase (shares cannot be supplied for a third party).<br>`collateral[u][0]' > collateral[u][0] => u == seller` | ✅ | ❌ [MidnightSupplyVaultSharesCallback#15](#m-midnightsupplyvaultsharescallback-15) |
| [CLB-MSV-06](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L77-L96) | `supplyCanRaiseVaultCollateral` | A vault-deposit supply can actually raise the seller's collateral.<br>`satisfy(collateral[seller][0]' > collateral[seller][0])` | ✅ | ❌ [MidnightSupplyVaultSharesCallback#8](#m-midnightsupplyvaultsharescallback-8) ❌ [MidnightSupplyVaultSharesCallback#9](#m-midnightsupplyvaultsharescallback-9) ❌ [MidnightSupplyVaultSharesCallback#18](#m-midnightsupplyvaultsharescallback-18) ❌ [MidnightSupplyVaultSharesCallback#20](#m-midnightsupplyvaultsharescallback-20) |
| [CLB-MSV-07](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L63-L85) (user-fund safety) | `noExtraPullWhenPercentZero` | With additionalDepositPercent == 0 the callback pulls no loanToken from the seller.<br>`additionalDepositPercent == 0 => balance[loanToken][seller]' == balance[loanToken][seller]` | ✅ | ❌ [MidnightSupplyVaultSharesCallback#13](#m-midnightsupplyvaultsharescallback-13) |
| [CLB-MSV-08](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L87-L100) | `vaultAssetMismatchReverts` | The callback rejects a vault whose underlying asset is not the loan token.<br>`vault.asset() != loanToken => REVERTS` | ✅ | ❌ [LendMidnightToVaultCallback#3](#m-lendmidnighttovaultcallback-3) ❌ [LendVaultToMidnightCallback#4](#m-lendvaulttomidnightcallback-4) ❌ [MidnightSupplyVaultSharesCallback#4](#m-midnightsupplyvaultsharescallback-4) |
| [CLB-MSV-09](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L102-L120) | `vaultNotAtIndexReverts` | The callback rejects a vault not listed at the configured collateral index.<br>`collateralParams[collateralIndex].token != vault => REVERTS` | ✅ | ❌ [MidnightSupplyVaultSharesCallback#5](#m-midnightsupplyvaultsharescallback-5) |
| [CLB-MSV-10](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L122-L134) (CB-DUST-1) | `receiverNotCallbackReverts` | The vault-share supply onSell requires the sale proceeds to route to the callback itself (else the sellerAssets it needs to mint the vault shares are stranded).<br>`receiver != address(callback) => REVERTS (InvalidReceiver)` | ✅ | ❌ [BorrowBlueToMidnightCallback#22](#m-borrowbluetomidnightcallback-22) ❌ [BorrowMidnightRenewalCallback#13](#m-borrowmidnightrenewalcallback-13) ❌ [LendMidnightToVaultCallback#11](#m-lendmidnighttovaultcallback-11) ❌ [MidnightSupplyVaultSharesCallback#10](#m-midnightsupplyvaultsharescallback-10) |
| [CLB-MSV-11](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L98-L129) (user-fund safety) | `extraPullMatchesPercentFormula` | With additionalDepositPercent > 0 the callback pulls exactly the expected extra loanToken from the seller (positive-percent complement of CLB-MSV-07).<br>`additionalDepositPercent > 0 => balance[loanToken][seller] - balance[loanToken][seller]' == mulDivUp(sellerAssets, additionalDepositPercent, WAD)` | ✅ | ❌ [MidnightSupplyVaultSharesCallback#21](#m-midnightsupplyvaultsharescallback-21) |

#### MidnightWithdrawVaultSharesCallback (MWV)

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [CLB-MWV-01](./specs/callbacks/MidnightWithdrawVaultSharesCallback/many.spec#L12-L27) (CB-VAULT-WD-1) | `takeCanDropCollateralOnNarrowedMarket` | A vault-share withdraw take can actually reduce a position's collateral.<br>`satisfy(collateral[id][u][i]' < collateral[id][u][i])` | ✅ | ❌ [MidnightWithdrawVaultSharesCallback#5](#m-midnightwithdrawvaultsharescallback-5) |
| [CLB-MWV-02](./specs/callbacks/MidnightWithdrawVaultSharesCallback/many.spec#L29-L53) (CB-VAULT-WD-1) | `takeLeavesVaultShareBalanceUnchanged` | A withdraw take leaves the callback's vault-share balance unchanged — onBuy nets the withdrawCollateral share-in against the vault.withdraw share-out.<br>`vaultToken == collateralParams[0].token => balance[vaultToken][callback]' == balance[vaultToken][callback]` | ✅ | ❌ [MidnightWithdrawVaultSharesCallback#1](#m-midnightwithdrawvaultsharescallback-1) ❌ [MidnightWithdrawVaultSharesCallback#8](#m-midnightwithdrawvaultsharescallback-8)ˢ |

<div style="page-break-before: always;"></div>

### Migration Ratifier

The MigrationRatifier standalone target is verified directly against its own harness (see [Verification Approach](#verification-approach)), running as six per-category configurations under `certora/confs/ratifier/`. Each rule's [`PROPERTIES.md`](./PROPERTIES.md) id is shown in parentheses in the Property column (three rules assert client-code guards that have no catalog entry and carry local ids instead: RTF-WL-1, RTF-CFEE-1, RTF-RC-V1V2); ✅ is a full proof within the target's trust boundary.

#### MigrationRatifier

The MigrationRatifier production confs run with `rule_sanity: none`; sanity is covered by the `debug_advanced/` variants (`rule_sanity: advanced`). Most rules drive the production entry `isRatified` directly; the four rate-gate monotonicity rules use the `ratifyRate` gate-isolation exposer, and the PriceLib/helper math (RTF-UT-05..10, PRICE-1..4 + ORCH-4/13) is asserted directly on the exposed real pure functions. External dependencies are summarised with deterministic ghosts (see [Standalone-Target Model](#standalone-target-model-ratifier)).

##### Valid state (`ratifier/valid_state.spec`) — inductive invariants on the stored fee configuration

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [RTF-VS-01](./specs/ratifier/valid_state.spec#L5-L11) (ORCH-1) | `feeRateNeverExceedsCallbackCap` | no reachable state stores an above-cap fee rate; setFeeConfig's guard is the inductive step.<br>`invariant: feeConfigs[cb][id].feeRate <= cap(cb)  (cap = 0 on the V2->V1 exits, 0.5e18 otherwise)` | [✅](https://prover.certora.com/output/52567/8e23bffb92054cafb075cea57e7e2f29?anonymousKey=fabd95ef7420ba4235839e5f37973805eac90ddb) | [❌](https://prover.certora.com/output/52567/2cd25c093c474a90a84b46198bc23415?anonymousKey=a60bdc860a1dd664c801b995a238731ea6ae01c8) [BaseMigrationRatifier#39](#m-basemigrationratifier-39) |
| [RTF-VS-02](./specs/ratifier/valid_state.spec#L13-L18) (ORCH-2) | `nonZeroFeeRateImpliesRecipient` | a stored non-zero fee rate always carries a recipient.<br>`invariant: feeConfigs[cb][id].feeRate > 0 => feeConfigs[cb][id].feeRecipient != 0` | [✅](https://prover.certora.com/output/52567/8e23bffb92054cafb075cea57e7e2f29?anonymousKey=fabd95ef7420ba4235839e5f37973805eac90ddb) | [❌](https://prover.certora.com/output/52567/8ff0b8d530ff4caea26003df0c6aa8c4?anonymousKey=fff31534089beb62ca9b3d2b02988c8524ab53cf) [BaseMigrationRatifier#40](#m-basemigrationratifier-40) |

##### Access control (`ratifier/access_control.spec`) — owner-/authorization-gated storage mutations

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [RTF-AC-01](./specs/ratifier/access_control.spec#L6-L22) (ORCH-1) | `feeConfigChangeRequiresOwner` | only the owner can change a stored fee config (access-control facet of the ORCH-1 fee-config family; the value-bound is RTF-VS-01).<br>`feeConfigs[cb][id]' != feeConfigs[cb][id] => msg.sender == owner` | [✅](https://prover.certora.com/output/52567/bf03aabf290f4f6a9b74a08270c10467?anonymousKey=df7020fbf74218773d685518f448a9c4a368ddb1) | [❌](https://prover.certora.com/output/52567/76df59a998eb40299c21388232522fdb?anonymousKey=88f03714e6f04a13b1921e99c0165dfd9f885cff) [BaseMigrationRatifier#2](#m-basemigrationratifier-2) |
| [RTF-AC-02](./specs/ratifier/access_control.spec#L24-L43) (REG-1) | `userParamsChangeRequiresAuthorization` | a user's stored params change only when the caller is onBehalf or Midnight-authorized for them.<br>`userParams[onBehalf][cb][src][tgt]' != userParams[onBehalf][cb][src][tgt] => sender == onBehalf OR isAuthorized(onBehalf, sender)` | [✅](https://prover.certora.com/output/52567/bf03aabf290f4f6a9b74a08270c10467?anonymousKey=df7020fbf74218773d685518f448a9c4a368ddb1) | [❌](https://prover.certora.com/output/52567/97f849a9e2ce491494beecfd2b65f8e2?anonymousKey=27df4b54c6e1e82a196fa8b3fea47d7613476328) [MigrationRatifier#8](#m-migrationratifier-8) |

##### Reverts (`ratifier/revert.spec`) — implication revert characterizations of the entry guards and validation gates, driven through `isRatified`

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [RTF-RV-01](./specs/ratifier/revert.spec#L5-L18) (ORCH-NEW-8, InvalidRatifierData) | `invalidRatifierDataLengthReverts` | isRatified rejects ratifierData that is not exactly 64 bytes (the abi.encode(src,tgt) length).<br>`ratifierData.length != 64 => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/7ef137b75cda4408b3af6cf0d969acb3?anonymousKey=45a9b0082422c52a440e4ad075ec6f0dc96615b0) [MigrationRatifier#9](#m-migrationratifier-9) |
| [RTF-RV-02](./specs/ratifier/revert.spec#L20-L36) (ORCH-NEW-6, InvalidReceiver) | `makerReceiverMustBePinned` | isRatified rejects an offer whose maker-seller receiver is not pinned — address(0) on a buy, offer.callback on a sell.<br>`receiverIfMakerIsSeller != (offer.buy ? 0 : offer.callback) => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/32202d6cf9154da79448d2c988576493?anonymousKey=940b953caa09f948f490bc6f6b9a7956de2a4259) [MigrationRatifier#10](#m-migrationratifier-10) |
| [RTF-RV-03](./specs/ratifier/revert.spec#L38-L55) (ORCH-NEW-7, InvalidGroup) | `migrationGroupNamespaceEnforced` | isRatified rejects an offer whose group is outside the reserved migration-group namespace.<br>`(offer.group & MIGRATION_GROUP_HEADER_MASK) != MIGRATION_GROUP_HEADER => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/e6bda177f7d3491aa2324f16513f60d8?anonymousKey=71fedf9a7bb18455f150ba0eb38648c34b46ede5) [MigrationRatifier#11](#m-migrationratifier-11) |
| [RTF-RV-04](./specs/ratifier/revert.spec#L57-L76) | `unconfiguredTupleAlwaysReverts` | isRatified reverts when the stored params tuple is unconfigured or malformed.<br>`policy==0 \|\| minDuration==0 \|\| maxDuration<minDuration => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/ed2ccca4688e4a50b224561d6d6f0c0d?anonymousKey=7549839549a37703eaef7183b50174fffb2a5887) [BaseMigrationRatifier#10](#m-basemigrationratifier-10) |
| [RTF-RV-05](./specs/ratifier/revert.spec#L78-L94) (DEFAULT-4) | `tickMustMatchOffer` | for V2→V2 (BMR/LMR) and V1→V2 (BBM/LVM) callbacks, callbackData.tick must equal offer.tick (V2→V1 exits exempt).<br>`(isV2ToV2(cb) \|\| isV1ToV2(cb)) && cd.tick != offer.tick => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/b84b34d4225248b6966d177d8459c16d?anonymousKey=d0faed4bfd14b2d9009a8860ce201440476d4e85) [BaseMigrationRatifier#25](#m-basemigrationratifier-25) |
| [RTF-RV-06](./specs/ratifier/revert.spec#L96-L111) (ORCH-9) | `targetMaturityMustExceedSource` | isRatified rejects a target maturity that does not strictly exceed the source.<br>`targetMaturity > 0 && targetMaturity <= sourceMaturity => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/5f1878ea4e894c28b3754bb2399934aa?anonymousKey=435b2d1761fd125df8eaf15db23055e206c25af4) [BaseMigrationRatifier#13](#m-basemigrationratifier-13) |
| [RTF-RV-07](./specs/ratifier/revert.spec#L113-L138) (ORCH-10) | `targetMaturityWithinDurationBand` | isRatified rejects a target maturity outside the stored [now+minDuration, now+maxDuration] band.<br>`tgtMat>0 && (tgtMat < now+minDuration \|\| tgtMat > now+maxDuration) => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/ca7823f7d1ea4146b69743e7e13d7a80?anonymousKey=8c64420ac22d9b18d7105924dff79cb7fbdbf169) [BaseMigrationRatifier#44](#m-basemigrationratifier-44) |
| [RTF-RV-08](./specs/ratifier/revert.spec#L140-L164) (ORCH-11) | `targetMaturityOnCadenceGrid` | with a cadence configured, isRatified rejects a target maturity off the cadence grid.<br>`tgtMat>0 && renewalCadence != 0 && cadencePeriodStart(tgtMat) != tgtMat => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/882c53afa7064efc90d991a7d90ce800?anonymousKey=f8cbbf73e1030c8604d073918b5c78e2a8b5aa9c) [BaseMigrationRatifier#15](#m-basemigrationratifier-15) |
| [RTF-RV-09](./specs/ratifier/revert.spec#L166-L184) (DEFAULT-3) | `ratifierDataMustMatchCallbackMarkets` | isRatified rejects an offer whose ratifierData markets disagree with the callback-derived markets.<br>`(cSrc, cTgt) != (ratifierSrc, ratifierTgt) => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/1c8cac9468f74900bf5711aee5815938?anonymousKey=ad2166a5990d588b5d553d2df7f8ceb78c770e3d) [MigrationRatifier#5](#m-migrationratifier-5) |
| [RTF-RV-10](./specs/ratifier/revert.spec#L186-L204) (DEFAULT-2) | `callbackFeeMustMatchEffectiveConfig` | isRatified rejects callbackData whose fee fields disagree with the effective fee config.<br>`(cFeeRate, cFeeRecip) != getEffectiveFeeConfig(cb, feeMarketId) => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/201f21e0b1e34ec4a06870ab0c912caf?anonymousKey=5377985800bac8d9550af5a7f27888534d97c3ab) [BaseMigrationRatifier#11](#m-basemigrationratifier-11) [❌](https://prover.certora.com/output/52567/28c4c1e773f34b4185430acdf678c400?anonymousKey=60d1a8a30085d7c3b99283b76fb02521570cdc7f) [BaseMigrationRatifier#12](#m-basemigrationratifier-12) |
| [RTF-RV-11](./specs/ratifier/revert.spec#L206-L227) (ORCH-8) | `v2SourceWindowEnforcedBeforeOpen` | a V2 (Midnight) source taken before its renewal window opens is rejected.<br>`now < srcMat - renewalWindow (mathint) => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/3296f8b884354d779c8e3a10c649cc34?anonymousKey=2868dfb80a6375b28cbfccadcdc3ac451124dc79) [BaseMigrationRatifier#45](#m-basemigrationratifier-45) |
| [RTF-RV-12](./specs/ratifier/revert.spec#L229-L249) (ORCH-7) | `variableSourceWindowEnforced` | a V1→V2 enter (variable source, sourceMaturity==0) needs a configured cadence whose nearest boundary is not in the future.<br>`isV1ToV2(cb) && (cad==0 \|\| cadencePeriodStart(now)>now) => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/2cb4222582eb4b05a6c231f40181c640?anonymousKey=7801ad00b67412b9f9c2aa7789e8f0203d6321cd) [BaseMigrationRatifier#36](#m-basemigrationratifier-36) |
| [RTF-RV-13](./specs/ratifier/revert.spec#L251-L277) (ORCH-10) | `targetMaturityWithinDurationBand_boundaryAccepted` | satisfy companion: a target maturity exactly at now+minDuration (inclusive lower band edge) is acceptable.<br>`satisfy !revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/d95268dfa67c46d4b5c81957588e1529?anonymousKey=50fb0b053bc02ef768df6f3f8b40999bc8bb4793) [BaseMigrationRatifier#22](#m-basemigrationratifier-22) |
| [RTF-RV-14](./specs/ratifier/revert.spec#L279-L306) (ORCH-8) | `v2SourceWindowEnforcedBeforeOpen_boundaryAccepted` | satisfy companion: a fixed V2 source with renewalWindow == sourceMaturity (window opens at time 0) is acceptable.<br>`satisfy !revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/7808468866dd423bb3a491b13a0e2540?anonymousKey=9e99aa8d91b4456e067b35a68c6559519672a1f5) [BaseMigrationRatifier#23](#m-basemigrationratifier-23) |
| [RTF-RV-15](./specs/ratifier/revert.spec#L308-L334) (ORCH-7) | `variableSourceWindowEnforced_boundaryAccepted` | satisfy companion: a V1→V2 enter whose nearest cadence boundary is exactly now is ratifiable.<br>`satisfy !revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/c29c49e1b6b44abcb27fb00415b1e79f?anonymousKey=7c28338e7ee85f03f9d8da0bb4a5b3f2a89057c2) [BaseMigrationRatifier#24](#m-basemigrationratifier-24) |
| [RTF-RV-16](./specs/ratifier/revert.spec#L336-L351) (RTF-WL-1) | `unauthorizedCallbackReverts` | isRatified rejects an offer whose callback is not one of the six authorized migration callbacks (the route whitelist; the callback-context decoder's final else-branch).<br>`callback not in {BMR,LMR,BBM,LVM,BMB,LMV} => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/6192d914087e486a8eccd157766bce54?anonymousKey=ff9422393a79f6e4a4c119f30769dd09f5340cb3) [BaseMigrationRatifier#43](#m-basemigrationratifier-43) |
| [RTF-RV-17](./specs/ratifier/revert.spec#L353-L377) (RTF-CFEE-1) | `continuousFeeCapReverts` | on the two Midnight-target lend flows (LVM enter, LMR renewal) isRatified rejects a target whose lifetime continuous fee would consume the whole WAD face value.<br>`cb in {LVM,LMR} && continuousFee != 0 && continuousFee*zeroFloorSub(maturity,now) >= WAD => revert(isRatified)` | [✅](https://prover.certora.com/output/52567/c46394fa2cc540b0973572df723f8f57?anonymousKey=b695c20961a49ed4c53d6a36f33625fcb50ea346) | [❌](https://prover.certora.com/output/52567/ec80357f6ef04c8f9ce9a9cdd2fd8a96?anonymousKey=b9cb6561aa24adba765d225eb78b99f6ce430209) [BaseMigrationRatifier#47](#m-basemigrationratifier-47) |

##### Unit (`ratifier/unit.spec`) — write-fidelity, the rate-gate directionality map, the per-callback helpers, and the PriceLib rate-limit math

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [RTF-UT-01](./specs/ratifier/unit.spec#L6-L24) (ORCH-3) | `getEffectiveFeeConfigMarketOverridesActionDefault` | getEffectiveFeeConfig returns the market slot when its recipient is set, else the bytes32(0) default.<br>`cfg[cb][id].recipient != 0 ? cfg[cb][id] : cfg[cb][bytes32(0)]` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/d18899aadfcb49f79996de8b37b9ede1?anonymousKey=e2ae2f2ecbb996c771dc5b197acf9912070e6aa0) [BaseMigrationRatifier#18](#m-basemigrationratifier-18) |
| [RTF-UT-02](./specs/ratifier/unit.spec#L26-L52) (ORCH-15, REG-2) | `setParamsWritesTupleAndLeavesOthers` | setParams writes exactly the addressed tuple and leaves every other tuple untouched.<br>`userParams[u][cb][s][t]' == p  &&  (u2,cb2,s2,t2) != (u,cb,s,t) => userParams[u2][cb2][s2][t2]' unchanged` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/438dd54ed58d4ee1909c036c5cc878e8?anonymousKey=7d997b536668f99fba68328ddb0ad04b90a215d9) [MigrationRatifier#2](#m-migrationratifier-2) |
| [RTF-UT-03](./specs/ratifier/unit.spec#L54-L78) (REG-3) | `clearParamsZeroesTupleAndLeavesOthers` | clearParams zeroes the addressed tuple and leaves every other tuple untouched.<br>`userParams[u][cb][s][t]' == 0  &&  (u2,cb2,s2,t2) != (u,cb,s,t) => userParams[u2][cb2][s2][t2]' unchanged` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/083f195bf7634d0ca780a1fcc506a262?anonymousKey=97013cc2674fa074a07f8754de8dde4d06146645) [MigrationRatifier#3](#m-migrationratifier-3) |
| [RTF-UT-04](./specs/ratifier/unit.spec#L80-L92) (DEFAULT-1, RATE-3) | `userIsBuyMatchesBuySideCallbacks` | the rate-gate buy-side flag is set for exactly the three Midnight-buy callbacks.<br>`_userIsBuy(cb) <=> cb in { LEND_VAULT_TO_MIDNIGHT, BORROW_MIDNIGHT_TO_BLUE, LEND_MIDNIGHT_RENEWAL }` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/7dcada76d4674d37aa783beb0e5d1d48?anonymousKey=de2504767e12349a39ed769a25d131d865836003) [BaseMigrationRatifier#19](#m-basemigrationratifier-19) |
| [RTF-UT-05](./specs/ratifier/unit.spec#L96-L111) (PRICE-1) | `priceFollowsZeroCouponFormula` | computePrice == WAD^2/(WAD + rate*dur), in (0, WAD], floored for the buyer / ceiled for the seller.<br>`buy == floor(WAD^2/denom) && sell == ceil(WAD^2/denom) && 0 < price <= WAD   (denom = WAD + rate*dur)` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/5b62b96cee994b09a7533863b8137b7e?anonymousKey=1263c5f3df6a931c66155de9c25891f73a7955c9) [PriceLib#1](#m-pricelib-1) [❌](https://prover.certora.com/output/52567/3cff95f3c9b149ae9722325495d721db?anonymousKey=f602d9e75e3fb2e9c66026017f7281548a4c4a8f) [PriceLib#2](#m-pricelib-2) |
| [RTF-UT-06](./specs/ratifier/unit.spec#L113-L119) (PRICE-2) | `priceRoundsInProtectedUserFavor` | rounding favors each side — the buyer's (floor) price never exceeds the seller's (ceil) price.<br>`computePrice(true, rate, dur) <= computePrice(false, rate, dur)` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/5b62b96cee994b09a7533863b8137b7e?anonymousKey=1263c5f3df6a931c66155de9c25891f73a7955c9) [PriceLib#1](#m-pricelib-1) |
| [RTF-UT-07](./specs/ratifier/unit.spec#L121-L129) (PRICE-3) | `effectiveRateSelectsTighterBound` | computeEffectiveRate selects the tighter bound — min for the borrower, max for the lender.<br>`computeEffectiveRate(false,p,l) == min(p,l) && computeEffectiveRate(true,p,l) == max(p,l)` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/367e91364af64ab982e032e4aee9793f?anonymousKey=ec161b6884775a84eca54c0f4a99d6a596539433) [PriceLib#3](#m-pricelib-3) |
| [RTF-UT-08](./specs/ratifier/unit.spec#L131-L146) (PRICE-4) | `satisfiesRateLimitComparisonDirection` | satisfiesRateLimit enforces the borrower ceiling (assets*WAD >= units*price) and the lender floor (<=).<br>`satisfies(false,..) <=> a*WAD >= u*priceBorrow && satisfies(true,..) <=> a*WAD <= u*priceLend` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/edb6ed92a3174a89b8e82ac6d6df1e0b?anonymousKey=9401f4f1a7788b0be7abc18fd3ec2166554140aa) [PriceLib#4](#m-pricelib-4) [❌](https://prover.certora.com/output/52567/cb669a975bc74282867b2a38630db50e?anonymousKey=439773a3f0aa545ee2251413f718b344b701aeb6) [PriceLib#7](#m-pricelib-7) |
| [RTF-UT-09](./specs/ratifier/unit.spec#L150-L158) (ORCH-4) | `maxFeeRateZeroOnV2ToV1Exits` | the per-callback fee-rate cap is zero on the V2→V1 exits (BMB/LMV), MAX_FEE_RATE otherwise.<br>`_maxFeeRate(cb) == (isV2ToV1(cb) ? 0 : MAX_FEE_RATE)` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/b7b3b7426a0147669c1cb6fc8e9a47eb?anonymousKey=b6f1ecbe5c617fc47b188d147c7afb424d6f7984) [BaseMigrationRatifier#20](#m-basemigrationratifier-20) |
| [RTF-UT-10](./specs/ratifier/unit.spec#L160-L182) (ORCH-13) | `computeDurationPerCallback` | per-callback accrual duration; the V2→V1 exit clamps to 0 once the source has matured.<br>`renewal: tgt - max(now,src) ; enter: tgt - now ; exit: now>=src ? 0 : src-now` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/d814f6d924ef457c941e00a2925b1100?anonymousKey=0897824bea3e4042776daa5ca2fb590315a15c49) [BaseMigrationRatifier#21](#m-basemigrationratifier-21) |
| [RTF-UT-11](./specs/ratifier/unit.spec#L186-L196) (decomposition, lifts RTF-HL-04) | `netSellerPriceMonotoneInFee` | the net seller price is non-increasing in the fee rate (a borrower enter prices the offer down as the fee grows).<br>`feeLo <= feeHi => netSellerPrice(p, sf, feeLo) >= netSellerPrice(p, sf, feeHi)` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/e9900c8f7dce408db2671d1c2528c330?anonymousKey=90833464a3882fa359f3d4e33fe7368d4581521d) [CallbackLib#3](#m-callbacklib-3) [❌](https://prover.certora.com/output/52567/589fc5e7943e461aa67b0e4d13861dcb?anonymousKey=cca399b6f23aeed32e3fba6876fc610f5ef53bc1) [RouterLib#1](#m-routerlib-1) |
| [RTF-UT-12](./specs/ratifier/unit.spec#L198-L209) (borrower limit-monotonicity — establishes RATE-1 directly) | `satisfiesRateLimitMonotoneInBorrowerLimit` | the borrower rate gate is monotone in the limit — a higher limit only loosens acceptance.<br>`limLo <= limHi => ( satisfies(false,u,a,limLo,pol,dur) => satisfies(false,u,a,limHi,pol,dur) )` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/cb669a975bc74282867b2a38630db50e?anonymousKey=439773a3f0aa545ee2251413f718b344b701aeb6) [PriceLib#7](#m-pricelib-7) |
| [RTF-UT-13](./specs/ratifier/unit.spec#L211-L221) (decomposition, lifts RTF-HL-05) | `netBuyerPriceMonotoneInFee` | the net buyer price is non-decreasing in the fee rate (a lender enter prices the offer up as the fee grows).<br>`feeLo <= feeHi => netBuyerPrice(p, sf, feeLo) <= netBuyerPrice(p, sf, feeHi)` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/e9900c8f7dce408db2671d1c2528c330?anonymousKey=90833464a3882fa359f3d4e33fe7368d4581521d) [CallbackLib#3](#m-callbacklib-3) [❌](https://prover.certora.com/output/52567/6386e7b709b74138912d9fc8ada48702?anonymousKey=6e2677d1162eeeb418a8a9809f4440a976f6c2aa) [RouterLib#2](#m-routerlib-2) |
| [RTF-UT-14](./specs/ratifier/unit.spec#L223-L234) (lender limit-monotonicity — establishes RATE-2 directly) | `satisfiesRateLimitMonotoneInLenderLimit` | the lender rate gate is monotone in the limit — a higher limit only tightens acceptance.<br>`limLo <= limHi => ( satisfies(true,u,a,limHi,pol,dur) => satisfies(true,u,a,limLo,pol,dur) )` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/edb6ed92a3174a89b8e82ac6d6df1e0b?anonymousKey=9401f4f1a7788b0be7abc18fd3ec2166554140aa) [PriceLib#4](#m-pricelib-4) |
| [RTF-UT-15](./specs/ratifier/unit.spec#L243-L257) | `isRatifiedReturnsCallbackSuccess` | isRatified returns the Midnight success token on every accepting (non-reverting) path - the producer side of the take() handshake (the midnight suite proves the consumer side against an untrusted-ratifier summary).<br>`!revert(isRatified) => return == keccak256("morpho.midnight.callbackSuccess")` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/02ffeb8d37c0414c929e2dd07ec02b9f?anonymousKey=361b5f298725fb03cc1cc5fe0422e1d6a9c4de4d) [MigrationRatifier#13](#m-migrationratifier-13) |
| [RTF-UT-16](./specs/ratifier/unit.spec#L259-L284) | `setFeeConfigWritesSlotAndLeavesOthers` | setFeeConfig stores exactly the addressed (callback, tenorMarketId) fee slot and leaves every other fee slot untouched.<br>`feeConfigs[cb][id]' == (recipient, rate) && (cb2,id2) != (cb,id) => feeConfigs[cb2][id2]' unchanged` | [✅](https://prover.certora.com/output/52567/da380e0b9d594fee8dc5a9311d79b95d?anonymousKey=f2cad79c63c02c9f5d34d1a5ea62758dd09c337d) | [❌](https://prover.certora.com/output/52567/576c483ecb144945a197768e10a8b991?anonymousKey=2350669db857ac65977f08dd67405af0574adc0a) [BaseMigrationRatifier#48](#m-basemigrationratifier-48) |

##### High-level (`ratifier/highlevel.spec`) — window/cadence & own-storage differentials, fee-slot isolation, rate-gate monotonicity

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [RTF-HL-01](./specs/ratifier/highlevel.spec#L6-L32) (ORCH-7) | `v1v2migrationsHaveNoRenewalWindowConstraint` | V1→V2 migrations (BBM, LVM) have no renewal window constraint.<br>`revert(isRatified \| renewalWindow=w1) == revert(isRatified \| renewalWindow=w2)` | [✅](https://prover.certora.com/output/52567/9ead3129674d41ac9c047c4188adcb4a?anonymousKey=d88645ac88b6529dc71823431d50ffd0d48e9ac7) | [❌](https://prover.certora.com/output/52567/5645638ecdba42a79601117170c96590?anonymousKey=48f7ee1f5ea39db71e7cbadd0aafd3e50b4a426d) [BaseMigrationRatifier#31](#m-basemigrationratifier-31) |
| [RTF-HL-02](./specs/ratifier/highlevel.spec#L34-L61) | `v2v1ExitsHaveNoRenewalCadenceConstraint` | V2→V1 exits (BMB, LMV) have no renewal cadence constraint.<br>`revert(isRatified \| renewalCadence=c1) == revert(isRatified \| renewalCadence=c2)` | [✅](https://prover.certora.com/output/52567/9ead3129674d41ac9c047c4188adcb4a?anonymousKey=d88645ac88b6529dc71823431d50ffd0d48e9ac7) | [❌](https://prover.certora.com/output/52567/ad2136a900a04ff6a98129ccf2705e15?anonymousKey=c61cd15d0e190239fafe2f5f41bf07fda716f60a) [BaseMigrationRatifier#1](#m-basemigrationratifier-1) |
| [RTF-HL-03](./specs/ratifier/highlevel.spec#L63-L88) (ORCH-14) | `feeMarketIdIgnoresCrossMarketSlot` | only the selected fee slot gates the verdict; any other market's slot is ignored.<br>`idX != feeMarketId && idX != 0 => revert(isRatified \| cfg[cb][idX]=A) == revert(... =B)` | [✅](https://prover.certora.com/output/52567/d0b8fd62f0b04e95ab45d3a172595dc1?anonymousKey=e5ec6ea5f5fa053f9cde610aaf912b0346d9a896) | [❌](https://prover.certora.com/output/52567/a7640198f8fc48b7b28f4ce7dd5d1054?anonymousKey=22f3e86fbaf892569a49e6adba5ab561e934f3ee) [BaseMigrationRatifier#41](#m-basemigrationratifier-41) |
| [RTF-HL-04E](./specs/ratifier/highlevel.spec#L90-L122) (decomposition bridge, RTF-HL-04) | `borrowerRateGateMatchesNetSellerThreshold` | the real borrower (BBM) rate gate reverts exactly when the reconstructed net-seller threshold fails — one real solve that RTF-HL-04 then lifts monotonically.<br>`revert(ratifyRate) <=> !satisfiesRateLimit(false, WAD, netSellerPrice(tickPrice, 0, feeRate), limit, policy, dur)` | [✅](https://prover.certora.com/output/52567/17232dcca2a24607a299de840c80eab7?anonymousKey=c7bcadca385e612d66e6aa07bfcefbadc502ee8b) | [❌](https://prover.certora.com/output/52567/f54402e08a1e409f9e7262183f7c0169?anonymousKey=141e0a079133e1afecccdea684d48a5b297a2b2f) [BaseMigrationRatifier#32](#m-basemigrationratifier-32) [❌](https://prover.certora.com/output/52567/3d2fd0a33e1642b29dded8bd1d78d153?anonymousKey=ec6c815d04701e43d42c119dc24ac85c87eeb71c) [BaseMigrationRatifier#33](#m-basemigrationratifier-33) |
| [RTF-HL-04](./specs/ratifier/highlevel.spec#L124-L165) (CB-RATE-1) | `higherFeeOnlyTightensBorrowerRateGate` | on a borrower enter (BBM, sell side) a larger fee only tightens the rate gate.<br>`feeRate_lo <= feeRate_hi  =>  ( revert(ratifyRate \| lo) => revert(ratifyRate \| hi) )` | [✅](https://prover.certora.com/output/52567/e1358c3d3e9e4457bc9d9ef455229714?anonymousKey=4cdd4f3a5ba338404a8a2fce00a5e7cb24aa6163) | [❌](https://prover.certora.com/output/52567/89fb620748dd41c7b8e29b1ea0567f63?anonymousKey=dffb590f4a93940f1f20dd8362df564f1b99dd60) [PriceLib#8](#m-pricelib-8) |
| [RTF-HL-05E](./specs/ratifier/highlevel.spec#L167-L201) (decomposition bridge, RTF-HL-05) | `lenderRateGateMatchesNetBuyerThreshold` | the real lender (LVM) rate gate reverts exactly when the reconstructed net-buyer threshold fails — one real solve that RTF-HL-05 then lifts monotonically.<br>`revert(ratifyRate) <=> !satisfiesRateLimit(true, WAD, netBuyerPrice(tickPrice, 0, feeRate), limit, policy, dur)` | [✅](https://prover.certora.com/output/52567/3df84a1897634fa0899188678a408725?anonymousKey=2c7fb12fece7e8c3c5dd48c66e000a28eb6ca052) | [❌](https://prover.certora.com/output/52567/f54402e08a1e409f9e7262183f7c0169?anonymousKey=141e0a079133e1afecccdea684d48a5b297a2b2f) [BaseMigrationRatifier#32](#m-basemigrationratifier-32) [❌](https://prover.certora.com/output/52567/3d2fd0a33e1642b29dded8bd1d78d153?anonymousKey=ec6c815d04701e43d42c119dc24ac85c87eeb71c) [BaseMigrationRatifier#33](#m-basemigrationratifier-33) |
| [RTF-HL-05](./specs/ratifier/highlevel.spec#L203-L247) (CB-RATE-2) | `higherFeeOnlyTightensLenderRateGate` | on a lender enter (LVM, buy side) a larger fee only tightens the rate gate.<br>`feeRate_lo <= feeRate_hi  =>  ( revert(ratifyRate \| lo) => revert(ratifyRate \| hi) )` | [✅](https://prover.certora.com/output/52567/505a3cf84d784df3946a8dddecfa81de?anonymousKey=ac9fc3e5f2d0a9963c47261500dd669120076f6a) | [❌](https://prover.certora.com/output/52567/7dc8e769158c49b5ad10e35825fc9ee7?anonymousKey=52dc64b64d5b6a4437d95dacffa29af175f96294) [PriceLib#9](#m-pricelib-9) |
| [RTF-HL-06](./specs/ratifier/highlevel.spec#L249-L274) | `isRatifiedReadsOnlyAddressedParams` | only the addressed userParams[offer.maker][offer.callback][src][tgt] tuple gates the verdict; other tuples cannot.<br>`(u2,cb2,s2,t2) != (offer.maker,offer.callback,iSrc,iTgt) => revert(isRatified \| set other tuple) == revert(...)` | [✅](https://prover.certora.com/output/52567/9ead3129674d41ac9c047c4188adcb4a?anonymousKey=d88645ac88b6529dc71823431d50ffd0d48e9ac7) | [❌](https://prover.certora.com/output/52567/496b7a0dd50a4e1c9ae7d2a080495518?anonymousKey=ebd50303d3660958a0dc7d17d1a62538775a29e5) [MigrationRatifier#12](#m-migrationratifier-12) |
| [RTF-HL-07](./specs/ratifier/highlevel.spec#L276-L289) | `getRatePrincipalForwardedFaithfully` | the rate policy is consulted for the right principal — offer.maker as the policy user.<br>`!revert(isRatified) => getRate user == offer.maker` | [✅](https://prover.certora.com/output/52567/9ead3129674d41ac9c047c4188adcb4a?anonymousKey=d88645ac88b6529dc71823431d50ffd0d48e9ac7) | [❌](https://prover.certora.com/output/52567/961fafbc84b1407d91751bde841ce41d?anonymousKey=4f255e9870f49416ad18ae41565f6185b57a529f) [BaseMigrationRatifier#42](#m-basemigrationratifier-42) |

##### Reachability (`ratifier/reachability.spec`) — `satisfy()` witnesses that post-maturity takes stay executable

| Property | Name | Description | Status | Mutations |
|----------|------|-------------|--------|----|
| [RTF-RC-01](./specs/ratifier/reachability.spec#L7-L27) (ORCH-5) | `postMaturityV2ToV2Executable` | a V2->V2 renewal taken at or after source maturity still has an accepting execution — post-maturity timing alone never blocks it (the renewal window is satisfied once now >= sourceMaturity). | [✅](https://prover.certora.com/output/52567/46fe0d086cae4264b3238cf477f1be8f?anonymousKey=452093c7b0c7e4cf516f27eafdd6d0eb8a7d00f5) | [❌](https://prover.certora.com/output/52567/808048ea08304f689edeb058b79e0b56?anonymousKey=ba593653d834f6bf4b4b148a8710683da316883f) [BaseMigrationRatifier#28](#m-basemigrationratifier-28) |
| [RTF-RC-02](./specs/ratifier/reachability.spec#L29-L48) (ORCH-6) | `postMaturityV2ToV1Executable` | a V2->V1 exit taken at or after source maturity still has an accepting execution — post-maturity the window check is satisfied (now>=sourceMaturity>=renewalPeriodStart); only target-maturity validation is skipped (V1 has no maturity). | [✅](https://prover.certora.com/output/52567/46fe0d086cae4264b3238cf477f1be8f?anonymousKey=452093c7b0c7e4cf516f27eafdd6d0eb8a7d00f5) | [❌](https://prover.certora.com/output/52567/17a53a2f766a4aa080d14279f7e04490?anonymousKey=02c90eda53928afa40eff3d40d6eca47c1a315a7) [BaseMigrationRatifier#29](#m-basemigrationratifier-29) |
| [RTF-RC-03](./specs/ratifier/reachability.spec#L50-L68) (RTF-RC-V1V2) | `entryV1ToV2Executable` | a V1->V2 enter (Blue/vault source, live Midnight target) has an accepting execution — completes the RC family (RC-01 V2->V2, RC-02 V2->V1, RC-03 V1->V2). | [✅](https://prover.certora.com/output/52567/46fe0d086cae4264b3238cf477f1be8f?anonymousKey=452093c7b0c7e4cf516f27eafdd6d0eb8a7d00f5) | [❌](https://prover.certora.com/output/52567/6b265e01015644a1a2a72f7493258ef0?anonymousKey=98765a7d533d58d83ead09f8f0852acf6649405f) [BaseMigrationRatifier#46](#m-basemigrationratifier-46) |

---

## Verification Results

139 properties — 90 across the nine callbacks + shared safety layer and 49 for the standalone Migration Ratifier: 120 verified, 19 timed out (4-hour SMT budget), 0 violated.

| Group | Verified | Timeout | Total |
|---|---|---|---|
| Shared Safety Rules (re-verified under each callback) | 5 | 5 | 10 |
| BorrowBlueToMidnightCallback (BBM) | 11 | 2 | 13 |
| BorrowMidnightToBlueCallback (BMB) | 8 | 3 | 11 |
| BorrowMidnightRenewalCallback (BMR) | 10 | 3 | 13 |
| LendVaultToMidnightCallback (LVM) | 5 | 2 | 7 |
| LendMidnightToVaultCallback (LMV) | 5 | 1 | 6 |
| LendMidnightRenewalCallback (LMR) | 7 | 1 | 8 |
| MidnightSupplyCollateralCallback (MSC) | 7 | 2 | 9 |
| MidnightSupplyVaultSharesCallback (MSV) | 11 | 0 | 11 |
| MidnightWithdrawVaultSharesCallback (MWV) | 2 | 0 | 2 |
| MigrationRatifier (standalone, 47 rules + 2 invariants) | 49 | 0 | 49 |
| **Total** | **120** | **19** | **139** |

A shared rule counts as timed out if any of its per-callback re-verifications hits the budget: 55 of 63 applicable matrix cells verify (CLB-09 times out in both of its setups).

<div style="page-break-before: always;"></div>

---

## Mutation Testing

**Mutation testing** injects deliberate one-line bugs into the verified `src/` contracts and re-runs the properties expected to catch them, measuring how tightly the proofs constrain the implementation. A property that flips to a counterexample **caught** the bug. The results below — each injected bug as a one-line diff and the properties that caught it — are self-contained. Status icons per the [legend](#verification-properties).

### Coverage by rule

Which rule caught which mutations (one rule can catch several). A **ˢ** marks a catch via the rule's satisfy-twin (the mutation reverts `take()`, so only the witness flags it).

| Rule (PROP) | Mutations |
|---|---|
| [`borrowCapacityUsageWithinCap`](./specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L34) (CB-SC-CAP-1) | ❌ [MidnightSupplyCollateralCallback#23](#m-midnightsupplycollateralcallback-23) |
| [`borrowerFeeBoundedByInterestShare`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L181) (CB-RATE-1) | ❌ [BorrowBlueToMidnightCallback#18](#m-borrowbluetomidnightcallback-18) ❌ [BorrowMidnightRenewalCallback#36](#m-borrowmidnightrenewalcallback-36) |
| [`borrowerRateGateMatchesNetSellerThreshold`](./specs/ratifier/highlevel.spec#L92) (BBM) | [❌](https://prover.certora.com/output/52567/f54402e08a1e409f9e7262183f7c0169?anonymousKey=141e0a079133e1afecccdea684d48a5b297a2b2f) [BaseMigrationRatifier#32](#m-basemigrationratifier-32) [❌](https://prover.certora.com/output/52567/3d2fd0a33e1642b29dded8bd1d78d153?anonymousKey=ec6c815d04701e43d42c119dc24ac85c87eeb71c) [BaseMigrationRatifier#33](#m-basemigrationratifier-33) |
| [`buyerTickFeePaidBoundedByUnits`](./specs/callbacks/callbacks.spec#L180) (CB-FEE-2) | ❌ [LendMidnightRenewalCallback#14](#m-lendmidnightrenewalcallback-14) |
| [`bystanderUntouched`](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L36) | ❌ [MidnightSupplyCollateralCallback#20](#m-midnightsupplycollateralcallback-20) ❌ [MidnightSupplyVaultSharesCallback#22](#m-midnightsupplyvaultsharescallback-22) |
| [`callbackFeeMustMatchEffectiveConfig`](./specs/ratifier/revert.spec#L188) (DEFAULT-2) | [❌](https://prover.certora.com/output/52567/201f21e0b1e34ec4a06870ab0c912caf?anonymousKey=5377985800bac8d9550af5a7f27888534d97c3ab) [BaseMigrationRatifier#11](#m-basemigrationratifier-11) [❌](https://prover.certora.com/output/52567/28c4c1e773f34b4185430acdf678c400?anonymousKey=60d1a8a30085d7c3b99283b76fb02521570cdc7f) [BaseMigrationRatifier#12](#m-basemigrationratifier-12) |
| [`callbackHoldsZeroAllowance`](./specs/callbacks/callbacks.spec#L7) (CB-DUST-1) | ❌ [MidnightWithdrawVaultSharesCallback#2](#m-midnightwithdrawvaultsharescallback-2) |
| [`callbackHoldsZeroAllowance__satisfy`](./specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L9) (CB-DUST-1) | ❌ [BorrowMidnightRenewalCallback#35](#m-borrowmidnightrenewalcallback-35)ˢ |
| [`callbackNeverHoldsTokens`](./specs/callbacks/callbacks.spec#L57) (CB-DUST-1) | ❌ [MidnightWithdrawVaultSharesCallback#6](#m-midnightwithdrawvaultsharescallback-6) |
| [`callbackNeverHoldsTokens__satisfy`](./specs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/many_satisfy.spec#L34) (CB-DUST-1) | ❌ [BorrowMidnightRenewalCallback#33](#m-borrowmidnightrenewalcallback-33)ˢ |
| [`callbackRevertsForNonMidnightCaller`](./specs/callbacks/callbacks.spec#L80) (CB-AUTH-1) | ❌ [BorrowBlueToMidnightCallback#1](#m-borrowbluetomidnightcallback-1) ❌ [MidnightSupplyCollateralCallback#1](#m-midnightsupplycollateralcallback-1) |
| [`callbackRevertsForSameSourceMarket`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L293) (CB-SAME-1) | ❌ [BorrowMidnightRenewalCallback#3](#m-borrowmidnightrenewalcallback-3) ❌ [LendMidnightRenewalCallback#24](#m-lendmidnightrenewalcallback-24) |
| [`callbackRevertsOnZeroAssetsOrUnits`](./specs/callbacks/callbacks.spec#L91) | ❌ [LendMidnightRenewalCallback#2](#m-lendmidnightrenewalcallback-2) ❌ [MidnightSupplyCollateralCallback#2](#m-midnightsupplycollateralcallback-2) |
| [`clearParamsZeroesTupleAndLeavesOthers`](./specs/ratifier/unit.spec#L56) (REG-3) | [❌](https://prover.certora.com/output/52567/083f195bf7634d0ca780a1fcc506a262?anonymousKey=97013cc2674fa074a07f8754de8dde4d06146645) [MigrationRatifier#3](#m-migrationratifier-3) |
| [`clearingOldDebtAlsoEmptiesOldCollateral`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L75) (CB-FINAL-2) | ❌ [BorrowBlueToMidnightCallback#3](#m-borrowbluetomidnightcallback-3) |
| [`collateralLengthMismatchReverts`](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L65) | ❌ [MidnightSupplyCollateralCallback#4](#m-midnightsupplycollateralcallback-4) |
| [`computeDurationPerCallback`](./specs/ratifier/unit.spec#L162) (ORCH-13) | [❌](https://prover.certora.com/output/52567/d814f6d924ef457c941e00a2925b1100?anonymousKey=0897824bea3e4042776daa5ca2fb590315a15c49) [BaseMigrationRatifier#21](#m-basemigrationratifier-21) |
| [`continuousFeeCapReverts`](./specs/ratifier/revert.spec#L356) (LVM, LMR) | [❌](https://prover.certora.com/output/52567/ec80357f6ef04c8f9ce9a9cdd2fd8a96?anonymousKey=b9cb6561aa24adba765d225eb78b99f6ce430209) [BaseMigrationRatifier#47](#m-basemigrationratifier-47) |
| [`effectiveRateSelectsTighterBound`](./specs/ratifier/unit.spec#L123) (PRICE-3) | [❌](https://prover.certora.com/output/52567/367e91364af64ab982e032e4aee9793f?anonymousKey=ec161b6884775a84eca54c0f4a99d6a596539433) [PriceLib#3](#m-pricelib-3) |
| [`entryV1ToV2Executable`](./specs/ratifier/reachability.spec#L52) | [❌](https://prover.certora.com/output/52567/6b265e01015644a1a2a72f7493258ef0?anonymousKey=98765a7d533d58d83ead09f8f0852acf6649405f) [BaseMigrationRatifier#46](#m-basemigrationratifier-46) |
| [`extraPullMatchesPercentFormula`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L102) | ❌ [MidnightSupplyVaultSharesCallback#21](#m-midnightsupplyvaultsharescallback-21) |
| [`feeConfigChangeRequiresOwner`](./specs/ratifier/access_control.spec#L8) | [❌](https://prover.certora.com/output/52567/76df59a998eb40299c21388232522fdb?anonymousKey=88f03714e6f04a13b1921e99c0165dfd9f885cff) [BaseMigrationRatifier#2](#m-basemigrationratifier-2) |
| [`feeMarketIdIgnoresCrossMarketSlot`](./specs/ratifier/highlevel.spec#L65) (ORCH-14) | [❌](https://prover.certora.com/output/52567/a7640198f8fc48b7b28f4ce7dd5d1054?anonymousKey=22f3e86fbaf892569a49e6adba5ab561e934f3ee) [BaseMigrationRatifier#41](#m-basemigrationratifier-41) |
| [`feeRateNeverExceedsCallbackCap`](./specs/ratifier/valid_state.spec#L7) (ORCH-1) | [❌](https://prover.certora.com/output/52567/2cd25c093c474a90a84b46198bc23415?anonymousKey=a60bdc860a1dd664c801b995a238731ea6ae01c8) [BaseMigrationRatifier#39](#m-basemigrationratifier-39) |
| [`feeRecipientNeverLosesTokens__satisfy`](./specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L72) | ❌ [BorrowMidnightRenewalCallback#35](#m-borrowmidnightrenewalcallback-35)ˢ |
| [`fullCollateralMigrationClearsAllOldDebt__satisfy`](./specs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/many_satisfy.spec#L220) (CB-CLOSE-2) | ❌ [BorrowBlueToMidnightCallback#12](#m-borrowbluetomidnightcallback-12)ˢ |
| [`getEffectiveFeeConfigMarketOverridesActionDefault`](./specs/ratifier/unit.spec#L8) (ORCH-3) | [❌](https://prover.certora.com/output/52567/d18899aadfcb49f79996de8b37b9ede1?anonymousKey=e2ae2f2ecbb996c771dc5b197acf9912070e6aa0) [BaseMigrationRatifier#18](#m-basemigrationratifier-18) |
| [`getRatePrincipalForwardedFaithfully`](./specs/ratifier/highlevel.spec#L279) | [❌](https://prover.certora.com/output/52567/961fafbc84b1407d91751bde841ce41d?anonymousKey=4f255e9870f49416ad18ae41565f6185b57a529f) [BaseMigrationRatifier#42](#m-basemigrationratifier-42) |
| [`higherFeeOnlyTightensBorrowerRateGate`](./specs/ratifier/highlevel.spec#L126) | [❌](https://prover.certora.com/output/52567/89fb620748dd41c7b8e29b1ea0567f63?anonymousKey=dffb590f4a93940f1f20dd8362df564f1b99dd60) [PriceLib#8](#m-pricelib-8) |
| [`higherFeeOnlyTightensLenderRateGate`](./specs/ratifier/highlevel.spec#L205) | [❌](https://prover.certora.com/output/52567/7dc8e769158c49b5ad10e35825fc9ee7?anonymousKey=52dc64b64d5b6a4437d95dacffa29af175f96294) [PriceLib#9](#m-pricelib-9) |
| [`invalidRatifierDataLengthReverts`](./specs/ratifier/revert.spec#L8) | [❌](https://prover.certora.com/output/52567/7ef137b75cda4408b3af6cf0d969acb3?anonymousKey=45a9b0082422c52a440e4ad075ec6f0dc96615b0) [MigrationRatifier#9](#m-migrationratifier-9) |
| [`isRatifiedReadsOnlyAddressedParams`](./specs/ratifier/highlevel.spec#L252) | [❌](https://prover.certora.com/output/52567/496b7a0dd50a4e1c9ae7d2a080495518?anonymousKey=ebd50303d3660958a0dc7d17d1a62538775a29e5) [MigrationRatifier#12](#m-migrationratifier-12) |
| [`isRatifiedReturnsCallbackSuccess`](./specs/ratifier/unit.spec#L247) | [❌](https://prover.certora.com/output/52567/02ffeb8d37c0414c929e2dd07ec02b9f?anonymousKey=361b5f298725fb03cc1cc5fe0422e1d6a9c4de4d) [MigrationRatifier#13](#m-migrationratifier-13) |
| [`lenderFeeBoundedByInterestShare`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L98) (CB-RATE-2) | ❌ [LendVaultToMidnightCallback#11](#m-lendvaulttomidnightcallback-11) |
| [`lenderRateGateMatchesNetBuyerThreshold`](./specs/ratifier/highlevel.spec#L169) (LVM) | [❌](https://prover.certora.com/output/52567/f54402e08a1e409f9e7262183f7c0169?anonymousKey=141e0a079133e1afecccdea684d48a5b297a2b2f) [BaseMigrationRatifier#32](#m-basemigrationratifier-32) [❌](https://prover.certora.com/output/52567/3d2fd0a33e1642b29dded8bd1d78d153?anonymousKey=ec6c815d04701e43d42c119dc24ac85c87eeb71c) [BaseMigrationRatifier#33](#m-basemigrationratifier-33) |
| [`makerReceiverMustBePinned`](./specs/ratifier/revert.spec#L23) | [❌](https://prover.certora.com/output/52567/32202d6cf9154da79448d2c988576493?anonymousKey=940b953caa09f948f490bc6f6b9a7956de2a4259) [MigrationRatifier#10](#m-migrationratifier-10) |
| [`maxBorrowCapacityUsageFillReachable`](./specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L63) | ❌ [MidnightSupplyCollateralCallback#13](#m-midnightsupplycollateralcallback-13) |
| [`maxFeeRateZeroOnV2ToV1Exits`](./specs/ratifier/unit.spec#L152) (ORCH-4) | [❌](https://prover.certora.com/output/52567/b7b3b7426a0147669c1cb6fc8e9a47eb?anonymousKey=b6f1ecbe5c617fc47b188d147c7afb424d6f7984) [BaseMigrationRatifier#20](#m-basemigrationratifier-20) |
| [`migrationCanFullyCloseOldPosition`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L158) (CB-CLOSE-1) | ❌ [BorrowBlueToMidnightCallback#21](#m-borrowbluetomidnightcallback-21) ❌ [BorrowMidnightToBlueCallback#10](#m-borrowmidnighttobluecallback-10) |
| [`migrationCanMoveCollateralBlueToMidnight`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L137) | ❌ [BorrowBlueToMidnightCallback#2](#m-borrowbluetomidnightcallback-2) |
| [`migrationCanMoveCollateralMidnightToBlue`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L154) | ❌ [BorrowMidnightToBlueCallback#9](#m-borrowmidnighttobluecallback-9) |
| [`migrationCanOpenNewBlueDebt`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L136) | ❌ [BorrowMidnightToBlueCallback#8](#m-borrowmidnighttobluecallback-8) |
| [`migrationCannotDepositMoreCollateralThanWithdrawn`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L93) (CB-SRC-1) | ❌ [BorrowMidnightToBlueCallback#24](#m-borrowmidnighttobluecallback-24) |
| [`migrationConservesMigratedCollateral`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L115) (CB-DIR-1) | ❌ [BorrowBlueToMidnightCallback#4](#m-borrowbluetomidnightcallback-4) |
| [`migrationFinalFillTransfersAllOldMidnightCollateral`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L116) (CB-FINAL-3) | ❌ [BorrowMidnightToBlueCallback#25](#m-borrowmidnighttobluecallback-25) |
| [`migrationGroupNamespaceEnforced`](./specs/ratifier/revert.spec#L42) | [❌](https://prover.certora.com/output/52567/e6bda177f7d3491aa2324f16513f60d8?anonymousKey=71fedf9a7bb18455f150ba0eb38648c34b46ede5) [MigrationRatifier#11](#m-migrationratifier-11) |
| [`migrationOnlyAddsNewBlueCollateral`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L74) (CB-DIR-1) | ❌ [BorrowMidnightToBlueCallback#26](#m-borrowmidnighttobluecallback-26) |
| [`migrationOnlyAddsNewMidnightCollateral`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L96) (CB-DIR-1) | ❌ [BorrowBlueToMidnightCallback#9](#m-borrowbluetomidnightcallback-9) |
| [`migrationOnlyOpensNewBlueDebt`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L56) (CB-DIR-1) | ❌ [BorrowMidnightToBlueCallback#27](#m-borrowmidnighttobluecallback-27) |
| [`migrationOnlyReducesOldBlueDebt`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L15) (CB-V1-REP-1) | ❌ [BorrowBlueToMidnightCallback#15](#m-borrowbluetomidnightcallback-15) |
| [`migrationOnlyWithdrawsOldBlueCollateral`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L33) (CB-DIR-1) | ❌ [BorrowBlueToMidnightCallback#16](#m-borrowbluetomidnightcallback-16) |
| [`migrationOnlyWithdrawsOldMidnightCollateral`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L15) (CB-DIR-1) | ❌ [BorrowMidnightToBlueCallback#20](#m-borrowmidnighttobluecallback-20) |
| [`migrationReducesOldDebtOnAtMostOneMarket__satisfy`](./specs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/many_satisfy.spec#L115) (CB-DIR-1) | ❌ [BorrowBlueToMidnightCallback#20](#m-borrowbluetomidnightcallback-20)ˢ ❌ [BorrowMidnightToBlueCallback#29](#m-borrowmidnighttobluecallback-29)ˢ |
| [`netBuyerPriceMonotoneInFee`](./specs/ratifier/unit.spec#L213) | [❌](https://prover.certora.com/output/52567/e9900c8f7dce408db2671d1c2528c330?anonymousKey=90833464a3882fa359f3d4e33fe7368d4581521d) [CallbackLib#3](#m-callbacklib-3) [❌](https://prover.certora.com/output/52567/6386e7b709b74138912d9fc8ada48702?anonymousKey=6e2677d1162eeeb418a8a9809f4440a976f6c2aa) [RouterLib#2](#m-routerlib-2) |
| [`netSellerPriceMonotoneInFee`](./specs/ratifier/unit.spec#L188) | [❌](https://prover.certora.com/output/52567/e9900c8f7dce408db2671d1c2528c330?anonymousKey=90833464a3882fa359f3d4e33fe7368d4581521d) [CallbackLib#3](#m-callbacklib-3) [❌](https://prover.certora.com/output/52567/589fc5e7943e461aa67b0e4d13861dcb?anonymousKey=cca399b6f23aeed32e3fba6876fc610f5ef53bc1) [RouterLib#1](#m-routerlib-1) |
| [`noExtraPullWhenPercentZero`](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L65) | ❌ [MidnightSupplyVaultSharesCallback#13](#m-midnightsupplyvaultsharescallback-13) |
| [`nonZeroFeeRateImpliesRecipient`](./specs/ratifier/valid_state.spec#L15) (ORCH-2) | [❌](https://prover.certora.com/output/52567/8ff0b8d530ff4caea26003df0c6aa8c4?anonymousKey=fff31534089beb62ca9b3d2b02988c8524ab53cf) [BaseMigrationRatifier#40](#m-basemigrationratifier-40) |
| [`offerSellerAssetsZeroReverts`](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L79) | ❌ [MidnightSupplyCollateralCallback#14](#m-midnightsupplycollateralcallback-14) |
| [`oldMidnightDebtAndNewBlueDebtMoveTogether`](./specs/callbacks/BorrowMidnightToBlueCallback/one.spec#L9) (CB-DIR-1) | ❌ [BorrowMidnightToBlueCallback#30](#m-borrowmidnighttobluecallback-30) |
| [`onlyVaultSlotReceivesSupply`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L7) | ❌ [MidnightSupplyVaultSharesCallback#14](#m-midnightsupplyvaultsharescallback-14) |
| [`percentageFeeNeverExceedsAssets`](./specs/callbacks/callbacks.spec#L139) (CB-FEE-3) | ❌ [LendMidnightToVaultCallback#10](#m-lendmidnighttovaultcallback-10) |
| [`percentageFeeRateAboveCapReverts`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L197) | ❌ [BorrowMidnightToBlueCallback#18](#m-borrowmidnighttobluecallback-18) |
| [`positiveFeeIsPayable`](./specs/callbacks/callbacks.spec#L201) | ❌ [LendMidnightRenewalCallback#8](#m-lendmidnightrenewalcallback-8) |
| [`postMaturityV2ToV1Executable`](./specs/ratifier/reachability.spec#L31) (ORCH-6) | [❌](https://prover.certora.com/output/52567/17a53a2f766a4aa080d14279f7e04490?anonymousKey=02c90eda53928afa40eff3d40d6eca47c1a315a7) [BaseMigrationRatifier#29](#m-basemigrationratifier-29) |
| [`postMaturityV2ToV2Executable`](./specs/ratifier/reachability.spec#L9) (ORCH-5) | [❌](https://prover.certora.com/output/52567/808048ea08304f689edeb058b79e0b56?anonymousKey=ba593653d834f6bf4b4b148a8710683da316883f) [BaseMigrationRatifier#28](#m-basemigrationratifier-28) |
| [`priceFollowsZeroCouponFormula`](./specs/ratifier/unit.spec#L98) (PRICE-1) | [❌](https://prover.certora.com/output/52567/5b62b96cee994b09a7533863b8137b7e?anonymousKey=1263c5f3df6a931c66155de9c25891f73a7955c9) [PriceLib#1](#m-pricelib-1) [❌](https://prover.certora.com/output/52567/3cff95f3c9b149ae9722325495d721db?anonymousKey=f602d9e75e3fb2e9c66026017f7281548a4c4a8f) [PriceLib#2](#m-pricelib-2) |
| [`priceRoundsInProtectedUserFavor`](./specs/ratifier/unit.spec#L115) (PRICE-2) | [❌](https://prover.certora.com/output/52567/5b62b96cee994b09a7533863b8137b7e?anonymousKey=1263c5f3df6a931c66155de9c25891f73a7955c9) [PriceLib#1](#m-pricelib-1) |
| [`proRataUpperBound`](./specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L8) | ❌ [MidnightSupplyCollateralCallback#18](#m-midnightsupplycollateralcallback-18) |
| [`ratifierDataMustMatchCallbackMarkets`](./specs/ratifier/revert.spec#L168) (DEFAULT-3) | [❌](https://prover.certora.com/output/52567/1c8cac9468f74900bf5711aee5815938?anonymousKey=ad2166a5990d588b5d553d2df7f8ceb78c770e3d) [MigrationRatifier#5](#m-migrationratifier-5) |
| [`receiverIsCallbackReverts`](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L93) | ❌ [MidnightSupplyCollateralCallback#10](#m-midnightsupplycollateralcallback-10) |
| [`receiverNotCallbackReverts`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L272) | ❌ [BorrowBlueToMidnightCallback#22](#m-borrowbluetomidnightcallback-22) ❌ [BorrowMidnightRenewalCallback#13](#m-borrowmidnightrenewalcallback-13) ❌ [LendMidnightToVaultCallback#11](#m-lendmidnighttovaultcallback-11) ❌ [MidnightSupplyVaultSharesCallback#10](#m-midnightsupplyvaultsharescallback-10) |
| [`renewalAddsCreditOnAtMostOneMarket__satisfy`](./specs/callbacks/LendMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L105) (CB-DIR-1) | ❌ [LendMidnightRenewalCallback#21](#m-lendmidnightrenewalcallback-21)ˢ |
| [`renewalAddsDebtOnAtMostOneMarket__satisfy`](./specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L122) (CB-DIR-1) | ❌ [BorrowMidnightRenewalCallback#34](#m-borrowmidnightrenewalcallback-34)ˢ |
| [`renewalCallbackNeverPullsExternalLoanToken`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L111) (CB-SRC-1) | ❌ [BorrowMidnightRenewalCallback#25](#m-borrowmidnightrenewalcallback-25) ❌ [LendMidnightRenewalCallback#23](#m-lendmidnightrenewalcallback-23) |
| [`renewalCanFullyCloseOldCredit`](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L112) (CB-CLOSE-1) | ❌ [LendMidnightRenewalCallback#16](#m-lendmidnightrenewalcallback-16) |
| [`renewalCanFullyCloseOldPosition`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L200) (CB-CLOSE-1) | ❌ [CollateralTransferLib#1](#m-collateraltransferlib-1) |
| [`renewalCanMigrateCollateralBetweenMarkets`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L178) | ❌ [CollateralTransferLib#4](#m-collateraltransferlib-4) |
| [`renewalCanMoveCreditWithPositiveFee`](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L135) | ❌ [LendMidnightRenewalCallback#17](#m-lendmidnightrenewalcallback-17) |
| [`renewalCanMoveDebtBetweenMarkets`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L157) | ❌ [BorrowMidnightRenewalCallback#1](#m-borrowmidnightrenewalcallback-1) ❌ [BorrowMidnightRenewalCallback#8](#m-borrowmidnightrenewalcallback-8) |
| [`renewalCannotAddCollateralWhenReducingDebt`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L67) (CB-DIR-1) | ❌ [BorrowMidnightRenewalCallback#23](#m-borrowmidnightrenewalcallback-23) |
| [`renewalCannotMoveMoreCollateralThanWithdrawn`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L131) (CB-FINAL-4) | ❌ [CollateralTransferLib#3](#m-collateraltransferlib-3) |
| [`renewalCannotRemoveCollateralWhenOpeningDebt`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L89) (CB-DIR-1) | ❌ [BorrowMidnightRenewalCallback#23](#m-borrowmidnightrenewalcallback-23) |
| [`renewalCannotRemoveCollateralWhenOpeningDebt__satisfy`](./specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L158) (CB-DIR-1) | ❌ [BorrowMidnightRenewalCallback#31](#m-borrowmidnightrenewalcallback-31)ˢ |
| [`renewalNeverTouchesUnrelatedLenderCredit__satisfy`](./specs/callbacks/LendMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L164) (CB-DIR-1) | ❌ [LendMidnightRenewalCallback#25](#m-lendmidnightrenewalcallback-25)ˢ |
| [`renewalReducesCreditOnAtMostOneMarket`](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L39) (CB-DIR-1) | ❌ [LendMidnightRenewalCallback#19](#m-lendmidnightrenewalcallback-19) |
| [`renewalReducesDebtOnAtMostOneMarket`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L21) (CB-DIR-1) | ❌ [BorrowMidnightRenewalCallback#24](#m-borrowmidnightrenewalcallback-24) |
| [`satisfiesRateLimitComparisonDirection`](./specs/ratifier/unit.spec#L133) (PRICE-4) | [❌](https://prover.certora.com/output/52567/edb6ed92a3174a89b8e82ac6d6df1e0b?anonymousKey=9401f4f1a7788b0be7abc18fd3ec2166554140aa) [PriceLib#4](#m-pricelib-4) [❌](https://prover.certora.com/output/52567/cb669a975bc74282867b2a38630db50e?anonymousKey=439773a3f0aa545ee2251413f718b344b701aeb6) [PriceLib#7](#m-pricelib-7) |
| [`satisfiesRateLimitMonotoneInBorrowerLimit`](./specs/ratifier/unit.spec#L200) | [❌](https://prover.certora.com/output/52567/cb669a975bc74282867b2a38630db50e?anonymousKey=439773a3f0aa545ee2251413f718b344b701aeb6) [PriceLib#7](#m-pricelib-7) |
| [`satisfiesRateLimitMonotoneInLenderLimit`](./specs/ratifier/unit.spec#L225) | [❌](https://prover.certora.com/output/52567/edb6ed92a3174a89b8e82ac6d6df1e0b?anonymousKey=9401f4f1a7788b0be7abc18fd3ec2166554140aa) [PriceLib#4](#m-pricelib-4) |
| [`sellerTickFeeNeverExceedsAssets`](./specs/callbacks/callbacks.spec#L160) (CB-FEE-1) | ❌ [BorrowMidnightRenewalCallback#22](#m-borrowmidnightrenewalcallback-22) |
| [`setFeeConfigWritesSlotAndLeavesOthers`](./specs/ratifier/unit.spec#L262) | [❌](https://prover.certora.com/output/52567/576c483ecb144945a197768e10a8b991?anonymousKey=2350669db857ac65977f08dd67405af0574adc0a) [BaseMigrationRatifier#48](#m-basemigrationratifier-48) |
| [`setParamsWritesTupleAndLeavesOthers`](./specs/ratifier/unit.spec#L28) (ORCH-15, REG-2) | [❌](https://prover.certora.com/output/52567/438dd54ed58d4ee1909c036c5cc878e8?anonymousKey=7d997b536668f99fba68328ddb0ad04b90a215d9) [MigrationRatifier#2](#m-migrationratifier-2) |
| [`sourceLoanTokenMismatchReverts`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L286) | ❌ [BorrowBlueToMidnightCallback#14](#m-borrowbluetomidnightcallback-14) |
| [`suppliedSharesMatchMintedShares`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L33) | ❌ [MidnightSupplyVaultSharesCallback#11](#m-midnightsupplyvaultsharescallback-11) |
| [`supplyCanRaiseCollateral`](./specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L88) | ❌ [MidnightSupplyCollateralCallback#9](#m-midnightsupplycollateralcallback-9) |
| [`supplyCanRaiseVaultCollateral`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79) | ❌ [MidnightSupplyVaultSharesCallback#8](#m-midnightsupplyvaultsharescallback-8) ❌ [MidnightSupplyVaultSharesCallback#9](#m-midnightsupplyvaultsharescallback-9) ❌ [MidnightSupplyVaultSharesCallback#18](#m-midnightsupplyvaultsharescallback-18) ❌ [MidnightSupplyVaultSharesCallback#20](#m-midnightsupplyvaultsharescallback-20) |
| [`supplyMonotoneCollateral`](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L14) | ❌ [MidnightSupplyCollateralCallback#21](#m-midnightsupplycollateralcallback-21) ❌ [MidnightSupplyVaultSharesCallback#12](#m-midnightsupplyvaultsharescallback-12) |
| [`takeCanDropCollateralOnNarrowedMarket`](./specs/callbacks/MidnightWithdrawVaultSharesCallback/many.spec#L14) (CB-VAULT-WD-1) | ❌ [MidnightWithdrawVaultSharesCallback#5](#m-midnightwithdrawvaultsharescallback-5) |
| [`takeLeavesVaultShareBalanceUnchanged`](./specs/callbacks/MidnightWithdrawVaultSharesCallback/many.spec#L32) (CB-VAULT-WD-1) | ❌ [MidnightWithdrawVaultSharesCallback#1](#m-midnightwithdrawvaultsharescallback-1) |
| [`takeLeavesVaultShareBalanceUnchanged__satisfy`](./specs/callbacks/MidnightWithdrawVaultSharesCallback/debug_satisfy/many_satisfy.spec#L74) (CB-VAULT-WD-1) | ❌ [MidnightWithdrawVaultSharesCallback#8](#m-midnightwithdrawvaultsharescallback-8)ˢ |
| [`targetMaturityMustExceedSource`](./specs/ratifier/revert.spec#L98) (ORCH-9) | [❌](https://prover.certora.com/output/52567/5f1878ea4e894c28b3754bb2399934aa?anonymousKey=435b2d1761fd125df8eaf15db23055e206c25af4) [BaseMigrationRatifier#13](#m-basemigrationratifier-13) |
| [`targetMaturityOnCadenceGrid`](./specs/ratifier/revert.spec#L142) (ORCH-11) | [❌](https://prover.certora.com/output/52567/882c53afa7064efc90d991a7d90ce800?anonymousKey=f8cbbf73e1030c8604d073918b5c78e2a8b5aa9c) [BaseMigrationRatifier#15](#m-basemigrationratifier-15) |
| [`targetMaturityWithinDurationBand`](./specs/ratifier/revert.spec#L115) (ORCH-10) | [❌](https://prover.certora.com/output/52567/ca7823f7d1ea4146b69743e7e13d7a80?anonymousKey=8c64420ac22d9b18d7105924dff79cb7fbdbf169) [BaseMigrationRatifier#44](#m-basemigrationratifier-44) |
| [`targetMaturityWithinDurationBand_boundaryAccepted`](./specs/ratifier/revert.spec#L253) (ORCH-10) | [❌](https://prover.certora.com/output/52567/d95268dfa67c46d4b5c81957588e1529?anonymousKey=50fb0b053bc02ef768df6f3f8b40999bc8bb4793) [BaseMigrationRatifier#22](#m-basemigrationratifier-22) |
| [`thirdPartyBalanceUnchanged__satisfy`](./specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L27) | ❌ [BorrowMidnightRenewalCallback#35](#m-borrowmidnightrenewalcallback-35)ˢ |
| [`tickFeeVanishesAtPar`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L141) (CB-FEE-4) | ❌ [CallbackLib#1](#m-callbacklib-1) ❌ [CallbackLib#4](#m-callbacklib-4) ❌ [CallbackLib#5](#m-callbacklib-5) ❌ [CallbackLib#6](#m-callbacklib-6) |
| [`tickMustMatchOffer`](./specs/ratifier/revert.spec#L80) (DEFAULT-4) | [❌](https://prover.certora.com/output/52567/b84b34d4225248b6966d177d8459c16d?anonymousKey=d0faed4bfd14b2d9009a8860ce201440476d4e85) [BaseMigrationRatifier#25](#m-basemigrationratifier-25) |
| [`unauthorizedCallbackReverts`](./specs/ratifier/revert.spec#L339) | [❌](https://prover.certora.com/output/52567/6192d914087e486a8eccd157766bce54?anonymousKey=ff9422393a79f6e4a4c119f30769dd09f5340cb3) [BaseMigrationRatifier#43](#m-basemigrationratifier-43) |
| [`unconfiguredTupleAlwaysReverts`](./specs/ratifier/revert.spec#L59) | [❌](https://prover.certora.com/output/52567/ed2ccca4688e4a50b224561d6d6f0c0d?anonymousKey=7549839549a37703eaef7183b50174fffb2a5887) [BaseMigrationRatifier#10](#m-basemigrationratifier-10) |
| [`userIsBuyMatchesBuySideCallbacks`](./specs/ratifier/unit.spec#L82) (DEFAULT-1, RATE-3) | [❌](https://prover.certora.com/output/52567/7dcada76d4674d37aa783beb0e5d1d48?anonymousKey=de2504767e12349a39ed769a25d131d865836003) [BaseMigrationRatifier#19](#m-basemigrationratifier-19) |
| [`userParamsChangeRequiresAuthorization`](./specs/ratifier/access_control.spec#L26) (REG-1) | [❌](https://prover.certora.com/output/52567/97f849a9e2ce491494beecfd2b65f8e2?anonymousKey=27df4b54c6e1e82a196fa8b3fea47d7613476328) [MigrationRatifier#8](#m-migrationratifier-8) |
| [`v1v2migrationsHaveNoRenewalWindowConstraint`](./specs/ratifier/highlevel.spec#L8) (ORCH-7) | [❌](https://prover.certora.com/output/52567/5645638ecdba42a79601117170c96590?anonymousKey=48f7ee1f5ea39db71e7cbadd0aafd3e50b4a426d) [BaseMigrationRatifier#31](#m-basemigrationratifier-31) |
| [`v2SourceWindowEnforcedBeforeOpen`](./specs/ratifier/revert.spec#L208) (ORCH-8) | [❌](https://prover.certora.com/output/52567/3296f8b884354d779c8e3a10c649cc34?anonymousKey=2868dfb80a6375b28cbfccadcdc3ac451124dc79) [BaseMigrationRatifier#45](#m-basemigrationratifier-45) |
| [`v2SourceWindowEnforcedBeforeOpen_boundaryAccepted`](./specs/ratifier/revert.spec#L283) (ORCH-8) | [❌](https://prover.certora.com/output/52567/7808468866dd423bb3a491b13a0e2540?anonymousKey=9e99aa8d91b4456e067b35a68c6559519672a1f5) [BaseMigrationRatifier#23](#m-basemigrationratifier-23) |
| [`v2v1ExitsHaveNoRenewalCadenceConstraint`](./specs/ratifier/highlevel.spec#L36) (BMB, LMV) | [❌](https://prover.certora.com/output/52567/ad2136a900a04ff6a98129ccf2705e15?anonymousKey=c61cd15d0e190239fafe2f5f41bf07fda716f60a) [BaseMigrationRatifier#1](#m-basemigrationratifier-1) |
| [`variableSourceWindowEnforced`](./specs/ratifier/revert.spec#L231) (ORCH-7) | [❌](https://prover.certora.com/output/52567/2cb4222582eb4b05a6c231f40181c640?anonymousKey=7801ad00b67412b9f9c2aa7789e8f0203d6321cd) [BaseMigrationRatifier#36](#m-basemigrationratifier-36) |
| [`variableSourceWindowEnforced_boundaryAccepted`](./specs/ratifier/revert.spec#L311) (ORCH-7) | [❌](https://prover.certora.com/output/52567/c29c49e1b6b44abcb27fb00415b1e79f?anonymousKey=7c28338e7ee85f03f9d8da0bb4a5b3f2a89057c2) [BaseMigrationRatifier#24](#m-basemigrationratifier-24) |
| [`vaultAssetMismatchReverts`](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L118) | ❌ [LendMidnightToVaultCallback#3](#m-lendmidnighttovaultcallback-3) ❌ [LendVaultToMidnightCallback#4](#m-lendvaulttomidnightcallback-4) ❌ [MidnightSupplyVaultSharesCallback#4](#m-midnightsupplyvaultsharescallback-4) |
| [`vaultExitCanFullyCloseCredit`](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L85) (CB-CLOSE-1) | ❌ [LendMidnightToVaultCallback#7](#m-lendmidnighttovaultcallback-7) |
| [`vaultExitConservesMidnightBalanceMinusFee`](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L17) (CB-SRC-1) | ❌ [LendMidnightToVaultCallback#20](#m-lendmidnighttovaultcallback-20) |
| [`vaultExitLeavesCollateralUnchanged`](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L42) | ❌ [LendMidnightToVaultCallback#21](#m-lendmidnighttovaultcallback-21) |
| [`vaultExitNeverTouchesUnrelatedUser`](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L61) (CB-DIR-1) | ❌ [LendMidnightToVaultCallback#13](#m-lendmidnighttovaultcallback-13) |
| [`vaultFundedLendCanRaiseCredit`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L55) | ❌ [LendVaultToMidnightCallback#5](#m-lendvaulttomidnightcallback-5) |
| [`vaultFundedLendLeavesCollateralUnchanged`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L36) | ❌ [LendVaultToMidnightCallback#7](#m-lendvaulttomidnightcallback-7) |
| [`vaultFundedLendNeverTouchesUnrelatedUser`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L73) (CB-DIR-1) | ❌ [LendVaultToMidnightCallback#12](#m-lendvaulttomidnightcallback-12) |
| [`vaultFundedLendOnlyMovesLoanToken`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L16) (CB-SRC-1) | ❌ [LendVaultToMidnightCallback#9](#m-lendvaulttomidnightcallback-9) |
| [`vaultNotAtIndexReverts`](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L104) | ❌ [MidnightSupplyVaultSharesCallback#5](#m-midnightsupplyvaultsharescallback-5) |
| [`vaultShareBeneficiaryIsSeller`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L59) | ❌ [MidnightSupplyVaultSharesCallback#15](#m-midnightsupplyvaultsharescallback-15) |

Each mutation below shows the one-line diff it injects and two copy-paste commands: the rule on clean `src/` (proves) and the same rule with the mutant applied via `certora/mutations/run_mutation.sh` (**VIOLATED** = mutant caught; the script restores `src/` afterwards). For the heaviest rules the commands use a perf-overlay conf (same rule, footprint-stubbed harness — see [Methodology](#verification-process)); the verdict is unaffected.

#### `BaseMigrationRatifier` — `src/ratifiers/BaseMigrationRatifier.sol`

<a id="m-basemigrationratifier-1"></a>
##### [❌](https://prover.certora.com/output/52567/ad2136a900a04ff6a98129ccf2705e15?anonymousKey=c61cd15d0e190239fafe2f5f41bf07fda716f60a) BaseMigrationRatifier #1 — _ratifyWindow guard ==0 -> !=0

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/1.sol`](./mutations/BaseMigrationRatifier/1.sol)
- **Caught by:** [`v2v1ExitsHaveNoRenewalCadenceConstraint`](./specs/ratifier/highlevel.spec#L36) (BMB, LMV)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule v2v1ExitsHaveNoRenewalCadenceConstraint`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 1`

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
##### [❌](https://prover.certora.com/output/52567/76df59a998eb40299c21388232522fdb?anonymousKey=88f03714e6f04a13b1921e99c0165dfd9f885cff) BaseMigrationRatifier #2 — Comment out the onlyOwner modifier to allow non-owners to call setFeeConfig

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/2.sol`](./mutations/BaseMigrationRatifier/2.sol)
- **Caught by:** [`feeConfigChangeRequiresOwner`](./specs/ratifier/access_control.spec#L8)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/access_control.conf --rule feeConfigChangeRequiresOwner`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 2`

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
##### [❌](https://prover.certora.com/output/52567/ed2ccca4688e4a50b224561d6d6f0c0d?anonymousKey=7549839549a37703eaef7183b50174fffb2a5887) BaseMigrationRatifier #10 — Flip || to && to allow single unconfigured field

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/10.sol`](./mutations/BaseMigrationRatifier/10.sol)
- **Caught by:** [`unconfiguredTupleAlwaysReverts`](./specs/ratifier/revert.spec#L59)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule unconfiguredTupleAlwaysReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 10`

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
##### [❌](https://prover.certora.com/output/52567/201f21e0b1e34ec4a06870ab0c912caf?anonymousKey=5377985800bac8d9550af5a7f27888534d97c3ab) BaseMigrationRatifier #11 — Invert feeMarketId selection (wrong market for fee lookup)

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/11.sol`](./mutations/BaseMigrationRatifier/11.sol)
- **Caught by:** [`callbackFeeMustMatchEffectiveConfig`](./specs/ratifier/revert.spec#L188) (DEFAULT-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule callbackFeeMustMatchEffectiveConfig`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 11`

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
##### [❌](https://prover.certora.com/output/52567/28c4c1e773f34b4185430acdf678c400?anonymousKey=60d1a8a30085d7c3b99283b76fb02521570cdc7f) BaseMigrationRatifier #12 — Accept fee rate mismatch when recipient matches

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/12.sol`](./mutations/BaseMigrationRatifier/12.sol)
- **Caught by:** [`callbackFeeMustMatchEffectiveConfig`](./specs/ratifier/revert.spec#L188) (DEFAULT-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule callbackFeeMustMatchEffectiveConfig`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 12`

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
##### [❌](https://prover.certora.com/output/52567/5f1878ea4e894c28b3754bb2399934aa?anonymousKey=435b2d1761fd125df8eaf15db23055e206c25af4) BaseMigrationRatifier #13 — Allow targetMaturity == sourceMaturity (off-by-one)

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/13.sol`](./mutations/BaseMigrationRatifier/13.sol)
- **Caught by:** [`targetMaturityMustExceedSource`](./specs/ratifier/revert.spec#L98) (ORCH-9)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule targetMaturityMustExceedSource`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 13`

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
##### [❌](https://prover.certora.com/output/52567/882c53afa7064efc90d991a7d90ce800?anonymousKey=f8cbbf73e1030c8604d073918b5c78e2a8b5aa9c) BaseMigrationRatifier #15 — cadence-grid guard != -> == : accepts off-grid maturities, rejects on-grid

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/15.sol`](./mutations/BaseMigrationRatifier/15.sol)
- **Caught by:** [`targetMaturityOnCadenceGrid`](./specs/ratifier/revert.spec#L142) (ORCH-11)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule targetMaturityOnCadenceGrid`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 15`

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
##### [❌](https://prover.certora.com/output/52567/d18899aadfcb49f79996de8b37b9ede1?anonymousKey=e2ae2f2ecbb996c771dc5b197acf9912070e6aa0) BaseMigrationRatifier #18 — Flip the condition from != to == to invert the override logic; market config is returned even when not set, instead of falling back to default

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/18.sol`](./mutations/BaseMigrationRatifier/18.sol)
- **Caught by:** [`getEffectiveFeeConfigMarketOverridesActionDefault`](./specs/ratifier/unit.spec#L8) (ORCH-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule getEffectiveFeeConfigMarketOverridesActionDefault`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 18`

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
##### [❌](https://prover.certora.com/output/52567/7dcada76d4674d37aa783beb0e5d1d48?anonymousKey=de2504767e12349a39ed769a25d131d865836003) BaseMigrationRatifier #19 — Change the disjunction || to conjunction && so no callback can satisfy the condition, breaking the buy-side flag directionality

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/19.sol`](./mutations/BaseMigrationRatifier/19.sol)
- **Caught by:** [`userIsBuyMatchesBuySideCallbacks`](./specs/ratifier/unit.spec#L82) (DEFAULT-1, RATE-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule userIsBuyMatchesBuySideCallbacks`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 19`

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
##### [❌](https://prover.certora.com/output/52567/b7b3b7426a0147669c1cb6fc8e9a47eb?anonymousKey=b6f1ecbe5c617fc47b188d147c7afb424d6f7984) BaseMigrationRatifier #20 — _maxFeeRate exit-cap removed: cap nonzero (MAX_FEE_RATE) on V2->V1 exits instead of 0

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/20.sol`](./mutations/BaseMigrationRatifier/20.sol)
- **Caught by:** [`maxFeeRateZeroOnV2ToV1Exits`](./specs/ratifier/unit.spec#L152) (ORCH-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule maxFeeRateZeroOnV2ToV1Exits`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 20`

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
##### [❌](https://prover.certora.com/output/52567/d814f6d924ef457c941e00a2925b1100?anonymousKey=0897824bea3e4042776daa5ca2fb590315a15c49) BaseMigrationRatifier #21 — Replace zeroFloorSub with plain subtraction to allow underflow on exits after source maturity, violating the clamping to 0 invariant

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/21.sol`](./mutations/BaseMigrationRatifier/21.sol)
- **Caught by:** [`computeDurationPerCallback`](./specs/ratifier/unit.spec#L162) (ORCH-13)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule computeDurationPerCallback`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 21`

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
##### [❌](https://prover.certora.com/output/52567/d95268dfa67c46d4b5c81957588e1529?anonymousKey=50fb0b053bc02ef768df6f3f8b40999bc8bb4793) BaseMigrationRatifier #22 — Tightens the lower duration-band check from < to <=, so a target maturity exactly at now+minDuration is now rejected; the witness that a boundary target maturity is accepted becomes unreachable because the take reverts.

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/22.sol`](./mutations/BaseMigrationRatifier/22.sol)
- **Caught by:** [`targetMaturityWithinDurationBand_boundaryAccepted`](./specs/ratifier/revert.spec#L253) (ORCH-10)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule targetMaturityWithinDurationBand_boundaryAccepted`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 22`

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
##### [❌](https://prover.certora.com/output/52567/7808468866dd423bb3a491b13a0e2540?anonymousKey=9e99aa8d91b4456e067b35a68c6559519672a1f5) BaseMigrationRatifier #23 — Window param guard > -> >= : rejects renewalWindow == sourceMaturity (window opens at time 0), a valid config. Caught by the boundary-accepted satisfy companion.

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/23.sol`](./mutations/BaseMigrationRatifier/23.sol)
- **Caught by:** [`v2SourceWindowEnforcedBeforeOpen_boundaryAccepted`](./specs/ratifier/revert.spec#L283) (ORCH-8)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule v2SourceWindowEnforcedBeforeOpen_boundaryAccepted`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 23`

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
##### [❌](https://prover.certora.com/output/52567/c29c49e1b6b44abcb27fb00415b1e79f?anonymousKey=7c28338e7ee85f03f9d8da0bb4a5b3f2a89057c2) BaseMigrationRatifier #24 — Cadence-boundary guard > -> >= : rejects a V1->V2 enter whose nearest boundary is exactly now, a valid config. Caught by the boundary-accepted satisfy companion.

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/24.sol`](./mutations/BaseMigrationRatifier/24.sol)
- **Caught by:** [`variableSourceWindowEnforced_boundaryAccepted`](./specs/ratifier/revert.spec#L311) (ORCH-7)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule variableSourceWindowEnforced_boundaryAccepted`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 24`

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
##### [❌](https://prover.certora.com/output/52567/b84b34d4225248b6966d177d8459c16d?anonymousKey=d0faed4bfd14b2d9009a8860ce201440476d4e85) BaseMigrationRatifier #25 — tick guard != -> == : reverts on a matching tick, accepts a mismatch

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/25.sol`](./mutations/BaseMigrationRatifier/25.sol)
- **Caught by:** [`tickMustMatchOffer`](./specs/ratifier/revert.spec#L80) (DEFAULT-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule tickMustMatchOffer`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 25`

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
##### [❌](https://prover.certora.com/output/52567/808048ea08304f689edeb058b79e0b56?anonymousKey=ba593653d834f6bf4b4b148a8710683da316883f) BaseMigrationRatifier #28 — Flips the renewal-window guard from < to >=, so every fixed-source take reverts instead of only early ones; the witness that a post-maturity renewal is executable disappears because the take always reverts.

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/28.sol`](./mutations/BaseMigrationRatifier/28.sol)
- **Caught by:** [`postMaturityV2ToV2Executable`](./specs/ratifier/reachability.spec#L9) (ORCH-5)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/reachability.conf --rule postMaturityV2ToV2Executable`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 28`

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
##### [❌](https://prover.certora.com/output/52567/17a53a2f766a4aa080d14279f7e04490?anonymousKey=02c90eda53928afa40eff3d40d6eca47c1a315a7) BaseMigrationRatifier #29 — Inverts the target-maturity guard from >0 to ==0, so an exit with zero target maturity now runs target-maturity validation and always reverts; the witness that a post-maturity exit is executable disappears because the take reverts.

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/29.sol`](./mutations/BaseMigrationRatifier/29.sol)
- **Caught by:** [`postMaturityV2ToV1Executable`](./specs/ratifier/reachability.spec#L31) (ORCH-6)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/reachability.conf --rule postMaturityV2ToV1Executable`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 29`

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
##### [❌](https://prover.certora.com/output/52567/5645638ecdba42a79601117170c96590?anonymousKey=48f7ee1f5ea39db71e7cbadd0aafd3e50b4a426d) BaseMigrationRatifier #31 — Adds a renewalWindow != 0 revert to the variable-source migration path, so the stored renewal window now gates a V1-to-V2 migration; the assert that such a migration ignores the renewal window flips to a counterexample.

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/31.sol`](./mutations/BaseMigrationRatifier/31.sol)
- **Caught by:** [`v1v2migrationsHaveNoRenewalWindowConstraint`](./specs/ratifier/highlevel.spec#L8) (ORCH-7)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule v1v2migrationsHaveNoRenewalWindowConstraint`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 31`

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
##### [❌](https://prover.certora.com/output/52567/f54402e08a1e409f9e7262183f7c0169?anonymousKey=141e0a079133e1afecccdea684d48a5b297a2b2f) BaseMigrationRatifier #32 — make-on-behalf check == -> != : real gate uses taker settlementFee, diverging from the fee=0 reconstruction

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/32.sol`](./mutations/BaseMigrationRatifier/32.sol)
- **Caught by:** [`borrowerRateGateMatchesNetSellerThreshold`](./specs/ratifier/highlevel.spec#L92) (BBM) · [`lenderRateGateMatchesNetBuyerThreshold`](./specs/ratifier/highlevel.spec#L169) (LVM)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule borrowerRateGateMatchesNetSellerThreshold lenderRateGateMatchesNetBuyerThreshold`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 32`

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
##### [❌](https://prover.certora.com/output/52567/3d2fd0a33e1642b29dded8bd1d78d153?anonymousKey=ec6c815d04701e43d42c119dc24ac85c87eeb71c) BaseMigrationRatifier #33 — wrong var: rate-limit slot clobbered with policyRate, real gate diverges from reconstruction's real limit

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/33.sol`](./mutations/BaseMigrationRatifier/33.sol)
- **Caught by:** [`lenderRateGateMatchesNetBuyerThreshold`](./specs/ratifier/highlevel.spec#L169) (LVM) · [`borrowerRateGateMatchesNetSellerThreshold`](./specs/ratifier/highlevel.spec#L92) (BBM)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule lenderRateGateMatchesNetBuyerThreshold borrowerRateGateMatchesNetSellerThreshold`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 33`

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
##### [❌](https://prover.certora.com/output/52567/2cb4222582eb4b05a6c231f40181c640?anonymousKey=7801ad00b67412b9f9c2aa7789e8f0203d6321cd) BaseMigrationRatifier #36 — cadence-boundary guard > -> < : allows future cadence boundary

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/36.sol`](./mutations/BaseMigrationRatifier/36.sol)
- **Caught by:** [`variableSourceWindowEnforced`](./specs/ratifier/revert.spec#L231) (ORCH-7)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule variableSourceWindowEnforced`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 36`

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
##### [❌](https://prover.certora.com/output/52567/2cd25c093c474a90a84b46198bc23415?anonymousKey=a60bdc860a1dd664c801b995a238731ea6ae01c8) BaseMigrationRatifier #39 — fee-cap check inverted: over-cap rate can be stored

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/39.sol`](./mutations/BaseMigrationRatifier/39.sol)
- **Caught by:** [`feeRateNeverExceedsCallbackCap`](./specs/ratifier/valid_state.spec#L7) (ORCH-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/valid_state.conf --rule feeRateNeverExceedsCallbackCap`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 39`

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
##### [❌](https://prover.certora.com/output/52567/8ff0b8d530ff4caea26003df0c6aa8c4?anonymousKey=fff31534089beb62ca9b3d2b02988c8524ab53cf) BaseMigrationRatifier #40 — recipient guard == -> != : nonzero rate with zero recipient stored

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/40.sol`](./mutations/BaseMigrationRatifier/40.sol)
- **Caught by:** [`nonZeroFeeRateImpliesRecipient`](./specs/ratifier/valid_state.spec#L15) (ORCH-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/valid_state.conf --rule nonZeroFeeRateImpliesRecipient`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 40`

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
##### [❌](https://prover.certora.com/output/52567/a7640198f8fc48b7b28f4ce7dd5d1054?anonymousKey=22f3e86fbaf892569a49e6adba5ab561e934f3ee) BaseMigrationRatifier #41 — fee-market ternary swapped: consults wrong market slot

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/41.sol`](./mutations/BaseMigrationRatifier/41.sol)
- **Caught by:** [`feeMarketIdIgnoresCrossMarketSlot`](./specs/ratifier/highlevel.spec#L65) (ORCH-14)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule feeMarketIdIgnoresCrossMarketSlot`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 41`

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
##### [❌](https://prover.certora.com/output/52567/961fafbc84b1407d91751bde841ce41d?anonymousKey=4f255e9870f49416ad18ae41565f6185b57a529f) BaseMigrationRatifier #42 — getRate user arg -> address(0): forwards wrong principal owner

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/42.sol`](./mutations/BaseMigrationRatifier/42.sol)
- **Caught by:** [`getRatePrincipalForwardedFaithfully`](./specs/ratifier/highlevel.spec#L279)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule getRatePrincipalForwardedFaithfully`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 42`

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
##### [❌](https://prover.certora.com/output/52567/6192d914087e486a8eccd157766bce54?anonymousKey=ff9422393a79f6e4a4c119f30769dd09f5340cb3) BaseMigrationRatifier #43 — unauthorized-callback revert disabled (if(false)): accepts unknown callback

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/43.sol`](./mutations/BaseMigrationRatifier/43.sol)
- **Caught by:** [`unauthorizedCallbackReverts`](./specs/ratifier/revert.spec#L339)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule unauthorizedCallbackReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 43`

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
##### [❌](https://prover.certora.com/output/52567/ca7823f7d1ea4146b69743e7e13d7a80?anonymousKey=8c64420ac22d9b18d7105924dff79cb7fbdbf169) BaseMigrationRatifier #44 — duration-band || -> && : out-of-band maturity no longer reverts

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/44.sol`](./mutations/BaseMigrationRatifier/44.sol)
- **Caught by:** [`targetMaturityWithinDurationBand`](./specs/ratifier/revert.spec#L115) (ORCH-10)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule targetMaturityWithinDurationBand`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 44`

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
##### [❌](https://prover.certora.com/output/52567/3296f8b884354d779c8e3a10c649cc34?anonymousKey=2868dfb80a6375b28cbfccadcdc3ac451124dc79) BaseMigrationRatifier #45 — source-window guard < -> > : before-open no longer reverts

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/45.sol`](./mutations/BaseMigrationRatifier/45.sol)
- **Caught by:** [`v2SourceWindowEnforcedBeforeOpen`](./specs/ratifier/revert.spec#L208) (ORCH-8)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule v2SourceWindowEnforcedBeforeOpen`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 45`

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
##### [❌](https://prover.certora.com/output/52567/6b265e01015644a1a2a72f7493258ef0?anonymousKey=98765a7d533d58d83ead09f8f0852acf6649405f) BaseMigrationRatifier #46 — target-maturity guard <= -> >= : V1->V2 (srcMat==0) always reverts, witness unreachable

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/46.sol`](./mutations/BaseMigrationRatifier/46.sol)
- **Caught by:** [`entryV1ToV2Executable`](./specs/ratifier/reachability.spec#L52)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/reachability.conf --rule entryV1ToV2Executable`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 46`

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
##### [❌](https://prover.certora.com/output/52567/ec80357f6ef04c8f9ce9a9cdd2fd8a96?anonymousKey=b9cb6561aa24adba765d225eb78b99f6ce430209) BaseMigrationRatifier #47 — continuous-fee lifetime * -> + : high fee no longer reaches WAD cap, over-cap offer accepted

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/47.sol`](./mutations/BaseMigrationRatifier/47.sol)
- **Caught by:** [`continuousFeeCapReverts`](./specs/ratifier/revert.spec#L356) (LVM, LMR)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule continuousFeeCapReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 47`

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
##### [❌](https://prover.certora.com/output/52567/576c483ecb144945a197768e10a8b991?anonymousKey=2350669db857ac65977f08dd67405af0574adc0a) BaseMigrationRatifier #48 — Comment out the feeRecipient assignment so setFeeConfig stores only the rate, breaking fee-slot write fidelity

- **Mutant:** [`certora/mutations/BaseMigrationRatifier/48.sol`](./mutations/BaseMigrationRatifier/48.sol)
- **Caught by:** [`setFeeConfigWritesSlotAndLeavesOthers`](./specs/ratifier/unit.spec#L262)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule setFeeConfigWritesSlotAndLeavesOthers`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BaseMigrationRatifier 48`

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

#### `BorrowBlueToMidnightCallback` — `src/callbacks/BorrowBlueToMidnightCallback.sol`

<a id="m-borrowbluetomidnightcallback-1"></a>
##### ❌ BorrowBlueToMidnightCallback #1 — auth guard flipped (!= -> ==)

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/1.sol`](./mutations/BorrowBlueToMidnightCallback/1.sol)
- **Caught by:** [`callbackRevertsForNonMidnightCaller`](./specs/callbacks/callbacks.spec#L80) (CB-AUTH-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/callbackRevertsForNonMidnightCaller.conf --rule callbackRevertsForNonMidnightCaller`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 1`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -52,7 +52,7 @@
         address receiver,
         bytes memory data
     ) external override returns (bytes32) {
-        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
+        if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();  // MUTATION: rebased
         if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
```

<a id="m-borrowbluetomidnightcallback-2"></a>
##### ❌ BorrowBlueToMidnightCallback #2 — supplyCollateral amount forced to 0: collateral never lands on Midnight, migration cannot move it

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/2.sol`](./mutations/BorrowBlueToMidnightCallback/2.sol)
- **Caught by:** [`migrationCanMoveCollateralBlueToMidnight`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L137)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/migrationCanMoveCollateralBlueToMidnight.conf --rule migrationCanMoveCollateralBlueToMidnight`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 2`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -89,7 +89,7 @@
         if (collateralMigrated > 0) {
             MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
             IERC20(sourceMarketParams.collateralToken).forceApprove(address(MORPHO_MIDNIGHT), collateralMigrated);
-            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated, seller);
+            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, 0, seller);  // MUTATION: rebased
         }
 
         emit BorrowMigratedBlueToMidnight(
```

<a id="m-borrowbluetomidnightcallback-3"></a>
##### ❌ BorrowBlueToMidnightCallback #3 — onSell final-fill collateral blueCollateral -1 : debt fully clears but 1 wei collateral remains (coupling broken)

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/3.sol`](./mutations/BorrowBlueToMidnightCallback/3.sol)
- **Caught by:** [`clearingOldDebtAlsoEmptiesOldCollateral`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L75) (CB-FINAL-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/clearingOldDebtAlsoEmptiesOldCollateral.conf --rule clearingOldDebtAlsoEmptiesOldCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 3`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -84,7 +84,7 @@
             MORPHO_BLUE.repay(sourceMarketParams, repayBudget, 0, seller, "");
         }
 
-        uint256 collateralMigrated = isFinalFill ? blueCollateral : blueCollateral.mulDivDown(repayBudget, blueDebt);
+        uint256 collateralMigrated = isFinalFill ? blueCollateral - 1 : blueCollateral.mulDivDown(repayBudget, blueDebt);  // MUTATION: rebased
 
         if (collateralMigrated > 0) {
             MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
```

<a id="m-borrowbluetomidnightcallback-4"></a>
##### ❌ BorrowBlueToMidnightCallback #4 — onSell Midnight supply amount collateralMigrated -1 : mnIn = blueOut-1, breaks 1:1 conservation

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/4.sol`](./mutations/BorrowBlueToMidnightCallback/4.sol)
- **Caught by:** [`migrationConservesMigratedCollateral`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L115) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/migrationConservesMigratedCollateral.conf --rule migrationConservesMigratedCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 4`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -89,7 +89,7 @@
         if (collateralMigrated > 0) {
             MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
             IERC20(sourceMarketParams.collateralToken).forceApprove(address(MORPHO_MIDNIGHT), collateralMigrated);
-            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated, seller);
+            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated - 1, seller);  // MUTATION: rebased
         }
 
         emit BorrowMigratedBlueToMidnight(
```

<a id="m-borrowbluetomidnightcallback-9"></a>
##### ❌ BorrowBlueToMidnightCallback #9 — Supplying collateral to the new Midnight market is replaced by withdrawing it, so the Midnight collateral shrinks instead of growing and the rule requiring migration to only add new-market collateral produces a counterexample.

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/9.sol`](./mutations/BorrowBlueToMidnightCallback/9.sol)
- **Caught by:** [`migrationOnlyAddsNewMidnightCollateral`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L96) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/perf/migrationOnlyAddsNewMidnightCollateral.conf --rule migrationOnlyAddsNewMidnightCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 9`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -89,7 +89,7 @@
         if (collateralMigrated > 0) {
             MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
             IERC20(sourceMarketParams.collateralToken).forceApprove(address(MORPHO_MIDNIGHT), collateralMigrated);
-            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated, seller);
+            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, seller, address(this));  // MUTATION: rebased
         }
 
         emit BorrowMigratedBlueToMidnight(
```

<a id="m-borrowbluetomidnightcallback-12"></a>
##### ❌ BorrowBlueToMidnightCallback #12 — Changing the excess-repayment check from greater-than to greater-or-equal makes the final fill (where repayBudget equals the debt) revert, so the witness showing all Blue collateral fully withdrawn can no longer be produced.

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/12.sol`](./mutations/BorrowBlueToMidnightCallback/12.sol)
- **Caught by:** [`fullCollateralMigrationClearsAllOldDebt__satisfy`](./specs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/many_satisfy.spec#L220) (CB-CLOSE-2)
- **Channel:** satisfy-twin — the mutation makes `take()` (or its antecedent branch) revert, so the witness becomes UNSAT (**VIOLATED** = mutant caught); the clean-`src/` witness is proven **SUCCESS**.
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/perf_kill_satisfy/fullCollateralMigrationClearsAllOldDebt.conf --rule fullCollateralMigrationClearsAllOldDebt__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 12`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -74,7 +74,7 @@
         }
         uint256 repayBudget = sellerAssets - fee;
 
-        if (repayBudget > blueDebt) revert CallbackLib.ExcessRepayment();
+        if (repayBudget >= blueDebt) revert CallbackLib.ExcessRepayment();  // MUTATION: rebased
         IERC20(loanToken).forceApprove(address(MORPHO_BLUE), repayBudget);
 
         bool isFinalFill = repayBudget == blueDebt;
```

<a id="m-borrowbluetomidnightcallback-14"></a>
##### ❌ BorrowBlueToMidnightCallback #14 — Flipping the source-market loan-token check from not-equal to equal accepts a source market whose loan token differs from the offer's, so the rule requiring a mismatched loan token to revert produces a counterexample.

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/14.sol`](./mutations/BorrowBlueToMidnightCallback/14.sol)
- **Caught by:** [`sourceLoanTokenMismatchReverts`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L286)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/sourceLoanTokenMismatchReverts.conf --rule sourceLoanTokenMismatchReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 14`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -59,7 +59,7 @@
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
         MarketParams memory sourceMarketParams = callbackData.sourceMarketParams;
         address loanToken = market.loanToken;
-        if (sourceMarketParams.loanToken != loanToken) revert CallbackLib.TokenMismatch();
+        if (sourceMarketParams.loanToken == loanToken) revert CallbackLib.TokenMismatch();  // MUTATION: rebased
         (bool found, uint256 collateralIndex) = market.findCollateral(sourceMarketParams.collateralToken);
         if (!found) revert CallbackLib.TokenMismatch();
 
```

<a id="m-borrowbluetomidnightcallback-15"></a>
##### ❌ BorrowBlueToMidnightCallback #15 — Replacing the Blue repay with a borrow makes the seller's old Blue debt increase instead of decrease, so the rule requiring migration to only reduce the old Blue debt produces a counterexample.

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/15.sol`](./mutations/BorrowBlueToMidnightCallback/15.sol)
- **Caught by:** [`migrationOnlyReducesOldBlueDebt`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L15) (CB-V1-REP-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/perf/migrationOnlyReducesOldBlueDebt.conf --rule migrationOnlyReducesOldBlueDebt`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 15`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -81,7 +81,7 @@
         if (isFinalFill) {
             MORPHO_BLUE.repay(sourceMarketParams, 0, bluePosition.borrowShares, seller, "");
         } else {
-            MORPHO_BLUE.repay(sourceMarketParams, repayBudget, 0, seller, "");
+            MORPHO_BLUE.borrow(sourceMarketParams, repayBudget, 0, seller, seller); // MUTATION: rebased
         }
 
         uint256 collateralMigrated = isFinalFill ? blueCollateral : blueCollateral.mulDivDown(repayBudget, blueDebt);
```

<a id="m-borrowbluetomidnightcallback-16"></a>
##### ❌ BorrowBlueToMidnightCallback #16 — Replacing the Blue collateral withdrawal with a supply makes the seller's old Blue collateral grow instead of shrink, so the rule requiring migration to only withdraw old Blue collateral produces a counterexample.

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/16.sol`](./mutations/BorrowBlueToMidnightCallback/16.sol)
- **Caught by:** [`migrationOnlyWithdrawsOldBlueCollateral`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L33) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/perf/migrationOnlyWithdrawsOldBlueCollateral.conf --rule migrationOnlyWithdrawsOldBlueCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 16`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -87,7 +87,7 @@
         uint256 collateralMigrated = isFinalFill ? blueCollateral : blueCollateral.mulDivDown(repayBudget, blueDebt);
 
         if (collateralMigrated > 0) {
-            MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
+            MORPHO_BLUE.supplyCollateral(sourceMarketParams, collateralMigrated, seller, ""); // MUTATION: rebased
             IERC20(sourceMarketParams.collateralToken).forceApprove(address(MORPHO_MIDNIGHT), collateralMigrated);
             MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated, seller);
         }
```

<a id="m-borrowbluetomidnightcallback-18"></a>
##### ❌ BorrowBlueToMidnightCallback #18 — Doubling the amount transferred to the fee recipient makes the borrower pay twice the intended fee, so the rule bounding the borrower fee by its interest share produces a counterexample.

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/18.sol`](./mutations/BorrowBlueToMidnightCallback/18.sol)
- **Caught by:** [`borrowerFeeBoundedByInterestShare`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L181) (CB-RATE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/perf/borrowerFeeBoundedByInterestShare.conf --rule borrowerFeeBoundedByInterestShare`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 18`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -70,7 +70,7 @@
 
         uint256 fee = CallbackLib.sellerFeeFromTick(callbackData.tick, callbackData.feeRate, units, sellerAssets);
         if (fee > 0) {
-            SafeTransferLib.safeTransfer(loanToken, callbackData.feeRecipient, fee);
+            SafeTransferLib.safeTransfer(loanToken, callbackData.feeRecipient, fee * 2); // MUTATION: rebased
         }
         uint256 repayBudget = sellerAssets - fee;
 
```

<a id="m-borrowbluetomidnightcallback-20"></a>
##### ❌ BorrowBlueToMidnightCallback #20 — Flipping the caller check from not-equal to equal makes onSell revert whenever Midnight (its only legitimate caller) invokes it, so take() always reverts and the witness that migration reduces old debt on at most one market can no longer be produced.

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/20.sol`](./mutations/BorrowBlueToMidnightCallback/20.sol)
- **Caught by:** [`migrationReducesOldDebtOnAtMostOneMarket__satisfy`](./specs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/many_satisfy.spec#L115) (CB-DIR-1)
- **Channel:** satisfy-twin — the mutation makes `take()` (or its antecedent branch) revert, so the witness becomes UNSAT (**VIOLATED** = mutant caught); the clean-`src/` witness is proven **SUCCESS**.
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/migrationReducesOldDebtOnAtMostOneMarket.conf --rule migrationReducesOldDebtOnAtMostOneMarket__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 20`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -52,7 +52,7 @@
         address receiver,
         bytes memory data
     ) external override returns (bytes32) {
-        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
+        if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();  // MUTATION: rebased
         if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
```

<a id="m-borrowbluetomidnightcallback-21"></a>
##### ❌ BorrowBlueToMidnightCallback #21 — Migrating one wei less than the full Blue collateral on the final fill always leaves a wei behind, so the seller's collateral never reaches zero and the witness showing the old position can be fully closed can no longer be produced.

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/21.sol`](./mutations/BorrowBlueToMidnightCallback/21.sol)
- **Caught by:** [`migrationCanFullyCloseOldPosition`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L158) (CB-CLOSE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/perf_kill/migrationCanFullyCloseOldPosition.conf --rule migrationCanFullyCloseOldPosition`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 21`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -84,7 +84,7 @@
             MORPHO_BLUE.repay(sourceMarketParams, repayBudget, 0, seller, "");
         }
 
-        uint256 collateralMigrated = isFinalFill ? blueCollateral : blueCollateral.mulDivDown(repayBudget, blueDebt);
+        uint256 collateralMigrated = isFinalFill ? blueCollateral - 1 : blueCollateral.mulDivDown(repayBudget, blueDebt);  // MUTATION: rebased
 
         if (collateralMigrated > 0) {
             MORPHO_BLUE.withdrawCollateral(sourceMarketParams, collateralMigrated, seller, address(this));
```

<a id="m-borrowbluetomidnightcallback-22"></a>
##### ❌ BorrowBlueToMidnightCallback #22 — onSell receiver guard flipped (!= -> ==): receiver!=callback no longer reverts. Caught by receiverNotCallbackReverts (CLB-BBM-12, receiverNotCallback => reverted via callbackCallWithRevert) — the flip leaves a non-reverting receiver!=callback trace, assert violated.

- **Mutant:** [`certora/mutations/BorrowBlueToMidnightCallback/22.sol`](./mutations/BorrowBlueToMidnightCallback/22.sol)
- **Caught by:** [`receiverNotCallbackReverts`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L272)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/receiverNotCallbackReverts.conf --rule receiverNotCallbackReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowBlueToMidnightCallback 22`

```diff
--- a/src/callbacks/BorrowBlueToMidnightCallback.sol
+++ b/src/callbacks/BorrowBlueToMidnightCallback.sol
@@ -53,7 +53,7 @@
         bytes memory data
     ) external override returns (bytes32) {
         if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
-        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();
+        if (receiver == address(this)) revert CallbackLib.InvalidReceiver();  // MUTATION: rebased
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
```

#### `BorrowMidnightRenewalCallback` — `src/callbacks/BorrowMidnightRenewalCallback.sol`

<a id="m-borrowmidnightrenewalcallback-1"></a>
##### ❌ BorrowMidnightRenewalCallback #1 — onlyMidnight guard flipped != -> == : the legitimate Midnight caller reverts, so renewal can never roll debt

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/1.sol`](./mutations/BorrowMidnightRenewalCallback/1.sol)
- **Caught by:** [`renewalCanMoveDebtBetweenMarkets`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L157)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalCanMoveDebtBetweenMarkets.conf --rule renewalCanMoveDebtBetweenMarkets`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 1`

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
##### ❌ BorrowMidnightRenewalCallback #3 — Allow renewal into the same market by flipping equality check; violates CLB-BMR-12

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/3.sol`](./mutations/BorrowMidnightRenewalCallback/3.sol)
- **Caught by:** [`callbackRevertsForSameSourceMarket`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L293) (CB-SAME-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/callbackRevertsForSameSourceMarket.conf --rule callbackRevertsForSameSourceMarket`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 3`

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
##### ❌ BorrowMidnightRenewalCallback #8 — Changing repayBudget to 0 prevents any debt repayment on the source market, making it impossible to satisfy the goal of moving debt from source to target market.

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/8.sol`](./mutations/BorrowMidnightRenewalCallback/8.sol)
- **Caught by:** [`renewalCanMoveDebtBetweenMarkets`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L157)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalCanMoveDebtBetweenMarkets.conf --rule renewalCanMoveDebtBetweenMarkets`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 8`

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
##### ❌ BorrowMidnightRenewalCallback #13 — onSell receiver guard flipped (!= -> ==): receiver!=callback no longer reverts. Caught by receiverNotCallbackReverts (CLB-BMR-13, receiverNotCallback => reverted via callbackCallWithRevert) — the flip leaves a non-reverting receiver!=callback trace, assert violated.

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/13.sol`](./mutations/BorrowMidnightRenewalCallback/13.sol)
- **Caught by:** [`receiverNotCallbackReverts`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L306)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/receiverNotCallbackReverts.conf --rule receiverNotCallbackReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 13`

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
##### ❌ BorrowMidnightRenewalCallback #22 — fee transfer doubled: the fee recipient receives fee*2, pushing the paid tick fee past the sellerAssets bound on a non-reverting take — sellerTickFeeNeverExceedsAssets is violated.

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/22.sol`](./mutations/BorrowMidnightRenewalCallback/22.sol)
- **Caught by:** [`sellerTickFeeNeverExceedsAssets`](./specs/callbacks/callbacks.spec#L160) (CB-FEE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/sellerTickFeeNeverExceedsAssets.conf --rule sellerTickFeeNeverExceedsAssets`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 22`

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
##### ❌ BorrowMidnightRenewalCallback #23 — onSell transferCollaterals source/target markets swapped : collateral flows target->source (CLB-BMR-03 add-while-reduce, CLB-BMR-04 remove-while-open)

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/23.sol`](./mutations/BorrowMidnightRenewalCallback/23.sol)
- **Caught by:** [`renewalCannotAddCollateralWhenReducingDebt`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L67) (CB-DIR-1) · [`renewalCannotRemoveCollateralWhenOpeningDebt`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L89) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_kill/renewalCannotAddCollateralWhenReducingDebt.conf --rule renewalCannotAddCollateralWhenReducingDebt renewalCannotRemoveCollateralWhenOpeningDebt`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 23`

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
##### ❌ BorrowMidnightRenewalCallback #24 — The callback inserts an extra self-funded repayment on the target market, so debt drops on both the source and target markets, and the rule requiring at most one market's debt to fall reports a counterexample.

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/24.sol`](./mutations/BorrowMidnightRenewalCallback/24.sol)
- **Caught by:** [`renewalReducesDebtOnAtMostOneMarket`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L21) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf/renewalReducesDebtOnAtMostOneMarket.conf --rule renewalReducesDebtOnAtMostOneMarket`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 24`

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
##### ❌ BorrowMidnightRenewalCallback #25 — onSell inserts safeTransferFrom(units+1) into the callback : loanToken inflow exceeds units bound

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/25.sol`](./mutations/BorrowMidnightRenewalCallback/25.sol)
- **Caught by:** [`renewalCallbackNeverPullsExternalLoanToken`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L111) (CB-SRC-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf/renewalCallbackNeverPullsExternalLoanToken.conf --rule renewalCallbackNeverPullsExternalLoanToken`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 25`

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
##### ❌ BorrowMidnightRenewalCallback #31 — The loan-token match check is inverted so that matching source and target tokens revert, which every real renewal needs, so take() always reverts and the witness opening new target debt without removing collateral can no longer be produced.

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/31.sol`](./mutations/BorrowMidnightRenewalCallback/31.sol)
- **Caught by:** [`renewalCannotRemoveCollateralWhenOpeningDebt__satisfy`](./specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L158) (CB-DIR-1)
- **Channel:** satisfy-twin — the mutation makes `take()` (or its antecedent branch) revert, so the witness becomes UNSAT (**VIOLATED** = mutant caught); the clean-`src/` witness is proven **SUCCESS**.
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/renewalCannotRemoveCollateralWhenOpeningDebt.conf --rule renewalCannotRemoveCollateralWhenOpeningDebt__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 31`

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
##### ❌ BorrowMidnightRenewalCallback #33 — onSell receiver guard inverted (!= to ==) so every take-driven onSell reverts and the receiver-narrowed callbackNeverHoldsTokens__satisfy witness becomes UNSAT.

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/33.sol`](./mutations/BorrowMidnightRenewalCallback/33.sol)
- **Caught by:** [`callbackNeverHoldsTokens__satisfy`](./specs/callbacks/BorrowBlueToMidnightCallback/debug_satisfy/many_satisfy.spec#L34) (CB-DUST-1)
- **Channel:** satisfy-twin — the mutation makes `take()` (or its antecedent branch) revert, so the witness becomes UNSAT (**VIOLATED** = mutant caught); the clean-`src/` witness is proven **SUCCESS**.
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_satisfy/callbackNeverHoldsTokens.conf --rule callbackNeverHoldsTokens__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 33`

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
##### ❌ BorrowMidnightRenewalCallback #34 — Flipping the Midnight-caller guard to == makes onSell revert on its first instruction whenever the caller is Midnight, which it always is inside take(), so the renewalAddsDebtOnAtMostOneMarket satisfy witness can never reach its assert point and turns unsatisfiable.

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/34.sol`](./mutations/BorrowMidnightRenewalCallback/34.sol)
- **Caught by:** [`renewalAddsDebtOnAtMostOneMarket__satisfy`](./specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L122) (CB-DIR-1)
- **Channel:** satisfy-twin — the mutation makes `take()` (or its antecedent branch) revert, so the witness becomes UNSAT (**VIOLATED** = mutant caught); the clean-`src/` witness is proven **SUCCESS**.
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_satisfy/renewalAddsDebtOnAtMostOneMarket.conf --rule renewalAddsDebtOnAtMostOneMarket__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 34`

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
##### ❌ BorrowMidnightRenewalCallback #35 — Flipping the Midnight-caller guard to == makes onSell revert immediately on every in-model take because the caller is always Midnight, so the thirdPartyBalanceUnchanged, callbackHoldsZeroAllowance, and feeRecipientNeverLosesTokens satisfy witnesses become unsatisfiable.

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/35.sol`](./mutations/BorrowMidnightRenewalCallback/35.sol)
- **Caught by:** [`thirdPartyBalanceUnchanged__satisfy`](./specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L27) · [`callbackHoldsZeroAllowance__satisfy`](./specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L9) (CB-DUST-1) · [`feeRecipientNeverLosesTokens__satisfy`](./specs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L72)
- **Channel:** satisfy-twin — the mutation makes `take()` (or its antecedent branch) revert, so the witness becomes UNSAT (**VIOLATED** = mutant caught); the clean-`src/` witness is proven **SUCCESS**.
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/debug_satisfy/thirdPartyBalanceUnchanged.conf --rule thirdPartyBalanceUnchanged__satisfy callbackHoldsZeroAllowance__satisfy feeRecipientNeverLosesTokens__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 35`

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
##### ❌ BorrowMidnightRenewalCallback #36 — Doubling the seller fee transfer pushes the fee recipient's loanToken balance delta past the interest-share bound, so borrowerFeeBoundedByInterestShare flips to a counterexample.

- **Mutant:** [`certora/mutations/BorrowMidnightRenewalCallback/36.sol`](./mutations/BorrowMidnightRenewalCallback/36.sol)
- **Caught by:** [`borrowerFeeBoundedByInterestShare`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L181) (CB-RATE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_kill/borrowerFeeBoundedByInterestShare.conf --rule borrowerFeeBoundedByInterestShare`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightRenewalCallback 36`

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

#### `BorrowMidnightToBlueCallback` — `src/callbacks/BorrowMidnightToBlueCallback.sol`

<a id="m-borrowmidnighttobluecallback-8"></a>
##### ❌ BorrowMidnightToBlueCallback #8 — Commenting out the borrow call prevents Blue debt from being opened, making the satisfy clause impossible to prove (cannot demonstrate that blueSharesAfter > sharesBefore).

- **Mutant:** [`certora/mutations/BorrowMidnightToBlueCallback/8.sol`](./mutations/BorrowMidnightToBlueCallback/8.sol)
- **Caught by:** [`migrationCanOpenNewBlueDebt`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L136)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationCanOpenNewBlueDebt.conf --rule migrationCanOpenNewBlueDebt`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 8`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -81,7 +81,7 @@
         }
 
         uint256 borrowAmount = buyerAssets + fee;
-        MORPHO_BLUE.borrow(callbackData.targetMarketParams, borrowAmount, 0, buyer, address(this));
+        // MORPHO_BLUE.borrow(callbackData.targetMarketParams, borrowAmount, 0, buyer, address(this));  // MUTATION: rebased
 
         if (fee > 0) {
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
```

<a id="m-borrowmidnighttobluecallback-9"></a>
##### ❌ BorrowMidnightToBlueCallback #9 — withdrawCollateral commented out: collateral never leaves Midnight, migration cannot move it

- **Mutant:** [`certora/mutations/BorrowMidnightToBlueCallback/9.sol`](./mutations/BorrowMidnightToBlueCallback/9.sol)
- **Caught by:** [`migrationCanMoveCollateralMidnightToBlue`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L154)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationCanMoveCollateralMidnightToBlue.conf --rule migrationCanMoveCollateralMidnightToBlue`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 9`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -73,7 +73,7 @@
             sourceDebtAfter == 0 ? sourceCollateral : sourceCollateral.mulDivDown(units, sourceDebtBefore);
 
         if (collateralMigrated > 0) {
-            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));
+            // MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));  // MUTATION: rebased
 
             IERC20(callbackData.targetMarketParams.collateralToken)
                 .forceApprove(address(MORPHO_BLUE), collateralMigrated);
```

<a id="m-borrowmidnighttobluecallback-10"></a>
##### ❌ BorrowMidnightToBlueCallback #10 — Setting the amount withdrawn from Midnight to zero leaves the borrower's old collateral in place, so no fill can ever fully close the old position and the rule's witness becomes unsatisfiable.

- **Mutant:** [`certora/mutations/BorrowMidnightToBlueCallback/10.sol`](./mutations/BorrowMidnightToBlueCallback/10.sol)
- **Caught by:** [`migrationCanFullyCloseOldPosition`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L175) (CB-CLOSE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationCanFullyCloseOldPosition.conf --rule migrationCanFullyCloseOldPosition`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 10`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -73,7 +73,7 @@
             sourceDebtAfter == 0 ? sourceCollateral : sourceCollateral.mulDivDown(units, sourceDebtBefore);
 
         if (collateralMigrated > 0) {
-            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));
+            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, 0, buyer, address(this));  // MUTATION: rebased
 
             IERC20(callbackData.targetMarketParams.collateralToken)
                 .forceApprove(address(MORPHO_BLUE), collateralMigrated);
```

<a id="m-borrowmidnighttobluecallback-18"></a>
##### ❌ BorrowMidnightToBlueCallback #18 — fee-cap guard inverted (> -> <): every legal below-cap feeRate now reverts while an above-cap rate is accepted — percentageFeeRateAboveCapReverts (aboveCap => reverted) is violated.

- **Mutant:** [`certora/mutations/BorrowMidnightToBlueCallback/18.sol`](./mutations/BorrowMidnightToBlueCallback/18.sol)
- **Caught by:** [`percentageFeeRateAboveCapReverts`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L197)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/percentageFeeRateAboveCapReverts.conf --rule percentageFeeRateAboveCapReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 18`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -58,7 +58,7 @@
     /// @dev Returns the flat percentage fee assets * feeRate / WAD, rounded down.
     /// @dev Reverts if feeRate > MAX_PERCENTAGE_FEE_RATE (1%).
     function percentageFee(uint256 assets, uint256 feeRate) internal pure returns (uint256 fee) {
-        if (feeRate > MAX_PERCENTAGE_FEE_RATE) revert InvalidFeeConfig();
+        if (feeRate < MAX_PERCENTAGE_FEE_RATE) revert InvalidFeeConfig();  // MUTATION: rebased
         fee = assets.mulDivDown(feeRate, WAD);
     }
 
```

<a id="m-borrowmidnighttobluecallback-20"></a>
##### ❌ BorrowMidnightToBlueCallback #20 — Replacing the Midnight withdrawCollateral call with supplyCollateral makes the borrower's old Midnight collateral grow instead of shrink, so the rule that the migration can only reduce old collateral flips to a counterexample.

- **Mutant:** [`certora/mutations/BorrowMidnightToBlueCallback/20.sol`](./mutations/BorrowMidnightToBlueCallback/20.sol)
- **Caught by:** [`migrationOnlyWithdrawsOldMidnightCollateral`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L15) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/migrationOnlyWithdrawsOldMidnightCollateral.conf --rule migrationOnlyWithdrawsOldMidnightCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 20`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -73,7 +73,7 @@
             sourceDebtAfter == 0 ? sourceCollateral : sourceCollateral.mulDivDown(units, sourceDebtBefore);
 
         if (collateralMigrated > 0) {
-            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));
+            MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, collateralMigrated, buyer);  // MUTATION: rebased
 
             IERC20(callbackData.targetMarketParams.collateralToken)
                 .forceApprove(address(MORPHO_BLUE), collateralMigrated);
```

<a id="m-borrowmidnighttobluecallback-24"></a>
##### ❌ BorrowMidnightToBlueCallback #24 — Withdrawing one unit less from Midnight than is supplied to Blue makes the amount deposited into Blue exceed the amount withdrawn from Midnight, so the deposit-at-most-withdrawn rule flips to a counterexample.

- **Mutant:** [`certora/mutations/BorrowMidnightToBlueCallback/24.sol`](./mutations/BorrowMidnightToBlueCallback/24.sol)
- **Caught by:** [`migrationCannotDepositMoreCollateralThanWithdrawn`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L93) (CB-SRC-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/migrationCannotDepositMoreCollateralThanWithdrawn.conf --rule migrationCannotDepositMoreCollateralThanWithdrawn`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 24`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -73,7 +73,7 @@
             sourceDebtAfter == 0 ? sourceCollateral : sourceCollateral.mulDivDown(units, sourceDebtBefore);
 
         if (collateralMigrated > 0) {
-            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));
+            MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated - 1, buyer, address(this));  // MUTATION: rebased
 
             IERC20(callbackData.targetMarketParams.collateralToken)
                 .forceApprove(address(MORPHO_BLUE), collateralMigrated);
```

<a id="m-borrowmidnighttobluecallback-25"></a>
##### ❌ BorrowMidnightToBlueCallback #25 — Migrating one unit less than the full source collateral on the final fill leaves a unit of old Midnight collateral behind after the debt is fully repaid, so the rule that the final fill drains all old collateral flips to a counterexample.

- **Mutant:** [`certora/mutations/BorrowMidnightToBlueCallback/25.sol`](./mutations/BorrowMidnightToBlueCallback/25.sol)
- **Caught by:** [`migrationFinalFillTransfersAllOldMidnightCollateral`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L116) (CB-FINAL-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/migrationFinalFillTransfersAllOldMidnightCollateral.conf --rule migrationFinalFillTransfersAllOldMidnightCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 25`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -70,7 +70,7 @@
         }
 
         uint256 collateralMigrated =
-            sourceDebtAfter == 0 ? sourceCollateral : sourceCollateral.mulDivDown(units, sourceDebtBefore);
+            sourceDebtAfter == 0 ? sourceCollateral - 1 : sourceCollateral.mulDivDown(units, sourceDebtBefore);  // MUTATION: rebased
 
         if (collateralMigrated > 0) {
             MORPHO_MIDNIGHT.withdrawCollateral(market, collateralIndex, collateralMigrated, buyer, address(this));
```

<a id="m-borrowmidnighttobluecallback-26"></a>
##### ❌ BorrowMidnightToBlueCallback #26 — Replacing the Blue supplyCollateral call with withdrawCollateral makes the borrower's new Blue collateral shrink instead of grow, so the rule that the migration can only add new Blue collateral flips to a counterexample.

- **Mutant:** [`certora/mutations/BorrowMidnightToBlueCallback/26.sol`](./mutations/BorrowMidnightToBlueCallback/26.sol)
- **Caught by:** [`migrationOnlyAddsNewBlueCollateral`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L74) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/migrationOnlyAddsNewBlueCollateral.conf --rule migrationOnlyAddsNewBlueCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 26`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -77,7 +77,7 @@
 
             IERC20(callbackData.targetMarketParams.collateralToken)
                 .forceApprove(address(MORPHO_BLUE), collateralMigrated);
-            MORPHO_BLUE.supplyCollateral(callbackData.targetMarketParams, collateralMigrated, buyer, "");
+            MORPHO_BLUE.withdrawCollateral(callbackData.targetMarketParams, collateralMigrated, buyer, address(this));  // MUTATION: rebased
         }
 
         uint256 borrowAmount = buyerAssets + fee;
```

<a id="m-borrowmidnighttobluecallback-27"></a>
##### ❌ BorrowMidnightToBlueCallback #27 — Replacing the Blue borrow call with repay makes the borrower's new Blue debt shares fall instead of rise, so the rule that the migration can only open new Blue debt flips to a counterexample.

- **Mutant:** [`certora/mutations/BorrowMidnightToBlueCallback/27.sol`](./mutations/BorrowMidnightToBlueCallback/27.sol)
- **Caught by:** [`migrationOnlyOpensNewBlueDebt`](./specs/callbacks/BorrowMidnightToBlueCallback/many.spec#L56) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/migrationOnlyOpensNewBlueDebt.conf --rule migrationOnlyOpensNewBlueDebt`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 27`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -81,7 +81,7 @@
         }
 
         uint256 borrowAmount = buyerAssets + fee;
-        MORPHO_BLUE.borrow(callbackData.targetMarketParams, borrowAmount, 0, buyer, address(this));
+        MORPHO_BLUE.repay(callbackData.targetMarketParams, borrowAmount, 0, buyer, "");  // MUTATION: rebased
 
         if (fee > 0) {
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
```

<a id="m-borrowmidnighttobluecallback-29"></a>
##### ❌ BorrowMidnightToBlueCallback #29 — Inverts the caller guard (!= to ==), so onBuy reverts OnlyMidnight on every take() (which always comes from Midnight) and the reachability witness goes UNSAT.

- **Mutant:** [`certora/mutations/BorrowMidnightToBlueCallback/29.sol`](./mutations/BorrowMidnightToBlueCallback/29.sol)
- **Caught by:** [`migrationReducesOldDebtOnAtMostOneMarket__satisfy`](./specs/callbacks/BorrowMidnightToBlueCallback/debug_satisfy/many_satisfy.spec#L88) (CB-DIR-1)
- **Channel:** satisfy-twin — the mutation makes `take()` (or its antecedent branch) revert, so the witness becomes UNSAT (**VIOLATED** = mutant caught); the clean-`src/` witness is proven **SUCCESS**.
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/debug_satisfy/migrationReducesOldDebtOnAtMostOneMarket.conf --rule migrationReducesOldDebtOnAtMostOneMarket__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 29`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -48,7 +48,7 @@
         address buyer,
         bytes memory data
     ) external override returns (bytes32) {
-        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
+        if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();  // MUTATION: rebased
         if (buyerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
```

<a id="m-borrowmidnighttobluecallback-30"></a>
##### ❌ BorrowMidnightToBlueCallback #30 — Borrowing on behalf of the callback contract instead of the buyer opens new Blue debt for a party whose old Midnight debt did not fall, so the rule coupling old and new debt movements flips to a counterexample.

- **Mutant:** [`certora/mutations/BorrowMidnightToBlueCallback/30.sol`](./mutations/BorrowMidnightToBlueCallback/30.sol)
- **Caught by:** [`oldMidnightDebtAndNewBlueDebtMoveTogether`](./specs/callbacks/BorrowMidnightToBlueCallback/one.spec#L9) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/perf/oldMidnightDebtAndNewBlueDebtMoveTogether.conf --rule oldMidnightDebtAndNewBlueDebtMoveTogether`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh BorrowMidnightToBlueCallback 30`

```diff
--- a/src/callbacks/BorrowMidnightToBlueCallback.sol
+++ b/src/callbacks/BorrowMidnightToBlueCallback.sol
@@ -81,7 +81,7 @@
         }
 
         uint256 borrowAmount = buyerAssets + fee;
-        MORPHO_BLUE.borrow(callbackData.targetMarketParams, borrowAmount, 0, buyer, address(this));
+        MORPHO_BLUE.borrow(callbackData.targetMarketParams, borrowAmount, 0, address(this), address(this));  // MUTATION: rebased
 
         if (fee > 0) {
             SafeTransferLib.safeTransfer(market.loanToken, callbackData.feeRecipient, fee);
```

#### `CallbackLib` — `src/libraries/CallbackLib.sol`

<a id="m-callbacklib-1"></a>
##### ❌ CallbackLib #1 — _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes

- **Mutant:** [`certora/mutations/CallbackLib/1.sol`](./mutations/CallbackLib/1.sol)
- **Caught by:** [`tickFeeVanishesAtPar`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L141) (CB-FEE-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/tickFeeVanishesAtPar.conf --rule tickFeeVanishesAtPar`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh CallbackLib 1`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -67,7 +67,7 @@
     /// @dev The caller must handle feeRate == 0 before calling.
     function _interestFeeComponent(uint256 price, uint256 feeRate) private pure returns (uint256) {
         if (feeRate > WAD) revert InvalidFeeConfig();
-        return (WAD - price).mulDivDown(feeRate, WAD);
+        return (WAD + price).mulDivDown(feeRate, WAD);  // MUTATION: rebased
     }
 
     /// @dev Returns the seller-side effective price, price * WAD / (WAD + feeShareOfInterest), rounded up.
```

<a id="m-callbacklib-3"></a>
##### [❌](https://prover.certora.com/output/52567/e9900c8f7dce408db2671d1c2528c330?anonymousKey=90833464a3882fa359f3d4e33fe7368d4581521d) CallbackLib #3 — transposed mulDivDown args (feeRate,WAD)->(WAD,feeRate): fee share inverse in feeRate breaks net-price fee-monotonicity

- **Mutant:** [`certora/mutations/CallbackLib/3.sol`](./mutations/CallbackLib/3.sol)
- **Caught by:** [`netSellerPriceMonotoneInFee`](./specs/ratifier/unit.spec#L188) · [`netBuyerPriceMonotoneInFee`](./specs/ratifier/unit.spec#L213)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule netSellerPriceMonotoneInFee netBuyerPriceMonotoneInFee`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh CallbackLib 3`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -67,7 +67,7 @@
     /// @dev The caller must handle feeRate == 0 before calling.
     function _interestFeeComponent(uint256 price, uint256 feeRate) private pure returns (uint256) {
         if (feeRate > WAD) revert InvalidFeeConfig();
-        return (WAD - price).mulDivDown(feeRate, WAD);
+        return (WAD - price).mulDivDown(WAD, feeRate);  // MUTATION: rebased
     }
 
     /// @dev Returns the seller-side effective price, price * WAD / (WAD + feeShareOfInterest), rounded up.
```

<a id="m-callbacklib-4"></a>
##### ❌ CallbackLib #4 — _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes; re-proves the kill for the BMR instance (the CallbackLib #1 kill under the LVM conf is not evidence for this per-(contract,rule) instance).

- **Mutant:** [`certora/mutations/CallbackLib/4.sol`](./mutations/CallbackLib/4.sol)
- **Caught by:** [`tickFeeVanishesAtPar`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L266) (CB-FEE-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/tickFeeVanishesAtPar.conf --rule tickFeeVanishesAtPar`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh CallbackLib 4`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -67,7 +67,7 @@
     /// @dev The caller must handle feeRate == 0 before calling.
     function _interestFeeComponent(uint256 price, uint256 feeRate) private pure returns (uint256) {
         if (feeRate > WAD) revert InvalidFeeConfig();
-        return (WAD - price).mulDivDown(feeRate, WAD);
+        return (WAD + price).mulDivDown(feeRate, WAD);  // MUTATION: rebased
     }
 
     /// @dev Returns the seller-side effective price, price * WAD / (WAD + feeShareOfInterest), rounded up.
```

<a id="m-callbacklib-5"></a>
##### ❌ CallbackLib #5 — _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes; re-proves the kill for the LMR instance (the CallbackLib #1 kill under the LVM conf is not evidence for this per-(contract,rule) instance).

- **Mutant:** [`certora/mutations/CallbackLib/5.sol`](./mutations/CallbackLib/5.sol)
- **Caught by:** [`tickFeeVanishesAtPar`](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L183) (CB-FEE-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/tickFeeVanishesAtPar.conf --rule tickFeeVanishesAtPar`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh CallbackLib 5`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -67,7 +67,7 @@
     /// @dev The caller must handle feeRate == 0 before calling.
     function _interestFeeComponent(uint256 price, uint256 feeRate) private pure returns (uint256) {
         if (feeRate > WAD) revert InvalidFeeConfig();
-        return (WAD - price).mulDivDown(feeRate, WAD);
+        return (WAD + price).mulDivDown(feeRate, WAD);  // MUTATION: rebased
     }
 
     /// @dev Returns the seller-side effective price, price * WAD / (WAD + feeShareOfInterest), rounded up.
```

<a id="m-callbacklib-6"></a>
##### ❌ CallbackLib #6 — _interestFeeComponent sign flip (WAD-price)->(WAD+price): nonzero interest fee at par, so the tick fee no longer vanishes; re-proves the kill for the BBM instance (the CallbackLib #1 kill under the LVM conf is not evidence for this per-(contract,rule) instance).

- **Mutant:** [`certora/mutations/CallbackLib/6.sol`](./mutations/CallbackLib/6.sol)
- **Caught by:** [`tickFeeVanishesAtPar`](./specs/callbacks/BorrowBlueToMidnightCallback/many.spec#L224) (CB-FEE-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/tickFeeVanishesAtPar.conf --rule tickFeeVanishesAtPar`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh CallbackLib 6`

```diff
--- a/src/libraries/CallbackLib.sol
+++ b/src/libraries/CallbackLib.sol
@@ -67,7 +67,7 @@
     /// @dev The caller must handle feeRate == 0 before calling.
     function _interestFeeComponent(uint256 price, uint256 feeRate) private pure returns (uint256) {
         if (feeRate > WAD) revert InvalidFeeConfig();
-        return (WAD - price).mulDivDown(feeRate, WAD);
+        return (WAD + price).mulDivDown(feeRate, WAD);  // MUTATION: rebased
     }
 
     /// @dev Returns the seller-side effective price, price * WAD / (WAD + feeShareOfInterest), rounded up.
```

#### `CollateralTransferLib` — `src/libraries/CollateralTransferLib.sol`

<a id="m-collateraltransferlib-1"></a>
##### ❌ CollateralTransferLib #1 — Subtracts 1 from the source collateral amount read on the closing fill, so the source position can never be fully drained; the renewalCanFullyCloseOldPosition witness requiring collateral to reach zero becomes unsatisfiable.

- **Mutant:** [`certora/mutations/CollateralTransferLib/1.sol`](./mutations/CollateralTransferLib/1.sol)
- **Caught by:** [`renewalCanFullyCloseOldPosition`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L200) (CB-CLOSE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_kill/renewalCanFullyCloseOldPosition.conf --rule renewalCanFullyCloseOldPosition`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh CollateralTransferLib 1`

```diff
--- a/src/libraries/CollateralTransferLib.sol
+++ b/src/libraries/CollateralTransferLib.sol
@@ -42,7 +42,7 @@
             (bool found, uint256 targetCollateralIndex) = targetMarket.findCollateral(collateralTokens[i]);
 
             if (found) {
-                uint256 collateralToTransfer = morphoMidnight.collateral(sourceMarketId, borrower, i);
+                uint256 collateralToTransfer = morphoMidnight.collateral(sourceMarketId, borrower, i) - 1;  // MUTATION: under-read closing collateral
                 if (sourceDebtBefore != repaidUnits) {
                     collateralToTransfer = collateralToTransfer.mulDivDown(repaidUnits, sourceDebtBefore);
                 }
```

<a id="m-collateraltransferlib-3"></a>
##### ❌ CollateralTransferLib #3 — the inlined collateral loop withdraws collateralToTransfer-1 from source but supplies the full amount to target : moves MORE collateral than withdrawn (callback seed funds +1)

- **Mutant:** [`certora/mutations/CollateralTransferLib/3.sol`](./mutations/CollateralTransferLib/3.sol)
- **Caught by:** [`renewalCannotMoveMoreCollateralThanWithdrawn`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L131) (CB-FINAL-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_kill/renewalCannotMoveMoreCollateralThanWithdrawn.conf --rule renewalCannotMoveMoreCollateralThanWithdrawn`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh CollateralTransferLib 3`

```diff
--- a/src/libraries/CollateralTransferLib.sol
+++ b/src/libraries/CollateralTransferLib.sol
@@ -47,7 +47,7 @@
                     collateralToTransfer = collateralToTransfer.mulDivDown(repaidUnits, sourceDebtBefore);
                 }
                 if (collateralToTransfer > 0) {
-                    morphoMidnight.withdrawCollateral(sourceMarket, i, collateralToTransfer, borrower, address(this));
+                    morphoMidnight.withdrawCollateral(sourceMarket, i, collateralToTransfer - 1, borrower, address(this));  // MUTATION: rebased
                     IERC20(collateralTokens[i]).forceApprove(address(morphoMidnight), collateralToTransfer);
                     morphoMidnight.supplyCollateral(targetMarket, targetCollateralIndex, collateralToTransfer, borrower);
                 }
```

<a id="m-collateraltransferlib-4"></a>
##### ❌ CollateralTransferLib #4 — Supplying zero to the target market leaves the borrower's target collateral unchanged while the source is still drained, so the renewalCanMigrateCollateralBetweenMarkets witness requiring the target collateral to rise becomes unsatisfiable.

- **Mutant:** [`certora/mutations/CollateralTransferLib/4.sol`](./mutations/CollateralTransferLib/4.sol)
- **Caught by:** [`renewalCanMigrateCollateralBetweenMarkets`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L178)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/perf_kill/renewalCanMigrateCollateralBetweenMarkets.conf --rule renewalCanMigrateCollateralBetweenMarkets`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh CollateralTransferLib 4`

```diff
--- a/src/libraries/CollateralTransferLib.sol
+++ b/src/libraries/CollateralTransferLib.sol
@@ -49,7 +49,7 @@
                 if (collateralToTransfer > 0) {
                     morphoMidnight.withdrawCollateral(sourceMarket, i, collateralToTransfer, borrower, address(this));
                     IERC20(collateralTokens[i]).forceApprove(address(morphoMidnight), collateralToTransfer);
-                    morphoMidnight.supplyCollateral(targetMarket, targetCollateralIndex, collateralToTransfer, borrower);
+                    morphoMidnight.supplyCollateral(targetMarket, targetCollateralIndex, 0, borrower);  // MUTATION: rebased
                 }
                 collateralAmounts[i] = collateralToTransfer;
             }
```

#### `LendMidnightRenewalCallback` — `src/callbacks/LendMidnightRenewalCallback.sol`

<a id="m-lendmidnightrenewalcallback-2"></a>
##### ❌ LendMidnightRenewalCallback #2 — zero-amount guard || -> &&

- **Mutant:** [`certora/mutations/LendMidnightRenewalCallback/2.sol`](./mutations/LendMidnightRenewalCallback/2.sol)
- **Caught by:** [`callbackRevertsOnZeroAssetsOrUnits`](./specs/callbacks/callbacks.spec#L91)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf/callbackRevertsOnZeroAssetsOrUnits.conf --rule callbackRevertsOnZeroAssetsOrUnits`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 2`

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
##### ❌ LendMidnightRenewalCallback #8 — Flip fee condition: transfers fee only when fee is zero instead of when it's positive

- **Mutant:** [`certora/mutations/LendMidnightRenewalCallback/8.sol`](./mutations/LendMidnightRenewalCallback/8.sol)
- **Caught by:** [`positiveFeeIsPayable`](./specs/callbacks/callbacks.spec#L201)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf/positiveFeeIsPayable.conf --rule positiveFeeIsPayable`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 8`

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
##### ❌ LendMidnightRenewalCallback #14 — lost the WAD denominator (effPrice,1): fee = units*effPrice explodes far past units

- **Mutant:** [`certora/mutations/LendMidnightRenewalCallback/14.sol`](./mutations/LendMidnightRenewalCallback/14.sol)
- **Caught by:** [`buyerTickFeePaidBoundedByUnits`](./specs/callbacks/callbacks.spec#L180) (CB-FEE-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/buyerTickFeePaidBoundedByUnits.conf --rule buyerTickFeePaidBoundedByUnits`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 14`

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
##### ❌ LendMidnightRenewalCallback #16 — source withdraw zeroed: the lender's source-market credit can never reach zero, so the position-bound close witness goes UNSAT (VIOLATED = caught).

- **Mutant:** [`certora/mutations/LendMidnightRenewalCallback/16.sol`](./mutations/LendMidnightRenewalCallback/16.sol)
- **Caught by:** [`renewalCanFullyCloseOldCredit`](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L112) (CB-CLOSE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf_kill/renewalCanFullyCloseOldCredit.conf --rule renewalCanFullyCloseOldCredit`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 16`

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
##### ❌ LendMidnightRenewalCallback #17 — Forces the buyer callback fee to zero, so the fee recipient is never paid even though the credit still rolls, and the witness that requires both a credit roll and a positive fee payment can no longer be satisfied.

- **Mutant:** [`certora/mutations/LendMidnightRenewalCallback/17.sol`](./mutations/LendMidnightRenewalCallback/17.sol)
- **Caught by:** [`renewalCanMoveCreditWithPositiveFee`](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L135)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/renewalCanMoveCreditWithPositiveFee.conf --rule renewalCanMoveCreditWithPositiveFee`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 17`

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
##### ❌ LendMidnightRenewalCallback #19 — onBuy inserts a 2nd MORPHO_MIDNIGHT.withdraw(units+buyerAssets+1) overshooting take's +units target-credit deposit : credit net-drops on both source and target

- **Mutant:** [`certora/mutations/LendMidnightRenewalCallback/19.sol`](./mutations/LendMidnightRenewalCallback/19.sol)
- **Caught by:** [`renewalReducesCreditOnAtMostOneMarket`](./specs/callbacks/LendMidnightRenewalCallback/many.spec#L39) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf_kill/renewalReducesCreditOnAtMostOneMarket.conf --rule renewalReducesCreditOnAtMostOneMarket`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 19`

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
##### ❌ LendMidnightRenewalCallback #21 — Inverts the zero-credit guard from ==0 to !=0, so every renewal with source credit reverts and the only admitted path (zero source credit) then fails the insufficient-credit check, making take() revert on all paths and leaving the reachability witness unsatisfiable.

- **Mutant:** [`certora/mutations/LendMidnightRenewalCallback/21.sol`](./mutations/LendMidnightRenewalCallback/21.sol)
- **Caught by:** [`renewalAddsCreditOnAtMostOneMarket__satisfy`](./specs/callbacks/LendMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L105) (CB-DIR-1)
- **Channel:** satisfy-twin — the mutation makes `take()` (or its antecedent branch) revert, so the witness becomes UNSAT (**VIOLATED** = mutant caught); the clean-`src/` witness is proven **SUCCESS**.
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf_satisfy/renewalAddsCreditOnAtMostOneMarket.conf --rule renewalAddsCreditOnAtMostOneMarket__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 21`

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
##### ❌ LendMidnightRenewalCallback #23 — Inserts an extra transfer that pulls units+1 of loan token directly from the buyer on top of the legitimate withdraw, so the callback's net external inflow exceeds units and the rule bounding that inflow flips to a counterexample.

- **Mutant:** [`certora/mutations/LendMidnightRenewalCallback/23.sol`](./mutations/LendMidnightRenewalCallback/23.sol)
- **Caught by:** [`renewalCallbackNeverPullsExternalLoanToken`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L111) (CB-SRC-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf/renewalCallbackNeverPullsExternalLoanToken.conf --rule renewalCallbackNeverPullsExternalLoanToken`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 23`

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
##### ❌ LendMidnightRenewalCallback #24 — Flips the same-market guard from == to !=, so the callback no longer reverts when the source and target markets are identical, and the rule requiring a revert in that case flips to a counterexample.

- **Mutant:** [`certora/mutations/LendMidnightRenewalCallback/24.sol`](./mutations/LendMidnightRenewalCallback/24.sol)
- **Caught by:** [`callbackRevertsForSameSourceMarket`](./specs/callbacks/BorrowMidnightRenewalCallback/many.spec#L293) (CB-SAME-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf/callbackRevertsForSameSourceMarket.conf --rule callbackRevertsForSameSourceMarket`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 24`

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
##### ❌ LendMidnightRenewalCallback #25 — Approves one less than buyerAssets for settlement, so Midnight's pull of the full buyerAssets exceeds the allowance and reverts on every path, making take() always revert and leaving the witness unsatisfiable.

- **Mutant:** [`certora/mutations/LendMidnightRenewalCallback/25.sol`](./mutations/LendMidnightRenewalCallback/25.sol)
- **Caught by:** [`renewalNeverTouchesUnrelatedLenderCredit__satisfy`](./specs/callbacks/LendMidnightRenewalCallback/debug_satisfy/many_satisfy.spec#L164) (CB-DIR-1)
- **Channel:** satisfy-twin — the mutation makes `take()` (or its antecedent branch) revert, so the witness becomes UNSAT (**VIOLATED** = mutant caught); the clean-`src/` witness is proven **SUCCESS**.
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/perf_kill/renewalNeverTouchesUnrelatedLenderCredit.conf --rule renewalNeverTouchesUnrelatedLenderCredit__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 25`

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

#### `LendMidnightToVaultCallback` — `src/callbacks/LendMidnightToVaultCallback.sol`

<a id="m-lendmidnighttovaultcallback-3"></a>
##### ❌ LendMidnightToVaultCallback #3 — The vault-asset check is inverted so a vault whose asset differs from the market loan token is accepted instead of rejected, and the rule that requires such a mismatch to revert finds no revert, flipping its assertion to a counterexample.

- **Mutant:** [`certora/mutations/LendMidnightToVaultCallback/3.sol`](./mutations/LendMidnightToVaultCallback/3.sol)
- **Caught by:** [`vaultAssetMismatchReverts`](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L118)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultAssetMismatchReverts.conf --rule vaultAssetMismatchReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 3`

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
##### ❌ LendMidnightToVaultCallback #7 — The vault deposit is redirected from the seller to the zero address, which reverts as a mint-to-zero on every fill, so take() always reverts and the satisfiability witness showing a lender's credit can be fully closed becomes unsatisfiable.

- **Mutant:** [`certora/mutations/LendMidnightToVaultCallback/7.sol`](./mutations/LendMidnightToVaultCallback/7.sol)
- **Caught by:** [`vaultExitCanFullyCloseCredit`](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L85) (CB-CLOSE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultExitCanFullyCloseCredit.conf --rule vaultExitCanFullyCloseCredit`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 7`

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
##### ❌ LendMidnightToVaultCallback #10 — Doubling the percentage fee makes 100 * fee > assets, exceeding the 1% cap and violating the assertion 100 * fee <= assets.

- **Mutant:** [`certora/mutations/LendMidnightToVaultCallback/10.sol`](./mutations/LendMidnightToVaultCallback/10.sol)
- **Caught by:** [`percentageFeeNeverExceedsAssets`](./specs/callbacks/callbacks.spec#L139) (CB-FEE-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/percentageFeeNeverExceedsAssets.conf --rule percentageFeeNeverExceedsAssets`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 10`

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
##### ❌ LendMidnightToVaultCallback #11 — onSell receiver guard flipped (routing check inverted)

- **Mutant:** [`certora/mutations/LendMidnightToVaultCallback/11.sol`](./mutations/LendMidnightToVaultCallback/11.sol)
- **Caught by:** [`receiverNotCallbackReverts`](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L104)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/receiverNotCallbackReverts.conf --rule receiverNotCallbackReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 11`

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
##### ❌ LendMidnightToVaultCallback #13 — onSell inserts foreign credit redemption on feeRecipient : reduces a bystander's credit

- **Mutant:** [`certora/mutations/LendMidnightToVaultCallback/13.sol`](./mutations/LendMidnightToVaultCallback/13.sol)
- **Caught by:** [`vaultExitNeverTouchesUnrelatedUser`](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L61) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultExitNeverTouchesUnrelatedUser.conf --rule vaultExitNeverTouchesUnrelatedUser`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 13`

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
##### ❌ LendMidnightToVaultCallback #20 — onSell inserts safeTransfer(collateralParams[0].token, Midnight, 1) : moves a non-loanToken, non-vault token with no settlement-fee delta

- **Mutant:** [`certora/mutations/LendMidnightToVaultCallback/20.sol`](./mutations/LendMidnightToVaultCallback/20.sol)
- **Caught by:** [`vaultExitConservesMidnightBalanceMinusFee`](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L17) (CB-SRC-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultExitConservesMidnightBalanceMinusFee.conf --rule vaultExitConservesMidnightBalanceMinusFee`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 20`

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
##### ❌ LendMidnightToVaultCallback #21 — onSell inserts foreign withdrawCollateral on seller : mutates collateral[seller][0], breaks collateral-unchanged

- **Mutant:** [`certora/mutations/LendMidnightToVaultCallback/21.sol`](./mutations/LendMidnightToVaultCallback/21.sol)
- **Caught by:** [`vaultExitLeavesCollateralUnchanged`](./specs/callbacks/LendMidnightToVaultCallback/many.spec#L42)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultExitLeavesCollateralUnchanged.conf --rule vaultExitLeavesCollateralUnchanged`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendMidnightToVaultCallback 21`

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

#### `LendVaultToMidnightCallback` — `src/callbacks/LendVaultToMidnightCallback.sol`

<a id="m-lendvaulttomidnightcallback-4"></a>
##### ❌ LendVaultToMidnightCallback #4 — Inverts the token check from != to ==, so a vault whose asset does not match the market loan token is accepted instead of rejected; the mismatched-vault call no longer reverts and the assert flips to a counterexample.

- **Mutant:** [`certora/mutations/LendVaultToMidnightCallback/4.sol`](./mutations/LendVaultToMidnightCallback/4.sol)
- **Caught by:** [`vaultAssetMismatchReverts`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L170)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultAssetMismatchReverts.conf --rule vaultAssetMismatchReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendVaultToMidnightCallback 4`

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
##### ❌ LendVaultToMidnightCallback #5 — Approving zero assets instead of buyerAssets prevents Midnight from pulling the loan funding, blocking credit increase for the buyer.

- **Mutant:** [`certora/mutations/LendVaultToMidnightCallback/5.sol`](./mutations/LendVaultToMidnightCallback/5.sol)
- **Caught by:** [`vaultFundedLendCanRaiseCredit`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L55)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendCanRaiseCredit.conf --rule vaultFundedLendCanRaiseCredit`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendVaultToMidnightCallback 5`

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
##### ❌ LendVaultToMidnightCallback #7 — onBuy inserts foreign withdrawCollateral on buyer : mutates collateral[buyer][0], breaks collateral-unchanged

- **Mutant:** [`certora/mutations/LendVaultToMidnightCallback/7.sol`](./mutations/LendVaultToMidnightCallback/7.sol)
- **Caught by:** [`vaultFundedLendLeavesCollateralUnchanged`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L36)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendLeavesCollateralUnchanged.conf --rule vaultFundedLendLeavesCollateralUnchanged`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendVaultToMidnightCallback 7`

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
##### ❌ LendVaultToMidnightCallback #9 — onBuy inserts safeTransfer(collateralParams[0].token, Midnight, 1) : moves a non-loanToken, breaking only-moves-loanToken

- **Mutant:** [`certora/mutations/LendVaultToMidnightCallback/9.sol`](./mutations/LendVaultToMidnightCallback/9.sol)
- **Caught by:** [`vaultFundedLendOnlyMovesLoanToken`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L16) (CB-SRC-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendOnlyMovesLoanToken.conf --rule vaultFundedLendOnlyMovesLoanToken`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendVaultToMidnightCallback 9`

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
##### ❌ LendVaultToMidnightCallback #11 — Doubling the fee transfer pushes the fee recipient's loanToken balance delta past the interest-share bound, so lenderFeeBoundedByInterestShare flips to a counterexample.

- **Mutant:** [`certora/mutations/LendVaultToMidnightCallback/11.sol`](./mutations/LendVaultToMidnightCallback/11.sol)
- **Caught by:** [`lenderFeeBoundedByInterestShare`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L98) (CB-RATE-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/perf/lenderFeeBoundedByInterestShare.conf --rule lenderFeeBoundedByInterestShare`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendVaultToMidnightCallback 11`

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
##### ❌ LendVaultToMidnightCallback #12 — Inserts an extra Midnight withdraw call that reduces the fee recipient's credit by one on a successful take, changing an unrelated user's balance and flipping the unrelated-user-untouched assert to a counterexample.

- **Mutant:** [`certora/mutations/LendVaultToMidnightCallback/12.sol`](./mutations/LendVaultToMidnightCallback/12.sol)
- **Caught by:** [`vaultFundedLendNeverTouchesUnrelatedUser`](./specs/callbacks/LendVaultToMidnightCallback/many.spec#L73) (CB-DIR-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendNeverTouchesUnrelatedUser.conf --rule vaultFundedLendNeverTouchesUnrelatedUser`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh LendVaultToMidnightCallback 12`

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

#### `MidnightSupplyCollateralCallback` — `src/callbacks/MidnightSupplyCollateralCallback.sol`

<a id="m-midnightsupplycollateralcallback-1"></a>
##### ❌ MidnightSupplyCollateralCallback #1 — auth guard flipped (!= -> ==)

- **Mutant:** [`certora/mutations/MidnightSupplyCollateralCallback/1.sol`](./mutations/MidnightSupplyCollateralCallback/1.sol)
- **Caught by:** [`callbackRevertsForNonMidnightCaller`](./specs/callbacks/callbacks.spec#L80) (CB-AUTH-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/callbackRevertsForNonMidnightCaller.conf --rule callbackRevertsForNonMidnightCaller`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 1`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -37,7 +37,7 @@
         address receiver,
         bytes memory data
     ) external override returns (bytes32) {
-        if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
+        if (msg.sender == address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();  // MUTATION: auth guard flipped (!= -> ==)
         if (receiver == address(this)) revert CallbackLib.InvalidReceiver();
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
```

<a id="m-midnightsupplycollateralcallback-2"></a>
##### ❌ MidnightSupplyCollateralCallback #2 — zero-amount guard || -> &&

- **Mutant:** [`certora/mutations/MidnightSupplyCollateralCallback/2.sol`](./mutations/MidnightSupplyCollateralCallback/2.sol)
- **Caught by:** [`callbackRevertsOnZeroAssetsOrUnits`](./specs/callbacks/callbacks.spec#L91)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/callbackRevertsOnZeroAssetsOrUnits.conf --rule callbackRevertsOnZeroAssetsOrUnits`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 2`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -39,7 +39,7 @@
     ) external override returns (bytes32) {
         if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
         if (receiver == address(this)) revert CallbackLib.InvalidReceiver();
-        if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
+        if (sellerAssets == 0 && units == 0) revert CallbackLib.ZeroAmount();  // MUTATION: zero-amount guard || -> &&
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
 
```

<a id="m-midnightsupplycollateralcallback-4"></a>
##### ❌ MidnightSupplyCollateralCallback #4 — Removes the length mismatch check, allowing amounts[] array with wrong length to bypass validation

- **Mutant:** [`certora/mutations/MidnightSupplyCollateralCallback/4.sol`](./mutations/MidnightSupplyCollateralCallback/4.sol)
- **Caught by:** [`collateralLengthMismatchReverts`](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L65)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/collateralLengthMismatchReverts.conf --rule collateralLengthMismatchReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 4`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -46,7 +46,7 @@
         if (callbackData.offerSellerAssets == 0) revert CallbackLib.ZeroAmount();
 
         uint256 collateralsLength = market.collateralParams.length;
-        if (callbackData.amounts.length != collateralsLength) revert CallbackLib.InvalidCollateral();
+        // if (callbackData.amounts.length != collateralsLength) revert CallbackLib.InvalidCollateral();  // MUTATION: Removes the length mismatch check, allowing amounts[] a
 
         uint256[] memory collateralAmounts = new uint256[](collateralsLength);
 
```

<a id="m-midnightsupplycollateralcallback-9"></a>
##### ❌ MidnightSupplyCollateralCallback #9 — supplyCollateral amount forced to 0: position collateral never rises, satisfy witness gone

- **Mutant:** [`certora/mutations/MidnightSupplyCollateralCallback/9.sol`](./mutations/MidnightSupplyCollateralCallback/9.sol)
- **Caught by:** [`supplyCanRaiseCollateral`](./specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L88)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/supplyCanRaiseCollateral.conf --rule supplyCanRaiseCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 9`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -59,7 +59,7 @@
                     address token = market.collateralParams[i].token;
                     SafeTransferLib.safeTransferFrom(token, seller, address(this), supplyAmount);
                     IERC20(token).forceApprove(address(MORPHO_MIDNIGHT), supplyAmount);
-                    MORPHO_MIDNIGHT.supplyCollateral(market, i, supplyAmount, seller);
+                    MORPHO_MIDNIGHT.supplyCollateral(market, i, 0, seller);  // MUTATION: supplyCollateral amount forced to 0: position collatera
                 }
                 collateralAmounts[i] = supplyAmount;
             }
```

<a id="m-midnightsupplycollateralcallback-10"></a>
##### ❌ MidnightSupplyCollateralCallback #10 — onSell receiver guard flipped (routing check inverted)

- **Mutant:** [`certora/mutations/MidnightSupplyCollateralCallback/10.sol`](./mutations/MidnightSupplyCollateralCallback/10.sol)
- **Caught by:** [`receiverIsCallbackReverts`](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L93)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/receiverIsCallbackReverts.conf --rule receiverIsCallbackReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 10`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -38,7 +38,7 @@
         bytes memory data
     ) external override returns (bytes32) {
         if (msg.sender != address(MORPHO_MIDNIGHT)) revert CallbackLib.OnlyMidnight();
-        if (receiver == address(this)) revert CallbackLib.InvalidReceiver();
+        if (receiver != address(this)) revert CallbackLib.InvalidReceiver();  // MUTATION: onSell receiver guard flipped (routing check inverted)
         if (sellerAssets == 0 || units == 0) revert CallbackLib.ZeroAmount();
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
```

<a id="m-midnightsupplycollateralcallback-13"></a>
##### ❌ MidnightSupplyCollateralCallback #13 — supply amount zeroed: no collateral ever reaches the seller, so the max-capacity fill witness goes UNSAT (VIOLATED = caught).

- **Mutant:** [`certora/mutations/MidnightSupplyCollateralCallback/13.sol`](./mutations/MidnightSupplyCollateralCallback/13.sol)
- **Caught by:** [`maxBorrowCapacityUsageFillReachable`](./specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L63)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/maxBorrowCapacityUsageFillReachable.conf --rule maxBorrowCapacityUsageFillReachable`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 13`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -59,7 +59,7 @@
                     address token = market.collateralParams[i].token;
                     SafeTransferLib.safeTransferFrom(token, seller, address(this), supplyAmount);
                     IERC20(token).forceApprove(address(MORPHO_MIDNIGHT), supplyAmount);
-                    MORPHO_MIDNIGHT.supplyCollateral(market, i, supplyAmount, seller);
+                    MORPHO_MIDNIGHT.supplyCollateral(market, i, 0, seller);  // MUTATION: coverage maxBorrowCapacityUsageFillReachable
                 }
                 collateralAmounts[i] = supplyAmount;
             }
```

<a id="m-midnightsupplycollateralcallback-14"></a>
##### ❌ MidnightSupplyCollateralCallback #14 — Changes the zero-amount guard to reject 1 instead of 0, so a zero offerSellerAssets denominator is now accepted; the rule requiring a zero offerSellerAssets to revert is violated.

- **Mutant:** [`certora/mutations/MidnightSupplyCollateralCallback/14.sol`](./mutations/MidnightSupplyCollateralCallback/14.sol)
- **Caught by:** [`offerSellerAssetsZeroReverts`](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L79)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/offerSellerAssetsZeroReverts.conf --rule offerSellerAssetsZeroReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 14`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -43,7 +43,7 @@
 
         CallbackData memory callbackData = abi.decode(data, (CallbackData));
 
-        if (callbackData.offerSellerAssets == 0) revert CallbackLib.ZeroAmount();
+        if (callbackData.offerSellerAssets == 1) revert CallbackLib.ZeroAmount();  // MUTATION: coverage offerSellerAssetsZeroReverts
 
         uint256 collateralsLength = market.collateralParams.length;
         if (callbackData.amounts.length != collateralsLength) revert CallbackLib.InvalidCollateral();
```

<a id="m-midnightsupplycollateralcallback-18"></a>
##### ❌ MidnightSupplyCollateralCallback #18 — pro-rata supplyAmount operands swapped (fill/cap inverted) : partial fill supplies MORE than the configured per-slot amount

- **Mutant:** [`certora/mutations/MidnightSupplyCollateralCallback/18.sol`](./mutations/MidnightSupplyCollateralCallback/18.sol)
- **Caught by:** [`proRataUpperBound`](./specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L8)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/proRataUpperBound.conf --rule proRataUpperBound`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 18`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -54,7 +54,7 @@
             uint256 configAmount = callbackData.amounts[i];
 
             if (configAmount > 0) {
-                uint256 supplyAmount = configAmount.mulDivDown(sellerAssets, callbackData.offerSellerAssets);
+                uint256 supplyAmount = configAmount.mulDivDown(callbackData.offerSellerAssets, sellerAssets); // MUTATION: pro-rata operands swapped
                 if (supplyAmount > 0) {
                     address token = market.collateralParams[i].token;
                     SafeTransferLib.safeTransferFrom(token, seller, address(this), supplyAmount);
```

<a id="m-midnightsupplycollateralcallback-20"></a>
##### ❌ MidnightSupplyCollateralCallback #20 — supplyCollateral beneficiary seller -> receiver : a bystander's collateral is credited by the supply

- **Mutant:** [`certora/mutations/MidnightSupplyCollateralCallback/20.sol`](./mutations/MidnightSupplyCollateralCallback/20.sol)
- **Caught by:** [`bystanderUntouched`](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L36)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/bystanderUntouched.conf --rule bystanderUntouched`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 20`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -59,7 +59,7 @@
                     address token = market.collateralParams[i].token;
                     SafeTransferLib.safeTransferFrom(token, seller, address(this), supplyAmount);
                     IERC20(token).forceApprove(address(MORPHO_MIDNIGHT), supplyAmount);
-                    MORPHO_MIDNIGHT.supplyCollateral(market, i, supplyAmount, seller);
+                    MORPHO_MIDNIGHT.supplyCollateral(market, i, supplyAmount, receiver); // MUTATION: supply beneficiary seller -> receiver
                 }
                 collateralAmounts[i] = supplyAmount;
             }
```

<a id="m-midnightsupplycollateralcallback-21"></a>
##### ❌ MidnightSupplyCollateralCallback #21 — supplyCollateral -> withdrawCollateral : the callback withdraws, so the seller's collateral DECREASES

- **Mutant:** [`certora/mutations/MidnightSupplyCollateralCallback/21.sol`](./mutations/MidnightSupplyCollateralCallback/21.sol)
- **Caught by:** [`supplyMonotoneCollateral`](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L14)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/supplyMonotoneCollateral.conf --rule supplyMonotoneCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 21`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -59,7 +59,7 @@
                     address token = market.collateralParams[i].token;
                     SafeTransferLib.safeTransferFrom(token, seller, address(this), supplyAmount);
                     IERC20(token).forceApprove(address(MORPHO_MIDNIGHT), supplyAmount);
-                    MORPHO_MIDNIGHT.supplyCollateral(market, i, supplyAmount, seller);
+                    MORPHO_MIDNIGHT.withdrawCollateral(market, i, supplyAmount, seller, address(this)); // MUTATION: supply -> withdraw
                 }
                 collateralAmounts[i] = supplyAmount;
             }
```

<a id="m-midnightsupplycollateralcallback-23"></a>
##### ❌ MidnightSupplyCollateralCallback #23 — Flips the cap check from greater-than to less-than, so a borrow-capacity usage above the maximum no longer reverts; the rule asserting usage stays within the cap is violated on the non-reverting path.

- **Mutant:** [`certora/mutations/MidnightSupplyCollateralCallback/23.sol`](./mutations/MidnightSupplyCollateralCallback/23.sol)
- **Caught by:** [`borrowCapacityUsageWithinCap`](./specs/callbacks/MidnightSupplyCollateralCallback/one.spec#L34) (CB-SC-CAP-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/borrowCapacityUsageWithinCap.conf --rule borrowCapacityUsageWithinCap`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyCollateralCallback 23`

```diff
--- a/src/callbacks/MidnightSupplyCollateralCallback.sol
+++ b/src/callbacks/MidnightSupplyCollateralCallback.sol
@@ -70,7 +70,7 @@
 
         if (callbackData.maxBorrowCapacityUsage > 0) {
             uint256 borrowCapacityUsage = _borrowCapacityUsage(market, seller, marketId);
-            if (borrowCapacityUsage > callbackData.maxBorrowCapacityUsage) {
+            if (borrowCapacityUsage < callbackData.maxBorrowCapacityUsage) { // MUTATION: rebased
                 revert CallbackLib.InvalidBorrowCapacityUsage();
             }
         }
```

#### `MidnightSupplyVaultSharesCallback` — `src/callbacks/MidnightSupplyVaultSharesCallback.sol`

<a id="m-midnightsupplyvaultsharescallback-4"></a>
##### ❌ MidnightSupplyVaultSharesCallback #4 — Removing the vault asset validation allows a vault with mismatched underlying asset to pass through, breaking the rule that requires reverts on asset mismatch

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/4.sol`](./mutations/MidnightSupplyVaultSharesCallback/4.sol)
- **Caught by:** [`vaultAssetMismatchReverts`](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L89)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/vaultAssetMismatchReverts.conf --rule vaultAssetMismatchReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 4`

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
##### ❌ MidnightSupplyVaultSharesCallback #5 — Removing the collateral index validation allows a vault not listed at the configured index to proceed, violating the rule that requires reverts when vault is not at its index

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/5.sol`](./mutations/MidnightSupplyVaultSharesCallback/5.sol)
- **Caught by:** [`vaultNotAtIndexReverts`](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L104)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/vaultNotAtIndexReverts.conf --rule vaultNotAtIndexReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 5`

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
##### ❌ MidnightSupplyVaultSharesCallback #8 — wrong deposit amount: deposit(0) instead of deposit(totalDeposit) -> zero shares minted

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/8.sol`](./mutations/MidnightSupplyVaultSharesCallback/8.sol)
- **Caught by:** [`supplyCanRaiseVaultCollateral`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/supplyCanRaiseVaultCollateral.conf --rule supplyCanRaiseVaultCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 8`

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
##### ❌ MidnightSupplyVaultSharesCallback #9 — vault-share supply amount forced to 0: position collateral never rises, satisfy witness gone

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/9.sol`](./mutations/MidnightSupplyVaultSharesCallback/9.sol)
- **Caught by:** [`supplyCanRaiseVaultCollateral`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/supplyCanRaiseVaultCollateral.conf --rule supplyCanRaiseVaultCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 9`

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
##### ❌ MidnightSupplyVaultSharesCallback #10 — receiver guard != -> == : onSell no longer reverts when receiver isn't the callback (proceeds strand)

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/10.sol`](./mutations/MidnightSupplyVaultSharesCallback/10.sol)
- **Caught by:** [`receiverNotCallbackReverts`](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L124)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/receiverNotCallbackReverts.conf --rule receiverNotCallbackReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 10`

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
##### ❌ MidnightSupplyVaultSharesCallback #11 — supplyCollateral amount shares -> shares-1 : one minted vault share is stranded, collateral delta != minted shares

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/11.sol`](./mutations/MidnightSupplyVaultSharesCallback/11.sol)
- **Caught by:** [`suppliedSharesMatchMintedShares`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L33)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/suppliedSharesMatchMintedShares.conf --rule suppliedSharesMatchMintedShares`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 11`

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
##### ❌ MidnightSupplyVaultSharesCallback #12 — supplyCollateral -> withdrawCollateral : the callback withdraws, so the seller's collateral DECREASES

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/12.sol`](./mutations/MidnightSupplyVaultSharesCallback/12.sol)
- **Caught by:** [`supplyMonotoneCollateral`](./specs/callbacks/MidnightSupplyCollateralCallback/many.spec#L14)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/perf/supplyMonotoneCollateral.conf --rule supplyMonotoneCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 12`

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
##### ❌ MidnightSupplyVaultSharesCallback #13 — inserted unconditional seller pull : loanToken is pulled from the seller even when additionalDepositPercent == 0

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/13.sol`](./mutations/MidnightSupplyVaultSharesCallback/13.sol)
- **Caught by:** [`noExtraPullWhenPercentZero`](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L65)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/noExtraPullWhenPercentZero.conf --rule noExtraPullWhenPercentZero`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 13`

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
##### ❌ MidnightSupplyVaultSharesCallback #14 — onSell supplies to collateralIndex+1 (a non-vault slot) instead of the pinned vault slot : a non-vault collateral slot receives supply

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/14.sol`](./mutations/MidnightSupplyVaultSharesCallback/14.sol)
- **Caught by:** [`onlyVaultSlotReceivesSupply`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L7)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/onlyVaultSlotReceivesSupply.conf --rule onlyVaultSlotReceivesSupply`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 14`

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
##### ❌ MidnightSupplyVaultSharesCallback #15 — onSell supplies vault shares onBehalf of loanToken instead of seller : the vault-share beneficiary is not the seller

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/15.sol`](./mutations/MidnightSupplyVaultSharesCallback/15.sol)
- **Caught by:** [`vaultShareBeneficiaryIsSeller`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L59)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/vaultShareBeneficiaryIsSeller.conf --rule vaultShareBeneficiaryIsSeller`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 15`

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
##### ❌ MidnightSupplyVaultSharesCallback #18 — Credits the supplied vault shares as collateral to the callback contract instead of the seller, so the seller's collateral never increases and the witness proving a supply can raise the seller's collateral becomes unsatisfiable.

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/18.sol`](./mutations/MidnightSupplyVaultSharesCallback/18.sol)
- **Caught by:** [`supplyCanRaiseVaultCollateral`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/supplyCanRaiseVaultCollateral.conf --rule supplyCanRaiseVaultCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 18`

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
##### ❌ MidnightSupplyVaultSharesCallback #20 — Supplying the vault shares on behalf of the callback instead of the seller credits the callback's own Midnight position, so the seller's collateral never rises and the witness that a vault-supply take can raise the seller's collateral vanishes.

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/20.sol`](./mutations/MidnightSupplyVaultSharesCallback/20.sol)
- **Caught by:** [`supplyCanRaiseVaultCollateral`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L79)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/supplyCanRaiseVaultCollateral.conf --rule supplyCanRaiseVaultCollateral`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 20`

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
##### ❌ MidnightSupplyVaultSharesCallback #21 — Adding one to the additional-deposit amount pulled from the seller overshoots the percent formula by a unit on every positive-percent take, so extraPullMatchesPercentFormula flips to a counterexample.

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/21.sol`](./mutations/MidnightSupplyVaultSharesCallback/21.sol)
- **Caught by:** [`extraPullMatchesPercentFormula`](./specs/callbacks/MidnightSupplyVaultSharesCallback/one.spec#L102)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/perf/extraPullMatchesPercentFormula.conf --rule extraPullMatchesPercentFormula`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 21`

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
##### ❌ MidnightSupplyVaultSharesCallback #22 — Supplying the vault shares on behalf of the loan token address instead of the seller credits an unrelated third account's Midnight position, so a bystander's collateral rises and the rule that a supply take never touches a bystander's position produces a counterexample.

- **Mutant:** [`certora/mutations/MidnightSupplyVaultSharesCallback/22.sol`](./mutations/MidnightSupplyVaultSharesCallback/22.sol)
- **Caught by:** [`bystanderUntouched`](./specs/callbacks/MidnightSupplyVaultSharesCallback/many.spec#L36)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/bystanderUntouched.conf --rule bystanderUntouched`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightSupplyVaultSharesCallback 22`

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

#### `MidnightWithdrawVaultSharesCallback` — `src/callbacks/MidnightWithdrawVaultSharesCallback.sol`

<a id="m-midnightwithdrawvaultsharescallback-1"></a>
##### ❌ MidnightWithdrawVaultSharesCallback #1 — off-by-one over-withdraw: sharesToWithdraw + 1 leaves a residual vault share in the callback

- **Mutant:** [`certora/mutations/MidnightWithdrawVaultSharesCallback/1.sol`](./mutations/MidnightWithdrawVaultSharesCallback/1.sol)
- **Caught by:** [`takeLeavesVaultShareBalanceUnchanged`](./specs/callbacks/MidnightWithdrawVaultSharesCallback/many.spec#L32) (CB-VAULT-WD-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/takeLeavesVaultShareBalanceUnchanged.conf --rule takeLeavesVaultShareBalanceUnchanged`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightWithdrawVaultSharesCallback 1`

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
##### ❌ MidnightWithdrawVaultSharesCallback #2 — leave 1 wei allowance to Midnight (approve buyerAssets+1)

- **Mutant:** [`certora/mutations/MidnightWithdrawVaultSharesCallback/2.sol`](./mutations/MidnightWithdrawVaultSharesCallback/2.sol)
- **Caught by:** [`callbackHoldsZeroAllowance`](./specs/callbacks/callbacks.spec#L7) (CB-DUST-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/callbackHoldsZeroAllowance.conf --rule callbackHoldsZeroAllowance`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightWithdrawVaultSharesCallback 2`

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
##### ❌ MidnightWithdrawVaultSharesCallback #5 — Withdrawing 0 collateral instead of the computed amount prevents collateral reduction; the assertion that collateral < collateralBefore fails.

- **Mutant:** [`certora/mutations/MidnightWithdrawVaultSharesCallback/5.sol`](./mutations/MidnightWithdrawVaultSharesCallback/5.sol)
- **Caught by:** [`takeCanDropCollateralOnNarrowedMarket`](./specs/callbacks/MidnightWithdrawVaultSharesCallback/many.spec#L14) (CB-VAULT-WD-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/takeCanDropCollateralOnNarrowedMarket.conf --rule takeCanDropCollateralOnNarrowedMarket`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightWithdrawVaultSharesCallback 5`

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
##### ❌ MidnightWithdrawVaultSharesCallback #6 — Withdrawing only half the assets leaves the callback holding half of the vault shares; the assertion that callback balance == 0 fails.

- **Mutant:** [`certora/mutations/MidnightWithdrawVaultSharesCallback/6.sol`](./mutations/MidnightWithdrawVaultSharesCallback/6.sol)
- **Caught by:** [`callbackNeverHoldsTokens`](./specs/callbacks/callbacks.spec#L57) (CB-DUST-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/callbackNeverHoldsTokens.conf --rule callbackNeverHoldsTokens`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightWithdrawVaultSharesCallback 6`

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
##### ❌ MidnightWithdrawVaultSharesCallback #8 — The callback approves Midnight for zero loanToken instead of buyerAssets, so Midnight cannot pull the funds and take() reverts, leaving the rule unable to witness a successful withdraw fill.

- **Mutant:** [`certora/mutations/MidnightWithdrawVaultSharesCallback/8.sol`](./mutations/MidnightWithdrawVaultSharesCallback/8.sol)
- **Caught by:** [`takeLeavesVaultShareBalanceUnchanged__satisfy`](./specs/callbacks/MidnightWithdrawVaultSharesCallback/debug_satisfy/many_satisfy.spec#L74) (CB-VAULT-WD-1)
- **Channel:** satisfy-twin — the mutation makes `take()` (or its antecedent branch) revert, so the witness becomes UNSAT (**VIOLATED** = mutant caught); the clean-`src/` witness is proven **SUCCESS**.
- **Run without the mutation (clean `src/` → witness FOUND, `SUCCESS`):** `certoraRun certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/debug_satisfy/takeLeavesVaultShareBalanceUnchanged.conf --rule takeLeavesVaultShareBalanceUnchanged__satisfy`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MidnightWithdrawVaultSharesCallback 8`

```diff
--- a/src/callbacks/MidnightWithdrawVaultSharesCallback.sol
+++ b/src/callbacks/MidnightWithdrawVaultSharesCallback.sol
@@ -59,7 +59,7 @@
 
         IERC4626(callbackData.vault).withdraw(buyerAssets, address(this), address(this));
 
-        IERC20(market.loanToken).forceApprove(msg.sender, buyerAssets);
+        IERC20(market.loanToken).forceApprove(msg.sender, 0); // MUTATION: approve 0 -> Midnight cannot pull loanToken -> take reverts
 
         emit VaultSharesWithdrawn(buyer, marketId, callbackData.vault, buyerAssets, sharesToWithdraw);
 
```

#### `MigrationRatifier` — `src/ratifiers/MigrationRatifier.sol`

<a id="m-migrationratifier-2"></a>
##### [❌](https://prover.certora.com/output/52567/438dd54ed58d4ee1909c036c5cc878e8?anonymousKey=7d997b536668f99fba68328ddb0ad04b90a215d9) MigrationRatifier #2 — Comment out the assignment so setParams does not actually write the tuple, breaking the storage fidelity invariant

- **Mutant:** [`certora/mutations/MigrationRatifier/2.sol`](./mutations/MigrationRatifier/2.sol)
- **Caught by:** [`setParamsWritesTupleAndLeavesOthers`](./specs/ratifier/unit.spec#L28) (ORCH-15, REG-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule setParamsWritesTupleAndLeavesOthers`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MigrationRatifier 2`

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
##### [❌](https://prover.certora.com/output/52567/083f195bf7634d0ca780a1fcc506a262?anonymousKey=97013cc2674fa074a07f8754de8dde4d06146645) MigrationRatifier #3 — Comment out the delete statement so clearParams does not actually zero the tuple, breaking the clear invariant

- **Mutant:** [`certora/mutations/MigrationRatifier/3.sol`](./mutations/MigrationRatifier/3.sol)
- **Caught by:** [`clearParamsZeroesTupleAndLeavesOthers`](./specs/ratifier/unit.spec#L56) (REG-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule clearParamsZeroesTupleAndLeavesOthers`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MigrationRatifier 3`

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
##### [❌](https://prover.certora.com/output/52567/1c8cac9468f74900bf5711aee5815938?anonymousKey=ad2166a5990d588b5d553d2df7f8ceb78c770e3d) MigrationRatifier #5 — ratifierData market-match guard flipped != to == : accepts a source-market mismatch

- **Mutant:** [`certora/mutations/MigrationRatifier/5.sol`](./mutations/MigrationRatifier/5.sol)
- **Caught by:** [`ratifierDataMustMatchCallbackMarkets`](./specs/ratifier/revert.spec#L168) (DEFAULT-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule ratifierDataMustMatchCallbackMarkets`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MigrationRatifier 5`

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
##### [❌](https://prover.certora.com/output/52567/97f849a9e2ce491494beecfd2b65f8e2?anonymousKey=27df4b54c6e1e82a196fa8b3fea47d7613476328) MigrationRatifier #8 — auth guard short-circuited to false: caller can change params on behalf of an unauthorizing owner

- **Mutant:** [`certora/mutations/MigrationRatifier/8.sol`](./mutations/MigrationRatifier/8.sol)
- **Caught by:** [`userParamsChangeRequiresAuthorization`](./specs/ratifier/access_control.spec#L26) (REG-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/access_control.conf --rule userParamsChangeRequiresAuthorization`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MigrationRatifier 8`

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
##### [❌](https://prover.certora.com/output/52567/7ef137b75cda4408b3af6cf0d969acb3?anonymousKey=45a9b0082422c52a440e4ad075ec6f0dc96615b0) MigrationRatifier #9 — invalid-length guard != -> == : accepts non-64-byte ratifierData

- **Mutant:** [`certora/mutations/MigrationRatifier/9.sol`](./mutations/MigrationRatifier/9.sol)
- **Caught by:** [`invalidRatifierDataLengthReverts`](./specs/ratifier/revert.spec#L8)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule invalidRatifierDataLengthReverts`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MigrationRatifier 9`

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
##### [❌](https://prover.certora.com/output/52567/32202d6cf9154da79448d2c988576493?anonymousKey=940b953caa09f948f490bc6f6b9a7956de2a4259) MigrationRatifier #10 — pinned-receiver guard != -> == : accepts unpinned receiver

- **Mutant:** [`certora/mutations/MigrationRatifier/10.sol`](./mutations/MigrationRatifier/10.sol)
- **Caught by:** [`makerReceiverMustBePinned`](./specs/ratifier/revert.spec#L23)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule makerReceiverMustBePinned`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MigrationRatifier 10`

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
##### [❌](https://prover.certora.com/output/52567/e6bda177f7d3491aa2324f16513f60d8?anonymousKey=71fedf9a7bb18455f150ba0eb38648c34b46ede5) MigrationRatifier #11 — group-namespace guard != -> == : accepts out-of-namespace group

- **Mutant:** [`certora/mutations/MigrationRatifier/11.sol`](./mutations/MigrationRatifier/11.sol)
- **Caught by:** [`migrationGroupNamespaceEnforced`](./specs/ratifier/revert.spec#L42)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/revert.conf --rule migrationGroupNamespaceEnforced`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MigrationRatifier 11`

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
##### [❌](https://prover.certora.com/output/52567/496b7a0dd50a4e1c9ae7d2a080495518?anonymousKey=ebd50303d3660958a0dc7d17d1a62538775a29e5) MigrationRatifier #12 — isRatified key swap [src][tgt]->[tgt][src]: reads a non-addressed tuple

- **Mutant:** [`certora/mutations/MigrationRatifier/12.sol`](./mutations/MigrationRatifier/12.sol)
- **Caught by:** [`isRatifiedReadsOnlyAddressedParams`](./specs/ratifier/highlevel.spec#L252)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule isRatifiedReadsOnlyAddressedParams`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MigrationRatifier 12`

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
##### [❌](https://prover.certora.com/output/52567/02ffeb8d37c0414c929e2dd07ec02b9f?anonymousKey=361b5f298725fb03cc1cc5fe0422e1d6a9c4de4d) MigrationRatifier #13 — Replace the success-token return with bytes32(0) so an accepting isRatified no longer produces the CALLBACK_SUCCESS value take() requires

- **Mutant:** [`certora/mutations/MigrationRatifier/13.sol`](./mutations/MigrationRatifier/13.sol)
- **Caught by:** [`isRatifiedReturnsCallbackSuccess`](./specs/ratifier/unit.spec#L247)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule isRatifiedReturnsCallbackSuccess`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh MigrationRatifier 13`

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

#### `PriceLib` — `src/libraries/PriceLib.sol`

<a id="m-pricelib-1"></a>
##### [❌](https://prover.certora.com/output/52567/5b62b96cee994b09a7533863b8137b7e?anonymousKey=1263c5f3df6a931c66155de9c25891f73a7955c9) PriceLib #1 — swapped buyer/seller rounding (mulDivDown<->mulDivUp)

- **Mutant:** [`certora/mutations/PriceLib/1.sol`](./mutations/PriceLib/1.sol)
- **Caught by:** [`priceFollowsZeroCouponFormula`](./specs/ratifier/unit.spec#L98) (PRICE-1) · [`priceRoundsInProtectedUserFavor`](./specs/ratifier/unit.spec#L115) (PRICE-2)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule priceFollowsZeroCouponFormula priceRoundsInProtectedUserFavor`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh PriceLib 1`

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
##### [❌](https://prover.certora.com/output/52567/3cff95f3c9b149ae9722325495d721db?anonymousKey=f602d9e75e3fb2e9c66026017f7281548a4c4a8f) PriceLib #2 — denominator rate*dur -> rate+dur (formula broken, rounding intact)

- **Mutant:** [`certora/mutations/PriceLib/2.sol`](./mutations/PriceLib/2.sol)
- **Caught by:** [`priceFollowsZeroCouponFormula`](./specs/ratifier/unit.spec#L98) (PRICE-1)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule priceFollowsZeroCouponFormula`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh PriceLib 2`

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
##### [❌](https://prover.certora.com/output/52567/367e91364af64ab982e032e4aee9793f?anonymousKey=ec161b6884775a84eca54c0f4a99d6a596539433) PriceLib #3 — computeEffectiveRate buy-side max->min (> to <)

- **Mutant:** [`certora/mutations/PriceLib/3.sol`](./mutations/PriceLib/3.sol)
- **Caught by:** [`effectiveRateSelectsTighterBound`](./specs/ratifier/unit.spec#L123) (PRICE-3)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule effectiveRateSelectsTighterBound`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh PriceLib 3`

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
##### [❌](https://prover.certora.com/output/52567/edb6ed92a3174a89b8e82ac6d6df1e0b?anonymousKey=9401f4f1a7788b0be7abc18fd3ec2166554140aa) PriceLib #4 — satisfiesRateLimit lender <= to >= [same diff as PriceLib#9, re-proven under highlevel.conf]

- **Mutant:** [`certora/mutations/PriceLib/4.sol`](./mutations/PriceLib/4.sol)
- **Caught by:** [`satisfiesRateLimitComparisonDirection`](./specs/ratifier/unit.spec#L133) (PRICE-4) · [`satisfiesRateLimitMonotoneInLenderLimit`](./specs/ratifier/unit.spec#L225)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule satisfiesRateLimitComparisonDirection satisfiesRateLimitMonotoneInLenderLimit`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh PriceLib 4`

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
##### [❌](https://prover.certora.com/output/52567/cb669a975bc74282867b2a38630db50e?anonymousKey=439773a3f0aa545ee2251413f718b344b701aeb6) PriceLib #7 — borrower compare >= -> <= (copy-paste of lender branch): inverts limit-monotonicity [same diff as PriceLib#8, re-proven under highlevel.conf]

- **Mutant:** [`certora/mutations/PriceLib/7.sol`](./mutations/PriceLib/7.sol)
- **Caught by:** [`satisfiesRateLimitMonotoneInBorrowerLimit`](./specs/ratifier/unit.spec#L200) · [`satisfiesRateLimitComparisonDirection`](./specs/ratifier/unit.spec#L133) (PRICE-4)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule satisfiesRateLimitMonotoneInBorrowerLimit satisfiesRateLimitComparisonDirection`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh PriceLib 7`

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
##### [❌](https://prover.certora.com/output/52567/89fb620748dd41c7b8e29b1ea0567f63?anonymousKey=dffb590f4a93940f1f20dd8362df564f1b99dd60) PriceLib #8 — borrower rate-limit compare >= -> <= : breaks gate-vs-reconstruction binding [same diff as PriceLib#7, re-proven under unit.conf]

- **Mutant:** [`certora/mutations/PriceLib/8.sol`](./mutations/PriceLib/8.sol)
- **Caught by:** [`higherFeeOnlyTightensBorrowerRateGate`](./specs/ratifier/highlevel.spec#L126)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule higherFeeOnlyTightensBorrowerRateGate`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh PriceLib 8`

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
##### [❌](https://prover.certora.com/output/52567/7dc8e769158c49b5ad10e35825fc9ee7?anonymousKey=52dc64b64d5b6a4437d95dacffa29af175f96294) PriceLib #9 — lender rate-limit compare <= -> >= : breaks gate-vs-reconstruction binding [same diff as PriceLib#4, re-proven under unit.conf]

- **Mutant:** [`certora/mutations/PriceLib/9.sol`](./mutations/PriceLib/9.sol)
- **Caught by:** [`higherFeeOnlyTightensLenderRateGate`](./specs/ratifier/highlevel.spec#L205)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/highlevel.conf --rule higherFeeOnlyTightensLenderRateGate`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh PriceLib 9`

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

#### `RouterLib` — `src/libraries/RouterLib.sol`

<a id="m-routerlib-1"></a>
##### [❌](https://prover.certora.com/output/52567/589fc5e7943e461aa67b0e4d13861dcb?anonymousKey=cca399b6f23aeed32e3fba6876fc610f5ef53bc1) RouterLib #1 — net-seller min -> max : breaks fee-monotone-decreasing

- **Mutant:** [`certora/mutations/RouterLib/1.sol`](./mutations/RouterLib/1.sol)
- **Caught by:** [`netSellerPriceMonotoneInFee`](./specs/ratifier/unit.spec#L188)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule netSellerPriceMonotoneInFee`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh RouterLib 1`

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
##### [❌](https://prover.certora.com/output/52567/6386e7b709b74138912d9fc8ada48702?anonymousKey=6e2677d1162eeeb418a8a9809f4440a976f6c2aa) RouterLib #2 — net-buyer max -> min : breaks fee-monotone-increasing

- **Mutant:** [`certora/mutations/RouterLib/2.sol`](./mutations/RouterLib/2.sol)
- **Caught by:** [`netBuyerPriceMonotoneInFee`](./specs/ratifier/unit.spec#L213)
- **Run without the mutation (clean `src/` → `VERIFIED`):** `certoraRun certora/confs/ratifier/unit.conf --rule netBuyerPriceMonotoneInFee`
- **Run with the mutation (rule `VIOLATED` = mutant caught):** `./certora/mutations/run_mutation.sh RouterLib 2`

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

<div style="page-break-before: always;"></div>

---

## Setup and Execution

The Certora Prover runs remotely (Certora's cloud) or locally (built from source); both modes share setup steps 1-5.

### Common Setup (Steps 1-5)

The instructions below are for Ubuntu 24.04. For step-by-step installation details refer to this setup [tutorial](https://alexzoid.com/first-steps-with-certora-fv-catching-a-real-bug#heading-setup).

All `certoraRun` commands are executed from the repository root at the audit commit, with the git submodules initialized first (the scenes compile sources out of `lib/midnight`, `lib/morpho-blue`, `lib/vault-v2`, and their transitive dependencies):

```bash
git submodule update --init --recursive
```

1. Install Java (tested with JDK 21)

```bash
sudo apt update
sudo apt install default-jre
java -version
```

2. Install [pipx](https://pipx.pypa.io/)

```bash
sudo apt install pipx
pipx ensurepath
```

3. Install Certora CLI. To match the prover version used for this audit, pin it explicitly

```bash
pipx install certora-cli==8.16.2
```

4. Install solc-select and the Solidity compiler versions required by the project (0.8.34 for the callbacks and the Midnight model, 0.8.19 for the Morpho Blue model, 0.8.28 for the Morpho Vault V2 target used by the four vault-touching callbacks)

```bash
pipx install solc-select
solc-select install 0.8.34
solc-select install 0.8.28
solc-select install 0.8.19
solc-select use 0.8.34
```

5. Create versioned solc symlinks for Certora. Configuration files reference the compiler as `solc0.8.34` / `solc0.8.28` / `solc0.8.19` (without dashes), but solc-select only creates a generic `solc` binary:

```bash
mkdir -p ~/.local/bin
ln -sf ~/.solc-select/artifacts/solc-0.8.34/solc-0.8.34 ~/.local/bin/solc0.8.34
ln -sf ~/.solc-select/artifacts/solc-0.8.28/solc-0.8.28 ~/.local/bin/solc0.8.28
ln -sf ~/.solc-select/artifacts/solc-0.8.19/solc-0.8.19 ~/.local/bin/solc0.8.19
```

Verify `~/.local/bin` is in your `PATH`. If not, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Remote Execution

Set up a Certora key. You can get a free key through the Certora [Discord](https://discord.gg/certora) or on their website. Once you have it, export it:

```bash
echo "export CERTORAKEY=<your_certora_api_key>" >> ~/.bashrc
```

> **Note:** If a local prover is installed (see below), it takes priority. To force remote execution, add the `--server production` flag:
> ```bash
> certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendCanRaiseCredit.conf --server production
> ```

### Local Execution

Follow the full build instructions in the [CertoraProver repository (v8.16.2)](https://github.com/Certora/CertoraProver/tree/8.16.2).

1. Install prerequisites

```bash
# JDK 19+
sudo apt install openjdk-21-jdk

# SMT solvers (z3 and cvc5 are required, others are optional)
# Download binaries and place them in PATH:
#   z3:   https://github.com/Z3Prover/z3/releases
#   cvc5: https://github.com/cvc5/cvc5/releases

# LLVM tools
sudo apt install llvm

# Rust 1.81.0+
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
cargo install rustfilt

# Graphviz (optional, for visual reports)
sudo apt install graphviz
```

2. Set up build output directory

```bash
export CERTORA="$HOME/CertoraProver/target/installed/"
mkdir -p "$CERTORA"
export PATH="$CERTORA:$PATH"
```

3. Clone and build

```bash
git clone --recurse-submodules https://github.com/Certora/CertoraProver.git
cd CertoraProver
git checkout tags/8.16.2
./gradlew assemble
```

4. Verify installation with test example

```bash
certoraRun.py -h
cd Public/TestEVM/Counter
certoraRun counter.conf
```

### Running Verification

Every property has its own configuration file under `certora/confs/callbacks/<Callback>/<ruleName>.conf` (flat, single make-on-behalf scenario). The listings below show the callback-specific confs; the applicable [shared safety-rule](#shared-safety-rules) confs live in the same directory and are re-verified under each callback's setup. Non-vacuity is covered by the `debug_satisfy` channel plus advanced-sanity runs; the `debug_advanced*` subdirectories are sanity tooling, not part of the proof suite.

#### BorrowBlueToMidnightCallback (BBM)

```bash
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/borrowerFeeBoundedByInterestShare.conf
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/clearingOldDebtAlsoEmptiesOldCollateral.conf
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/fullCollateralMigrationClearsAllOldDebt.conf
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/migrationCanFullyCloseOldPosition.conf
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/migrationCanMoveCollateralBlueToMidnight.conf
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/migrationConservesMigratedCollateral.conf
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/migrationOnlyAddsNewMidnightCollateral.conf
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/migrationOnlyReducesOldBlueDebt.conf
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/migrationOnlyWithdrawsOldBlueCollateral.conf
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/migrationReducesOldDebtOnAtMostOneMarket.conf
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/receiverNotCallbackReverts.conf
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/sourceLoanTokenMismatchReverts.conf
certoraRun certora/confs/callbacks/BorrowBlueToMidnightCallback/tickFeeVanishesAtPar.conf
```

#### BorrowMidnightToBlueCallback (BMB)

```bash
certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationCanFullyCloseOldPosition.conf
certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationCanMoveCollateralMidnightToBlue.conf
certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationCanOpenNewBlueDebt.conf
certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationCannotDepositMoreCollateralThanWithdrawn.conf
certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationFinalFillTransfersAllOldMidnightCollateral.conf
certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationOnlyAddsNewBlueCollateral.conf
certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationOnlyOpensNewBlueDebt.conf
certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationOnlyWithdrawsOldMidnightCollateral.conf
certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/migrationReducesOldDebtOnAtMostOneMarket.conf
certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/oldMidnightDebtAndNewBlueDebtMoveTogether.conf
certoraRun certora/confs/callbacks/BorrowMidnightToBlueCallback/percentageFeeRateAboveCapReverts.conf
```

#### BorrowMidnightRenewalCallback (BMR)

```bash
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/borrowerFeeBoundedByInterestShare.conf
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/callbackRevertsForSameSourceMarket.conf
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/receiverNotCallbackReverts.conf
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalAddsDebtOnAtMostOneMarket.conf
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalCallbackNeverPullsExternalLoanToken.conf
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalCanFullyCloseOldPosition.conf
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalCanMigrateCollateralBetweenMarkets.conf
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalCanMoveDebtBetweenMarkets.conf
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalCannotAddCollateralWhenReducingDebt.conf
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalCannotMoveMoreCollateralThanWithdrawn.conf
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalCannotRemoveCollateralWhenOpeningDebt.conf
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/renewalReducesDebtOnAtMostOneMarket.conf
certoraRun certora/confs/callbacks/BorrowMidnightRenewalCallback/tickFeeVanishesAtPar.conf
```

#### LendVaultToMidnightCallback (LVM)

```bash
certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/lenderFeeBoundedByInterestShare.conf
certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/tickFeeVanishesAtPar.conf
certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultAssetMismatchReverts.conf
certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendCanRaiseCredit.conf
certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendLeavesCollateralUnchanged.conf
certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendNeverTouchesUnrelatedUser.conf
certoraRun certora/confs/callbacks/LendVaultToMidnightCallback/vaultFundedLendOnlyMovesLoanToken.conf
```

#### LendMidnightToVaultCallback (LMV)

```bash
certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/receiverNotCallbackReverts.conf
certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultAssetMismatchReverts.conf
certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultExitCanFullyCloseCredit.conf
certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultExitConservesMidnightBalanceMinusFee.conf
certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultExitLeavesCollateralUnchanged.conf
certoraRun certora/confs/callbacks/LendMidnightToVaultCallback/vaultExitNeverTouchesUnrelatedUser.conf
```

#### LendMidnightRenewalCallback (LMR)

```bash
certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/callbackRevertsForSameSourceMarket.conf
certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/renewalAddsCreditOnAtMostOneMarket.conf
certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/renewalCallbackNeverPullsExternalLoanToken.conf
certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/renewalCanFullyCloseOldCredit.conf
certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/renewalCanMoveCreditWithPositiveFee.conf
certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/renewalNeverTouchesUnrelatedLenderCredit.conf
certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/renewalReducesCreditOnAtMostOneMarket.conf
certoraRun certora/confs/callbacks/LendMidnightRenewalCallback/tickFeeVanishesAtPar.conf
```

#### MidnightSupplyCollateralCallback (MSC)

```bash
certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/supplyMonotoneCollateral.conf
certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/bystanderUntouched.conf
certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/proRataUpperBound.conf
certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/borrowCapacityUsageWithinCap.conf
certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/maxBorrowCapacityUsageFillReachable.conf
certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/supplyCanRaiseCollateral.conf
certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/collateralLengthMismatchReverts.conf
certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/offerSellerAssetsZeroReverts.conf
certoraRun certora/confs/callbacks/MidnightSupplyCollateralCallback/receiverIsCallbackReverts.conf
```

#### MidnightSupplyVaultSharesCallback (MSV)

```bash
certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/supplyMonotoneCollateral.conf
certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/bystanderUntouched.conf
certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/onlyVaultSlotReceivesSupply.conf
certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/suppliedSharesMatchMintedShares.conf
certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/vaultShareBeneficiaryIsSeller.conf
certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/supplyCanRaiseVaultCollateral.conf
certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/noExtraPullWhenPercentZero.conf
certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/vaultAssetMismatchReverts.conf
certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/vaultNotAtIndexReverts.conf
certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/extraPullMatchesPercentFormula.conf
certoraRun certora/confs/callbacks/MidnightSupplyVaultSharesCallback/receiverNotCallbackReverts.conf
```

#### MidnightWithdrawVaultSharesCallback (MWV)

```bash
certoraRun certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/takeCanDropCollateralOnNarrowedMarket.conf
certoraRun certora/confs/callbacks/MidnightWithdrawVaultSharesCallback/takeLeavesVaultShareBalanceUnchanged.conf
```

> The heavier coupling and source-funding rules (`renewalCallbackNeverPullsExternalLoanToken`, `renewalCannotMoveMoreCollateralThanWithdrawn`, `renewalReducesCreditOnAtMostOneMarket`, and the `_one`-regime `oldMidnightDebtAndNewBlueDebtMoveTogether`) use a solver portfolio (`prover_args` with multiple solvers and an increased split depth) to push through the 4-hour SMT timeout.

#### Migration Ratifier

The ratifier runs as six per-category configurations; the advanced-sanity variants in `debug_advanced/` re-run the same rules under `rule_sanity: advanced` (`override_base_config` → the base conf):

```bash
# production (basic sanity)
certoraRun certora/confs/ratifier/valid_state.conf
certoraRun certora/confs/ratifier/unit.conf
certoraRun certora/confs/ratifier/revert.conf
certoraRun certora/confs/ratifier/highlevel.conf
certoraRun certora/confs/ratifier/access_control.conf
certoraRun certora/confs/ratifier/reachability.conf
# advanced-sanity variants
certoraRun certora/confs/ratifier/debug_advanced/valid_state.conf
certoraRun certora/confs/ratifier/debug_advanced/unit.conf
certoraRun certora/confs/ratifier/debug_advanced/revert.conf
certoraRun certora/confs/ratifier/debug_advanced/highlevel.conf
certoraRun certora/confs/ratifier/debug_advanced/access_control.conf
certoraRun certora/confs/ratifier/debug_advanced/reachability.conf
```

---

## Resources

- [Certora Tutorials](https://docs.certora.com/en/latest/docs/user-guide/tutorials.html) -- Official Certora documentation and guided tutorials
- [AlexZoid FV Resources](https://github.com/alexzoid-eth/fv-resources) -- Curated collection of formal verification resources, examples, and references
- [Updraft Assembly & Formal Verification Course](https://updraft.cyfrin.io/courses/formal-verification) -- Comprehensive video course covering assembly and formal verification from the ground up
- [RareSkills Certora Book](https://rareskills.io/tutorials/certora-book) -- Structured tutorial covering CVL syntax, patterns, and common pitfalls
