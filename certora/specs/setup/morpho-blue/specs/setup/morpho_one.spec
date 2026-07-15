// One-market regime: scalar per-market ghosts (no id key) + position narrowing.
//
// Sstore writes for any id; Sload mirror checks force single-id consistency.
// Any path that touches two distinct ids with conflicting values is infeasible
// because the scalar ghost cannot simultaneously equal both values. This
// collapses the multi-market surface to a single symbolic market.

import "./morpho.spec";

function setupOneBlue(env e) {
    setupEnv(e);
    setupERC20();
    // TRUSTED: owner is non-zero
    require(ghostMbOwner != 0,
        "TRUSTED: owner is non-zero -- governance does not call setOwner(address(0))");

    // TRUSTED: created market has non-zero loan token (scalar narrowing)
    require(ghostMbOneLastUpdate128 != 0 => ghostMbOneLoanToken != 0,
        "TRUSTED: created market has non-zero loan token (scalar)");

    // UNSAFE: one-market regime pins the touched market's loanToken to a single
    // non-zero address; this lets ERC20_ACCOUNT_BOUNDS on position hooks stay
    // bound to a stable token across the rule.
    require(ghostMbOneLoanToken != 0,
        "UNSAFE: one-market regime pins to a single non-zero loanToken");
}

// ========== HELPER DEFINITIONS ==========

// Sum of supply shares for the bounded ERC20 accounts of the (single) market loan token
definition SUPPLY_SHARES_SUM_ONE() returns mathint =
    ghostMbOneSupplyShares256[ghostErc20AccountsValues[ghostMbOneLoanToken][0]]
    + ghostMbOneSupplyShares256[ghostErc20AccountsValues[ghostMbOneLoanToken][1]]
    + ghostMbOneSupplyShares256[ghostErc20AccountsValues[ghostMbOneLoanToken][2]]
    + ghostMbOneSupplyShares256[ghostErc20AccountsValues[ghostMbOneLoanToken][3]]
    + ghostMbOneSupplyShares256[ghostErc20AccountsValues[ghostMbOneLoanToken][4]];

// Sum of borrow shares for the bounded ERC20 accounts of the (single) market loan token
definition BORROW_SHARES_SUM_ONE() returns mathint =
    ghostMbOneBorrowShares128[ghostErc20AccountsValues[ghostMbOneLoanToken][0]]
    + ghostMbOneBorrowShares128[ghostErc20AccountsValues[ghostMbOneLoanToken][1]]
    + ghostMbOneBorrowShares128[ghostErc20AccountsValues[ghostMbOneLoanToken][2]]
    + ghostMbOneBorrowShares128[ghostErc20AccountsValues[ghostMbOneLoanToken][3]]
    + ghostMbOneBorrowShares128[ghostErc20AccountsValues[ghostMbOneLoanToken][4]];

// ========== POSITION MAPPING: position[*][user] (scalar over id) ==========

// uint256 position[*][user].supplyShares
persistent ghost mapping(address => mathint) ghostMbOneSupplyShares256 {
    init_state axiom forall address user. ghostMbOneSupplyShares256[user] == 0;
    axiom forall address user.
        ghostMbOneSupplyShares256[user] >= 0 && ghostMbOneSupplyShares256[user] <= max_uint256;
}
hook Sload uint256 val _Morpho.position[KEY MorphoHarness.Id id][KEY address user].supplyShares {
    require(require_uint256(ghostMbOneSupplyShares256[user]) == val,
        "ghost mirror: position[user].supplyShares (one-regime scalar)");
    require(ERC20_ACCOUNT_BOUNDS(ghostMbOneLoanToken, user),
        "SAFE: supply user in bounded account set");
}
hook Sstore _Morpho.position[KEY MorphoHarness.Id id][KEY address user].supplyShares uint256 val {
    ghostMbOneSupplyShares256[user] = val;
}

// uint128 position[*][user].borrowShares
persistent ghost mapping(address => mathint) ghostMbOneBorrowShares128 {
    init_state axiom forall address user. ghostMbOneBorrowShares128[user] == 0;
    axiom forall address user.
        ghostMbOneBorrowShares128[user] >= 0 && ghostMbOneBorrowShares128[user] <= max_uint128;
}
hook Sload uint128 val _Morpho.position[KEY MorphoHarness.Id id][KEY address user].borrowShares {
    require(require_uint128(ghostMbOneBorrowShares128[user]) == val,
        "ghost mirror: position[user].borrowShares (one-regime scalar)");
    require(ERC20_ACCOUNT_BOUNDS(ghostMbOneLoanToken, user),
        "SAFE: borrow user in bounded account set");
}
hook Sstore _Morpho.position[KEY MorphoHarness.Id id][KEY address user].borrowShares uint128 val {
    ghostMbOneBorrowShares128[user] = val;
}

