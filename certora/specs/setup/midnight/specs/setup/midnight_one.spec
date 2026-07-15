// One-market regime: scalar per-market ghosts + position/collateral narrowing.

import "midnight.spec";
import "touch_market_summary.spec";

// Scalar per-market ghosts (no id key). Sstore writes for any id; Sload
// mirror checks force single-id consistency. The scalar loanToken (set by
// touchMarketCVL with a stability require) pins all touches to one id.
//
// KNOWN LIMITATION ("scalar-mirror smearing"): the Sstore hooks below are UNKEYED by id, so a
// write to a second id's marketState overwrites the scalar the one-mode rules assert on (only the
// Sload-side equality requires prune diverged traces). Benign today; if the external touchMarket
// creation path is ever made live one-mode, key these hooks by a pinned ghostMiOneMarketId first
// or AC-MI-07/08/09 will refute spuriously.

//
// position[*][u].*
//

persistent ghost mapping(address => mathint) ghostMiOnePositionCredit128 {
    init_state axiom forall address u. ghostMiOnePositionCredit128[u] == 0;
    axiom forall address u. ghostMiOnePositionCredit128[u] >= 0 && ghostMiOnePositionCredit128[u] <= max_uint128;
}
hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].credit {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiOnePositionCredit128[u]) == v,
        "ghost mirror: position[u].credit");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].credit uint128 v {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    ghostMiOnePositionCredit128[u] = v;
}

persistent ghost mapping(address => mathint) ghostMiOnePositionPendingFee128 {
    init_state axiom forall address u. ghostMiOnePositionPendingFee128[u] == 0;
    axiom forall address u. ghostMiOnePositionPendingFee128[u] >= 0 && ghostMiOnePositionPendingFee128[u] <= max_uint128;
}
hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].pendingFee {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiOnePositionPendingFee128[u]) == v,
        "ghost mirror: position[u].pendingFee");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].pendingFee uint128 v {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    ghostMiOnePositionPendingFee128[u] = v;
}

persistent ghost mapping(address => mathint) ghostMiOnePositionLastLossFactor128 {
    init_state axiom forall address u. ghostMiOnePositionLastLossFactor128[u] == 0;
    axiom forall address u. ghostMiOnePositionLastLossFactor128[u] >= 0 && ghostMiOnePositionLastLossFactor128[u] <= max_uint128;
}
hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].lastLossFactor {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiOnePositionLastLossFactor128[u]) == v,
        "ghost mirror: position[u].lastLossFactor");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].lastLossFactor uint128 v {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    ghostMiOnePositionLastLossFactor128[u] = v;
}

persistent ghost mapping(address => mathint) ghostMiOnePositionLastAccrual128 {
    init_state axiom forall address u. ghostMiOnePositionLastAccrual128[u] == 0;
    axiom forall address u. ghostMiOnePositionLastAccrual128[u] >= 0 && ghostMiOnePositionLastAccrual128[u] <= max_uint128;
}
hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].lastAccrual {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiOnePositionLastAccrual128[u]) == v,
        "ghost mirror: position[u].lastAccrual");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].lastAccrual uint128 v {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    ghostMiOnePositionLastAccrual128[u] = v;
}

persistent ghost mapping(address => mathint) ghostMiOnePositionDebt128 {
    init_state axiom forall address u. ghostMiOnePositionDebt128[u] == 0;
    axiom forall address u. ghostMiOnePositionDebt128[u] >= 0 && ghostMiOnePositionDebt128[u] <= max_uint128;
}
hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].debt {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiOnePositionDebt128[u]) == v,
        "ghost mirror: position[u].debt");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].debt uint128 v {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    ghostMiOnePositionDebt128[u] = v;
}

