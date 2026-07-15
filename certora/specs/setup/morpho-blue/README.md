# Formal Verification Report: Morpho Blue

- Repository: https://github.com/morpho-org/morpho-blue
- Latest Commit Hash: [57d444d](https://github.com/morpho-org/morpho-blue/commit/57d444d9e243be21a80e8d4bf8794ebce4a089d9)
- Date: March 2026
- Author: [@alexzoid](https://x.com/alexzoid)
- Certora Prover version: 8.8.1

> Note: This vendored sub-report documents the standalone Morpho Blue valid-state campaign at
> upstream commit `57d444d`; this repository pins `lib/morpho-blue` to `55d2d99` (tag `v1.0.0`),
> whose in-scope sources differ from `57d444d` only by comment/formatting touch-ups and the
> BUSL-1.1 → GPL-2.0-or-later relicense. The confs and specs under this directory carry paths
> relative to the standalone repo root and are not wired to run from this repo root; the
> valid-state invariants are reused as preconditions on the Blue-touching callback scenes.

---

## Table of Contents

1. [About Morpho Blue](#about-morpho-blue)
2. [Formal Verification Methodology](#formal-verification-methodology)
   - [Verification Approach](#verification-approach)
   - [Types of Properties](#types-of-properties)
   - [Verification Process](#verification-process)
   - [Project Structure](#project-structure)
   - [Assumptions](#assumptions)
3. [Verification Properties](#verification-properties)
   - [High-Level](#high-level)
   - [Valid State](#valid-state)
   - [Variable Transitions](#variable-transitions)
   - [State Transitions](#state-transitions)
   - [Unit Tests](#unit-tests)
   - [Accrue Interest](#accrue-interest)
   - [Reachability](#reachability)
   - [Reverts](#reverts)
   - [Access Control](#access-control)
4. [Mutation Testing](#mutation-testing)
   - [What is Mutation Testing](#what-is-mutation-testing)
   - [liquidityInvariant](#liquidityinvariant)
   - [supplySharesSolvency](#supplysharessolvency)
   - [borrowSharesConservation](#borrowsharesconservation)
5. [Setup and Execution](#setup-and-execution)
   - [Common Setup (Steps 1-5)](#common-setup-steps-1-5)
   - [Remote Execution](#remote-execution)
   - [Local Execution](#local-execution)
   - [Running Verification](#running-verification)
   - [Running Mutation Testing](#running-mutation-testing)

---

## About Morpho Blue

Morpho Blue is a noncustodial lending protocol for the Ethereum Virtual Machine that provides permissionless market creation with isolated lending pools. Each market is defined by a unique tuple of (loanToken, collateralToken, oracle, IRM, LLTV) and operates independently. The protocol is a singleton immutable contract with no governance over individual markets -- the owner can only enable new IRMs and LLTVs, set fees, and transfer ownership.

The entire protocol lives in a single contract `Morpho.sol` (555 lines). It uses no proxy patterns, is not upgradeable, and has no Diamond facets. All logic is in the singleton contract, delegating only to internal pure/view libraries for math operations: `MathLib` (WAD-scaled arithmetic), `SharesMathLib` (virtual-shares conversion), `UtilsLib` (helpers), `SafeTransferLib` (safe ERC20 wrappers), and `MarketParamsLib` (market ID computation).

Core operations include supply/withdraw (lending), borrow/repay (borrowing), collateral management, liquidation with bad debt socialization, unrestricted flash loans, and EIP-712 authorization delegation. Interest accrual is lazy, triggered at the start of most operations. Virtual shares (1e6) mitigate inflation attacks on empty markets.

<div style="page-break-before: always;"></div>

---

## Formal Verification Methodology

Certora Formal Verification (FV) provides mathematical proofs of smart contract correctness by verifying code against a formal specification. Unlike testing and fuzzing which examine specific execution paths, Certora FV examines all possible states and execution paths.

The process involves crafting properties in CVL (Certora Verification Language) and submitting them alongside compiled Solidity smart contracts to a remote prover. The prover transforms the contract bytecode and rules into a mathematical model and determines the validity of rules.

### Verification Approach

The valid-state surface is verified under two complementary market regimes — a single-market narrowing and an unrestricted per-id form — to keep the SMT problem tractable while still covering the cross-id reasoning that the single-market form cannot express. The two regimes share the same shared base ([`setup/morpho.spec`](./specs/setup/morpho.spec) — methods block, constants, non-id-keyed ghosts) and the same harness ([`MorphoHarness`](./harnesses/MorphoHarness.sol)); they differ only in how the per-market ghost surface is shaped.

- **One-market regime** ([`morpho_valid_state_one.spec`](./specs/morpho_valid_state_one.spec) + [`setup/morpho_one.spec`](./specs/setup/morpho_one.spec)) — the per-market ghost surface is collapsed to scalar (no-id) ghosts. Sload mirror checks on the `_Morpho.market[KEY id].*`, `_Morpho.position[KEY id][KEY user].*`, and `_Morpho.idToMarketParams[KEY id].*` slots force single-id consistency: any path that touches a second distinct id with a different stored value is infeasible because the scalar ghost cannot simultaneously equal both values. Every per-market valid-state invariant proves in this regime; because markets do not interfere, the proof generalises to every market.
- **Many-market regime** ([`morpho_valid_state_many.spec`](./specs/morpho_valid_state_many.spec) + [`setup/morpho_many.spec`](./specs/setup/morpho_many.spec)) — per-id ghosts are retained and the full valid-state invariant set is lifted to `forall MorphoHarness.Id id.`. This is the regime used by every non-valid-state spec category (high-level, state transitions, unit tests, reverts, reachability, access control, accrue interest, variable transitions), since their rules already fix or quantify over `id` directly.

The non-valid-state spec categories import `setup/morpho_many.spec` for their per-id ghost surface. Only the valid-state property set is duplicated across the two regimes (every invariant proven once in each); all 23 valid-state invariants verify under both confs.

### Types of Properties

Properties are categorized following the [official Certora methodology](https://github.com/Certora/Tutorials/blob/master/06.Lesson_ThinkingProperties/Categorizing_Properties.pdf). Valid State, Variable Transitions and State Transitions properties are **parametric** -- they are automatically verified against every external function in the contract, including functions added after the specification is completed. High-Level properties target specific function sequences.

**High-Level** -- Complex multi-step properties verifying business logic integrity. Unlike parametric properties, these target specific function sequences to validate end-to-end protocol behavior.

**Valid State** -- System-wide invariants that MUST always hold true. These properties define the fundamental constraints of the protocol, such as accounting consistency and structural integrity. Once proven, these invariants serve as trusted assumptions in other properties via `requireInvariant`, reducing verification complexity.

**Variable Transitions** -- Properties that verify specific storage variables change only under expected conditions. The process captures a variable value before instruction execution, runs the instruction, then asserts the variable changed only as permitted or remained unchanged.

**State Transitions** -- Properties that verify the correctness of transitions between valid states. Building upon the valid state invariants, these properties ensure the protocol's state machine operates correctly and that state changes are both authorized and sequentially valid.

**Unit Tests** -- Properties that verify basic behavior of individual functions: direct effects on state, and non-effects on unrelated state. Unlike parametric properties, each unit test targets a specific function call.

**Accrue Interest** -- Properties verifying that interest accrual is correctly triggered across lending operations. Each rule uses `lastStorage` to compare two execution paths: one with an explicit `accrueInterest()` call before the operation, and one without. Identity of final storage proves the operation internally accrues interest.

**Reachability** -- Properties using `satisfy()` to prove that key scenarios are reachable, confirming non-vacuous verification. Basic function reachability confirms each function can execute successfully; conditional reachability validates that specific states and paths are achievable.

**Reverts** -- Properties verifying revert conditions using `@withrevert` and `lastReverted`. These confirm that functions correctly reject invalid inputs, enforce preconditions, and revert under expected circumstances.

**Access Control** -- Parametric rules verifying that unauthorized callers cannot modify protected state. These confirm that role-gated functions reject calls from non-privileged addresses.

### Verification Process

1. **Setup phase**: Define ghost variables, storage hooks, and helper definitions to model contract state in CVL. Establish the verification harness and configuration. This phase addresses several prover limitations:
   - Math library summaries ([`morpho_math_lib.spec`](./specs/setup/libs/morpho_math_lib.spec)): Internal math functions (`wMulDown`, `mulDivDown`, `wTaylorCompounded`) are summarized in CVL to avoid prover timeouts from complex WAD arithmetic.
   - Shares math library summaries ([`morpho_shares_math_lib.spec`](./specs/setup/libs/morpho_shares_math_lib.spec)): Share-to-asset conversion functions (`toSharesDown`, `toSharesUp`, `toAssetsDown`, `toAssetsUp`) are summarized in CVL for tractability.
   - Safe transfer library summaries ([`solmate_safe_transfer_lib.spec`](./specs/setup/libs/solmate_safe_transfer_lib.spec)): SafeTransferLib's inline assembly is summarized in CVL to model ERC20 token transfers.
   - ERC20 model ([`erc20.spec`](./specs/setup/libs/erc20.spec)): Full CVL model for ERC20 tokens with bounded account sets, ghost-tracked balances, and sum invariants.
   - Environment constraints ([`env.spec`](./specs/setup/libs/env.spec)): Standard environment assumptions (no ETH, non-zero sender, realistic timestamps).
2. **Crafting Properties**: Write invariants and rules in CVL, starting with valid state invariants (which become trusted preconditions for other rules), then state/variable transitions, and finally high-level properties.

### Project Structure

```
certora/
├── confs/                                          # Prover configuration files
│   ├── access_control.conf
│   ├── accrue_interest.conf
│   ├── high_level.conf
│   ├── high_level_mutations_borrowSharesConservation.conf
│   ├── reachability.conf
│   ├── reverts.conf
│   ├── state_transitions.conf
│   ├── unit_tests.conf
│   ├── valid_state_one.conf                        # One-market regime (scalar ghosts)
│   ├── valid_state_many.conf                       # Many-market regime (per-id ghosts)
│   ├── valid_state_mutations_liquidityInvariant.conf
│   ├── valid_state_mutations_supplySharesSolvency.conf
│   ├── variable_transitions.conf
│   └── debug/                                      # Debug/sanity configurations
│       ├── erc20_max_users.conf
│       ├── morpho_valid_state_debug.conf
│       └── sanity.conf
│
├── harnesses/                                      # Verification harnesses
│   ├── HelperCVL.sol
│   └── MorphoHarness.sol
│
├── mutations/                                      # Mutation testing files
│   ├── add_mutation.sh
│   ├── borrowSharesConservation/                   # 10 manual mutants
│   │   ├── 1.sol ... 10.sol
│   ├── liquidityInvariant/                         # 13 manual mutants
│   │   ├── 1.sol ... 13.sol
│   └── supplySharesSolvency/                       # 10 manual mutants
│       ├── 1.sol ... 10.sol
│
└── specs/                                          # CVL specification files
    ├── morpho_access_control.spec                  # Access control rules
    ├── morpho_accrue_interest.spec                 # Interest accrual idempotency
    ├── morpho_high_level.spec                      # High-level behavioral rules
    ├── morpho_reachability.spec                    # Reachability rules
    ├── morpho_reverts.spec                         # Revert condition rules
    ├── morpho_state_transitions.spec               # State transition rules
    ├── morpho_unit_tests.spec                      # Unit test rules
    ├── morpho_valid_state_one.spec                 # Valid state invariants (one-market regime)
    ├── morpho_valid_state_many.spec                # Valid state invariants (many-market regime)
    ├── morpho_variable_transitions.spec            # Variable transition rules
    ├── setup/                                      # Setup specs (ghosts, hooks, summaries)
    │   ├── morpho.spec                             # Shared base: methods, constants, non-id-keyed ghosts
    │   ├── morpho_one.spec                         # One-market regime: scalar (no-id) ghosts
    │   ├── morpho_many.spec                        # Many-market regime: per-id ghosts
    │   └── libs/                                   # Library summaries and models
    │       ├── env.spec                            # Environment constraints
    │       ├── erc20.spec                          # Ghost-based ERC20 token model
    │       ├── helper.spec                         # CVL helper utilities
    │       ├── morpho_math_lib.spec                # MathLib CVL summaries
    │       ├── morpho_shares_math_lib.spec         # SharesMathLib CVL summaries
    │       └── solmate_safe_transfer_lib.spec      # SafeTransferLib CVL summaries
    └── debug/                                      # Debug/test specs
        ├── morpho_erc20_max_users_test.spec
        ├── morpho_sanity.spec
        └── morpho_valid_state_debug.spec
```

### Assumptions

Formal verification requires assumptions about the code and its environment to address prover timeouts, tool limitations, and state consistency. However, incorrect assumptions can mask real bugs by excluding reachable states from analysis. To maintain transparency, all assumptions are categorized into four groups: **Safe** (real-world constraints that don't reduce security coverage), **Proved** (formally verified invariants reused as preconditions), **Unsafe** (scope reductions necessary for tractability that may exclude valid scenarios), and **Trusted** (initialization state and admin-configured parameters assumed correct because initialization logic is excluded from verification).

#### Safe Assumptions

These reflect real-world constraints that don't impact security guarantees. In the codebase, every `require` statement that constitutes a safe assumption is annotated with a `"SAFE: ..."` message string.

Environment Constraints ([`env.spec`](./specs/setup/libs/env.spec)):
Morpho has no payable functions, so `msg.value == 0` is assumed. Sender is non-zero and not the Morpho contract itself. Timestamps are bounded between realistic values (greater than 0, less than max uint32). Block number is non-zero. When two environments are used in the same rule, they share the same block context.

- `msg.value == 0` (no ETH)
- `msg.sender != 0` (non-zero sender)
- `msg.sender != currentContract` (sender is not Morpho)
- `block.timestamp` bounded between max_uint16 and max_uint32
- `block.number != 0`
- Same-block constraints for multi-env rules

Ghost Synchronization ([`morpho.spec`](./specs/setup/morpho.spec)):
All ghost variables tracking Morpho's storage are synchronized with actual storage values via `require` statements in Sload hooks. These are safe because the ghost-hook mechanism ensures one-to-one correspondence between ghost state and contract storage.

- Ghost sync for all market fields (totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares, lastUpdate, fee)
- Ghost sync for position fields (supplyShares, borrowShares, collateral)
- Ghost sync for global state (owner, feeRecipient, isIrmEnabled, isLltvEnabled, isAuthorized, nonce)
- Ghost sync for market params (loanToken, collateralToken, oracle, irm, lltv)
- User account bounded set membership for position access

ERC20 Model ([`erc20.spec`](./specs/setup/libs/erc20.spec)):
ERC20 tokens are modeled with standard assumptions: total supply equals sum of all balances, token decimals between 6 and 18, called contract is non-zero, accounts are within predefined bounded sets.

- Total supply equals sum of all balances
- Realistic token decimals (6-18)
- Non-zero token contract address
- Account set membership for transfers and approvals

Math Library Summaries ([`morpho_math_lib.spec`](./specs/setup/libs/morpho_math_lib.spec)):
Division denominators are assumed non-zero, matching Solidity's revert behavior for division by zero.

- `mulDivDown` denominator non-zero
- `mulDivUp` denominator non-zero

#### Proved Assumptions

These properties have been formally verified as valid state invariants and are used as trusted preconditions (via `requireInvariant`) in state transition and high-level rules. See [Valid State](#valid-state) for detailed descriptions and prover run links.

Accounting Consistency ([`morpho_valid_state_many.spec`](./specs/morpho_valid_state_many.spec)):
- Total supply assets are at least total borrow assets (`liquidityInvariant`)
- Sum of user supply shares does not exceed total supply shares (`supplySharesSolvency`)
- Sum of user borrow shares does not exceed total borrow shares (`borrowSharesSolvency`)
- Fee is bounded by MAX_FEE (25%) (`feeBounded`)

Market Existence ([`morpho_valid_state_many.spec`](./specs/morpho_valid_state_many.spec)):
- Non-existent markets have zero totals (`nonExistentMarketIsZero`)
- Non-existent markets have zero params (`nonExistentMarketParamsAreZero`)
- Non-existent markets have zero positions (`nonExistentMarketPositionsZero`)
- Supply/borrow shares and collateral require market existence

Market Configuration ([`morpho_valid_state_many.spec`](./specs/morpho_valid_state_many.spec)):
- Market IRM is enabled (`marketIrmIsEnabled`)
- Market LLTV is enabled (`marketLltvIsEnabled`)
- Enabled LLTVs are below WAD (`enabledLltvBelowWad`)
- Market LLTV is below WAD (`marketLltvBelowWad`)

Temporal Bounds ([`morpho_valid_state_many.spec`](./specs/morpho_valid_state_many.spec)):
- Last update is bounded by current timestamp (`lastUpdateBoundedByTimestamp`)
- Last update has a minimum bound (`lastUpdateMinBound`)

Safety ([`morpho_valid_state_many.spec`](./specs/morpho_valid_state_many.spec)):
- Borrowers always have collateral (`alwaysCollateralized`)
- Zero address does not authorize (`zeroDoesNotAuthorize`)

#### Unsafe Assumptions

These reduce verification scope to make the problem tractable for the prover. In the codebase, every `require` statement that constitutes an unsafe assumption is annotated with an `"UNSAFE: ..."` message string.

ERC20 Transfer Bounds ([`erc20.spec`](./specs/setup/libs/erc20.spec)):
Transfer amounts in the ERC20 CVL model are bounded by max uint128 to avoid overflow in ghost arithmetic. This excludes scenarios with extremely large token amounts but is necessary for prover tractability.

- Transfer amount bounded by max uint128
- TransferFrom amount bounded by max uint128
- SafeTransfer `to` bounded to predefined account set
- SafeTransferFrom `from` bounded to predefined account set

Prover Configuration:
- Loop unrolling is capped at 3 iterations across all configurations
- Optimistic loop is enabled (assumes loop termination)

One-Market Regime Pins ([`morpho_one.spec`](./specs/setup/morpho_one.spec)):
The one-market regime collapses per-market storage to scalar (no-id) ghosts. Sload mirror checks on `_Morpho.market[KEY id].*`, `_Morpho.position[KEY id][KEY user].*`, and `_Morpho.idToMarketParams[KEY id].*` slots require the stored value to match the scalar ghost, making paths that touch a second distinct id with a conflicting value infeasible. The regime also pins `ghostMbOneLoanToken != 0` so `ERC20_ACCOUNT_BOUNDS` on position hooks stays bound to a stable loan token. These constraints exclude verification paths that genuinely cross between markets; cross-id reasoning is delegated to the many-market regime.

- Scalar `ghostMbOne*` ghosts mirror only one symbolic market.
- Sload mirror on per-market slots forces single-id consistency.
- `ghostMbOneLoanToken != 0` pre-state require in `setupOneBlue`.

#### Trusted Assumptions

These assume that governance and market creation have been done correctly with reasonable parameters. In the codebase, every `require` statement that constitutes a trusted assumption is annotated with a `"TRUSTED: ..."` message string.

Governance State ([`morpho.spec`](./specs/setup/morpho.spec) / [`morpho_many.spec`](./specs/setup/morpho_many.spec) / [`morpho_one.spec`](./specs/setup/morpho_one.spec)):
The protocol owner is assumed to be non-zero, reflecting that `setOwner(address(0))` would not be called in practice. The constructor enforces `owner != address(0)`, but `setOwner` only checks `newOwner != owner`, not `newOwner != 0`. Governance discipline prevents self-destructing ownership.

- Owner is non-zero

Market Initialization ([`morpho_many.spec`](./specs/setup/morpho_many.spec) / [`morpho_one.spec`](./specs/setup/morpho_one.spec)):
Created markets are assumed to have a non-zero loan token. `createMarket` does not validate `loanToken != address(0)`, but a market with zero-address loan token would be non-functional (safeTransfer reverts). Market creators are trusted not to use zero-address tokens. The constraint is expressed as `forall id. lastUpdate[id] != 0 => loanToken[id] != 0` in the many-market regime and as `ghostMbOneLastUpdate128 != 0 => ghostMbOneLoanToken != 0` in the one-market regime.

- Created markets have non-zero loan token

<div style="page-break-before: always;"></div>

---

## Verification Properties

Links to specific CVL spec files are provided for each property, with status indicators.

- ✅ Verified
- ⚠️ Timeout
- ❌ Violated

### High-Level

Complex multi-step properties verifying Morpho Blue's business logic integrity. These target specific function sequences to validate share conservation, asset conservation, round-trip safety, and protocol safety invariants.

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [HL-01](./specs/morpho_high_level.spec#L16-L50) | `supplySharesConservation` | Supply: total shares delta == user delta + fee recipient delta<br>`supply(): totalSharesDelta == userSharesDelta + feeRecSharesDelta` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |
| [HL-02](./specs/morpho_high_level.spec#L60-L94) | `withdrawSharesConservation` | Withdraw: total shares delta == user delta + fee recipient delta<br>`withdraw(): totalSharesDelta == userSharesDelta + feeRecSharesDelta` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |
| [HL-03](./specs/morpho_high_level.spec#L103-L129) | `borrowSharesConservation` | Borrow: total borrow shares delta == user borrow shares delta<br>`borrow(): totalBorrowSharesDelta == userBorrowSharesDelta` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | [Mutation tested (7/10)](#borrowsharesconservation) |
| [HL-04](./specs/morpho_high_level.spec#L137-L162) | `repaySharesConservation` | Repay: total borrow shares delta == user borrow shares delta<br>`repay(): totalBorrowSharesDelta == userBorrowSharesDelta` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |
| [HL-05](./specs/morpho_high_level.spec#L172-L209) | `supplyAssetConservation` | Supply: net asset delta (minus interest) == ERC20 balance change<br>`supply(): (supplyAssetsDelta - interestDelta) == erc20BalanceDelta` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |
| [HL-06](./specs/morpho_high_level.spec#L220-L257) | `supplyWithdrawNoProfit` | Supply-then-withdraw round-trip yields no profit<br>`supply(assets); withdraw(shares) => balanceAfter <= balanceBefore` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |
| [HL-07](./specs/morpho_high_level.spec#L266-L300) | `borrowRepayNoProfit` | Borrow-then-repay round-trip costs at least what was borrowed<br>`borrow(assets); repay(shares) => balanceAfter <= balanceBefore` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |
| [HL-08](./specs/morpho_high_level.spec#L310-L326) | `accrueInterestIncreasesSupplyAssets` | Interest accrual monotonically increases supply assets<br>`accrueInterest() => totalSupplyAssetsAfter >= totalSupplyAssetsBefore` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |
| [HL-09](./specs/morpho_high_level.spec#L333-L349) | `accrueInterestIncreasesBorrowAssets` | Interest accrual monotonically increases borrow assets<br>`accrueInterest() => totalBorrowAssetsAfter >= totalBorrowAssetsBefore` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |
| [HL-10](./specs/morpho_high_level.spec#L358-L379) | `accrueInterestEqualDelta` | Interest accrual increases supply and borrow assets by equal amounts<br>`accrueInterest() => supplyAssetsDelta == borrowAssetsDelta` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |
| [HL-11](./specs/morpho_high_level.spec#L394-L419) | `liquidationPreservesLiquidityRelation` | Liquidation preserves totalBorrowAssets <= totalSupplyAssets<br>`liquidate() => totalBorrowAssetsAfter <= totalSupplyAssetsAfter` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |
| [HL-12](./specs/morpho_high_level.spec#L429-L454) | `liquidationBorrowSharesConservation` | Liquidation: total borrow shares delta == borrower shares delta<br>`liquidate() => totalBorrowSharesDelta == borrowerSharesDelta` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |
| [HL-13](./specs/morpho_high_level.spec#L464-L490) | `supplyCollateralDoesNotChangeTotals` | Supply collateral does not change market-level supply or borrow totals<br>`supplyCollateral() => all totals unchanged` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |
| [HL-14](./specs/morpho_high_level.spec#L499-L523) | `nonLiquidationPreservesCollateralization` | Non-liquidation operations preserve position collateralization<br>`forall f: f != liquidate AND borrowShares > 0 => collateral > 0` | [✅](https://prover.certora.com/output/52567/9fe3d984c234443fa9312aa8799698f6/?anonymousKey=0c039dffffa0fba1d02f6d06bb9d145f63f64fc6) | |

### Valid State

System-wide invariants that define the fundamental constraints of Morpho Blue's accounting and structural integrity. These 23 invariants are verified parametrically against every external function and serve as trusted preconditions for other property categories.

> All 23 invariants are verified in both the one-market regime ([`morpho_valid_state_one.spec`](./specs/morpho_valid_state_one.spec) → `valid_state_one.conf`) and the many-market regime ([`morpho_valid_state_many.spec`](./specs/morpho_valid_state_many.spec) → `valid_state_many.conf`). The spec links in the table below point to the many-market form (with `forall id`) for readability; the one-market form is the same property with `forall id` dropped against scalar ghosts. See [Verification Approach](#verification-approach).

#### Accounting Invariants

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [VS-01](./specs/morpho_valid_state_many.spec#L44-L47) | `feeBounded` | Market fee never exceeds MAX_FEE (25%)<br>`forall id: fee[id] <= MAX_FEE` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-02](./specs/morpho_valid_state_many.spec#L53-L56) | `feeRequiresMarket` | Fee is zero for non-existent markets<br>`forall id: fee[id] != 0 => lastUpdate[id] != 0` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-05](./specs/morpho_valid_state_many.spec#L87-L91) | `liquidityInvariant` | Total supply assets >= total borrow assets for existing markets<br>`forall id: lastUpdate[id] != 0 => totalBorrowAssets[id] <= totalSupplyAssets[id]` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | [Mutation tested (4/13)](#liquidityinvariant) |
| [VS-06](./specs/morpho_valid_state_many.spec#L99-L102) | `supplySharesSolvency` | Sum of user supply shares <= total supply shares<br>`forall id: totalSupplyShares[id] >= sum(supplyShares[id])` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | [Mutation tested (3/10)](#supplysharessolvency) |
| [VS-07](./specs/morpho_valid_state_many.spec#L110-L113) | `borrowSharesSolvency` | Sum of user borrow shares <= total borrow shares<br>`forall id: totalBorrowShares[id] >= sum(borrowShares[id])` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |

#### Temporal Invariants

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [VS-03](./specs/morpho_valid_state_many.spec#L63-L67) | `lastUpdateBoundedByTimestamp` | Last update <= current block timestamp for existing markets<br>`forall id: lastUpdate[id] != 0 => lastUpdate[id] <= block.timestamp` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-04](./specs/morpho_valid_state_many.spec#L74-L78) | `lastUpdateMinBound` | Last update >= MIN_BLOCK_TIMESTAMP for existing markets<br>`forall id: lastUpdate[id] != 0 => lastUpdate[id] >= MIN_TIMESTAMP` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |

#### Market Existence Invariants

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [VS-08](./specs/morpho_valid_state_many.spec#L120-L128) | `nonExistentMarketIsZero` | Non-existent markets have zero accounting totals<br>`forall id: lastUpdate[id] == 0 => all totals and fee == 0` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-09](./specs/morpho_valid_state_many.spec#L135-L143) | `nonExistentMarketParamsAreZero` | Non-existent markets have zero market params<br>`forall id: lastUpdate[id] == 0 => all params == 0` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-21](./specs/morpho_valid_state_many.spec#L267-L273) | `nonExistentMarketPositionsZero` | Non-existent markets have zero positions<br>`forall id, user: lastUpdate[id] == 0 => supplyShares == 0 AND borrowShares == 0 AND collateral == 0` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |

#### Market Configuration Invariants

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [VS-10](./specs/morpho_valid_state_many.spec#L150-L154) | `marketIrmIsEnabled` | Created market's IRM is in the enabled set<br>`forall id: lastUpdate[id] != 0 => isIrmEnabled[irm[id]]` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-11](./specs/morpho_valid_state_many.spec#L162-L166) | `marketLltvIsEnabled` | Created market's LLTV is in the enabled set<br>`forall id: lastUpdate[id] != 0 => isLltvEnabled[lltv[id]]` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-12](./specs/morpho_valid_state_many.spec#L172-L175) | `enabledLltvBelowWad` | Enabled LLTVs are strictly below WAD<br>`forall lltv: isLltvEnabled[lltv] => lltv < WAD` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-13](./specs/morpho_valid_state_many.spec#L182-L186) | `marketLltvBelowWad` | Created market's LLTV is strictly below WAD<br>`forall id: lastUpdate[id] != 0 => lltv[id] < WAD` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |

#### Position Existence Invariants

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [VS-14](./specs/morpho_valid_state_many.spec#L193-L197) | `supplySharesRequiresMarket` | Non-zero supply shares imply market exists<br>`forall id, user: supplyShares[id][user] > 0 => lastUpdate[id] != 0` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-15](./specs/morpho_valid_state_many.spec#L204-L208) | `borrowSharesRequiresMarket` | Non-zero borrow shares imply market exists<br>`forall id, user: borrowShares[id][user] > 0 => lastUpdate[id] != 0` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-16](./specs/morpho_valid_state_many.spec#L215-L219) | `collateralRequiresMarket` | Non-zero collateral implies market exists<br>`forall id, user: collateral[id][user] > 0 => lastUpdate[id] != 0` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-17](./specs/morpho_valid_state_many.spec#L226-L230) | `supplyAssetsRequiresMarket` | Non-zero total supply assets imply market exists<br>`forall id: totalSupplyAssets[id] > 0 => lastUpdate[id] != 0` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-18](./specs/morpho_valid_state_many.spec#L236-L240) | `supplySharesTotalRequiresMarket` | Non-zero total supply shares imply market exists<br>`forall id: totalSupplyShares[id] > 0 => lastUpdate[id] != 0` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-19](./specs/morpho_valid_state_many.spec#L247-L251) | `borrowAssetsRequiresMarket` | Non-zero total borrow assets imply market exists<br>`forall id: totalBorrowAssets[id] > 0 => lastUpdate[id] != 0` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-20](./specs/morpho_valid_state_many.spec#L257-L261) | `borrowSharesTotalRequiresMarket` | Non-zero total borrow shares imply market exists<br>`forall id: totalBorrowShares[id] > 0 => lastUpdate[id] != 0` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |

#### Safety Invariants

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [VS-22](./specs/morpho_valid_state_many.spec#L281-L285) | `alwaysCollateralized` | Positions with borrow shares always have collateral<br>`forall id, user: borrowShares[id][user] != 0 => collateral[id][user] != 0` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |
| [VS-23](./specs/morpho_valid_state_many.spec#L293-L296) | `zeroDoesNotAuthorize` | Zero address does not authorize anyone<br>`forall authorized: !isAuthorized[0][authorized]` | [✅](https://prover.certora.com/output/52567/c5a162c125464f63a249cd45becb4efc/?anonymousKey=960d6632774827f483c5cc29c1ea20a17b5075f8) | |

### Variable Transitions

Properties verifying that specific storage variables in Morpho Blue change only under expected conditions. Each rule captures a variable value before and after an arbitrary function call, asserting it changed only as permitted.

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [VT-01](./specs/morpho_variable_transitions.spec#L46-L59) | `irmEnablementIsPermanent` | Once an IRM is enabled, it stays enabled forever<br>`forall f: isIrmEnabled[irm] before => isIrmEnabled[irm] after` | [✅](https://prover.certora.com/output/52567/2234bb92f4604274a2759aefb3df8c53/?anonymousKey=dea1825d7ac22b8f46027387552b6c8afab68050) | |
| [VT-02](./specs/morpho_variable_transitions.spec#L66-L79) | `lltvEnablementIsPermanent` | Once an LLTV is enabled, it stays enabled forever<br>`forall f: isLltvEnabled[lltv] before => isLltvEnabled[lltv] after` | [✅](https://prover.certora.com/output/52567/2234bb92f4604274a2759aefb3df8c53/?anonymousKey=dea1825d7ac22b8f46027387552b6c8afab68050) | |
| [VT-03](./specs/morpho_variable_transitions.spec#L91-L117) | `marketParamsAddressesImmutableAfterCreation` | Market param addresses cannot change after creation<br>`forall f, id: loanToken[id] != 0 => loanToken[id] unchanged (and collateralToken, oracle, irm)` | [✅](https://prover.certora.com/output/52567/2234bb92f4604274a2759aefb3df8c53/?anonymousKey=dea1825d7ac22b8f46027387552b6c8afab68050) | |
| [VT-04](./specs/morpho_variable_transitions.spec#L124-L138) | `marketLltvImmutableAfterCreation` | Market LLTV cannot change after creation<br>`forall f, id: lltv[id] != 0 => lltv[id] unchanged` | [✅](https://prover.certora.com/output/52567/2234bb92f4604274a2759aefb3df8c53/?anonymousKey=dea1825d7ac22b8f46027387552b6c8afab68050) | |
| [VT-05](./specs/morpho_variable_transitions.spec#L150-L164) | `lastUpdateOnlyIncreases` | Last update timestamp only increases or stays the same<br>`forall f, id: lastUpdate[id] after >= lastUpdate[id] before` | [✅](https://prover.certora.com/output/52567/2234bb92f4604274a2759aefb3df8c53/?anonymousKey=dea1825d7ac22b8f46027387552b6c8afab68050) | |
| [VT-06](./specs/morpho_variable_transitions.spec#L173-L187) | `lastUpdateNonZeroLatch` | Once a market is created (lastUpdate non-zero), it cannot be uncreated<br>`forall f, id: lastUpdate[id] != 0 before => lastUpdate[id] != 0 after` | [✅](https://prover.certora.com/output/52567/2234bb92f4604274a2759aefb3df8c53/?anonymousKey=dea1825d7ac22b8f46027387552b6c8afab68050) | |

### State Transitions

Properties verifying the correctness of transitions between valid states. These ensure Morpho Blue's state machine operates correctly and that accounting changes are coherent across related variables.

#### Market Lifecycle

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [ST-01](./specs/morpho_state_transitions.spec#L19-L56) | `marketCreationAtomicity` | Market params only change during market creation (lastUpdate 0->non-zero)<br>`forall f: paramsChanged => (lastUpdate: 0 -> non-zero)` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |
| [ST-02](./specs/morpho_state_transitions.spec#L69-L100) | `accountingChangesRefreshTimestamp` | Accounting changes with elapsed time refresh lastUpdate to block.timestamp<br>`forall f: accountingChanged AND timeElapsed => lastUpdate == block.timestamp` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |
| [ST-03](./specs/morpho_state_transitions.spec#L109-L148) | `lastUpdateChangeRequiresAccountingOrFeeChange` | lastUpdate change requires accounting change, fee change, or timestamp refresh<br>`forall f: lastUpdateChanged => created OR accountingChanged OR feeChanged OR refreshed` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |

#### Supply/Borrow Share Co-transitions

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [ST-04](./specs/morpho_state_transitions.spec#L162-L191) | `userSupplySharesIncreaseImpliesTotalIncrease` | User supply shares increase implies total supply shares increase<br>`forall f: supplyShares[id][user] increased => totalSupplyShares[id] increased` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |
| [ST-05](./specs/morpho_state_transitions.spec#L200-L229) | `userSupplySharesDecreaseImpliesTotalDecrease` | User supply shares decrease implies total supply shares decrease<br>`forall f: supplyShares[id][user] decreased => totalSupplyShares[id] decreased` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |
| [ST-06](./specs/morpho_state_transitions.spec#L240-L257) | `userBorrowSharesIncreaseImpliesTotalIncrease` | User borrow shares increase implies total borrow shares increase<br>`forall f: borrowShares[id][user] increased => totalBorrowShares[id] increased` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |
| [ST-07](./specs/morpho_state_transitions.spec#L264-L281) | `userBorrowSharesDecreaseImpliesTotalDecrease` | User borrow shares decrease implies total borrow shares decrease<br>`forall f: borrowShares[id][user] decreased => totalBorrowShares[id] decreased` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |

#### Asset/Share Correlation

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [ST-08](./specs/morpho_state_transitions.spec#L295-L321) | `totalSupplySharesIncreaseImpliesAssetsIncrease` | Supply shares increase implies supply assets increase<br>`forall f: totalSupplyShares[id] increased => totalSupplyAssets[id] increased` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |
| [ST-09](./specs/morpho_state_transitions.spec#L330-L362) | `totalSupplySharesDecreaseImpliesAssetsDecrease` | Supply shares decrease implies supply assets do not increase<br>`forall f: totalSupplyShares[id] decreased => totalSupplyAssets[id] <= before` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |
| [ST-10](./specs/morpho_state_transitions.spec#L375-L403) | `totalBorrowSharesIncreaseImpliesAssetsIncrease` | Borrow shares increase implies borrow assets do not decrease<br>`forall f: totalBorrowShares[id] increased => totalBorrowAssets[id] >= before` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |

#### Cross-variable Consistency

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [ST-11](./specs/morpho_state_transitions.spec#L420-L453) | `interestAccrualSymmetry` | Pure interest accrual increases supply assets by at least the borrow assets delta<br>`accrueInterest(): pureInterest => supplyAssetsDelta >= borrowAssetsDelta` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |
| [ST-12](./specs/morpho_state_transitions.spec#L466-L488) | `collateralAndBorrowDecreaseImplyTotalBorrowSharesDecrease` | Collateral and borrow shares decrease imply total borrow shares decrease<br>`forall f: collateral decreased AND borrowShares decreased => totalBorrowShares decreased` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |
| [ST-13](./specs/morpho_state_transitions.spec#L504-L547) | `supplyIncreasesContractBalance` | Supply shares increase is accompanied by loan token balance increase<br>`supply(): totalSupplyShares increased => loanToken.balanceOf(Morpho) increased` | [✅](https://prover.certora.com/output/52567/85ad51f851b047d4b5bce9f568526860/?anonymousKey=2e91090b8389431a8b063dcc95857dfc30da2ab1) | |

### Unit Tests

Properties verifying basic behavior of individual Morpho Blue functions: direct effects on state, non-effects on unrelated state, view function consistency, and never-revert guarantees.

#### Direct Effects

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [UT-01](./specs/morpho_unit_tests.spec#L12-L20) | `setOwnerSetsNewOwner` | setOwner sets the new owner<br>`setOwner(newOwner) => owner == newOwner` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-02](./specs/morpho_unit_tests.spec#L26-L34) | `enableIrmEnablesGivenIrm` | enableIrm enables the given IRM<br>`enableIrm(irm) => isIrmEnabled[irm] == true` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-03](./specs/morpho_unit_tests.spec#L40-L48) | `enableLltvEnablesGivenLltv` | enableLltv enables the given LLTV<br>`enableLltv(lltv) => isLltvEnabled[lltv] == true` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-04](./specs/morpho_unit_tests.spec#L54-L63) | `setFeeRecipientSetsNewRecipient` | setFeeRecipient sets the new recipient<br>`setFeeRecipient(addr) => feeRecipient == addr` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-05](./specs/morpho_unit_tests.spec#L69-L81) | `setFeeSetsNewFee` | setFee sets the new fee for the market<br>`setFee(mp, newFee) => fee[id] == newFee` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-06](./specs/morpho_unit_tests.spec#L88-L101) | `createMarketSetsLastUpdate` | createMarket sets lastUpdate to block.timestamp<br>`createMarket(mp) => lastUpdate[id] == block.timestamp` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-07](./specs/morpho_unit_tests.spec#L107-L132) | `createMarketStoresParams` | createMarket stores all market params<br>`createMarket(mp) => idToMarketParams[id] matches mp` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-08](./specs/morpho_unit_tests.spec#L139-L169) | `supplyIncreasesSharesAndTotals` | Supply increases user shares and market totals<br>`supply() => supplyShares, totalSupplyShares, totalSupplyAssets all >= before` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-09](./specs/morpho_unit_tests.spec#L180-L205) | `withdrawDecreasesSharesAndTotals` | Withdraw decreases user shares by returned amount<br>`withdraw() => supplySharesAfter == supplySharesBefore - returnedShares` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-10](./specs/morpho_unit_tests.spec#L212-L234) | `borrowIncreasesBorrowSharesAndTotals` | Borrow increases user borrow shares by returned amount<br>`borrow() => borrowSharesAfter == borrowSharesBefore + returnedShares` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-11](./specs/morpho_unit_tests.spec#L239-L261) | `repayDecreasesBorrowShares` | Repay decreases user borrow shares by returned amount<br>`repay() => borrowSharesAfter == borrowSharesBefore - returnedShares` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-12](./specs/morpho_unit_tests.spec#L266-L285) | `supplyCollateralIncreasesUserCollateral` | Supply collateral increases user collateral by assets<br>`supplyCollateral(assets) => collateralAfter == collateralBefore + assets` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-13](./specs/morpho_unit_tests.spec#L290-L309) | `withdrawCollateralDecreasesUserCollateral` | Withdraw collateral decreases user collateral by assets<br>`withdrawCollateral(assets) => collateralAfter == collateralBefore - assets` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-14](./specs/morpho_unit_tests.spec#L314-L325) | `setAuthorizationSetsFlag` | setAuthorization sets the authorization flag<br>`setAuthorization(authorized, val) => isAuthorized[sender][authorized] == val` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-15](./specs/morpho_unit_tests.spec#L330-L350) | `liquidateDecreasesBorrowerCollateral` | Liquidate does not increase borrower collateral<br>`liquidate() => collateralAfter <= collateralBefore` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-16](./specs/morpho_unit_tests.spec#L355-L375) | `liquidateDecreasesBorrowerBorrowShares` | Liquidate does not increase borrower borrow shares<br>`liquidate() => borrowSharesAfter <= borrowSharesBefore` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |

#### Non-Effects

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [UT-17](./specs/morpho_unit_tests.spec#L383-L394) | `setOwnerDoesNotChangeFeeRecipient` | setOwner does not change fee recipient<br>`setOwner() => feeRecipient unchanged` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-18](./specs/morpho_unit_tests.spec#L398-L409) | `setFeeRecipientDoesNotChangeOwner` | setFeeRecipient does not change owner<br>`setFeeRecipient() => owner unchanged` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-19](./specs/morpho_unit_tests.spec#L413-L426) | `enableIrmDoesNotAffectLltvEnablement` | enableIrm does not affect LLTV enablement<br>`enableIrm(irm) => isLltvEnabled[lltv] unchanged` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-20](./specs/morpho_unit_tests.spec#L430-L443) | `enableLltvDoesNotAffectIrmEnablement` | enableLltv does not affect IRM enablement<br>`enableLltv(lltv) => isIrmEnabled[irm] unchanged` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-21](./specs/morpho_unit_tests.spec#L451-L471) | `supplyCollateralDoesNotChangeSupplyShares` | Supply collateral does not change any user's supply shares<br>`supplyCollateral() => supplyShares[id][user] unchanged` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-22](./specs/morpho_unit_tests.spec#L478-L501) | `supplyCollateralDoesNotChangeBorrowTotals` | Supply collateral does not change borrow totals<br>`supplyCollateral() => totalBorrowAssets[id], totalBorrowShares[id] unchanged` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-23](./specs/morpho_unit_tests.spec#L508-L531) | `supplyCollateralDoesNotChangeSupplyTotals` | Supply collateral does not change supply totals<br>`supplyCollateral() => totalSupplyAssets[id], totalSupplyShares[id] unchanged` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-24](./specs/morpho_unit_tests.spec#L536-L551) | `setAuthorizationDoesNotAffectOtherPairs` | setAuthorization does not affect other authorization pairs<br>`setAuthorization(authorized, val) => isAuthorized[other1][other2] unchanged` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |

#### Third-Party Isolation

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [UT-25](./specs/morpho_unit_tests.spec#L564-L587) | `supplyDoesNotAffectThirdPartyShares` | Supply does not affect third-party supply shares<br>`supply(onBehalf) => supplyShares[id][third] unchanged (third != onBehalf AND third != feeRecipient)` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-26](./specs/morpho_unit_tests.spec#L592-L615) | `withdrawDoesNotAffectThirdPartyShares` | Withdraw does not affect third-party supply shares<br>`withdraw(onBehalf) => supplyShares[id][third] unchanged (third != onBehalf AND third != feeRecipient)` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-27](./specs/morpho_unit_tests.spec#L619-L641) | `borrowDoesNotAffectThirdPartyBorrowShares` | Borrow does not affect third-party borrow shares<br>`borrow(onBehalf) => borrowShares[id][third] unchanged (third != onBehalf)` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-28](./specs/morpho_unit_tests.spec#L645-L667) | `repayDoesNotAffectThirdPartyBorrowShares` | Repay does not affect third-party borrow shares<br>`repay(onBehalf) => borrowShares[id][third] unchanged (third != onBehalf)` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-29](./specs/morpho_unit_tests.spec#L671-L692) | `supplyCollateralDoesNotAffectThirdPartyCollateral` | Supply collateral does not affect third-party collateral<br>`supplyCollateral(onBehalf) => collateral[id][third] unchanged (third != onBehalf)` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-30](./specs/morpho_unit_tests.spec#L696-L717) | `withdrawCollateralDoesNotAffectThirdPartyCollateral` | Withdraw collateral does not affect third-party collateral<br>`withdrawCollateral(onBehalf) => collateral[id][third] unchanged (third != onBehalf)` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |

#### Cross-Market Isolation

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [UT-31](./specs/morpho_unit_tests.spec#L729-L747) | `setFeeDoesNotCorruptOtherMarketLastUpdate` | setFee does not corrupt other market's lastUpdate (packed slot)<br>`setFee(mp) => lastUpdate[otherId] unchanged` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-32](./specs/morpho_unit_tests.spec#L752-L774) | `setFeeDoesNotCorruptOtherMarketTotals` | setFee does not corrupt other market's totals<br>`setFee(mp) => all totals[otherId] unchanged` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-33](./specs/morpho_unit_tests.spec#L784-L809) | `supplyDoesNotAffectOtherMarketTotals` | Supply does not affect other market's totals<br>`supply(mp) => all totals[otherId] unchanged` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-34](./specs/morpho_unit_tests.spec#L814-L839) | `borrowDoesNotAffectOtherMarketTotals` | Borrow does not affect other market's totals<br>`borrow(mp) => all totals[otherId] unchanged` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |

#### View Function Consistency

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [UT-35](./specs/morpho_unit_tests.spec#L847-L859) | `ownerSameForAnyCaller` | owner() returns the same value for any caller<br>`owner(e1) == owner(e2) for any e1, e2` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-36](./specs/morpho_unit_tests.spec#L863-L875) | `feeRecipientSameForAnyCaller` | feeRecipient() returns the same value for any caller<br>`feeRecipient(e1) == feeRecipient(e2) for any e1, e2` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-37](./specs/morpho_unit_tests.spec#L879-L891) | `isIrmEnabledSameForAnyCaller` | isIrmEnabled() returns the same value for any caller<br>`isIrmEnabled(irm, e1) == isIrmEnabled(irm, e2) for any e1, e2` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-38](./specs/morpho_unit_tests.spec#L895-L907) | `isLltvEnabledSameForAnyCaller` | isLltvEnabled() returns the same value for any caller<br>`isLltvEnabled(lltv, e1) == isLltvEnabled(lltv, e2) for any e1, e2` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |

#### Never-Revert Guarantees

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [UT-39](./specs/morpho_unit_tests.spec#L915-L921) | `ownerNeverReverts` | owner() never reverts<br>`@withrevert owner(); !lastReverted` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-40](./specs/morpho_unit_tests.spec#L925-L931) | `feeRecipientNeverReverts` | feeRecipient() never reverts<br>`@withrevert feeRecipient(); !lastReverted` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-41](./specs/morpho_unit_tests.spec#L935-L941) | `isIrmEnabledNeverReverts` | isIrmEnabled() never reverts<br>`@withrevert isIrmEnabled(irm); !lastReverted` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-42](./specs/morpho_unit_tests.spec#L945-L951) | `isLltvEnabledNeverReverts` | isLltvEnabled() never reverts<br>`@withrevert isLltvEnabled(lltv); !lastReverted` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |
| [UT-43](./specs/morpho_unit_tests.spec#L955-L961) | `nonceNeverReverts` | nonce() never reverts<br>`@withrevert nonce(addr); !lastReverted` | [✅](https://prover.certora.com/output/52567/0f498191f14d4c59852fb0447f988eb6/?anonymousKey=64c89ff29a13bc895058e9281fc17ec117f3001e) | |

### Accrue Interest

Properties verifying that interest accrual is correctly triggered across lending operations. Each rule uses `lastStorage` to compare two execution paths: one with an explicit `accrueInterest()` call before the operation, and one without. Identity of final storage proves the operation internally calls `_accrueInterest()`.

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [AI-01](./specs/morpho_accrue_interest.spec#L115-L138) | `supplyAccruesInterest` | Explicit accrueInterest before supply is idempotent<br>`storage(accrueInterest + supply) == storage(supply alone)` | [✅](https://prover.certora.com/output/52567/e54572cca8474fb8894142e7bbad71bb/?anonymousKey=6cb05d4e035ca64e6348679a695545c290dd044e) | |
| [AI-02](./specs/morpho_accrue_interest.spec#L144-L165) | `withdrawAccruesInterest` | Explicit accrueInterest before withdraw is idempotent<br>`storage(accrueInterest + withdraw) == storage(withdraw alone)` | [✅](https://prover.certora.com/output/52567/e54572cca8474fb8894142e7bbad71bb/?anonymousKey=6cb05d4e035ca64e6348679a695545c290dd044e) | |
| [AI-03](./specs/morpho_accrue_interest.spec#L171-L192) | `borrowAccruesInterest` | Explicit accrueInterest before borrow is idempotent<br>`storage(accrueInterest + borrow) == storage(borrow alone)` | [✅](https://prover.certora.com/output/52567/e54572cca8474fb8894142e7bbad71bb/?anonymousKey=6cb05d4e035ca64e6348679a695545c290dd044e) | |
| [AI-04](./specs/morpho_accrue_interest.spec#L198-L219) | `repayAccruesInterest` | Explicit accrueInterest before repay is idempotent<br>`storage(accrueInterest + repay) == storage(repay alone)` | [✅](https://prover.certora.com/output/52567/e54572cca8474fb8894142e7bbad71bb/?anonymousKey=6cb05d4e035ca64e6348679a695545c290dd044e) | |

### Reachability

Properties using `satisfy()` to prove that key scenarios are reachable, confirming non-vacuous verification. Basic function reachability confirms each function can execute successfully; conditional reachability validates that specific protocol states and edge cases are achievable.

#### Basic Function Reachability

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [RC-01](./specs/morpho_reachability.spec#L8-L15) | `setOwnerIsReachable` | setOwner can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-02](./specs/morpho_reachability.spec#L18-L25) | `enableIrmIsReachable` | enableIrm can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-03](./specs/morpho_reachability.spec#L28-L35) | `enableLltvIsReachable` | enableLltv can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-04](./specs/morpho_reachability.spec#L38-L51) | `setFeeIsReachable` | setFee can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-05](./specs/morpho_reachability.spec#L54-L61) | `setFeeRecipientIsReachable` | setFeeRecipient can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-06](./specs/morpho_reachability.spec#L64-L76) | `createMarketIsReachable` | createMarket can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-07](./specs/morpho_reachability.spec#L79-L98) | `supplyIsReachable` | supply can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-08](./specs/morpho_reachability.spec#L101-L120) | `withdrawIsReachable` | withdraw can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-09](./specs/morpho_reachability.spec#L123-L142) | `borrowIsReachable` | borrow can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-10](./specs/morpho_reachability.spec#L145-L164) | `repayIsReachable` | repay can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-11](./specs/morpho_reachability.spec#L167-L185) | `supplyCollateralIsReachable` | supplyCollateral can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-12](./specs/morpho_reachability.spec#L188-L206) | `withdrawCollateralIsReachable` | withdrawCollateral can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-13](./specs/morpho_reachability.spec#L209-L228) | `liquidateIsReachable` | liquidate can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-14](./specs/morpho_reachability.spec#L231-L238) | `flashLoanIsReachable` | flashLoan can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-15](./specs/morpho_reachability.spec#L241-L252) | `setAuthorizationIsReachable` | setAuthorization can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-16](./specs/morpho_reachability.spec#L255-L270) | `accrueInterestIsReachable` | accrueInterest can execute successfully<br>`satisfy(!lastReverted)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |

#### Conditional Reachability

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [RC-17](./specs/morpho_reachability.spec#L277-L297) | `supplyReachableWithPositiveAssets` | Supply with positive assets is reachable<br>`satisfy(totalSupplyAssetsAfter > totalSupplyAssetsBefore)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-18](./specs/morpho_reachability.spec#L300-L323) | `borrowReachableWithCollateral` | Borrow with existing collateral is reachable<br>`satisfy(totalBorrowAssetsAfter > totalBorrowAssetsBefore)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-19](./specs/morpho_reachability.spec#L326-L347) | `liquidateReachableWithBadDebt` | Liquidation with bad debt socialization is reachable<br>`satisfy(totalSupplyAssetsAfter < totalSupplyAssetsBefore)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-20](./specs/morpho_reachability.spec#L350-L373) | `withdrawReachableByAuthorizedAgent` | Withdraw by authorized agent is reachable<br>`satisfy(sender != onBehalf AND isAuthorized[onBehalf][sender] AND sharesDecreased)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-21](./specs/morpho_reachability.spec#L376-L390) | `setFeeReachableWithZeroFee` | Fee removal (set to zero) is reachable<br>`satisfy(fee[id] > 0 before AND fee[id] == 0 after)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-22](./specs/morpho_reachability.spec#L393-L412) | `accrueInterestReachableWithPositiveInterest` | Interest accrual with positive interest is reachable<br>`satisfy(totalBorrowAssetsAfter > totalBorrowAssetsBefore)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-23](./specs/morpho_reachability.spec#L415-L434) | `repayReachableWithFullRepayment` | Full debt repayment is reachable<br>`satisfy(borrowShares[id][onBehalf] > 0 before AND borrowShares[id][onBehalf] == 0 after)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |
| [RC-24](./specs/morpho_reachability.spec#L439-L477) | `canWithdrawAll` | Full supply withdrawal with active borrows is reachable<br>`satisfy(borrows > 0 AND otherSuppliers exist AND supplyShares[id][user] == 0 after)` | [✅](https://prover.certora.com/output/52567/719dc48f798e492098ec0cadf89ac5eb/?anonymousKey=78a5bd1248333e7ea49b1d5930e2718e5588b5d1) | |
| [RC-25](./specs/morpho_reachability.spec#L480-L512) | `canWithdrawCollateralAll` | Full collateral withdrawal (debt-free) is reachable<br>`satisfy(collateral[id][user] > 0 before AND collateral[id][user] == 0 after)` | [✅](https://prover.certora.com/output/52567/c94c1829fba8478cbbfef13033c56cc6/?anonymousKey=e7cd792e6903f31987aba2d2fba08ba88cd680c8) | |

### Reverts

Properties verifying revert conditions using `@withrevert` and `lastReverted`. These confirm that Morpho Blue functions correctly reject invalid inputs, enforce preconditions, and revert under expected circumstances.

#### Governance Reverts

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [RV-02](./specs/morpho_reverts.spec#L19-L29) | `setOwnerRevertsForNonOwner` | setOwner reverts when caller is not the owner<br>`@withrevert setOwner(); msg.sender != owner => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-03](./specs/morpho_reverts.spec#L33-L43) | `setOwnerRevertsWhenAlreadySet` | setOwner reverts when newOwner equals current owner<br>`@withrevert setOwner(newOwner); newOwner == owner => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-04](./specs/morpho_reverts.spec#L47-L57) | `enableIrmRevertsForNonOwner` | enableIrm reverts when caller is not the owner<br>`@withrevert enableIrm(); msg.sender != owner => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-05](./specs/morpho_reverts.spec#L61-L71) | `enableIrmRevertsWhenAlreadyEnabled` | enableIrm reverts when IRM is already enabled<br>`@withrevert enableIrm(irm); isIrmEnabled[irm] => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-06](./specs/morpho_reverts.spec#L75-L85) | `enableLltvRevertsForNonOwner` | enableLltv reverts when caller is not the owner<br>`@withrevert enableLltv(); msg.sender != owner => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-07](./specs/morpho_reverts.spec#L89-L99) | `enableLltvRevertsWhenAlreadyEnabled` | enableLltv reverts when LLTV is already enabled<br>`@withrevert enableLltv(lltv); isLltvEnabled[lltv] => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-08](./specs/morpho_reverts.spec#L103-L113) | `enableLltvRevertsWhenExceedsMax` | enableLltv reverts when LLTV >= WAD<br>`@withrevert enableLltv(lltv); lltv >= WAD => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-09](./specs/morpho_reverts.spec#L117-L129) | `setFeeRevertsForNonOwner` | setFee reverts when caller is not the owner<br>`@withrevert setFee(); msg.sender != owner => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-10](./specs/morpho_reverts.spec#L133-L145) | `setFeeRevertsWhenExceedsMax` | setFee reverts when fee exceeds MAX_FEE<br>`@withrevert setFee(mp, newFee); newFee > MAX_FEE => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-11](./specs/morpho_reverts.spec#L149-L162) | `setFeeRevertsOnNonExistentMarket` | setFee reverts when market does not exist<br>`@withrevert setFee(mp); lastUpdate[id] == 0 => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-12](./specs/morpho_reverts.spec#L166-L176) | `setFeeRecipientRevertsForNonOwner` | setFeeRecipient reverts when caller is not the owner<br>`@withrevert setFeeRecipient(); msg.sender != owner => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-13](./specs/morpho_reverts.spec#L180-L190) | `setFeeRecipientRevertsWhenAlreadySet` | setFeeRecipient reverts when recipient is already set<br>`@withrevert setFeeRecipient(addr); addr == feeRecipient => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |

#### Market Creation Reverts

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [RV-14](./specs/morpho_reverts.spec#L194-L206) | `createMarketRevertsWhenIrmNotEnabled` | createMarket reverts when IRM is not enabled<br>`@withrevert createMarket(mp); !isIrmEnabled[mp.irm] => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-15](./specs/morpho_reverts.spec#L210-L222) | `createMarketRevertsWhenLltvNotEnabled` | createMarket reverts when LLTV is not enabled<br>`@withrevert createMarket(mp); !isLltvEnabled[mp.lltv] => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-16](./specs/morpho_reverts.spec#L226-L239) | `createMarketRevertsWhenAlreadyCreated` | createMarket reverts when market already exists<br>`@withrevert createMarket(mp); lastUpdate[id] != 0 => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |

#### Lending Operation Reverts

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [RV-17](./specs/morpho_reverts.spec#L243-L261) | `supplyRevertsOnNonExistentMarket` | supply reverts on non-existent market<br>`@withrevert supply(mp); lastUpdate[id] == 0 => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-18](./specs/morpho_reverts.spec#L265-L282) | `supplyRevertsForZeroOnBehalf` | supply reverts when onBehalf is zero address<br>`@withrevert supply(onBehalf=0); lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-19](./specs/morpho_reverts.spec#L286-L303) | `withdrawRevertsForZeroReceiver` | withdraw reverts when receiver is zero address<br>`@withrevert withdraw(receiver=0); lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-20](./specs/morpho_reverts.spec#L307-L326) | `withdrawRevertsWhenUnauthorized` | withdraw reverts when sender is unauthorized<br>`@withrevert withdraw(); sender != onBehalf AND !isAuthorized => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-21](./specs/morpho_reverts.spec#L330-L347) | `borrowRevertsForZeroReceiver` | borrow reverts when receiver is zero address<br>`@withrevert borrow(receiver=0); lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-22](./specs/morpho_reverts.spec#L351-L370) | `borrowRevertsWhenUnauthorized` | borrow reverts when sender is unauthorized<br>`@withrevert borrow(); sender != onBehalf AND !isAuthorized => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-23](./specs/morpho_reverts.spec#L374-L391) | `repayRevertsForZeroOnBehalf` | repay reverts when onBehalf is zero address<br>`@withrevert repay(onBehalf=0); lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |

#### Collateral Operation Reverts

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [RV-24](./specs/morpho_reverts.spec#L395-L411) | `supplyCollateralRevertsForZeroAssets` | supplyCollateral reverts when assets is zero<br>`@withrevert supplyCollateral(assets=0); lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-25](./specs/morpho_reverts.spec#L415-L431) | `supplyCollateralRevertsForZeroOnBehalf` | supplyCollateral reverts when onBehalf is zero address<br>`@withrevert supplyCollateral(onBehalf=0); lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-26](./specs/morpho_reverts.spec#L435-L451) | `withdrawCollateralRevertsForZeroAssets` | withdrawCollateral reverts when assets is zero<br>`@withrevert withdrawCollateral(assets=0); lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-27](./specs/morpho_reverts.spec#L455-L471) | `withdrawCollateralRevertsForZeroReceiver` | withdrawCollateral reverts when receiver is zero address<br>`@withrevert withdrawCollateral(receiver=0); lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-28](./specs/morpho_reverts.spec#L475-L493) | `withdrawCollateralRevertsWhenUnauthorized` | withdrawCollateral reverts when sender is unauthorized<br>`@withrevert withdrawCollateral(); sender != onBehalf AND !isAuthorized => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |

#### Miscellaneous Reverts

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [RV-01](./specs/morpho_reverts.spec#L7-L15) | `isAuthorizedNeverReverts` | isAuthorized() never reverts<br>`@withrevert isAuthorized(a, b); !lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-29](./specs/morpho_reverts.spec#L497-L509) | `setAuthorizationRevertsWhenAlreadySet` | setAuthorization reverts when value is already set<br>`@withrevert setAuthorization(addr, val); isAuthorized[sender][addr] == val => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-30](./specs/morpho_reverts.spec#L513-L525) | `flashLoanRevertsForZeroAssets` | flashLoan reverts when assets is zero<br>`@withrevert flashLoan(token, assets=0, data); lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |
| [RV-31](./specs/morpho_reverts.spec#L529-L542) | `accrueInterestRevertsOnNonExistentMarket` | accrueInterest reverts when market does not exist<br>`@withrevert accrueInterest(mp); lastUpdate[id] == 0 => lastReverted` | [✅](https://prover.certora.com/output/52567/06c2bcbe50ed46d7879440eec7d2da2b/?anonymousKey=b747940b705dff9032d83450428f90472fd4f8f6) | |

### Access Control

Parametric rules verifying that unauthorized callers cannot modify protected state in Morpho Blue. These confirm that position changes require proper authorization.

| Property | Name | Description | Status | Notes |
|----------|------|-------------|--------|-------|
| [AC-01](./specs/morpho_access_control.spec#L7-L21) | `unauthorizedCannotDecreaseSupplyShares` | Unauthorized callers cannot decrease a user's supply shares<br>`forall f: sender != user AND !isAuthorized[user][sender] => supplyShares[id][user] >= before` | [✅](https://prover.certora.com/output/52567/1ad2cbc003ba41a4affdfb2df0765976/?anonymousKey=681e50d043f244d335e1a797a215f042be2d70cd) | |
| [AC-02](./specs/morpho_access_control.spec#L25-L39) | `unauthorizedCannotIncreaseBorrowShares` | Unauthorized callers cannot increase a user's borrow shares<br>`forall f: sender != user AND !isAuthorized[user][sender] => borrowShares[id][user] <= before` | [✅](https://prover.certora.com/output/52567/1ad2cbc003ba41a4affdfb2df0765976/?anonymousKey=681e50d043f244d335e1a797a215f042be2d70cd) | |
| [AC-03](./specs/morpho_access_control.spec#L43-L59) | `unauthorizedCannotDecreaseCollateral` | Unauthorized non-liquidation callers cannot decrease a user's collateral<br>`forall f != liquidate: sender != user AND !isAuthorized => collateral[id][user] >= before` | [✅](https://prover.certora.com/output/52567/1ad2cbc003ba41a4affdfb2df0765976/?anonymousKey=681e50d043f244d335e1a797a215f042be2d70cd) | |

<div style="page-break-before: always;"></div>

---

## Mutation Testing

### What is Mutation Testing

Mutation testing validates the strength and completeness of formal verification specifications by introducing small, deliberate bugs (mutations) into the source code and checking whether existing properties detect them. A **caught** mutation means the specification correctly identified the bug (the rule was violated). A **survived** mutation means the specification did not detect the change, indicating a potential gap in coverage.

Three properties were selected for mutation testing based on their criticality to Morpho Blue's accounting integrity.

### liquidityInvariant

The `liquidityInvariant` (invariant in [`morpho_valid_state_many.spec`](./specs/morpho_valid_state_many.spec)) asserts that total borrow assets never exceed total supply assets. This is the core solvency constraint -- if violated, the protocol cannot honor all withdrawals.

**Result: [4/13 mutations caught](https://mutation-testing.certora.com/?id=f2885415-ed7e-4c68-bce9-d5a2d7cac14c&anonymousKey=a274673d-1c3e-41dd-b7a9-51ab71322c6d)** -- the invariant detects sign flips and missing accounting on the supply side, but single-sided removals on borrow or withdraw survive because the inequality remains satisfiable.

**Configuration:** [`valid_state_mutations_liquidityInvariant.conf`](./confs/valid_state_mutations_liquidityInvariant.conf)

#### supply mutations

**#1** ✅ Removed totalSupplyAssets increase in supply.
```diff
-        market[id].totalSupplyAssets += assets.toUint128();
+        // market[id].totalSupplyAssets += assets.toUint128(); // MUTATION: removed totalSupplyAssets increase in supply
```

**#2** [❌](https://prover.certora.com/output/52567/8728ee650aad498e8dfe47fe0cf8be5b?anonymousKey=8d2e57c7c5b0656051f2a257cbe78dcdf6828cac) Flipped += to -= for totalSupplyAssets in supply.
```diff
-        market[id].totalSupplyAssets += assets.toUint128();
+        market[id].totalSupplyAssets -= assets.toUint128(); // MUTATION: flipped += to -= for totalSupplyAssets in supply
```

#### withdraw mutations

**#3** ✅ Removed totalSupplyAssets decrease in withdraw.
```diff
-        market[id].totalSupplyAssets -= assets.toUint128();
+        // market[id].totalSupplyAssets -= assets.toUint128(); // MUTATION: removed totalSupplyAssets decrease in withdraw
```

#### borrow mutations

**#4** ✅ Flipped += to -= for totalBorrowAssets in borrow.
```diff
-        market[id].totalBorrowAssets += assets.toUint128();
+        market[id].totalBorrowAssets -= assets.toUint128(); // MUTATION: flipped += to -= for totalBorrowAssets in borrow
```

**#5** [❌](https://prover.certora.com/output/52567/52c8b5fd5d6c4be1839b9c17e138a419?anonymousKey=b7e86b5e52fcd3f9631d137725c60c336419f2a5) Removed liquidity check in borrow.
```diff
-        require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, ErrorsLib.INSUFFICIENT_LIQUIDITY);
+        // require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, ErrorsLib.INSUFFICIENT_LIQUIDITY); // MUTATION: removed liquidity check in borrow
```

![mutation-testing_patch5](./mutations/liquidityInvariant/mutation-testing_patch5.png)

**#12** ✅ Zeroed totalBorrowAssets in borrow.
```diff
-        market[id].totalBorrowAssets += assets.toUint128();
+        market[id].totalBorrowAssets = 0; // MUTATION: zeroed totalBorrowAssets in borrow
```

#### repay mutations

**#6** ✅ Removed totalBorrowAssets decrease in repay.
```diff
-        market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, assets).toUint128();
+        // market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, assets).toUint128(); // MUTATION: removed totalBorrowAssets decrease in repay
```

#### liquidate mutations

**#7** [❌](https://prover.certora.com/output/52567/35510ced62bb4e14b6d64a4a49453030?anonymousKey=e40cb1fbd2d366bf1e95efa3d312282e329490e7) Removed bad debt borrow assets decrease.
```diff
-            market[id].totalBorrowAssets -= badDebtAssets.toUint128();
+            // market[id].totalBorrowAssets -= badDebtAssets.toUint128(); // MUTATION: removed bad debt borrow assets decrease
```

**#8** ✅ Removed bad debt supply assets decrease.
```diff
-            market[id].totalSupplyAssets -= badDebtAssets.toUint128();
+            // market[id].totalSupplyAssets -= badDebtAssets.toUint128(); // MUTATION: removed bad debt supply assets decrease
```

**#9** ✅ Negated bad debt condition (== to !=).
```diff
-        if (position[id][borrower].collateral == 0) {
+        if (position[id][borrower].collateral != 0) { // MUTATION: negated bad debt condition
```

#### _accrueInterest mutations

**#10** ✅ Flipped interest to subtract from borrow.
```diff
-            market[id].totalBorrowAssets += interest.toUint128();
+            market[id].totalBorrowAssets -= interest.toUint128(); // MUTATION: flipped interest to subtract from borrow
```

**#11** [❌](https://prover.certora.com/output/52567/f81a1fa7c57140f6b7ffed03a94c47eb?anonymousKey=870afb6756f01dba03039a6205bac9086ba282b3) Removed supply assets interest addition.
```diff
-            market[id].totalSupplyAssets += interest.toUint128();
+            // market[id].totalSupplyAssets += interest.toUint128(); // MUTATION: removed supply assets interest addition
```

**#13** ✅ Negated elapsed check (== to !=).
```diff
-        if (elapsed == 0) return;
+        if (elapsed != 0) return; // MUTATION: negated elapsed check in _accrueInterest
```

### supplySharesSolvency

The `supplySharesSolvency` (invariant in [`morpho_valid_state_many.spec`](./specs/morpho_valid_state_many.spec)) asserts that total supply shares are at least as large as the sum of individual user supply shares. This prevents share dilution or phantom supply positions.

**Result: [3/10 mutations caught](https://mutation-testing.certora.com/?id=c46676f2-f726-48b7-afce-285ec9894936&anonymousKey=f5b3f32b-8151-41e5-bc88-1b9f522d64ef)** -- the invariant detects removal of total-level share updates but misses user-level mutations where the sum-of-parts relationship is not directly tracked.

**Configuration:** [`valid_state_mutations_supplySharesSolvency.conf`](./confs/valid_state_mutations_supplySharesSolvency.conf)

#### supply mutations

**#1** ✅ Removed user supplyShares increase in supply.
```diff
-        position[id][onBehalf].supplyShares += shares;
+        // position[id][onBehalf].supplyShares += shares; // MUTATION: removed user supplyShares increase in supply
```

**#2** [❌](https://prover.certora.com/output/52567/6155ff8ff4f841a3ad246d2c95e27998?anonymousKey=25516dc5c0da82ab2b51255bbb8197a7c7cd668b) Removed totalSupplyShares increase in supply.
```diff
-        market[id].totalSupplyShares += shares.toUint128();
+        // market[id].totalSupplyShares += shares.toUint128(); // MUTATION: removed totalSupplyShares increase in supply
```

**#3** ✅ Flipped += to -= for user supplyShares in supply.
```diff
-        position[id][onBehalf].supplyShares += shares;
+        position[id][onBehalf].supplyShares -= shares; // MUTATION: flipped += to -= for user supplyShares in supply
```

**#9** ✅ Zeroed user supplyShares in supply.
```diff
-        position[id][onBehalf].supplyShares += shares;
+        position[id][onBehalf].supplyShares = 0; // MUTATION: zeroed user supplyShares in supply
```

#### withdraw mutations

**#4** [❌](https://prover.certora.com/output/52567/58b7eca2c8d14758a93db960cf243d2e?anonymousKey=a643076ae56562022d89778be7d23dbaa60d1aab) Removed user supplyShares decrease in withdraw.
```diff
-        position[id][onBehalf].supplyShares -= shares;
+        // position[id][onBehalf].supplyShares -= shares; // MUTATION: removed user supplyShares decrease in withdraw
```

**#5** ✅ Removed totalSupplyShares decrease in withdraw.
```diff
-        market[id].totalSupplyShares -= shares.toUint128();
+        // market[id].totalSupplyShares -= shares.toUint128(); // MUTATION: removed totalSupplyShares decrease in withdraw
```

**#6** ✅ Flipped -= to += for totalSupplyShares in withdraw.
```diff
-        market[id].totalSupplyShares -= shares.toUint128();
+        market[id].totalSupplyShares += shares.toUint128(); // MUTATION: flipped -= to += for totalSupplyShares in withdraw
```

#### _accrueInterest mutations

**#7** ✅ Removed feeRecipient supplyShares increase.
```diff
-                position[id][feeRecipient].supplyShares += feeShares;
+                // position[id][feeRecipient].supplyShares += feeShares; // MUTATION: removed feeRecipient supplyShares increase
```

**#8** [❌](https://prover.certora.com/output/52567/2412896d32fb4f7ebd9608403fb97ec3?anonymousKey=5db88e350f5f8422cd3edb8df265ab76b7223dea) Removed totalSupplyShares fee increase.
```diff
-                market[id].totalSupplyShares += feeShares.toUint128();
+                // market[id].totalSupplyShares += feeShares.toUint128(); // MUTATION: removed totalSupplyShares fee increase
```

**#10** ✅ Negated fee condition (!= to ==).
```diff
-            if (market[id].fee != 0) {
+            if (market[id].fee == 0) { // MUTATION: negated fee condition in _accrueInterest
```

### borrowSharesConservation

The `borrowSharesConservation` (rule in [`morpho_high_level.spec`](./specs/morpho_high_level.spec)) asserts that the change in total borrow shares equals the change in the caller's borrow shares after a borrow operation. This is a conservation law -- no shares are created or destroyed outside the expected accounting.

**Result: [7/10 mutations caught](https://mutation-testing.certora.com/?id=cca291f5-46b4-4f7d-9373-ddddabbc7431&anonymousKey=58d5ed86-9d65-4c6d-9409-80cbd429132a)** -- the rule catches all share-tracking mutations (removals, sign flips, zeroing, doubling, off-by-one) but expectedly misses mutations to unrelated state (totalBorrowAssets) and preconditions (health check, computation condition).

![mutation-testing](./mutations/borrowSharesConservation/mutation-testing.png)

**Configuration:** [`high_level_mutations_borrowSharesConservation.conf`](./confs/high_level_mutations_borrowSharesConservation.conf)

#### borrow mutations

**#1** [❌](https://prover.certora.com/output/52567/ed546721551846a8984cddea5f26915f?anonymousKey=dbe5895c6471546b04edef0b21614f38fa1f1692) Removed user borrowShares increase in borrow.
```diff
-        position[id][onBehalf].borrowShares += shares.toUint128();
+        // position[id][onBehalf].borrowShares += shares.toUint128(); // MUTATION: removed user borrowShares increase in borrow
```

**#2** [❌](https://prover.certora.com/output/52567/3e9e647098f047f18ea9d880b217a4fc?anonymousKey=320535ed20f4845591b9a2dc36b0448438d5a898) Removed totalBorrowShares increase in borrow.
```diff
-        market[id].totalBorrowShares += shares.toUint128();
+        // market[id].totalBorrowShares += shares.toUint128(); // MUTATION: removed totalBorrowShares increase in borrow
```

**#3** [❌](https://prover.certora.com/output/52567/be60130a4655483a97671cdf3b224250?anonymousKey=b05f9dc8395d3e1445e68241d5e19866b49419e2) Flipped += to -= for user borrowShares in borrow.
```diff
-        position[id][onBehalf].borrowShares += shares.toUint128();
+        position[id][onBehalf].borrowShares -= shares.toUint128(); // MUTATION: flipped += to -= for user borrowShares in borrow
```

**#4** [❌](https://prover.certora.com/output/52567/7416f491e5924b2895e691c7934af76a?anonymousKey=aa39e0bfa4c97f80c8e39a616f916fc8056e0aad) Flipped += to -= for totalBorrowShares in borrow.
```diff
-        market[id].totalBorrowShares += shares.toUint128();
+        market[id].totalBorrowShares -= shares.toUint128(); // MUTATION: flipped += to -= for totalBorrowShares in borrow
```

**#5** [❌](https://prover.certora.com/output/52567/e84e25717fb9431bb97ad9a865762e73?anonymousKey=d0d3254d3a5986a35939c2891c47566a1b39f60d) Zeroed user borrowShares in borrow.
```diff
-        position[id][onBehalf].borrowShares += shares.toUint128();
+        position[id][onBehalf].borrowShares = 0; // MUTATION: zeroed user borrowShares in borrow
```

**#6** [❌](https://prover.certora.com/output/52567/dfa2db0ad281482895ee91abc30a91fb?anonymousKey=5ee7fe505d3c1c6d3f3b6654083146970670b07d) Doubled user borrowShares in borrow.
```diff
-        position[id][onBehalf].borrowShares += shares.toUint128();
+        position[id][onBehalf].borrowShares += (shares * 2).toUint128(); // MUTATION: doubled user borrowShares in borrow
```

**#7** [❌](https://prover.certora.com/output/52567/5a664f2ea1d54846ad4f62a45d9370a3?anonymousKey=c6b2ed0e23f5a5de81a48aa3bd7f1e0a10643d42) Off-by-one over for user borrowShares (+1).
```diff
-        position[id][onBehalf].borrowShares += shares.toUint128();
+        position[id][onBehalf].borrowShares += (shares + 1).toUint128(); // MUTATION: off-by-one over for user borrowShares
```

**#8** ✅ Removed health check in borrow.
```diff
-        require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);
+        // require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL); // MUTATION: removed health check in borrow
```

**#9** ✅ Negated shares computation condition (assets > 0 to == 0).
```diff
-        if (assets > 0) shares = assets.toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
+        if (assets == 0) shares = assets.toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares); // MUTATION: negated assets > 0 to assets == 0
```

**#10** ✅ Removed totalBorrowAssets increase in borrow.
```diff
-        market[id].totalBorrowAssets += assets.toUint128();
+        // market[id].totalBorrowAssets += assets.toUint128(); // MUTATION: removed totalBorrowAssets increase in borrow
```

**Overall mutation testing results:** 14 caught / 33 total mutations (42% catch rate). The `borrowSharesConservation` rule shows the strongest mutation detection at 70%, catching all share-tracking mutations. Survived mutations in `liquidityInvariant` and `supplySharesSolvency` are expected for mutations that affect only one side of the invariant inequality or modify state not directly tracked by the specific invariant.

<div style="page-break-before: always;"></div>

---

## Setup and Execution

The Certora Prover can be run either remotely (using Certora's cloud infrastructure) or locally (building from source). Both modes share the same initial setup steps.

### Common Setup (Steps 1-5)

The instructions below are for Ubuntu 24.04. For step-by-step installation details refer to this setup [tutorial](https://alexzoid.com/first-steps-with-certora-fv-catching-a-real-bug#heading-setup).

1. Install Java (tested with JDK 21)

```bash
sudo apt update
sudo apt install default-jre
java -version
```

2. Install [pipx](https://pipx.pypa.io/) -- installs Python CLI tools in isolated environments, avoiding dependency conflicts

```bash
sudo apt install pipx
pipx ensurepath
```

3. Install Certora CLI. To match a specific prover version, pin it explicitly (e.g. `certora-cli==8.8.1`)

```bash
pipx install certora-cli
```

4. Install solc-select and the Solidity compiler version required by the project

```bash
pipx install solc-select
solc-select install 0.8.19
solc-select use 0.8.19
```

5. Create a versioned solc symlink for Certora. Configuration files reference the compiler as `solc0.8.19` (without dashes), but solc-select only creates a generic `solc` binary. Create the symlink so Certora can find it:

```bash
mkdir -p ~/.local/bin
ln -sf ~/.solc-select/artifacts/solc-0.8.19/solc-0.8.19 ~/.local/bin/solc0.8.19
```

Verify `~/.local/bin` is in your `PATH`. If not, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Remote Execution

6. Set up Certora key. You can get a free key through the Certora [Discord](https://discord.gg/certora) or on their website. Once you have it, export it:

```bash
echo "export CERTORAKEY=<your_certora_api_key>" >> ~/.bashrc
```

> **Note:** If a local prover is installed (see below), it takes priority. To force remote execution, add the `--server production` flag:
> ```bash
> certoraRun certora/confs/valid_state_many.conf --server production
> ```

### Local Execution

Follow the full build instructions in the [CertoraProver repository (v8.8.1)](https://github.com/Certora/CertoraProver/tree/8.8.1). Once the local prover is installed it takes priority over the remote cloud by default. Tested on Ubuntu 24.04.

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
git checkout tags/8.8.1
./gradlew assemble
```

4. Verify installation with test example

```bash
certoraRun.py -h
cd Public/TestEVM/Counter
certoraRun counter.conf
```

### Running Verification

#### Quick Runs

`variable_transitions`, `unit_tests`, `accrue_interest`, `reachability`, `reverts`, and `access_control` are lightweight and can be run as full conf files:

```bash
certoraRun certora/confs/variable_transitions.conf
certoraRun certora/confs/unit_tests.conf
certoraRun certora/confs/accrue_interest.conf
certoraRun certora/confs/reachability.conf
certoraRun certora/confs/reverts.conf
certoraRun certora/confs/access_control.conf
```

> **Note:** `valid_state_one`, `valid_state_many`, `state_transitions`, and `high_level` may time out when running all rules at once. Run them per-rule using [`--rule`](https://docs.certora.com/en/latest/docs/prover/cli/options.html#rule) as shown below.

#### Morpho Blue -- Valid State (one regime)

Runs every parametric method against the full valid-state invariant set under the one-market narrowing (scalar ghosts):

```bash
certoraRun certora/confs/valid_state_one.conf --rule feeBounded
certoraRun certora/confs/valid_state_one.conf --rule feeRequiresMarket
certoraRun certora/confs/valid_state_one.conf --rule lastUpdateBoundedByTimestamp
certoraRun certora/confs/valid_state_one.conf --rule lastUpdateMinBound
certoraRun certora/confs/valid_state_one.conf --rule liquidityInvariant
certoraRun certora/confs/valid_state_one.conf --rule supplySharesSolvency
certoraRun certora/confs/valid_state_one.conf --rule borrowSharesSolvency
certoraRun certora/confs/valid_state_one.conf --rule nonExistentMarketIsZero
certoraRun certora/confs/valid_state_one.conf --rule nonExistentMarketParamsAreZero
certoraRun certora/confs/valid_state_one.conf --rule nonExistentMarketPositionsZero
certoraRun certora/confs/valid_state_one.conf --rule marketIrmIsEnabled
certoraRun certora/confs/valid_state_one.conf --rule marketLltvIsEnabled
certoraRun certora/confs/valid_state_one.conf --rule enabledLltvBelowWad
certoraRun certora/confs/valid_state_one.conf --rule marketLltvBelowWad
certoraRun certora/confs/valid_state_one.conf --rule supplySharesRequiresMarket
certoraRun certora/confs/valid_state_one.conf --rule borrowSharesRequiresMarket
certoraRun certora/confs/valid_state_one.conf --rule collateralRequiresMarket
certoraRun certora/confs/valid_state_one.conf --rule supplyAssetsRequiresMarket
certoraRun certora/confs/valid_state_one.conf --rule supplySharesTotalRequiresMarket
certoraRun certora/confs/valid_state_one.conf --rule borrowAssetsRequiresMarket
certoraRun certora/confs/valid_state_one.conf --rule borrowSharesTotalRequiresMarket
certoraRun certora/confs/valid_state_one.conf --rule alwaysCollateralized
certoraRun certora/confs/valid_state_one.conf --rule zeroDoesNotAuthorize
```

#### Morpho Blue -- Valid State (many regime)

Runs every parametric method against the valid-state invariant set lifted to `forall MorphoHarness.Id id.` (per-id ghosts):

```bash
certoraRun certora/confs/valid_state_many.conf --rule feeBounded
certoraRun certora/confs/valid_state_many.conf --rule feeRequiresMarket
certoraRun certora/confs/valid_state_many.conf --rule lastUpdateBoundedByTimestamp
certoraRun certora/confs/valid_state_many.conf --rule lastUpdateMinBound
certoraRun certora/confs/valid_state_many.conf --rule liquidityInvariant
certoraRun certora/confs/valid_state_many.conf --rule supplySharesSolvency
certoraRun certora/confs/valid_state_many.conf --rule borrowSharesSolvency
certoraRun certora/confs/valid_state_many.conf --rule nonExistentMarketIsZero
certoraRun certora/confs/valid_state_many.conf --rule nonExistentMarketParamsAreZero
certoraRun certora/confs/valid_state_many.conf --rule nonExistentMarketPositionsZero
certoraRun certora/confs/valid_state_many.conf --rule marketIrmIsEnabled
certoraRun certora/confs/valid_state_many.conf --rule marketLltvIsEnabled
certoraRun certora/confs/valid_state_many.conf --rule enabledLltvBelowWad
certoraRun certora/confs/valid_state_many.conf --rule marketLltvBelowWad
certoraRun certora/confs/valid_state_many.conf --rule supplySharesRequiresMarket
certoraRun certora/confs/valid_state_many.conf --rule borrowSharesRequiresMarket
certoraRun certora/confs/valid_state_many.conf --rule collateralRequiresMarket
certoraRun certora/confs/valid_state_many.conf --rule supplyAssetsRequiresMarket
certoraRun certora/confs/valid_state_many.conf --rule supplySharesTotalRequiresMarket
certoraRun certora/confs/valid_state_many.conf --rule borrowAssetsRequiresMarket
certoraRun certora/confs/valid_state_many.conf --rule borrowSharesTotalRequiresMarket
certoraRun certora/confs/valid_state_many.conf --rule alwaysCollateralized
certoraRun certora/confs/valid_state_many.conf --rule zeroDoesNotAuthorize
```

#### State Transitions

```bash
certoraRun certora/confs/state_transitions.conf --rule marketCreationAtomicity
certoraRun certora/confs/state_transitions.conf --rule accountingChangesRefreshTimestamp
certoraRun certora/confs/state_transitions.conf --rule lastUpdateChangeRequiresAccountingOrFeeChange
certoraRun certora/confs/state_transitions.conf --rule userSupplySharesIncreaseImpliesTotalIncrease
certoraRun certora/confs/state_transitions.conf --rule userSupplySharesDecreaseImpliesTotalDecrease
certoraRun certora/confs/state_transitions.conf --rule userBorrowSharesIncreaseImpliesTotalIncrease
certoraRun certora/confs/state_transitions.conf --rule userBorrowSharesDecreaseImpliesTotalDecrease
certoraRun certora/confs/state_transitions.conf --rule totalSupplySharesIncreaseImpliesAssetsIncrease
certoraRun certora/confs/state_transitions.conf --rule totalSupplySharesDecreaseImpliesAssetsDecrease
certoraRun certora/confs/state_transitions.conf --rule totalBorrowSharesIncreaseImpliesAssetsIncrease
certoraRun certora/confs/state_transitions.conf --rule interestAccrualSymmetry
certoraRun certora/confs/state_transitions.conf --rule collateralAndBorrowDecreaseImplyTotalBorrowSharesDecrease
certoraRun certora/confs/state_transitions.conf --rule supplyIncreasesContractBalance
```

#### High-Level

```bash
certoraRun certora/confs/high_level.conf --rule supplySharesConservation
certoraRun certora/confs/high_level.conf --rule withdrawSharesConservation
certoraRun certora/confs/high_level.conf --rule borrowSharesConservation
certoraRun certora/confs/high_level.conf --rule repaySharesConservation
certoraRun certora/confs/high_level.conf --rule supplyAssetConservation
certoraRun certora/confs/high_level.conf --rule supplyWithdrawNoProfit
certoraRun certora/confs/high_level.conf --rule borrowRepayNoProfit
certoraRun certora/confs/high_level.conf --rule accrueInterestIncreasesSupplyAssets
certoraRun certora/confs/high_level.conf --rule accrueInterestIncreasesBorrowAssets
certoraRun certora/confs/high_level.conf --rule accrueInterestEqualDelta
certoraRun certora/confs/high_level.conf --rule liquidationPreservesLiquidityRelation
certoraRun certora/confs/high_level.conf --rule liquidationBorrowSharesConservation
certoraRun certora/confs/high_level.conf --rule supplyCollateralDoesNotChangeTotals
certoraRun certora/confs/high_level.conf --rule nonLiquidationPreservesCollateralization
```

### Running Mutation Testing

Run the mutation test suite for each tested property:

```bash
certoraMutate certora/mutations/liquidityInvariant.conf
certoraMutate certora/mutations/supplySharesSolvency.conf
certoraMutate certora/mutations/borrowSharesConservation.conf
```

#### Creating Mutations for Other Invariants

1. **Create the mutations directory**: `mkdir -p certora/mutations/<invariantName>`
2. **Introduce a mutation** into the source contract (e.g., comment out a line, flip a condition)
3. **Run the helper script** to snapshot the mutation:
   ```bash
   ./certora/mutations/add_mutation.sh <invariantName> src/Morpho.sol
   ```
   This auto-numbers the mutation file (e.g., `1.sol`, `2.sol`, ...) and embeds the diff block. The original source is automatically restored via `git restore`.
4. **Create a conf file** (copy an existing one and add the `mutations` section pointing to your new directory)
5. **Run** `certoraMutate` with your new conf file
