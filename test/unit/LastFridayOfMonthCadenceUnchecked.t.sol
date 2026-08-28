// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IRenewalCadence} from "../../src/ratifiers/interfaces/IRenewalCadence.sol";
import {LastFridayOfMonthCadence} from "../../src/ratifiers/policies/LastFridayOfMonthCadence.sol";
import {BOUNDARY_TIME_OF_DAY, DOMAIN_START} from "../helpers/CadenceTestConstants.sol";

/// @dev A fully-checked twin of LastFridayOfMonthCadence: byte-for-byte the same algorithm, with every
/// `unchecked` block removed AND without the FIRST_BOUNDARY guard, so its revert domain is whatever the
/// checked arithmetic naturally produces. It exists only as a differential oracle for the shipped contract,
/// proving two things at once: the unchecked interior changed no returned value, and the explicit guard sits
/// exactly at the arithmetic underflow floor (call success must agree everywhere; revert reasons are expected
/// to differ - typed error vs panic - and are deliberately not compared).
contract CheckedReference is IRenewalCadence {
    uint256 public immutable BOUNDARY_TIME_OF_DAY;

    constructor(uint256 boundaryTimeOfDay) {
        require(boundaryTimeOfDay < 1 days);
        BOUNDARY_TIME_OF_DAY = boundaryTimeOfDay;
    }

    function cadencePeriodStart(uint256 timestamp) external view returns (uint256) {
        uint256 day = (timestamp - BOUNDARY_TIME_OF_DAY) / 1 days;
        (uint256 year, uint256 month, uint256 dayOfMonth) = _civilFromDays(day);
        uint256 lastDayOfMonth = day + _daysInMonth(year, month) - dayOfMonth;
        uint256 boundary = _fridayOnOrBefore(lastDayOfMonth);
        if (boundary > day) {
            boundary = _fridayOnOrBefore(day - dayOfMonth);
        }
        return boundary * 1 days + BOUNDARY_TIME_OF_DAY;
    }

    function _fridayOnOrBefore(uint256 epochDay) private pure returns (uint256) {
        return epochDay - ((epochDay + 6) % 7);
    }

    function _civilFromDays(uint256 epochDay) private pure returns (uint256 year, uint256 month, uint256 dayOfMonth) {
        uint256 z = epochDay + 719468;
        uint256 era = z / 146097;
        uint256 dayOfEra = z - era * 146097;
        uint256 yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365;
        year = yearOfEra + era * 400;
        uint256 dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
        uint256 monthPrime = (5 * dayOfYear + 2) / 153;
        dayOfMonth = dayOfYear - (153 * monthPrime + 2) / 5 + 1;
        month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9;
        if (month <= 2) year += 1;
    }

    function _daysInMonth(uint256 year, uint256 month) private pure returns (uint256) {
        if (month == 2) {
            bool leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
            return leap ? 29 : 28;
        }
        return (month == 4 || month == 6 || month == 9 || month == 11) ? 30 : 31;
    }
}

contract LastFridayOfMonthCadenceUncheckedTest is Test {
    LastFridayOfMonthCadence internal unc; // shipped contract (guarded, interior unchecked)
    CheckedReference internal chk; // fully-checked, guardless twin

    function setUp() public {
        unc = new LastFridayOfMonthCadence(BOUNDARY_TIME_OF_DAY);
        chk = new CheckedReference(BOUNDARY_TIME_OF_DAY);
    }

    /// @dev Across the ENTIRE uint256 input domain — below the floor (both must revert: guard vs underflow)
    /// and in-domain (equal value) — the guarded unchecked contract behaves identically to the guardless
    /// fully-checked twin. No third regime exists: `boundary <= (timestamp - BOUNDARY_TIME_OF_DAY) / 1 days`,
    /// so the final `boundary * 1 days + BOUNDARY_TIME_OF_DAY` is bounded by `timestamp` and cannot overflow
    /// for any uint256 input.
    function testFuzz_identicalBehaviour(uint256 timestamp) public view {
        _assertIdentical(address(unc), address(chk), timestamp);
    }

    /// @dev Same, but for an arbitrary configured boundary time, so the equivalence does not depend on 15:00.
    function testFuzz_identicalBehaviourAnyHour(uint256 hour, uint256 timestamp) public {
        hour = bound(hour, 0, 1 days - 1);
        _assertIdentical(address(new LastFridayOfMonthCadence(hour)), address(new CheckedReference(hour)), timestamp);
    }

    function test_revertEdgeParity() public view {
        _assertIdentical(address(unc), address(chk), DOMAIN_START);
        _assertIdentical(address(unc), address(chk), DOMAIN_START - 1);
        _assertIdentical(address(unc), address(chk), 0);
        _assertIdentical(address(unc), address(chk), type(uint256).max);
    }

    function _assertIdentical(address a, address b, uint256 t) internal view {
        (bool okA, uint256 vA) = _tryCall(a, t);
        (bool okB, uint256 vB) = _tryCall(b, t);
        assertEq(okA, okB, "revert parity");
        if (okA) assertEq(vA, vB, "value parity");
    }

    function _tryCall(address c, uint256 t) internal view returns (bool ok, uint256 v) {
        try IRenewalCadence(c).cadencePeriodStart(t) returns (uint256 r) {
            return (true, r);
        } catch {
            return (false, 0);
        }
    }
}
