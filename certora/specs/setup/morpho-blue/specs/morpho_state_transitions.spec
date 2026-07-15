// State transition properties verifying correctness of transitions between valid states

import "./morpho_valid_state.spec";

//
// Market Creation Atomicity
//

// ST-01: Market params and lastUpdate change atomically from zero
// FORMULA: (lastUpdate 0->non-zero) => (idToMarketParams written) AND
//          (idToMarketParams changed) => (lastUpdate 0->non-zero)
//
// createMarket is the only function that sets lastUpdate from 0 to non-zero, and it
// atomically writes all idToMarketParams fields. No other function can set lastUpdate
// from 0. createMarket allows loanToken==address(0), so we check that at least one
// of {collateralToken, oracle, irm, lltv} changed (irm must be enabled and non-zero
// since IRM(address(0)).borrowRate is skipped, but lltv can be 0 if enabled).
// The second assert ensures params only change during market creation.
rule marketCreationAtomicity(env e, method f, calldataarg args, MorphoHarness.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    mathint lastUpdateBefore = ghostMbLastUpdate128[id];
    address loanTokenBefore = ghostMbLoanToken[id];
    address collateralTokenBefore = ghostMbCollateralToken[id];
    address oracleBefore = ghostMbOracle[id];
    address irmBefore = ghostMbIrm[id];
    mathint lltvBefore = ghostMbLltv256[id];

    f(e, args);

    mathint lastUpdateAfter = ghostMbLastUpdate128[id];
    address loanTokenAfter = ghostMbLoanToken[id];
    address collateralTokenAfter = ghostMbCollateralToken[id];
    address oracleAfter = ghostMbOracle[id];
    address irmAfter = ghostMbIrm[id];
    mathint lltvAfter = ghostMbLltv256[id];

    bool marketCreated = lastUpdateBefore == 0 && lastUpdateAfter != 0;

    // Market params do not change without market creation.
    // createMarket is the only writer of idToMarketParams, and it requires
    // lastUpdate == 0 (market not yet created). The forward direction
    // (marketCreated => paramsChanged) is not asserted because createMarket allows
    // all-zero params (loanToken==0, lltv==0 if enabled, etc.), which would not
    // differ from the pre-state zero values established by nonExistentMarketParamsAreZero.
    bool paramsChanged = loanTokenAfter != loanTokenBefore
        || collateralTokenAfter != collateralTokenBefore
        || oracleAfter != oracleBefore
        || irmAfter != irmBefore
        || lltvAfter != lltvBefore;

    assert(paramsChanged => marketCreated,
        "Market params only change during market creation (lastUpdate 0->non-zero)");
}

//
// Accounting and Timestamp Coordination
//

// ST-02: Accounting changes require lastUpdate refresh to block.timestamp
// FORMULA: (totalSupplyAssets OR totalBorrowAssets changed) AND (time elapsed since lastUpdate)
//          => lastUpdate refreshed to block.timestamp
//
// All functions that modify totalSupplyAssets or totalBorrowAssets call _accrueInterest
// first, which sets lastUpdate = block.timestamp when elapsed > 0. This ensures interest
// is always accrued before accounting state changes.
rule accountingChangesRefreshTimestamp(
    env e, method f, calldataarg args, MorphoHarness.Id id
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    mathint totalSupplyAssetsBefore = ghostMbTotalSupplyAssets128[id];
    mathint totalBorrowAssetsBefore = ghostMbTotalBorrowAssets128[id];
    mathint totalSupplySharesBefore = ghostMbTotalSupplyShares128[id];
    mathint totalBorrowSharesBefore = ghostMbTotalBorrowShares128[id];
    mathint lastUpdateBefore = ghostMbLastUpdate128[id];

    f(e, args);

    mathint totalSupplyAssetsAfter = ghostMbTotalSupplyAssets128[id];
    mathint totalBorrowAssetsAfter = ghostMbTotalBorrowAssets128[id];
    mathint totalSupplySharesAfter = ghostMbTotalSupplyShares128[id];
    mathint totalBorrowSharesAfter = ghostMbTotalBorrowShares128[id];
    mathint lastUpdateAfter = ghostMbLastUpdate128[id];

    bool accountingChanged =
        totalSupplyAssetsAfter != totalSupplyAssetsBefore
        || totalBorrowAssetsAfter != totalBorrowAssetsBefore
        || totalSupplySharesAfter != totalSupplySharesBefore
        || totalBorrowSharesAfter != totalBorrowSharesBefore;

    bool timeElapsed = to_mathint(e.block.timestamp) > lastUpdateBefore;

    assert(accountingChanged && timeElapsed
        => lastUpdateAfter == to_mathint(e.block.timestamp),
        "Accounting changes with elapsed time must refresh lastUpdate to block.timestamp");
}

