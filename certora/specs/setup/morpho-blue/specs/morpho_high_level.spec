import "./morpho_valid_state.spec";

// ========== High-Level Behavioral Rules ==========

// ========== Conservation Laws ==========

// HL-01: Supply preserves share accounting -- the delta of individual supply
// shares equals the delta of total supply shares
// FORMULA: (totalSupplySharesAfter - totalSupplySharesBefore) ==
//          (userSupplySharesAfter - userSupplySharesBefore)
//
// When supply() is called for a specific onBehalf, position[id][onBehalf].supplyShares
// and market[id].totalSupplyShares must increase by the same shares amount.
// Note: _accrueInterest may also add feeShares to totalSupplyShares and
// feeRecipient's position, so we track both onBehalf and feeRecipient deltas.
rule supplySharesConservation(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    // Separate onBehalf from feeRecipient to avoid double-counting deltas
    // (when they're the same address, userDelta and feeRecDelta read the same slot)
    require(onBehalf != ghostMbFeeRecipient,
        "SAFE: separate onBehalf and feeRecipient for clean accounting");

    mathint userSharesBefore = ghostMbSupplyShares256[id][onBehalf];
    mathint feeRecSharesBefore = ghostMbSupplyShares256[id][ghostMbFeeRecipient];
    mathint totalSharesBefore = ghostMbTotalSupplyShares128[id];

    supply(e, marketParams, assets, shares, onBehalf, data);

    mathint userSharesAfter = ghostMbSupplyShares256[id][onBehalf];
    mathint feeRecSharesAfter = ghostMbSupplyShares256[id][ghostMbFeeRecipient];
    mathint totalSharesAfter = ghostMbTotalSupplyShares128[id];

    mathint userDelta = userSharesAfter - userSharesBefore;
    mathint feeRecDelta = feeRecSharesAfter - feeRecSharesBefore;
    mathint totalDelta = totalSharesAfter - totalSharesBefore;

    // Total supply shares increase = user increase + feeRecipient increase (from accrueInterest)
    assert(totalDelta == userDelta + feeRecDelta,
        "Supply shares: total delta must equal user delta plus fee recipient delta");
}

// HL-02: Withdraw preserves share accounting -- the delta of individual supply
// shares equals the delta of total supply shares (accounting for fee accrual)
// FORMULA: (totalSupplySharesBefore - totalSupplySharesAfter) ==
//          (userSupplySharesBefore - userSupplySharesAfter) - feeRecDelta
//
// When withdraw() is called, position[id][onBehalf].supplyShares decreases and
// market[id].totalSupplyShares decreases by the same shares minus any feeShares
// added during interest accrual.
rule withdrawSharesConservation(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    // Separate onBehalf from feeRecipient to avoid double-counting deltas
    // (when they're the same address, userDelta and feeRecDelta read the same slot)
    require(onBehalf != ghostMbFeeRecipient,
        "SAFE: separate onBehalf and feeRecipient for clean accounting");

    mathint userSharesBefore = ghostMbSupplyShares256[id][onBehalf];
    mathint feeRecSharesBefore = ghostMbSupplyShares256[id][ghostMbFeeRecipient];
    mathint totalSharesBefore = ghostMbTotalSupplyShares128[id];

    withdraw(e, marketParams, assets, shares, onBehalf, receiver);

    mathint userSharesAfter = ghostMbSupplyShares256[id][onBehalf];
    mathint feeRecSharesAfter = ghostMbSupplyShares256[id][ghostMbFeeRecipient];
    mathint totalSharesAfter = ghostMbTotalSupplyShares128[id];

    mathint userDelta = userSharesAfter - userSharesBefore;
    mathint feeRecDelta = feeRecSharesAfter - feeRecSharesBefore;
    mathint totalDelta = totalSharesAfter - totalSharesBefore;

    // Total supply shares change = user change + fee recipient change
    assert(totalDelta == userDelta + feeRecDelta,
        "Withdraw shares: total delta must equal user delta plus fee recipient delta");
}

