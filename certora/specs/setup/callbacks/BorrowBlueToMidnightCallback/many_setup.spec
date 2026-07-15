import "../../midnight/specs/midnight_valid_state_many.spec";
import "../../morpho-blue/specs/morpho_valid_state_many.spec";
import "../../morpho-blue/specs/setup/morpho_lib_many.spec";
import "cmn.spec";

function setupCallbackState(env e) {
    setupManyMidnight(e);
    requireInvariant nonEmptyPositionImpliesTouched(e);
    requireInvariant creditAndDebtMutuallyExclusive(e);
    requireInvariant collateralBitmapMatchesSlot(e);

    setupManyBlue(e);
    requireInvariant nonExistentMarketPositionsZero(e);
    requireInvariant alwaysCollateralized(e);
}

function requireSourceMarketIrmBinding(env e, bytes cbData) {
    MorphoHarness.Id srcBlueId = _Callback.decodeCallbackSourceMarketId(e, cbData);
    address srcBlueIrm = _Callback.decodeCallbackSourceIrm(e, cbData);
    require(ghostMbIrm[srcBlueId] == srcBlueIrm,
        "SAFE: source Blue market stored irm == decoded sourceMarketParams.irm (id<->marketParams binding)");
}
