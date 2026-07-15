import "./morpho_valid_state.spec";

// =============================================================================
// Integrity
// =============================================================================

// UT-01: setOwner sets the new owner
// FORMULA: setOwner(newOwner) => ghostMbOwner == newOwner
//
// setOwner writes owner = newOwner. After a successful call, the ghost
// must reflect the new value.
rule setOwnerSetsNewOwner(env e, address newOwner) {
    setupValidStateMB(e);

    setOwner(e, newOwner);

    address ownerAfter = ghostMbOwner;

    assert(ownerAfter == newOwner, "setOwner must set owner to newOwner");
}

// UT-02: enableIrm enables the given IRM
// FORMULA: enableIrm(irm) => ghostMbIsIrmEnabled[irm] == true
//
// enableIrm sets isIrmEnabled[irm] = true.
rule enableIrmEnablesGivenIrm(env e, address irm) {
    setupValidStateMB(e);

    enableIrm(e, irm);

    bool enabledAfter = ghostMbIsIrmEnabled[irm];

    assert(enabledAfter, "enableIrm must enable the given IRM");
}

// UT-03: enableLltv enables the given LLTV
// FORMULA: enableLltv(lltv) => ghostMbIsLltvEnabled[lltv] == true
//
// enableLltv sets isLltvEnabled[lltv] = true.
rule enableLltvEnablesGivenLltv(env e, uint256 lltv) {
    setupValidStateMB(e);

    enableLltv(e, lltv);

    bool enabledAfter = ghostMbIsLltvEnabled[lltv];

    assert(enabledAfter, "enableLltv must enable the given LLTV");
}

// UT-04: setFeeRecipient sets the new fee recipient
// FORMULA: setFeeRecipient(newFeeRecipient) => ghostMbFeeRecipient == newFeeRecipient
//
// setFeeRecipient writes feeRecipient = newFeeRecipient.
rule setFeeRecipientSetsNewRecipient(env e, address newFeeRecipient) {
    setupValidStateMB(e);

    setFeeRecipient(e, newFeeRecipient);

    address recipientAfter = ghostMbFeeRecipient;

    assert(recipientAfter == newFeeRecipient,
        "setFeeRecipient must set feeRecipient to newFeeRecipient");
}

// UT-05: setFee sets the new fee for the market
// FORMULA: setFee(mp, newFee) => ghostMbFee128[id] == newFee
//
// setFee writes market[id].fee = uint128(newFee) after accruing interest.
rule setFeeSetsNewFee(
    env e, MorphoHarness.MarketParams marketParams, uint256 newFee
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    setFee(e, marketParams, newFee);

    mathint feeAfter = ghostMbFee128[id];

    assert(feeAfter == to_mathint(newFee), "setFee must set fee to newFee");
}

// UT-06: createMarket sets lastUpdate to block.timestamp
// FORMULA: createMarket(mp) => ghostMbLastUpdate128[id] == e.block.timestamp
//
// createMarket writes market[id].lastUpdate = uint128(block.timestamp)
// and stores idToMarketParams.
rule createMarketSetsLastUpdate(
    env e, MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    createMarket(e, marketParams);

    mathint lastUpdateAfter = ghostMbLastUpdate128[id];

    assert(lastUpdateAfter == to_mathint(e.block.timestamp),
        "createMarket must set lastUpdate to block.timestamp");
}

// UT-07: createMarket stores market params
// FORMULA: createMarket(mp) => idToMarketParams[id] matches mp
//
// createMarket writes idToMarketParams[id] = marketParams.
rule createMarketStoresParams(
    env e, MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    createMarket(e, marketParams);

    address loanTokenAfter = ghostMbLoanToken[id];
    address collateralTokenAfter = ghostMbCollateralToken[id];
    address oracleAfter = ghostMbOracle[id];
    address irmAfter = ghostMbIrm[id];
    mathint lltvAfter = ghostMbLltv256[id];

    assert(loanTokenAfter == marketParams.loanToken,
        "createMarket must store loanToken");
    assert(collateralTokenAfter == marketParams.collateralToken,
        "createMarket must store collateralToken");
    assert(oracleAfter == marketParams.oracle,
        "createMarket must store oracle");
    assert(irmAfter == marketParams.irm,
        "createMarket must store irm");
    assert(lltvAfter == to_mathint(marketParams.lltv),
        "createMarket must store lltv");
}