persistent ghost mapping(address => mathint) ghostMiOnePositionCollateralBitmap128 {
    init_state axiom forall address u. ghostMiOnePositionCollateralBitmap128[u] == 0;
    axiom forall address u. ghostMiOnePositionCollateralBitmap128[u] >= 0 && ghostMiOnePositionCollateralBitmap128[u] <= max_uint128;
}
hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].collateralBitmap {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiOnePositionCollateralBitmap128[u]) == v,
        "ghost mirror: position[u].collateralBitmap");
    require(VALID_COLLATERAL_BITMAP(to_mathint(v)),
        "UNSAFE: bitmap valid for ghostNumCollaterals");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].collateralBitmap uint128 v {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(VALID_COLLATERAL_BITMAP(to_mathint(v)),
        "UNSAFE: bitmap valid for ghostNumCollaterals");
    ghostMiOnePositionCollateralBitmap128[u] = v;
}

persistent ghost mapping(address => mapping(uint256 => mathint)) ghostMiOnePositionCollateral128 {
    init_state axiom forall address u. forall uint256 i.
        ghostMiOnePositionCollateral128[u][i] == 0;
    axiom forall address u. forall uint256 i.
        ghostMiOnePositionCollateral128[u][i] >= 0 && ghostMiOnePositionCollateral128[u][i] <= max_uint128;
}

persistent ghost mapping(address => mathint) ghostMiOnePositionCollateralLength {
    init_state axiom forall address u. ghostMiOnePositionCollateralLength[u] == 0;
    axiom forall address u. ghostMiOnePositionCollateralLength[u] >= 0 && ghostMiOnePositionCollateralLength[u] <= 128;
}

// Under two-collateral narrowing only slots {0, 1} can be non-zero.
definition COLLATERAL_ACTIVE_COUNT_ONE(address _u) returns mathint =
    (ghostMiOnePositionCollateral128[_u][0] != 0 ? 1 : 0)
    + (ghostMiOnePositionCollateral128[_u][1] != 0 ? 1 : 0);

hook Sload uint128 v _Midnight.position[KEY bytes32 id][KEY address u].collateral[INDEX uint256 i] {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(require_uint128(ghostMiOnePositionCollateral128[u][i]) == v,
        "ghost mirror: position[u].collateral[i]");
    require(VALID_COLLATERAL_BIT(i) || v == 0,
        "UNSAFE: collateral[i] reads only at VALID_COLLATERAL_BIT (or zero)");
    require(ghostMiOnePositionCollateralLength[u] == COLLATERAL_ACTIVE_COUNT_ONE(u),
        "sync: collateralLength matches COLLATERAL_ACTIVE_COUNT_ONE");
}
hook Sstore _Midnight.position[KEY bytes32 id][KEY address u].collateral[INDEX uint256 i] uint128 v (uint128 oldV) {
    require(VALID_POSITION_USER(u),
        "UNSAFE: position user in three-user narrowing");
    require(VALID_COLLATERAL_BIT(i) || v == 0,
        "UNSAFE: collateral[i] writes only at VALID_COLLATERAL_BIT (or to zero)");

    if (oldV == 0 && v != 0) {
        ghostMiOnePositionCollateralLength[u] = ghostMiOnePositionCollateralLength[u] + 1;
    } else if (oldV != 0 && v == 0) {
        ghostMiOnePositionCollateralLength[u] = ghostMiOnePositionCollateralLength[u] - 1;
    }

    ghostMiOnePositionCollateral128[u][i] = v;
}

//
// marketState[*].* (scalar)
//

persistent ghost mathint ghostMiOneMarketTotalUnits128 {
    init_state axiom ghostMiOneMarketTotalUnits128 == 0;
    axiom ghostMiOneMarketTotalUnits128 >= 0 && ghostMiOneMarketTotalUnits128 <= max_uint128;
}
hook Sload uint128 v _Midnight.marketState[KEY bytes32 id].totalUnits {
    require(require_uint128(ghostMiOneMarketTotalUnits128) == v,
        "ghost mirror: marketState.totalUnits");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].totalUnits uint128 v {
    ghostMiOneMarketTotalUnits128 = v;
}

