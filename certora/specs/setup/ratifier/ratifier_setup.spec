import "../constants.spec";

using MigrationRatifierHarness as _Ratifier;

methods {
    // lib/midnight TickLib (src/libraries/TickLib.sol).
    function TickLib.tickToPrice(uint256 tick) internal returns (uint256)
        => tickPriceGhost(tick);

    // Midnight (lib/midnight IMidnight.settlementFee / continuousFee). settlementFee is only consulted on the
    // taker leg (offer.maker != user); make-on-behalf (user == offer.maker) short-circuits it to 0.
    function _.settlementFee(bytes32 id, uint256 ttm) external
        => mySettlementFee(id, ttm) expect uint256;
    function _.continuousFee(bytes32 id) external
        => ghostContinuousFee[id] expect uint256;

    // Morpho Midnight isAuthorized — the authorization authority for setParams/clearParams (IMidnight.isAuthorized).
    function _.isAuthorized(address authorizer, address authorized) external
        => ghostMnIsAuthorized[authorizer][authorized] expect bool;

    // IInterestRatePolicy (src/ratifiers/interfaces/IInterestRatePolicy.sol).
    // Recording summary: captures the forwarded `user` principal (RTF-HL-07), value unchanged.
    function _.getRate(bytes32 a, bytes32 b, uint256 c, address user, address taker,
        uint256 g, uint256 h, bool i) external
            => recordGetRate(a, b, c, user, taker, g, h, i) expect uint256;

    // IRenewalCadence (src/ratifiers/interfaces/IRenewalCadence.sol).
    function _.cadencePeriodStart(uint256 t) external
        => ghostCadencePeriodStart[t] expect uint256;

    // TenorMarketIdLib.toTenorMarketId (src/libraries/TenorMarketIdLib.sol): summarize the dynamic-array keccak
    // as a deterministic ghost of the maturity-excluded scalars; collateralParams dropped (id_lib.spec convention, no collision-resistance axiom).
    function TenorMarketIdLib.toTenorMarketId(MigrationRatifierHarness.Market memory market)
        internal returns (bytes32) => toTenorMarketIdCVL(market);

    // IdLib.toId (lib/midnight/src/libraries/IdLib.sol): the other dynamic-array keccak on the ratifier path;
    // summarize it too, else removing the hashing flags leaves this hash uncovered.
    function IdLib.toId(MigrationRatifierHarness.Market memory market)
        internal returns (bytes32) => idLibToIdCVL(market);
}

definition EXCLUDED_FUNCTION(method f) returns bool = !f.isView && !f.isPure;

persistent ghost tickPriceGhost(uint256) returns uint256 {
    axiom forall uint256 t. tickPriceGhost(t) <= 10^18;
    axiom forall uint256 t1. forall uint256 t2.
        t1 <= t2 => tickPriceGhost(t1) <= tickPriceGhost(t2);
}

persistent ghost mapping(address => mapping(address => bool)) ghostMnIsAuthorized {
    init_state axiom forall address a. forall address b. ghostMnIsAuthorized[a][b] == false;
}

persistent ghost mySettlementFee(bytes32, uint256) returns uint256 {
    axiom forall bytes32 id. forall uint256 ttm. mySettlementFee(id, ttm) <= 10^18;
}

persistent ghost mapping(bytes32 => uint256) ghostContinuousFee {
    axiom forall bytes32 id. ghostContinuousFee[id] <= max_uint32;
}

// UNSAFE: the wildcard summary caps any policy's rate at 2^128 (the canonical policy's uint128 range).
persistent ghost myGetRate(bytes32, bytes32, uint256, address, address, uint256, uint256, bool) returns uint256 {
    axiom forall bytes32 a. forall bytes32 b. forall uint256 c. forall address user. forall address taker.
        forall uint256 g. forall uint256 h. forall bool i.
            myGetRate(a, b, c, user, taker, g, h, i) <= 2^128;
}

// Recorder for the getRate `user` arg (RTF-HL-07): persistent so the value written during the call survives.
persistent ghost address gGetRateUserArg;

function recordGetRate(bytes32 a, bytes32 b, uint256 c, address user, address taker,
        uint256 g, uint256 h, bool i) returns uint256 {
    gGetRateUserArg = user;
    return myGetRate(a, b, c, user, taker, g, h, i);
}

persistent ghost mapping(uint256 => uint256) ghostCadencePeriodStart;

function setupEnv(env e) {
    require(e.msg.value == 0, "SAFE: no ETH");
    require(e.msg.sender != 0 && e.msg.sender != currentContract, "SAFE: valid sender");
    require(e.block.timestamp >= max_uint16 && e.block.timestamp < max_uint32,
        "SAFE: realistic timestamp bounds");
    require(e.block.number != 0, "SAFE: non-zero block");
}

