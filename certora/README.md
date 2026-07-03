# Property Catalog

## Scope

- `BaseMigrationRatifier.sol` — abstract base: fee config, callback discrimination, window/cadence/rate-check validation
- `MigrationRatifier.sol` — Morpho Midnight ratifier implementing `isRatified`: stores `UserMigrationParams` per user/callback/market tuple, delegates to base. The migrating user is the offer maker; Midnight gates on `isAuthorized[offer.maker][offer.ratifier]` and calls `isRatified` during a counterparty's `take`.
- `LinearInterpolationLib.sol` — shared piecewise-linear interpolation with edge clamping (backs SRP-1 / SRP-2 and `MarketMakingPolicy`)
- `StaticRatePolicy.sol` — immutable rate curve; delegates interpolation to `LinearInterpolationLib`
- `PausableStaticRatePolicy.sol` — `StaticRatePolicy` + pauser-gated pause on `getRate`
- `FourWeekCadence.sol` — canonical `IRenewalCadence` implementation (28-day floor)
- `PriceLib.sol` — rate ↔ price conversion and rate-limit validation
- `CallbackLib.sol` — fee formulas, vault-collateral validation, collateral lookup
- `CollateralTransferLib.sol` — collateral transfer logic
- 6 renewal/migration callbacks (`BorrowMidnightRenewalCallback`, `BorrowBlueToMidnightCallback`, `LendVaultToMidnightCallback`, `BorrowMidnightToBlueCallback`, `LendMidnightToVaultCallback`, `LendMidnightRenewalCallback`)
- 3 supply/withdraw callbacks (`MidnightSupplyCollateralCallback`, `MidnightSupplyVaultSharesCallback`, `MidnightWithdrawVaultSharesCallback`)
- `TenorRouter.sol` — batch execution
- `MidnightLib.sol` — view helpers for clamp health checks
- Clamp contracts (`src/router/clamps/`)
- `DelayedLiquidationGate.sol`, `VaultV2AllowlistGate.sol`, `MidnightAllowlistGate.sol`
- `OracleWithValidation.sol` + `OracleWithValidationFactory.sol`
- `MidnightVaultExecutor.sol` — vault share collateral operations behind gated vaults

---

## 1. Rate Math

### 1a. StaticRatePolicy (src/ratifiers/policies/StaticRatePolicy.sol)

| ID | Property | Description |
|----|----------|-------------|
| SRP-1 | **Continuity & boundary clamping** | At each knot point `i`, the interpolated rate at `rp[i].duration()` equals `rp[i].rate()`. Outside the knot range, the curve is clamped to the boundary knot's rate: `elapsed <= rp[0].duration()` returns `rp[0].rate()`, `elapsed >= rp[N-1].duration()` returns `rp[N-1].rate()`. Implemented via `LinearInterpolationLib.interpolate` — see LERP-2. |
| SRP-2 | **Bounded output** | Within any segment `[rp[i].duration(), rp[i+1].duration()]`, the interpolated rate at `elapsed` lies in `[min(rp[i].rate(), rp[i+1].rate()), max(rp[i].rate(), rp[i+1].rate())]`. Monotonicity within the segment follows for piecewise-linear interpolation. |

### 1b. PausableStaticRatePolicy (src/ratifiers/policies/PausableStaticRatePolicy.sol)

`StaticRatePolicy` extended with a pauser-gated pause mechanism. Pause is asymmetric — easy to engage (any pauser), hard to release (owner only) — by design.

| ID | Property | Description |
|----|----------|-------------|
| PAUSE-1 | **Pause gates `getRate`** | When `paused == true`, `getRate(...)` reverts `IsPaused`. Inherits SRP-1 / SRP-2 when not paused. |
| PAUSE-2 | **Asymmetric authorization** | `pause()` is callable by any `isPauser[msg.sender]` address (reverts `OnlyPauser` otherwise); `unpause()` is `onlyOwner` (Ownable2Step). Only the owner can manage the pauser set via `setPauser(address, bool)`. |
| PAUSE-3 | **Idempotency reverts** | `pause()` reverts `AlreadyPaused` when already paused; `unpause()` reverts `NotPaused` when already unpaused. State changes are exactly-once per transition. |

### 1c. FourWeekCadence (src/ratifiers/policies/FourWeekCadence.sol)

Canonical `IRenewalCadence` implementation backing ORCH-11.

| ID | Property | Description |
|----|----------|-------------|
| CAD-1 | **28-day floor from Unix epoch** | `cadencePeriodStart(t) == (t / 28 days) * 28 days`. Pure, deterministic, no state. |

### 1d. PriceLib (src/libraries/PriceLib.sol)

Pure arithmetic underlying RATE-1 / RATE-2.

| ID | Property | Description |
|----|----------|-------------|
| PRICE-1 | **`computePrice` formula and bounds** | `computePrice(isBuy, rate, duration) = WAD² / (WAD + rate * duration)`, rounded per PRICE-2. Returns `WAD` (par) when `rate == 0` or `duration == 0`; otherwise lies in `[0, WAD)` for `isBuy=true` (the floor/`mulDivDown` branch can return 0 for very large `rate * duration`) and `[1, WAD]` for `isBuy=false` (ceil never returns 0). Ceil branch (`UtilsLib.mulDivUp`) requires `WAD + rate * duration <= uint256.max - WAD²`; unreachable in production since the seller-side effective rate is capped by `min()` with the `uint40` limit rate (RATE-1). |
| PRICE-2 | **Rounding favors the protected user** | `computePrice` rounds DOWN when the user buys (`isBuy=true`: a lower price tightens the lender's ceiling `assets * WAD <= units * price`) and UP when the user sells (`isBuy=false`: a higher price tightens the borrower's receipt floor `assets * WAD >= units * price`). Both directions make `satisfiesRateLimit` strictly harder to satisfy, never easier; the two prices differ by at most one wei. |
| PRICE-3 | **`computeEffectiveRate` directionality** | For `isBuy=false` (borrower), returns `min(policyRate, limitRate)` — the tighter ceiling. For `isBuy=true` (lender), returns `max(policyRate, limitRate)` — the tighter floor. |
| PRICE-4 | **`satisfiesRateLimit` comparison direction** | For `isBuy=false`: `assets * WAD >= marketUnits * price`. For `isBuy=true`: `assets * WAD <= marketUnits * price`. A single inversion flips ceiling↔floor — see RATE-3. |

### 1e. Rate Validation (BaseMigrationRatifier._ratifyRate + PriceLib.satisfiesRateLimit)

> `satisfiesRateLimit` takes post-fee `assets`: any fee is folded into the price by the caller before the check. At the `_ratifyRate` call site, the callback fee and Midnight's settlement fee are composed into `effPrice` upstream via `RouterLib.netSellerPrice` / `netBuyerPrice`.

| ID | Property | Description |
|----|----------|-------------|
| RATE-1 | **Borrower ceiling (isBuy=false)** | `effectiveRate = min(policyRate, limitRate)` via `PriceLib.computeEffectiveRate()`. Validates `assets * WAD >= obligationUnits * price` where `price = WAD * WAD / (WAD + effectiveRate * duration)` via `PriceLib.satisfiesRateLimit()`, with `assets` already net of fees. The borrower's post-fee cost never exceeds the rate ceiling. |
| RATE-2 | **Lender floor (isBuy=true)** | `effectiveRate = max(policyRate, limitRate)` via `PriceLib.computeEffectiveRate()`. Validates `assets * WAD <= obligationUnits * price` via `PriceLib.satisfiesRateLimit()`, with `assets` already gross of fees. The lender's post-fee yield never falls below the rate floor. |
| RATE-3 | **Directionality correctness** | Directionality is derived from the callback address via `BaseMigrationRatifier._userIsBuy(callback)`: returns `true` for `LEND_VAULT_TO_MIDNIGHT`, `BORROW_MIDNIGHT_TO_BLUE`, `LEND_MIDNIGHT_RENEWAL`. Note: isBuy follows offer direction (taker=seller vs taker=buyer), NOT the callback's borrow/lend label. A single inversion means users get the opposite protection — ceiling becomes floor or vice versa. |

### 1f. LinearInterpolationLib (src/libraries/LinearInterpolationLib.sol)

Shared piecewise-linear interpolator with edge clamping. Used by `StaticRatePolicy` (rate curve over elapsed time) and `MarketMakingPolicy` (rate curve over time-to-maturity).

| ID | Property | Description |
|----|----------|-------------|
| LERP-1 | **Input validation reverts** | `interpolate` reverts `EmptyCurve` if `knots.length == 0`; reverts `LengthMismatch` if `values.length != knots.length`. |
| LERP-2 | **Sorted-knots precondition** | Callers must pass strictly-increasing `knots`. Unsorted input is undefined behavior: the function does not revert, but the returned value is meaningless. Only `MarketMakingPolicy` enforces strict monotonicity onchain (in `setCurve`); `StaticRatePolicy`'s constructor performs no validation, so for SRP a sorted, length-matched curve is an off-chain deployer precondition, not a constructor-enforced invariant. |

