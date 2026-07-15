// MorphoLib + MorphoBalancesLib storage-hook obviazka (many-market).
// Ties MorphoLib.* (raw reads via morpho.extSloads inline assembly,
// which Certora's storage analyzer cannot hook on) and
// MorphoBalancesLib.* (post-accrue projections) to the per-id ghosts
// from morpho_many.spec, so SMT cannot pick divergent values for the
// same slot. MarketParams -> Id via 5-arg deterministic ghost
// (id_lib pattern). Many-market only -- one-market needs a fork.

// ====================================================================
// Section 1 -- MarketParams -> Id deterministic derivation
// ====================================================================

persistent ghost ghostMlibMarketIdGhost(
    address /*loanToken*/, address /*collateralToken*/,
    address /*oracle*/,    address /*irm*/, uint256 /*lltv*/
) returns MorphoHarness.Id;

function ghostMlibMarketIdCVL(MorphoHarness.MarketParams mp)
    returns MorphoHarness.Id
{
    return ghostMlibMarketIdGhost(
        mp.loanToken, mp.collateralToken, mp.oracle, mp.irm,
        require_uint256(to_mathint(mp.lltv))
    );
}

methods {
    function MarketParamsLib.id(MorphoHarness.MarketParams memory mp)
        internal returns (MorphoHarness.Id)
        => ghostMlibMarketIdCVL(mp);
}

// ====================================================================
// Section 2 -- MorphoLib summaries: raw (pre-accrue) reads via the
// per-id storage-hook ghosts declared in morpho_many.spec.
// ====================================================================

methods {
    function MorphoLib.supplyShares(address, MorphoHarness.Id id, address user)
        internal returns (uint256)
        => require_uint256(ghostMbSupplyShares256[id][user]);
    function MorphoLib.borrowShares(address, MorphoHarness.Id id, address user)
        internal returns (uint256)
        => require_uint256(ghostMbBorrowShares128[id][user]);
    function MorphoLib.collateral(address, MorphoHarness.Id id, address user)
        internal returns (uint256)
        => require_uint256(ghostMbCollateral128[id][user]);
    function MorphoLib.totalSupplyAssets(address, MorphoHarness.Id id)
        internal returns (uint256)
        => require_uint256(ghostMbTotalSupplyAssets128[id]);
    function MorphoLib.totalSupplyShares(address, MorphoHarness.Id id)
        internal returns (uint256)
        => require_uint256(ghostMbTotalSupplyShares128[id]);
    function MorphoLib.totalBorrowAssets(address, MorphoHarness.Id id)
        internal returns (uint256)
        => require_uint256(ghostMbTotalBorrowAssets128[id]);
    function MorphoLib.totalBorrowShares(address, MorphoHarness.Id id)
        internal returns (uint256)
        => require_uint256(ghostMbTotalBorrowShares128[id]);
    function MorphoLib.lastUpdate(address, MorphoHarness.Id id)
        internal returns (uint256)
        => require_uint256(ghostMbLastUpdate128[id]);
    function MorphoLib.fee(address, MorphoHarness.Id id)
        internal returns (uint256)
        => require_uint256(ghostMbFee128[id]);
}

// ====================================================================
// Section 3 -- expectedMarketBalancesCVL: mirrors _accrueInterest
//
// Pure post-accrue projection of (totalSupplyAssets, totalSupplyShares,
// totalBorrowAssets, totalBorrowShares) for market `id` at time
// e.block.timestamp. Identical formula to
// MorphoBalancesLib.expectedMarketBalances
// (lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol:33-61)
// and to Morpho._accrueInterest
// (lib/morpho-blue/src/Morpho.sol:482-508), reading inputs from the
// storage-synced ghosts in morpho_many.spec.
//
// Math identity with Morpho.repay: Morpho's _accrueInterest mutates
// the storage hooks (via Sstore) using the same CVL math summaries
// (wTaylorCompoundedCVL / wMulDownCVL / toSharesDownCVL). So after
// _accrueInterest runs in Morpho.repay, ghostMbTotalBorrowAssets128[id]
// == the tBA1 our helper computes here. Both paths converge.
//
// Defensive require: setupManyBlue (in morpho_many.spec) does NOT
// requireInvariant lastUpdateBoundedByTimestamp (that lives in
// setupValidStateManyBlue from morpho_valid_state_many.spec). Without
// the defensive require, elapsed could underflow when consumer skipped
// the valid-state setup.
// ====================================================================

