// perf overlay BorrowMidnightRenewalCallback/many: branches B10, B4, B8 disabled — per the footprint matrix
// they do not intersect the read-set of the listed rules (footprint analysis: branch write-set is disjoint from the rules' read-set).
// RULES: renewalCannotMoveMoreCollateralThanWithdrawn
// BASE: light
// STUBS: B10,B4,B8
// SATISFY-TWINS (re-check non-vacuity under the same overlay): renewalCannotMoveMoreCollateralThanWithdrawn

import "../many.spec";
import "../debug_satisfy/many_satisfy.spec";

methods {
    function MidnightHarness.isHealthy(MidnightHarness.Market memory market, bytes32 id, address borrower)
        internal returns (bool) => NONDET;
    function MidnightHarness.settlementFee(bytes32 id, uint256 timeToMaturity)
        internal returns (uint256) => pfSettlementFee(id, timeToMaturity);
    function MidnightHarness.updatePositionView(MidnightHarness.Market market, bytes32 id, address user)
        external returns (uint128, uint128, uint128) => NONDET;
}

// B10: Midnight health gate -> NONDET bool (both branches reachable; not force-true).

// B4 (partial): settlementFee -> UF; the inline mulDiv in take's body is not covered by this stub.
ghost pfSettlementFee(bytes32, uint256) returns uint256;

// B8: view leg only (the write leg _updatePosition must NOT be summarized —
// ghost-only writes break hook-sync -> silent vacuity).

use rule renewalCannotMoveMoreCollateralThanWithdrawn;
use rule renewalCannotMoveMoreCollateralThanWithdrawn__satisfy;