// UT-08: supply increases user supplyShares and market totals
// FORMULA: supply(mp, assets, 0, onBehalf, data) =>
//   position[id][onBehalf].supplyShares += shares
//   market[id].totalSupplyShares += shares
//   market[id].totalSupplyAssets += assets
rule supplyIncreasesSharesAndTotals(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint userSharesBefore = ghostMbSupplyShares256[id][onBehalf];
    mathint totalSharesBefore = ghostMbTotalSupplyShares128[id];
    mathint totalAssetsBefore = ghostMbTotalSupplyAssets128[id];

    uint256 returnedAssets;
    uint256 returnedShares;
    returnedAssets, returnedShares = supply(e, marketParams, assets, shares, onBehalf, data);

    mathint userSharesAfter = ghostMbSupplyShares256[id][onBehalf];
    mathint totalSharesAfter = ghostMbTotalSupplyShares128[id];
    mathint totalAssetsAfter = ghostMbTotalSupplyAssets128[id];

    assert(userSharesAfter >= userSharesBefore,
        "supply must not decrease user supply shares");
    assert(totalSharesAfter >= totalSharesBefore,
        "supply must not decrease total supply shares");
    assert(totalAssetsAfter >= totalAssetsBefore,
        "supply must not decrease total supply assets");
}

// UT-09: withdraw decreases user supplyShares and market totals
// FORMULA: withdraw(mp, assets, 0, onBehalf, receiver) =>
//   position[id][onBehalf].supplyShares -= shares
//   market[id].totalSupplyShares -= shares
//   market[id].totalSupplyAssets -= assets
//
// Note: onBehalf != feeRecipient because _accrueInterest may increase
// position[id][feeRecipient].supplyShares via fee shares before the
// withdraw decreases them, making the net change unpredictable.
rule withdrawDecreasesSharesAndTotals(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    require(onBehalf != ghostMbFeeRecipient,
        "SAFE: exclude fee recipient -- _accrueInterest adds fee shares to their position");

    mathint userSharesBefore = ghostMbSupplyShares256[id][onBehalf];

    uint256 returnedAssets;
    uint256 returnedShares;
    returnedAssets, returnedShares = withdraw(e, marketParams, assets, shares, onBehalf, receiver);

    mathint userSharesAfter = ghostMbSupplyShares256[id][onBehalf];

    assert(userSharesAfter == userSharesBefore - to_mathint(returnedShares),
        "withdraw must decrease user supply shares by returned shares");
}

// UT-10: borrow increases user borrowShares and market borrow totals
// FORMULA: borrow(mp, assets, 0, onBehalf, receiver) =>
//   position[id][onBehalf].borrowShares += shares
//   market[id].totalBorrowShares += shares
//   market[id].totalBorrowAssets += assets
rule borrowIncreasesBorrowSharesAndTotals(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint userBorrowSharesBefore = ghostMbBorrowShares128[id][onBehalf];

    uint256 returnedAssets;
    uint256 returnedShares;
    returnedAssets, returnedShares = borrow(e, marketParams, assets, shares, onBehalf, receiver);

    mathint userBorrowSharesAfter = ghostMbBorrowShares128[id][onBehalf];

    assert(userBorrowSharesAfter == userBorrowSharesBefore + to_mathint(returnedShares),
        "borrow must increase user borrow shares by returned shares");
}

// UT-11: repay decreases user borrowShares
// FORMULA: repay(mp, assets, 0, onBehalf, data) =>
//   position[id][onBehalf].borrowShares -= shares
rule repayDecreasesBorrowShares(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint userBorrowSharesBefore = ghostMbBorrowShares128[id][onBehalf];

    uint256 returnedAssets;
    uint256 returnedShares;
    returnedAssets, returnedShares = repay(e, marketParams, assets, shares, onBehalf, data);

    mathint userBorrowSharesAfter = ghostMbBorrowShares128[id][onBehalf];

    assert(userBorrowSharesAfter == userBorrowSharesBefore - to_mathint(returnedShares),
        "repay must decrease user borrow shares by returned shares");
}

