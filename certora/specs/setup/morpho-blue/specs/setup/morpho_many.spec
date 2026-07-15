// Many-market regime: per-id ghosts mirroring storage; consumed by
// `morpho_valid_state_many.spec` and the seven non-valid-state specs.
//
// Invariant set is the full `forall MorphoHarness.Id id.` form; the prover
// reasons over an unbounded set of touched markets. Shared base
// (`morpho.spec`) holds methods block, constants, and non-id-keyed ghosts.

import "./morpho.spec";

function setupManyBlue(env e) {
    setupEnv(e);
    setupERC20();
    // TRUSTED: owner is non-zero
    // Rationale: constructor enforces owner != address(0). setOwner only checks
    // newOwner != owner, not newOwner != 0. Governance discipline prevents
    // self-destructing ownership by calling setOwner(address(0)).
    require(ghostMbOwner != 0,
        "TRUSTED: owner is non-zero -- governance does not call setOwner(address(0))");

    // TRUSTED: created markets have non-zero loan token
    // Rationale: createMarket does not validate loanToken != address(0). A market
    // with zero-address loanToken would be non-functional (safeTransfer reverts).
    // Trusted assumption: market creators do not use zero-address tokens.
    require(forall MorphoHarness.Id id. ghostMbLastUpdate128[id] != 0
        => ghostMbLoanToken[id] != 0,
        "TRUSTED: created markets have non-zero loan token");
}

// ========== HELPER DEFINITIONS ==========

// Sum of supply shares for the bounded ERC20 accounts of a market's loan token
definition SUPPLY_SHARES_SUM(MorphoHarness.Id id) returns mathint =
    ghostMbSupplyShares256[id][ghostErc20AccountsValues[ghostMbLoanToken[id]][0]]
    + ghostMbSupplyShares256[id][ghostErc20AccountsValues[ghostMbLoanToken[id]][1]]
    + ghostMbSupplyShares256[id][ghostErc20AccountsValues[ghostMbLoanToken[id]][2]]
    + ghostMbSupplyShares256[id][ghostErc20AccountsValues[ghostMbLoanToken[id]][3]]
    + ghostMbSupplyShares256[id][ghostErc20AccountsValues[ghostMbLoanToken[id]][4]];

// Sum of borrow shares for the bounded ERC20 accounts of a market's loan token
definition BORROW_SHARES_SUM(MorphoHarness.Id id) returns mathint =
    ghostMbBorrowShares128[id][ghostErc20AccountsValues[ghostMbLoanToken[id]][0]]
    + ghostMbBorrowShares128[id][ghostErc20AccountsValues[ghostMbLoanToken[id]][1]]
    + ghostMbBorrowShares128[id][ghostErc20AccountsValues[ghostMbLoanToken[id]][2]]
    + ghostMbBorrowShares128[id][ghostErc20AccountsValues[ghostMbLoanToken[id]][3]]
    + ghostMbBorrowShares128[id][ghostErc20AccountsValues[ghostMbLoanToken[id]][4]];

// ========== POSITION MAPPING: position[id][user] ==========

// uint256 position[id][user].supplyShares
persistent ghost mapping(MorphoHarness.Id => mapping(address => mathint)) ghostMbSupplyShares256 {
    init_state axiom forall MorphoHarness.Id id. forall address user.
        ghostMbSupplyShares256[id][user] == 0;
    axiom forall MorphoHarness.Id id. forall address user.
        ghostMbSupplyShares256[id][user] >= 0 && ghostMbSupplyShares256[id][user] <= max_uint256;
}
hook Sload uint256 val _Morpho.position[KEY MorphoHarness.Id id][KEY address user].supplyShares {
    require(require_uint256(ghostMbSupplyShares256[id][user]) == val,
        "SAFE: ghost sync supplyShares");
    require(ERC20_ACCOUNT_BOUNDS(ghostMbLoanToken[id], user),
        "SAFE: supply user in bounded account set");
}
hook Sstore _Morpho.position[KEY MorphoHarness.Id id][KEY address user].supplyShares uint256 val {
    ghostMbSupplyShares256[id][user] = val;
}

// uint128 position[id][user].borrowShares
persistent ghost mapping(MorphoHarness.Id => mapping(address => mathint)) ghostMbBorrowShares128 {
    init_state axiom forall MorphoHarness.Id id. forall address user.
        ghostMbBorrowShares128[id][user] == 0;
    axiom forall MorphoHarness.Id id. forall address user.
        ghostMbBorrowShares128[id][user] >= 0 && ghostMbBorrowShares128[id][user] <= max_uint128;
}
hook Sload uint128 val _Morpho.position[KEY MorphoHarness.Id id][KEY address user].borrowShares {
    require(require_uint128(ghostMbBorrowShares128[id][user]) == val,
        "SAFE: ghost sync borrowShares");
    require(ERC20_ACCOUNT_BOUNDS(ghostMbLoanToken[id], user),
        "SAFE: borrow user in bounded account set");
}
hook Sstore _Morpho.position[KEY MorphoHarness.Id id][KEY address user].borrowShares uint128 val {
    ghostMbBorrowShares128[id][user] = val;
}

