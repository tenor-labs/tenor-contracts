# Tenor Contracts

Tenor Contracts is a collection of contracts that extend the Morpho stack — Morpho Midnight, Morpho Blue, Morpho Vault V2, and Morpho Oracles. They can be used in combination or standalone to enable more advanced features (gates, auto-renewal, programmatic strategies, etc.). The codebase provides callbacks, a renewal intent system, routing, and standalone utility contracts built on top of these protocols.

## Architecture Overview

The codebase is organized into **standalone contracts** that interact directly with Morpho Midnight, and **composed layers** that build on each other:

```
                       ┌─────────────────────────────┐
                       │          Bundler3           │
                       │       (TenorAdapter)        │
                       └──────────────┬──────────────┘
                                      │ multicall
                       ┌──────────────┴──────────────┐
                       │         TenorRouter         │
                       │   (batch fill across N      │
                       │    offers + clamping)       │
                       └──────────────┬──────────────┘
                                      │ batches midnight.take()
                                      │ (initiator = taker)
               isRatified(offer)      ▼   invokes offer.callback
  ┌──────────────────┐   ┌─────────────────────────┐   ┌─────────────────────────────────────┐
  │ MigrationRatifier│◄──│     Morpho Midnight     │──►│              Callbacks              │
  │ validates user   │   └─────────────────────────┘   │  Borrow  {BlueToMidnight,           │
  │ params for each  │                                 │           MidnightToBlue,           │
  │ migration route  │                                 │           MidnightRenewal}          │
  └────────▲─────────┘                                 │  Lend    {VaultToMidnight,          │
           │ setParams / clearParams                   │           MidnightToVault,          │
  ┌────────┴──────────┐                                │           MidnightRenewal}          │
  │ Auto-renewal user │                                │  Supply  {Collateral, VaultShares}  │
  └───────────────────┘                                │  Withdraw{VaultShares}              │
                                                       └─────────────────────────────────────┘

  ─── Standalone contracts (no dependency on above) ───

  ┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
  │ OracleWithValidation │  │ DelayedLiquidation   │  │ VaultV2Allowlist     │
  │                      │  │ Gate                 │  │ Gate                 │
  └──────────────────────┘  └──────────────────────┘  └──────────────────────┘
  ┌──────────────────────┐  ┌──────────────────────┐
  │ MidnightAllowlist    │  │ MidnightVaultExecutor│
  │ Gate                 │  │                      │
  └──────────────────────┘  └──────────────────────┘
```

---

## Standalone Contracts

These contracts are independent and do not depend on the renewal intent system, router, or bundler.

### OracleWithValidation

Implements the Morpho `IOracle` interface. Reads from a primary `IOracle` feed and validates the price against a secondary `IOracle` feed within a configurable deviation threshold. Reverts if deviation exceeds `MAX_ORACLE_DEVIATION`. Owner can pause the validation check if needed.

Deployed via `OracleWithValidationFactory`.

### DelayedLiquidationGate

Set as the `liquidatorGate` on Morpho Midnight obligations. Enforces a grace period between when a position becomes unhealthy and when liquidation is allowed. Post-maturity liquidations are always permitted without grace period.

```
Pre-maturity:  position unhealthy --> startGracePeriod() --> [grace period] --> liquidate() allowed --> [liquidation period expires]
Post-maturity: liquidate() always allowed (no grace period needed)
```

Also acts as a liquidation router: liquidators call `liquidate()` on the gate (not Morpho Midnight directly). The gate handles token flows via Morpho Midnight's `onLiquidate` callback — it receives seized collateral, optionally calls back to the liquidator for swaps, then pulls loan tokens from the liquidator to repay the debt.

Supports a **priority liquidator** mechanism: when a grace period is started, a priority liquidator can be designated. During the priority period (a configurable window at the start of the liquidation window), only the priority liquidator can execute the liquidation. The factory enforces that `liquidationPeriod >= priorityPeriod + MIN_PERIOD`, guaranteeing at least 1 minute of open liquidation window after the priority period ends.

Deployed via `DelayedLiquidationGateFactory`.

### VaultV2AllowlistGate

