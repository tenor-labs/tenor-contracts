// Debug: Morpho reachability -- proves every function is reachable with valid state.
import "../morpho_valid_state.spec";

rule sanityValidState(env e, method f, calldataarg args) {
    setupValidStateMB(e);
    f(e, args);
    satisfy(true, "sanity check reachable");
}
