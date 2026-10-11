#!/usr/bin/env bash
# Run a command under the nightly's lock, so it never meets a nightly run on the
# shared test hosts - a suite run by hand, a rerun script:
#
#   nightly/locked.sh ../topology/run_all.sh
#
# A run (a nightly, or another locked.sh) already holds the lock: nothing is run,
# exit 75, and it says who holds it. While the command runs, a nightly that starts
# does the same.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
[ $# -gt 0 ] || { sed -n '2,9s/^# \{0,1\}//p' "$0"; exit 2; }
LOCK="$HERE/state/nightly.lock"
mkdir -p "$HERE/state"
exec 9>> "$LOCK"
if ! flock -n 9; then
	echo "$(date -u +%FT%TZ) not run: another run holds $LOCK - $(cat "$LOCK.who" 2>/dev/null || echo unknown)" >&2
	exit 75
fi
echo "locked.sh pid $$ since $(date -u +%FT%TZ): $*" > "$LOCK.who"
"$@" 9>&-   # the lock is this shell's: a daemon the command leaves behind (an ssh master) must not hold it