Allowlist-based gate for VaultV2 share/asset transfers. Owner configures per-address permissions (`canReceiveShares`, `canSendShares`, `canReceiveAssets`, `canSendAssets`), then can `renounceOwnership()` to make the allowlist immutable.

### MidnightAllowlistGateFactory

Factory for deploying `MidnightAllowlistGate` instances via CREATE2 with deterministic addresses.

### VaultV2AllowlistGateFactory

Factory for deploying `VaultV2AllowlistGate` instances via CREATE2 with deterministic addresses.

### MidnightVaultExecutor

Pass-through helper that bundles deposit/withdraw/liquidation flows for ERC-4626 vault shares used as Midnight collateral. Implements `IRepayCallback` and `ILiquidateCallback` so callers can repay debt or liquidate positions while atomically depositing/withdrawing vault shares. Authorization is delegated to Midnight's `isAuthorized` system (same pattern as `TenorRouter`); the executor holds no custody — funds are supplied within a single call, and any balance left behind across calls is neither usable nor recoverable.

---

## Callbacks

Stateless, immutable contracts invoked by Morpho Midnight during `take()`. Each callback encodes a specific state transition.

### Renewal & Migration Callbacks

These 6 callbacks are declared as immutables by `BaseMigrationRatifier` (inherited by `MigrationRatifier`):

- **Midnight→Midnight borrow renewal** (`BorrowMidnightRenewalCallback`) - Sell-side callback. When a borrower's renewal offer is taken: pulls loan tokens from the borrower, deducts a fee on the interest portion, repays the source obligation debt, and transfers collateral from source to target pro-rata (all collateral on final fill). Fee via `sellerFeeFromTick()` (up to 50% of interest). Source/target obligations must list the same collateral token set — this is a keeper/operator precondition, not enforced onchain.
- **Midnight→Midnight lend renewal** (`LendMidnightRenewalCallback`) - Buy-side callback. When a lender's renewal offer is filled: calculates fee on interest, withdraws `buyerAssets + fee` from the source obligation, and transfers fee to recipient. Lender must authorize the callback on Morpho Midnight. Fee via `buyerFeeFromTick()` (up to 50% of interest).
- **Blue→Midnight / Vault→Midnight migrations** (`BorrowBlueToMidnightCallback`, `LendVaultToMidnightCallback`) - Move positions into Morpho Midnight. The borrow callback repays Morpho Blue debt and transfers collateral; the lend callback redeems from a Morpho Vault V2 position to fund the Midnight position. Fees: borrow via `sellerFeeFromTick()`, lend via `buyerFeeFromTick()`.
- **Midnight→Blue / Midnight→Vault migrations** (`BorrowMidnightToBlueCallback`, `LendMidnightToVaultCallback`) - Exit Midnight fixed-rate positions back to Morpho Blue or Morpho Vault V2. Uses a flat `percentageFee()` (callback enforces max 1%; ratifier disables this fee entirely — `MAX_FEE_RATE_FIXED_TO_VARIABLE = 0`, so any non-zero `setFeeConfig` for Midnight→Blue / Midnight→Vault callbacks reverts) since the rate check on these paths is pre-fee and there is no fixed-rate interest component to apportion.

### Standalone Callbacks

These callbacks are used directly with Morpho Midnight's `take()` and are **not** part of the renewal intent flow:

- **Deposit collateral on fill** (`MidnightSupplyCollateralCallback`) - Supply collateral arrays pro-rata on partial fills. Supports a `maxBorrowCapacityUsage` health cap. No fees.
- **Vault as collateral** (`MidnightSupplyVaultSharesCallback`, `MidnightWithdrawVaultSharesCallback`) - `SupplyVaultShares` is a sell-side callback: when a borrower's sell offer is taken, it pulls loan tokens from the borrower, deposits them into an ERC-4626 vault, and supplies the resulting vault shares as collateral on the new obligation. `WithdrawVaultShares` is a buy-side callback: when a borrower's buy offer (early exit) is filled, it withdraws vault shares from collateral, redeems them for loan tokens, and sends them to the buyer. These are designed for Morpho Vault V2 vaults (which allocate into Morpho Blue markets) where the vault shares serve as collateral in Morpho Midnight obligations.

### Design Principles

