// BorrowMidnightToBlueCallback: many-market, single make-on-behalf scenario.
import "../../setup/callbacks/BorrowMidnightToBlueCallback/many_setup.spec";

// generic callback guards (bodies in callbacks.spec)
use rule callbackHoldsZeroAllowance;              // CLB-01
use rule thirdPartyBalanceUnchanged;              // CLB-02
use rule callbackNeverHoldsTokens;                // CLB-03
use rule callbackRevertsForNonMidnightCaller;     // CLB-04
use rule callbackRevertsOnZeroAssetsOrUnits;      // CLB-05
use rule percentageFeeNeverExceedsAssets;         // CLB-07
use rule positiveFeeIsPayable;                    // CLB-10

// CLB-BMB-01 (CB-DIR-1): old Midnight collateral only withdrawn, never added.
// FORMULA: mnCollateral[id][u][i]' <= mnCollateral[id][u][i]
rule migrationOnlyWithdrawsOldMidnightCollateral(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint colBefore = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint colAfter = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];

    assert(colAfter <= colBefore, "old Midnight collateral slot never grows");
}

// CLB-BMB-02 (CB-DIR-1): old debt drops on at most one market.
// FORMULA: NOT( mnDebt[idA][u]' < mnDebt[idA][u] AND mnDebt[idB][u]' < mnDebt[idB][u] )
// Mutation coverage: the permanent-revert satisfy twin only (no direct-CEX mutation can break this assert).
rule migrationReducesOldDebtOnAtMostOneMarket(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 idA, bytes32 idB, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(idA != idB, "SAFE: two distinct Midnight market ids");

    mathint aBefore = ghostMiPositionDebt128[idA][anyUser];
    mathint bBefore = ghostMiPositionDebt128[idB][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint aAfter = ghostMiPositionDebt128[idA][anyUser];
    mathint bAfter = ghostMiPositionDebt128[idB][anyUser];

    assert(!(aAfter < aBefore && bAfter < bBefore),
        "old debt cannot drop on two Midnight markets at once");
}

// CLB-BMB-03 (CB-DIR-1): new Blue debt only opens, never reduces.
// FORMULA: blueBorrowShares[id][u]' >= blueBorrowShares[id][u]
rule migrationOnlyOpensNewBlueDebt(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint sharesBefore = ghostMbBorrowShares128[anyBlueId][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint sharesAfter = ghostMbBorrowShares128[anyBlueId][anyUser];

    assert(sharesAfter >= sharesBefore, "new Blue borrow shares never shrink");
}

// CLB-BMB-04 (CB-DIR-1): new Blue collateral only added, never removed.
// FORMULA: blueCollateral[id][u]' >= blueCollateral[id][u]
rule migrationOnlyAddsNewBlueCollateral(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint colBefore = ghostMbCollateral128[anyBlueId][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint colAfter = ghostMbCollateral128[anyBlueId][anyUser];

    assert(colAfter >= colBefore, "new Blue collateral never shrinks");
}

// CLB-BMB-05 (CB-SRC-1): new collateral in bounded by old collateral out.
// FORMULA: mnColOut > 0 AND blueColIn > 0 => blueColIn <= mnColOut
// FORMULA:   (mnColOut = mnCollateral[id][u][i] - mnCollateral', blueColIn = blueCollateral' - blueCollateral)
rule migrationCannotDepositMoreCollateralThanWithdrawn(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint mnColBefore = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    mathint blueColBefore = ghostMbCollateral128[anyBlueId][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint mnColAfter = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    mathint blueColAfter = ghostMbCollateral128[anyBlueId][anyUser];

    assert(mnColAfter < mnColBefore && blueColAfter > blueColBefore
        => mnColBefore - mnColAfter >= blueColAfter - blueColBefore,
        "new Blue collateral inflow bounded by old Midnight collateral outflow");
}

// CLB-BMB-11 (CB-FINAL-3): final fill transfers ALL old Midnight collateral.
// FORMULA: mnCollateral[id][u][i] > mnCollateral[id][u][i]' AND mnDebt[id][u]' == 0
//          => mnCollateral[id][u][i]' == 0
rule migrationFinalFillTransfersAllOldMidnightCollateral(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint colBefore = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint colAfter  = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    mathint debtAfter = ghostMiPositionDebt128[anyMnId][anyUser];

    assert(colBefore > colAfter && debtAfter == 0 => colAfter == 0,
        "final fill drains the migrated source collateral slot completely");
}

// CLB-BMB-07: migration can open new Blue debt.
// FORMULA: satisfy(blueBorrowShares[id][u]' > blueBorrowShares[id][u])
rule migrationCanOpenNewBlueDebt(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint sharesBefore = ghostMbBorrowShares128[anyBlueId][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMbBorrowShares128[anyBlueId][anyUser] > sharesBefore,
        "migration can actually open Blue borrow shares");
}

// CLB-BMB-08: migration can move collateral Midnight->Blue.
// FORMULA: satisfy(mnCollateral[id][u][i]' < mnCollateral[id][u][i] AND blueCollateral[id][u]' > blueCollateral[id][u])
rule migrationCanMoveCollateralMidnightToBlue(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        MorphoHarness.Id anyBlueId, bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint mnColBefore = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    mathint blueColBefore = ghostMbCollateral128[anyBlueId][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint mnColAfter = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    mathint blueColAfter = ghostMbCollateral128[anyBlueId][anyUser];

    satisfy(mnColAfter < mnColBefore && blueColAfter > blueColBefore,
        "migration can actually move collateral Midnight->Blue");
}

// CLB-BMB-09 (CB-CLOSE-1): migration can fully close the old position.
// FORMULA: satisfy(mnDebt[id][u]' == 0 AND mnCollateral[id][u][i]' == 0)  (pre: both > 0)
rule migrationCanFullyCloseOldPosition(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);
    require(ghostMiPositionDebt128[anyMnId][anyUser] > 0,
        "SAFE: positive Midnight debt before");
    require(ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex] > 0,
        "SAFE: positive Midnight collateral before");

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMiPositionDebt128[anyMnId][anyUser] == 0
        && ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex] == 0,
        "old Midnight position can be fully closed");
}

// CLB-BMB-10 (CL-2, InvalidFeeConfig): a callback fee rate above the 1% cap (MAX_PERCENTAGE_FEE_RATE) is rejected by percentageFee.
// FORMULA: decodeCallbackFeeRate(data) > MAX_PERCENTAGE_FEE_RATE => REVERTS
rule percentageFeeRateAboveCapReverts(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    bool feeRateAboveCap = to_mathint(_Callback.decodeCallbackFeeRate(e, data)) > MAX_PERCENTAGE_FEE_RATE();

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(feeRateAboveCap => reverted,
        "a callback percentage fee rate above the 1% cap is rejected under any caller/inputs (InvalidFeeConfig)");
}
