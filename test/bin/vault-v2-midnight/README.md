# vault-v2 MidnightAdapter artifacts

Prebuilt artifacts for `test/integration/MidnightAdapterCurveRatifierIntegration.t.sol`. The test deploys them with `deployCode`.

They are prebuilt for two reasons:

- `lib/vault-v2` is pinned to a commit that predates the MidnightAdapter.
- vault-v2 pins its own Midnight. Compiling that Midnight here would make the existing `deployCode("Midnight.sol:Midnight")` calls ambiguous.

| File | Source |
| --- | --- |
| `VaultV2Factory.json` | vault-v2 `6d8152100c61079295ea7482cfeee61b748c210f`, `src/VaultV2Factory.sol` |
| `MidnightAdapterFactory.json` | vault-v2 `6d8152100c61079295ea7482cfeee61b748c210f`, `src/adapters/midnight/MidnightAdapterFactory.sol` |
| `Midnight.json` | midnight `4e2570e51171d09228645b2d5bdf84ef24b1720b`, vault-v2's `lib/midnight` pin at the commit above |

To rebuild them, build inside a vault-v2 checkout at that commit, using vault-v2's own `foundry.toml`:

```sh
git clone https://github.com/morpho-org/vault-v2 vv2 && cd vv2
git checkout 6d8152100c61079295ea7482cfeee61b748c210f && git submodule update --init lib/midnight
forge build src/VaultV2Factory.sol src/adapters/midnight/MidnightAdapterFactory.sol lib/midnight/src/Midnight.sol
```

Then copy `out/<Name>.sol/<Name>.json` here, keeping only these keys: `abi`, `bytecode`, `deployedBytecode`, `methodIdentifiers`, `rawMetadata`, `metadata` and `id`.
