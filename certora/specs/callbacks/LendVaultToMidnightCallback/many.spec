// LendVaultToMidnightCallback: many-market, single make-on-behalf scenario.
import "../../setup/callbacks/LendVaultToMidnightCallback/many_setup.spec";

// generic callback guards (bodies in callbacks.spec)
use rule callbackHoldsZeroAllowance;              // CLB-01
use rule thirdPartyBalanceUnchanged;              // CLB-02
use rule callbackNeverHoldsTokens;                // CLB-03
use rule callbackRevertsForNonMidnightCaller;     // CLB-04
use rule callbackRevertsOnZeroAssetsOrUnits;      // CLB-05
use rule feeRecipientNeverLosesTokens;            // CLB-06
use rule buyerTickFeePaidBoundedByUnits;          // CLB-09
use rule positiveFeeIsPayable;                    // CLB-10

// CLB-LVM-01 (CB-SRC-1): vault-funded lend touches only loanToken; other non-vault tokens untouched.
// FORMULA: t != loanToken AND ERC4626asset[t] == 0 => balance[t][Midnight]' == balance[t][Midnight]
rule vaultFundedLendOnlyMovesLoanToken(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        address anyToken) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint balBefore = ghostERC20Balances128[anyToken][_Midnight];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint balAfter = ghostERC20Balances128[anyToken][_Midnight];

    assert(anyToken != offer.market.loanToken && ghostERC4626Asset[anyToken] == 0
        => balBefore == balAfter,
        "non-loan, non-vault token: Midnight balance untouched");
}

// CLB-LVM-02: vault-funded lend never touches collateral.
// FORMULA: collateral[id][u][i]' == collateral[id][u][i]
rule vaultFundedLendLeavesCollateralUnchanged(env e,
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
        "position collateral untouched by vault-funded lend");
}

// CLB-LVM-03: vault-funded lend can raise a lender's credit.
// FORMULA: satisfy(credit[id][u]' > credit[id][u])
rule vaultFundedLendCanRaiseCredit(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    mathint creditBefore = ghostMiPositionCredit128[anyMnId][anyUser];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    satisfy(ghostMiPositionCredit128[anyMnId][anyUser] > creditBefore,
        "vault-funded lend can actually raise a lender's credit");
}

// CLB-LVM-04 (CB-DIR-1): vault-funded lend never touches a bystander's credit or debt.
// FORMULA: u bystander => credit[id][u]' == credit[id][u] AND debt[id][u]' == debt[id][u]
rule vaultFundedLendNeverTouchesUnrelatedUser(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData,
        bytes32 anyMnId, address anyUser) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    bool bystander = anyUser != taker && anyUser != offer.maker;

    mathint creditBefore = ghostMiPositionCredit128[anyMnId][anyUser];
    mathint debtBefore   = ghostMiPositionDebt128[anyMnId][anyUser];

    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);

    assert(bystander =>
           (ghostMiPositionCredit128[anyMnId][anyUser] == creditBefore
        && ghostMiPositionDebt128[anyMnId][anyUser] == debtBefore),
        "bystander credit and debt untouched by vault-funded lend");
}

