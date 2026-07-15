// perf overlay BorrowBlueToMidnightCallback/many: branches B11, B2 disabled — per the footprint matrix
// they do not intersect the read-set of the listed rules (footprint analysis: branch write-set is disjoint from the rules' read-set).
// RULES: migrationCanFullyCloseOldPosition
// BASE: light
// STUBS: B11,B2
// B7-ELIGIBLE (hashing flags, deferred to keccak inventory): migrationCanFullyCloseOldPosition

import "../many.spec";

methods {
    function Morpho._isHealthy(MorphoHarness.MarketParams memory marketParams, MorphoHarness.Id id,
        address borrower) internal returns (bool) => NONDET;
    function CallbackLib.sellerFeeFromTick(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal returns (uint256) => pfSellerFeeFromTick(tick, feeRate, units, assets);
    function CallbackLib.buyerFeeFromTick(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal returns (uint256) => pfBuyerFeeFromTick(tick, feeRate, units, assets);
    function CallbackLib.percentageFee(uint256 assets, uint256 feeRate)
        internal returns (uint256) => pfPercentageFee(assets, feeRate);
}

// B11: Blue health gate -> NONDET bool (both branches reachable).

// B2: callback fee math -> deterministic UFs (no axioms — no hidden fee bound).
ghost pfSellerFeeFromTick(uint256, uint256, uint256, uint256) returns uint256;
ghost pfBuyerFeeFromTick(uint256, uint256, uint256, uint256) returns uint256;
ghost pfPercentageFee(uint256, uint256) returns uint256;

use rule migrationCanFullyCloseOldPosition;
