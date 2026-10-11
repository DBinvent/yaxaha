#!/usr/bin/env bash
# [topology] az routing, and the minority-zone regression.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== az: a table routed to east (2 of 6 nodes) =="

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists az_t; create table az_t (id bigint primary key, v text);" >/dev/null
done
sleep 2

# az_routing lives in CfgTabl field 20; the row value is base64 protobuf, so it
# is written with the same encoder yxctl's TUI uses rather than hand-packed here.
AZCFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'az=east' | tail -1)"
[ -n "$AZCFG" ] || { echo "  encoder produced nothing" >&2; exit 1; }
echo "  az_routing value: $AZCFG"
# register_table, not yt_setup: yt_setup creates the trigger and writes the
# module-A row in ONE transaction, and on a node whose config table is synced
# that write is refused unless the node is the leader - rolling the CREATE
# TRIGGER back with it. The node then has neither, and every write there dies
# with `yt_complete: not connected`. See env.sh.
register_table public.az_t "$AZCFG"
restart_all
await_cluster

# THE REGRESSION: east is a minority, so before the threshold fix party_size
# came out 3 against 1 eligible peer and this write aborted outright.
out="$(q n3 "begin; insert into az_t values (1,'from-east'); select yt_complete(true); commit;" 2>&1)"
check "a write in a MINORITY zone is accepted (topology-todo 2.0)" "" "$(echo "$out" | grep -ci abort | tr -d ' ' | sed 's/^0$//')"
sleep 5

for n in n3 n4; do
	check "east node $n holds the row" "from-east" "$(q "$n" "select v from az_t where id=1")"
done
for n in n1 n2 n5 n6; do
	check "non-east node $n does NOT hold it" "" "$(q "$n" "select v from az_t where id=1")"
done
summary
