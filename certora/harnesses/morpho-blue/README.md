# Certora-only fork of morpho-blue (`MarketBlue`)

`src/` here is a copy of upstream `morpho-org/morpho-blue` at commit
[`57d444d`](https://github.com/morpho-org/morpho-blue/commit/57d444d9e243be21a80e8d4bf8794ebce4a089d9)
with **two** deviations:

1. the per-market accounting struct upstream morpho-blue calls `Market` is renamed to
   **`MarketBlue`** (in `interfaces/IMorpho.sol`, `Morpho.sol`, `interfaces/IIrm.sol`,
   `libraries/periphery/MorphoBalancesLib.sol`, `mocks/IrmMock.sol`), plus an FV note in
   `interfaces/IMorpho.sol` explaining the rename;
2. `Morpho.sol`'s pragma is relaxed from `pragma solidity 0.8.19` to `>=0.8.19` so the
   tree stays importable from scene contracts compiled with a newer solc (the production
   confs compile `MorphoHarness` and this tree with `solc0.8.19` throughout).

The copy is taken from a later upstream snapshot than the `lib/morpho-blue` submodule pin
(`55d2d99`, tag `v1.0.0`), so a `diff -r` against `lib/morpho-blue/src` additionally shows
upstream's own drift between those two commits: the BUSL-1.1 → GPL-2.0-or-later relicense
of `Morpho.sol` and NatSpec/formatting touch-ups in `interfaces/IMorpho.sol`,
`libraries/ErrorsLib.sol`, `libraries/periphery/MorphoBalancesLib.sol`,
`libraries/periphery/MorphoStorageLib.sol`.

## Why

Tenor's Blue-callback Certora scenes load midnight and morpho-blue together. Midnight
defines its own top-level `struct Market` (`lib/midnight/src/interfaces/IMidnight.sol`),
structurally different from morpho-blue's. The Prover merges same-named user structs by
name across the scene and fails with a duplicate-type error. Renaming morpho-blue's struct
to `MarketBlue` in the compiled sources removes the collision.

## Why a separate copy (not in `lib/`)

`lib/morpho-blue` is kept a faithful upstream mirror (`Market`) so the Foundry build and
the delivered `src/` match `morpho-org/morpho-blue` / `tenor-labs/tenor-contracts`. The
FV-only rename lives here instead.

## Wiring

- Foundry (`foundry.toml`): `@morphoBlue/ = lib/morpho-blue/src/` → stock `Market`.
- Certora confs (`certora/confs/callbacks/_base*.conf`, `certora/confs/ratifier/*.conf`):
  `@morphoBlue = certora/harnesses/morpho-blue/src` → this fork (`MarketBlue`).

`src/**` reaches morpho-blue exclusively through the `@morphoBlue/` alias, so the two
builds diverge only in what that alias resolves to.

## Maintenance

On a morpho-blue upstream sync, re-sync `lib/morpho-blue/src`, then refresh this tree:
copy `lib/morpho-blue/src` here and re-apply the two deviations above — `Market →
MarketBlue` in the 5 files and the `>=0.8.19` pragma in `Morpho.sol`. After such a
same-commit refresh, a `diff -r` against `lib/morpho-blue/src` should show only those
deviations.
