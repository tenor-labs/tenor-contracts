import "./morpho_valid_state.spec";

// =============================================================================
// Basic Reachability
// =============================================================================

// RC-01: setOwner is reachable
rule setOwnerIsReachable(env e, address newOwner) {
    setupValidStateMB(e);

    setOwner(e, newOwner);

    satisfy(ghostMbOwner == newOwner && newOwner != 0,
        "setOwner must be reachable with a new non-zero owner");
}

// RC-02: enableIrm is reachable
rule enableIrmIsReachable(env e, address irm) {
    setupValidStateMB(e);

    enableIrm(e, irm);

    satisfy(ghostMbIsIrmEnabled[irm],
        "enableIrm must be reachable and set IRM to enabled");
}

// RC-03: enableLltv is reachable
rule enableLltvIsReachable(env e, uint256 lltv) {
    setupValidStateMB(e);

    enableLltv(e, lltv);

    satisfy(ghostMbIsLltvEnabled[lltv] && to_mathint(lltv) > 0,
        "enableLltv must be reachable with a positive LLTV");
}

// RC-04: setFee is reachable
rule setFeeIsReachable(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 newFee
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    setFee(e, marketParams, newFee);

    satisfy(ghostMbFee128[id] > 0,
        "setFee must be reachable with a positive fee");
}

// RC-05: setFeeRecipient is reachable
rule setFeeRecipientIsReachable(env e, address newFeeRecipient) {
    setupValidStateMB(e);

    setFeeRecipient(e, newFeeRecipient);

    satisfy(ghostMbFeeRecipient == newFeeRecipient && newFeeRecipient != 0,
        "setFeeRecipient must be reachable with a non-zero recipient");
}

// RC-06: createMarket is reachable
rule createMarketIsReachable(
    env e,
    MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    createMarket(e, marketParams);

    satisfy(ghostMbLastUpdate128[id] > 0,
        "createMarket must be reachable and set lastUpdate");
}

// RC-07: supply is reachable
rule supplyIsReachable(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    mathint supplySharesBefore = ghostMbTotalSupplyShares128[id];

    supply(e, marketParams, assets, shares, onBehalf, data);

    mathint supplySharesAfter = ghostMbTotalSupplyShares128[id];

    satisfy(supplySharesAfter > supplySharesBefore,
        "supply must be reachable with positive share increase");
}

// RC-08: withdraw is reachable
rule withdrawIsReachable(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    mathint supplySharesBefore = ghostMbTotalSupplyShares128[id];

    withdraw(e, marketParams, assets, shares, onBehalf, receiver);

    mathint supplySharesAfter = ghostMbTotalSupplyShares128[id];

    satisfy(supplySharesBefore > supplySharesAfter,
        "withdraw must be reachable with positive share decrease");
}

// RC-09: borrow is reachable
rule borrowIsReachable(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    mathint borrowSharesBefore = ghostMbTotalBorrowShares128[id];

    borrow(e, marketParams, assets, shares, onBehalf, receiver);

    mathint borrowSharesAfter = ghostMbTotalBorrowShares128[id];

    satisfy(borrowSharesAfter > borrowSharesBefore,
        "borrow must be reachable with positive borrow share increase");
}

// RC-10: repay is reachable
rule repayIsReachable(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    mathint borrowSharesBefore = ghostMbTotalBorrowShares128[id];

    repay(e, marketParams, assets, shares, onBehalf, data);

    mathint borrowSharesAfter = ghostMbTotalBorrowShares128[id];

    satisfy(borrowSharesBefore > borrowSharesAfter,
        "repay must be reachable with positive borrow share decrease");
}

// RC-11: supplyCollateral is reachable
rule supplyCollateralIsReachable(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    mathint collateralBefore = ghostMbCollateral128[id][onBehalf];

    supplyCollateral(e, marketParams, assets, onBehalf, data);

    mathint collateralAfter = ghostMbCollateral128[id][onBehalf];

    satisfy(collateralAfter > collateralBefore,
        "supplyCollateral must be reachable with positive collateral increase");
}

// RC-12: withdrawCollateral is reachable
rule withdrawCollateralIsReachable(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    mathint collateralBefore = ghostMbCollateral128[id][onBehalf];

    withdrawCollateral(e, marketParams, assets, onBehalf, receiver);

    mathint collateralAfter = ghostMbCollateral128[id][onBehalf];

    satisfy(collateralBefore > collateralAfter,
        "withdrawCollateral must be reachable with positive collateral decrease");
}