---

## 2. TenorMarketIdLib — Tenor Market ID Properties (src/libraries/TenorMarketIdLib.sol)

| ID | Property | Description |
|----|----------|-------------|
| ID-1 | **Maturity excluded** | `toTenorMarketId(a) == toTenorMarketId(b)` whenever `a` and `b` differ only in `maturity`. Maturity is a term attribute, not a Tenor market attribute. |
| ID-2 | **All non-maturity fields included** | `toTenorMarketId(a) != toTenorMarketId(b)` whenever any non-maturity field differs (`chainId`, `midnight`, `loanToken`, `collateralParams`, `rcfThreshold`, `enterGate`, `liquidatorGate`). No two distinct Tenor markets may hash to the same ID. |

---

## 3. BaseMigrationRatifier — Validation Invariants (src/ratifiers/BaseMigrationRatifier.sol)

These invariants live in the abstract base; the canonical `MigrationRatifier` inherits them. Any future ratifier extending `BaseMigrationRatifier` inherits the same guarantees.

### 3a. Fee Config

| ID | Property | Description |
|----|----------|-------------|
| ORCH-1 | **Fee rate bounded** | `setFeeConfig(callback, marketId, feeRate, feeRecipient)` reverts when `feeRate > _maxFeeRate(callback)`. V2-to-V1 callbacks are capped at `MAX_FEE_RATE_FIXED_TO_VARIABLE` (0 — fees disabled, any non-zero setFeeConfig reverts); all others at `MAX_FEE_RATE` (50% of interest). Use `marketId = bytes32(0)` for the action-level default. |
| ORCH-2 | **No fees to address(0)** | `setFeeConfig` reverts if `feeRate > 0 && feeRecipient == address(0)`. A non-zero fee rate always requires a valid recipient. |
| ORCH-3 | **Market overrides action** | `getEffectiveFeeConfig(callback, marketId)` returns the market-specific config when its `feeRecipient != address(0)`, otherwise falls back to the action-level default (`marketId = bytes32(0)`). |

### 3b. V2-to-V1 Rate Bound

| ID | Property | Description |
|----|----------|-------------|
| ORCH-4 | **V2-to-V1 uses percentageFee** | V2-to-V1 callbacks (`BORROW_MIDNIGHT_TO_BLUE_CALLBACK`, `LEND_MIDNIGHT_TO_VAULT_CALLBACK`) use `percentageFee` (flat fee on total assets) instead of tick-based fees. ORCH-1 caps these callbacks at `MAX_FEE_RATE_FIXED_TO_VARIABLE` (0), so `feeConfig.feeRate` is always 0 for them and the flat fee is excluded from rate limit validation. A distinct fee pathway with a stricter cap enforced by ORCH-1. |

### 3c. Timing & Maturity

| ID | Property | Description |
|----|----------|-------------|
| ORCH-5 | **V2→V2 post-maturity always executable** | When `block.timestamp >= sourceMaturity`, the renewal window check is always satisfied. A V2→V2 renewal can never be blocked by timing alone after maturity — only target maturity validation and rate limits can reject it. |
| ORCH-6 | **V2→V1 post-maturity always executable** | When `block.timestamp >= sourceMaturity`, V2→V1 exits skip both the window check and target maturity validation (V1 has no maturity). Post-maturity V2→V1 exits can never be blocked by timing constraints. |
| ORCH-7 | **V1→V2 always executable** | V1→V2 migrations have no renewal window constraint — `renewalPeriodStart` is resolved from the cadence boundary, and no window check is applied. A V1→V2 migration can never be blocked by timing alone — only target maturity validation and rate limits can reject it. |
| ORCH-8 | **V2 pre-maturity window enforced** | For V2 sources before maturity, `block.timestamp` must be within `[sourceMaturity - renewalWindow, sourceMaturity]`. Takes before the window are rejected. |
| ORCH-9 | **Target maturity strictly increasing** | Target maturity must be strictly greater than source maturity. For V1→V2 migrations (`sourceMaturity == 0`), this reduces to `targetMaturity > 0`. |
| ORCH-10 | **Duration bounds respected** | Target maturity must fall within `[block.timestamp + minDuration, block.timestamp + maxDuration]`. |
| ORCH-11 | **Cadence enforced on target** | If `renewalCadence != address(0)`, the target maturity must land exactly on a cadence boundary (`cadencePeriodStart(targetMaturity) == targetMaturity`). |

### 3d. Return Value Accuracy (Take Function)

TenorRouter reads `(buyerAssets, sellerAssets)` directly from `MORPHO_MIDNIGHT.take()`. These must reflect the taker's actual net token flows after all fees. Getting this wrong means TenorRouter fill/slippage accounting diverges from reality.

| ID | Property | Description |
|----|----------|-------------|
| ORCH-12 | **Return values reflect net taker flows** | TenorRouter calls `MORPHO_MIDNIGHT.take()` directly and reads back `(buyerAssets, sellerAssets)` — no transformation. TenorRouter synthesizes the obligation-units fill dimension from the clamped input `takeUnits` (Midnight reverts on overshoot, so matched units == requested units). TenorRouter accumulates these values for fill/slippage accounting — a mismatch silently corrupts batch totals. |

### 3e. V2-to-V1 Post-Maturity Duration

| ID | Property | Description |
|----|----------|-------------|
| ORCH-13 | **V2-to-V1 post-maturity duration** | V2-to-V1 renewals clamp `secondsToMaturity` to zero when the source maturity has passed. Post-maturity, the price resolves to WAD (par value, 0% discount). This is consistent with all other renewal paths. |

### 3f. Fee Market ID Selection

| ID | Property | Description |
|----|----------|-------------|
| ORCH-14 | **Fee market ID selection** | V2-to-V1 fees (where `targetMaturity == 0`) resolve against the source market ID. All other callbacks resolve against the target market ID. The ratifier owner must set market fee overrides on the correct ID. |
| ORCH-15 | **Single active params per tuple** | For any given (user, callback, sourceMarketId, targetMarketId) tuple, the Ratifier stores exactly one `UserMigrationParams`. The key structure is `mapping(user => mapping(callback => mapping(sourceMarketId => mapping(targetMarketId => UserMigrationParams))))` — `setParams` overwrites atomically. Corollary: since each callback has a distinct address, params set for one renewal path can never be loaded by another. |

---

## 4. Callbacks — Execution Properties

### 4a. No Dust After Execution

| ID | Property | Callback | Description |
|----|----------|----------|-------------|
| CB-DUST-1 | **Per-call distribution** | All 9 | Every token received during a callback call is fully distributed before it returns. Balances are not isolated cross-call: tokens sent to a callback address outside an active fill are forfeited. `MidnightSupplyVaultSharesCallback.onSell` funds its deposit from `totalDeposit = sellerAssets + amountFromSeller` (the Midnight-delivered proceeds plus the optional seller top-up). The seller-funded callbacks (`BorrowBlueToMidnight`, `BorrowMidnightRenewal`, `LendMidnightToVault`, `MidnightSupplyVaultShares`) reject a misconfigured receiver: `onSell` reverts `CallbackLib.InvalidReceiver` unless `receiver == address(this)`, so the `sellerAssets` portion can never be silently sourced from a pre-existing balance on the callback. |
| CB-DUST-2 | **Offer receiver must not be the callback** | SupplyCollateral | The sell offer's `receiver` must not be set to the callback address: the callback funds collateral via `transferFrom(seller)` and never spends its own balance, so loan proceeds sent to it would be permanently locked. Enforced onchain: `onSell` reverts `CallbackLib.InvalidReceiver` when `receiver == address(this)` — the inverse of the seller-funded callbacks in CB-DUST-1, which require `receiver == address(this)`. |

### 4b. Final Fill — No Collateral Dust in Source Position

| ID | Property | Callback | Description |
|----|----------|----------|-------------|
| CB-FINAL-1 | **Final fill transfers all** | BorrowMidnightRenewal (CollateralTransferLib) | When `sourceDebtBefore == repaidUnits` (isFinalFill), `collateralToTransfer == sourceCollateralBalance` (uses full balance, not pro-rata `mulDivDown`). |
| CB-FINAL-2 | **Final fill transfers all (V1)** | BorrowBlueToMidnight | When `repayBudget == blueDebt` (isFinalFill), `collateralMigrated == blueCollateral` (full V1 collateral balance, not pro-rata). The isFinalFill check uses **asset equality** (`repayBudget == blueDebt`), not share equality — see CB-CLOSE-2 for why this correctly implies all borrow shares are cleared. |
| CB-FINAL-3 | **Final fill transfers all (V2->V1)** | BorrowMidnightToBlue | When `sourceDebtAfter == 0`, `collateralTransferred == sourceCollateral` (full balance). |
| CB-FINAL-4 | **Pro-rata bounded** | All borrow callbacks | For partial fills: `collateralTransferred <= sourceCollateralBalance` (from `mulDivDown` with `repaidUnits <= sourceDebtBefore`). |