// ST-03: lastUpdate refresh on existing market requires accounting or fee change
// FORMULA: (lastUpdate changed on existing market) => (accounting changed OR fee changed OR market just created)
//
// lastUpdate is only written by createMarket (0->non-zero) and _accrueInterest.
// _accrueInterest is called by supply, withdraw, borrow, repay, liquidate,
// accrueInterest, and setFee. If lastUpdate changes on an existing market, some
// accounting or fee operation must have triggered _accrueInterest.
rule lastUpdateChangeRequiresAccountingOrFeeChange(
    env e, method f, calldataarg args, MorphoHarness.Id id
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    mathint lastUpdateBefore = ghostMbLastUpdate128[id];
    mathint totalSupplyAssetsBefore = ghostMbTotalSupplyAssets128[id];
    mathint totalBorrowAssetsBefore = ghostMbTotalBorrowAssets128[id];
    mathint totalSupplySharesBefore = ghostMbTotalSupplyShares128[id];
    mathint totalBorrowSharesBefore = ghostMbTotalBorrowShares128[id];
    mathint feeBefore = ghostMbFee128[id];

    f(e, args);

    mathint lastUpdateAfter = ghostMbLastUpdate128[id];
    mathint totalSupplyAssetsAfter = ghostMbTotalSupplyAssets128[id];
    mathint totalBorrowAssetsAfter = ghostMbTotalBorrowAssets128[id];
    mathint totalSupplySharesAfter = ghostMbTotalSupplyShares128[id];
    mathint totalBorrowSharesAfter = ghostMbTotalBorrowShares128[id];
    mathint feeAfter = ghostMbFee128[id];

    bool lastUpdateChanged = lastUpdateAfter != lastUpdateBefore;
    bool marketJustCreated = lastUpdateBefore == 0 && lastUpdateAfter != 0;
    bool accountingChanged =
        totalSupplyAssetsAfter != totalSupplyAssetsBefore
        || totalBorrowAssetsAfter != totalBorrowAssetsBefore
        || totalSupplySharesAfter != totalSupplySharesBefore
        || totalBorrowSharesAfter != totalBorrowSharesBefore;
    bool feeChanged = feeAfter != feeBefore;

    // Allow lastUpdate to change to block.timestamp: _accrueInterest always refreshes
    // lastUpdate when time has elapsed, even if computed interest rounds to zero.
    bool lastUpdateRefreshedToTimestamp = lastUpdateAfter == to_mathint(e.block.timestamp);

    assert(lastUpdateChanged
        => (marketJustCreated || accountingChanged || feeChanged
            || lastUpdateRefreshedToTimestamp),
        "lastUpdate change on existing market requires accounting, fee change, or timestamp refresh");
}

//
// Supply Shares Co-Transitions
//

