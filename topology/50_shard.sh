#!/usr/bin/env bash
# [topology] Shard: rows land only where their partition column says.
#
# `outer=pin` (az_node_uuid) is the one policy with a strictly owner-only party:
# the column names the owner, so there is exactly one place the row can go.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== shard: az_node_uuid routes each row by its owner column =="

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists sh_t;
	        create table sh_t (id bigint primary key, owner text, v text);" >/dev/null
done
sleep 2

CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'shard=owner; outer=pin' | tail -1)"
echo "  shard value: $CFG"
# register_table, not yt_setup: yt_setup creates the trigger and writes the
# module-A row in ONE transaction, and on a node whose config table is synced
# that write is refused unless the node is the leader - rolling the CREATE
# TRIGGER back with it. The node then has neither, and every write there dies
# with `yt_complete: not connected`. See env.sh.
register_table public.sh_t "$CFG"
restart_all
await_cluster

# one row per zone, each written from a node in that zone
q n1 "begin; insert into sh_t values (1,'top','for-top');   select yt_complete(true); commit;" >/dev/null
q n3 "begin; insert into sh_t values (2,'east','for-east'); select yt_complete(true); commit;" >/dev/null
q n5 "begin; insert into sh_t values (3,'west','for-west'); select yt_complete(true); commit;" >/dev/null
sleep 6

# each row is held only in its own zone
for n in "${NODES[@]}"; do
	az="${NODE_AZ[$n]}"
	for id_az in "1 top" "2 east" "3 west"; do
		set -- $id_az
		want=""; [ "$az" = "$2" ] && want="for-$2"
		check "$n(az=$az) row id=$1(owner=$2)" "$want" "$(q "$n" "select v from sh_t where id=$1")"
	done
done
summary