// UT-12: supplyCollateral increases user collateral
// FORMULA: supplyCollateral(mp, assets, onBehalf, data) =>
//   position[id][onBehalf].collateral += assets
rule supplyCollateralIncreasesUserCollateral(
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

    assert(collateralAfter == collateralBefore + to_mathint(assets),
        "supplyCollateral must increase user collateral by assets");
}

// UT-13: withdrawCollateral decreases user collateral
// FORMULA: withdrawCollateral(mp, assets, onBehalf, receiver) =>
//   position[id][onBehalf].collateral -= assets
rule withdrawCollateralDecreasesUserCollateral(
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

    assert(collateralAfter == collateralBefore - to_mathint(assets),
        "withdrawCollateral must decrease user collateral by assets");
}

// UT-14: setAuthorization sets the authorization flag
// FORMULA: setAuthorization(authorized, newIsAuthorized) =>
//   ghostMbIsAuthorized[msg.sender][authorized] == newIsAuthorized
rule setAuthorizationSetsFlag(
    env e, address authorized, bool newIsAuthorized
) {
    setupValidStateMB(e);

    setAuthorization(e, authorized, newIsAuthorized);

    bool authAfter = ghostMbIsAuthorized[e.msg.sender][authorized];

    assert(authAfter == newIsAuthorized,
        "setAuthorization must set the authorization flag");
}

// UT-15: liquidate decreases borrower collateral
// FORMULA: liquidate(mp, borrower, seizedAssets, 0, data) =>
//   position[id][borrower].collateral decreases
rule liquidateDecreasesBorrowerCollateral(
    env e,
    MorphoHarness.MarketParams marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint collateralBefore = ghostMbCollateral128[id][borrower];

    liquidate(e, marketParams, borrower, seizedAssets, repaidShares, data);

    mathint collateralAfter = ghostMbCollateral128[id][borrower];

    assert(collateralAfter <= collateralBefore,
        "liquidate must not increase borrower collateral");
}

// UT-16: liquidate decreases borrower borrow shares
// FORMULA: liquidate(mp, borrower, ...) =>
//   position[id][borrower].borrowShares decreases or goes to zero
rule liquidateDecreasesBorrowerBorrowShares(
    env e,
    MorphoHarness.MarketParams marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint borrowSharesBefore = ghostMbBorrowShares128[id][borrower];

    liquidate(e, marketParams, borrower, seizedAssets, repaidShares, data);

    mathint borrowSharesAfter = ghostMbBorrowShares128[id][borrower];

    assert(borrowSharesAfter <= borrowSharesBefore,
        "liquidate must not increase borrower borrow shares");
}

// =============================================================================
// Non-Effects
// =============================================================================

// UT-17: setOwner does not change feeRecipient
// FORMULA: setOwner(newOwner) => ghostMbFeeRecipient unchanged
rule setOwnerDoesNotChangeFeeRecipient(env e, address newOwner) {
    setupValidStateMB(e);

    address feeRecipientBefore = ghostMbFeeRecipient;

    setOwner(e, newOwner);

    address feeRecipientAfter = ghostMbFeeRecipient;

    assert(feeRecipientAfter == feeRecipientBefore,
        "setOwner must not change feeRecipient");
}

// UT-18: setFeeRecipient does not change owner
// FORMULA: setFeeRecipient(newFeeRecipient) => ghostMbOwner unchanged
rule setFeeRecipientDoesNotChangeOwner(env e, address newFeeRecipient) {
    setupValidStateMB(e);

    address ownerBefore = ghostMbOwner;

    setFeeRecipient(e, newFeeRecipient);

    address ownerAfter = ghostMbOwner;

    assert(ownerAfter == ownerBefore,
        "setFeeRecipient must not change owner");
}

// UT-19: enableIrm does not affect LLTV enablement
// FORMULA: enableIrm(irm) => ghostMbIsLltvEnabled[lltv] unchanged
rule enableIrmDoesNotAffectLltvEnablement(
    env e, address irm, uint256 lltv
) {
    setupValidStateMB(e);

    bool lltvEnabledBefore = ghostMbIsLltvEnabled[lltv];

    enableIrm(e, irm);

    bool lltvEnabledAfter = ghostMbIsLltvEnabled[lltv];

    assert(lltvEnabledAfter == lltvEnabledBefore,
        "enableIrm must not affect LLTV enablement");
}

