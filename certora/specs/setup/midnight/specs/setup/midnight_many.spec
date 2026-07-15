// Many-market regime: per-id ghosts + three-market narrowing for cross-id rules.

import "midnight.spec";
import "touch_market_summary.spec";

// Three-market narrowing: ghost ids (idA, idB, idC) pin the only three
// touched markets the prover may see; methods on any other id are
// infeasible (VALID_MARKET_MANY require in every per-id hook).
persistent ghost bytes32 ghostMiMarketIdA {
    axiom ghostMiMarketIdA != to_bytes32(0);
}
persistent ghost bytes32 ghostMiMarketIdB {
    axiom ghostMiMarketIdB != to_bytes32(0);
    axiom ghostMiMarketIdA != ghostMiMarketIdB;
}
persistent ghost bytes32 ghostMiMarketIdC {
    axiom ghostMiMarketIdC != to_bytes32(0);
    axiom ghostMiMarketIdA != ghostMiMarketIdC;
    axiom ghostMiMarketIdB != ghostMiMarketIdC;
}

definition VALID_MARKET_MANY(bytes32 id) returns bool =
    id == ghostMiMarketIdA || id == ghostMiMarketIdB || id == ghostMiMarketIdC;

// Per-id ghosts mirroring storage; consumed by `midnight_valid_state_many.spec`.

persistent ghost mapping(bytes32 => mapping(address => mathint)) ghostMiPositionCredit128 {
    init_state axiom forall bytes32 id. forall address u. ghostMiPositionCredit128[id][u] == 0;
    axiom forall bytes32 id. forall address u. ghostMiPositionCredit128[id][u] >= 0 && ghostMiPositionCredit128[id][u] <= max_uint128;
}
hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].credit {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiPositionCredit128[id][u]) == v,
        "ghost mirror: position[id][u].credit");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].credit uint128 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    ghostMiPositionCredit128[id][u] = v;
}

persistent ghost mapping(bytes32 => mapping(address => mathint)) ghostMiPositionPendingFee128 {
    init_state axiom forall bytes32 id. forall address u. ghostMiPositionPendingFee128[id][u] == 0;
    axiom forall bytes32 id. forall address u. ghostMiPositionPendingFee128[id][u] >= 0 && ghostMiPositionPendingFee128[id][u] <= max_uint128;
}
hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].pendingFee {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiPositionPendingFee128[id][u]) == v,
        "ghost mirror: position[id][u].pendingFee");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].pendingFee uint128 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    ghostMiPositionPendingFee128[id][u] = v;
}

persistent ghost mapping(bytes32 => mapping(address => mathint)) ghostMiPositionLastLossFactor128 {
    init_state axiom forall bytes32 id. forall address u. ghostMiPositionLastLossFactor128[id][u] == 0;
    axiom forall bytes32 id. forall address u. ghostMiPositionLastLossFactor128[id][u] >= 0 && ghostMiPositionLastLossFactor128[id][u] <= max_uint128;
}
hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].lastLossFactor {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiPositionLastLossFactor128[id][u]) == v,
        "ghost mirror: position[id][u].lastLossFactor");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].lastLossFactor uint128 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    ghostMiPositionLastLossFactor128[id][u] = v;
}

persistent ghost mapping(bytes32 => mapping(address => mathint)) ghostMiPositionLastAccrual128 {
    init_state axiom forall bytes32 id. forall address u. ghostMiPositionLastAccrual128[id][u] == 0;
    axiom forall bytes32 id. forall address u. ghostMiPositionLastAccrual128[id][u] >= 0 && ghostMiPositionLastAccrual128[id][u] <= max_uint128;
}
hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].lastAccrual {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiPositionLastAccrual128[id][u]) == v,
        "ghost mirror: position[id][u].lastAccrual");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].lastAccrual uint128 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    ghostMiPositionLastAccrual128[id][u] = v;
}