### 4c. Source Position Full Closure (CRITICAL)

**Invariant**: Given no constraints on the target side, it must always be possible to fully close the source position in a single fill. No source position can become "stranded" with residual debt or credit after a full take. This applies to all 6 renewal paths. See also CLAMP-4 (source exhaustion) which proves this at the clamp level.

**Collateral migration precondition (V2-to-V2 borrow):** "All collateral migrated" in CB-CLOSE-1 holds only when the source and target obligations list the same collateral token set. `CollateralTransferLib.transferCollaterals` silently skips any source-only token (see CTL-1), so a final fill against a target obligation missing a collateral token closes source debt while leaving that token's balance in the source obligation. Source/target compatibility is a keeper/operator precondition for the V2-to-V2 borrow path — it is not enforced onchain by `BorrowMidnightRenewalCallback`, `BorrowMidnightRenewalClamp`, or the ratifier.

| ID | Property | Callback | Description |
|----|----------|----------|-------------|
| CB-CLOSE-1 | **Full closure achievable** | All 6 renewal/migration | There always exists a take amount that fully closes the source position — zero remaining debt or credit. Full collateral migration additionally requires that every source collateral token is also listed in the target obligation (see precondition above and CTL-1). |
| CB-CLOSE-2 | **V1 rounding compatibility** | BorrowBlueToMidnight | Repaying `expectedBorrowAssets(seller)` must clear all V1 borrow shares. The V1 case is non-trivial because Morpho Blue uses complementary rounding (toAssetsUp / toSharesDown) — this must not prevent full closure. |

### 4d. Fees Cannot Exceed Assets

| ID | Property | Callback | Description |
|----|----------|----------|-------------|
| CB-FEE-1 | **Seller tick fee <= sellerAssets** | BorrowMidnightRenewal, BorrowBlueToMidnight | `sellerFeeFromTick(tick, feeRate, units, sellerAssets) <= sellerAssets` so `repayBudget = sellerAssets - fee` never underflows. |
| CB-FEE-2 | **Buyer tick fee bounded** | LendVaultToMidnight, LendMidnightRenewal | `buyerFeeFromTick(tick, feeRate, units, buyerAssets)` — `fee = ceil(units * effPrice / WAD) - buyerAssets`, clamped to 0. Does not cause unexpected overflow. |
| CB-FEE-3 | **Flat fee <= assets** | BorrowMidnightToBlue, LendMidnightToVault | `percentageFee(assets, feeRate) <= assets` for any valid fee rate. The flat fee can never exceed the assets it's computed on. |
| CB-FEE-4 | **Tick fees bounded by interest** | All tick-based | Tick-based fees are proportional to the interest component and vanish at zero discount. They cannot consume the user's principal. In contrast, `percentageFee` can consume principal — hence the stricter cap. |

### 4e. Fee Rate Distortion

**Invariant**: Fees cannot distort the user's effective interest rate by more than the configured fee rate. A borrower's post-fee cost stays within `feeRate` of the pre-fee rate, and a lender's post-fee yield stays within `feeRate` of the pre-fee yield. No hidden amplification.

| ID | Property | Description |
|----|----------|-------------|
| CB-RATE-1 | **Borrower: rate distortion bounded** | The borrower's effective rate after fees is at most `(1 + feeRate/WAD)` times the pre-fee rate. |
| CB-RATE-2 | **Lender: rate distortion bounded** | The lender's effective rate after fees is at least `(1 - feeRate/WAD)` times the pre-fee rate. |

### 4f. Position Integrity

| ID | Property | Description |
|----|----------|-------------|
| CB-SRC-1 | **Exclusive source funding** | All 6 renewal callbacks must fund the associated offer exclusively from the source position. No external funds (beyond what Midnight delivers as `sellerAssets`/`buyerAssets`) are pulled into the callback. The callback only moves tokens between source position, target position, and fee recipient. |
| CB-DIR-1 | **Exit source, open target** | Every take path only exits (reduces/closes) the source position and only opens (creates/increases) the target position. No callback may increase the source position or reduce the target position. Corollary: a source position can never "cross" — a debt position cannot become credit, and vice versa, since only reduction toward zero is allowed. "Opens" is per Midnight semantics — see CB-NET-1. |
| CB-SAME-1 | **Source market must differ from target** | The Midnight renewal callbacks (`BorrowMidnightRenewalCallback`, `LendMidnightRenewalCallback`) revert with `SameMarket` when the decoded `sourceMarketId` equals the target `marketId`. Defense-in-depth against renewing a position into the same market. |
| CB-NET-1 | **Target-side netting is Midnight semantics, not blocked** | A Midnight account holds one side per market: `take` nets the fill against any opposite-side position before opening a new one (`Midnight.sol` — seller credit is consumed first, only the overflow becomes debt; buyer symmetric). If a user holds an opposite-side position in the *target* market of an opening callback (BorrowBlueToMidnight, BorrowMidnightRenewal, LendVaultToMidnight, LendMidnightRenewal), the migration consumes that position instead of creating a second one. Expected by design and not blocked onchain: the netted position is exited at the offer price, which passed the ratifier's rate check. |
| CB-PURE-1 | **Stateless execution** | All 9 callbacks are stateless. Given equivalent offers, positions, and Midnight state (fees, lossFactor, etc.), execution yields exactly the same result. Callbacks hold no storage and their output is fully determined by their inputs. |

### 4g. Access Control

| ID | Property | Description |
|----|----------|-------------|
| CB-AUTH-1 | **Callbacks only usable within Midnight take** | All 9 callbacks can only be invoked as part of a Morpho Midnight take execution. They cannot be called directly outside that context. |

### 4h. Supply Health Bounds

Both supply callbacks let the maker bound the post-supply position health: `CB-LTV-1` for vault-share supply, `CB-SC-CAP-1` for direct collateral supply.

| ID | Property | Callback | Description |
|----|----------|----------|-------------|
| CB-LTV-1 | **Vault supply overcollateralization** | SupplyVaultShares | The callback deposits `sellerAssets + ceil(sellerAssets * additionalDepositPercent / WAD)` into the vault and supplies the resulting shares as collateral. The caller must choose `additionalDepositPercent >= WAD² / (bondPrice * LLTV) - WAD` to guarantee health. Position health is enforced by Midnight's LLTV check at supply time. |
| CB-SC-CAP-1 | **Maker-bounded liquidation distance** | SupplyCollateral | When the maker sets `maxBorrowCapacityUsage > 0`, every take the callback admits leaves the seller's resulting position with debt ≤ `maxBorrowCapacityUsage` of its borrowing capacity (`Σ collateralᵢ·priceᵢ·lltvᵢ`) — equivalently, the position keeps a liquidation buffer of at least `(1 − maxBorrowCapacityUsage)` of capacity (≈ that much uniform collateral-price drop before reaching the liquidation line). Any fill that would breach the cap reverts `InvalidBorrowCapacityUsage`. The guarantee lets the maker force the just-in-time-collateralized position to land strictly inside Midnight's `isHealthy()` boundary by a chosen margin — covering the quote→settlement price drift and the fragmented-fill collateral shortfall (per-slot pro-rata rounds down) that could otherwise leave the position at the bare liquidation line. The cap is meaningful only in the open interval `(0, WAD)`: `maxBorrowCapacityUsage = 0` skips the check, and any value `≥ WAD` is non-binding (it can only reject `debt > capacity`, which Midnight already rejects) — both defer to Midnight's own supply-time health check. The matching `SupplyCollateralCallbackClamp` debt-limit uses the same borrowing capacity, so quotes never exceed what the gate admits. |

### 4i. V1→V2 Strict Repayment

| ID | Property | Callback | Description |
|----|----------|----------|-------------|
| CB-V1-REP-1 | **No silent overpayment to V1** | BorrowBlueToMidnight | The V1→V2 borrow callback cannot transfer more loan tokens to Morpho Blue than the seller's outstanding V1 debt. Excess (after-fee budget > V1 debt) reverts rather than being absorbed into the V1 market. |

### 4j. Vault Share Settlement

