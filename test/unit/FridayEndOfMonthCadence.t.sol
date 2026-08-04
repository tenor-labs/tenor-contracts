// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test, stdError} from "forge-std/Test.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";
import {FridayEndOfMonthCadence} from "../../src/ratifiers/policies/FridayEndOfMonthCadence.sol";

contract FridayEndOfMonthCadenceTest is Test {
    FridayEndOfMonthCadence cadence;

    uint256 constant SECONDS_PER_DAY = 86400;
    /// @dev Boundaries fall at 15:00:00 UTC, the maturity time used across Tenor markets.
    uint256 constant BOUNDARY_TIME_OF_DAY = 15 hours;
    /// @dev 2026-01-30 15:00:00 UTC, last Friday of January 2026 (the first market month).
    uint256 constant FIRST_BOUNDARY = 1769785200;
    /// @dev 2025-12-26 15:00:00 UTC, last Friday of the month preceding the first market maturity.
    uint256 constant PRE_ANCHOR_BOUNDARY = 1766761200;
    /// @dev 1970-01-30 15:00:00 UTC (day 29, last Friday of January 1970), the epoch's first
    /// boundary and the earliest valid input.
    uint256 constant EPOCH_FIRST_BOUNDARY = 29 * 86400 + 15 hours;
    /// @dev 2126-12-27 15:00:00 UTC, last boundary of the horizon under test.
    uint256 constant LAST_TESTED_BOUNDARY = 4954057200;
    /// @dev Largest input whose civil day stays inside Solady's supported epoch-day domain, less a
    /// 40-day margin so the month extension in `lastDayOfMonth` and the +7 day last-Friday probe
    /// below also stay in range. Above this the DateTimeLib results are documented as undefined.
    uint256 constant LAST_SUPPORTED_INPUT =
        (DateTimeLib.MAX_SUPPORTED_EPOCH_DAY - 40) * SECONDS_PER_DAY + BOUNDARY_TIME_OF_DAY;

    function setUp() public {
        cadence = new FridayEndOfMonthCadence();
    }

    /// @dev Externally verified last-Friday-of-month dates (cross-checked against Python's
    /// calendar module) at their 15:00:00 UTC boundary, covering leap Februaries, the non-leap
    /// century year 2100, and a month that ends exactly on a Friday. Each boundary is paired
    /// with the (also externally verified) previous month's boundary, so the one-second-before
    /// case can be checked against a hardcoded expectation.
    function test_knownBoundaries() public view {
        _assertBoundary(1766707200 + BOUNDARY_TIME_OF_DAY, 1769731200 + BOUNDARY_TIME_OF_DAY); // 2025-12-26, 2026-01-30
        _assertBoundary(1769731200 + BOUNDARY_TIME_OF_DAY, 1772150400 + BOUNDARY_TIME_OF_DAY); // 2026-01-30, 2026-02-27
        _assertBoundary(1795737600 + BOUNDARY_TIME_OF_DAY, 1798156800 + BOUNDARY_TIME_OF_DAY); // 2026-11-27, 2026-12-25
        // Leap February.
        _assertBoundary(1832630400 + BOUNDARY_TIME_OF_DAY, 1835049600 + BOUNDARY_TIME_OF_DAY); // 2028-01-28, 2028-02-25
        _assertBoundary(1866499200 + BOUNDARY_TIME_OF_DAY, 1869523200 + BOUNDARY_TIME_OF_DAY); // 2029-02-23, 2029-03-30
        // Leap February.
        _assertBoundary(2464041600 + BOUNDARY_TIME_OF_DAY, 2466460800 + BOUNDARY_TIME_OF_DAY); // 2048-01-31, 2048-02-28
        // Century year, not a leap year.
        _assertBoundary(4104864000 + BOUNDARY_TIME_OF_DAY, 4107283200 + BOUNDARY_TIME_OF_DAY); // 2100-01-29, 2100-02-26
        // Month ends on a Friday.
        _assertBoundary(4130870400 + BOUNDARY_TIME_OF_DAY, 4133894400 + BOUNDARY_TIME_OF_DAY); // 2100-11-26, 2100-12-31
        _assertBoundary(4920134400 + BOUNDARY_TIME_OF_DAY, 4922553600 + BOUNDARY_TIME_OF_DAY); // 2125-11-30, 2125-12-28
    }

    /// @dev Walks every month of the next 100 years (January 2026 through December 2125) and
    /// checks the cadence against an independent reference (Hinnant's civil-date algorithms):
    /// the boundary value, the fixed-point property that
    /// BaseMigrationRatifier._validateTargetMaturity relies on to accept a maturity, and the
    /// mapping on both sides of every boundary.
    function test_allMaturitiesNext100Years() public view {
        uint256 previous = 0;
        for (uint256 year = 2026; year <= 2125; ++year) {
            for (uint256 month = 1; month <= 12; ++month) {
                uint256 boundary = _refLastFridayOfMonth(year, month) * SECONDS_PER_DAY + BOUNDARY_TIME_OF_DAY;
                // Valid maturities are exact fixed points.
                assertEq(cadence.cadencePeriodStart(boundary), boundary);
                // One second later still maps back to the boundary (so boundary + 1 is not a
                // fixed point and would be rejected as a maturity).
                assertEq(cadence.cadencePeriodStart(boundary + 1), boundary);
                if (previous != 0) {
                    // One second before a boundary maps to the previous boundary.
                    assertEq(cadence.cadencePeriodStart(boundary - 1), previous);
                    // Consecutive last Fridays are exactly four or five weeks apart.
                    assertTrue(boundary - previous == 28 days || boundary - previous == 35 days);
                }
                previous = boundary;
            }
        }
    }

    /// @dev Pins the domain edges: from the epoch's first boundary (1970-01-30 15:00:00 UTC) on, the
    /// cadence returns the historically correct last Friday and never a boundary in the input's
    /// future, so BaseMigrationRatifier._ratifyWindow's invariant check (renewalPeriodStart >
    /// block.timestamp reverts with InvalidRenewalParams) cannot trigger with this cadence. Earlier
    /// inputs revert with an arithmetic underflow.
    function test_epochEdges() public {
        assertEq(cadence.cadencePeriodStart(FIRST_BOUNDARY - 1), PRE_ANCHOR_BOUNDARY);
        assertEq(cadence.cadencePeriodStart(PRE_ANCHOR_BOUNDARY), PRE_ANCHOR_BOUNDARY);
        // 2025-11-28 15:00:00 UTC, last Friday of November 2025.
        assertEq(cadence.cadencePeriodStart(PRE_ANCHOR_BOUNDARY - 1), 1764342000);
        assertEq(cadence.cadencePeriodStart(EPOCH_FIRST_BOUNDARY), EPOCH_FIRST_BOUNDARY);
        vm.expectRevert(stdError.arithmeticError);
        cadence.cadencePeriodStart(EPOCH_FIRST_BOUNDARY - 1);
        vm.expectRevert(stdError.arithmeticError);
        cadence.cadencePeriodStart(BOUNDARY_TIME_OF_DAY - 1);
    }

    /// @dev Differential fuzz over the whole horizon: the implementation must agree with the
    /// independent reference for arbitrary timestamps, and every result must be a Friday at
    /// 15:00:00 UTC no more than five weeks in the past.
    function testFuzz_matchesReference(uint256 timestamp) public view {
        timestamp = bound(timestamp, EPOCH_FIRST_BOUNDARY, LAST_TESTED_BOUNDARY);
        uint256 boundary = cadence.cadencePeriodStart(timestamp);
        assertEq(boundary, _refCadencePeriodStart(timestamp));
        assertLe(boundary, timestamp);
        assertEq(boundary % SECONDS_PER_DAY, BOUNDARY_TIME_OF_DAY);
        // Monday-indexed weekday: day 0 (1970-01-01) was a Thursday (index 3), Friday is index 4.
        assertEq((boundary / SECONDS_PER_DAY + 3) % 7, 4);
        assertGt(boundary + 35 days, timestamp);
    }

    function testFuzz_idempotent(uint256 timestamp) public view {
        // The valid domain starts at the epoch's first boundary; earlier inputs revert.
        timestamp = bound(timestamp, EPOCH_FIRST_BOUNDARY, LAST_TESTED_BOUNDARY);
        uint256 boundary = cadence.cadencePeriodStart(timestamp);
        assertEq(cadence.cadencePeriodStart(boundary), boundary);
    }

    /// @dev Later timestamps never map to earlier boundaries. Renewals are ratified in timestamp
    /// order, so an inversion (a month transition resolving backwards) would let a later take
    /// price against an older period than an earlier one.
    function testFuzz_monotonic(uint256 earlier, uint256 later) public view {
        earlier = bound(earlier, EPOCH_FIRST_BOUNDARY, LAST_TESTED_BOUNDARY);
        later = bound(later, EPOCH_FIRST_BOUNDARY, LAST_TESTED_BOUNDARY);
        if (earlier > later) (earlier, later) = (later, earlier);
        assertLe(cadence.cadencePeriodStart(earlier), cadence.cadencePeriodStart(later));
    }

    /// @dev The other fuzz tests stop at 2126, which leaves most of the domain the contract accepts
    /// untested. This one runs the same properties over everything Solady supports (out to roughly
    /// year 4.29e9), so an arithmetic edge that only appears at large day counts cannot hide above
    /// the 100-year horizon.
    function testFuzz_supportedDomain(uint256 timestamp) public view {
        timestamp = bound(timestamp, EPOCH_FIRST_BOUNDARY, LAST_SUPPORTED_INPUT);
        uint256 boundary = cadence.cadencePeriodStart(timestamp);

        assertEq(boundary, _refCadencePeriodStart(timestamp));
        // BaseMigrationRatifier._ratifyWindow reverts if the cadence returns a future period start.
        assertLe(boundary, timestamp);
        // BaseMigrationRatifier._validateTargetMaturity accepts a maturity only if it is a fixed point.
        assertEq(cadence.cadencePeriodStart(boundary), boundary);
        assertEq(boundary % SECONDS_PER_DAY, BOUNDARY_TIME_OF_DAY);
        assertEq((boundary / SECONDS_PER_DAY + 3) % 7, 4);
        // No boundary is skipped: the longest gap between consecutive last Fridays is five weeks.
        assertGt(boundary + 35 days, timestamp);
        // The returned Friday is the last one of its month, so the next is already in the next month.
        uint256 boundaryDay = boundary / SECONDS_PER_DAY;
        (uint256 year, uint256 month,) = DateTimeLib.epochDayToDate(boundaryDay);
        (uint256 nextYear, uint256 nextMonth,) = DateTimeLib.epochDayToDate(boundaryDay + 7);
        assertTrue(year != nextYear || month != nextMonth);
    }

    /// @dev Above Solady's supported epoch day the returned value is no longer a real last Friday
    /// (DateTimeLib documents the result as undefined there), but the contract still must not revert
    /// and must still return a period start at or before its input: that bound is what stops
    /// BaseMigrationRatifier._ratifyWindow from reverting with InvalidRenewalParams. Pins the
    /// behaviour so a future upper-domain guard has to be a deliberate change, not an accident.
    function test_aboveSupportedDomainStaysBoundedByInput() public view {
        uint256[5] memory inputs = [
            DateTimeLib.MAX_SUPPORTED_EPOCH_DAY * SECONDS_PER_DAY + BOUNDARY_TIME_OF_DAY,
            (DateTimeLib.MAX_SUPPORTED_EPOCH_DAY + 1) * SECONDS_PER_DAY + BOUNDARY_TIME_OF_DAY,
            DateTimeLib.MAX_SUPPORTED_TIMESTAMP,
            2 ** 200,
            type(uint256).max
        ];
        for (uint256 i = 0; i < inputs.length; ++i) {
            uint256 boundary = cadence.cadencePeriodStart(inputs[i]);
            assertLe(boundary, inputs[i]);
            assertEq(boundary % SECONDS_PER_DAY, BOUNDARY_TIME_OF_DAY);
        }
    }

    function _assertBoundary(uint256 previousBoundary, uint256 boundary) internal view {
        // A boundary is a fixed point, one second later still maps to it, and one second
        // earlier maps to the previous month's boundary.
        assertEq(cadence.cadencePeriodStart(boundary), boundary);
        assertEq(cadence.cadencePeriodStart(boundary + 1), boundary);
        assertEq(cadence.cadencePeriodStart(boundary - 1), previousBoundary);
        assertEq(cadence.cadencePeriodStart(boundary + 1 days), boundary);
        // The shortest period is 28 days, so 27 days in the period still maps back.
        assertEq(cadence.cadencePeriodStart(boundary + 27 days), boundary);
        // Sanity-check the hardcoded pair: the previous boundary is itself a fixed point
        // exactly four or five weeks earlier.
        assertEq(cadence.cadencePeriodStart(previousBoundary), previousBoundary);
        assertTrue(boundary - previousBoundary == 28 days || boundary - previousBoundary == 35 days);
    }

    /// @dev Reference period start: last Friday of the timestamp's month at 15:00:00 UTC, or of
    /// the previous month when that boundary is still in the future. Built only on the Hinnant
    /// primitives below.
    function _refCadencePeriodStart(uint256 timestamp) internal pure returns (uint256) {
        uint256 day = (timestamp - BOUNDARY_TIME_OF_DAY) / SECONDS_PER_DAY;
        (uint256 year, uint256 month) = _refCivilFromDays(day);
        uint256 friday = _refLastFridayOfMonth(year, month);
        if (friday > day) {
            if (month == 1) {
                year -= 1;
                month = 12;
            } else {
                month -= 1;
            }
            friday = _refLastFridayOfMonth(year, month);
        }
        return friday * SECONDS_PER_DAY + BOUNDARY_TIME_OF_DAY;
    }

    /// @dev Day index (days since 1970-01-01) of the last Friday of (year, month): takes the day
    /// before the first of the next month and rolls back to a Friday using a Monday-indexed
    /// weekday, sharing no code or weekday convention with the implementation.
    function _refLastFridayOfMonth(uint256 year, uint256 month) internal pure returns (uint256) {
        uint256 nextYear = month == 12 ? year + 1 : year;
        uint256 nextMonth = month == 12 ? 1 : month + 1;
        uint256 lastDay = _refDaysFromCivil(nextYear, nextMonth, 1) - 1;
        uint256 weekday = (lastDay + 3) % 7; // Monday-indexed, Friday is 4
        return lastDay - ((weekday + 3) % 7); // (weekday - 4) mod 7 days back to Friday
    }

    /// @dev Howard Hinnant's days_from_civil, valid for years >= 1970.
    function _refDaysFromCivil(uint256 year, uint256 month, uint256 dayOfMonth) internal pure returns (uint256) {
        if (month <= 2) year -= 1;
        uint256 era = year / 400;
        uint256 yearOfEra = year - era * 400;
        uint256 dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + dayOfMonth - 1;
        uint256 dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
        return era * 146097 + dayOfEra - 719468;
    }

    /// @dev Howard Hinnant's civil_from_days (year and month only), valid for days >= 0.
    function _refCivilFromDays(uint256 day) internal pure returns (uint256 year, uint256 month) {
        uint256 z = day + 719468;
        uint256 era = z / 146097;
        uint256 dayOfEra = z - era * 146097;
        uint256 yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365;
        year = yearOfEra + era * 400;
        uint256 dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
        uint256 monthPrime = (5 * dayOfYear + 2) / 153;
        month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9;
        if (month <= 2) year += 1;
    }
}
