// perf overlay MidnightSupplyCollateralCallback/many: branches B13, B2, B4 disabled — per the footprint matrix
// they do not intersect the read-set of the listed rules (footprint analysis: branch write-set is disjoint from the rules' read-set).
// RULES: supplyMonotoneCollateral
// BASE: light
// STUBS: B13,B2,B4
// B7-ELIGIBLE (hashing flags, deferred to keccak inventory): supplyMonotoneCollateral

import "../many.spec";

methods {
    function MidnightSupplyCollateralCallback._borrowCapacityUsage(MidnightHarness.Market memory market,
        address borrower, bytes32 marketId) internal returns (uint256) => NONDET;
    function CallbackLib.sellerFeeFromTick(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal returns (uint256) => pfSellerFeeFromTick(tick, feeRate, units, assets);
    function CallbackLib.buyerFeeFromTick(uint256 tick, uint256 feeRate, uint256 units, uint256 assets)
        internal returns (uint256) => pfBuyerFeeFromTick(tick, feeRate, units, assets);
    function CallbackLib.percentageFee(uint256 assets, uint256 feeRate)
        internal returns (uint256) => pfPercentageFee(assets, feeRate);
    function MidnightHarness.settlementFee(bytes32 id, uint256 timeToMaturity)
        internal returns (uint256) => pfSettlementFee(id, timeToMaturity);
}

// B13: bcu gate after the supply cycle, no writes -> NONDET.

// B2: callback fee math -> deterministic UFs (no axioms — no hidden fee bound).
ghost pfSellerFeeFromTick(uint256, uint256, uint256, uint256) returns uint256;
ghost pfBuyerFeeFromTick(uint256, uint256, uint256, uint256) returns uint256;
ghost pfPercentageFee(uint256, uint256) returns uint256;

// B4 (partial): settlementFee -> UF; the inline mulDiv in take's body is not covered by this stub.
ghost pfSettlementFee(bytes32, uint256) returns uint256;

use rule supplyMonotoneCollateral;