- **Immutable**: Once deployed, behavior never changes
- **Stateless execution**: No stored state that could be manipulated
- **Scoped authorizations**: Users grant specific permissions, not blanket access
- **No delegate calls**: Callbacks never enter other callbacks

---

## Migration Ratifier

The Migration Ratifier is a **Morpho Midnight ratifier**: the migrating user is the offer **maker** and sets this contract as the offer's ratifier. When a counterparty fills that offer via `midnight.take()`, Midnight invokes the ratifier's `isRatified` callback, which checks the offer against the user's stored params (fees, window, maturity, rate) for the migration route and reverts if anything is off.

### User Configuration

Users configure renewals by calling `setParams()` on the ratifier, keyed by `(user, callback, sourceTenorMarketId, targetTenorMarketId)`. Each key stores a `UserMigrationParams` struct:

- **`interestRatePolicy`** — Address of an `IInterestRatePolicy` contract (e.g. `StaticRatePolicy`, `PausableStaticRatePolicy`, `MarketMakingPolicy`, `PausableMarketMakingPolicy`) that returns the acceptable rate for a given context
- **`renewalWindow`** — Duration in seconds (uint32) of the renewal window before maturity. For Midnight→Midnight and Midnight→Blue / Midnight→Vault: takes are allowed in `[maturity - renewalWindow, maturity]`. After maturity, always active. For Blue→Midnight / Vault→Midnight: ignored (uses `renewalCadence` boundary instead)
- **`minDuration` / `maxDuration`** — Bounds on target maturity relative to `block.timestamp` (uint32)
- **`limitRatePerSecond`** — Rate limit in WAD per second (uint40). For lenders: floor (max of policy rate and limit). For borrowers: ceiling (min of policy rate and limit)
- **`renewalCadence`** — Optional cadence contract (`IRenewalCadence`, e.g. `FourWeekCadence` which snaps boundaries to every 28 days from the UTC epoch) for target maturity validation and Blue/Vault-source renewal window computation. `address(0)` = no constraint

### Fee Configuration

The **Ratifier owner** configures fee rates via `setFeeConfig(callback, marketId, feeRate, feeRecipient)`. Use `marketId = bytes32(0)` for the action-level default. Market-specific configs take precedence when the `feeRecipient` is set. There is **no timelock** on fee changes — this is by design. Fee updates take effect immediately on subsequent takes.

### Migration Ratifier Validations

When a counterparty fills the user's offer, Midnight checks `isAuthorized[offer.maker][offer.ratifier]` and calls the ratifier's `isRatified(offer, ratifierData)`, which validates:

1. **Params validity** — `interestRatePolicy != address(0)`, `minDuration > 0`, `maxDuration >= minDuration`
2. **Callback data consistency** — Source/target market IDs in callback data match the take's source/target market IDs
3. **Fee consistency** — Fee rate and recipient in callback data match the effective fee config
4. **Renewal window** — `block.timestamp` falls within `[maturity - renewalWindow, maturity]`, or always active after maturity. For Blue / Vault sources (no maturity), uses `renewalCadence.cadencePeriodStart()` instead
5. **Target maturity** — Falls within `[minDuration, maxDuration]` from now, must be after source maturity, and passes `renewalCadence.cadencePeriodStart()` alignment if set
6. **Rate check** — Offer rate satisfies both the policy rate and the rate limit (floor for lenders, ceiling for borrowers). For Midnight→Midnight, the duration used for rate-to-price conversion is `min(targetMaturity - sourceMaturity, targetMaturity - block.timestamp)` — before source maturity this equals the roll period (accounting for the cost of settling at par early), after source maturity it equals the remaining time to target (since settling at par post-maturity is costless). For Blue→Midnight / Vault→Midnight, duration is `targetMaturity - block.timestamp`. For Midnight→Blue / Midnight→Vault, duration is time remaining on the source. Rate checks for Midnight→Midnight and Blue→Midnight / Vault→Midnight reflect **post-fee** effective prices. For Midnight→Blue / Midnight→Vault, the rate check is **pre-fee** since these paths use a flat percentage fee rather than the interest-based effective-price model

### Renewal Flow

