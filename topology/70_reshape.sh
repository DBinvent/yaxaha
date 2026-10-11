#!/usr/bin/env bash
# [topology] Shard reshape: move a table's zone and confirm nothing is lost and
# nothing is committed twice.
#
# topology.md invariant 1. The old owner keeps committing while the new one
# fills; ownership flips only when a frame comparison over the table agrees.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== reshape: move a table from east to west without losing rows =="

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists rs_t; create table rs_t (id bigint primary key, v text);" >/dev/null
	# Clear reshape_run BEFORE the first restart, not just before the second.
	#
	# reshape_flip is what normally consumes this row, so a run that is killed
	# mid-move leaves it set - and the monitor reads a value still present at
	# startup as "resume an unfinished move". The next run then fires a reshape
	# against the OLD rule during its seed phase, whose targets are the nodes that
	# already hold everything; they match on the first comparison, it flips, and
	# the flip consumes the row the test is about to rely on. That is exactly what
	# happened: n5 and n6 came back from the real restart with reshape_run empty,
	# never began the move, and west stayed at 0 rows while every log line said
	# the move had completed successfully.
	cfg_delete "$n" reshape_run C
done

EAST="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'az=east' | tail -1)"
# register_table, not yt_setup: yt_setup creates the trigger and writes the
# module-A row in one transaction, and on a node whose config table is synced
# that write is refused unless the node is the leader - taking the CREATE
# TRIGGER down with it. See env.sh. This test spent a run reporting "east never
# became writable" because five of six nodes had silently ended up with no
# trigger at all.
register_table public.rs_t "$EAST"
restart_all
await_cluster

# settle after restart_all before writing - the one test that never had this.
# A node still loading WAL answers pings past the deadline, peers flap to
# "switched off", and select_party cannot fill a party: the write aborts with
# "Not enought working nodes". 80_recon and 85_alert already wait; this did not,
# which is why its seed kept failing.
sleep 20

# Seeded as SEPARATE single-row transactions.
#
# A multi-row transaction replicates intermittently on this cluster - it aborts
# with "Not enought working nodes" when a peer misses a ping deadline mid-write.
# Single-row transactions are reliable. The seed is SETUP, not the thing under
# test, so it must not be the flakiest part of the test: a failure here should
# mean Copy failed, not that the write path had a bad minute.
SEED=40
# Wait for the write path, do not assume it. On freshly created containers the
# `sleep 20` above is not enough: the seed's first writes PREPARE on the party
# and never commit, and the run ends with 0 rows and orphaned prepared
# transactions on n5/n6. The probe absorbs that window once instead of losing
# the seed to it.
wait_writable n3 n4 rs_t || { bad "east never became writable"; summary; }
echo "  seeding $SEED rows in east, one transaction each..."
for i in $(seq 1 $SEED); do
	q n3 "begin; insert into rs_t values ($i,'row-$i'); select yt_complete(true); commit;" >/dev/null
	# one retry, locally checked: the probe already proved the path, so a miss
	# here is a transient party hiccup rather than a cluster that is not up
	[ "$(q n3 "select count(*) from rs_t where id=$i")" = "1" ] ||
		q n3 "begin; insert into rs_t values ($i,'row-$i'); select yt_complete(true); commit;" >/dev/null
done
for _ in $(seq 1 12); do
	[ "$(q n4 "select count(*) from rs_t where id > 0")" = "$SEED" ] && break
	sleep 5
done
check "east holds the seed" "$SEED" "$(q n3 "select count(*) from rs_t where id > 0")"
# the OTHER east node must have it too - asserting only on the writer is how the
# reshape test hid a replication failure from itself all day
check "the other east node has it too" "$SEED" "$(q n4 "select count(*) from rs_t where id > 0")"
check "west holds nothing yet" "0" "$(q n5 "select count(*) from rs_t where id > 0")"

# Widen the rule to include west, then ask for the move.
#
# recon=repair stays on so the frame comparison that gates the flip can run, but
# the BACKFILL is `Copy` over the transfer stream - recon converges rows both
# sides know about and cannot enumerate a table for a node starting empty. That
# was the claim this test disproved.
BOTH="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'az=east,west; recon=repair' | tail -1)"
for n in "${NODES[@]}"; do
	cfg_write "$n" public.rs_t A "$BOTH"
	cfg_write "$n" reshape_run C "$YX_DB.public.rs_t"