persistent ghost mathint ghostMiOneMarketLossFactor128 {
    init_state axiom ghostMiOneMarketLossFactor128 == 0;
    axiom ghostMiOneMarketLossFactor128 >= 0 && ghostMiOneMarketLossFactor128 <= max_uint128;
}
hook Sload uint128 v _Midnight.marketState[KEY bytes32 id].lossFactor {
    require(require_uint128(ghostMiOneMarketLossFactor128) == v,
        "ghost mirror: marketState.lossFactor");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].lossFactor uint128 v {
    ghostMiOneMarketLossFactor128 = v;
}

persistent ghost mathint ghostMiOneMarketWithdrawable128 {
    init_state axiom ghostMiOneMarketWithdrawable128 == 0;
    axiom ghostMiOneMarketWithdrawable128 >= 0 && ghostMiOneMarketWithdrawable128 <= max_uint128;
}
hook Sload uint128 v _Midnight.marketState[KEY bytes32 id].withdrawable {
    require(require_uint128(ghostMiOneMarketWithdrawable128) == v,
        "ghost mirror: marketState.withdrawable");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].withdrawable uint128 v {
    ghostMiOneMarketWithdrawable128 = v;
}

persistent ghost mathint ghostMiOneMarketContinuousFeeCredit128 {
    init_state axiom ghostMiOneMarketContinuousFeeCredit128 == 0;
    axiom ghostMiOneMarketContinuousFeeCredit128 >= 0 && ghostMiOneMarketContinuousFeeCredit128 <= max_uint128;
}
hook Sload uint128 v _Midnight.marketState[KEY bytes32 id].continuousFeeCredit {
    require(require_uint128(ghostMiOneMarketContinuousFeeCredit128) == v,
        "ghost mirror: marketState.continuousFeeCredit");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].continuousFeeCredit uint128 v {
    ghostMiOneMarketContinuousFeeCredit128 = v;
}