// uint128 position[*][user].collateral
persistent ghost mapping(address => mathint) ghostMbOneCollateral128 {
    init_state axiom forall address user. ghostMbOneCollateral128[user] == 0;
    axiom forall address user.
        ghostMbOneCollateral128[user] >= 0 && ghostMbOneCollateral128[user] <= max_uint128;
}
hook Sload uint128 val _Morpho.position[KEY MorphoHarness.Id id][KEY address user].collateral {
    require(require_uint128(ghostMbOneCollateral128[user]) == val,
        "ghost mirror: position[user].collateral (one-regime scalar)");
    require(ERC20_ACCOUNT_BOUNDS(ghostMbOneCollateralToken, user),
        "SAFE: collateral user in bounded account set");
}
hook Sstore _Morpho.position[KEY MorphoHarness.Id id][KEY address user].collateral uint128 val {
    ghostMbOneCollateral128[user] = val;
}

// ========== MARKET MAPPING: market[*] (scalar over id) ==========

// uint128 market[*].totalSupplyAssets
persistent ghost mathint ghostMbOneTotalSupplyAssets128 {
    init_state axiom ghostMbOneTotalSupplyAssets128 == 0;
    axiom ghostMbOneTotalSupplyAssets128 >= 0 && ghostMbOneTotalSupplyAssets128 <= max_uint128;
}
hook Sload uint128 val _Morpho.market[KEY MorphoHarness.Id id].totalSupplyAssets {
    require(require_uint128(ghostMbOneTotalSupplyAssets128) == val,
        "ghost mirror: market.totalSupplyAssets (one-regime scalar)");
}
hook Sstore _Morpho.market[KEY MorphoHarness.Id id].totalSupplyAssets uint128 val {
    ghostMbOneTotalSupplyAssets128 = val;
}

// uint128 market[*].totalSupplyShares
persistent ghost mathint ghostMbOneTotalSupplyShares128 {
    init_state axiom ghostMbOneTotalSupplyShares128 == 0;
    axiom ghostMbOneTotalSupplyShares128 >= 0 && ghostMbOneTotalSupplyShares128 <= max_uint128;
}
hook Sload uint128 val _Morpho.market[KEY MorphoHarness.Id id].totalSupplyShares {
    require(require_uint128(ghostMbOneTotalSupplyShares128) == val,
        "ghost mirror: market.totalSupplyShares (one-regime scalar)");
}
hook Sstore _Morpho.market[KEY MorphoHarness.Id id].totalSupplyShares uint128 val {
    ghostMbOneTotalSupplyShares128 = val;
}

// uint128 market[*].totalBorrowAssets
persistent ghost mathint ghostMbOneTotalBorrowAssets128 {
    init_state axiom ghostMbOneTotalBorrowAssets128 == 0;
    axiom ghostMbOneTotalBorrowAssets128 >= 0 && ghostMbOneTotalBorrowAssets128 <= max_uint128;
}
hook Sload uint128 val _Morpho.market[KEY MorphoHarness.Id id].totalBorrowAssets {
    require(require_uint128(ghostMbOneTotalBorrowAssets128) == val,
        "ghost mirror: market.totalBorrowAssets (one-regime scalar)");
}
hook Sstore _Morpho.market[KEY MorphoHarness.Id id].totalBorrowAssets uint128 val {
    ghostMbOneTotalBorrowAssets128 = val;
}

// uint128 market[*].totalBorrowShares
persistent ghost mathint ghostMbOneTotalBorrowShares128 {
    init_state axiom ghostMbOneTotalBorrowShares128 == 0;
    axiom ghostMbOneTotalBorrowShares128 >= 0 && ghostMbOneTotalBorrowShares128 <= max_uint128;
}
hook Sload uint128 val _Morpho.market[KEY MorphoHarness.Id id].totalBorrowShares {
    require(require_uint128(ghostMbOneTotalBorrowShares128) == val,
        "ghost mirror: market.totalBorrowShares (one-regime scalar)");
}
hook Sstore _Morpho.market[KEY MorphoHarness.Id id].totalBorrowShares uint128 val {
    ghostMbOneTotalBorrowShares128 = val;
}