// uint128 position[id][user].collateral
persistent ghost mapping(MorphoHarness.Id => mapping(address => mathint)) ghostMbCollateral128 {
    init_state axiom forall MorphoHarness.Id id. forall address user.
        ghostMbCollateral128[id][user] == 0;
    axiom forall MorphoHarness.Id id. forall address user.
        ghostMbCollateral128[id][user] >= 0 && ghostMbCollateral128[id][user] <= max_uint128;
}
hook Sload uint128 val _Morpho.position[KEY MorphoHarness.Id id][KEY address user].collateral {
    require(require_uint128(ghostMbCollateral128[id][user]) == val,
        "SAFE: ghost sync collateral");
    require(ERC20_ACCOUNT_BOUNDS(ghostMbCollateralToken[id], user),
        "SAFE: collateral user in bounded account set");
}
hook Sstore _Morpho.position[KEY MorphoHarness.Id id][KEY address user].collateral uint128 val {
    ghostMbCollateral128[id][user] = val;
}

// ========== MARKET MAPPING: market[id] ==========

// uint128 market[id].totalSupplyAssets
persistent ghost mapping(MorphoHarness.Id => mathint) ghostMbTotalSupplyAssets128 {
    init_state axiom forall MorphoHarness.Id id. ghostMbTotalSupplyAssets128[id] == 0;
    axiom forall MorphoHarness.Id id.
        ghostMbTotalSupplyAssets128[id] >= 0 && ghostMbTotalSupplyAssets128[id] <= max_uint128;
}
hook Sload uint128 val _Morpho.market[KEY MorphoHarness.Id id].totalSupplyAssets {
    require(require_uint128(ghostMbTotalSupplyAssets128[id]) == val,
        "SAFE: ghost sync totalSupplyAssets");
}
hook Sstore _Morpho.market[KEY MorphoHarness.Id id].totalSupplyAssets uint128 val {
    ghostMbTotalSupplyAssets128[id] = val;
}

// uint128 market[id].totalSupplyShares
persistent ghost mapping(MorphoHarness.Id => mathint) ghostMbTotalSupplyShares128 {
    init_state axiom forall MorphoHarness.Id id. ghostMbTotalSupplyShares128[id] == 0;
    axiom forall MorphoHarness.Id id.
        ghostMbTotalSupplyShares128[id] >= 0 && ghostMbTotalSupplyShares128[id] <= max_uint128;
}
hook Sload uint128 val _Morpho.market[KEY MorphoHarness.Id id].totalSupplyShares {
    require(require_uint128(ghostMbTotalSupplyShares128[id]) == val,
        "SAFE: ghost sync totalSupplyShares");
}
hook Sstore _Morpho.market[KEY MorphoHarness.Id id].totalSupplyShares uint128 val {
    ghostMbTotalSupplyShares128[id] = val;
}

// uint128 market[id].totalBorrowAssets
persistent ghost mapping(MorphoHarness.Id => mathint) ghostMbTotalBorrowAssets128 {
    init_state axiom forall MorphoHarness.Id id. ghostMbTotalBorrowAssets128[id] == 0;
    axiom forall MorphoHarness.Id id.
        ghostMbTotalBorrowAssets128[id] >= 0 && ghostMbTotalBorrowAssets128[id] <= max_uint128;
}
hook Sload uint128 val _Morpho.market[KEY MorphoHarness.Id id].totalBorrowAssets {
    require(require_uint128(ghostMbTotalBorrowAssets128[id]) == val,
        "SAFE: ghost sync totalBorrowAssets");
}
hook Sstore _Morpho.market[KEY MorphoHarness.Id id].totalBorrowAssets uint128 val {
    ghostMbTotalBorrowAssets128[id] = val;
}

// uint128 market[id].totalBorrowShares
persistent ghost mapping(MorphoHarness.Id => mathint) ghostMbTotalBorrowShares128 {
    init_state axiom forall MorphoHarness.Id id. ghostMbTotalBorrowShares128[id] == 0;
    axiom forall MorphoHarness.Id id.
        ghostMbTotalBorrowShares128[id] >= 0 && ghostMbTotalBorrowShares128[id] <= max_uint128;
}
hook Sload uint128 val _Morpho.market[KEY MorphoHarness.Id id].totalBorrowShares {
    require(require_uint128(ghostMbTotalBorrowShares128[id]) == val,
        "SAFE: ghost sync totalBorrowShares");
}
hook Sstore _Morpho.market[KEY MorphoHarness.Id id].totalBorrowShares uint128 val {
    ghostMbTotalBorrowShares128[id] = val;
}

