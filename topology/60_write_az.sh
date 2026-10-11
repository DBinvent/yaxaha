#!/usr/bin/env bash
# [topology] writable_az: a zone may HOLD a table and still not be allowed to
# originate writes to it.
#
# topology.md's "write by top only" (shard.md usecase 4): the top cluster owns
# the config tables, the tiers below read them. Until this test the rule had no
# live coverage at all - the gate at checkin.rs:715 was only unit-tested.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== writable_az: east holds the table, only top may write it =="

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists waz_t; create table waz_t (id bigint primary key, v text);" >/dev/null
done
sleep 2

CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'az=top,east; write=top' | tail -1)"
echo "  writable_az value: $CFG"
# register_table, not yt_setup: yt_setup creates the trigger and writes the
# module-A row in ONE transaction, and on a node whose config table is synced
# that write is refused unless the node is the leader - rolling the CREATE
# TRIGGER back with it. The node then has neither, and every write there dies
# with `yt_complete: not connected`. See env.sh.
register_table public.waz_t "$CFG"
restart_all
await_cluster

# a write from top: allowed
q n1 "begin; insert into waz_t values (1,'from-top'); select yt_complete(true); commit;" >/dev/null
sleep 5
check "top may write"            "from-top" "$(q n1 "select v from waz_t where id=1")"
check "east HOLDS what top wrote" "from-top" "$(q n3 "select v from waz_t where id=1")"

# a write from east: refused. The leader decides this, so the error comes back
# to the client rather than being silently dropped.
out="$(q n3 "begin; insert into waz_t values (2,'from-east'); select yt_complete(true); commit;" 2>&1)"
check "east is REFUSED (read-only there)" "" "$(q n3 "select v from waz_t where id=2")"
check "and the refusal did not leak to top" "" "$(q n1 "select v from waz_t where id=2")"

# west holds nothing: not in the az list at all
check "west holds neither row" "" "$(q n5 "select count(*) from waz_t" | grep -v '^0$')"
summary
