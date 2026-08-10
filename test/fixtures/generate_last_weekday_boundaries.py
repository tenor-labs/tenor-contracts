#!/usr/bin/env python3
"""Generate the golden fixtures of last-weekday-of-month boundaries, one file per weekday.

This is an INDEPENDENT oracle for LastWeekdayOfMonthCadence: it derives each boundary from Python's
standard-library `calendar`/`datetime` modules, which share no code and no algorithm with the
contract's inlined Hinnant civil-date math. The contract is checked against these hardcoded values,
so a bug shared between the contract and any Solidity reference cannot hide.

Weekdays are Monday-indexed (0 = Monday .. 6 = Sunday), matching both `calendar` and the contract's
BOUNDARY_DAY_OF_WEEK. Each line of last_<weekday>_boundaries.txt is the Unix timestamp (seconds,
UTC) of 15:00:00 on the last such weekday of a month, one per month, ascending. Regenerate with:

    python3 test/fixtures/generate_last_weekday_boundaries.py
"""

import calendar
import datetime
import pathlib

FIRST_YEAR = 2025
LAST_YEAR = 2125
BOUNDARY_HOUR = 15  # 15:00:00 UTC, the maturity time used across Tenor markets
WEEKDAY_NAMES = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


def last_weekday(year: int, month: int, weekday: int) -> int:
    """Day-of-month of the last given weekday, via calendar.monthcalendar (Monday-first weeks)."""
    weeks = calendar.monthcalendar(year, month)
    days = [week[weekday] for week in weeks if week[weekday] != 0]
    return days[-1]


def boundary_timestamp(year: int, month: int, weekday: int) -> int:
    day = last_weekday(year, month, weekday)
    dt = datetime.datetime(year, month, day, BOUNDARY_HOUR, 0, 0, tzinfo=datetime.timezone.utc)
    return int(dt.timestamp())


def main() -> None:
    out_dir = pathlib.Path(__file__).resolve().parent
    for weekday, name in enumerate(WEEKDAY_NAMES):
        prev = None
        lines = []
        for year in range(FIRST_YEAR, LAST_YEAR + 1):
            for month in range(1, 13):
                ts = boundary_timestamp(year, month, weekday)
                assert prev is None or ts > prev, "boundaries must be strictly increasing"
                prev = ts
                lines.append(f"{ts}\n")
        (out_dir / f"last_{name}_boundaries.txt").write_text("".join(lines))


if __name__ == "__main__":
    main()
