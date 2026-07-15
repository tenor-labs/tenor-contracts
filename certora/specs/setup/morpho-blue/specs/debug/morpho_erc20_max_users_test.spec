// Debug: Proves MAX_ERC20_USERS=5 is sufficient for Morpho.
// Tracks ALL ERC20 account accesses (reads + writes) via ghostERC20AccountAccessed.
// Takes 5 users from the bounded set, asserts at least one was NOT accessed.
// This proves at most 4 accounts are touched per call per token, so 5 slots is sufficient.
import "../morpho_valid_state.spec";

rule erc20MaxUsersAccessed(method f, env e, calldataarg args) {

    // Reset access tracking
    require(forall address t. forall address a.
        ghostERC20AccountAccessed[t][a] == false);

    setupValidStateMB(e);

    // Any token -- Prover explores all possible token addresses
    address token;
    require(token != 0);

    // The 5 bounded accounts for this token
    address u1 = ghostErc20AccountsValues[token][0];
    address u2 = ghostErc20AccountsValues[token][1];
    address u3 = ghostErc20AccountsValues[token][2];
    address u4 = ghostErc20AccountsValues[token][3];
    address u5 = ghostErc20AccountsValues[token][4];

    f(e, args);

    // From 5 bounded accounts, at least one was NOT accessed
    // Proves max 4 accounts touched per call per token, so 5 is safe
    assert(
        !ghostERC20AccountAccessed[token][u1] ||
        !ghostERC20AccountAccessed[token][u2] ||
        !ghostERC20AccountAccessed[token][u3] ||
        !ghostERC20AccountAccessed[token][u4] ||
        !ghostERC20AccountAccessed[token][u5],
        "SAFE: at most 4 of 5 bounded accounts accessed per call per token"
    );
}
