import "../../midnight/specs/midnight_valid_state_many.spec";
import "../../morpho-blue/specs/morpho_valid_state_many.spec";
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