// RC-13: liquidate is reachable
rule liquidateIsReachable(
    env e,
    MorphoHarness.MarketParams marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    mathint borrowSharesBefore = ghostMbTotalBorrowShares128[id];

    liquidate(e, marketParams, borrower, seizedAssets, repaidShares, data);

    mathint borrowSharesAfter = ghostMbTotalBorrowShares128[id];

    satisfy(borrowSharesBefore > borrowSharesAfter,
        "liquidate must be reachable with borrow shares reduced");
}

// RC-14: flashLoan is reachable
rule flashLoanIsReachable(env e, address token, uint256 assets, bytes data) {
    setupValidStateMB(e);

    flashLoan(e, token, assets, data);

    satisfy(assets > 0,
        "flashLoan must be reachable with a positive loan amount");
}

// RC-15: setAuthorization is reachable
rule setAuthorizationIsReachable(
    env e,
    address authorized,
    bool newIsAuthorized
) {
    setupValidStateMB(e);

    setAuthorization(e, authorized, newIsAuthorized);

    satisfy(ghostMbIsAuthorized[e.msg.sender][authorized] == newIsAuthorized,
        "setAuthorization must be reachable and update authorization state");
}

// RC-16: accrueInterest is reachable
rule accrueInterestIsReachable(
    env e,
    MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    mathint lastUpdateBefore = ghostMbLastUpdate128[id];

    accrueInterest(e, marketParams);

    mathint lastUpdateAfter = ghostMbLastUpdate128[id];

    satisfy(lastUpdateAfter > lastUpdateBefore,
        "accrueInterest must be reachable and advance lastUpdate");
}

// =============================================================================
// Conditional Reachability
// =============================================================================

// RC-17: supply reachable with positive assets (not shares)
rule supplyReachableWithPositiveAssets(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    require(assets > 0, "SAFE: supply with positive assets path");

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    mathint totalAssetsBefore = ghostMbTotalSupplyAssets128[id];

    supply(e, marketParams, assets, 0, onBehalf, data);

    mathint totalAssetsAfter = ghostMbTotalSupplyAssets128[id];

    satisfy(totalAssetsAfter > totalAssetsBefore,
        "supply reachable with positive assets input and increased total supply");
}

// RC-18: borrow reachable with existing collateral
rule borrowReachableWithCollateral(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    require(assets > 0, "SAFE: borrow positive assets");
    require(ghostMbCollateral128[id][onBehalf] > 0,
        "SAFE: borrower has existing collateral");

    mathint borrowAssetsBefore = ghostMbTotalBorrowAssets128[id];

    borrow(e, marketParams, assets, 0, onBehalf, receiver);

    mathint borrowAssetsAfter = ghostMbTotalBorrowAssets128[id];

    satisfy(borrowAssetsAfter > borrowAssetsBefore,
        "borrow reachable with existing collateral and positive asset increase");
}

// RC-19: liquidate reachable with bad debt socialization
rule liquidateReachableWithBadDebt(
    env e,
    MorphoHarness.MarketParams marketParams,
    address borrower,
    uint256 seizedAssets,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    require(seizedAssets > 0, "SAFE: seize positive collateral");

    mathint totalSupplyBefore = ghostMbTotalSupplyAssets128[id];

    liquidate(e, marketParams, borrower, seizedAssets, 0, data);

    mathint totalSupplyAfter = ghostMbTotalSupplyAssets128[id];

    satisfy(totalSupplyAfter < totalSupplyBefore,
        "liquidate reachable with bad debt socialization reducing total supply");
}

// RC-20: withdraw reachable by authorized agent (not position owner)
rule withdrawReachableByAuthorizedAgent(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    require(e.msg.sender != onBehalf, "SAFE: agent is not position owner");
    require(ghostMbIsAuthorized[onBehalf][e.msg.sender],
        "SAFE: agent is authorized by position owner");
    require(assets > 0, "SAFE: withdraw positive assets");

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    mathint supplySharesBefore = ghostMbTotalSupplyShares128[id];

    withdraw(e, marketParams, assets, 0, onBehalf, receiver);

    mathint supplySharesAfter = ghostMbTotalSupplyShares128[id];

    satisfy(supplySharesBefore > supplySharesAfter,
        "withdraw reachable by authorized agent on behalf of position owner");
}

