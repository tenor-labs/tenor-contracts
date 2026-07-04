# Oracle With Validation

A Morpho-compatible oracle that checks the deviation between a primary and a validation oracle onchain before the price is consumed by a Morpho market (Morpho Blue, Morpho Midnight).

## Overview

`OracleWithValidation` conforms to the Morpho `IOracle` interface. The primary oracle is always used for the price, but `price()` reverts if the deviation from the validation oracle exceeds `MAX_ORACLE_DEVIATION`. This prevents a malfunctioning primary oracle from feeding erroneous prices into a market.

## Contracts

### OracleWithValidation

The core oracle. Implements `IOracleWithValidation`, which extends the Morpho `IOracle` interface, and inherits `Ownable2Step`.

**Key Features:**
- Returns the price from the primary oracle (e.g. Chainlink)
- Validates it against a validation oracle (e.g. TWAP, Chronicle, Redstone)
- Reverts with `ExcessiveOracleDeviation` if the deviation exceeds `MAX_ORACLE_DEVIATION`
- Owner can pause/unpause the validation check (`pauseValidationCheck` / `unpauseValidationCheck`). Renouncing ownership while unpaused makes the validated configuration permanently enforced (no pause possible); renouncing while paused permanently locks the wrapper into primary-only mode.

**Immutable Parameters:**
| Parameter | Description |
|-----------|-------------|
| `PRIMARY_ORACLE` | The primary oracle whose price is always returned |
| `VALIDATION_ORACLE` | The validation oracle used to bound-check the primary's price |
| `MAX_ORACLE_DEVIATION` | Maximum allowed `\|primary - validation\| / primary` deviation, in WAD (e.g. `5e16` = 5%) |
| `REVERT_ON_VALIDATION_ORACLE_FAILURE` | If true, `price()` reverts when the validation oracle call reverts. If false, the primary price is returned unchecked. |

**Storage:**
| Variable | Description |
|----------|-------------|
| `validationCheckPaused` | When true, `price()` returns the primary price without validation |

**Deviation Calculation:**
```
absoluteDeviation = |primaryPrice - validationPrice|
maxAllowedDeviation = (primaryPrice * MAX_ORACLE_DEVIATION) / 1e18
if (absoluteDeviation > maxAllowedDeviation) revert ExcessiveOracleDeviation()
```

The deviation is scaled by the primary price, so a threshold `d` allows up to `d / (1 - d)` overpricing relative to the validation oracle (e.g. 5% configured allows ~5.26% effective).

### OracleWithValidationFactory

CREATE2 factory deploying `OracleWithValidation` instances (`src/factories/OracleWithValidationFactory.sol`).

**Functions:**
- `createOracleWithValidation(...)` — deploy a new oracle instance via CREATE2. Reverts with `NotAllowed` if an oracle address is zero, the two oracles are identical, or `maxOracleDeviation >= 1e18`.
- `isDeployedOracle(address)` — whether the address was deployed by this factory.

> Direct deployment of `OracleWithValidation` bypasses these checks. Deploying through the factory is recommended so that `maxOracleDeviation >= 1e18` and degenerate oracle configurations are rejected.

## Configuration Guidelines

### Setting MAX_ORACLE_DEVIATION

The deviation threshold should be:
- **Wide enough** to accommodate natural oracle price differences
- **Narrow enough** to prevent manipulation attacks
- **Below** `(1 - LLTV * maxLif)`, where `maxLif = 1 / (1 - liquidationCursor * (1 - LLTV))` is the per-collateral maximum liquidation incentive factor. `Midnight.liquidate` books bad debt as `debt - collateralValue / maxLif` per collateral, so a liquidation can clear at most `collateralValue / maxLif` of debt — the incentive eats part of the `(1 - LLTV)` cushion. If the primary oracle overestimates the true price by more than `(1 - LLTV * maxLif)`, a position opened at the LLTV limit cannot be fully repaid even after seizing all its collateral, and the shortfall becomes bad debt. `MAX_ORACLE_DEVIATION` is `|primary - validation| / primary`, the same high-side fraction the bound is expressed in.

  This is a recommended ceiling, not a precise safety line: it assumes a single collateral, the oracle inflated by the full deviation at open then correcting to the true price, and full seizure at `maxLif`. Real positions can hold many collaterals, each with its own `LLTV`, `liquidationCursor`, and `maxLif`, summed across the basket; and the validation oracle is only a proxy for the true price. Set the deviation below `(1 - LLTV * maxLif)` per collateral, with headroom for natural oracle drift.