```
┌─────────┐  setIsAuthorized(ratifier)  ┌──────────────┐
│  User   │────────────────────────────→│ Morpho       │  stores isAuthorized[user][ratifier]
│         │                             │ Midnight     │
│         │                             └──────────────┘
│         │  setParams()         ┌──────────┐
│         │─────────────────────→│ Ratifier │  stores UserMigrationParams per key
└─────────┘                      └──────────┘

┌──────────────┐  take(userOffer, …)  ┌──────────────┐  checks isAuthorized[maker][ratifier]
│ Counterparty │─────────────────────→│ Morpho       │──┐
└──────────────┘                      │ Midnight     │  │ isRatified(offer, ratifierData)
                                      └───────┬──────┘  ▼
                                              │     ┌──────────┐  validates fees, window,
                                              │     │ Ratifier │  maturity, rate
                                              │     └──────────┘  (reverts if invalid)
                                              ▼
                                     ┌────────────────┐
                                     │ offer.callback │  atomic state transition (maker side)
                                     └────────────────┘
```

1. **User authorizes the ratifier** on Morpho Midnight via `setIsAuthorized(ratifier, true)` — the same `isAuthorized[user][ratifier]` map Midnight checks for any offer's ratifier
2. **User configures params** on the Ratifier via `setParams(user, callback, sourceTenorMarketId, targetTenorMarketId, params)`
3. **User authorizes** the callback contracts on Morpho Midnight via `setIsAuthorized()` so callbacks can withdraw collateral on their behalf
4. A **counterparty** fills the user's migration offer with `midnight.take()` (permissionless) — Midnight checks the user authorized the ratifier, calls `isRatified()` for validation, and invokes the offer's callback
5. **`offer.callback` executes** the state transition atomically (repay source debt, transfer collateral, etc.)

### Pause

To pause renewals for a specific market/route, users can set their `interestRatePolicy` to a `PausableStaticRatePolicy`. When paused, `getRate()` reverts with `IsPaused()`, which causes the ratifier's rate check to revert, blocking all renewal takes for that intent. Any designated pauser can pause; only the owner can unpause.

---

## Tenor Router

Abstract batch execution router that fills a user's source position across N offers in a single transaction. Deployed only as a base for `TenorRouterAdapterBase`/`TenorAdapter`, never standalone. Each action dispatches to raw Morpho Midnight `take()`.

- **Fill accumulation** - Tracks total filled amount along a `FillAxis` (`ASSETS` or `UNITS`). `ASSETS` resolves to the batch's side (buyer or seller) — capping on the counterparty's flow is unrepresentable. Stops once `maxFill` is reached, reverts if under `minFill`. `maxFill`/`minFill = type(uint256).max` is a renewal/close-out sentinel resolved against onchain state by `TenorRouterAdapterBase._resolveSentinel`
- **Per-batch invariants** - All actions in a batch must share the same market and the same side (buyer vs seller). The initiator is always the Midnight taker. Optional `reduceOnly` reverts if the initiator's wrong-side position grows across the batch
- **Price slippage** - Uniform per-unit price bound via `minPrice` / `maxPrice` (WAD-scaled, over `assetTotal / unitTotal`). Useful when `minFill < maxFill` to enforce a rate ceiling independent of fill quantity
- **Per-action clamping** - Optional `ITakeClamp` contracts reduce `takeUnits` before dispatch (e.g. capping based on offer consumption, health checks, budget constraints)
- **Per-action fee adjustment** - Optional `ICallbackFeeAdjuster` contracts size `takeUnits` pre-dispatch and adjust `totals[]` post-dispatch to reflect callback-charged fees. `CallbackFeeAdjuster` is the default implementation, mirroring the INTEREST and PERCENTAGE fee formulas of `CallbackLib`
- **Soft failures** - Actions with `allowRevert = true` emit `ActionReverted` instead of reverting the batch
- **Authorization** - The router itself performs no authorization check. Each dispatched action delegates to its downstream contract: the take calls `Midnight.take()` with `_initiator()` as the taker (Midnight enforces its own `isAuthorized(taker, msg.sender)` rule)

### Clamps

Stateless, view-only contracts that cap `takeUnits` before dispatch. There is one clamp per callback type plus generic offer-side clamps for callback-less takes:

