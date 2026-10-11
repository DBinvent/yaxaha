#!/usr/bin/env bash
# [mpp:1] ClickHouse: is it up, and does a committed row reach it?
#
# Phase 1 of the MPP work, and deliberately a SMOKE TEST: the question is
# whether the ClickHouse path is wired and operational end to end, not whether
# any particular analytic is correct.
#
# Two halves, and they are different mechanisms:
#
# | | who writes | needs |
# |---|---|---|
# | `on_commit_clickhouse` | ytserv, in Rust over hyper | a ClickHouse server |
# | `CH` in a python function | rppd, via the `clickhouse_connect` package | that package too |
#
# The first needs no python at all - it is a `INSERT INTO <db>.<table> FORMAT
# JSONEachRow` POST from ytserv itself (`state/clickhouse.rs`). The second is
# the rppd half the phase is named for, and it needs a PyPI package that is NOT
# in the Ubuntu archive, so unlike psycopg2 and etcd3 the deb cannot declare it.
# The product documents it as optional for exactly that reason: "a missing
# package or a refused connection is logged and simply leaves CH unbound".
#
# ## The sink does not create the table
#
# It inserts and nothing else, so ClickHouse must already have a table whose
# columns match the PostgreSQL ones - the JSON keys are the PG column names
# (`row_json`). Target is `<clickhouse_db>.<table>`, falling back to the PG
# SCHEMA name when `clickhouse_db` is empty, so `public.t` would land as
# `public.t`.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== clickhouse: a committed row reaches ClickHouse =="

CH_HOST="${YX_CH_HOST:-chsrv}"
CH_IMAGE="${YX_CH_IMAGE:-clickhouse/clickhouse-server:24.8-alpine}"

chq() { # chq <sql> — run SQL in the ClickHouse container
	rh "docker exec $CH_HOST clickhouse-client --query \"$1\"" 2>/dev/null || true
}

# ── 1. ClickHouse is up, and reachable FROM A NODE ─────────────────────────
#
# Reachability from a cluster node is the part that matters: ytserv dials it
# over the docker network, so "up on the host" proves nothing by itself.
if [ -z "$(rh "docker ps --format '{{.Names}}' | grep -x $CH_HOST" 2>/dev/null)" ]; then
	echo "  starting $CH_HOST..."
	rh "docker run -d --name $CH_HOST --network $YX_NET --ulimit nofile=262144:262144 \
	    -e CLICKHOUSE_SKIP_USER_SETUP=1 $CH_IMAGE >/dev/null" 2>/dev/null || true
	for _ in $(seq 1 12); do
		[ "$(chq 'SELECT 1')" = "1" ] && break
		sleep 5
	done
fi
check "ClickHouse answers SELECT 1" "1" "$(chq 'SELECT 1')"

from_node="$(rh "docker exec ${NODES[0]} sh -c 'curl -s -m 5 \"http://$CH_HOST:8123/?query=SELECT%201\"'" 2>/dev/null || true)"
check "...and answers from ${NODES[0]} over the cluster network" "1" "$from_node"

ver="$(chq 'SELECT version()')"
echo "     ClickHouse $ver"

# ── 2. the target table, which the sink will not create ────────────────────
chq "CREATE DATABASE IF NOT EXISTS $YX_DB" >/dev/null
chq "DROP TABLE IF EXISTS $YX_DB.ch_t" >/dev/null
chq "CREATE TABLE $YX_DB.ch_t (id Int64, v String) ENGINE = MergeTree ORDER BY id" >/dev/null
check "the ClickHouse target table exists" "1" \
	"$(chq "SELECT count() FROM system.tables WHERE database='$YX_DB' AND name='ch_t'")"

# ── 3. point the cluster at it ─────────────────────────────────────────────
#
# `cfg_write` + the restart below: the STARTUP path. A runtime config change is
# PLAN.md F8 - it reaches the leader and not the followers - and a sink that is
# configured on one node out of seven would make this test measure the leader.
for n in "${NODES[@]}"; do
	cfg_write "$n" serve_clickhouse C true
	cfg_write "$n" clickhouse_url C "http://$CH_HOST:8123"
	cfg_write "$n" clickhouse_db C "$YX_DB"
done

CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'on_commit_clickhouse' | tail -1)"
[ -n "$CFG" ] && ok "on_commit_clickhouse encodes to a config ($CFG)" \
	|| bad "--encode-table-cfg 'on_commit_clickhouse' produced nothing"

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists ch_t; create table ch_t (id bigint primary key, v text);" >/dev/null
done
register_table public.ch_t "$CFG"
restart_all
await_cluster
wait_writable n1 n2 ch_t || { bad "cluster never became writable"; summary; }

L=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in *Leader) L="$n";; esac
done
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }

# Read it back from the LIVE config, not the table: a sink configured in the
# table and not loaded is exactly the failure this would otherwise blame on
# ClickHouse.
check "$L is running with serve_clickhouse on" "true" "$(info "$L" E cfg.serve_clickhouse)"
check "...and pointed at the right endpoint" "http://$CH_HOST:8123" \
	"$(info "$L" E cfg.clickhouse_url)"

# ── 4. a committed row reaches ClickHouse ──────────────────────────────────
echo "  writing 3 rows through the cluster..."
for i in 1 2 3; do
	q "$L" "begin; insert into ch_t values ($i,'row-$i'); select yt_complete(true); commit;" >/dev/null 2>&1
done

# The sink is asynchronous and batches, so poll rather than sleep-and-peek.
landed=0
for _ in $(seq 1 24); do
	landed="$(chq "SELECT count() FROM $YX_DB.ch_t")"
	[ "${landed:-0}" -ge 3 ] && break
	sleep 5