function expectedMarketBalancesCVL(env e, MorphoHarness.Id id)
    returns (uint256, uint256, uint256, uint256)
{
    uint256 tSA = require_uint256(ghostMbTotalSupplyAssets128[id]);
    uint256 tSS = require_uint256(ghostMbTotalSupplyShares128[id]);
    uint256 tBA = require_uint256(ghostMbTotalBorrowAssets128[id]);
    uint256 tBS = require_uint256(ghostMbTotalBorrowShares128[id]);
    uint256 lu  = require_uint256(ghostMbLastUpdate128[id]);
    uint256 fee = require_uint256(ghostMbFee128[id]);
    address irm = ghostMbIrm[id];

    require(to_mathint(e.block.timestamp) >= to_mathint(lu),
        "SAFE: lastUpdateBoundedByTimestamp (defensive; not pulled by setupManyBlue)");
    uint256 elapsed = require_uint256(to_mathint(e.block.timestamp) - to_mathint(lu));

    // Shortcut path mirrors MorphoBalancesLib.sol:44 -- skip when
    // elapsed == 0 || totalBorrowAssets == 0 || irm == 0.
    if (elapsed == 0 || tBA == 0 || irm == 0) {
        return (tSA, tSS, tBA, tBS);
    }

    uint256 rate = ghostMbIrmBorrowRate[irm];
    uint256 taylor = wTaylorCompoundedCVL(rate, elapsed);
    uint256 interest = wMulDownCVL(tBA, taylor);

    uint256 tBA1 = require_uint256(to_mathint(tBA) + to_mathint(interest));
    uint256 tSA1 = require_uint256(to_mathint(tSA) + to_mathint(interest));

    // Match MorphoBalancesLib.sol:50-56 -- feeShares is computed against
    // the PRE-feeShares totalSupplyShares (initial tSS), then added.
    uint256 tSS1;
    if (fee != 0) {
        uint256 feeAmount = wMulDownCVL(interest, fee);
        uint256 tSA1MinusFee = require_uint256(to_mathint(tSA1) - to_mathint(feeAmount));
        uint256 feeShares = toSharesDownCVL(feeAmount, tSA1MinusFee, tSS);
        tSS1 = require_uint256(to_mathint(tSS) + to_mathint(feeShares));
    } else {
        tSS1 = tSS;
    }

    return (tSA1, tSS1, tBA1, tBS);
}

// ====================================================================
// Section 4 -- MorphoBalancesLib summaries (internal with env e).
//
// Pattern reference: lib/morpho-blue/certora/specs/Liveness.spec:19.
// ====================================================================

methods {
    function MorphoBalancesLib.expectedMarketBalances(
        address, MorphoHarness.MarketParams memory mp
    ) internal returns (uint256, uint256, uint256, uint256) with (env e)
        => mblibExpectedMarketBalancesCVL(e, mp);

    function MorphoBalancesLib.expectedTotalSupplyAssets(
        address, MorphoHarness.MarketParams memory mp
    ) internal returns (uint256) with (env e)
        => mblibExpectedTotalSupplyAssetsCVL(e, mp);

    function MorphoBalancesLib.expectedTotalBorrowAssets(
        address, MorphoHarness.MarketParams memory mp
    ) internal returns (uint256) with (env e)
        => mblibExpectedTotalBorrowAssetsCVL(e, mp);

    function MorphoBalancesLib.expectedTotalSupplyShares(
        address, MorphoHarness.MarketParams memory mp
    ) internal returns (uint256) with (env e)
        => mblibExpectedTotalSupplySharesCVL(e, mp);

    function MorphoBalancesLib.expectedSupplyAssets(
        address, MorphoHarness.MarketParams memory mp, address user
    ) internal returns (uint256) with (env e)
        => mblibExpectedSupplyAssetsCVL(e, mp, user);

    function MorphoBalancesLib.expectedBorrowAssets(
        address, MorphoHarness.MarketParams memory mp, address user
    ) internal returns (uint256) with (env e)
        => mblibExpectedBorrowAssetsCVL(e, mp, user);
}

// ====================================================================
// Section 5 -- Wrappers for the summaries. All read inputs from
// storage-hook ghosts (morpho_many.spec); none introduce new state.
// ====================================================================

function mblibExpectedMarketBalancesCVL(env e, MorphoHarness.MarketParams mp)
    returns (uint256, uint256, uint256, uint256)
{
    uint256 r0; uint256 r1; uint256 r2; uint256 r3;
    r0, r1, r2, r3 = expectedMarketBalancesCVL(e, ghostMlibMarketIdCVL(mp));
    return (r0, r1, r2, r3);
}

function mblibExpectedTotalSupplyAssetsCVL(env e, MorphoHarness.MarketParams mp)
    returns uint256
{
    uint256 r0; uint256 r1; uint256 r2; uint256 r3;
    r0, r1, r2, r3 = expectedMarketBalancesCVL(e, ghostMlibMarketIdCVL(mp));
    return r0;
}

function mblibExpectedTotalSupplySharesCVL(env e, MorphoHarness.MarketParams mp)
    returns uint256
{
    uint256 r0; uint256 r1; uint256 r2; uint256 r3;
    r0, r1, r2, r3 = expectedMarketBalancesCVL(e, ghostMlibMarketIdCVL(mp));
    return r1;
}

function mblibExpectedTotalBorrowAssetsCVL(env e, MorphoHarness.MarketParams mp)
    returns uint256
{
    uint256 r0; uint256 r1; uint256 r2; uint256 r3;
    r0, r1, r2, r3 = expectedMarketBalancesCVL(e, ghostMlibMarketIdCVL(mp));
    return r2;
}

function mblibExpectedSupplyAssetsCVL(env e, MorphoHarness.MarketParams mp, address user)
    returns uint256
{
    MorphoHarness.Id id = ghostMlibMarketIdCVL(mp);
    uint256 r0; uint256 r1; uint256 r2; uint256 r3;
    r0, r1, r2, r3 = expectedMarketBalancesCVL(e, id);
    uint256 shares = require_uint256(ghostMbSupplyShares256[id][user]);
    return toAssetsDownCVL(shares, r0, r1);
}

function mblibExpectedBorrowAssetsCVL(env e, MorphoHarness.MarketParams mp, address user)
    returns uint256
{
    MorphoHarness.Id id = ghostMlibMarketIdCVL(mp);
    uint256 r0; uint256 r1; uint256 r2; uint256 r3;
    r0, r1, r2, r3 = expectedMarketBalancesCVL(e, id);
    uint256 shares = require_uint256(ghostMbBorrowShares128[id][user]);
    return toAssetsUpCVL(shares, r2, r3);
}
