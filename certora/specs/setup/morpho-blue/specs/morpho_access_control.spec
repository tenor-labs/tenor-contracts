import "./morpho_valid_state.spec";

// ========== Access Control ==========

// AC-01: Unauthorized caller cannot decrease user's supply shares
// FORMULA: sender != user && !isAuthorizedBefore => supplySharesAfter >= supplySharesBefore
rule unauthorizedCannotDecreaseSupplyShares(
    env e, method f, calldataarg args, MorphoHarness.Id id, address user
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {
    setupValidStateMB(e);

    bool isAuthorizedBefore = ghostMbIsAuthorized[user][e.msg.sender];
    mathint sharesBefore = ghostMbSupplyShares256[id][user];

    f(e, args);

    mathint sharesAfter = ghostMbSupplyShares256[id][user];

    assert(e.msg.sender != user && !isAuthorizedBefore => sharesAfter >= sharesBefore,
        "Unauthorized caller must not decrease user's supply shares");
}

// AC-02: Unauthorized caller cannot increase user's borrow shares
// FORMULA: sender != user && !isAuthorizedBefore => borrowSharesAfter <= borrowSharesBefore
rule unauthorizedCannotIncreaseBorrowShares(
    env e, method f, calldataarg args, MorphoHarness.Id id, address user
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {
    setupValidStateMB(e);

    bool isAuthorizedBefore = ghostMbIsAuthorized[user][e.msg.sender];
    mathint borrowSharesBefore = ghostMbBorrowShares128[id][user];

    f(e, args);

    mathint borrowSharesAfter = ghostMbBorrowShares128[id][user];

    assert(e.msg.sender != user && !isAuthorizedBefore => borrowSharesAfter <= borrowSharesBefore,
        "Unauthorized caller must not increase user's borrow shares");
}

// AC-03: Unauthorized non-liquidation cannot decrease user's collateral
// FORMULA: sender != user && !isAuthorizedBefore && f != liquidate => collateralAfter >= collateralBefore
rule unauthorizedCannotDecreaseCollateral(
    env e, method f, calldataarg args, MorphoHarness.Id id, address user
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {
    setupValidStateMB(e);

    bool isAuthorizedBefore = ghostMbIsAuthorized[user][e.msg.sender];
    mathint collateralBefore = ghostMbCollateral128[id][user];

    f(e, args);

    mathint collateralAfter = ghostMbCollateral128[id][user];

    assert(e.msg.sender != user && !isAuthorizedBefore
        && f.selector != sig:liquidate(MorphoHarness.MarketParams,address,uint256,uint256,bytes).selector
        => collateralAfter >= collateralBefore,
        "Unauthorized non-liquidation caller must not decrease user's collateral");
}
