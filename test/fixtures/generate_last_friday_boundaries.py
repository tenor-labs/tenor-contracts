#!/usr/bin/env python3
"""Generate the golden fixture of last-Friday-of-month boundaries.

This is an INDEPENDENT oracle for LastFridayOfMonthCadence: it derives each boundary from Python's
standard-library `calendar`/`datetime` modules, which share no code and no algorithm with the
contract's inlined Hinnant civil-date math. The contract is checked against these hardcoded values,
so a bug shared between the contract and any Solidity reference cannot hide.

Each output line is the Unix timestamp (seconds, UTC) of 15:00:00 on the last Friday of a month,
one per month, ascending. Regenerate with:

    python3 test/fixtures/generate_last_friday_boundaries.py > test/fixtures/last_friday_boundaries.txt
"""

import calendar
import datetime
import sys

FIRST_YEAR = 2025
LAST_YEAR = 2125
BOUNDARY_HOUR = 15  # 15:00:00 UTC, the maturity time used across Tenor markets


def last_friday(year: int, month: int) -> int:
    """Day-of-month of the last Friday, via calendar.monthcalendar (Monday-first weeks)."""
    weeks = calendar.monthcalendar(year, month)
    fridays = [week[calendar.FRIDAY] for week in weeks if week[calendar.FRIDAY] != 0]
    return fridays[-1]


def boundary_timestamp(year: int, month: int) -> int:
    day = last_friday(year, month)
    dt = datetime.datetime(year, month, day, BOUNDARY_HOUR, 0, 0, tzinfo=datetime.timezone.utc)
    return int(dt.timestamp())


def main() -> None:
    prev = None
    for year in range(FIRST_YEAR, LAST_YEAR + 1):
        for month in range(1, 13):
            ts = boundary_timestamp(year, month)
            assert prev is None or ts > prev, "boundaries must be strictly increasing"
            prev = ts
            sys.stdout.write(f"{ts}\n")


if __name__ == "__main__":
    main()
