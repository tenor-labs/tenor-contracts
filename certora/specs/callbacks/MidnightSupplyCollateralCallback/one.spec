// MidnightSupplyCollateralCallback: one-market, single make-on-behalf scenario: borrow-capacity usage + pro-rata.

import "../../setup/callbacks/MidnightSupplyCollateralCallback/one_setup.spec";


// CLB-MSC-03: partial fill never supplies more than the configured per-slot amount.
// FORMULA: collateral[seller][i]' - collateral[seller][i] <= amounts[i]   (supply_i = mulDivDown(amounts[i], fill, cap), fill <= cap)
rule proRataUpperBound(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(VALID_COLLATERAL_BIT(anyIndex),
        "SAFE: collateral slot within the two-collateral narrowing");

    address seller = offer.buy ? taker : offer.maker;
    mathint amtI = decodeActiveAmount(e, offer, anyIndex);

    mathint collateralBefore = ghostMiOnePositionCollateral128[seller][anyIndex];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint collateralAfter = ghostMiOnePositionCollateral128[seller][anyIndex];

    assert(collateralAfter - collateralBefore <= amtI,
        "per-slot supplied collateral never exceeds the configured amount");
}

// CLB-MSC-04 (CB-SC-CAP-1): post-supply borrow-capacity usage stays within maxBorrowCapacityUsage.
// NOTE: capacity = lltv-weighted (isHealthy ratio, not raw LTV); guard ceil(debt'*WAD/capacity')<=maxBCU <=> debt'*WAD<=maxBCU*capacity'.
// FORMULA: maxBCU > 0 AND debt' > 0 => debt'*WAD <= maxBCU*capacity'  (capacity' = mulDivDown(mulDivDown(col0',price0,ORACLE_PRICE_SCALE),lltv0,WAD))
rule borrowCapacityUsageWithinCap(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(ghostNumCollaterals == 1,
        "UNSAFE: single collateral slot; one-term capacity fully exercises the borrow-capacity loop");

    address seller = offer.buy ? taker : offer.maker;
    uint256 maxBCU = decodeActiveMaxBorrowCapacityUsage(e, offer);
    mathint price0 = ghostMiOraclePrice256[offer.market.collateralParams[0].oracle];
    mathint lltv0  = offer.market.collateralParams[0].lltv;

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    mathint debtAfter = ghostMiOnePositionDebt128[seller];
    mathint col0After = ghostMiOnePositionCollateral128[seller][0];
    mathint capAfter = ((col0After * price0) / ORACLE_PRICE_SCALE_CVL()) * lltv0 / WAD_CVL();

    assert(maxBCU > 0 && debtAfter > 0
        => debtAfter * WAD_CVL() <= to_mathint(maxBCU) * capAfter,
        "post-supply borrow-capacity usage stays within the caller's maxBorrowCapacityUsage (InvalidBorrowCapacityUsage guard)");
}

// CLB-MSC-05 (CB-SC-CAP-1 liveness): a maxBorrowCapacityUsage-guarded fill can succeed with rising collateral and live debt.
// FORMULA: satisfy(maxBCU > 0 AND collateral[seller][0]' > collateral[seller][0] AND debt[seller]' > 0)
rule maxBorrowCapacityUsageFillReachable(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(ghostNumCollaterals == 1,
        "UNSAFE: single collateral slot");

    address seller = offer.buy ? taker : offer.maker;
    require(decodeActiveMaxBorrowCapacityUsage(e, offer) > 0,
        "SCOPE: a zero maxBorrowCapacityUsage would otherwise skip the capacity-usage check branch");

    mathint col0Before = ghostMiOnePositionCollateral128[seller][0];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMiOnePositionCollateral128[seller][0] > col0Before
         && ghostMiOnePositionDebt128[seller] > 0,
        "a maxBorrowCapacityUsage-guarded supply fill can succeed with rising collateral and outstanding debt");
}

// CLB-MSC-06: a supply fill can raise the borrower's collateral.
// FORMULA: satisfy(collateral[seller][0]' > collateral[seller][0])
rule supplyCanRaiseCollateral(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    address seller = offer.buy ? taker : offer.maker;
    mathint col0Before = ghostMiOnePositionCollateral128[seller][0];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMiOnePositionCollateral128[seller][0] > col0Before,
        "the supply path can raise the borrower's collateral");
}