// uint128 market[*].lastUpdate
persistent ghost mathint ghostMbOneLastUpdate128 {
    init_state axiom ghostMbOneLastUpdate128 == 0;
    axiom ghostMbOneLastUpdate128 >= 0 && ghostMbOneLastUpdate128 <= max_uint128;
}
hook Sload uint128 val _Morpho.market[KEY MorphoHarness.Id id].lastUpdate {
    require(require_uint128(ghostMbOneLastUpdate128) == val,
        "ghost mirror: market.lastUpdate (one-regime scalar)");
}
hook Sstore _Morpho.market[KEY MorphoHarness.Id id].lastUpdate uint128 val {
    ghostMbOneLastUpdate128 = val;
}

// uint128 market[*].fee
persistent ghost mathint ghostMbOneFee128 {
    init_state axiom ghostMbOneFee128 == 0;
    axiom ghostMbOneFee128 >= 0 && ghostMbOneFee128 <= max_uint128;
}
hook Sload uint128 val _Morpho.market[KEY MorphoHarness.Id id].fee {
    require(require_uint128(ghostMbOneFee128) == val,
        "ghost mirror: market.fee (one-regime scalar)");
}
hook Sstore _Morpho.market[KEY MorphoHarness.Id id].fee uint128 val {
    ghostMbOneFee128 = val;
}

// ========== MARKET PARAMS MAPPING: idToMarketParams[*] (scalar over id) ==========

// address idToMarketParams[*].loanToken
persistent ghost address ghostMbOneLoanToken {
    init_state axiom ghostMbOneLoanToken == 0;
}
hook Sload address val _Morpho.idToMarketParams[KEY MorphoHarness.Id id].loanToken {
    require(ghostMbOneLoanToken == val,
        "ghost mirror: idToMarketParams.loanToken (one-regime scalar)");
}
hook Sstore _Morpho.idToMarketParams[KEY MorphoHarness.Id id].loanToken address val {
    ghostMbOneLoanToken = val;
}

// address idToMarketParams[*].collateralToken
persistent ghost address ghostMbOneCollateralToken {
    init_state axiom ghostMbOneCollateralToken == 0;
}
hook Sload address val _Morpho.idToMarketParams[KEY MorphoHarness.Id id].collateralToken {
    require(ghostMbOneCollateralToken == val,
        "ghost mirror: idToMarketParams.collateralToken (one-regime scalar)");
}
hook Sstore _Morpho.idToMarketParams[KEY MorphoHarness.Id id].collateralToken address val {
    ghostMbOneCollateralToken = val;
}

// address idToMarketParams[*].oracle
persistent ghost address ghostMbOneOracle {
    init_state axiom ghostMbOneOracle == 0;
}
hook Sload address val _Morpho.idToMarketParams[KEY MorphoHarness.Id id].oracle {
    require(ghostMbOneOracle == val,
        "ghost mirror: idToMarketParams.oracle (one-regime scalar)");
}
hook Sstore _Morpho.idToMarketParams[KEY MorphoHarness.Id id].oracle address val {
    ghostMbOneOracle = val;
}

// address idToMarketParams[*].irm
persistent ghost address ghostMbOneIrm {
    init_state axiom ghostMbOneIrm == 0;
}
hook Sload address val _Morpho.idToMarketParams[KEY MorphoHarness.Id id].irm {
    require(ghostMbOneIrm == val,
        "ghost mirror: idToMarketParams.irm (one-regime scalar)");
}
hook Sstore _Morpho.idToMarketParams[KEY MorphoHarness.Id id].irm address val {
    ghostMbOneIrm = val;
}

// uint256 idToMarketParams[*].lltv
persistent ghost mathint ghostMbOneLltv256 {
    init_state axiom ghostMbOneLltv256 == 0;
    axiom ghostMbOneLltv256 >= 0 && ghostMbOneLltv256 <= max_uint256;
}
hook Sload uint256 val _Morpho.idToMarketParams[KEY MorphoHarness.Id id].lltv {
    require(require_uint256(ghostMbOneLltv256) == val,
        "ghost mirror: idToMarketParams.lltv (one-regime scalar)");
}
hook Sstore _Morpho.idToMarketParams[KEY MorphoHarness.Id id].lltv uint256 val {
    ghostMbOneLltv256 = val;
}