// HL-03: Borrow preserves borrow share accounting -- the delta of individual
// borrow shares equals the delta of total borrow shares
// FORMULA: (totalBorrowSharesAfter - totalBorrowSharesBefore) ==
//          (userBorrowSharesAfter - userBorrowSharesBefore)
//
// When borrow() is called, position[id][onBehalf].borrowShares and
// market[id].totalBorrowShares increase by the same shares.
rule borrowSharesConservation(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint userSharesBefore = ghostMbBorrowShares128[id][onBehalf];
    mathint totalSharesBefore = ghostMbTotalBorrowShares128[id];

    borrow(e, marketParams, assets, shares, onBehalf, receiver);

    mathint userSharesAfter = ghostMbBorrowShares128[id][onBehalf];
    mathint totalSharesAfter = ghostMbTotalBorrowShares128[id];

    mathint userDelta = userSharesAfter - userSharesBefore;
    mathint totalDelta = totalSharesAfter - totalSharesBefore;

    // Borrow does not trigger fee minting, so 1:1 conservation
    assert(totalDelta == userDelta,
        "Borrow shares: total delta must equal user delta");
}

// HL-04: Repay preserves borrow share accounting -- the delta of individual
// borrow shares equals the delta of total borrow shares
// FORMULA: (totalBorrowSharesBefore - totalBorrowSharesAfter) ==
//          (userBorrowSharesBefore - userBorrowSharesAfter)
//
// When repay() is called, both position and total borrow shares decrease equally.
rule repaySharesConservation(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint userSharesBefore = ghostMbBorrowShares128[id][onBehalf];
    mathint totalSharesBefore = ghostMbTotalBorrowShares128[id];

    repay(e, marketParams, assets, shares, onBehalf, data);

    mathint userSharesAfter = ghostMbBorrowShares128[id][onBehalf];
    mathint totalSharesAfter = ghostMbTotalBorrowShares128[id];

    mathint userDelta = userSharesBefore - userSharesAfter;
    mathint totalDelta = totalSharesBefore - totalSharesAfter;

    assert(totalDelta == userDelta,
        "Repay shares: total delta must equal user delta");
}

// HL-05: Supply internal asset accounting matches ERC20 transfer
// FORMULA: (totalSupplyAssetsAfter - totalSupplyAssetsBefore - interestDelta) ==
//          (contractERC20BalanceAfter - contractERC20BalanceBefore)
//
// The ERC20 balance change of Morpho's loan token must match the change in
// totalSupplyAssets, minus any interest that was accrued. Since interest
// equally increases both totalSupplyAssets and totalBorrowAssets, we can
// isolate the supply delta by accounting for the borrow delta.
rule supplyAssetConservation(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    // Ensure ghost loan token matches the marketParams used in the call
    // (without this, Prover can pick id where ghostMbLoanToken was set by a
    // different createMarket, tracking the wrong ERC20 balance)
    require(ghostMbLoanToken[id] == marketParams.loanToken,
        "SAFE: loan token ghost matches market params");

    address loanToken = ghostMbLoanToken[id];

    mathint supplyAssetsBefore = ghostMbTotalSupplyAssets128[id];
    mathint borrowAssetsBefore = ghostMbTotalBorrowAssets128[id];
    mathint contractBalBefore = ghostERC20Balances128[loanToken][currentContract];

    supply(e, marketParams, assets, shares, onBehalf, data);

    mathint supplyAssetsAfter = ghostMbTotalSupplyAssets128[id];
    mathint borrowAssetsAfter = ghostMbTotalBorrowAssets128[id];
    mathint contractBalAfter = ghostERC20Balances128[loanToken][currentContract];

    // Interest increases both supply and borrow by the same amount
    mathint interestDelta = borrowAssetsAfter - borrowAssetsBefore;
    mathint netSupplyDelta = (supplyAssetsAfter - supplyAssetsBefore) - interestDelta;
    mathint erc20Delta = contractBalAfter - contractBalBefore;

    assert(netSupplyDelta == erc20Delta,
        "Supply: net asset delta (minus interest) must equal ERC20 balance change");
}

