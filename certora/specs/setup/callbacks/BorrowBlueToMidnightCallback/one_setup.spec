import "../../midnight/specs/midnight_valid_state_one.spec";
import "../../morpho-blue/specs/morpho_valid_state_one.spec";
import "cmn.spec";

function setupCallbackState(env e) {
    setupValidStateOneMidnight(e);
    setupValidStateOneBlue(e);
}

// One-market: no ghostMbIrm, so binding is a no-op.
function requireSourceMarketIrmBinding(env e, bytes cbData) {
}
