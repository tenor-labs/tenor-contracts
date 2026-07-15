// MidnightSupplyCollateralCallback (one-market): satisfy-witness twins of the take-based assert rules — each witnesses its parent's assert point reachable (run with rule_sanity:none).

import "../../../setup/callbacks/MidnightSupplyCollateralCallback/one_setup.spec";
import "../one.spec";

// CLB-MSC-03
rule proRataUpperBound__satisfy(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(VALID_COLLATERAL_BIT(anyIndex),
        "SAFE: collateral slot within the two-collateral narrowing");
    mathint amtI = decodeActiveAmount(e, offer, anyIndex);
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(true,
        "witness: proRataUpperBound assert-point reachable");
}

// CLB-MSC-04 (CB-SC-CAP-1)
rule borrowCapacityUsageWithinCap__satisfy(env e,
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

    satisfy(maxBCU > 0 && debtAfter > 0,
        "witness: borrowCapacityUsageWithinCap assert-point reachable");
}