done
[ "${landed:-0}" -ge 3 ] \
	&& ok "all 3 committed rows reached ClickHouse ($landed)" \
	|| bad "only ${landed:-0} of 3 rows reached ClickHouse after 120s - the sink \
is configured and loaded, so this is the sink itself or the endpoint"

# The VALUES too, not just the count: a sink that inserted three empty rows
# would satisfy a count and nothing else.
got="$(chq "SELECT v FROM $YX_DB.ch_t WHERE id = 2")"
check "the row's value arrived intact" "row-2" "$got"

# ── 5. rppd + CH: the python binding ───────────────────────────────────────
#
# The half this phase is named for. `CH` is bound by importing
# `clickhouse_connect`, which is PyPI-only - not in the Ubuntu archive, so
# unlike psycopg2 and etcd3 it cannot be a deb dependency. Installed here for
# the test; a real deployment does the same thing.
# `apt-get update` first: the node image removes /var/lib/apt/lists, so an
# install without it fails silently and pip3 is simply absent - which the first
# version of this reported as "could not install clickhouse_connect", blaming
# the package rather than the missing package manager.
echo "  installing clickhouse_connect for the rppd binding..."
pip_ok=0
rh "docker exec $L sh -c 'apt-get update -q >/dev/null 2>&1 && \
    apt-get install -qy python3-pip >/dev/null 2>&1; \
    pip3 install --quiet --break-system-packages clickhouse_connect >/dev/null 2>&1; \
    python3 -c \"import clickhouse_connect\" 2>/dev/null && echo yes'" 2>/dev/null | grep -q yes && pip_ok=1
if [ "$pip_ok" = "1" ]; then
	ok "clickhouse_connect is importable on $L"
else
	bad "could not install clickhouse_connect on $L - the rppd CH binding cannot \
be tested without it (PyPI only; the deb cannot declare it)"
	summary
fi

# ── 6. a python function writes to ClickHouse through `CH` ─────────────────
#
# The rppd half. `serve_clickhouse` binds a `clickhouse_connect` client as `CH`
# alongside `DB`, so a server function can join a PostgreSQL row with whatever
# else it needs and land the result in ClickHouse - which is the shape the
# product describes for analytics.
#
# The rppd tables and serve_rppd come from 92_rppd.sh; installed here too so
# this script stands alone.
RPPD_DDL="
create table if not exists rppd_config (
    id serial primary key, host varchar(64) not null unique,
    host_name varchar(64) not null unique,
    active_since timestamptz default current_timestamp,
    max_db_connections int not null default 10, master bool unique);
create table if not exists rppd_function (
    id serial primary key, code text not null, checksum varchar(64) not null,
    schema_table varchar(64) not null, topic varchar(64) not null default '',
    priority int not null default 1, queue bool not null default true,
    cleanup_logs_min int not null default 0, fn_logging bool not null default false,
    verbose_debug bool not null default false, env json, sign json);
create table if not exists rppd_function_log (
    id bigserial primary key, node_id int not null, fn_id int not null,
    trig_value json, trig_type int not null default 0,
    started_at timestamptz not null default current_timestamp,
    took_ms bigint, output text, error_msg text);
"
for n in "${NODES[@]}"; do
	q "$n" "$RPPD_DDL drop table if exists chp_t;
	        create table chp_t (id bigint primary key, v text);" >/dev/null
	cfg_write "$n" serve_rppd C true
done
chq "DROP TABLE IF EXISTS $YX_DB.chp_sink" >/dev/null
chq "CREATE TABLE $YX_DB.chp_sink (id Int64, note String) ENGINE = MergeTree ORDER BY id" >/dev/null

PYCFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'on_commit_python' | tail -1)"
register_table public.chp_t "$PYCFG"

q "$L" "insert into rppd_config (host, host_name, master) values ('$L:7421','$L',true)
        on conflict do nothing" >/dev/null

# Minimal, and using CH the way the product documents it.
FN='CH.command("INSERT INTO '"$YX_DB"'.chp_sink (id, note) VALUES (7, '"'"'from-rppd'"'"')")'
# On EVERY node: rppd_function is a plain local table, and the function runs on
# the rppd master - the leader the restart below elects, which need not be the
# node that leads now (a function on one node ran only when leadership stayed).
for n in "${NODES[@]}"; do
	q "$n" "delete from rppd_function where schema_table='public.chp_t';
        insert into rppd_function (code, checksum, schema_table, topic, fn_logging, verbose_debug)
        values (\$fn\$$FN\$fn\$, 'na', 'public.chp_t', '', true, true)" >/dev/null
done

restart_all
await_cluster
sleep 10
L=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in *Leader) L="$n";; esac
done

echo "  writing a row to trigger the python function..."
q "$L" "begin; insert into chp_t values (1,'trigger'); select yt_complete(true); commit;" >/dev/null 2>&1

via_py=0
for _ in $(seq 1 24); do
	via_py="$(chq "SELECT count() FROM $YX_DB.chp_sink WHERE note='from-rppd'")"
	[ "${via_py:-0}" -ge 1 ] && break
	sleep 5
done
if [ "${via_py:-0}" -ge 1 ]; then
	ok "a python function wrote to ClickHouse through CH - rppd+ch is wired"
else
	err="$(q "$L" "select coalesce(error_msg,'<none>') from rppd_function_log order by id desc limit 1")"
	bad "the python function did not reach ClickHouse; last rppd error: ${err:-<no log row>}"
fi

summary
