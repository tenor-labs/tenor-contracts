// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LastFridayOfMonthCadence} from "../../src/ratifiers/policies/LastFridayOfMonthCadence.sol";
import {
    BOUNDARY_TIME_OF_DAY,
    DOMAIN_START,
    DOMAIN_END,
    isFridayAt,
    isLastFridayOfMonth
} from "../helpers/CadenceTestConstants.sol";

/// @dev Walks the cadence forward through time in random increments, latching any property
/// violation into a flag rather than reverting, so the campaign reports the first counterexample
/// with the timestamps that produced it.
/// @dev The cadence is pure, so the state that matters is not the contract's but the walk's: the
/// handler carries the previous (timestamp, boundary) pair across calls. That is what the unit
/// fuzz tests cannot do. They sample isolated points, while a walk crosses month, year, and leap
/// boundaries in sequence, which is where an ordering inversion would surface.
contract CadenceWalkHandler is Test {
    LastFridayOfMonthCadence public immutable CADENCE;

    uint256 public previousTimestamp;
    uint256 public previousBoundary;

    /// @dev Set on the first violation of each property, with the inputs that caused it.
    bool public monotonicityViolated;
    bool public futureBoundaryReturned;
    bool public notFixedPoint;
    bool public notFridayAtBoundaryTime;
    bool public notLastFridayOfMonth;
    bool public boundarySkipped;
    uint256 public failingTimestamp;
    uint256 public failingBoundary;
    uint256 public failingPreviousTimestamp;
    uint256 public failingPreviousBoundary;

    constructor(LastFridayOfMonthCadence cadence) {
        CADENCE = cadence;
    }

    /// @dev Steps forward by up to 400 days (long enough to skip a whole month, so transitions are
    /// crossed both one day and one month at a time), reseeding anywhere in the domain on overflow.
    /// @dev The reseed is a fuzzed point rather than the domain floor because a sequence of a few hundred
    /// calls advances only ~80 years at 400 days a step. Always restarting at DOMAIN_START (1970) therefore
    /// confined every run to roughly 1970-2050 - short of the fixture's 2125 horizon, so the whole region
    /// where no golden value exists, which is exactly what the campaign is here to cover, was never walked.
    /// Reseeding at random spreads the runs over the full domain instead.
    function walk(uint256 step) external {
        uint256 timestamp = previousTimestamp == 0 || previousTimestamp > DOMAIN_END - 400 days
            ? bound(step, DOMAIN_START, DOMAIN_END)
            : previousTimestamp + bound(step, 1, 400 days);
        uint256 boundary = CADENCE.cadencePeriodStart(timestamp);

        if (timestamp >= previousTimestamp && boundary < previousBoundary) {
            monotonicityViolated = true;
            _record(timestamp, boundary);
        }
        _checkPointProperties(timestamp, boundary);

        previousTimestamp = timestamp;
        previousBoundary = boundary;
    }

    /// @dev Re-enters at the boundary the walk last produced and at its immediate neighbours, so the
    /// fixed point and the one-second-before rollback are exercised on real boundaries rather than
    /// on randomly sampled timestamps.
    function probeBoundaryNeighbourhood() external {
        uint256 boundary = previousBoundary;
        if (boundary <= DOMAIN_START) return;
        _checkPointProperties(boundary, CADENCE.cadencePeriodStart(boundary));
        _checkPointProperties(boundary + 1, CADENCE.cadencePeriodStart(boundary + 1));
        _checkPointProperties(boundary - 1, CADENCE.cadencePeriodStart(boundary - 1));
    }

    function _checkPointProperties(uint256 timestamp, uint256 boundary) private {
        // BaseMigrationRatifier._ratifyWindow reverts if the cadence returns a future period start.
        if (boundary > timestamp) {
            futureBoundaryReturned = true;
            _record(timestamp, boundary);
        }
        // BaseMigrationRatifier._validateTargetMaturity accepts a maturity only if it is a fixed point.
        if (CADENCE.cadencePeriodStart(boundary) != boundary) {
            notFixedPoint = true;
            _record(timestamp, boundary);
        }
        if (!isFridayAt(boundary, BOUNDARY_TIME_OF_DAY)) {
            notFridayAtBoundaryTime = true;
            _record(timestamp, boundary);
        }
        // Being a Friday, at or before the input, a fixed point and within five weeks are all true of the
        // second-to-last Friday of each month too, so without this the walk cannot tell the two series apart.
        if (!isLastFridayOfMonth(boundary)) {
            notLastFridayOfMonth = true;
            _record(timestamp, boundary);
        }
        // Consecutive last Fridays are 28 or 35 days apart, so a gap over 35 days skipped one.
        if (boundary + 35 days <= timestamp) {
            boundarySkipped = true;
            _record(timestamp, boundary);
        }
    }

    /// @dev Keeps the inputs behind the first failure only, so later calls cannot overwrite them.
    function _record(uint256 timestamp, uint256 boundary) private {
        if (failingTimestamp != 0) return;
        failingTimestamp = timestamp;
        failingBoundary = boundary;
        failingPreviousTimestamp = previousTimestamp;
        failingPreviousBoundary = previousBoundary;
    }
}

/// @notice Stateful campaign over sequences of increasing timestamps, complementing the
/// point-sampled fuzz tests in test/unit/LastFridayOfMonthCadence.t.sol.
/// @dev fail-on-revert stays on: every handler input is bounded into the documented valid domain,
/// so a revert is itself a failure (the cadence must not revert anywhere at or after its floor).
contract LastFridayOfMonthCadenceInvariantTest is Test {
    CadenceWalkHandler internal handler;

    function setUp() public {
        handler = new CadenceWalkHandler(new LastFridayOfMonthCadence(BOUNDARY_TIME_OF_DAY));
        targetContract(address(handler));
    }

    /// @dev fail-on-revert is set per invariant, not once for the contract, because Foundry binds
    /// the directive to the function it annotates. Without it on every one, a mutant that makes the
    /// cadence revert would be silently tolerated: the handler calls would be discarded and the
    /// remaining invariants would pass without ever evaluating their property.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_monotonicAcrossTime() public view {
        assertFalse(handler.monotonicityViolated(), "later timestamp mapped to an earlier boundary");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_neverReturnsFutureBoundary() public view {
        assertFalse(handler.futureBoundaryReturned(), "period start is after the queried timestamp");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_boundariesAreFixedPoints() public view {
        assertFalse(handler.notFixedPoint(), "boundary does not map to itself");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_boundariesAreFridaysAtBoundaryTime() public view {
        assertFalse(handler.notFridayAtBoundaryTime(), "boundary is not a Friday at 15:00:00 UTC");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_boundariesAreLastFridaysOfTheirMonth() public view {
        assertFalse(handler.notLastFridayOfMonth(), "boundary is not the last Friday of its month");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_noBoundarySkipped() public view {
        assertFalse(handler.boundarySkipped(), "boundary is more than five weeks before the timestamp");
    }
}
