#!/usr/bin/env bash
# [sweep] A node that MISSED rows heals without anyone writing to the table again.
#
# The gap this closes: recon_due iterated the queue, and the queue holds rows
# written on THIS node. A node that merely missed rows had nothing queued, so no
# round ran and the stale rows persisted indefinitely. Self-healing was
# write-driven; now time can trigger it too.
#
# Distinct from 80_recon: there the table keeps being written, so a round runs
# for ordinary reasons. Here NOTHING touches the table after the corruption.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== sweep: a quiescent table heals on the age trigger alone =="

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists qs_t; create table qs_t (id bigint primary key, v text);" >/dev/null
done
# a short age trigger so the test does not take ten minutes; rows trigger set
# high so ONLY the age path can fire
CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'recon=repair; recon_rows=100000; recon_timeout_sec=20' | tail -1)"
echo "  config (age-only): $CFG"
# register_table, not yt_setup: yt_setup creates the trigger and writes the
# module-A row in ONE transaction, and on a node whose config table is synced
# that write is refused unless the node is the leader - rolling the CREATE
# TRIGGER back with it. The node then has neither, and every write there dies
# with `yt_complete: not connected`. See env.sh.
register_table public.qs_t "$CFG"
restart_all
await_cluster
sleep 15

for i in $(seq 1 6); do
	q n1 "begin; insert into qs_t values ($i,'good-$i'); select yt_complete(true); commit;" >/dev/null
	sleep 1
done
for _ in $(seq 1 12); do
	[ "$(q n4 "select count(*) from qs_t")" = "6" ] && break
	sleep 5
done
check "seed replicated" "6" "$(q n4 "select count(*) from qs_t")"

trg="$(q n4 "select tgname from pg_trigger where tgrelid='qs_t'::regclass and not tgisinternal and (tgtype & 1) = 1 limit 1")"
q n4 "alter table qs_t disable trigger $trg;
      update qs_t set v='STALE' where id=4;
      alter table qs_t enable trigger $trg;" >/dev/null
check "n4 is stale on row 4" "STALE" "$(q n4 "select v from qs_t where id=4")"

echo "  NOT writing to the table again - waiting for the age trigger alone..."
for _ in $(seq 1 30); do
	[ "$(q n4 "select v from qs_t where id=4")" = "good-4" ] && break
	sleep 10
done
check "healed with no further writes" "good-4" "$(q n4 "select v from qs_t where id=4")"
check "no other row disturbed" "good-3" "$(q n4 "select v from qs_t where id=3")"
printf "     %s\n" "$(info n4 E recon)"
summary
