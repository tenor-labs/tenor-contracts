// perf overlay MidnightSupplyCollateralCallback/one: branches B13 disabled — per the footprint matrix
// they do not intersect the read-set of the listed rules (footprint analysis: branch write-set is disjoint from the rules' read-set).
// RULES: proRataUpperBound
// BASE: light
// STUBS: B13
// SATISFY-TWINS (re-check non-vacuity under the same overlay): proRataUpperBound

import "../one.spec";
import "../debug_satisfy/one_satisfy.spec";

methods {
    function MidnightSupplyCollateralCallback._borrowCapacityUsage(MidnightHarness.Market memory market,
        address borrower, bytes32 marketId) internal returns (uint256) => NONDET;
}

// B13: bcu gate after the supply cycle, no writes -> NONDET.

use rule proRataUpperBound;
use rule proRataUpperBound__satisfy;
