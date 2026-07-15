// Common base for Midnight setup -- imports primitives, declares ghost storage mirrors, summarizes touchMarket.

import "env.spec";
import "erc20/erc20.spec";
import "erc20/safe_transfer_lib.spec";
import "oracle.spec";
import "gates.spec";
import "ratifier.spec";
import "id_lib.spec";
import "utils_lib.spec";
import "tick_lib.spec";

using MidnightHarness as _Midnight;

methods {
    // multicall: unbounded delegatecall loop; individual call paths covered by direct method calls.
    function MidnightHarness.multicall(bytes[]) external => NONDET DELETE;
}

// The touchMarket summary lives in touch_market_summary.spec (imported by the one-/many-regime
// setups), NOT here. touchMarket is PUBLIC, so an `internal` summary also
// intercepts the external ABI entry (the wrapper calls the summarized internal implementation) —
// market CREATION is dead code in every conf that loads the summary. Creation is verified in its
// own conf (market_creation.conf -> midnight_market_creation.spec), which imports this base file
// directly and never loads the summary.

definition EXCLUDED_FUNCTION(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    ;

definition WAD_CVL() returns mathint = 1000000000000000000; // 1e18
definition CBP_CVL() returns mathint = 1000000000000;       // 1e12 (centi-basis-point)
// 1e16 / (365 * 86400) — matches Solidity `uint32(uint256(0.01e18) / uint256(365 days))`.
// A 365.25-day year is off by 210534 and produces fake refutations on
// setDefaultContinuousFee / setMarketContinuousFee.
definition MAX_CONTINUOUS_FEE_CVL() returns mathint = 317097919;
definition MAX_COLLATERALS_CVL() returns mathint = 128;
// 0.999e18 — the MaxLifTooHigh creation gate ceiling on lltv*maxLif (src/Midnight.sol).
definition MAXLIF_LLTV_PRODUCT_CAP_CVL() returns mathint = 999000000000000000;

// maxSettlementFee(i) / CBP — per-index stored upper bound. Source: src/libraries/ConstantsLib.sol.
definition MAX_SETTLEMENT_FEE_STORED_0() returns mathint = 14;
definition MAX_SETTLEMENT_FEE_STORED_1() returns mathint = 14;
definition MAX_SETTLEMENT_FEE_STORED_2() returns mathint = 98;
definition MAX_SETTLEMENT_FEE_STORED_3() returns mathint = 417;
definition MAX_SETTLEMENT_FEE_STORED_4() returns mathint = 1250;
definition MAX_SETTLEMENT_FEE_STORED_5() returns mathint = 2500;
definition MAX_SETTLEMENT_FEE_STORED_6() returns mathint = 5000;

// chainId/midnight are now struct fields of Market (3836155): toId derives the id purely from the
// struct, and both the harness toId wrapper and touchMarketCVL call the same idLibToIdCVL, so the
// SAME Market struct always maps to the SAME id within a rule — no stand-in ghost link needed.

// Many-mode flag — set by `setupManyMidnight`. Lets touchMarketCVL apply
// many-mode-specific narrowings (currently: no token aliasing between loanToken
// and any collateralToken). Stays false under one-mode (where the joint form
// of VS-MI-13 already covers the aliasing case via the collateral sum term).
persistent ghost bool ghostMiManyModeActive {
    init_state axiom ghostMiManyModeActive == false;
}

// Mirror of ConstantsLib.maxLif. Callers ensure lltv <= WAD and cursor < WAD first (touchMarket's
// creation gate / setup premise), so subtractions stay non-negative and mulDivDownCVL divisors are
// non-zero.
function maxLifCVL(uint256 lltv, uint256 cursor) returns uint256 {
    uint256 wad = require_uint256(WAD_CVL());
    uint256 inner = mulDivDownCVL(cursor, require_uint256(to_mathint(wad) - to_mathint(lltv)), wad);
    return mulDivDownCVL(wad, wad, require_uint256(to_mathint(wad) - to_mathint(inner)));
}

// Numeric consequences of touchMarket's per-collateral creation gates (src/Midnight.sol):
//   isLltvEnabled[lltv]                         => lltv <= WAD          (enableLltv: lltv <= WAD)
//   isLiquidationCursorEnabled[liquidationCursor] => liquidationCursor < WAD (enableLiquidationCursor)
//   maxLif(lltv, cursor) <= 2*WAD                                       (InvalidMaxLif)
//   lltv == WAD || lltv*maxLif <= 0.999e18*WAD                         (MaxLifTooHigh)
// LLTV tiers and cursors are now governance-enabled at runtime (no fixed set), so a created market's
// params are modeled by these bounds — exactly what the HL rules rely on (well-defined maxLifCVL,
// and a positive RCF denominator WAD^2 - lif*lltv since lltv*maxLif <= 0.999e18*WAD when lltv < WAD).
function validCollateralParamsCVL(uint256 lltv, uint256 cursor) returns bool {
    uint256 wad = require_uint256(WAD_CVL());
    if (lltv > wad) return false;
    if (cursor >= wad) return false;
    uint256 ml = maxLifCVL(lltv, cursor);
    if (to_mathint(ml) > 2 * WAD_CVL()) return false;
    if (lltv != wad && to_mathint(lltv) * to_mathint(ml) > MAXLIF_LLTV_PRODUCT_CAP_CVL() * WAD_CVL())
        return false;
    return true;
}

// Summary for internal touchMarket call sites. A market is "touched" iff
// marketState[id].tickSpacing > 0; the summary models only already-touched
// markets, so the external touchMarket entry verifies creation directly.
function touchMarketCVL(env e, MidnightHarness.Market market) returns bytes32 {
    bytes32 id = idLibToIdCVL(e, market);

    require(ghostMiMarketTickSpacing[id] > 0,
        "UNSAFE: touchMarket summary models only already-touched markets");

    // Captured for one-market regime to pin market→loanToken mapping.
    // Harmless in many-market regime (ghost written but unused).
    require(ghostMiMarketLoanToken[id] == 0
         || ghostMiMarketLoanToken[id] == market.loanToken,
        "UNSAFE: loanToken stable across touchMarket calls for the same id");
    ghostMiMarketLoanToken[id] = market.loanToken;

    // Scalar mirror consumed by one-market regime. Single-id consistency is
    // enforced by Sload mirror checks on other per-market slots; we only need
    // the stability check here. Harmless in many-market regime (unused).
    require(ghostMiOneMarketLoanToken == 0
         || ghostMiOneMarketLoanToken == market.loanToken,
        "UNSAFE: scalar loanToken stable across touchMarket calls");
    ghostMiOneMarketLoanToken = market.loanToken;

    require(market.collateralParams.length > 0,
        "SAFE: touched market has collateralParams (NoCollateralParams)");
    require(to_mathint(market.collateralParams.length) <= ghostNumCollaterals,
        "UNSAFE: collateralParams.length <= ghostNumCollaterals (two-collateral model)");

    // Index 0 is always present (length > 0); previousCollateralToken == 0
    // reduces `token[0] > previousCollateralToken` to `token[0] != 0`.
    require(market.collateralParams[0].token != 0,
        "SAFE: collateralParams sorted — token[0] != 0 (CollateralParamsNotSorted)");
    // Many-mode no-aliasing: every touched market has loanToken disjoint from
    // each of its collateral tokens. In one-mode the joint form of VS-MI-13
    // covers aliasing via its COLLATERAL_SUM_FOR_LOANTOKEN_ONE term, so the
    // flag stays false there and this require is vacuous.
    require(!ghostMiManyModeActive
         || market.collateralParams[0].token != market.loanToken,
        "UNSAFE: many-mode no-aliasing (collateralParams[0].token != loanToken)");
    require(validCollateralParamsCVL(market.collateralParams[0].lltv,
            market.collateralParams[0].liquidationCursor),
        "SAFE: collateralParams[0] enabled lltv/cursor with valid maxLif (creation gates)");

    // Scalar slot→token capture consumed by VS-MI-14 collateralBackedByBalance.
    // Stability require pins each slot to a fixed token across all touches.
    require(ghostMiOneCollateralToken[0] == 0
         || ghostMiOneCollateralToken[0] == market.collateralParams[0].token,
        "UNSAFE: scalar collateralToken[0] stable across touchMarket calls");
    ghostMiOneCollateralToken[0] = market.collateralParams[0].token;

    // Per-id slot→token capture consumed by many-market collateral sums.
    require(ghostMiMarketCollateralToken[id][0] == 0
         || ghostMiMarketCollateralToken[id][0] == market.collateralParams[0].token,
        "UNSAFE: per-id collateralToken[0] stable across touchMarket calls");
    ghostMiMarketCollateralToken[id][0] = market.collateralParams[0].token;

    if (market.collateralParams.length > 1) {
        require(market.collateralParams[1].token > market.collateralParams[0].token,
            "SAFE: collateralParams sorted — token[1] > token[0] (CollateralParamsNotSorted)");
        require(!ghostMiManyModeActive
             || market.collateralParams[1].token != market.loanToken,
            "UNSAFE: many-mode no-aliasing (collateralParams[1].token != loanToken)");
        require(validCollateralParamsCVL(market.collateralParams[1].lltv,
                market.collateralParams[1].liquidationCursor),
            "SAFE: collateralParams[1] enabled lltv/cursor with valid maxLif (creation gates)");

        require(ghostMiOneCollateralToken[1] == 0
             || ghostMiOneCollateralToken[1] == market.collateralParams[1].token,
            "UNSAFE: scalar collateralToken[1] stable across touchMarket calls");
        ghostMiOneCollateralToken[1] = market.collateralParams[1].token;

        require(ghostMiMarketCollateralToken[id][1] == 0
             || ghostMiMarketCollateralToken[id][1] == market.collateralParams[1].token,
            "UNSAFE: per-id collateralToken[1] stable across touchMarket calls");
        ghostMiMarketCollateralToken[id][1] = market.collateralParams[1].token;
    }

    return id;
}

// Base setup. Per-market specifics (per-id ghost narrowing, position/collateral
// zeroing) live in midnight_one.spec / midnight_many.spec.
function setupMidnight(env e) {
    setupMidnightWithLock(e, true);
}

// pinLiquidationLock == false is the ST-MI-13 regime: the transient lock is left
// free at entry so the liquidate guard (src L621) is actually exercised. Every
// other caller goes through setupMidnight(e) and keeps the fresh-tx pin.
function setupMidnightWithLock(env e, bool pinLiquidationLock) {
    setupEnv(e);
    setupERC20();
    setupOracle();

    // Constructor body is NONDET DELETE'd; without this require, the init_state
    // axiom admits configurator == 0 — unrealistic and vacuously breaks invariants.
    require(ghostMiConfigurator != 0,
        "TRUSTED: configurator set in constructor");

    require(ghostMiConfigurator != _Midnight,
        "TRUSTED: configurator != _Midnight");

    require(ghostMiFeeSetter != _Midnight,
        "TRUSTED: feeSetter != _Midnight");

    require(ghostMiFeeClaimer != _Midnight,
        "TRUSTED: feeClaimer != _Midnight");

    // Note: "Midnight never self-approves" is encoded as VS-MI-16
    // `noSelfApprove` (an invariant), not a TRUSTED setup require. The
    // invariant is asserted in pre-state via `requireInvariant noSelfApprove(e)`
    // in `setupValidStateOneMidnight` and proved by the parametric run.

    // tstore'd values do not persist across transactions.
    if (pinLiquidationLock) {
        require(forall bytes32 _id. forall address _u. !ghostMiLiquidationLock[_id][_u],
            "SAFE: transient liquidation lock starts unlocked");
    }

    require(forall bytes32 _id.
        ghostMiMarketCollateralParamsLength[_id] == 0
        || ghostMiMarketCollateralParamsLength[_id] == ghostNumCollaterals,
        "UNSAFE: market.collateralParams.length matches ghostNumCollaterals");
}

// Three-user narrowing for position[id][user]: minimum set covering take's two
// distinct positions plus one bystander. Pattern mirrors ghostTick* in tick_lib.spec.
persistent ghost address ghostMiPositionUserOne {
    axiom ghostMiPositionUserOne != 0;
}
persistent ghost address ghostMiPositionUserTwo {
    axiom ghostMiPositionUserTwo != 0;
    axiom ghostMiPositionUserOne != ghostMiPositionUserTwo;
}
persistent ghost address ghostMiPositionUserThree {
    axiom ghostMiPositionUserThree != 0;
    axiom ghostMiPositionUserOne != ghostMiPositionUserThree;
    axiom ghostMiPositionUserTwo != ghostMiPositionUserThree;
}

definition VALID_POSITION_USER(address u) returns bool =
    u == ghostMiPositionUserOne
    || u == ghostMiPositionUserTwo
    || u == ghostMiPositionUserThree;

// A market's tickSpacing is a divisor of DEFAULT_TICK_SPACING (4): touchMarket
// sets it to 4, setMarketTickSpacing only refines it to a divisor of the
// current value. 0 marks an untouched market.
definition VALID_TICK_SPACING(mathint t) returns bool =
    t == 0 || t == 1 || t == 2 || t == 4;

//
// marketState[id].tickSpacing (id-keyed; common)
//
// A market is "touched" iff tickSpacing > 0 — touchMarket sets DEFAULT_TICK_SPACING
// on creation. Used by touchMarketCVL (read), so stays in the common base.
// one-market invariants reference the scalar mirror ghostMiOneMarketTickSpacing.

persistent ghost mapping(bytes32 => mathint) ghostMiMarketTickSpacing {
    init_state axiom forall bytes32 id. ghostMiMarketTickSpacing[id] == 0;
    axiom forall bytes32 id.
        ghostMiMarketTickSpacing[id] >= 0 && ghostMiMarketTickSpacing[id] <= max_uint8;
}
// Scalar mirror consumed by one-market invariants. Tracks the latest-written
// id's value; single-id consistency emerges from Sload mirror checks on other
// per-market slots (see midnight_one.spec hooks).
persistent ghost mathint ghostMiOneMarketTickSpacing {
    init_state axiom ghostMiOneMarketTickSpacing == 0;
    axiom ghostMiOneMarketTickSpacing >= 0 && ghostMiOneMarketTickSpacing <= max_uint8;
}
hook Sload uint8 v _Midnight.marketState[KEY bytes32 id].tickSpacing {
    require(require_uint8(ghostMiMarketTickSpacing[id]) == v,
        "ghost mirror: marketState[id].tickSpacing");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].tickSpacing uint8 v {
    ghostMiMarketTickSpacing[id] = v;
    ghostMiOneMarketTickSpacing = v;
}

//
// market -> loanToken (id-keyed; common)
//
// Captured by touchMarketCVL. Pins market→loanToken mapping; consumed by the
// one-market regime; harmless in many-market regime.

persistent ghost mapping(bytes32 => address) ghostMiMarketLoanToken {
    init_state axiom forall bytes32 id. ghostMiMarketLoanToken[id] == 0;
}

// Scalar mirror consumed by one-market invariants. Captured by touchMarketCVL
// with stability require — feasible paths share loanToken across all touches.
persistent ghost address ghostMiOneMarketLoanToken {
    init_state axiom ghostMiOneMarketLoanToken == 0;
}

// Scalar slot→token map consumed by VS-MI-14 collateralBackedByBalance.
persistent ghost mapping(uint256 => address) ghostMiOneCollateralToken {
    init_state axiom forall uint256 i. ghostMiOneCollateralToken[i] == 0;
}

// Per-id slot→token map consumed by many-market VS-MI-13/14 collateral sums.
persistent ghost mapping(bytes32 => mapping(uint256 => address)) ghostMiMarketCollateralToken {
    init_state axiom forall bytes32 id. forall uint256 i.
        ghostMiMarketCollateralToken[id][i] == 0;
}

//
// Top-level mappings (token-keyed / address-keyed)
//

persistent ghost mapping(address => mapping(bytes32 => mathint)) ghostMiConsumed256 {
    init_state axiom forall address u. forall bytes32 g. ghostMiConsumed256[u][g] == 0;
    axiom forall address u. forall bytes32 g. ghostMiConsumed256[u][g] >= 0 && ghostMiConsumed256[u][g] <= max_uint128;
}
hook Sload uint128 v _Midnight.consumed[KEY address u][KEY bytes32 g] {
    require(ghostMiConsumed256[u][g] == to_mathint(v),
        "ghost mirror: consumed[user][group]");
}
hook Sstore _Midnight.consumed[KEY address u][KEY bytes32 g] uint128 v {
    ghostMiConsumed256[u][g] = v;
}

persistent ghost mapping(address => mapping(address => bool)) ghostMiIsAuthorized {
    init_state axiom forall address a. forall address b. ghostMiIsAuthorized[a][b] == false;
}
hook Sload bool v _Midnight.isAuthorized[KEY address a][KEY address b] {
    require(ghostMiIsAuthorized[a][b] == v,
        "ghost mirror: isAuthorized[owner][delegate]");
}
hook Sstore _Midnight.isAuthorized[KEY address a][KEY address b] bool v {
    ghostMiIsAuthorized[a][b] = v;
}

persistent ghost mapping(address => mapping(uint256 => mathint)) ghostMiDefaultSettlementFeeCbp16 {
    init_state axiom forall address t. forall uint256 i. ghostMiDefaultSettlementFeeCbp16[t][i] == 0;
    axiom forall address t. forall uint256 i.
        ghostMiDefaultSettlementFeeCbp16[t][i] >= 0 && ghostMiDefaultSettlementFeeCbp16[t][i] <= max_uint16;
}
hook Sload uint16 v _Midnight.defaultSettlementFeeCbp[KEY address t][INDEX uint256 i] {
    require(require_uint16(ghostMiDefaultSettlementFeeCbp16[t][i]) == v,
        "ghost mirror: defaultSettlementFeeCbp[token][i]");
}
hook Sstore _Midnight.defaultSettlementFeeCbp[KEY address t][INDEX uint256 i] uint16 v {
    ghostMiDefaultSettlementFeeCbp16[t][i] = v;
}

persistent ghost mapping(address => mathint) ghostMiDefaultContinuousFee32 {
    init_state axiom forall address t. ghostMiDefaultContinuousFee32[t] == 0;
    axiom forall address t. ghostMiDefaultContinuousFee32[t] >= 0 && ghostMiDefaultContinuousFee32[t] <= max_uint32;
}
hook Sload uint32 v _Midnight.defaultContinuousFee[KEY address t] {
    require(require_uint32(ghostMiDefaultContinuousFee32[t]) == v,
        "ghost mirror: defaultContinuousFee[token]");
}
hook Sstore _Midnight.defaultContinuousFee[KEY address t] uint32 v {
    ghostMiDefaultContinuousFee32[t] = v;
}

persistent ghost mapping(address => mathint) ghostMiClaimableSettlementFee256 {
    init_state axiom forall address t. ghostMiClaimableSettlementFee256[t] == 0;
    axiom forall address t. ghostMiClaimableSettlementFee256[t] >= 0 && ghostMiClaimableSettlementFee256[t] <= max_uint256;
}
hook Sload uint256 v _Midnight.claimableSettlementFee[KEY address t] {
    require(require_uint256(ghostMiClaimableSettlementFee256[t]) == v,
        "ghost mirror: claimableSettlementFee[token]");
}
hook Sstore _Midnight.claimableSettlementFee[KEY address t] uint256 v {
    ghostMiClaimableSettlementFee256[t] = v;
}

persistent ghost address ghostMiConfigurator {
    init_state axiom ghostMiConfigurator == 0;
}
hook Sload address v _Midnight.configurator {
    require(ghostMiConfigurator == v,
        "ghost mirror: configurator");
}
hook Sstore _Midnight.configurator address v {
    ghostMiConfigurator = v;
}

persistent ghost address ghostMiFeeSetter {
    init_state axiom ghostMiFeeSetter == 0;
}
hook Sload address v _Midnight.feeSetter {
    require(ghostMiFeeSetter == v,
        "ghost mirror: feeSetter");
}
hook Sstore _Midnight.feeSetter address v {
    ghostMiFeeSetter = v;
}

persistent ghost address ghostMiFeeClaimer {
    init_state axiom ghostMiFeeClaimer == 0;
}
hook Sload address v _Midnight.feeClaimer {
    require(ghostMiFeeClaimer == v,
        "ghost mirror: feeClaimer");
}
hook Sstore _Midnight.feeClaimer address v {
    ghostMiFeeClaimer = v;
}

persistent ghost address ghostMiTickSpacingSetter {
    init_state axiom ghostMiTickSpacingSetter == 0;
}
hook Sload address v _Midnight.tickSpacingSetter {
    require(ghostMiTickSpacingSetter == v,
        "ghost mirror: tickSpacingSetter");
}
hook Sstore _Midnight.tickSpacingSetter address v {
    ghostMiTickSpacingSetter = v;
}

//
// Governance-enabled LLTV tiers and liquidation cursors (3836155): runtime mappings replacing the
// old fixed ConstantsLib sets. Consumed by market-creation, access-control, and state-transition
// rules. Only ever flip false -> true (enableLltv / enableLiquidationCursor).
//

persistent ghost mapping(uint256 => bool) ghostMiIsLltvEnabled {
    init_state axiom forall uint256 lltv. ghostMiIsLltvEnabled[lltv] == false;
}
hook Sload bool v _Midnight.isLltvEnabled[KEY uint256 lltv] {
    require(ghostMiIsLltvEnabled[lltv] == v,
        "ghost mirror: isLltvEnabled[lltv]");
}
hook Sstore _Midnight.isLltvEnabled[KEY uint256 lltv] bool v {
    ghostMiIsLltvEnabled[lltv] = v;
}

persistent ghost mapping(uint256 => bool) ghostMiIsLiquidationCursorEnabled {
    init_state axiom forall uint256 cursor. ghostMiIsLiquidationCursorEnabled[cursor] == false;
}
hook Sload bool v _Midnight.isLiquidationCursorEnabled[KEY uint256 cursor] {
    require(ghostMiIsLiquidationCursorEnabled[cursor] == v,
        "ghost mirror: isLiquidationCursorEnabled[cursor]");
}
hook Sstore _Midnight.isLiquidationCursorEnabled[KEY uint256 cursor] bool v {
    ghostMiIsLiquidationCursorEnabled[cursor] = v;
}
