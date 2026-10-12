#!/usr/bin/env python3
"""Write nightly/badge.json - the newest nightly run as a shields.io endpoint badge.

    nightly/badge.py              # results.yaml next to this file -> badge.json
    nightly/badge.py --print      # print the badge, write nothing

The badge is what dbinvent.com shows next to the release it announces:

    https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FDBinvent%2Fyaxaha%2Fmain%2Fnightly%2Fbadge.json

    nightly 1.1.82 | 2,782 tests · all passed
    nightly 1.1.82 | 2,782 tests · 1 failed
    nightly 1.1.82 | 2,782 tests · all passed · ytserv coverage 77%

The label is the ytserv tested, the message the total and how it went - green
only for a run whose every suite passed, red otherwise. A suite skipped for a
missing outside service is named: it tested nothing, and a green badge should not
hide that. Coverage is ytserv's line coverage, unit and end-to-end tests together,
from coverage.yaml - the last measurement: a run measures only when that file is
missing (or lists fewer suites than a whole run), so most runs carry none of their own.

Only the tail of results.yaml is read (TAIL lines): the file only grows, and the
newest run is the last `- run` entry in it. An entry longer than TAIL is an error,
not a guess - raise TAIL.

It only reaches the page once badge.json is pushed: shields.io reads it from
GitHub, never from this host.
"""
import json
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results.yaml"
BADGE = HERE / "badge.json"
COVERAGE = HERE / "coverage.yaml"
TAIL = 30


def tail(path: Path, n: int) -> list[str]:
    """The last n lines of a file, read from its end."""
    with open(path, "rb") as f:
        end = pos = f.seek(0, 2)
        data = b""
        while pos > 0 and data.count(b"\n") <= n:
            pos = max(0, pos - 4096)
            f.seek(pos)
            data = f.read(end - pos)
    return data.decode().splitlines()[-n:]


def newest_run(path: Path) -> dict:
    lines = tail(path, TAIL)
    starts = [i for i, line in enumerate(lines) if line.startswith("- run")]
    if not starts:
        raise ValueError(f"no '- run' in the last {TAIL} lines of {path}")
    return yaml.safe_load("\n".join(lines[starts[-1]:]))[0]


def ytserv_coverage() -> float | None:
    """ytserv's percent in coverage.yaml, as nightly.sh last measured it."""
    try:
        crates = yaml.safe_load(COVERAGE.read_text())["crates"]
        return next(float(c["percent"]) for c in crates if c.get("name") == "ytserv")
    except (OSError, yaml.YAMLError, KeyError, TypeError, ValueError, StopIteration):
        return None


def badge(run: dict) -> dict:
    version = (run.get("version") or {}).get("ytserv", "?")
    totals = run.get("totals") or {}
    passed, failed = int(totals.get("passed", 0)), int(totals.get("failed", 0))
    skipped = sum(1 for s in run.get("suites") or [] if s.get("result") == "skipped")
    parts = [f"{passed + failed:,} tests"]
    if run.get("result") == "pass":
        color = "brightgreen"
        parts.append("all passed" + (f", {skipped} suite{'s' if skipped > 1 else ''} skipped" if skipped else ""))
    else:
        color = "red"
        parts.append(f"{failed:,} failed" if run.get("suites") else "build failed")
    coverage = ytserv_coverage()
    if coverage is not None:
        parts.append(f"ytserv coverage {coverage:.0f}%")
    return {"schemaVersion": 1, "label": f"nightly {version}", "message": " · ".join(parts),
            "color": color, "cacheSeconds": 3600}


def main() -> int:
    try:
        run = newest_run(RESULTS)
    except (OSError, ValueError, yaml.YAMLError, IndexError, TypeError) as err:
        print(f"badge: {err}", file=sys.stderr)
        return 1
    text = json.dumps(badge(run), ensure_ascii=False) + "\n"
    if "--print" in sys.argv:
        print(text, end="")
    else:
        BADGE.write_text(text)
        b = json.loads(text)
        print(f"badge: {BADGE.name} <- run {run.get('run')}: {b['label']} | {b['message']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