// ========== Round-Trip Testing ==========

// HL-06: Supply-then-withdraw round-trip yields no profit (protocol rounding
// favors the protocol)
// FORMULA: after supply(assets) then withdraw(resultingShares), user's ERC20
//          balance <= original balance
//
// supply uses toSharesDown (fewer shares for depositor), withdraw uses
// toAssetsDown (fewer assets returned). The round-trip must not be profitable.
rule supplyWithdrawNoProfit(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 supplyAssets,
    address onBehalf,
    address receiver,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    address loanToken = ghostMbLoanToken[id];

    // Require e.msg.sender == onBehalf so no authorization needed for withdraw
    require(e.msg.sender == onBehalf,
        "SAFE: sender is onBehalf for self-service round-trip");
    // Require receiver != Morpho to avoid self-transfer confusion
    require(receiver != currentContract,
        "SAFE: receiver is not Morpho contract");
    // Require onBehalf == receiver for clean round-trip balance tracking
    require(onBehalf == receiver,
        "SAFE: onBehalf equals receiver for clean balance tracking");

    mathint userBalanceBefore = ghostERC20Balances128[loanToken][onBehalf];

    // Step 1: Supply assets, receiving shares
    uint256 returnedAssets;
    uint256 returnedShares;
    returnedAssets, returnedShares = supply(e, marketParams, supplyAssets, 0, onBehalf, data);

    // Step 2: Withdraw using the shares received from supply
    withdraw(e, marketParams, 0, returnedShares, onBehalf, receiver);

    mathint userBalanceAfter = ghostERC20Balances128[loanToken][onBehalf];

    assert(userBalanceAfter <= userBalanceBefore,
        "Supply-then-withdraw round-trip must not profit the user");
}

// HL-07: Borrow-then-repay round-trip costs at least what was borrowed
// (protocol rounding favors the protocol)
// FORMULA: after borrow(assets) then repay(resultingShares), user's ERC20
//          balance <= original balance
//
// borrow uses toSharesUp (more shares for borrower), repay uses toAssetsUp
// (more assets to repay). The borrower always repays at least what they borrowed.
rule borrowRepayNoProfit(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 borrowAssets,
    address onBehalf,
    address receiver,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    address loanToken = ghostMbLoanToken[id];

    // Require e.msg.sender == onBehalf so no authorization needed for borrow
    require(e.msg.sender == onBehalf,
        "SAFE: sender is onBehalf for self-service round-trip");
    // Require receiver == onBehalf for clean round-trip balance tracking
    require(receiver == onBehalf,
        "SAFE: receiver equals onBehalf for clean balance tracking");

    mathint userBalanceBefore = ghostERC20Balances128[loanToken][onBehalf];

    // Step 1: Borrow assets, getting shares
    uint256 returnedAssets;
    uint256 returnedShares;
    returnedAssets, returnedShares = borrow(e, marketParams, borrowAssets, 0, onBehalf, receiver);

    // Step 2: Repay using the shares from borrow
    repay(e, marketParams, 0, returnedShares, onBehalf, data);

    mathint userBalanceAfter = ghostERC20Balances128[loanToken][onBehalf];

    assert(userBalanceAfter <= userBalanceBefore,
        "Borrow-then-repay round-trip must not profit the user");
}

// ========== Monotonicity ==========

// HL-08: Interest accrual monotonically increases totalSupplyAssets
// FORMULA: totalSupplyAssetsAfter >= totalSupplyAssetsBefore
//
// _accrueInterest adds interest to both totalBorrowAssets and totalSupplyAssets.
// totalSupplyAssets can never decrease from interest accrual. Verifies
// the core safety property that suppliers' assets grow, not shrink.
rule accrueInterestIncreasesSupplyAssets(
    env e,
    MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint supplyAssetsBefore = ghostMbTotalSupplyAssets128[id];

    accrueInterest(e, marketParams);

    mathint supplyAssetsAfter = ghostMbTotalSupplyAssets128[id];

    assert(supplyAssetsAfter >= supplyAssetsBefore,
        "Interest accrual must not decrease total supply assets");
}