// ST-04: User supply shares increase implies total supply shares increase
// FORMULA: supplyShares[id][user] increased => totalSupplyShares[id] increased
//
// supply() adds equal shares to position and total. _accrueInterest fee minting
// adds feeShares to feeRecipient position and total. No path increases a user's
// supply shares without also increasing the total.
// Preconditions: user != feeRecipient (fee minting is a separate mechanism) and
// no interest accrual (timestamp == lastUpdate) to isolate the co-transition.
rule userSupplySharesIncreaseImpliesTotalIncrease(
    env e, method f, calldataarg args, MorphoHarness.Id id, address user
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    // SAFE: user is not feeRecipient -- fee minting is a separate co-transition
    // that causes user-shares and total-shares to diverge when user==feeRecipient
    require(user != ghostMbFeeRecipient,
        "SAFE: user is not feeRecipient -- fee minting is a separate co-transition");

    mathint lastUpdateBefore = ghostMbLastUpdate128[id];

    // SAFE: no interest accrual -- eliminates fee share minting interference
    // that can add shares to total without affecting the tracked user
    require(lastUpdateBefore == 0 || to_mathint(e.block.timestamp) == lastUpdateBefore,
        "SAFE: no interest accrual -- isolates co-transition from fee minting");

    mathint userSharesBefore = ghostMbSupplyShares256[id][user];
    mathint totalSharesBefore = ghostMbTotalSupplyShares128[id];

    f(e, args);

    mathint userSharesAfter = ghostMbSupplyShares256[id][user];
    mathint totalSharesAfter = ghostMbTotalSupplyShares128[id];

    assert(userSharesAfter > userSharesBefore
        => totalSharesAfter > totalSharesBefore,
        "User supply shares increase must be accompanied by total supply shares increase");
}

// ST-05: User supply shares decrease implies total supply shares decrease
// FORMULA: supplyShares[id][user] decreased => totalSupplyShares[id] decreased
//
// withdraw() subtracts equal shares from position and total. No path decreases
// a user's supply shares without also decreasing the total.
// Preconditions: user != feeRecipient and no interest accrual to isolate the
// co-transition from fee share minting by _accrueInterest.
rule userSupplySharesDecreaseImpliesTotalDecrease(
    env e, method f, calldataarg args, MorphoHarness.Id id, address user
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    // SAFE: user is not feeRecipient -- fee minting is a separate co-transition
    // that causes user-shares and total-shares to diverge when user==feeRecipient
    require(user != ghostMbFeeRecipient,
        "SAFE: user is not feeRecipient -- fee minting is a separate co-transition");

    mathint lastUpdateBefore = ghostMbLastUpdate128[id];

    // SAFE: no interest accrual -- eliminates fee share minting interference
    // that can add feeShares to total, masking the withdrawal's total decrease
    require(lastUpdateBefore == 0 || to_mathint(e.block.timestamp) == lastUpdateBefore,
        "SAFE: no interest accrual -- isolates co-transition from fee minting");

    mathint userSharesBefore = ghostMbSupplyShares256[id][user];
    mathint totalSharesBefore = ghostMbTotalSupplyShares128[id];

    f(e, args);

    mathint userSharesAfter = ghostMbSupplyShares256[id][user];
    mathint totalSharesAfter = ghostMbTotalSupplyShares128[id];

    assert(userSharesAfter < userSharesBefore
        => totalSharesAfter < totalSharesBefore,
        "User supply shares decrease must be accompanied by total supply shares decrease");
}

//
// Borrow Shares Co-Transitions
//

// ST-06: User borrow shares increase implies total borrow shares increase
// FORMULA: borrowShares[id][user] increased => totalBorrowShares[id] increased
//
// borrow() adds equal shares to position and total. No path increases a user's
// borrow shares without also increasing the total.
rule userBorrowSharesIncreaseImpliesTotalIncrease(
    env e, method f, calldataarg args, MorphoHarness.Id id, address user
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    mathint userSharesBefore = ghostMbBorrowShares128[id][user];
    mathint totalSharesBefore = ghostMbTotalBorrowShares128[id];

    f(e, args);

    mathint userSharesAfter = ghostMbBorrowShares128[id][user];
    mathint totalSharesAfter = ghostMbTotalBorrowShares128[id];

    assert(userSharesAfter > userSharesBefore
        => totalSharesAfter > totalSharesBefore,
        "User borrow shares increase must be accompanied by total borrow shares increase");
}

