import "../erc4626_asset.spec";
import "../safe_erc20.spec";

methods {
    function _.collateral(bytes32 id, address user, uint256 index) external
        => DISPATCHER(true);
    function _.debt(bytes32 id, address user) external => DISPATCHER(true);
    function _.updatePositionView(MidnightHarness.Market market, bytes32 id,
        address user) external => DISPATCHER(true);
    function _.withdraw(MidnightHarness.Market market, uint256 units,
        address onBehalf, address receiver) external => DISPATCHER(true);
    function _.repay(MidnightHarness.Market market, uint256 units, address onBehalf,
        address callback, bytes data) external => DISPATCHER(true);
    function _.supplyCollateral(MidnightHarness.Market market, uint256 collateralIndex,
        uint256 assets, address onBehalf) external => DISPATCHER(true);
    function _.withdrawCollateral(MidnightHarness.Market market, uint256 collateralIndex,
        uint256 assets, address onBehalf, address receiver) external => DISPATCHER(true);
}

definition MAX_FEE_RATE() returns mathint = 500000000000000000;
// MAX_PERCENTAGE_FEE_RATE = 1% cap (BMB, LMV)
definition MAX_PERCENTAGE_FEE_RATE() returns mathint = 10000000000000000;

function callbackSetup(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    setupCallbackEnv(e, offer, taker);
    setupCallbackState(e);
    setupMigrationRatifier(e, offer, units, taker, receiverIfTakerIsSeller,
                           takerCallback, takerCallbackData, ratifierData);

    require(e.msg.sender != _Callback, "SAFE: msg.sender is a real account, distinct from the callback contract");
    require(e.msg.sender != _Midnight, "SAFE: msg.sender is a real account, distinct from the Midnight contract");
}

function setupCallbackEnv(env e,
        MidnightHarness.Offer offer, address taker) {

    require(_Callback != _Midnight, "SAFE: callback and Midnight are distinct deployed addresses");

    require(ghostMiPositionUserOne   != _Callback, "SAFE: a tracked Midnight position user is a real account, distinct from the callback contract");
    require(ghostMiPositionUserTwo   != _Callback, "SAFE: a tracked Midnight position user is a real account, distinct from the callback contract");
    require(ghostMiPositionUserThree != _Callback, "SAFE: a tracked Midnight position user is a real account, distinct from the callback contract");

    require(offer.maker != _Callback, "SAFE: offer maker is a real account, distinct from the callback contract");
    require(offer.maker != _Midnight, "SAFE: offer maker is a real account, distinct from the Midnight contract");
    require(taker       != _Callback, "SAFE: taker is a real account, distinct from the callback contract");
    require(taker       != _Midnight, "SAFE: taker is a real account, distinct from the Midnight contract");
}