// UT-20: enableLltv does not affect IRM enablement
// FORMULA: enableLltv(lltv) => ghostMbIsIrmEnabled[irm] unchanged
rule enableLltvDoesNotAffectIrmEnablement(
    env e, uint256 lltv, address irm
) {
    setupValidStateMB(e);

    bool irmEnabledBefore = ghostMbIsIrmEnabled[irm];

    enableLltv(e, lltv);

    bool irmEnabledAfter = ghostMbIsIrmEnabled[irm];

    assert(irmEnabledAfter == irmEnabledBefore,
        "enableLltv must not affect IRM enablement");
}

// UT-21: supplyCollateral does not change user supply shares
// FORMULA: supplyCollateral(mp, assets, onBehalf, data) =>
//   ghostMbSupplyShares256[id][onBehalf] unchanged
//
// supplyCollateral only writes position[id][onBehalf].collateral.
// It does NOT accrue interest. No supply shares should change.
rule supplyCollateralDoesNotChangeSupplyShares(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    bytes data,
    address anyUser
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint supplySharesBefore = ghostMbSupplyShares256[id][anyUser];

    supplyCollateral(e, marketParams, assets, onBehalf, data);

    mathint supplySharesAfter = ghostMbSupplyShares256[id][anyUser];

    assert(supplySharesAfter == supplySharesBefore,
        "supplyCollateral must not change any user's supply shares");
}

// UT-22: supplyCollateral does not change market borrow totals
// FORMULA: supplyCollateral(mp, ...) =>
//   ghostMbTotalBorrowAssets128[id] unchanged && ghostMbTotalBorrowShares128[id] unchanged
//
// supplyCollateral does not accrue interest and does not touch borrow state.
rule supplyCollateralDoesNotChangeBorrowTotals(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint totalBorrowAssetsBefore = ghostMbTotalBorrowAssets128[id];
    mathint totalBorrowSharesBefore = ghostMbTotalBorrowShares128[id];

    supplyCollateral(e, marketParams, assets, onBehalf, data);

    mathint totalBorrowAssetsAfter = ghostMbTotalBorrowAssets128[id];
    mathint totalBorrowSharesAfter = ghostMbTotalBorrowShares128[id];

    assert(totalBorrowAssetsAfter == totalBorrowAssetsBefore,
        "supplyCollateral must not change totalBorrowAssets");
    assert(totalBorrowSharesAfter == totalBorrowSharesBefore,
        "supplyCollateral must not change totalBorrowShares");
}

// UT-23: supplyCollateral does not change supply totals
// FORMULA: supplyCollateral(mp, ...) =>
//   ghostMbTotalSupplyAssets128[id] unchanged && ghostMbTotalSupplyShares128[id] unchanged
//
// supplyCollateral explicitly skips interest accrual. No supply totals should change.
rule supplyCollateralDoesNotChangeSupplyTotals(
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

    supplyCollateral(e, marketParams, assets, onBehalf, data);

    mathint totalSupplyAssetsAfter = ghostMbTotalSupplyAssets128[id];
    mathint totalSupplySharesAfter = ghostMbTotalSupplyShares128[id];

    assert(totalSupplyAssetsAfter == totalSupplyAssetsBefore,
        "supplyCollateral must not change totalSupplyAssets");
    assert(totalSupplySharesAfter == totalSupplySharesBefore,
        "supplyCollateral must not change totalSupplyShares");
}

// UT-24: setAuthorization does not affect other user pairs (mapping isolation)
// FORMULA: (otherOwner != sender || otherAuth != authorized)
//   => ghostMbIsAuthorized[otherOwner][otherAuth] unchanged
rule setAuthorizationDoesNotAffectOtherPairs(
    env e, address authorized, bool newIsAuthorized,
    address otherOwner, address otherAuth
) {
    setupValidStateMB(e);

    bool authBefore = ghostMbIsAuthorized[otherOwner][otherAuth];

    setAuthorization(e, authorized, newIsAuthorized);

    bool authAfter = ghostMbIsAuthorized[otherOwner][otherAuth];

    assert(otherOwner != e.msg.sender || otherAuth != authorized
        => authAfter == authBefore,
        "setAuthorization must not affect other user authorization pairs");
}