done
restart_all 40
await_cluster

echo "  waiting for the frame comparison to agree..."
# Wait for BOTH the fill and the flip, because they are two separate events and
# the second is not implied by the first. `Copy` finishes the backfill inside one
# monitor tick, but the FLIP needs the leader's NEXT reshape_tick to run the
# frame comparison and consume reshape_run - up to another 5s, more if a
# comparison round is already in flight. Breaking as soon as the row count lands
# and then reading the log is a race that earlier runs simply won; it cost this
# test a spurious "the move never completed" with all 8 data assertions green.
why=""
for _ in $(seq 1 36); do
	w="$(q n5 "select count(*) from rs_t where id > 0")"
	if [ "${w:-0}" = "$SEED" ]; then
		why="$(logs_all | { grep -aoE 'reshape COMPLETE.*' || true; } | tail -1)"
		[ -n "$why" ] && break
	fi
	sleep 5
done

check "west caught up to the full set" "$SEED" "$(q n5 "select count(*) from rs_t where id > 0")"
check "east still has every row"       "$SEED" "$(q n3 "select count(*) from rs_t where id > 0")"
check "top still holds none"           "0"     "$(q n1 "select count(*) from rs_t where id > 0")"
# The real invariant: not one row lost or duplicated anywhere it landed.
# Guarded, because md5 of two empty tables matches - this assertion reported
# "agree exactly" for a whole day while both sides held nothing.
check_same "east and west agree exactly" n3 n5 \
	"select md5(string_agg(id||':'||v, ',' order by id)) from rs_t where id > 0" \
	"$SEED" "rs_t where id > 0"

# Copy has to have MOVED something. Without this the test cannot tell a working
# backfill from rows that were already there: east and west would agree in both
# cases, and for most of this test's life nothing was copied at all.
#
# `|| true` on every grep that is ALLOWED to find nothing: env.sh runs under
# `set -euo pipefail`, and a non-matching grep in an ASSIGNMENT exits 1 and takes
# the script with it - silently, mid-run, with no summary line. (Inside an
# argument list it is harmless, which is why the older greps here never bit.)
bf="$(logs_all | grep -acE 'A3.*backfill: [1-9][0-9]* row' || true)"
if [ "${bf:-0}" -gt 0 ]; then
	ok "Copy backfilled rows ($bf non-zero copy log line(s) across the cluster)"
else
	bad "no node logged a non-zero Copy backfill — west filled some other way, or not at all"
fi

# WHY the move completed, not just that it did.
#
# Polling for the flip cannot catch a premature one - a 40-row copy finishes
# inside a single monitor tick, so both the fill and the flip land between two
# samples. The reason string is not racy: reshape_flip logs the verdict that
# justified it, and the two are distinguishable.
#
#   "N frame(s) agree, 40 row(s)"  the comparison actually ran and matched
#   "table is empty"               the reference held nothing, so the gate was
#                                  never really consulted - this is the bug
#
# It said "table is empty" because reshape_reference returned Option::None for
# BOTH "read locally" and "no reference found", and the leader holds no
# east/west table: it framed its own empty copy and handed ownership over. The
# fix is a four-state Reference; this line is what proves the gate ran.
#
# `why` was captured by the wait loop above; re-read only if that timed out, so
# the failure message reflects the final state rather than an empty mid-wait one.
[ -n "$why" ] || why="$(logs_all | { grep -aoE 'reshape COMPLETE.*' || true; } | tail -1)"
case "$why" in
	"")                 bad "the move never completed — no reshape COMPLETE in any log" ;;
	*"table is empty"*) bad "flipped on an empty reference, not a comparison — [$why]" ;;
	*)                  ok "the flip was justified by a real comparison — [${why#*- }]" ;;
esac
# The flip consumes `reshape_run` on the node that flipped only - it is a runtime
# row, local to each node - so every other node would resume this move on each
# later restart (F13), under the tests that follow. A job (yt_job) has no such
# leftover; this legacy path needs the cleanup.
for n in "${NODES[@]}"; do cfg_delete "$n" reshape_run C; done
summary
