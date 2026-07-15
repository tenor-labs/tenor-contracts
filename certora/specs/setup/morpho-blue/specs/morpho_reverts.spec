import "./morpho_valid_state.spec";

// ========== Revert Conditions ==========

// RV-01: isAuthorized() never reverts
// FORMULA: isAuthorized(a, b) does not revert under any condition
rule isAuthorizedNeverReverts(
    env e, address authorizer, address authorized
) {
    setupValidStateMB(e);

    _Morpho.isAuthorized@withrevert(authorizer, authorized);

    assert(!lastReverted, "isAuthorized() must not revert");
}

// RV-02: setOwner reverts when caller is not owner
// FORMULA: msg.sender != owner => setOwner reverts
rule setOwnerRevertsForNonOwner(env e, address newOwner) {
    setupValidStateMB(e);

    bool isNotOwner = e.msg.sender != ghostMbOwner;

    setOwner@withrevert(e, newOwner);
    bool reverted = lastReverted;

    assert(isNotOwner => reverted,
        "setOwner must revert when caller is not the owner");
}

// RV-03: setOwner reverts when newOwner equals current owner
// FORMULA: newOwner == owner => setOwner reverts
rule setOwnerRevertsWhenAlreadySet(env e, address newOwner) {
    setupValidStateMB(e);

    bool alreadySet = newOwner == ghostMbOwner;

    setOwner@withrevert(e, newOwner);
    bool reverted = lastReverted;

    assert(alreadySet => reverted,
        "setOwner must revert when newOwner equals current owner");
}

// RV-04: enableIrm reverts when caller is not owner
// FORMULA: msg.sender != owner => enableIrm reverts
rule enableIrmRevertsForNonOwner(env e, address irm) {
    setupValidStateMB(e);

    bool isNotOwner = e.msg.sender != ghostMbOwner;

    enableIrm@withrevert(e, irm);
    bool reverted = lastReverted;

    assert(isNotOwner => reverted,
        "enableIrm must revert when caller is not the owner");
}

// RV-05: enableIrm reverts when IRM already enabled
// FORMULA: isIrmEnabled[irm] => enableIrm reverts
rule enableIrmRevertsWhenAlreadyEnabled(env e, address irm) {
    setupValidStateMB(e);

    bool alreadyEnabled = ghostMbIsIrmEnabled[irm];

    enableIrm@withrevert(e, irm);
    bool reverted = lastReverted;

    assert(alreadyEnabled => reverted,
        "enableIrm must revert when IRM already enabled");
}

// RV-06: enableLltv reverts when caller is not owner
// FORMULA: msg.sender != owner => enableLltv reverts
rule enableLltvRevertsForNonOwner(env e, uint256 lltv) {
    setupValidStateMB(e);

    bool isNotOwner = e.msg.sender != ghostMbOwner;

    enableLltv@withrevert(e, lltv);
    bool reverted = lastReverted;

    assert(isNotOwner => reverted,
        "enableLltv must revert when caller is not the owner");
}

// RV-07: enableLltv reverts when LLTV already enabled
// FORMULA: isLltvEnabled[lltv] => enableLltv reverts
rule enableLltvRevertsWhenAlreadyEnabled(env e, uint256 lltv) {
    setupValidStateMB(e);

    bool alreadyEnabled = ghostMbIsLltvEnabled[lltv];

    enableLltv@withrevert(e, lltv);
    bool reverted = lastReverted;

    assert(alreadyEnabled => reverted,
        "enableLltv must revert when LLTV already enabled");
}

// RV-08: enableLltv reverts when LLTV >= WAD
// FORMULA: lltv >= WAD => enableLltv reverts
rule enableLltvRevertsWhenExceedsMax(env e, uint256 lltv) {
    setupValidStateMB(e);

    bool exceedsMax = to_mathint(lltv) >= MORPHO_WAD_CVL();

    enableLltv@withrevert(e, lltv);
    bool reverted = lastReverted;

    assert(exceedsMax => reverted,
        "enableLltv must revert when lltv >= WAD");
}

// RV-09: setFee reverts when caller is not owner
// FORMULA: msg.sender != owner => setFee reverts
rule setFeeRevertsForNonOwner(
    env e, MorphoHarness.MarketParams marketParams, uint256 newFee
) {
    setupValidStateMB(e);

    bool isNotOwner = e.msg.sender != ghostMbOwner;

    setFee@withrevert(e, marketParams, newFee);
    bool reverted = lastReverted;

    assert(isNotOwner => reverted,
        "setFee must revert when caller is not the owner");
}

// RV-10: setFee reverts when fee exceeds MAX_FEE
// FORMULA: newFee > MAX_FEE => setFee reverts
rule setFeeRevertsWhenExceedsMax(
    env e, MorphoHarness.MarketParams marketParams, uint256 newFee
) {
    setupValidStateMB(e);

    bool exceedsMax = to_mathint(newFee) > MAX_FEE_CVL();

    setFee@withrevert(e, marketParams, newFee);
    bool reverted = lastReverted;

    assert(exceedsMax => reverted,
        "setFee must revert when newFee exceeds MAX_FEE");
}