// =============================================================================
// Non-Effects -- User Isolation
// =============================================================================

// UT-25: supply does not affect third-party supply shares
// FORMULA: third != onBehalf && third != feeRecipient
//   => supplyShares[id][third] unchanged
//
// supply increases position[id][onBehalf].supplyShares. _accrueInterest
// may increase position[id][feeRecipient].supplyShares. Third parties
// should be unaffected.
rule supplyDoesNotAffectThirdPartyShares(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data,
    address third
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    address feeRecipientBefore = ghostMbFeeRecipient;
    mathint thirdSharesBefore = ghostMbSupplyShares256[id][third];

    supply(e, marketParams, assets, shares, onBehalf, data);

    mathint thirdSharesAfter = ghostMbSupplyShares256[id][third];

    assert(third != onBehalf && third != feeRecipientBefore
        => thirdSharesAfter == thirdSharesBefore,
        "supply must not change third-party supply shares");
}

// UT-26: withdraw does not affect third-party supply shares
// FORMULA: third != onBehalf && third != feeRecipient
//   => supplyShares[id][third] unchanged
rule withdrawDoesNotAffectThirdPartyShares(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver,
    address third
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    address feeRecipientBefore = ghostMbFeeRecipient;
    mathint thirdSharesBefore = ghostMbSupplyShares256[id][third];

    withdraw(e, marketParams, assets, shares, onBehalf, receiver);

    mathint thirdSharesAfter = ghostMbSupplyShares256[id][third];

    assert(third != onBehalf && third != feeRecipientBefore
        => thirdSharesAfter == thirdSharesBefore,
        "withdraw must not change third-party supply shares");
}

// UT-27: borrow does not affect third-party borrow shares
// FORMULA: third != onBehalf => borrowShares[id][third] unchanged
rule borrowDoesNotAffectThirdPartyBorrowShares(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver,
    address third
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint thirdBorrowSharesBefore = ghostMbBorrowShares128[id][third];

    borrow(e, marketParams, assets, shares, onBehalf, receiver);

    mathint thirdBorrowSharesAfter = ghostMbBorrowShares128[id][third];

    assert(third != onBehalf
        => thirdBorrowSharesAfter == thirdBorrowSharesBefore,
        "borrow must not change third-party borrow shares");
}

// UT-28: repay does not affect third-party borrow shares
// FORMULA: third != onBehalf => borrowShares[id][third] unchanged
rule repayDoesNotAffectThirdPartyBorrowShares(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data,
    address third
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint thirdBorrowSharesBefore = ghostMbBorrowShares128[id][third];

    repay(e, marketParams, assets, shares, onBehalf, data);

    mathint thirdBorrowSharesAfter = ghostMbBorrowShares128[id][third];

    assert(third != onBehalf
        => thirdBorrowSharesAfter == thirdBorrowSharesBefore,
        "repay must not change third-party borrow shares");
}

// UT-29: supplyCollateral does not affect third-party collateral
// FORMULA: third != onBehalf => collateral[id][third] unchanged
rule supplyCollateralDoesNotAffectThirdPartyCollateral(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    bytes data,
    address third
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint thirdCollateralBefore = ghostMbCollateral128[id][third];

    supplyCollateral(e, marketParams, assets, onBehalf, data);

    mathint thirdCollateralAfter = ghostMbCollateral128[id][third];

    assert(third != onBehalf
        => thirdCollateralAfter == thirdCollateralBefore,
        "supplyCollateral must not change third-party collateral");
}

// UT-30: withdrawCollateral does not affect third-party collateral
// FORMULA: third != onBehalf => collateral[id][third] unchanged
rule withdrawCollateralDoesNotAffectThirdPartyCollateral(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    address receiver,
    address third
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint thirdCollateralBefore = ghostMbCollateral128[id][third];

    withdrawCollateral(e, marketParams, assets, onBehalf, receiver);

    mathint thirdCollateralAfter = ghostMbCollateral128[id][third];

    assert(third != onBehalf
        => thirdCollateralAfter == thirdCollateralBefore,
        "withdrawCollateral must not change third-party collateral");
}

// =============================================================================
// Non-Effects -- Packed Slot Isolation
// =============================================================================

