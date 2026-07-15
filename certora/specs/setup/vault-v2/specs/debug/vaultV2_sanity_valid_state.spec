import "../vaultV2_valid_state.spec";

rule sanityValidState(env e, method f, calldataarg args)
filtered { f -> !EXCLUDED_FUNCTION_VA(f) } {
    setupValidStateVaultV2(e);
    f(e, args);
    satisfy(true, "sanityValidState: reachable");
}