| ID | Property | Callback | Description |
|----|----------|----------|-------------|
| CB-VAULT-WD-1 | **No vault shares retained on callback** | WithdrawVaultShares | `onBuy` withdraws exactly `previewWithdraw(buyerAssets)` shares from Midnight collateral and immediately burns them via `vault.withdraw(buyerAssets, this, this)`. Subject to ERC-4626 `previewWithdraw` consistency, the callback's vault-share balance is unchanged across the call. Surplus collateral stays on Midnight against the maker's remaining position — there is no full-repay surplus-to-buyer branch in this callback. |

### 4k. CallbackLib Helpers (src/libraries/CallbackLib.sol)

Shared utilities the callback contracts call into. The fee formulas pinned here are what CB-FEE-1..4 and CB-RATE-1..2 rely on; this section states the library-level invariants directly.

| ID | Property | Description |
|----|----------|-------------|
| CL-1 | **`validateVaultCollateral` integrity** | Reverts `TokenMismatch` unless BOTH `IERC4626(vault).asset() == loanToken` AND `market.collateralParams[collateralIndex].token == vault`. Prevents operating on a wrong vault or a wrong collateral index. |
| CL-2 | **`percentageFee` callback-level cap** | `percentageFee(assets, feeRate)` reverts `InvalidFeeConfig` if `feeRate > MAX_PERCENTAGE_FEE_RATE` (0.01e18, i.e. 1%). Within the cap, returns `assets * feeRate / WAD` via `mulDivDown`. This is the callback-level cap below the ratifier-level cap `MAX_FEE_RATE_FIXED_TO_VARIABLE = 0` (see ORCH-1, ORCH-4). |
| CL-3 | **Effective-price rounding favors the user** | `sellerEffectivePrice` rounds the price UP (`mulDivUp`), so the seller's residual fee rounds DOWN. `buyerEffectivePrice` rounds the price DOWN (`mulDivDown`), so the buyer's residual fee also rounds DOWN. Both sides round against the protocol fee recipient. |
| CL-4 | **Interest-fee rate bounded by WAD** | `sellerEffectivePrice` and `buyerEffectivePrice` revert `InvalidFeeConfig` if `feeRate > WAD`. The buyer side additionally reverts if `(WAD - price) * feeRate / WAD >= WAD` (only reachable at `price == 0 && feeRate == WAD`). |
| CL-5 | **`findCollateral` sorted-array search** | Walks `market.collateralParams` early-exiting when the current token exceeds the target. Correctness depends on Midnight's invariant that collaterals are sorted ascending by address (same dependency captured by CTL-3, which consumes this function). |

---

## 5. CollateralTransferLib — Transfer Properties (src/libraries/CollateralTransferLib.sol)

| ID | Property | Description |
|----|----------|-------------|
| CTL-1 | **Only matching collaterals transferred (partial migration)** | Only collateral tokens present in BOTH source and target obligations are transferred. Non-matching source-only collaterals get `collateralAmounts[i] == 0` and remain in the source obligation. Source/target collateral compatibility is the caller's precondition — `transferCollaterals` does not revert on a mismatch. Callers that require full migration (e.g. V2-to-V2 borrow renewal) must enforce compatibility upstream. |
| CTL-2 | **Pro-rata is conservative** | When `sourceDebtBefore > repaidUnits`, `collateralToTransfer == sourceCollateralBalance * repaidUnits / sourceDebtBefore` (mulDivDown — rounds down, never over-transfers). |
| CTL-3 | **Collateral lookup correctness** | Collateral lookup correctly finds all matching tokens without false negatives. Correctness depends on the sorted invariant of the collaterals array (maintained by Midnight). |

---

## 6. Clamps — Offer Constraining Properties (src/router/clamps/)

### Terminology

- **Resolved units**: The value returned by `maxUnits(offer, data)` — the largest fill that won't trip a maker-side constraint (capacity, balance, allowance).
- **Maker**: The offer signer. Clamps protect the maker's constraints (capacity, balance, allowance).
- **Taker**: The counterparty filling the offer. Taker health/balance is the taker's responsibility.

### Health is not a clamp dimension

Clamps do not constrain on position health for either side. Health is handled off-chain by a backend router (price-movement buffer) plus per-action `allowRevert: true` on `TenorRouter` (ROUTER-4), which absorbs at-Midnight reverts gracefully. The single onchain exception is `CB-SC-CAP-1` (`MidnightSupplyCollateralCallback.maxBorrowCapacityUsage`).

### Core Clamp Invariants

| ID | Property | Description |
|----|----------|-------------|
| CLAMP-1 | **Feasibility** | `take(resolvedUnits)` does not revert at any maker-side check (capacity, balance, allowance). The clamp never returns a value that would cause a take-time revert on those dimensions. (Health is excluded by design — see "Health is not a clamp dimension" above.) |
| CLAMP-2 | **Tightness** | `take(resolvedUnits + 1)` always reverts on at least one maker-side check (capacity, balance, allowance). The clamp returns the largest value that doesn't trip any maker-side constraint. Corollaries: after `take(resolvedUnits)`, `take(1)` reverts (exhaustion) and `maxUnits()` returns 0 (no-dust). (Health is excluded by design — see "Health is not a clamp dimension" above.) |
| CLAMP-3 | **No-revert** | Clamp functions never revert. If the offer is unfillable (zero capacity, zero balance, etc.), the clamp returns 0 instead of reverting. A reverting clamp DoS-es the entire router batch. |
| CLAMP-4 | **Source exhaustion (renewal clamps)** | For renewal callback clamps: given no liquidity constraints on the target side, the clamped value fully consumes the source position. |
| CLAMP-5 | **BUY+fee seller sizing closes source debt** | `TakeMathLib.maxUnitsForSellerBudget` sizes BUY offers solely by `sellerPrice` (settlement-fee adjusted), not the tighter Tenor-fee `sellerEffectivePrice`. This keeps `repayBudget <= sellerAssets <= maxBudget` (the Tenor fee is carved out of `sellerAssets`) while letting a BUY renewal close the source debt exactly and trigger the final collateral sweep (CB-FINAL-1) when capacity permits. |
| CLAMP-7 | **`VaultSupplyClamp.maxUnits` saturates to `uint128`** | A tiny `additionalDepositPercent` inverts to `~available * WAD` seller-assets, whose unit conversion can exceed `uint128`. `maxUnits` saturates to `uint128.max` (via `TakeMathLib.assetsToSellerUnits`) so a single `Midnight.take` never forwards `> uint128` units and reverts at its `toUint128` cast. |
| CLAMP-6 | **Fee-aware vault sizing (LendMidnightToVaultClamp)** | Under a binding ERC-4626 `maxDeposit` cap and a matching fee-charging deposit callback, the clamp grosses up the assets budget by the fee fraction so the net deposit (`sellerAssets - fee`) fills the cap exactly, rather than under-utilizing it. No-op when `feeRate == 0`. |

### SupplyCollateralCallbackClamp (src/router/clamps/SupplyCollateralCallbackClamp.sol)

| ID | Property | Description |
|----|----------|-------------|
| SCCC-1 | **CallbackData-faithful sizing** | The pro-rata denominator (`offerSellerAssets`), per-slot `amounts`, and `maxBorrowCapacityUsage` are decoded from `offer.callbackData` — the same struct the callback decodes — not from keeper-supplied clampData. Returns 0 if the CallbackData fails to decode, `amounts.length` ≠ market collaterals, or `offerSellerAssets == 0`, so the clamp never reverts (CLAMP-3) nor quotes a fill the callback would reject. |
| SCCC-2 | **Monotone-safe debt-limit bound** | The health/maxBorrowCapacityUsage bound never over-sizes: the linearized estimate is kept only when it is self-consistent at the exact post-take seller-assets rounding it produces, otherwise the clamp falls back to the monotone-safe existing-collateral headroom (`existingLimit − currentDebt`), which keeps `take(u)` healthy for every `u` at or below the quote — the contract the router relies on since it fills `min(offerRemaining, clamp)`. Quotes are conservative and never exceed a fill the take would accept (CLAMP-3). |

---

## 6.1 MigrationRatifier — Params Storage (src/ratifiers/MigrationRatifier.sol)

Per-tuple `UserMigrationParams` storage. Stores renewal configuration keyed by `(user, callback, sourceMarketId, targetMarketId)`. Auth for mutation via `midnight.isAuthorized` delegation.

| ID | Property | Description |
|----|----------|-------------|
| REG-1 | **Authorized mutation only** | `setParams` and `clearParams` require either `msg.sender == onBehalf` or `MORPHO_MIDNIGHT.isAuthorized(onBehalf, msg.sender)`. Third parties cannot modify a user's stored params. |
| REG-2 | **Single active entry per tuple** | For any given `(user, callback, sourceMarketId, targetMarketId)` tuple, there is exactly one active `UserMigrationParams`. `setParams` overwrites atomically. |
| REG-3 | **Clear is total** | After `clearParams(user, cb, src, tgt)`, the stored params are zeroed. No partial state remains. |