- **Migration / renewal clamps** — `BorrowMidnightRenewalClamp`, `LendMidnightRenewalClamp`, `BorrowBlueToMidnightClamp`, `LendVaultToMidnightClamp`, `BorrowMidnightToBlueClamp`, `LendMidnightToVaultClamp`
- **Standalone-callback clamps** — `SupplyCollateralCallbackClamp` (used with `MidnightSupplyCollateralCallback`), `VaultSupplyClamp` (used with `MidnightSupplyVaultSharesCallback`), `VaultWithdrawClamp` (used with `MidnightWithdrawVaultSharesCallback`)
- **Callback-less offer clamps** — `BuyOfferClamp` (BUY offers — buyer pays loan tokens directly to Midnight), `SellOfferClamp` (SELL offers — seller resells existing credit or borrows against onchain collateral)

---

## Bundler Adapter

`TenorAdapter` extends Bundler3's adapter pattern to expose all Tenor operations as multicallable actions. Composed of:

- **`MidnightAdapterBase`** - Raw Morpho Midnight operations (take, repay, supply/withdraw collateral, flash loans)
- **`MigrationRatifierAdapterBase`** - Ratifier param operations (`migrationSetParams`, `migrationClearParams`). Pins the ratifier as an immutable at deploy time.
- **`TenorRouterAdapterBase`** - Batch fill execution via TenorRouter, with sentinel value resolution for onchain balance lookups

`AuthorizationAdapter` is a separate standalone adapter for granting/revoking long-lived authorizations on Morpho Midnight on behalf of the bundle initiator.

---

## Project Structure

```
src/
├── bundler/                         # Bundler3 adapters (TenorAdapter + AuthorizationAdapter)
├── callbacks/                       # Stateless take callbacks (9 types)
├── factories/                       # CREATE2 deployment factories
├── gates/                           # Access control gates
├── libraries/                       # Shared libraries (CallbackLib, CollateralTransferLib, RouterLib, TakeMathLib, MidnightLib, etc.)
├── oracles/                         # Oracle with validation
├── periphery/
│   └── MidnightVaultExecutor.sol    # Vault share lifecycle management
├── ratifiers/                       # Migration ratifier subsystem
│   ├── BaseMigrationRatifier.sol    # Abstract: fee config, callback discrimination, validation logic
│   ├── MigrationRatifier.sol        # Canonical ratifier: stores user params, implements isRatified
│   ├── policies/                    # Rate policies (Static, MarketMaking, Pausable) and cadence validators (FourWeekCadence)
│   └── interfaces/                  # IMigrationRatifier, IInterestRatePolicy, IRenewalCadence, IMarketMakingPolicy, …
└── router/                          # Batch-fill router subsystem
    ├── TenorRouter.sol              # Batch fill router (abstract)
    ├── CallbackFeeAdjuster.sol      # Pluggable fee resolver
    ├── clamps/                      # Per-action take unit caps (ITakeClamp implementations)
    └── interfaces/                  # ITenorRouter, ICallbackFeeAdjuster, ITakeClamp
```

---

## Audit Scope

The following were **outside the formal scope** of the security audits:

- The clamp contracts in `src/router/clamps/` — optional, opt-in per action and inactive unless an `action.clamp` address is supplied.
- `CallbackFeeAdjuster` — fees are disabled at launch (`feeAdjuster` is pinned to `address(0)`) and this contract is not instantiated by any deployment.

`TakeMathLib` is shared routing math used on the core take path and was reviewed in scope.

## Dependencies

| Dependency | Purpose |
|------------|---------|
| `midnight` | Morpho Midnight — fixed-rate lending markets |
| `morpho-blue` | Morpho Blue protocol |
| `bundler3` | Multicall for write operations |
| `vault-v2` | Morpho Vault V2 — vaults with granular fee capture and role abdication |
| `openzeppelin-contracts` | Standard token interfaces and utilities |

## Build

```bash
forge build
```

## Test

```bash
forge test
```

## License

Business Source License 1.1 (BUSL-1.1) - Copyright 2026 Les entreprises Shippooor inc.

See [LICENSE](LICENSE) for details.