persistent ghost mathint ghostMiOneMarketSettlementFeeCbp0_16 {
    init_state axiom ghostMiOneMarketSettlementFeeCbp0_16 == 0;
    axiom ghostMiOneMarketSettlementFeeCbp0_16 >= 0 && ghostMiOneMarketSettlementFeeCbp0_16 <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp0 {
    require(require_uint16(ghostMiOneMarketSettlementFeeCbp0_16) == v,
        "ghost mirror: marketState.settlementFeeCbp0");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp0 uint16 v {
    ghostMiOneMarketSettlementFeeCbp0_16 = v;
}

persistent ghost mathint ghostMiOneMarketSettlementFeeCbp1_16 {
    init_state axiom ghostMiOneMarketSettlementFeeCbp1_16 == 0;
    axiom ghostMiOneMarketSettlementFeeCbp1_16 >= 0 && ghostMiOneMarketSettlementFeeCbp1_16 <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp1 {
    require(require_uint16(ghostMiOneMarketSettlementFeeCbp1_16) == v,
        "ghost mirror: marketState.settlementFeeCbp1");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp1 uint16 v {
    ghostMiOneMarketSettlementFeeCbp1_16 = v;
}

persistent ghost mathint ghostMiOneMarketSettlementFeeCbp2_16 {
    init_state axiom ghostMiOneMarketSettlementFeeCbp2_16 == 0;
    axiom ghostMiOneMarketSettlementFeeCbp2_16 >= 0 && ghostMiOneMarketSettlementFeeCbp2_16 <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp2 {
    require(require_uint16(ghostMiOneMarketSettlementFeeCbp2_16) == v,
        "ghost mirror: marketState.settlementFeeCbp2");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp2 uint16 v {
    ghostMiOneMarketSettlementFeeCbp2_16 = v;
}

persistent ghost mathint ghostMiOneMarketSettlementFeeCbp3_16 {
    init_state axiom ghostMiOneMarketSettlementFeeCbp3_16 == 0;
    axiom ghostMiOneMarketSettlementFeeCbp3_16 >= 0 && ghostMiOneMarketSettlementFeeCbp3_16 <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp3 {
    require(require_uint16(ghostMiOneMarketSettlementFeeCbp3_16) == v,
        "ghost mirror: marketState.settlementFeeCbp3");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp3 uint16 v {
    ghostMiOneMarketSettlementFeeCbp3_16 = v;
}

persistent ghost mathint ghostMiOneMarketSettlementFeeCbp4_16 {
    init_state axiom ghostMiOneMarketSettlementFeeCbp4_16 == 0;
    axiom ghostMiOneMarketSettlementFeeCbp4_16 >= 0 && ghostMiOneMarketSettlementFeeCbp4_16 <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp4 {
    require(require_uint16(ghostMiOneMarketSettlementFeeCbp4_16) == v,
        "ghost mirror: marketState.settlementFeeCbp4");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp4 uint16 v {
    ghostMiOneMarketSettlementFeeCbp4_16 = v;
}

persistent ghost mathint ghostMiOneMarketSettlementFeeCbp5_16 {
    init_state axiom ghostMiOneMarketSettlementFeeCbp5_16 == 0;
    axiom ghostMiOneMarketSettlementFeeCbp5_16 >= 0 && ghostMiOneMarketSettlementFeeCbp5_16 <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp5 {
    require(require_uint16(ghostMiOneMarketSettlementFeeCbp5_16) == v,
        "ghost mirror: marketState.settlementFeeCbp5");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp5 uint16 v {
    ghostMiOneMarketSettlementFeeCbp5_16 = v;
}

persistent ghost mathint ghostMiOneMarketSettlementFeeCbp6_16 {
    init_state axiom ghostMiOneMarketSettlementFeeCbp6_16 == 0;
    axiom ghostMiOneMarketSettlementFeeCbp6_16 >= 0 && ghostMiOneMarketSettlementFeeCbp6_16 <= max_uint16;
}
hook Sload uint16 v _Midnight.marketState[KEY bytes32 id].settlementFeeCbp6 {
    require(require_uint16(ghostMiOneMarketSettlementFeeCbp6_16) == v,
        "ghost mirror: marketState.settlementFeeCbp6");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].settlementFeeCbp6 uint16 v {
    ghostMiOneMarketSettlementFeeCbp6_16 = v;
}

persistent ghost mathint ghostMiOneMarketContinuousFee32 {
    init_state axiom ghostMiOneMarketContinuousFee32 == 0;
    axiom ghostMiOneMarketContinuousFee32 >= 0 && ghostMiOneMarketContinuousFee32 <= max_uint32;
}
hook Sload uint32 v _Midnight.marketState[KEY bytes32 id].continuousFee {
    require(require_uint32(ghostMiOneMarketContinuousFee32) == v,
        "ghost mirror: marketState.continuousFee");
}
hook Sstore _Midnight.marketState[KEY bytes32 id].continuousFee uint32 v {
    ghostMiOneMarketContinuousFee32 = v;
}

function setupOneMidnight(env e) {
    setupOneMidnightWithLock(e, true);
}

// Lock-pin passthrough — see setupMidnightWithLock (ST-MI-13 regime).
function setupOneMidnightWithLock(env e, bool pinLiquidationLock) {
    setupMidnightWithLock(e, pinLiquidationLock);

    require(ghostMiOneMarketLoanToken != 0,
        "UNSAFE: loanToken set by prior touchMarket");
    require(ghostMiOneMarketLoanToken != _Midnight,
        "TRUSTED: loanToken is not the lending contract itself");

    // Narrowed market is assumed touched. touchMarketCVL only require's the
    // id-keyed ghost (no Sstore on .tickSpacing), so without this the scalar
    // stays 0 from init_state and breaks invariants on any path that writes
    // a position field.
    require(ghostMiOneMarketTickSpacing > 0,
        "UNSAFE: scalar ghostMiOneMarketTickSpacing > 0 in one-mode (narrowed market is touched)");

    // The scalar mirror is otherwise unanchored to loads (the Sload hook checks
    // only the id-keyed ghost), letting the solver pick a scalar that disagrees
    // with the spacing the code actually reads.
    require(forall bytes32 _id. ghostMiMarketTickSpacing[_id] == 0
        || ghostMiMarketTickSpacing[_id] == ghostMiOneMarketTickSpacing,
        "UNSAFE: one-mode -- every touched market's tickSpacing equals the scalar mirror");

    // One-mode: every touched market shares the same loanToken (take is sole
    // writer of claimableSettlementFee), so claimableSettlementFee[t] is non-zero
    // only for the scalar loanToken.
    require(forall address _t. _t != ghostMiOneMarketLoanToken
        => ghostMiClaimableSettlementFee256[_t] == 0,
        "UNSAFE: claimableSettlementFee non-zero only for ghostMiOneMarketLoanToken (one-mode)");

    // collateralToken[0] sanity. Aliasing with loanToken is permitted; the
    // joint claim+withdrawable+collateral_in_loanToken invariant covers it.
    require(ghostMiOneCollateralToken[0] != 0,
        "UNSAFE: collateralToken[0] set by prior touchMarket");
    require(ghostMiOneCollateralToken[0] != _Midnight,
        "TRUSTED: collateralToken[0] is not the lending contract itself");

    // collateralToken[1] sanity (gated on two-collateral narrowing); restates
    // sorted-tokens require from touchMarketCVL so the proof does not depend on
    // cross-call sort ordering.
    require(ghostNumCollaterals == 1 || (
        ghostMiOneCollateralToken[1] != 0
        && ghostMiOneCollateralToken[1] != _Midnight
        && ghostMiOneCollateralToken[1] != ghostMiOneCollateralToken[0]
    ), "UNSAFE: collateralToken[1] sanity when numCollaterals == 2");

    require(forall address _u.
        VALID_COLLATERAL_BITMAP(ghostMiOnePositionCollateralBitmap128[_u]),
        "UNSAFE: bitmap valid for ghostNumCollaterals");

    require(forall address _u. forall uint256 _i.
        !VALID_COLLATERAL_BIT(_i) => ghostMiOnePositionCollateral128[_u][_i] == 0,
        "UNSAFE: collateral[i] = 0 for i outside VALID_COLLATERAL_BIT");

    require(forall address _u.
        ghostMiOnePositionCollateralLength[_u] == COLLATERAL_ACTIVE_COUNT_ONE(_u),
        "UNSAFE: collateralLength synchronized with non-zero collateral count");

    require(forall address _u.
        ghostMiOnePositionCollateralLength[_u] <= ghostNumCollaterals,
        "UNSAFE: collateralLength <= ghostNumCollaterals");

    require(forall address _u. !VALID_POSITION_USER(_u) => (
        ghostMiOnePositionCredit128[_u] == 0
        && ghostMiOnePositionPendingFee128[_u] == 0
        && ghostMiOnePositionLastLossFactor128[_u] == 0
        && ghostMiOnePositionLastAccrual128[_u] == 0
        && ghostMiOnePositionDebt128[_u] == 0
        && ghostMiOnePositionCollateralBitmap128[_u] == 0
        && ghostMiOnePositionCollateralLength[_u] == 0
    ), "UNSAFE: position fields zeroed for users outside three-user narrowing");

    require(forall address _u. forall uint256 _i.
        !VALID_POSITION_USER(_u) => ghostMiOnePositionCollateral128[_u][_i] == 0,
        "UNSAFE: position collateral zeroed for users outside three-user narrowing");

    // Top-level user-keyed state (consumed, isAuthorized) zeroed for users
    // outside the three-user narrowing -- keeps cross-call quantifier
    // instantiation tractable.
    require(forall address _u. forall bytes32 _g.
        !VALID_POSITION_USER(_u) => ghostMiConsumed256[_u][_g] == 0,
        "UNSAFE: consumed[u][g] zeroed for users outside three-user narrowing");

    // Narrowing is on the owner side only: the two-sided (a||b) form forced
    // isAuthorized[seller][_Callback]==false, making onBehalf-auth take paths UNSAT (MSV/MSC
    // one-regime). Freeing the delegate side only widens the model (sound).
    require(forall address _a. forall address _b.
        !VALID_POSITION_USER(_a) => !ghostMiIsAuthorized[_a][_b],
        "UNSAFE: untracked owners grant no authorization (delegate side free)");
}
