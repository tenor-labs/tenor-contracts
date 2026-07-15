// perf overlay LendVaultToMidnightCallback/many: branches B4 disabled — per the footprint matrix
// they do not intersect the read-set of the listed rules (footprint analysis: branch write-set is disjoint from the rules' read-set).
// RULES: callbackHoldsZeroAllowance positiveFeeIsPayable
// BASE: light
// STUBS: B4
// B7-ELIGIBLE (hashing flags, deferred to keccak inventory): callbackHoldsZeroAllowance
// SATISFY-TWINS (re-check non-vacuity under the same overlay): callbackHoldsZeroAllowance

import "../many.spec";
import "../debug_satisfy/many_satisfy.spec";

methods {
    function MidnightHarness.settlementFee(bytes32 id, uint256 timeToMaturity)
        internal returns (uint256) => pfSettlementFee(id, timeToMaturity);
}

// B4 (partial): settlementFee -> UF; the inline mulDiv in take's body is not covered by this stub.
ghost pfSettlementFee(bytes32, uint256) returns uint256;

use rule callbackHoldsZeroAllowance;
use rule positiveFeeIsPayable;
use rule callbackHoldsZeroAllowance__satisfy;