// CLB-LVM-05 (CB-RATE-2): the lender's callback overcharge (fee) never exceeds feeRate on the trade's
// interest portion, so the effective lender rate stays within (1 - feeRate/WAD) of the offer rate.
// FORMULA: f*WAD^2 <= units*(WAD - price)*feeRate (+ one-unit floor/mulDivDown rounding slack)
rule lenderFeeBoundedByInterestShare(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    callbackSetup(e, offer, units, taker, receiverIfTakerIsSeller,
                  takerCallback, takerCallbackData, ratifierData);

    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    address loanToken    = offer.market.loanToken;

    // feeRecipient is the sole sink of the callback fee on loanToken (mirror CLB-06 narrowings).
    address takeBuyer  = offer.buy ? offer.maker : taker;
    address takeSeller = offer.buy ? taker : offer.maker;
    require(feeRecipient != takeBuyer
         && feeRecipient != takeSeller
         && feeRecipient != offer.callback
         && feeRecipient != takerCallback
         && feeRecipient != _Midnight
         && feeRecipient != receiverIfTakerIsSeller
         && feeRecipient != offer.receiverIfMakerIsSeller,
        "TRUSTED: feeRecipient is neither a take participant/seller-proceeds receiver nor Midnight (isolates the fee on loanToken)");
    require(feeRecipient != e.msg.sender,
        "TRUSTED: feeRecipient != msg.sender (buyer-payment flow is orthogonal to fee accrual)");
    require(ghostERC4626Asset[feeRecipient] == 0,
        "TRUSTED: feeRecipient is not an ERC-4626 vault (not the source vault either)");
    requireFeeRecipientNarrowings(e, feeRecipient);

    mathint price   = tickToPriceGhost(offer.tick);   // price <= WAD under the tick model
    uint256 feeRate = _Callback.decodeCallbackFeeRate(e, offer.callbackData);   // active payload (takerCallback==0)

    mathint feeBefore = ghostERC20Balances128[loanToken][feeRecipient];
    take(e, offer, ratifierData, units, taker, receiverIfTakerIsSeller, takerCallback, takerCallbackData);
    mathint f = ghostERC20Balances128[loanToken][feeRecipient] - feeBefore;   // == buyerFeeFromTick(...)

    assert(f * WAD_CVL() * WAD_CVL()
             <= to_mathint(units) * (WAD_CVL() - price) * to_mathint(feeRate) + WAD_CVL() * WAD_CVL(),
        "lender callback fee bounded by feeRate * interest => effective rate >= (1-feeRate) * offer rate");
}

// CLB-LVM-06 (CB-FEE-4): at par (price==WAD) with full-value settlement (assets==units) the buyer tick
// fee vanishes -- carved from the interest component, not the principal.
// FORMULA: price==WAD && assets==units && !reverted => feeRecipient delta == 0
rule tickFeeVanishesAtPar(env e,
        MidnightHarness.Offer offer, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) {

    require(e.msg.sender == _Midnight, "PROVED: CLB-04 owns the non-Midnight-caller revert");

    uint256 tick = _Callback.decodeCallbackTick(e, data);
    require(VALID_TICK(tick) && ghostNumTicks == 5 && tick == ghostTickFive,
        "SAFE: par tick = top tick ghostTickFive -- only tick whose price can reach WAD under the monotone model (ghostTickOne<...<ghostTickFive<=WAD)");
    require(tickToPriceGhost(tick) == WAD_MATH(), "SCOPE: par tick -- zero discount (price == WAD)");
    require(to_mathint(assets) == to_mathint(units), "SCOPE: full-value settlement at par (no interest)");

    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    require(feeRecipient != _Callback && feeRecipient != _Midnight && feeRecipient != user,
        "TRUSTED: feeRecipient is isolated, so its loanToken delta equals the fee paid");
    require(ghostERC4626Asset[feeRecipient] == 0,
        "TRUSTED: feeRecipient is not an ERC-4626 vault (onBuy's vault.withdraw would move its loanToken, aliasing the fee delta) -- mirrors lenderFee/percentageFee");
    requireFeeRecipientNarrowings(e, feeRecipient);

    mathint feeBefore = ghostERC20Balances128[market.loanToken][feeRecipient];
    bool reverted = callbackCallWithRevert(e, id, market, assets, units, pendingFee, user, receiver, data);
    mathint feeAfter  = ghostERC20Balances128[market.loanToken][feeRecipient];

    assert(!reverted => feeAfter == feeBefore,
        "no tick fee at par with full-value settlement (fee is purely from interest)");}

// CLB-LVM-07 (CB-DUST-1, TokenMismatch): vault-funded onBuy rejects any vault whose asset() != market.loanToken.
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