**Caveats when sizing the threshold:**

1. **Validation oracle may also drift from the true price.** The bound above assumes the validation oracle tracks the true price exactly and the primary is the only one that deviates. In practice, validation can drift too. Set `MAX_ORACLE_DEVIATION` below `(1 - LLTV * maxLif)` and leave headroom for normal deviation between two honest oracles (feed update cadence, decimal rounding, sequencer lag, TWAP smoothing). A reasonable starting point is `MAX_ORACLE_DEVIATION <= (1 - LLTV * maxLif) - expected_normal_deviation`.

2. **Asymmetric formula.** The deviation is measured as a fraction of `primaryPrice`, not `validationPrice`. When primary is the high side, this accepts an effective overshoot of `d / (1 - d)` against validation rather than `d`.

3. **Triggering the deviation check blocks `price()`, which blocks liquidations.** If the threshold is set too narrow, transient honest deviation between the two oracles will halt liquidations of unhealthy positions and let bad debt accumulate via interest accrual. A threshold that is too narrow is just as dangerous as one that is too wide — it trades direct manipulation risk for liquidation-availability risk. Choose the threshold to comfortably exceed normal market spread between the two feeds while staying under `(1 - LLTV * maxLif)`. A reverting `price()` also blocks any operation Midnight routes through the oracle: liquidations, `withdrawCollateral`/`take` for accounts with debt, and the initial `supplyCollateral` that activates a collateral on markets using this oracle.

### Validation Oracle Revert Behavior

The validation oracle call uses `try/catch`. The immutable `REVERT_ON_VALIDATION_ORACLE_FAILURE` flag controls what happens when the validation oracle reverts:

- **`REVERT_ON_VALIDATION_ORACLE_FAILURE = true`:** if the validation oracle reverts, the entire `price()` call reverts with `ValidationOracleFailure`. No price is returned unless both oracles succeed. Use this when a malfunctioning validation oracle should halt all operations that depend on the price. Note that pausing the validation check is then the only way to keep `price()` working if the validation oracle permanently breaks; renouncing ownership removes that option.
- **`REVERT_ON_VALIDATION_ORACLE_FAILURE = false`:** if the validation oracle reverts, the primary price is returned without validation. Use this when availability is more important than validation, and the owner can pause/unpause validation manually if needed.

## Extensibility

The validation oracle can implement circuit breakers or arbitrary logic beyond simple price comparison — for example, blocking borrows and collateral withdrawals during abnormal market conditions.

## Security Considerations

1. **Both oracles must be trusted.** A compromised validation oracle could be used to block legitimate prices.
2. **Staleness is not checked.** This contract does not check price freshness; the underlying oracles should handle this.
3. **`price()` can return 0 to a Morpho market.** This happens when the primary oracle returns 0 and the deviation check does not revert (the validation check is paused, the validation price is also 0, or the validation call reverts while `REVERT_ON_VALIDATION_ORACLE_FAILURE` is false).
4. **A validation oracle that returns 0 instead of reverting is not caught by `try/catch`.** Against a nonzero primary price the deviation check fails and `price()` reverts with `ExcessiveOracleDeviation`, even when `REVERT_ON_VALIDATION_ORACLE_FAILURE` is false.
5. **The validation oracle must return a well-formed `uint256` payload.** Malformed returndata (length != 32) bypasses `try/catch` and reverts `price()`; excess returndata is truncated to the first 32 bytes.