---

## 6.2 MigrationRatifier — Midnight Ratifier (`isRatified`) (src/ratifiers/MigrationRatifier.sol)

The migrating user is the offer **maker** (`offer.maker == user`, `offer.ratifier == MigrationRatifier`, `offer.callback == <migration callback>`, `offer.group` carrying `MIGRATION_GROUP_HEADER`). A counterparty fills it via `midnight.take(offer, ratifierData, ...)`. Midnight enforces the user's opt-in (`isAuthorized[offer.maker][offer.ratifier]`, set via `MORPHO_MIDNIGHT.setIsAuthorized`) and calls `MigrationRatifier.isRatified(offer, ratifierData, taker)`, which returns `CALLBACK_SUCCESS`. `ratifierData = abi.encode(bytes32 sourceTenorMarketId, bytes32 targetTenorMarketId)`; the user is `offer.maker` and the callback is `offer.callback`. `isRatified` is a `view` with no caller restriction — Midnight's `isAuthorized[maker][ratifier]` is the real gate. It looks up `userParams[offer.maker][offer.callback][src][tgt]` and calls `BaseMigrationRatifier._ratify`. All RATE-*, ORCH-5..11, ORCH-14 properties live in the ratifier composition (`BaseMigrationRatifier` + `MigrationRatifier`).

