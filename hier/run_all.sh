#!/usr/bin/env bash
# [tpl2] The hierarchical fixture: three clusters, one network, every relation.
#
# Failure policy matches ../topology/run_a.sh - **record and carry on**. A red
# script does not stop the run, because one complete picture is worth more than an
# early exit, and nothing here changes ytserv mid-run.
#
# Order is by dependency, not by cost:
#
#   10_up        destructive; recreates all nine containers
#   20_relations the relation layer is configured, loaded and derived at all
#   30_quorum    ...and an external link is excluded from quorum/election/party
#   40_dial      ...and rules 1 and 2 are enforced on the dial
#   50_tables    the two per-table configurations, across a real boundary
#   60_neighbor  the sideways rule: sharded crosses, unsharded does not
#   70_failover  a leader change below does not sever the link from above
#
# 20 and 30 come before everything else deliberately: if the relation layer is not
# loaded, or a foreign node is counted in quorum, then every later assertion is
# about a merged cluster and would be read as a routing bug.
#
# Ends with one line the nightly reads, in ../topology's summary format:
#   ---- hier: <passed> passed, <failed> failed ----
# summed from each script's own "---- N passed, M failed ----" lines, plus one
# failure for a script that FAILED without counting a failure in a summary (it
# died before its summary, or exited non-zero on its own). ./90_down.sh frees the
# containers afterwards; it is not run here, so a red script can be re-run
# against live state.
cd "$(dirname "$0")"
LOG="${YX_LOG:-/tmp/yxhier-run.log}"

exec > >(tee -a "$LOG") 2>&1
echo "================================================================"
echo "fixture HIER  started $(date -Is)"
echo "================================================================"

rc=0
tot_pass=0; tot_fail=0
step_out="$(mktemp)"
trap 'rm -f "$step_out"' EXIT
step() {
	local src sums p f
	echo
	echo "───────── $1 ─────────"
	./"$1" 2>&1 | tee "$step_out"
	src=${PIPESTATUS[0]}
	sums="$(grep -oE -- '---- [0-9]+ passed, [0-9]+ failed ----' "$step_out")"
	p=$(awk '{s+=$2} END {print s+0}' <<< "$sums")
	f=$(awk '{s+=$4} END {print s+0}' <<< "$sums")
	if [ "$src" -eq 0 ]; then
		echo "── $1: PASS"
	else
		echo "── $1: FAIL (recorded; continuing)"
		rc=1
		if [ "$f" -eq 0 ]; then
			echo "  (counted as one failure: exit $src with no failed check in a summary)"
			f=1
		fi
	fi
	tot_pass=$((tot_pass + p)); tot_fail=$((tot_fail + f))
}

# Named scripts resume a run; no arguments means the whole sequence. Resumable
# because 10_up is the destructive step and re-running it after an interruption
# would throw away three healthy elected clusters to rebuild identical ones.
if [ $# -gt 0 ]; then
	echo "resuming: $*"
	for t in "$@"; do step "$t"; done
else
	step 10_up.sh
	for t in 20_relations.sh 30_quorum.sh 40_dial.sh 50_tables.sh 60_neighbor.sh \
	         70_failover.sh; do
		step "$t"
	done
fi

[ "$tot_fail" -gt 0 ] && rc=1
echo
echo "================================================================"
echo "fixture HIER  finished $(date -Is)  rc=$rc"
echo "================================================================"
echo "---- hier: $tot_pass passed, $tot_fail failed ----"
echo "(./90_down.sh to free the containers)"
exit $rc