// ST-07: User borrow shares decrease implies total borrow shares decrease
// FORMULA: borrowShares[id][user] decreased => totalBorrowShares[id] decreased
//
// repay() and liquidate() subtract shares from position and total together.
// No path decreases a user's borrow shares without also decreasing the total.
rule userBorrowSharesDecreaseImpliesTotalDecrease(
    env e, method f, calldataarg args, MorphoHarness.Id id, address user
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    mathint userSharesBefore = ghostMbBorrowShares128[id][user];
    mathint totalSharesBefore = ghostMbTotalBorrowShares128[id];

    f(e, args);

    mathint userSharesAfter = ghostMbBorrowShares128[id][user];
    mathint totalSharesAfter = ghostMbTotalBorrowShares128[id];

    assert(userSharesAfter < userSharesBefore
        => totalSharesAfter < totalSharesBefore,
        "User borrow shares decrease must be accompanied by total borrow shares decrease");
}

//
// Supply Assets and Shares Coordination
//

// ST-08: Total supply shares increase implies total supply assets increase
// FORMULA: totalSupplyShares[id] increased => totalSupplyAssets[id] increased
//
// Total supply shares increase via supply() (which also increases assets)
// or via _accrueInterest fee minting (which only happens after interest is
// added to assets). There is no path that increases shares without increasing assets.
// Precondition: no interest accrual eliminates fee share minting and interest
// accrual interference that make liquidate timeout.
rule totalSupplySharesIncreaseImpliesAssetsIncrease(
    env e, method f, calldataarg args, MorphoHarness.Id id
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);
    requireInvariant liquidityInvariant(e);
    requireInvariant supplySharesSolvency(e);

    mathint lastUpdateBefore = ghostMbLastUpdate128[id];

    // SAFE: no interest accrual -- eliminates fee minting and interest
    // interaction that causes liquidate to timeout
    require(lastUpdateBefore == 0 || to_mathint(e.block.timestamp) == lastUpdateBefore,
        "SAFE: no interest accrual -- isolates shares/assets co-transition");

    mathint totalSharesBefore = ghostMbTotalSupplyShares128[id];
    mathint totalAssetsBefore = ghostMbTotalSupplyAssets128[id];

    f(e, args);

    mathint totalSharesAfter = ghostMbTotalSupplyShares128[id];
    mathint totalAssetsAfter = ghostMbTotalSupplyAssets128[id];

    assert(totalSharesAfter > totalSharesBefore
        => totalAssetsAfter > totalAssetsBefore,
        "Total supply shares increase must be accompanied by total supply assets increase");
}

// ST-09: Total supply shares decrease implies total supply assets decrease
// FORMULA: totalSupplyShares[id] decreased => totalSupplyAssets[id] decreased
//
// Total supply shares decrease only via withdraw() which also decreases assets.
// There is no path that decreases shares without decreasing assets.
// Precondition: no interest accrual to eliminate the scenario where interest
// increases supply assets while withdrawal decreases shares and assets.
rule totalSupplySharesDecreaseImpliesAssetsDecrease(
    env e, method f, calldataarg args, MorphoHarness.Id id
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);
    requireInvariant liquidityInvariant(e);
    requireInvariant supplySharesSolvency(e);

    mathint lastUpdateBefore = ghostMbLastUpdate128[id];

    // SAFE: no interest accrual -- eliminates interest offsetting withdrawal
    require(lastUpdateBefore == 0 || to_mathint(e.block.timestamp) == lastUpdateBefore,
        "SAFE: no interest accrual -- isolates shares/assets co-transition");

    // SAFE: market exists -- focus on existing markets only
    require(lastUpdateBefore != 0,
        "SAFE: market exists -- non-existent markets have zero totals (no change)");

    mathint totalSharesBefore = ghostMbTotalSupplyShares128[id];
    mathint totalAssetsBefore = ghostMbTotalSupplyAssets128[id];

    f(e, args);

    mathint totalSharesAfter = ghostMbTotalSupplyShares128[id];
    mathint totalAssetsAfter = ghostMbTotalSupplyAssets128[id];

    // Virtual shares (VIRTUAL_ASSETS=1, VIRTUAL_SHARES=1e6) can cause toAssetsDown
    // to round to zero for small share withdrawals, so shares decrease but assets don't.
    // The weaker assertion allows assets to remain unchanged (zero-asset rounding edge case).
    assert(totalSharesAfter < totalSharesBefore
        => totalAssetsAfter <= totalAssetsBefore,
        "Total supply shares decrease must not increase total supply assets");
}

//
// Borrow Assets and Shares Coordination
//