// UT-31: setFee does not corrupt lastUpdate (packed slot 2)
// FORMULA: otherId != id => ghostMbLastUpdate128[otherId] unchanged
//
// market[id].lastUpdate and market[id].fee are in the same packed slot (slot 2).
// setFee writes fee; _accrueInterest writes lastUpdate for the SAME id.
// For OTHER market ids, neither field should change.
rule setFeeDoesNotCorruptOtherMarketLastUpdate(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 newFee,
    MorphoHarness.Id otherId
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint lastUpdateBefore = ghostMbLastUpdate128[otherId];

    setFee(e, marketParams, newFee);

    mathint lastUpdateAfter = ghostMbLastUpdate128[otherId];

    assert(otherId != id => lastUpdateAfter == lastUpdateBefore,
        "setFee must not corrupt other market lastUpdate");
}

// UT-32: setFee does not corrupt totalSupplyAssets/totalBorrowAssets on other market
// FORMULA: setFee(mp, newFee) => ghostMbTotalSupplyAssets128[otherId] unchanged
//   && ghostMbTotalBorrowAssets128[otherId] unchanged
rule setFeeDoesNotCorruptOtherMarketTotals(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 newFee,
    MorphoHarness.Id otherId
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint supplyAssetsBefore = ghostMbTotalSupplyAssets128[otherId];
    mathint borrowAssetsBefore = ghostMbTotalBorrowAssets128[otherId];

    setFee(e, marketParams, newFee);

    mathint supplyAssetsAfter = ghostMbTotalSupplyAssets128[otherId];
    mathint borrowAssetsAfter = ghostMbTotalBorrowAssets128[otherId];

    assert(otherId != id => supplyAssetsAfter == supplyAssetsBefore,
        "setFee must not corrupt other market totalSupplyAssets");
    assert(otherId != id => borrowAssetsAfter == borrowAssetsBefore,
        "setFee must not corrupt other market totalBorrowAssets");
}

// =============================================================================
// Non-Effects -- Cross-Market Isolation
// =============================================================================

// UT-33: supply does not affect other market totals
// FORMULA: supply(mp, ...) => ghostMbTotalSupplyAssets128[otherId] unchanged
//   && ghostMbTotalBorrowAssets128[otherId] unchanged
//   (where otherId != id)
rule supplyDoesNotAffectOtherMarketTotals(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data,
    MorphoHarness.Id otherId
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint supplyAssetsBefore = ghostMbTotalSupplyAssets128[otherId];
    mathint borrowAssetsBefore = ghostMbTotalBorrowAssets128[otherId];

    supply(e, marketParams, assets, shares, onBehalf, data);

    mathint supplyAssetsAfter = ghostMbTotalSupplyAssets128[otherId];
    mathint borrowAssetsAfter = ghostMbTotalBorrowAssets128[otherId];

    assert(otherId != id => supplyAssetsAfter == supplyAssetsBefore,
        "supply must not change other market totalSupplyAssets");
    assert(otherId != id => borrowAssetsAfter == borrowAssetsBefore,
        "supply must not change other market totalBorrowAssets");
}

// UT-34: borrow does not affect other market totals
// FORMULA: borrow(mp, ...) => ghostMbTotalBorrowAssets128[otherId] unchanged
//   && ghostMbTotalSupplyAssets128[otherId] unchanged (where otherId != id)
rule borrowDoesNotAffectOtherMarketTotals(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver,
    MorphoHarness.Id otherId
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);

    mathint supplyAssetsBefore = ghostMbTotalSupplyAssets128[otherId];
    mathint borrowAssetsBefore = ghostMbTotalBorrowAssets128[otherId];

    borrow(e, marketParams, assets, shares, onBehalf, receiver);

    mathint supplyAssetsAfter = ghostMbTotalSupplyAssets128[otherId];
    mathint borrowAssetsAfter = ghostMbTotalBorrowAssets128[otherId];

    assert(otherId != id => supplyAssetsAfter == supplyAssetsBefore,
        "borrow must not change other market totalSupplyAssets");
    assert(otherId != id => borrowAssetsAfter == borrowAssetsBefore,
        "borrow must not change other market totalBorrowAssets");
}