// RV-11: setFee reverts on non-existent market
// FORMULA: lastUpdate == 0 => setFee reverts
rule setFeeRevertsOnNonExistentMarket(
    env e, MorphoHarness.MarketParams marketParams, uint256 newFee
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    bool notCreated = ghostMbLastUpdate128[id] == 0;

    setFee@withrevert(e, marketParams, newFee);
    bool reverted = lastReverted;

    assert(notCreated => reverted,
        "setFee must revert when market does not exist");
}

// RV-12: setFeeRecipient reverts when caller is not owner
// FORMULA: msg.sender != owner => setFeeRecipient reverts
rule setFeeRecipientRevertsForNonOwner(env e, address newFeeRecipient) {
    setupValidStateMB(e);

    bool isNotOwner = e.msg.sender != ghostMbOwner;

    setFeeRecipient@withrevert(e, newFeeRecipient);
    bool reverted = lastReverted;

    assert(isNotOwner => reverted,
        "setFeeRecipient must revert when caller is not the owner");
}

// RV-13: setFeeRecipient reverts when already set
// FORMULA: newFeeRecipient == feeRecipient => setFeeRecipient reverts
rule setFeeRecipientRevertsWhenAlreadySet(env e, address newFeeRecipient) {
    setupValidStateMB(e);

    bool alreadySet = newFeeRecipient == ghostMbFeeRecipient;

    setFeeRecipient@withrevert(e, newFeeRecipient);
    bool reverted = lastReverted;

    assert(alreadySet => reverted,
        "setFeeRecipient must revert when newFeeRecipient is already set");
}

// RV-14: createMarket reverts when IRM not enabled
// FORMULA: !isIrmEnabled[mp.irm] => createMarket reverts
rule createMarketRevertsWhenIrmNotEnabled(
    env e, MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    bool irmNotEnabled = !ghostMbIsIrmEnabled[marketParams.irm];

    createMarket@withrevert(e, marketParams);
    bool reverted = lastReverted;

    assert(irmNotEnabled => reverted,
        "createMarket must revert when IRM is not enabled");
}

// RV-15: createMarket reverts when LLTV not enabled
// FORMULA: !isLltvEnabled[mp.lltv] => createMarket reverts
rule createMarketRevertsWhenLltvNotEnabled(
    env e, MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    bool lltvNotEnabled = !ghostMbIsLltvEnabled[marketParams.lltv];

    createMarket@withrevert(e, marketParams);
    bool reverted = lastReverted;

    assert(lltvNotEnabled => reverted,
        "createMarket must revert when LLTV is not enabled");
}

// RV-16: createMarket reverts when market already exists
// FORMULA: lastUpdate != 0 => createMarket reverts
rule createMarketRevertsWhenAlreadyCreated(
    env e, MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    bool alreadyCreated = ghostMbLastUpdate128[id] != 0;

    createMarket@withrevert(e, marketParams);
    bool reverted = lastReverted;

    assert(alreadyCreated => reverted,
        "createMarket must revert when market already exists");
}

// RV-17: supply reverts on non-existent market
// FORMULA: lastUpdate == 0 => supply reverts
rule supplyRevertsOnNonExistentMarket(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    bool notCreated = ghostMbLastUpdate128[id] == 0;

    supply@withrevert(e, marketParams, assets, shares, onBehalf, data);
    bool reverted = lastReverted;

    assert(notCreated => reverted,
        "supply must revert when market does not exist");
}

// RV-18: supply reverts when onBehalf is zero address
// FORMULA: onBehalf == 0 => supply reverts
rule supplyRevertsForZeroOnBehalf(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    bool zeroOnBehalf = onBehalf == 0;

    supply@withrevert(e, marketParams, assets, shares, onBehalf, data);
    bool reverted = lastReverted;

    assert(zeroOnBehalf => reverted,
        "supply must revert when onBehalf is zero address");
}