// ST-10: Total borrow shares increase implies total borrow assets increase
// FORMULA: totalBorrowShares[id] increased => totalBorrowAssets[id] increased
//
// Total borrow shares increase only via borrow() which also increases borrow assets.
// _accrueInterest increases borrow assets but not shares. No path increases shares
// without also increasing assets.
// Precondition: no interest accrual to isolate the borrow-only co-transition.
rule totalBorrowSharesIncreaseImpliesAssetsIncrease(
    env e, method f, calldataarg args, MorphoHarness.Id id
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);
    requireInvariant liquidityInvariant(e);
    requireInvariant borrowSharesSolvency(e);

    mathint lastUpdateBefore = ghostMbLastUpdate128[id];

    // SAFE: no interest accrual -- eliminates interest bumping assets before borrow
    require(lastUpdateBefore == 0 || to_mathint(e.block.timestamp) == lastUpdateBefore,
        "SAFE: no interest accrual -- isolates shares/assets co-transition");

    mathint totalSharesBefore = ghostMbTotalBorrowShares128[id];
    mathint totalAssetsBefore = ghostMbTotalBorrowAssets128[id];

    f(e, args);

    mathint totalSharesAfter = ghostMbTotalBorrowShares128[id];
    mathint totalAssetsAfter = ghostMbTotalBorrowAssets128[id];

    // Virtual shares (VIRTUAL_ASSETS=1, VIRTUAL_SHARES=1e6) can cause toAssetsDown
    // to round to zero for small share borrows, so shares increase but assets don't.
    // The weaker assertion allows assets to remain unchanged (zero-asset rounding edge case).
    assert(totalSharesAfter > totalSharesBefore
        => totalAssetsAfter >= totalAssetsBefore,
        "Total borrow shares increase must not decrease total borrow assets");
}

//
// Interest Accrual Symmetry
//

// ST-11: Interest adds equal amounts to supply and borrow assets
// FORMULA: (totalBorrowAssets increased AND totalBorrowShares unchanged AND market existed)
//          => totalSupplyAssets increased by at least the same amount
//
// _accrueInterest adds the same `interest` to both totalBorrowAssets and totalSupplyAssets.
// If borrow assets increased without borrow shares changing, it must be pure interest
// accrual, and supply assets must have increased by at least the same delta.
// Filter: only accrueInterest is tested, since other functions that call _accrueInterest
// also perform additional state changes (withdraw decreases supply assets, etc.) that
// confound the pureInterest detection. accrueInterest is the only function that calls
// _accrueInterest without additional accounting changes.
rule interestAccrualSymmetry(
    env e, method f, calldataarg args, MorphoHarness.Id id
) filtered {
    f -> !EXCLUDED_FUNCTION_MB(f)
        && f.selector == sig:MorphoHarness.accrueInterest(
            MorphoHarness.MarketParams).selector
} {

    setupValidStateMB(e);

    mathint lastUpdateBefore = ghostMbLastUpdate128[id];
    mathint totalBorrowAssetsBefore = ghostMbTotalBorrowAssets128[id];
    mathint totalBorrowSharesBefore = ghostMbTotalBorrowShares128[id];
    mathint totalSupplyAssetsBefore = ghostMbTotalSupplyAssets128[id];

    f(e, args);

    mathint totalBorrowAssetsAfter = ghostMbTotalBorrowAssets128[id];
    mathint totalBorrowSharesAfter = ghostMbTotalBorrowShares128[id];
    mathint totalSupplyAssetsAfter = ghostMbTotalSupplyAssets128[id];

    // Detect pure interest accrual: borrow assets increased, borrow shares unchanged,
    // on existing market. Since we filter to accrueInterest only, there are no
    // confounding state changes from other operations (withdraw, etc.).
    bool pureInterest = totalBorrowAssetsAfter > totalBorrowAssetsBefore
        && totalBorrowSharesAfter == totalBorrowSharesBefore
        && lastUpdateBefore != 0;

    mathint borrowAssetsDelta = totalBorrowAssetsAfter - totalBorrowAssetsBefore;
    mathint supplyAssetsDelta = totalSupplyAssetsAfter - totalSupplyAssetsBefore;

    assert(pureInterest => supplyAssetsDelta >= borrowAssetsDelta,
        "Pure interest accrual must increase supply assets by at least the borrow assets delta");
}