function setupMigrationRatifier(env e) {

    setupEnv(e);

    address bmr = _Ratifier.BORROW_MIDNIGHT_RENEWAL_CALLBACK;
    address bb  = _Ratifier.BORROW_BLUE_TO_MIDNIGHT_CALLBACK;
    address lv  = _Ratifier.LEND_VAULT_TO_MIDNIGHT_CALLBACK;
    address bm  = _Ratifier.BORROW_MIDNIGHT_TO_BLUE_CALLBACK;
    address lmv = _Ratifier.LEND_MIDNIGHT_TO_VAULT_CALLBACK;
    address lmr = _Ratifier.LEND_MIDNIGHT_RENEWAL_CALLBACK;

    require(bmr != bb  && bmr != lv  && bmr != bm  && bmr != lmv && bmr != lmr
         && bb  != lv  && bb  != bm  && bb  != lmv && bb  != lmr
         && lv  != bm  && lv  != lmv && lv  != lmr
         && bm  != lmv && bm  != lmr
         && lmv != lmr,
        "SAFE: 6 callback immutables are pairwise distinct");
}

// True for the two V2→V1 exit callbacks (BMB / LMV): source is a live Midnight market, target is V1.
function isV2ToV1(address callback) returns bool {
    return callback == _Ratifier.BORROW_MIDNIGHT_TO_BLUE_CALLBACK
        || callback == _Ratifier.LEND_MIDNIGHT_TO_VAULT_CALLBACK;
}

// True for the two V1→V2 enter callbacks (BBM / LVM): source is V1, target is a Midnight market (sourceMaturity==0).
function isV1ToV2(address callback) returns bool {
    return callback == _Ratifier.BORROW_BLUE_TO_MIDNIGHT_CALLBACK
        || callback == _Ratifier.LEND_VAULT_TO_MIDNIGHT_CALLBACK;
}

// True for the two V2→V2 renewal callbacks (BMR / LMR): both source and target are live Midnight markets.
function isV2ToV2(address callback) returns bool {
    return callback == _Ratifier.BORROW_MIDNIGHT_RENEWAL_CALLBACK
        || callback == _Ratifier.LEND_MIDNIGHT_RENEWAL_CALLBACK;
}

// Two param structs that agree on everything except the renewal window.
function paramsDifferOnlyInRenewalWindow(IMigrationRatifier.UserMigrationParams p1,
        IMigrationRatifier.UserMigrationParams p2) returns bool {
    return p1.interestRatePolicy == p2.interestRatePolicy && p1.limitRatePerSecond == p2.limitRatePerSecond
        && p1.minDuration == p2.minDuration && p1.maxDuration == p2.maxDuration
        && p1.renewalCadence == p2.renewalCadence;
}

// Two param structs that agree on everything except the renewal cadence.
function paramsDifferOnlyInRenewalCadence(IMigrationRatifier.UserMigrationParams p1,
        IMigrationRatifier.UserMigrationParams p2) returns bool {
    return p1.interestRatePolicy == p2.interestRatePolicy && p1.limitRatePerSecond == p2.limitRatePerSecond
        && p1.renewalWindow == p2.renewalWindow
        && p1.minDuration == p2.minDuration && p1.maxDuration == p2.maxDuration;
}

// === Market-id hashing summaries (replace the two dynamic-array keccak sites on the ratifier path) ===

// Backing ghost for the toTenorMarketId summary above: deterministic id over the maturity-excluded scalars.
persistent ghost tenorMarketIdGhost(uint256 /*chainId*/, address /*midnight*/, address /*loanToken*/,
    uint256 /*rcfThreshold*/, address /*enterGate*/, address /*liquidatorGate*/) returns bytes32;

function toTenorMarketIdCVL(MigrationRatifierHarness.Market market) returns bytes32 {
    return tenorMarketIdGhost(market.chainId, market.midnight, market.loanToken,
        market.rcfThreshold, market.enterGate, market.liquidatorGate);
}

// Midnight market id (IdLib.toId): maturity-INCLUSIVE deterministic ghost, disjoint from the Tenor id ghost above.
persistent ghost idLibToIdGhost(uint256 /*chainId*/, address /*midnight*/, address /*loanToken*/,
    uint256 /*maturity*/, uint256 /*rcfThreshold*/, address /*enterGate*/, address /*liquidatorGate*/) returns bytes32;

function idLibToIdCVL(MigrationRatifierHarness.Market market) returns bytes32 {
    return idLibToIdGhost(market.chainId, market.midnight, market.loanToken,
        market.maturity, market.rcfThreshold, market.enterGate, market.liquidatorGate);
}
