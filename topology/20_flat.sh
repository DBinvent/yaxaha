#!/usr/bin/env bash
# [topology] Baseline: with NO az or shard rule, the cluster behaves exactly as
# it did before any of this landed.
#
# topology.md invariant 6 asks for precisely this, and it is the regression gate
# for every other test here: if the unconfigured path changed, nothing below
# means anything.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== flat: an unrouted table replicates everywhere =="

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists flat_t;
	        create table flat_t (id bigint primary key, v text);" >/dev/null
done
# register_table, not yt_setup: yt_setup creates the trigger and writes the
# module-A row in ONE transaction, and on a node whose config table is synced
# that write is refused unless the node is the leader - rolling the CREATE
# TRIGGER back with it. The node then has neither, and every write there dies
# with `yt_complete: not connected`. See env.sh.
register_table public.flat_t
restart_all
await_cluster

q n1 "begin; insert into flat_t values (1,'from-n1'); select yt_complete(true); commit;" >/dev/null
sleep 5

for n in "${NODES[@]}"; do
	check "flat_t row reached $n" "from-n1" "$(q "$n" "select v from flat_t where id=1")"
done
summary