| ID | Property | Description |
|----|----------|-------------|
| ORCH-NEW-6 | **Seller receiver pinned to the user's callback** | `_ratify` reverts `InvalidReceiver` unless `offer.receiverIfMakerIsSeller == (offer.buy ? address(0) : offer.callback)` — when the maker is the seller, sale proceeds must route to the user's own callback; when the maker buys, the unused receiver must be `address(0)`. Otherwise proceeds could be skimmed whenever the callback happens to hold a balance. |
| ORCH-NEW-7 | **Ratified-offer group confined to a reserved namespace** | `_ratify` reverts `InvalidGroup` unless `offer.group & MIGRATION_GROUP_HEADER_MASK == MIGRATION_GROUP_HEADER` — the top 6 bytes equal the `"tenor"` domain prefix plus an schema version byte, with the `0xE0`–`0xEF` version range reserved for migration groups. The offer is the user's own maker offer, and settling it makes Midnight increment `consumed[offer.maker][offer.group]`. Confining migration groups to the reserved version keeps that write disjoint from the user's own groups — signed limit orders and `executeAndConsume` self-limit groups carry a different version — so a counterparty cannot alias one and poison a user's fill accounting (premature cancellation, or overfill via the unit/asset-domain mismatch in Midnight's single raw counter). Off-chain group construction must keep signed/self-limit groups out of the reserved migration version; a group that sets it only exposes that user. (#488 group-namespace rationale.) |
| ORCH-NEW-8 | **`ratifierData` length check** | `isRatified` reverts `InvalidRatifierData` unless `ratifierData.length == 64`. Only a well-formed `(sourceTenorMarketId, targetTenorMarketId)` pair is accepted before the `(src, tgt)` decode. |
| ORCH-NEW-9 | **User opt-in via Midnight; ratifier has no caller gate** | The user opts in by setting `MORPHO_MIDNIGHT.isAuthorized[offer.maker][address(this)] = true` (via `setIsAuthorized`). That Midnight authorization — checked by Midnight before it invokes the ratifier — is the only gate. `isRatified` itself is a `view` with no `msg.sender` restriction; it can be called by anyone and only ever returns `CALLBACK_SUCCESS` or reverts. |
| DEFAULT-1 | **RATE-3 directionality matches main's mapping** | `_userIsBuy(callback)` returns `true` iff `callback ∈ { LEND_VAULT_TO_MIDNIGHT, BORROW_MIDNIGHT_TO_BLUE, LEND_MIDNIGHT_RENEWAL }`. Equivalent to main's per-take hardcoded `isBuy` argument. Evaluated during ratification (in `_ratifyRate`, reached from `isRatified`) keyed by `(offer.maker, offer.callback, src, tgt)` with `(src, tgt)` from `ratifierData`. |
| DEFAULT-2 | **callbackData fee fields must match ProtocolFeeConfig** | The decoded `(feeRate, feeRecipient)` from the callback context MUST equal `getEffectiveFeeConfig(callback, feeMarketId).{feeRate, feeRecipient}` (`InvalidFeeConfig` otherwise). A counterparty cannot run a take with stale or forged fee config. |
| DEFAULT-3 | **callback-derived source/target must match `ratifierData`** | The `(sourceMarketId, targetMarketId)` derived from the callback context (per callback type) MUST equal the `(src, tgt)` decoded from `ratifierData` (`InvalidCallbackData` otherwise). |
| DEFAULT-4 | **tick must match offer** | For V2→V2 and V1→V2 callbacks, the callback-context tick MUST equal `offer.tick`. V2→V1 callbacks have no tick field and are exempt. |

> The old IIntentRatifier interface invariants (view enforcement, own-storage scoping, callbackData cross-validation, caller-principal forwarding) and the settler-only / intent-names-this-ratifier guards are obsolete: the `IIntentRatifier` interface, the `Intent` envelope, and the standalone settler are removed, and `isRatified` runs as a Midnight ratifier with no caller gate. The old settler-only and intent-ratifier-match guards are superseded by the IntentSettler removal.

In `_ratifyRate`, because the user is always the offer maker, the Midnight settlement-fee term is always 0 (the maker pays no settlement fee); the rate check nets only the protocol fee. The policy `getRate(...)` receives `user == offer.maker` as the position owner; there is no separate caller principal.

---

## 7. TenorRouter — Batch Execution Properties (src/router/TenorRouter.sol)

### Fill & Slippage

| ID | Property | Description |
|----|----------|-------------|
| ROUTER-1 | **Fill cap respected** | Aggregate filled amount in the `fillAxis` dimension never exceeds `maxFill`. |
| ROUTER-2 | **Minimum fill enforced** | Reverts `InsufficientFill` if aggregate fill < `minFill`. |
| ROUTER-3 | **Price slippage bounds enforced** | Aggregate `totals[sideAssetsIndex] / totals[FILL_UNITS]` must lie in `[minPrice, maxPrice]`. `sideAssetsIndex` is auto-pinned to the batch side via `_initiatorIsBuyer(actions[0], initiator)`. Rounding is taker-adverse (ceil for `maxPrice`, floor for `minPrice`). |
| ROUTER-4 | **Same market** | Every action's `offer.market` matches `actions[0]`'s. Reverts `InconsistentMarket`. |
| ROUTER-5 | **Same side** | Every action's `_initiatorIsBuyer(action, initiator)` matches `actions[0]`'s. Reverts `InconsistentSide`. |
| ROUTER-7 | **ASSETS axis is batch-side** | `fillAxis == ASSETS` resolves to `BUYER_ASSETS` or `SELLER_ASSETS` via `_initiatorIsBuyer(actions[0], initiator)`. Capping on the counterparty's flow is unrepresentable. |
| ROUTER-10 | **Take-sizers never revert, tight, `uint128`-saturating** | `_capTakeUnits`'s sizing helpers (`TakeMathLib`, `RouterLib.budgetToUnits`) intentionally deviate from Midnight's `ConsumableUnitsLib`/`TakeAmountsLib`: degenerate or non-binding constraints (zero price, overflow, `offerPrice < settlementFee`) saturate to `uint128.max` instead of reverting, and the inverses are tight (largest units whose forward image fits the budget — `TakeAmountsLib` under-fills BUY offers, see morpho-org/midnight#952). Midnight enforces take validity at take time. |
| ROUTER-13 | **`mulDivDownInverse` non-binding cap saturates** | `TakeMathLib.mulDivDownInverse(target, ...)` returns `type(uint256).max` when `target == type(uint256).max` (a non-binding cap), short-circuiting the `target + 1` checked-add overflow. Since `Offer.maxAssets` is `uint128`, the largest non-binding cap an offer can carry is `type(uint128).max`, so `remainingAssets` never reaches `type(uint256).max` and the `target == type(uint256).max` short-circuit is no longer reachable through `getOfferRemaining` (it remains a general division-by-zero / non-binding guard). Even so, `remainingAssets <= type(uint128).max` keeps `target + 1` from overflowing, so a malicious BUY asset-denominated offer cannot DoS the routing batch (pre-dispatch, outside `allowRevert`). Both inverses also short-circuit `num == 0` (zero price ⇒ vacuous constraint) to `uint256.max` rather than dividing by zero. |

### Action Dispatch

| ID | Property | Description |
|----|----------|-------------|
| ROUTER-8 | **Failed action handling** | A failed action either reverts the entire batch or is skipped based on `action.allowRevert`. |
| ROUTER-9 | **`reduceOnly` opt-in** | `params.reduceOnly = true` reverts `ReduceOnlyViolated` if the initiator's wrong side grows across the batch — credit for buyer-side, debt for seller-side. Net-across-batch (weaker than `Offer.reduceOnly`'s per-take). Available unconditionally — the initiator is always the taker. |
| ROUTER-11 | **`executeAndConsume` counts every fill once** | `consumed[initiator][consumeGroup]` is read after execution and advanced by taker-side raw fills. Since the initiator is always the taker, every direct fill is a taker-side fill and is counted. Maker-side fills — reentrant nested fills of the initiator's own resting offers — are counted by Midnight under `consumed[initiator][offer.group]`, so each fill lands exactly once. |
| ROUTER-12 | **`maxConsumed` aggregate cap** | The counter is accounting, not an atomic in-tx cap. `maxConsumed` bounds `consumed[initiator][consumeGroup]` after the write, reverting `ConsumedCapExceeded` on overfill from front-running or mid-batch interleaving. `maxConsumed` is `uint128`; `type(uint128).max` disables. |
| ROUTER-14 | **`executeAndConsume` counts only top-level fills** | The consumed advance sums top-level taker fills (`rawTotals`); taker fills settled inside a callback are not counted (complements ROUTER-11, which covers maker-side nested fills). So both the `maxConsumed` cap and the persisted counter undercount nested taker fills — the cap can pass and OCO/self-limit stay incomplete when unknown maker callbacks are in the batch. |

### Fee Adjuster (src/router/CallbackFeeAdjuster.sol)

| ID | Property | Description |
|----|----------|-------------|
| ADJUSTER-1 | **Adjuster cannot worsen user outcome** | Specifying a fee adjuster can never put the user in a worse position than not specifying one. The adjuster can only tighten the router's fill/slippage accounting — the sign of its effect is fixed at the router (buyer pays more / seller receives less), so a user cannot end up borrowing at a worse rate or lending at a lower yield because of an adjuster, regardless of adjuster behavior. |
| ADJUSTER-2 | **`beforeDispatch` never overshoots in effective space** | For the fill dimension where the callback fee lands (buyer dim with `!offer.buy`, seller dim with `offer.buy`), the returned `takeUnits` satisfies `effectiveAmount(takeUnits) <= remainingBudget`. Achieved by inverting against the dominant (worst-case) per-unit price composing Midnight's forward price with Tenor's effective price: MAX for buyer, MIN for seller. For other fill dimensions, the adjuster delegates to `RouterLib.budgetToUnits`' tight inversion (ROUTER-10). |
| ADJUSTER-3 | **`afterDispatch` matches the callback's onchain fee** | For the configured `feeRate` and `FeeFormula`, `afterDispatch` returns exactly the fee the corresponding callback charges onchain. INTEREST uses `CallbackLib.{buyer,seller}FeeFromTick`; PERCENTAGE uses `CallbackLib.percentageFee`. If the adjuster's config drifts from the callback's config, tracking drifts — but no funds move (the adjuster is view-only and the router books only in the taker-worsening direction). |
| ADJUSTER-4 | **`beforeDispatch` is orientation-aware** | The initiator is always the taker, so the settlement fee is folded into the price for the taker-side fill dimension (`(fillIndex == FILL_BUYER_ASSETS) != offer.buy`). The PERCENTAGE seller inverse matches Midnight's seller-receipt forward rounding — down for BUY (taker-seller), up for SELL (maker-seller) — so the cap never overshoots `remainingBudget` (would cause post-dispatch `FillOvershoot`). |

---

## 8. MidnightLib — View Helper Properties (src/libraries/MidnightLib.sol)

| ID | Property | Description |
|----|----------|-------------|
| ML-1 | **Mirrors isHealthy** | `computeMaxDebt` must produce the same result as Midnight's internal `isHealthy()` check. A divergence means clamps make health decisions on wrong data. |

---

## 9. Gates — Access Control Properties

### 9a. DelayedLiquidationGate (src/gates/DelayedLiquidationGate.sol)

| ID | Property | Description |
|----|----------|-------------|
| GATE-1 | **Grace period required** | `liquidate()` reverts with `LiquidationNotAllowed` if `block.timestamp <= maturity` and no grace period has been started (or it hasn't elapsed). |
| GATE-2 | **Grace period timing** | After `startGracePeriod()`, liquidation is allowed only during `[startTime + GRACE_PERIOD, startTime + GRACE_PERIOD + LIQUIDATION_PERIOD)`. Before or after this window, `_requireLiquidationAllowed` reverts. |
| GATE-3 | **Health check for grace start** | `startGracePeriod()` reverts with `PositionIsHealthy` if the borrower's position is still healthy. Only unhealthy positions can enter a grace period. |
| GATE-4 | **Post-maturity bypass** | When `block.timestamp > obligation.maturity`, `_requireLiquidationAllowed` skips the grace period check entirely — liquidation is always allowed post-maturity. |

### 9b. VaultV2AllowlistGate (src/gates/VaultV2AllowlistGate.sol)

| ID | Property | Description |
|----|----------|-------------|
| GATE-5 | **Fee recipient auto-allow** | `canReceiveShares`, `canSendShares`, and `canReceiveAssets` return `true` if `account` is the vault's `managementFeeRecipient()` or `performanceFeeRecipient()`, even if not explicitly allowlisted (`canSendAssets` has no fee-recipient exemption). This prevents fees from silently accruing as zero. Note: the effective receive-share set is only fully frozen if BOTH the gate is renounced AND the vault's fee-recipient setters (`setManagementFeeRecipient`, `setPerformanceFeeRecipient`) are abdicated upstream — a vault curator with active setters can post-renounce nominate any address as fee recipient, making it share-eligible. |

### 9c. MidnightVaultExecutor (src/periphery/MidnightVaultExecutor.sol)

Executor for vault shares used as Midnight collateral behind a VaultV2AllowlistGate, allowlisted on the gate so vault shares can be minted to / redeemed from it. The contract uses a callback-based design: the entry/exit helpers `depositAndAddCollateral` and `withdrawCollateralAndRedeem` are called directly, while repays run through Midnight's `repay` with the executor as the `IRepayCallback` (`onRepay`), and liquidations run through `Midnight.liquidate` called **directly by the liquidator** with the executor passed as `receiver` and `ILiquidateCallback` (`onLiquidate`); both callbacks self-fund the repay from the redeemed loan-token proceeds via `_fundRepay`. The vault is derived from `market.collateralParams[collateralIndex].token`, not caller-supplied. **Incompatible deployment combination**: `MidnightVaultExecutor` cannot be used on a market whose `liquidatorGate` is `DelayedLiquidationGate`. That gate is itself a liquidation router (liquidators call the gate, which calls `Midnight.liquidate` with the gate as receiver), so vault-share collateral that must be redeemed through the executor-as-receiver becomes unliquidatable — the seized shares would transfer to the un-allowlisted gate and revert.

| ID | Property | Description |
|----|----------|-------------|
| EXEC-1 | **Auth on entry/exit; liquidation gated by Midnight** | The direct functions (`depositAndAddCollateral`, `withdrawCollateralAndRedeem`) revert `Unauthorized` unless `msg.sender == onBehalf` or `isAuthorized(onBehalf, msg.sender)` on Midnight (`_checkAuthorized`). The executor performs no liquidator auth itself: the liquidator calls `Midnight.liquidate` directly, so Midnight's own `liquidatorGate` checks the liquidator — the executor is merely the receiver/callback (and must be the receiver, see EXEC-5). |
| EXEC-2 | **Vault/loan-token validation** | Every path derives `vault = market.collateralParams[collateralIndex].token` and requires `IERC4626(vault).asset() == market.loanToken`, reverting `CallbackLib.TokenMismatch` otherwise. Prevents operating on the wrong vault. |
| EXEC-3 | **No custody across calls** | Pass-through, not custody. Repay/liquidate are funded strictly from assets redeemed inside the same callback, so loan tokens or shares left on the executor outside an active call are neither usable nor recoverable. |
| EXEC-4 | **Exact-amount approvals** | All approvals are exact and per-call: `depositAndAddCollateral` approves exactly the deposited/minted assets and the resulting shares; `_fundRepay` (the shared tail of `onRepay`/`onLiquidate`) sweeps any surplus beyond `repaidUnits` to `onBehalf` (repay path) or the liquidator (liquidation path) and approves Midnight for exactly `repaidUnits`. No max approvals are used. |
| EXEC-5 | **Midnight callback hooks only callable by Midnight** | Both `onRepay` and `onLiquidate` revert `CallbackLib.OnlyMidnight` if `msg.sender != MORPHO_MIDNIGHT`; `onLiquidate` additionally reverts `LiquidationReceiverMismatch` unless `receiver == address(this)`. Prevents direct invocation outside a Midnight-driven repay or liquidation flow. |

### 9d. Vault Callback Gate Compatibility

| ID | Property | Description |
|----|----------|-------------|
| CB-GATE-1 | **No share transfers to non-allowlisted addresses** | `MidnightWithdrawVaultSharesCallback` never transfers vault shares to the buyer. It only withdraws the shares needed for `buyerAssets` via `previewWithdraw` and redeems to the callback itself. Remaining collateral stays on Midnight. |
| CB-GATE-2 | **Supply callback share flow** | `MidnightSupplyVaultSharesCallback` deposits into vault (shares to callback), then immediately supplies as collateral on Midnight. Shares are never sent to the seller. |

### 9e. MidnightAllowlistGate (src/gates/MidnightAllowlistGate.sol)

Role-based allowlist gate. Configured as the `enterGate` and/or `liquidatorGate` on a Midnight obligation. Each entry carries three booleans (`canIncreaseCredit`, `canIncreaseDebt`, `canLiquidate`).

| ID | Property | Description |
|----|----------|-------------|
| MAL-1 | **Gate views read the per-account allowlist verbatim** | `canIncreaseCredit(account) == allowlist[account].canIncreaseCredit`, and analogously for `canIncreaseDebt` and `canLiquidate`. A non-allowlisted address defaults to `false` on all three. |
| MAL-2 | **Mutation owner-gated** | `setAllowlist(Role[])` is `onlyOwner` (`Ownable2Step`). Overwrites each entry atomically; emits `MidnightAllowlistUpdated` per role. No third party can mutate the allowlist. |
| MAL-3 | **Renounce makes allowlist immutable** | After `renounceOwnership()`, no further `setAllowlist` calls are possible. The allowlist is frozen at whatever state the owner left it in. |

---

## 10. OracleWithValidation (src/oracles/OracleWithValidation.sol)

Wraps a primary oracle and cross-checks each price read against a validation oracle. The returned price is always from the primary; the validation oracle only causes reverts. The owner can pause validation (e.g. to deprecate a failing secondary feed) and — by then renouncing ownership — make that pause permanent.

| ID | Property | Description |
|----|----------|-------------|
| ORA-1 | **Zero primary price is not special-cased** | `price()` does not check for a zero primary price; a zero is returned verbatim (subject to the same deviation/validation checks as any other value). Zero-price handling was removed in #537. |
| ORA-2 | **Deviation bound enforced** | When validation is unpaused and the validation call succeeds, `price()` reverts `ExcessiveOracleDeviation` if `abs(primary - validation) > primary * MAX_ORACLE_DEVIATION / 1e18` (rounded down — `mulDivDown`). |
| ORA-3 | **Paused short-circuits validation** | When `validationCheckPaused == true`, `price()` returns the primary price directly and never queries the validation oracle (no zero-check is performed — see ORA-1). |
| ORA-4 | **Validation failure mode is immutable** | `REVERT_ON_VALIDATION_ORACLE_FAILURE` is set at deploy time and never changes. When `true`, a reverting validation oracle reverts `price()` with `ValidationOracleFailure`; when `false`, a reverting validation oracle is swallowed and the primary price is returned. |
| ORA-5 | **Returned price is always primary** | `price()` either reverts or returns `PRIMARY_ORACLE.price()` verbatim. The validation oracle's value is never returned. |
| ORA-6 | **Pause + renounce is a permanent pause** | After `pauseValidationCheck()` (owner-only) followed by `Ownable2Step.renounceOwnership()`, the contract is permanently locked into primary-only mode. Intentional — lets the deployer deliberately deprecate a validation oracle. |
| ORA-7 | **Validation returndata payload bounded** | A successful validation call with returndata **shorter than 32 bytes** reverts (the implicit ABI decode fails outside the try/catch failure branch); returndata of 32 bytes or **longer** is silently truncated to the first 32 bytes (no revert — the first word is used as the validation price), so a non-conforming oracle that returns *more* than 32 bytes fails open, not closed. Deployers must point at a validation oracle whose `price()` returns exactly `(uint256)`. |

### 10b. OracleWithValidationFactory (src/factories/OracleWithValidationFactory.sol)

Canonical entry point for deploying `OracleWithValidation` instances. Tenor UI surfaces only oracles deployed through this factory.

| ID | Property | Description |
|----|----------|-------------|
| FACT-1 | **Deployment preconditions** | `createOracleWithValidation` reverts `NotAllowed` if `primaryOracle == address(0)`, if `validationOracle == address(0)`, if `primaryOracle == validationOracle`, or if `maxOracleDeviation >= 1e18`. The last bound prevents a literal 100% deviation (vacuous check) but is not a risk-aware safety bound — values like `1e18 - 1` are accepted. A meaningful per-market maximum (derived from the collateral's LLTV and liquidation assumptions) is enforced off-chain by UI-level oracle allowlisting. |
| FACT-2 | **Deployment tracking** | Each successful deployment sets `isDeployedOracle[oracle] = true` and emits `OracleWithValidationDeployed` with all constructor arguments + salt. Provides a downstream provenance signal (UI / monitoring can filter on factory-deployed instances). |

---

## 11. Assumptions

| ID | Assumption | Description |
|----|------------|-------------|
| ASSUME-TOKEN-1 | **No fee-on-transfer tokens** | Loan tokens and collateral tokens do not have fee-on-transfer, rebasing, or blocklist behavior. All callbacks assume `transfer(to, amount)` delivers exactly `amount`. |
| ASSUME-POLICY-1 | **Policy and cadence trust** | `IInterestRatePolicy` and `IRenewalCadence` contracts are trusted by the position owner. A malicious policy can block or manipulate rate checks for that owner's renewals only. A policy returning `type(uint256).max` may cause overflow in `ratePerSecond * duration`. |
| ASSUME-FEE-1 | **Fee recipient accepts tokens** | Fee recipients must be capable of receiving ERC20 tokens without reverting. A reverting fee recipient permanently blocks all takes for that callback/market. |
| ASSUME-REENTRANT-1 | **No reentrancy from externals** | Morpho Midnight prevents reentrant callbacks. Token contracts, Morpho Blue, and ERC4626 vaults do not call back into callback contracts. |
| ASSUME-VAULT-1 | **ERC4626 vault trust** | ERC4626 vaults used in lend callbacks are trusted. Their `withdraw()`/`deposit()` functions return accurate share/asset amounts and do not re-enter. |
| ASSUME-VAULT-2 | **Vault share-price manipulation resistance** | The vault callbacks and `MidnightVaultExecutor` settle deposits/withdrawals/redemptions at the vault's reported share price, with no onchain slippage or share-price bound. This relies on the vault being resistant to atomic share-price manipulation (e.g. donation/sandwich). Legitimate share-price decline is a collateral-value risk handled by the market LLTV, not by these callbacks. |
| ASSUME-VAULT-3 | **`previewWithdraw` parity** | `MidnightWithdrawVaultSharesCallback.onBuy` pulls `previewWithdraw(buyerAssets)` shares from the buyer's collateral, then burns them via `vault.withdraw(buyerAssets)`, assuming `withdraw(assets)` burns *exactly* `previewWithdraw(assets)` shares in the same transaction. ERC-4626 only requires `withdraw` to burn no more shares than `previewWithdraw`, so a lazy-accrual vault returns a stale, inflated preview and the surplus shares are stranded on the callback. Holds for Vault V2: `withdraw` and `previewWithdraw` share the same `block.timestamp`-based accrual, and the intervening `withdrawCollateral` is a share transfer that leaves `totalSupply`/`totalAssets` unchanged. Validate any new vault before listing it as collateral. |
| ASSUME-VAULT-4 | **`deposit()` return equals shares minted** | The supply paths that forward `deposit()`'s return value as the share count to supply as collateral — `MidnightSupplyVaultSharesCallback.onSell` and `MidnightVaultExecutor.depositAndAddCollateral` — assume that return equals the shares actually minted. ERC-4626 does not require this, so a non-compliant vault would under-supply collateral and strand the remainder. Holds for Vault V1 (MetaMorpho v1.1 `deposit` returns the minted `shares`) and Vault V2 (`deposit` returns `previewDeposit`, exactly what `createShares` mints). |
| ASSUME-TICK-1 | **Midnight TickLib trusted** | `lib/midnight/src/libraries/TickLib` is a trusted upstream dependency. Tenor relies on: `tickToPrice(tick) <= 1e18` for `tick <= MAX_TICK`, monotonicity in `tick`, `priceToTick(p, spacing)` returning a `spacing`-multiple tick with `tickToPrice(priceToTick(p,s)) >= p`, and rounding to `PRICE_ROUNDING_STEP = 1e11` multiples. Constants (`MAX_TICK = 6744`, `PRICE_ROUNDING_STEP = 1e11`) are audited as part of Midnight. |
| CLAMP-A1 | **Maker-constrained only** | Clamps strictly restrict on the maker's constraints. It is the taker's responsibility to ensure their account has sufficient balance, allowance, and health. |

### Router Assumptions (Well-Formed Input)

The router does **not** validate its input. If input is malformed, no execution guarantees are provided.

| ID | Assumption | Description |
|----|------------|-------------|
| ROUTER-A1 | **Non-empty actions when `ASSETS` axis is used** | `fillAxis == ASSETS` reads `actions[0]` to derive the batch side. Sentinel resolution and `executeAndConsume`'s counter read also dereference `actions[0]`. |
| ROUTER-A2 | **Compatible clamps** | Specified clamp addresses are compatible with the corresponding action types. |
| ROUTER-A3 | **Truthful outcomes** | The outcome returned by taken offers truly reflects the filled amounts (i.e., no hidden callback fee that distorts `buyerAssets`/`sellerAssets` without a corresponding fee adjuster). |
| ROUTER-A4 | **Fee adjuster required under non-zero callback fees** | `Midnight.take` returns raw Midnight amounts; they do not fold in the callback-charged fee. With a non-zero fee and `feeAdjuster == address(0)`, `totals[fillIndex]` understates effective spend and the pre-dispatch cap oversizes the fill. At production's `feeRate = 0` this is a no-op; when fees activate, callers must wire a matching `ICallbackFeeAdjuster`. |
| ROUTER-A5 | **Non-reverting pre-dispatch helpers** | The initiator is always the taker, so `allowRevert: true` wraps `Midnight.take()` only. Pre-dispatch work — action decoding, `touchMarket`, `_capTakeUnits` (`RouterLib`, `TakeMathLib`, fee adjuster) — is outside the soft-fail boundary. Callers must supply clamps (CLAMP-3) and fee adjusters that do not revert on adversarial offers, or batched actions can abort the whole batch. |
| ROUTER-A6 | **`(callback, FeeFormula)` consistency** | `CallbackFeeAdjuster` trusts `feeAdjusterData`'s `FeeFormula` selector without cross-checking it against the action's callback type. Callers must specify the formula that matches the callback (INTEREST for tick-based callbacks; PERCENTAGE for V2→V1 flat-fee callbacks). A mismatched formula lets router accounting under-account for the fee actually charged onchain — router-level limits then enforce against under-reported totals. No fund flow vs. correct adjuster (ADJUSTER-3), but `maxFill`/slippage protections become looser. |

---

## Priority

| Priority | Properties | Rationale | Coverage |
|----------|-----------|-----------|----------|
| **P0** | RATE-1, RATE-2, RATE-3, ORCH-4 | Rate bound enforcement — core user protection against unfavorable rates | Tested |
| **P0** | CB-RATE-1, CB-RATE-2 | Fee-rate distortion band — ensures fees don't silently undermine rate limits | Gap |
| **P0** | CB-FEE-1, CB-FEE-2, CB-FEE-3, CB-FEE-4 | Fee safety — fees bounded by assets, tick fees bounded by interest | Tested |
| **P0** | CB-CLOSE-1, CB-CLOSE-2 | Source position full closure — all paths can fully close source, V1 rounding compatible | CB-CLOSE-1: Partial (via clamp fuzz), CB-CLOSE-2: Tested |
| **P0** | CB-SRC-1, CB-DIR-1 | Source position integrity — exclusive funding, exit source / open target only (no crossing) | Gap |
| **P0** | ORCH-NEW-9 | User opt-in via Midnight `isAuthorized[maker][ratifier]`; `isRatified` reverts on any unconfigured tuple — the gate that keeps an unauthorized take from ever reaching Midnight | Tested |
| **P1** | CB-DUST-1 | No residual funds in callback contracts | Tested |
| **P1** | CB-FINAL-1..2, CB-FINAL-4, CTL-1, CTL-2 | Final fill completeness — prevents collateral stranding | Tested |
| **P1** | CB-FINAL-3 | Final fill V2-to-V1 (full collateral transfer on sourceDebtAfter == 0) | Gap |
| **P1** | CB-V1-REP-1 | V1→V2 borrow rejects overpayment of V1 debt | Tested |
| **P1** | CB-VAULT-WD-1 | Withdraw vault shares: no shares retained on callback (subject to previewWithdraw consistency) | Tested |
| **P1** | CB-LTV-1 | Vault supply overcollateralization — share supply leaves position healthy | Gap |
| **P1** | CB-SC-CAP-1 | SupplyCollateral borrow-capacity-usage cap — maker-bounded liquidation distance | Tested |
| **P1** | CB-AUTH-1 | Callback access control | Pre-existing |
| **P1** | ORCH-5, ORCH-6, ORCH-7, ORCH-8 | Timing invariants — post-maturity always executable, pre-maturity window enforced | Tested |
| **P1** | ORCH-9, ORCH-10, ORCH-11 | Target maturity constraints — strictly increasing, duration bounds, cadence | Tested |
| **P1** | ORCH-12, ORCH-13 | Return value accuracy and V2-to-V1 post-maturity duration | Tested |
| **P1** | ID-1, ID-2 | Market ID correctness — maturity excluded, all other fields included | Tested |
| **P1** | CLAMP-1..4 | Clamp correctness — safety, tightness, no-revert, source exhaustion | Tested |
| **P1** | ROUTER-1..5, ROUTER-7, ROUTER-8 | Fill/slippage enforcement, same market/side batch invariants, taker-pinned ASSETS axis, allow-revert handling | Pre-existing + new (4/5/7 tested in PR #465) |
| **P1** | ADJUSTER-1, ADJUSTER-2, ADJUSTER-3 | Fee adjuster: monotonic tightening, conservative `beforeDispatch` cap, `afterDispatch` matches callback | Tested |
| **P1** | ML-1 | MidnightLib mirrors isHealthy — clamp health checks use correct formula | Gap |
| **P1** | ORCH-1, ORCH-2, ORCH-3, ORCH-14, ORCH-15 | Fee config bounds, layering, market ID selection, and migration-group isolation | Tested (ORCH-14: Gap, ORCH-15: By inspection) |
| **P1** | ORCH-NEW-6..8 | Ratifier `isRatified` guards — seller-receiver pinning, reserved group namespace, 64-byte `ratifierData` length | By inspection |
| **P1** | DEFAULT-1..4 | MigrationRatifier validation — directionality mapping + fee/source-target/tick consistency against `ratifierData` and protocol state, inside `isRatified` | Tested |
| **P1** | REG-1..3 | MigrationRatifier param storage — authorized mutation only, single active entry per tuple, clear is total | Tested |
| **P1** | ORA-1..7 | OracleWithValidation: deviation enforced, paused short-circuit, immutable failure mode, permanent pause, returndata bounds | Pre-existing |
| **P1** | PRICE-1..4 | PriceLib: formula bounds, conservative rounding, effective-rate selection, comparison directionality (underlies RATE-1..3) | Tested (via RATE-* fuzz) |
| **P1** | CL-1..5 | CallbackLib: vault-collateral integrity, percentage-fee cap, effective-price rounding favors user, interest-fee rate bound, sorted-array lookup | Tested |
| **P2** | SRP-1..2 | Rate interpolation — continuity, boundary clamping, segment boundedness | Tested |
| **P2** | LERP-1..2 | LinearInterpolationLib: input validation reverts and sorted-knots precondition | Tested |
| **P2** | PAUSE-1..3 | PausableStaticRatePolicy: pause gates getRate, asymmetric pause/unpause auth, idempotency reverts | Tested |
| **P2** | CAD-1 | FourWeekCadence: 28-day floor from epoch | Tested |
| **P2** | GATE-1..4 | Delayed liquidation timing — grace period, health check, post-maturity bypass | Tested |
| **P2** | GATE-5 | Fee recipient auto-allow in VaultV2AllowlistGate | Tested |
| **P2** | EXEC-1..5 | Executor auth, vault validation, pass-through (no custody across calls), approvals, callback hooks | Tested |
| **P2** | CB-GATE-1, CB-GATE-2 | Callback gate compatibility — no share transfers to non-allowlisted | Tested (unit + integration) |
| **P2** | MAL-1..3 | MidnightAllowlistGate: per-account role views, owner-only mutation, renounce freezes allowlist | Tested |
| **P2** | FACT-1..2 | OracleWithValidationFactory: deployment preconditions, factory-deployed provenance tracking | Tested |
| **P2** | CTL-3 | Sorted lookup correctness | Gap |