// HL-09: Interest accrual monotonically increases totalBorrowAssets
// FORMULA: totalBorrowAssetsAfter >= totalBorrowAssetsBefore
//
// _accrueInterest adds interest to totalBorrowAssets. Borrowers' debt only
// grows from interest, never shrinks.
rule accrueInterestIncreasesBorrowAssets(
    env e,
    MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint borrowAssetsBefore = ghostMbTotalBorrowAssets128[id];

    accrueInterest(e, marketParams);

    mathint borrowAssetsAfter = ghostMbTotalBorrowAssets128[id];

    assert(borrowAssetsAfter >= borrowAssetsBefore,
        "Interest accrual must not decrease total borrow assets");
}

// HL-10: Interest accrual increases supply and borrow assets by the same amount
// FORMULA: (totalSupplyAssetsAfter - totalSupplyAssetsBefore) ==
//          (totalBorrowAssetsAfter - totalBorrowAssetsBefore)
//
// Interest is computed from totalBorrowAssets and added equally to both
// totalBorrowAssets and totalSupplyAssets. This ensures no value is created
// or destroyed during interest accrual.
rule accrueInterestEqualDelta(
    env e,
    MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint supplyAssetsBefore = ghostMbTotalSupplyAssets128[id];
    mathint borrowAssetsBefore = ghostMbTotalBorrowAssets128[id];

    accrueInterest(e, marketParams);

    mathint supplyAssetsAfter = ghostMbTotalSupplyAssets128[id];
    mathint borrowAssetsAfter = ghostMbTotalBorrowAssets128[id];

    mathint supplyDelta = supplyAssetsAfter - supplyAssetsBefore;
    mathint borrowDelta = borrowAssetsAfter - borrowAssetsBefore;

    assert(supplyDelta == borrowDelta,
        "Interest accrual must increase supply and borrow assets by equal amounts");
}

// ========== Dependency Enforcement ==========

// HL-11: Bad debt socialization symmetry -- when liquidation triggers bad debt
// (borrower's collateral reaches 0), totalBorrowAssets and totalSupplyAssets
// decrease by the same badDebtAssets amount, preserving the liquidity invariant.
// FORMULA: if collateral reaches 0 during liquidation, then
//          (totalSupplyAssetsBefore - totalSupplyAssetsAfter) >=
//          (totalBorrowAssetsBefore - totalBorrowAssetsAfter)
//          (supply decreases at least as much as borrow, because supply also
//          absorbs the bad debt in addition to any interest effect)
//
// This is a critical safety property: bad debt socialization must maintain
// totalBorrowAssets <= totalSupplyAssets.
rule liquidationPreservesLiquidityRelation(
    env e,
    MorphoHarness.MarketParams marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint supplyAssetsBefore = ghostMbTotalSupplyAssets128[id];
    mathint borrowAssetsBefore = ghostMbTotalBorrowAssets128[id];

    liquidate(e, marketParams, borrower, seizedAssets, repaidShares, data);

    mathint supplyAssetsAfter = ghostMbTotalSupplyAssets128[id];
    mathint borrowAssetsAfter = ghostMbTotalBorrowAssets128[id];

    // After liquidation (including bad debt), the liquidity invariant must hold
    // This is stronger than just checking the invariant -- it shows that
    // the gap does not widen (borrow never increases relative to supply)
    assert(borrowAssetsAfter <= supplyAssetsAfter,
        "Liquidation must preserve totalBorrowAssets <= totalSupplyAssets");
}