persistent ghost mapping(bytes32 => mapping(address => mathint)) ghostMiPositionDebt128 {
    init_state axiom forall bytes32 id. forall address u. ghostMiPositionDebt128[id][u] == 0;
    axiom forall bytes32 id. forall address u. ghostMiPositionDebt128[id][u] >= 0 && ghostMiPositionDebt128[id][u] <= max_uint128;
}
hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].debt {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiPositionDebt128[id][u]) == v,
        "ghost mirror: position[id][u].debt");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].debt uint128 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    ghostMiPositionDebt128[id][u] = v;
}

persistent ghost mapping(bytes32 => mapping(address => mathint)) ghostMiPositionCollateralBitmap128 {
    init_state axiom forall bytes32 id. forall address u. ghostMiPositionCollateralBitmap128[id][u] == 0;
    axiom forall bytes32 id. forall address u. ghostMiPositionCollateralBitmap128[id][u] >= 0 && ghostMiPositionCollateralBitmap128[id][u] <= max_uint128;
}
hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].collateralBitmap {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiPositionCollateralBitmap128[id][u]) == v,
        "ghost mirror: position[id][u].collateralBitmap");
    require(VALID_COLLATERAL_BITMAP(to_mathint(v)),
        "UNSAFE: bitmap valid for ghostNumCollaterals");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].collateralBitmap uint128 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(VALID_COLLATERAL_BITMAP(to_mathint(v)),
        "UNSAFE: bitmap valid for ghostNumCollaterals");
    ghostMiPositionCollateralBitmap128[id][u] = v;
}

persistent ghost mapping(bytes32 => mapping(address => mapping(uint256 => mathint))) ghostMiPositionCollateral128 {
    init_state axiom forall bytes32 id. forall address u. forall uint256 i.
        ghostMiPositionCollateral128[id][u][i] == 0;
    axiom forall bytes32 id. forall address u. forall uint256 i.
        ghostMiPositionCollateral128[id][u][i] >= 0 && ghostMiPositionCollateral128[id][u][i] <= max_uint128;
}

// Count of non-zero collateral[i]; maintained via 0<->nonzero Sstore transitions.
persistent ghost mapping(bytes32 => mapping(address => mathint)) ghostMiPositionCollateralLength {
    init_state axiom forall bytes32 id. forall address u.
        ghostMiPositionCollateralLength[id][u] == 0;
    axiom forall bytes32 id. forall address u.
        ghostMiPositionCollateralLength[id][u] >= 0
        && ghostMiPositionCollateralLength[id][u] <= 128;
}

// Under two-collateral narrowing only slots {0, 1} can be non-zero.
definition COLLATERAL_ACTIVE_COUNT(bytes32 _id, address _u) returns mathint =
    (ghostMiPositionCollateral128[_id][_u][0] != 0 ? 1 : 0)
    + (ghostMiPositionCollateral128[_id][_u][1] != 0 ? 1 : 0);

hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].collateral[INDEX uint256 i] {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiPositionCollateral128[id][u][i]) == v,
        "ghost mirror: position[id][u].collateral[i]");
    require(VALID_COLLATERAL_BIT(i) || v == 0,
        "UNSAFE: collateral[i] reads only at VALID_COLLATERAL_BIT (or zero)");
    require(ghostMiPositionCollateralLength[id][u] == COLLATERAL_ACTIVE_COUNT(id, u),
        "sync: collateralLength matches COLLATERAL_ACTIVE_COUNT");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].collateral[INDEX uint256 i] uint128 v (uint128 oldV) {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(VALID_COLLATERAL_BIT(i) || v == 0,
        "UNSAFE: collateral[i] writes only at VALID_COLLATERAL_BIT (or to zero)");

    // Track 0<->nonzero transitions.
    if (oldV == 0 && v != 0) {
        ghostMiPositionCollateralLength[id][u] = ghostMiPositionCollateralLength[id][u] + 1;
    } else if (oldV != 0 && v == 0) {
        ghostMiPositionCollateralLength[id][u] = ghostMiPositionCollateralLength[id][u] - 1;
    }

    ghostMiPositionCollateral128[id][u][i] = v;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketTotalUnits128 {
    init_state axiom forall bytes32 id. ghostMiMarketTotalUnits128[id] == 0;
    axiom forall bytes32 id. ghostMiMarketTotalUnits128[id] >= 0 && ghostMiMarketTotalUnits128[id] <= max_uint128;
}
hook Sload uint128 v _Midnight.marketState[KEY bytes32 id].totalUnits {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(require_uint128(ghostMiMarketTotalUnits128[id]) == v,
        "ghost mirror: marketState[id].totalUnits");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].totalUnits uint128 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    ghostMiMarketTotalUnits128[id] = v;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketLossFactor128 {
    init_state axiom forall bytes32 id. ghostMiMarketLossFactor128[id] == 0;
    axiom forall bytes32 id. ghostMiMarketLossFactor128[id] >= 0 && ghostMiMarketLossFactor128[id] <= max_uint128;
}
hook Sload uint128 v _Midnight.marketState[KEY bytes32 id].lossFactor {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(require_uint128(ghostMiMarketLossFactor128[id]) == v,
        "ghost mirror: marketState[id].lossFactor");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].lossFactor uint128 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    ghostMiMarketLossFactor128[id] = v;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketWithdrawable128 {
    init_state axiom forall bytes32 id. ghostMiMarketWithdrawable128[id] == 0;
    axiom forall bytes32 id. ghostMiMarketWithdrawable128[id] >= 0 && ghostMiMarketWithdrawable128[id] <= max_uint128;
}
hook Sload uint128 v _Midnight.marketState[KEY bytes32 id].withdrawable {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(require_uint128(ghostMiMarketWithdrawable128[id]) == v,
        "ghost mirror: marketState[id].withdrawable");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].withdrawable uint128 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    ghostMiMarketWithdrawable128[id] = v;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketContinuousFeeCredit128 {
    init_state axiom forall bytes32 id. ghostMiMarketContinuousFeeCredit128[id] == 0;
    axiom forall bytes32 id. ghostMiMarketContinuousFeeCredit128[id] >= 0 && ghostMiMarketContinuousFeeCredit128[id] <= max_uint128;
}
hook Sload uint128 v _Midnight.marketState[KEY bytes32 id].continuousFeeCredit {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(require_uint128(ghostMiMarketContinuousFeeCredit128[id]) == v,
        "ghost mirror: marketState[id].continuousFeeCredit");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].continuousFeeCredit uint128 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    ghostMiMarketContinuousFeeCredit128[id] = v;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketSettlementFeeCbp0_16 {
    init_state axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp0_16[id] == 0;
    axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp0_16[id] >= 0 && ghostMiMarketSettlementFeeCbp0_16[id] <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp0 {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(require_uint16(ghostMiMarketSettlementFeeCbp0_16[id]) == v,
        "ghost mirror: marketState[id].settlementFeeCbp0");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp0 uint16 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    ghostMiMarketSettlementFeeCbp0_16[id] = v;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketSettlementFeeCbp1_16 {
    init_state axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp1_16[id] == 0;
    axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp1_16[id] >= 0 && ghostMiMarketSettlementFeeCbp1_16[id] <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp1 {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(require_uint16(ghostMiMarketSettlementFeeCbp1_16[id]) == v,
        "ghost mirror: marketState[id].settlementFeeCbp1");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp1 uint16 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    ghostMiMarketSettlementFeeCbp1_16[id] = v;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketSettlementFeeCbp2_16 {
    init_state axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp2_16[id] == 0;
    axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp2_16[id] >= 0 && ghostMiMarketSettlementFeeCbp2_16[id] <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp2 {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(require_uint16(ghostMiMarketSettlementFeeCbp2_16[id]) == v,
        "ghost mirror: marketState[id].settlementFeeCbp2");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp2 uint16 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    ghostMiMarketSettlementFeeCbp2_16[id] = v;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketSettlementFeeCbp3_16 {
    init_state axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp3_16[id] == 0;
    axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp3_16[id] >= 0 && ghostMiMarketSettlementFeeCbp3_16[id] <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp3 {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(require_uint16(ghostMiMarketSettlementFeeCbp3_16[id]) == v,
        "ghost mirror: marketState[id].settlementFeeCbp3");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp3 uint16 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    ghostMiMarketSettlementFeeCbp3_16[id] = v;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketSettlementFeeCbp4_16 {
    init_state axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp4_16[id] == 0;
    axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp4_16[id] >= 0 && ghostMiMarketSettlementFeeCbp4_16[id] <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp4 {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(require_uint16(ghostMiMarketSettlementFeeCbp4_16[id]) == v,
        "ghost mirror: marketState[id].settlementFeeCbp4");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp4 uint16 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    ghostMiMarketSettlementFeeCbp4_16[id] = v;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketSettlementFeeCbp5_16 {
    init_state axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp5_16[id] == 0;
    axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp5_16[id] >= 0 && ghostMiMarketSettlementFeeCbp5_16[id] <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp5 {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(require_uint16(ghostMiMarketSettlementFeeCbp5_16[id]) == v,
        "ghost mirror: marketState[id].settlementFeeCbp5");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp5 uint16 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    ghostMiMarketSettlementFeeCbp5_16[id] = v;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketSettlementFeeCbp6_16 {
    init_state axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp6_16[id] == 0;
    axiom forall bytes32 id. ghostMiMarketSettlementFeeCbp6_16[id] >= 0 && ghostMiMarketSettlementFeeCbp6_16[id] <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp6 {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(require_uint16(ghostMiMarketSettlementFeeCbp6_16[id]) == v,
        "ghost mirror: marketState[id].settlementFeeCbp6");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp6 uint16 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    ghostMiMarketSettlementFeeCbp6_16[id] = v;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketContinuousFee32 {
    init_state axiom forall bytes32 id. ghostMiMarketContinuousFee32[id] == 0;
    axiom forall bytes32 id. ghostMiMarketContinuousFee32[id] >= 0 && ghostMiMarketContinuousFee32[id] <= max_uint32;
}
hook Sload uint32 v _Midnight.marketState[KEY bytes32 id].continuousFee {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    require(require_uint32(ghostMiMarketContinuousFee32[id]) == v,
        "ghost mirror: marketState[id].continuousFee");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].continuousFee uint32 v {
    require(VALID_MARKET_MANY(id),
        "UNSAFE: market id in three-market narrowing");
    ghostMiMarketContinuousFee32[id] = v;
}

function setupManyMidnight(env e) {
    setupMidnight(e);

    // Activate many-mode no-aliasing requires in touchMarketCVL.
    require(ghostMiManyModeActive,
        "UNSAFE: many-mode flag enables no-aliasing requires in touchMarketCVL");

    // Only idA, idB, idC may be touched; any other touched id would let methods
    // on it move balance without appearing in the three-market sums.
    require(forall bytes32 _id.
        ghostMiMarketTickSpacing[_id] > 0 => VALID_MARKET_MANY(_id),
        "UNSAFE: at most 3 markets touched (many-mode narrowing)");

    // touched[id] <=> loanToken-ghost is set. The external touchMarket body sets
    // tickSpacing without going through touchMarketCVL, so the loanToken ghost
    // can stay stale without this require.
    require(forall bytes32 _id.
        (ghostMiMarketTickSpacing[_id] > 0) <=> (ghostMiMarketLoanToken[_id] != 0),
        "UNSAFE: touched[id] iff loanToken-ghost is set");

    // No collateral pot may exist in a slot whose token attribution is unset:
    // supplyCollateral always passes through touchMarket, which pins the slot
    // token before any collateral can land. Otherwise touchMarketCVL's 0->token
    // attribution flip migrates the summed pot into that token's backing bucket
    // with no balance movement.
    require(forall bytes32 _id. forall address _u. forall uint256 _i.
        ghostMiMarketCollateralToken[_id][_i] == 0
            => ghostMiPositionCollateral128[_id][_u][_i] == 0,
        "UNSAFE: no collateral pot in a slot with unset token attribution");

    // Initial state: markets outside the three-market narrowing carry no state.
    // Every per-id hook require's VALID_MARKET_MANY(id), so writes to other ids
    // are infeasible -- but the pre-state must be pinned too, else the prover
    // could seed a non-narrowed market with arbitrary fields.
    require(forall bytes32 _id. !VALID_MARKET_MANY(_id) => (
        ghostMiMarketTotalUnits128[_id] == 0
        && ghostMiMarketLossFactor128[_id] == 0
        && ghostMiMarketWithdrawable128[_id] == 0
        && ghostMiMarketContinuousFeeCredit128[_id] == 0
        && ghostMiMarketSettlementFeeCbp0_16[_id] == 0
        && ghostMiMarketSettlementFeeCbp1_16[_id] == 0
        && ghostMiMarketSettlementFeeCbp2_16[_id] == 0
        && ghostMiMarketSettlementFeeCbp3_16[_id] == 0
        && ghostMiMarketSettlementFeeCbp4_16[_id] == 0
        && ghostMiMarketSettlementFeeCbp5_16[_id] == 0
        && ghostMiMarketSettlementFeeCbp6_16[_id] == 0
        && ghostMiMarketContinuousFee32[_id] == 0
    ), "UNSAFE: market state zeroed for ids outside three-market narrowing");

    require(forall bytes32 _id. forall uint256 _i. !VALID_MARKET_MANY(_id)
        => ghostMiMarketCollateralToken[_id][_i] == 0,
        "UNSAFE: collateralToken zeroed for ids outside three-market narrowing");

    require(forall bytes32 _id. forall address _u. !VALID_MARKET_MANY(_id) => (
        ghostMiPositionCredit128[_id][_u] == 0
        && ghostMiPositionPendingFee128[_id][_u] == 0
        && ghostMiPositionLastLossFactor128[_id][_u] == 0
        && ghostMiPositionLastAccrual128[_id][_u] == 0
        && ghostMiPositionDebt128[_id][_u] == 0
        && ghostMiPositionCollateralBitmap128[_id][_u] == 0
        && ghostMiPositionCollateralLength[_id][_u] == 0
    ), "UNSAFE: position fields zeroed for ids outside three-market narrowing");

    require(forall bytes32 _id. forall address _u. forall uint256 _i.
        !VALID_MARKET_MANY(_id) => ghostMiPositionCollateral128[_id][_u][_i] == 0,
        "UNSAFE: position collateral zeroed for ids outside three-market narrowing");

    // Note: "Midnight never self-approves" is encoded as the VS-MI-16
    // noSelfApprove invariant (asserted via requireInvariant in
    // setupValidStateManyMidnight), not as a TRUSTED require here.

    require(forall bytes32 _id. forall address _u.
        VALID_COLLATERAL_BITMAP(ghostMiPositionCollateralBitmap128[_id][_u]),
        "UNSAFE: bitmap valid for ghostNumCollaterals");

    require(forall bytes32 _id. forall address _u. forall uint256 _i.
        !VALID_COLLATERAL_BIT(_i) => ghostMiPositionCollateral128[_id][_u][_i] == 0,
        "UNSAFE: collateral[i] = 0 for i outside VALID_COLLATERAL_BIT");

    require(forall bytes32 _id. forall address _u.
        ghostMiPositionCollateralLength[_id][_u] == COLLATERAL_ACTIVE_COUNT(_id, _u),
        "UNSAFE: collateralLength synchronized with non-zero collateral count");

    require(forall bytes32 _id. forall address _u.
        ghostMiPositionCollateralLength[_id][_u] <= ghostNumCollaterals,
        "UNSAFE: collateralLength <= ghostNumCollaterals");

    require(forall bytes32 _id. forall address _u. !VALID_POSITION_USER(_u) => (
        ghostMiPositionCredit128[_id][_u] == 0
        && ghostMiPositionPendingFee128[_id][_u] == 0
        && ghostMiPositionLastLossFactor128[_id][_u] == 0
        && ghostMiPositionLastAccrual128[_id][_u] == 0
        && ghostMiPositionDebt128[_id][_u] == 0
        && ghostMiPositionCollateralBitmap128[_id][_u] == 0
        && ghostMiPositionCollateralLength[_id][_u] == 0
    ), "UNSAFE: position fields zeroed for users outside three-user narrowing");

    require(forall bytes32 _id. forall address _u. forall uint256 _i.
        !VALID_POSITION_USER(_u) => ghostMiPositionCollateral128[_id][_u][_i] == 0,
        "UNSAFE: position collateral zeroed for users outside three-user narrowing");
}