// RC-21: setFee reachable with fee set to zero (fee removal)
rule setFeeReachableWithZeroFee(
    env e,
    MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    require(ghostMbFee128[id] > 0, "SAFE: market currently has a positive fee");

    setFee(e, marketParams, 0);

    satisfy(ghostMbFee128[id] == 0,
        "setFee reachable to remove fee from a market");
}

// RC-22: accrueInterest reachable with positive interest accrued
rule accrueInterestReachableWithPositiveInterest(
    env e,
    MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    require(ghostMbTotalBorrowAssets128[id] > 0,
        "SAFE: market has outstanding borrows for interest to accrue on");

    mathint totalBorrowBefore = ghostMbTotalBorrowAssets128[id];

    accrueInterest(e, marketParams);

    mathint totalBorrowAfter = ghostMbTotalBorrowAssets128[id];

    satisfy(totalBorrowAfter > totalBorrowBefore,
        "accrueInterest reachable with positive interest increasing total borrow");
}

// RC-23: repay reachable with full debt repayment
rule repayReachableWithFullRepayment(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    require(ghostMbBorrowShares128[id][onBehalf] > 0,
        "SAFE: borrower has existing debt to repay");
    require(shares > 0, "SAFE: repay positive shares");

    repay(e, marketParams, 0, shares, onBehalf, data);

    satisfy(ghostMbBorrowShares128[id][onBehalf] == 0,
        "repay reachable with full debt repayment clearing borrow shares");
}

// ========== Full-Amount Liveness ==========

// RC-24: user can withdraw entire supply position with active borrows
rule canWithdrawAll(
    env e,
    MorphoHarness.MarketParams marketParams,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint userShares = ghostMbSupplyShares256[id][onBehalf];
    mathint totalSupplyShares = ghostMbTotalSupplyShares128[id];
    require(userShares > 0, "SAFE: user has a supply position");
    require(totalSupplyShares > userShares,
        "SAFE: other suppliers exist -- user is not the sole depositor");
    require(e.msg.sender == onBehalf, "SAFE: self-withdrawal");
    require(receiver != 0, "SAFE: non-zero receiver required by Solidity");

    require(to_mathint(e.block.timestamp) == ghostMbLastUpdate128[id],
        "SAFE: no elapsed time -- interest accrual is a no-op");

    address loanToken = ghostMbLoanToken[id];
    require(ghostERC20Balances128[loanToken][currentContract]
        >= ghostMbTotalSupplyAssets128[id],
        "SAFE: Morpho token balance covers total supply");

    // Active borrows: the liquidity check in withdraw() must pass
    // after removing user's pro-rata share of totalSupplyAssets
    require(ghostMbTotalBorrowAssets128[id] > 0,
        "SAFE: market has active borrows -- testing realistic conditions");

    uint256 returnedAssets;
    uint256 returnedShares;
    returnedAssets, returnedShares
        = withdraw(e, marketParams, 0, require_uint256(userShares), onBehalf, receiver);

    satisfy(ghostMbSupplyShares256[id][onBehalf] == 0,
        "Full supply withdrawal with active borrows must be reachable");
}

// RC-25: user can withdraw entire collateral position
rule canWithdrawCollateralAll(
    env e,
    MorphoHarness.MarketParams marketParams,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint userCollateral = ghostMbCollateral128[id][onBehalf];
    require(userCollateral > 0, "SAFE: user has collateral");
    require(ghostMbBorrowShares128[id][onBehalf] == 0,
        "SAFE: no debt so withdrawal is unrestricted");
    require(e.msg.sender == onBehalf, "SAFE: self-withdrawal");
    require(receiver != 0, "SAFE: non-zero receiver required by Solidity");

    // SAFE: skip interest accrual to avoid NONDET IRM interaction complexity
    require(to_mathint(e.block.timestamp)
        == ghostMbLastUpdate128[id],
        "SAFE: no elapsed time -- interest accrual is a no-op");

    // SAFE: Morpho holds enough collateral tokens to cover the withdrawal.
    address collateralToken = ghostMbCollateralToken[id];
    require(ghostERC20Balances128[collateralToken][currentContract]
        >= userCollateral,
        "SAFE: Morpho token balance covers collateral withdrawal");

    withdrawCollateral(e, marketParams, require_uint256(userCollateral), onBehalf, receiver);

    satisfy(ghostMbCollateral128[id][onBehalf] == 0,
        "Full collateral withdrawal clearing all collateral must be reachable");
}