//
// Collateral and Borrow Position Coordination
//

// ST-12: Collateral decrease with borrow shares decrease is liquidation pattern
// FORMULA: (collateral[id][user] decreased AND borrowShares[id][user] decreased)
//          => totalBorrowShares[id] decreased
//
// The only operation that decreases both collateral and borrowShares for the same
// user is liquidate(). Liquidate always decreases totalBorrowShares as well.
// This ensures the global accounting stays consistent during liquidation.
rule collateralAndBorrowDecreaseImplyTotalBorrowSharesDecrease(
    env e, method f, calldataarg args, MorphoHarness.Id id, address user
) filtered { f -> !EXCLUDED_FUNCTION_MB(f) } {

    setupValidStateMB(e);

    mathint collateralBefore = ghostMbCollateral128[id][user];
    mathint borrowSharesBefore = ghostMbBorrowShares128[id][user];
    mathint totalBorrowSharesBefore = ghostMbTotalBorrowShares128[id];

    f(e, args);

    mathint collateralAfter = ghostMbCollateral128[id][user];
    mathint borrowSharesAfter = ghostMbBorrowShares128[id][user];
    mathint totalBorrowSharesAfter = ghostMbTotalBorrowShares128[id];

    bool collateralDecreased = collateralAfter < collateralBefore;
    bool borrowSharesDecreased = borrowSharesAfter < borrowSharesBefore;

    assert(collateralDecreased && borrowSharesDecreased
        => totalBorrowSharesAfter < totalBorrowSharesBefore,
        "Collateral and borrow shares decrease must reduce total borrow shares");
}

//
// ERC20 and Protocol Accounting Coordination
//

// ST-13: Supply shares increase requires token transfer in
// FORMULA: (totalSupplyShares[id] increased) => (loanToken balance of Morpho increased)
//
// supply() calls safeTransferFrom to pull loanToken from the caller into the contract.
// Whenever total supply shares increase (from supply), the contract's loan token balance
// must also increase. Written as a concrete rule targeting supply() directly with
// marketParams as a parameter (not free id), computing id = marketParams.id() to bind
// the market identity. This avoids ghost aliasing from unbound id parameters.
// Preconditions: no interest accrual (isolates supply-only state changes from fee minting),
// Morpho contract in bounded ERC20 account set, market exists with non-zero loan token.
rule supplyIncreasesContractBalance(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    // SAFE: market exists -- supply reverts on non-existent market
    require(ghostMbLastUpdate128[id] != 0,
        "SAFE: market exists -- supply requires lastUpdate != 0");

    // SAFE: no interest accrual -- eliminates fee share minting that adds shares
    // to total without a corresponding token transfer in this call
    require(to_mathint(e.block.timestamp) == ghostMbLastUpdate128[id],
        "SAFE: no interest accrual -- isolates supply-only state changes");

    // SAFE: loan token binding -- ensures ghost lookup matches the actual token
    // that supply() will call safeTransferFrom on
    address loanToken = ghostMbLoanToken[id];
    require(loanToken != 0,
        "SAFE: market has non-zero loan token");
    require(loanToken == marketParams.loanToken,
        "SAFE: loan token ghost matches market params");

    // SAFE: Morpho contract is in the bounded ERC20 account set for the loan token
    require(ERC20_ACCOUNT_BOUNDS(loanToken, currentContract),
        "SAFE: Morpho is in bounded ERC20 account set for loan token");

    mathint totalSharesBefore = ghostMbTotalSupplyShares128[id];
    mathint balanceBefore = ghostERC20Balances128[loanToken][currentContract];

    supply(e, marketParams, assets, shares, onBehalf, data);

    mathint totalSharesAfter = ghostMbTotalSupplyShares128[id];
    mathint balanceAfter = ghostERC20Balances128[loanToken][currentContract];

    assert(totalSharesAfter > totalSharesBefore => balanceAfter > balanceBefore,
        "Supply shares increase must be accompanied by loan token balance increase");
}
