#!/usr/bin/env bash
# [topology] Fixture A: bring the cluster up, then run everything that exists.
#
# Split from run_all.sh because the two fixtures have different lifecycles —
# A is long-lived and B is torn down between SKV phases (PLAN.md §5).
#
# Failure policy is PLAN.md §4a: **record and carry on**. A red script does not
# stop the run, because one complete coverage picture is worth more than an
# early exit, and nothing here changes ytserv or yxctl mid-run.
cd "$(dirname "$0")"
LOG="${YX_LOG:-/tmp/yxtopo-run-a.log}"

# The 7-node fixture: the original six plus n7, whose PostgreSQL is reached
# over TCP so it can never be Main (membership.md, Forever-Spare) while staying
# a full etcd, rppd and queue member. It is in the ROSTER but not the quorum —
# `min_cluster_size` is 6, and a 7-node roster still forming a 6-node cluster
# is itself the assertion 24_db_local.sh makes.
#
# Seven is also what makes 23_split.sh meaningful: it partitions 4/3, an odd
# split with a genuine minority. Six partitions 3/3, where "both sides elected"
# and "neither did" look identical from either side.
export YX_NODES="${YX_NODES:-n1 n2 n3 n4 n5 n6 n7}"
export YX_AZ="${YX_AZ:-n1=top,n2=top,n3=east,n4=east,n5=west,n6=west,n7=west}"
export YX_TIER="${YX_TIER:-top=0,east=1,west=1}"
export YX_SPARE_NODES="${YX_SPARE_NODES:-n7}"

exec > >(tee -a "$LOG") 2>&1
echo "================================================================"
echo "fixture A  started $(date -Is)"
echo "================================================================"

rc=0
# Every test case starts clean and wiped (env.sh pre_case): its nodes running and
# ready, the fixture's config back, the WAL wiped and the cluster restarted - so a
# case that failed halfway cannot fail the next one too. Not before 10_up (which
# builds the fixture) or 05_gitsrv; YX_NO_PRECASE=1 skips it.
step() {
	echo
	echo "───────── $1 ─────────"
	case "$1" in
		10_up.sh|05_gitsrv.sh) ;;
		*) [ "${YX_NO_PRECASE:-0}" = 1 ] || bash -c 'source ./env.sh; pre_case' ;;
	esac
	if ./"$1"; then
		echo "── $1: PASS"
	else
		echo "── $1: FAIL (recorded; continuing per PLAN.md §4a)"
		rc=1
	fi
}

# Named scripts resume a run; no arguments means the whole sequence.
#
# Resumable because this is a long run on a shared box and it has twice been
# killed by unrelated memory pressure. The fixture is long-lived, so re-running
# `10_up.sh` after an interruption would throw away a healthy elected cluster to
# rebuild an identical one — and the destructive step is exactly the one not to
# repeat by reflex.
if [ $# -gt 0 ]; then
	echo "resuming: $*"
	for t in "$@"; do step "$t"; done
else
	# P7c — the destructive half. Recreates n1..n7 from the new image; a rebuilt
	# image does NOT reach a running container, which is why this and
	# 00_build.sh always go together.
	step 10_up.sh
	step 05_gitsrv.sh

	# Group 1 — the regression baseline. First, because a red here is a
	# regression from this session's work and finding that out before anything
	# else is the only way to attribute the rest.
	for t in 15_setup.sh 20_flat.sh 30_az.sh 40_tier.sh 50_shard.sh 60_write_az.sh \
	         70_reshape.sh 80_recon.sh 85_alert.sh 88_quiescent.sh 95_partition.sh \
	         96_jsonb_merge.sh 96b_merge_more.sh 31_commit.sh; do
		step "$t"
	done

	# Group 2 — the capability coverage added this session, measured against
	# dbinvent.com's Platform Capabilities list rather than against whatever
	# tests happened to exist. Second, so a red here is read against a known-good
	# Group 1 rather than confused with a regression.
	#
	# Order is by cost and by dependency: blocking first (cheap, restarts only),
	# then the server-function stack (rppd -> etcd -> clickhouse, each needing
	# the one before it to work), then MPP last - the layout, then the engine.
	# 98 installs a 58MB wheel on every node, so it is genuinely the slowest.
	for t in 86_schema_block.sh 87_node_block.sh 89_recover.sh 23_split.sh \
	         92_rppd.sh 93_etcd.sh 92c_rppd_cadence.sh 94_clickhouse.sh \
	         97_mpp.sh 98_mpp_df.sh 98_skv_join.sh 29_concurrent.sh 99_peer_stream.sh 25_cross_db.sh; do
		step "$t"
	done

	# [db-local] The regression guard for the defect run 1 found: a TCP-attached
	# node that does not start. Last, because it restarts the cluster.
	step 24_db_local.sh
fi

echo
echo "================================================================"
echo "fixture A  finished $(date -Is)  rc=$rc"
echo "================================================================"
exit $rc
