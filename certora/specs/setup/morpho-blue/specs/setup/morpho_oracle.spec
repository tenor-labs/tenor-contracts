// ========== Oracle wildcard summary ==========
// IOracle.price() -> NONDET (bounded by oracle ghost in valid_state).
// Extracted from `morpho.spec` so that cross-protocol scenes (e.g.
// midnight + morpho-blue) can drop this import in favour of midnight's
// own `setup/oracle.spec` wildcard summary, which would otherwise
// collide on the same `price()` signature.

methods {
    function _.price() external => NONDET;
}