// RV-19: withdraw reverts when receiver is zero address
// FORMULA: receiver == 0 => withdraw reverts
rule withdrawRevertsForZeroReceiver(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    bool zeroReceiver = receiver == 0;

    withdraw@withrevert(e, marketParams, assets, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(zeroReceiver => reverted,
        "withdraw must revert when receiver is zero address");
}

// RV-20: withdraw reverts when sender is unauthorized
// FORMULA: sender != onBehalf && !isAuthorized[onBehalf][sender] => withdraw reverts
rule withdrawRevertsWhenUnauthorized(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    bool notSelf = e.msg.sender != onBehalf;
    bool notAuthorized = !ghostMbIsAuthorized[onBehalf][e.msg.sender];
    bool unauthorized = notSelf && notAuthorized;

    withdraw@withrevert(e, marketParams, assets, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(unauthorized => reverted,
        "withdraw must revert when sender is unauthorized");
}

// RV-21: borrow reverts when receiver is zero address
// FORMULA: receiver == 0 => borrow reverts
rule borrowRevertsForZeroReceiver(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    bool zeroReceiver = receiver == 0;

    borrow@withrevert(e, marketParams, assets, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(zeroReceiver => reverted,
        "borrow must revert when receiver is zero address");
}

// RV-22: borrow reverts when sender is unauthorized
// FORMULA: sender != onBehalf && !isAuthorized[onBehalf][sender] => borrow reverts
rule borrowRevertsWhenUnauthorized(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    bool notSelf = e.msg.sender != onBehalf;
    bool notAuthorized = !ghostMbIsAuthorized[onBehalf][e.msg.sender];
    bool unauthorized = notSelf && notAuthorized;

    borrow@withrevert(e, marketParams, assets, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(unauthorized => reverted,
        "borrow must revert when sender is unauthorized");
}

// RV-23: repay reverts when onBehalf is zero address
// FORMULA: onBehalf == 0 => repay reverts
rule repayRevertsForZeroOnBehalf(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    bool zeroOnBehalf = onBehalf == 0;

    repay@withrevert(e, marketParams, assets, shares, onBehalf, data);
    bool reverted = lastReverted;

    assert(zeroOnBehalf => reverted,
        "repay must revert when onBehalf is zero address");
}

// RV-24: supplyCollateral reverts when assets is zero
// FORMULA: assets == 0 => supplyCollateral reverts
rule supplyCollateralRevertsForZeroAssets(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    bool zeroAssets = assets == 0;

    supplyCollateral@withrevert(e, marketParams, assets, onBehalf, data);
    bool reverted = lastReverted;

    assert(zeroAssets => reverted,
        "supplyCollateral must revert when assets is zero");
}

// RV-25: supplyCollateral reverts when onBehalf is zero address
// FORMULA: onBehalf == 0 => supplyCollateral reverts
rule supplyCollateralRevertsForZeroOnBehalf(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    bytes data
) {
    setupValidStateMB(e);

    bool zeroOnBehalf = onBehalf == 0;

    supplyCollateral@withrevert(e, marketParams, assets, onBehalf, data);
    bool reverted = lastReverted;

    assert(zeroOnBehalf => reverted,
        "supplyCollateral must revert when onBehalf is zero address");
}

// RV-26: withdrawCollateral reverts when assets is zero
// FORMULA: assets == 0 => withdrawCollateral reverts
rule withdrawCollateralRevertsForZeroAssets(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    bool zeroAssets = assets == 0;

    withdrawCollateral@withrevert(e, marketParams, assets, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(zeroAssets => reverted,
        "withdrawCollateral must revert when assets is zero");
}

// RV-27: withdrawCollateral reverts when receiver is zero address
// FORMULA: receiver == 0 => withdrawCollateral reverts
rule withdrawCollateralRevertsForZeroReceiver(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    bool zeroReceiver = receiver == 0;

    withdrawCollateral@withrevert(e, marketParams, assets, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(zeroReceiver => reverted,
        "withdrawCollateral must revert when receiver is zero address");
}

// RV-28: withdrawCollateral reverts when sender is unauthorized
// FORMULA: sender != onBehalf && !isAuthorized[onBehalf][sender] => withdrawCollateral reverts
rule withdrawCollateralRevertsWhenUnauthorized(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 assets,
    address onBehalf,
    address receiver
) {
    setupValidStateMB(e);

    bool notSelf = e.msg.sender != onBehalf;
    bool notAuthorized = !ghostMbIsAuthorized[onBehalf][e.msg.sender];
    bool unauthorized = notSelf && notAuthorized;

    withdrawCollateral@withrevert(e, marketParams, assets, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(unauthorized => reverted,
        "withdrawCollateral must revert when sender is unauthorized");
}

// RV-29: setAuthorization reverts when value already set
// FORMULA: newIsAuthorized == isAuthorized[sender][authorized] => setAuthorization reverts
rule setAuthorizationRevertsWhenAlreadySet(
    env e, address authorized, bool newIsAuthorized
) {
    setupValidStateMB(e);

    bool alreadySet = newIsAuthorized == ghostMbIsAuthorized[e.msg.sender][authorized];

    setAuthorization@withrevert(e, authorized, newIsAuthorized);
    bool reverted = lastReverted;

    assert(alreadySet => reverted,
        "setAuthorization must revert when value is already set");
}

// RV-30: flashLoan reverts when assets is zero
// FORMULA: assets == 0 => flashLoan reverts
rule flashLoanRevertsForZeroAssets(
    env e, address token, uint256 assets, bytes data
) {
    setupValidStateMB(e);

    bool zeroAssets = assets == 0;

    flashLoan@withrevert(e, token, assets, data);
    bool reverted = lastReverted;

    assert(zeroAssets => reverted,
        "flashLoan must revert when assets is zero");
}

// RV-31: accrueInterest reverts on non-existent market
// FORMULA: lastUpdate == 0 => accrueInterest reverts
rule accrueInterestRevertsOnNonExistentMarket(
    env e, MorphoHarness.MarketParams marketParams
) {
    setupValidStateMB(e);

    MorphoHarness.Id id = _HelperCVL.marketId(e, marketParams);
    bool notCreated = ghostMbLastUpdate128[id] == 0;

    accrueInterest@withrevert(e, marketParams);
    bool reverted = lastReverted;

    assert(notCreated => reverted,
        "accrueInterest must revert when market does not exist");
}