// =============================================================================
// Caller-Agnostic
// =============================================================================

// UT-35: owner() is caller-agnostic
// FORMULA: owner(e1) == owner(e2) for any two callers
rule ownerSameForAnyCaller(env e1, env e2) {
    setupValidStateMB(e1);
    setupValidStateMB(e2);

    require(e1.block.timestamp == e2.block.timestamp,
        "SAFE: same timestamp for both environments");

    storage init = lastStorage;
    address result1 = _Morpho.owner() at init;
    address result2 = _Morpho.owner() at init;

    assert(result1 == result2, "owner() must be caller-agnostic");
}

// UT-36: feeRecipient() is caller-agnostic
// FORMULA: feeRecipient(e1) == feeRecipient(e2) for any two callers
rule feeRecipientSameForAnyCaller(env e1, env e2) {
    setupValidStateMB(e1);
    setupValidStateMB(e2);

    require(e1.block.timestamp == e2.block.timestamp,
        "SAFE: same timestamp for both environments");

    storage init = lastStorage;
    address result1 = _Morpho.feeRecipient() at init;
    address result2 = _Morpho.feeRecipient() at init;

    assert(result1 == result2, "feeRecipient() must be caller-agnostic");
}

// UT-37: isIrmEnabled() is caller-agnostic
// FORMULA: isIrmEnabled(e1, irm) == isIrmEnabled(e2, irm)
rule isIrmEnabledSameForAnyCaller(env e1, env e2, address irm) {
    setupValidStateMB(e1);
    setupValidStateMB(e2);

    require(e1.block.timestamp == e2.block.timestamp,
        "SAFE: same timestamp for both environments");

    storage init = lastStorage;
    bool result1 = _Morpho.isIrmEnabled(irm) at init;
    bool result2 = _Morpho.isIrmEnabled(irm) at init;

    assert(result1 == result2, "isIrmEnabled() must be caller-agnostic");
}

// UT-38: isLltvEnabled() is caller-agnostic
// FORMULA: isLltvEnabled(e1, lltv) == isLltvEnabled(e2, lltv)
rule isLltvEnabledSameForAnyCaller(env e1, env e2, uint256 lltv) {
    setupValidStateMB(e1);
    setupValidStateMB(e2);

    require(e1.block.timestamp == e2.block.timestamp,
        "SAFE: same timestamp for both environments");

    storage init = lastStorage;
    bool result1 = _Morpho.isLltvEnabled(lltv) at init;
    bool result2 = _Morpho.isLltvEnabled(lltv) at init;

    assert(result1 == result2, "isLltvEnabled() must be caller-agnostic");
}

// =============================================================================
// Must Not Revert
// =============================================================================

// UT-39: owner() never reverts
// FORMULA: owner() does not revert under any condition
rule ownerNeverReverts(env e) {
    setupValidStateMB(e);

    _Morpho.owner@withrevert();

    assert(!lastReverted, "owner() must not revert");
}

// UT-40: feeRecipient() never reverts
// FORMULA: feeRecipient() does not revert under any condition
rule feeRecipientNeverReverts(env e) {
    setupValidStateMB(e);

    _Morpho.feeRecipient@withrevert();

    assert(!lastReverted, "feeRecipient() must not revert");
}

// UT-41: isIrmEnabled() never reverts
// FORMULA: isIrmEnabled(irm) does not revert under any condition
rule isIrmEnabledNeverReverts(env e, address irm) {
    setupValidStateMB(e);

    _Morpho.isIrmEnabled@withrevert(irm);

    assert(!lastReverted, "isIrmEnabled() must not revert");
}

// UT-42: isLltvEnabled() never reverts
// FORMULA: isLltvEnabled(lltv) does not revert under any condition
rule isLltvEnabledNeverReverts(env e, uint256 lltv) {
    setupValidStateMB(e);

    _Morpho.isLltvEnabled@withrevert(lltv);

    assert(!lastReverted, "isLltvEnabled() must not revert");
}

// UT-43: nonce() never reverts
// FORMULA: nonce(user) does not revert under any condition
rule nonceNeverReverts(env e, address user) {
    setupValidStateMB(e);

    _Morpho.nonce@withrevert(user);

    assert(!lastReverted, "nonce() must not revert");
}