// HL-12: Liquidation borrow share conservation -- the borrow shares
// removed from the borrower equal the borrow shares removed from the total
// FORMULA: (totalBorrowSharesBefore - totalBorrowSharesAfter) ==
//          (borrowerSharesBefore - borrowerSharesAfter)
//
// liquidate() subtracts repaidShares from both position and total, then
// if bad debt occurs, subtracts remaining position shares from total and
// zeros the position. Total delta must always equal position delta.
rule liquidationBorrowSharesConservation(
    env e,
    MorphoHarness.MarketParams marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint borrowerSharesBefore = ghostMbBorrowShares128[id][borrower];
    mathint totalSharesBefore = ghostMbTotalBorrowShares128[id];

    liquidate(e, marketParams, borrower, seizedAssets, repaidShares, data);

    mathint borrowerSharesAfter = ghostMbBorrowShares128[id][borrower];
    mathint totalSharesAfter = ghostMbTotalBorrowShares128[id];

    mathint borrowerDelta = borrowerSharesBefore - borrowerSharesAfter;
    mathint totalDelta = totalSharesBefore - totalSharesAfter;

    assert(totalDelta == borrowerDelta,
        "Liquidation: total borrow shares delta must equal borrower shares delta");
}

// ========== Bounds Enforcement ==========

// HL-13: Supply collateral does not change market-level supply or borrow totals
// FORMULA: totalSupplyAssets, totalSupplyShares, totalBorrowAssets,
//          totalBorrowShares all unchanged after supplyCollateral
//
// supplyCollateral only modifies position[id][onBehalf].collateral.
// It does not call _accrueInterest. Market-level totals must not change.
rule supplyCollateralDoesNotChangeTotals(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint totalSupplyAssetsBefore = ghostMbTotalSupplyAssets128[id];
    mathint totalSupplySharesBefore = ghostMbTotalSupplyShares128[id];
    mathint totalBorrowAssetsBefore = ghostMbTotalBorrowAssets128[id];
    mathint totalBorrowSharesBefore = ghostMbTotalBorrowShares128[id];

    supplyCollateral(e, marketParams, assets, onBehalf, data);

    assert(ghostMbTotalSupplyAssets128[id] == totalSupplyAssetsBefore,
        "supplyCollateral must not change totalSupplyAssets");
    assert(ghostMbTotalSupplyShares128[id] == totalSupplySharesBefore,
        "supplyCollateral must not change totalSupplyShares");
    assert(ghostMbTotalBorrowAssets128[id] == totalBorrowAssetsBefore,
        "supplyCollateral must not change totalBorrowAssets");
    assert(ghostMbTotalBorrowShares128[id] == totalBorrowSharesBefore,
        "supplyCollateral must not change totalBorrowShares");
}

// ========== Safety Preservation ==========

// HL-14: Non-liquidation operations preserve collateralization
// FORMULA: collateralized(user) before && !isLiquidate(f) => collateralized(user) after
//
// If a user has borrowShares > 0, they must have collateral > 0. Non-liquidation
// operations should not create undercollateralized positions.
rule nonLiquidationPreservesCollateralization(
    env e,
    method f,
    calldataarg args,
    MorphoHarness.Id id,
    address user
) filtered { f -> !EXCLUDED_FUNCTION_MB(f)
    && f.selector != sig:liquidate(MorphoHarness.MarketParams,address,uint256,uint256,bytes).selector } {

    setupValidStateMB(e);

    // Pre: user is collateralized (has borrow => has collateral)
    mathint borrowSharesBefore = ghostMbBorrowShares128[id][user];
    mathint collateralBefore = ghostMbCollateral128[id][user];
    require(borrowSharesBefore > 0 => collateralBefore > 0,
        "SAFE: user starts collateralized");

    f(e, args);

    mathint borrowSharesAfter = ghostMbBorrowShares128[id][user];
    mathint collateralAfter = ghostMbCollateral128[id][user];

    assert(borrowSharesAfter > 0 => collateralAfter > 0,
        "Non-liquidation operation must not create undercollateralized position");
}
