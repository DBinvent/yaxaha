#!/usr/bin/env bash
# [topology] Full suite: build the node image, then fixture A (run_a.sh) - every
# script, failures recorded and the run carried on. Ends with one line the
# nightly reads: "---- topology: <passed> passed, <failed> failed ----".
#
#   ./run_all.sh                 # YT_PGXT's newest deb, or YAXAHA_DEB
#   ./90_down.sh                 # free the containers afterwards
set -uo pipefail
cd "$(dirname "$0")"
LOG="${YX_LOG:-/tmp/yxtopo-run-all.$$.log}"
: > "$LOG"
./00_build.sh 2>&1 | tee -a "$LOG" || { echo "---- topology: 0 passed, 1 failed ----"; exit 1; }
YX_LOG="$LOG" ./run_a.sh "$@"; rc=$?
sums=$(grep -oE -- "---- [0-9]+ passed, [0-9]+ failed ----" "$LOG")
p=$(awk '{s+=$2} END {print s+0}' <<< "$sums")
f=$(awk '{s+=$4} END {print s+0}' <<< "$sums")
# a script that failed without counting a failure - it died before its summary,
# or exited non-zero on its own - is one failure the counters never saw
red=$(grep -c -- "── .*: FAIL" "$LOG")
counted=$(awk '$4 > 0' <<< "$sums" | grep -c .)
[ "$red" -gt "$counted" ] && f=$((f + red - counted))
echo
[ "$rc" -eq 0 ] && echo "ALL TOPOLOGY TESTS PASSED" || echo "SOME TESTS FAILED"
echo "---- topology: $p passed, $f failed ----"
echo "(./90_down.sh to free the containers)"
exit $rc
