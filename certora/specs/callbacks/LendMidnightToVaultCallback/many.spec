// LendMidnightToVaultCallback: many-market, single make-on-behalf scenario.
import "../../setup/callbacks/LendMidnightToVaultCallback/many_setup.spec";

// generic callback guards (bodies in callbacks.spec)
use rule callbackHoldsZeroAllowance;              // CLB-01
use rule thirdPartyBalanceUnchanged;              // CLB-02
use rule callbackNeverHoldsTokens;                // CLB-03
use rule callbackRevertsForNonMidnightCaller;     // CLB-04
use rule callbackRevertsOnZeroAssetsOrUnits;      // CLB-05
use rule feeRecipientNeverLosesTokens;            // CLB-06
use rule percentageFeeNeverExceedsAssets;         // CLB-07
use rule positiveFeeIsPayable;                    // CLB-10

// CLB-LMV-01 (CB-SRC-1): vault exit moves a non-vault, non-loanToken balance only by the fee.
// FORMULA: t != loanToken AND ERC4626asset[t] == 0
// FORMULA:   => delta(balance[t][Midnight]) == delta(claimableSettlementFee[t])
rule vaultExitConservesMidnightBalanceMinusFee(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyToken) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    require(anyToken != offer.market.loanToken,
        "SAFE: loanToken excluded -- it is the asset the take settles, so Midnight's loanToken balance is not a fee-only quantity; the equality is proven for every other token");

    mathint balBefore = ghostERC20Balances128[anyToken][_Midnight];
    mathint feeBefore = ghostMiClaimableSettlementFee256[anyToken];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint balAfter = ghostERC20Balances128[anyToken][_Midnight];
    mathint feeAfter = ghostMiClaimableSettlementFee256[anyToken];

    assert(ghostERC4626Asset[anyToken] == 0
        => balAfter - balBefore == feeAfter - feeBefore,
        "Midnight balance delta equals trading-fee delta (non-vault token)");
}

// CLB-LMV-02: exiting a credit position into a vault never touches anyone's collateral.
// FORMULA: collateral[id][u][i]' == collateral[id][u][i]
rule vaultExitLeavesCollateralUnchanged(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser, uint256 anyIndex) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint collateralBefore = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint collateralAfter = ghostMiPositionCollateral128[anyMnId][anyUser][anyIndex];

    assert(collateralAfter == collateralBefore,
        "position collateral untouched by vault exit");
}

// CLB-LMV-03 (CB-DIR-1): a vault exit never touches the credit or debt of an unrelated user.
// FORMULA: u bystander => credit[id][u]' == credit[id][u] AND debt[id][u]' == debt[id][u]
rule vaultExitNeverTouchesUnrelatedUser(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    bool bystander = anyUser != taker && anyUser != offer.maker;

    mathint creditBefore = ghostMiPositionCredit128[anyMnId][anyUser];
    mathint debtBefore = ghostMiPositionDebt128[anyMnId][anyUser];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(bystander =>
           (ghostMiPositionCredit128[anyMnId][anyUser] == creditBefore
        && ghostMiPositionDebt128[anyMnId][anyUser] == debtBefore),
        "bystander credit and debt untouched by vault exit");
}

// CLB-LMV-04 (CB-CLOSE-1): vault exit can fully close a lender's source credit.
// FORMULA: satisfy(credit[id][u]' == 0)  (pre: credit[id][u] > 0)
rule vaultExitCanFullyCloseCredit(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint creditBefore = ghostMiPositionCredit128[anyMnId][anyUser];
    require(creditBefore > 0, "SCOPE: source has credit to close");
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMiPositionCredit128[anyMnId][anyUser] == 0,
        "vault exit can fully close a lender's source credit");
}

// CLB-LMV-05 (CB-DUST-1, InvalidReceiver): vault-exit onSell rejects any receiver other than the callback itself.
// FORMULA: receiver != address(callback) => REVERTS
rule receiverNotCallbackReverts(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    bool receiverNotCallback = receiver != _Callback;

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(receiverNotCallback => reverted,
        "callback unconditionally rejects receiver != address(this) (InvalidReceiver)");
}

// CLB-LMV-06 (CB-DUST-1, TokenMismatch): vault-exit onSell rejects any vault whose asset() != market.loanToken.
// FORMULA: vault.asset() != loanToken => REVERTS
rule vaultAssetMismatchReverts(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    address vault = _Callback.decodeCallbackVault(e, data);
    bool assetMismatch = ghostERC4626Asset[vault] != market.loanToken;

    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);

    assert(assetMismatch => reverted,
        "callback unconditionally rejects a vault whose asset() != loanToken (TokenMismatch)");
}
