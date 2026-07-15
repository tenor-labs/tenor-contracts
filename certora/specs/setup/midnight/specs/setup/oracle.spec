// Oracle.price() summary backed by a per-oracle ghost mapping (well-behaved positive branch).

methods {
    function _.price() external => oraclePriceCVL(calledContract) expect uint256;
}

persistent ghost mapping(address => mathint) ghostMiOraclePrice256 {
    init_state axiom forall address o. ghostMiOraclePrice256[o] == 0;
    axiom forall address o.
        ghostMiOraclePrice256[o] >= 0 && ghostMiOraclePrice256[o] <= max_uint128;
}

function oraclePriceCVL(address oracle) returns uint256 {
    return require_uint256(ghostMiOraclePrice256[oracle]);
}

function setupOracle() {
    // Zero-return branch covered by separate edge-case rules.
    require(forall address o. ghostMiOraclePrice256[o] >= 1,
        "SAFE: oracle returns positive price (well-behaved branch)");
}