// uint128 market[id].lastUpdate
persistent ghost mapping(MorphoHarness.Id => mathint) ghostMbLastUpdate128 {
    init_state axiom forall MorphoHarness.Id id. ghostMbLastUpdate128[id] == 0;
    axiom forall MorphoHarness.Id id.
        ghostMbLastUpdate128[id] >= 0 && ghostMbLastUpdate128[id] <= max_uint128;
}
hook Sload uint128 val _Morpho.market[KEY MorphoHarness.Id id].lastUpdate {
    require(require_uint128(ghostMbLastUpdate128[id]) == val,
        "SAFE: ghost sync lastUpdate");
}
hook Sstore _Morpho.market[KEY MorphoHarness.Id id].lastUpdate uint128 val {
    ghostMbLastUpdate128[id] = val;
}

// uint128 market[id].fee
persistent ghost mapping(MorphoHarness.Id => mathint) ghostMbFee128 {
    init_state axiom forall MorphoHarness.Id id. ghostMbFee128[id] == 0;
    axiom forall MorphoHarness.Id id.
        ghostMbFee128[id] >= 0 && ghostMbFee128[id] <= max_uint128;
}
hook Sload uint128 val _Morpho.market[KEY MorphoHarness.Id id].fee {
    require(require_uint128(ghostMbFee128[id]) == val, "SAFE: ghost sync fee");
}
hook Sstore _Morpho.market[KEY MorphoHarness.Id id].fee uint128 val {
    ghostMbFee128[id] = val;
}

// ========== MARKET PARAMS MAPPING: idToMarketParams[id] ==========

// address idToMarketParams[id].loanToken
persistent ghost mapping(MorphoHarness.Id => address) ghostMbLoanToken {
    init_state axiom forall MorphoHarness.Id id. ghostMbLoanToken[id] == 0;
}
hook Sload address val _Morpho.idToMarketParams[KEY MorphoHarness.Id id].loanToken {
    require(ghostMbLoanToken[id] == val, "SAFE: ghost sync loanToken");
}
hook Sstore _Morpho.idToMarketParams[KEY MorphoHarness.Id id].loanToken address val {
    ghostMbLoanToken[id] = val;
}

// address idToMarketParams[id].collateralToken
persistent ghost mapping(MorphoHarness.Id => address) ghostMbCollateralToken {
    init_state axiom forall MorphoHarness.Id id. ghostMbCollateralToken[id] == 0;
}
hook Sload address val _Morpho.idToMarketParams[KEY MorphoHarness.Id id].collateralToken {
    require(ghostMbCollateralToken[id] == val, "SAFE: ghost sync collateralToken");
}
hook Sstore _Morpho.idToMarketParams[KEY MorphoHarness.Id id].collateralToken address val {
    ghostMbCollateralToken[id] = val;
}

// address idToMarketParams[id].oracle
persistent ghost mapping(MorphoHarness.Id => address) ghostMbOracle {
    init_state axiom forall MorphoHarness.Id id. ghostMbOracle[id] == 0;
}
hook Sload address val _Morpho.idToMarketParams[KEY MorphoHarness.Id id].oracle {
    require(ghostMbOracle[id] == val, "SAFE: ghost sync oracle");
}
hook Sstore _Morpho.idToMarketParams[KEY MorphoHarness.Id id].oracle address val {
    ghostMbOracle[id] = val;
}

// address idToMarketParams[id].irm
persistent ghost mapping(MorphoHarness.Id => address) ghostMbIrm {
    init_state axiom forall MorphoHarness.Id id. ghostMbIrm[id] == 0;
}
hook Sload address val _Morpho.idToMarketParams[KEY MorphoHarness.Id id].irm {
    require(ghostMbIrm[id] == val, "SAFE: ghost sync irm");
}
hook Sstore _Morpho.idToMarketParams[KEY MorphoHarness.Id id].irm address val {
    ghostMbIrm[id] = val;
}

// uint256 idToMarketParams[id].lltv
persistent ghost mapping(MorphoHarness.Id => mathint) ghostMbLltv256 {
    init_state axiom forall MorphoHarness.Id id. ghostMbLltv256[id] == 0;
    axiom forall MorphoHarness.Id id.
        ghostMbLltv256[id] >= 0 && ghostMbLltv256[id] <= max_uint256;
}
hook Sload uint256 val _Morpho.idToMarketParams[KEY MorphoHarness.Id id].lltv {
    require(require_uint256(ghostMbLltv256[id]) == val, "SAFE: ghost sync lltv");
}
hook Sstore _Morpho.idToMarketParams[KEY MorphoHarness.Id id].lltv uint256 val {
    ghostMbLltv256[id] = val;
}
