# MidnightVaultExecutor

`MidnightVaultExecutor` lets users borrow at a fixed rate against [Morpho VaultV2](https://github.com/morpho-org/vault-v2) shares used as collateral on a Morpho Midnight market.

## Overview

Morpho Midnight supports the creation of fixed-rate markets. 

Morpho VaultV2 is a variable-rate vault whose shares can be listed as collateral in those markets. 

Tenor uses an immutable, unmanaged VaultV2 to allocate to a single Morpho Blue variable-rate market (e.g. cbBTC / USDC), creating a share wrapper that represents a position in that underlying market. Listing the shares as collateral on Midnight connects the fixed-rate market on Morpho Midnight to the variable-rate market on Morpho Blue, allowing borrowers to post VaultV2 shares as collateral and borrow USDC at a fixed rate. The shares keep earning the variable yield of the underlying Morpho Blue market.

This lets borrowers trade rates according to their expectations of the differential between the fixed and variable markets, up to the maturity of the fixed-rate market.

This market structure also gives borrowers a way to exit early. Instead of using Midnight's `repay` function — which forces repayment at par (0%) — they can unwind at the prevailing market rate. Listing the vault shares (i.e. the Morpho Blue position) as collateral deepens liquidity, so borrowers can close out before maturity without repaying at par.


Example setup:

| Market | Rate | Loan token | Collateral |
|---|---|---|---|
| Morpho Midnight | Fixed | USDC | cbBTC + VaultV2 shares |
| Morpho Blue (underlying vault allocation) | Variable | USDC | cbBTC |

The VaultV2 allocates its USDC into the cbBTC / USDC Morpho Blue market, so its shares represent a lender position in that market. Those shares are then posted as collateral on the Midnight fixed-rate market.

## Contracts

Three contracts support the full lifecycle of a borrow against VaultV2 share collateral. Each handles a different entry or exit path. Note that only `MidnightVaultExecutor` lives in `src/periphery/`; the two offer callbacks below live in `src/callbacks/` (`MidnightSupplyVaultSharesCallback.sol`, `MidnightWithdrawVaultSharesCallback.sol`).

All three share the same design properties:

- **Singleton** — one deployment serves every market, vault, and user; the market and vault are passed per call (the vault is derived from `market.collateralParams[collateralIndex]`).
- **Immutable** — no proxy, initializer, or upgrade path. The only stored state is the `MORPHO_MIDNIGHT` address set at construction.
- **Ungoverned** — no owner, admin, or privileged role. Authorization is delegated entirely to Midnight (`isAuthorized` / `onBehalf`).
- **No custody** — funds and shares are held only for the duration of a single call. A balance left behind across calls is not recoverable by its depositor.

### `MidnightSupplyVaultSharesCallback`

Borrower-side callback for SELL offers (borrow). A borrower who wants to borrow USDC without already holding VaultV2 shares creates a SELL offer with this callback and specifies the rate they want to borrow at. When the offer executes:

1. Midnight transfers the loan tokens (USDC) to the callback.
2. The callback optionally pulls additional USDC from the borrower (`additionalDepositPercent`, sized to cover the interest and LLTV gaps).
3. The callback deposits the combined USDC into the VaultV2 and receives shares.
4. The callback supplies the shares as collateral on Midnight on behalf of the borrower.

The borrower ends the transaction with vault-share collateral and an open USDC debt — lending at the variable rate and borrowing at the fixed rate.

The callback is keyed to the **seller** role (`onSell`), not to being the maker. A borrower can also take an existing BUY offer and pass this contract as the `takerCallback` to wind up the same position by taking liquidity instead of making it. In that case `receiverIfTakerIsSeller` must point to this contract (mirroring the `receiverIfMakerIsSeller` requirement) so the loan tokens land here before `onSell` runs.

### `MidnightWithdrawVaultSharesCallback`

Borrower-side callback for BUY offers (early exit). A borrower who wants to repay their fixed-rate debt and unwind their vault-share collateral position can use this callback. When the offer fills:

1. Midnight calls the callback with the USDC amount needed.
2. The callback computes the shares to withdraw via `previewWithdraw(buyerAssets)`.
3. The callback withdraws the shares from the borrower's Midnight collateral.
4. The callback redeems the shares for USDC and approves Midnight to pull the proceeds.

Remaining collateral stays on Midnight and can be withdrawn separately.

Like the supply callback, this is keyed to the **buyer** role (`onBuy`), not to being the maker. A borrower can also take an existing SELL offer and pass this contract as the `takerCallback` to unwind by taking liquidity instead of making it. No receiver field is needed on this path: the callback acts as the buyer's `payer` and approves Midnight to pull the proceeds directly.

### `MidnightVaultExecutor` (this contract)

Direct deposit, withdraw, repay, and liquidation helper outside the offer flow. The two callbacks above are tied to offers (SELL / BUY); the executor handles the operations that do not go through an offer:

- **`depositAndAddCollateral`**: deposits the user's USDC into the vault (or mints a target share amount), then supplies the shares as Midnight collateral on their behalf.
- **`withdrawCollateralAndRedeem`**: withdraws vault-share collateral from Midnight and redeems it for USDC in one call.
- **`onRepay`** (callback): the user calls `Midnight.repay(..., callback = executor)`; the executor pulls the needed shares, redeems them, and funds the repayment.
- **`onLiquidate`** (callback): liquidators call `Midnight.liquidate(..., callback = executor, receiver = executor)`; the executor redeems the seized shares and forwards USDC to the liquidator, so liquidators never hold vault shares.

All four paths share the same authorization model: the caller must be `onBehalf` or authorized by it on Midnight (`isAuthorized`). The vault is derived from `market.collateralParams[collateralIndex]`, and the executor checks the vault's `asset()` matches the market's loan token on every path.

The executor does not take custody. It holds shares and assets only for the duration of a call; repay and liquidation are funded strictly from the assets redeemed in that same call, so a balance parked across calls is neither usable nor recoverable. No per-share-price / slippage bound is enforced — deposit, mint, and redeem settle at whatever rate the vault reports at execution time. See the contract's `VAULT SAFETY REQUIREMENTS` NatSpec for the full list of vault assumptions this relies on.

## Why the executor exists

The executor is required when vault shares are listed as collateral but the vault gates which addresses (contracts) can hold them. Every deposit, withdrawal, repayment, and liquidation of vault-share collateral must go through it. This keeps VaultV2 shares locked to a single use: collateral on Midnight. Because shares can only ever sit as Midnight collateral, they cannot be borrowed, shorted, or traded. That closes off the lending-market attack surface that using vault shares could otherwise open (see Morpho's [vault-as-asset security considerations](https://docs.morpho.org/curate/concepts/security-considerations/#vault-as-asset)). While VaultV2 uses firstTotalAssets to avoid these issues, it does not guard against borrowable shares directly. Gating the shares as collateral constrains what one can do with the vault shares.

### Constraining shares to collateral only

The deployment sets a `receiveSharesGate` on the VaultV2 and allowlists only the contracts that must hold shares to support the collateral lifecycle:

- `MidnightSupplyVaultSharesCallback` and `MidnightWithdrawVaultSharesCallback` (offer-flow entry/exit).
- `Morpho Midnight` (holds shares as collateral balances).
- `MidnightVaultExecutor` (transient holder during deposit, withdraw, repay, and liquidation).
- `BorrowMidnightRenewalCallback` (transient holder when a borrower renews a position into another market).

End users and third-party lending markets are not allowlisted, and no function to borrow shares (e.g., `take` on Midnight) is exposed. As a result:

- No lending market can list vault shares as a borrowable asset.
- Shares can only enter and leave Midnight collateral through the allowlisted contracts.

### Why the gate needs the executor

The executor is the entry/exit path for everything that is not an offer (direct deposits, direct withdrawals, repayments, liquidations). Without it, every user, repayer, and liquidator would need to be allowlisted on the gate individually, which is impractical and would defeat the gate's purpose. Liquidators receive USDC directly via `onLiquidate`; they never hold vault shares, so no per-liquidator allowlisting is required.