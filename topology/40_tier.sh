#!/usr/bin/env bash
# [topology] The up/down filter: a table that must not climb to the tier above.
#
# shard.md usecase 4 - the edge's big tables stay at the edge while the top
# cluster's config still comes down. `no_up` is what expresses that, and until
# tiers existed it was a proto field nothing read.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== tier: east table with no_up does not reach top =="

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists tier_t; create table tier_t (id bigint primary key, v text);" >/dev/null
done
sleep 2

# holds in east AND west (both tier 1), but never climbs to tier 0
CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'az=east,west; no_up' | tail -1)"
echo "  no_up value: $CFG"
# register_table, not yt_setup: yt_setup creates the trigger and writes the
# module-A row in ONE transaction, and on a node whose config table is synced
# that write is refused unless the node is the leader - rolling the CREATE
# TRIGGER back with it. The node then has neither, and every write there dies
# with `yt_complete: not connected`. See env.sh.
register_table public.tier_t "$CFG"
restart_all
await_cluster

q n3 "begin; insert into tier_t values (1,'edge-data'); select yt_complete(true); commit;" >/dev/null
sleep 5

for n in n3 n4 n5 n6; do
	check "tier-1 node $n holds it" "edge-data" "$(q "$n" "select v from tier_t where id=1")"
done
for n in n1 n2; do
	check "tier-0 node $n did NOT receive it (no_up)" "" "$(q "$n" "select v from tier_t where id=1")"
done
summary
