#!/usr/bin/env bash
# [mpp:2b] DataFusion: is it up, and does the parallel analytic run through it?
#
# Phase 2's other half. `97_mpp.sh` proved the LAYOUT - that the partition ranges
# ytserv hands out tile a sharded table exactly once. This proves the ENGINE link:
# that a server function gets a live DataFusion session and can execute that
# layout's partials on it, in parallel.
#
# ## Why this is possible after all
#
# The earlier note said an end-to-end DataFusion query "needs a running Ballista
# scheduler and a PyPI package, neither of which exists here". The package does
# exist (`ballista` on PyPI, 54.1.0), and it ships `BallistaScheduler` +
# `BallistaExecutor`, so the scheduler can be started IN the node container - no
# separate service, no image change. rppd dials `localhost:50050` in its own
# container, so nothing crosses the docker network.
#
# ## The three things that have to line up, and all three are separate failures
#
# | | what it is | how it fails |
# |---|---|---|
# | `datafusion_url` reaching the running node | ytserv config (`rmc.rs` [df]) | set in the table, never loaded |
# | the `ballista` import | rppd `py.rs` `DATAFUSION_PY` | logged, then `DF` is simply absent |
# | the scheduler answering | `BallistaSessionContext(url)` | logged, then `DF` is simply absent |
#
# The last two both end as "`DF` is not in scope", which a function body sees as
# a `NameError` and nothing else - so the function records whether `DF` was bound
# BEFORE it tries to use it. Without that, a config that never loaded and a
# scheduler that never answered are the same empty sink.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== mpp/df: a parallel analytic executed by DataFusion, driven from rppd =="

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DF_PORT="${YX_DF_PORT:-50050}"
DF_URL="${YX_DF_URL:-df://localhost:$DF_PORT}"
ROWS="${YX_MPP_ROWS:-2000}"
PARTS="${YX_MPP_PARTS:-4}"

# ── 1. the ballista package, on every node ─────────────────────────────────
#
# Every node, not just the leader: the function runs wherever rppd dispatches
# it, and a node whose python cannot import ballista silently has no DF.
# `apt-get update` first - the node image removes /var/lib/apt/lists, so an
# install without it fails and pip3 is simply absent (94_clickhouse.sh hit
# exactly this and reported it as a package problem).
echo "  installing ballista on ${#NODES[@]} nodes (58MB wheel each, in parallel)..."
pids=()
for n in "${NODES[@]}"; do
	rh "docker exec $n sh -c 'command -v pip3 >/dev/null 2>&1 || { apt-get update -q >/dev/null 2>&1; apt-get install -qy python3-pip >/dev/null 2>&1; }; \
	    python3 -c \"import ballista\" 2>/dev/null || pip3 install --quiet --break-system-packages ballista >/dev/null 2>&1'" \
		>/dev/null 2>&1 &
	pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done

have=0; missing=""
for n in "${NODES[@]}"; do
	if [ -n "$(rh "docker exec $n python3 -c 'import ballista; print(1)'" 2>/dev/null)" ]; then
		have=$((have + 1))
	else
		missing="$missing $n"
	fi
done
[ "$have" = "${#NODES[@]}" ] \
	&& ok "ballista imports on all ${#NODES[@]} nodes" \
	|| bad "ballista is missing on:$missing ($have of ${#NODES[@]}) - those nodes \
cannot bind DF at all (PyPI only; the deb cannot declare it)"

# The symbol rppd actually reaches for. A package that imports but does not
# expose this leaves DF unbound with an AttributeError in the log - worth
# separating from "not installed", because the fix is different.
sym="$(rh "docker exec ${NODES[0]} python3 -c 'import ballista; print(hasattr(ballista,\"BallistaSessionContext\"))'" 2>/dev/null || true)"
check "the package exposes BallistaSessionContext (what rppd imports)" "True" "$sym"

# ── 2. the scheduler daemon, defined here and STARTED AFTER THE RESTART ────
#
# Scheduler on :50050, executor on :50051, both loopback - all rppd needs, since
# it runs in the same container.
#
# Started after `restart_all`, not before, because `restart_all` restarts the
# CONTAINERS and that kills every process in them. Starting it up here and
# checking it here passed, and then the scheduler was dead by the time the
# function ran.
#
# The liveness guard connects to the PORT. Two cheaper guards both lied:
# `pgrep -f /tmp/dfd.py` matches the enclosing `sh -c` command line, which
# contains that very path, so it always found a "running" daemon and never
# started one; and `grep "executor started" /tmp/dfd.log` survives a container
# restart in the writable layer, so it reported a dead daemon as alive.
#
# Staged as base64 through `rh`, NOT written to a local file and `docker cp`'d:
# `rh` is `ssh $YX_HOST`, so a path only this box has does not exist where the
# command runs.
DFD_PY="$(printf '%s' 'from ballista import BallistaScheduler, BallistaExecutor
import time, sys
s = BallistaScheduler(); s.start()
sys.stderr.write("scheduler started\n"); sys.stderr.flush()
time.sleep(3)
e = BallistaExecutor(); e.start()
sys.stderr.write("executor started\n"); sys.stderr.flush()
s.wait_for_termination()' | base64 -w0)"

df_up() { # df_up — (re)start the daemon on every node and report how many answer
	local n up=0 down="" live
	for n in "${NODES[@]}"; do
		rh "docker exec $n sh -c 'echo $DFD_PY | base64 -d > /tmp/dfd.py; \
		    python3 -c \"import socket; socket.create_connection((\\\"127.0.0.1\\\",$DF_PORT),2)\" 2>/dev/null \
		    || { rm -f /tmp/dfd.log; nohup python3 /tmp/dfd.py > /tmp/dfd.log 2>&1 & } ; sleep 1'" \
			>/dev/null 2>&1 || true
	done
	for n in "${NODES[@]}"; do
		live=""
		for _ in $(seq 1 12); do
			live="$( { rh "docker exec $n sh -c 'python3 -c \"import socket; socket.create_connection((\\\"127.0.0.1\\\",$DF_PORT),2); print(1)\" 2>/dev/null || true'" 2>/dev/null || true; } | tr -d ' \n')"
			[ "${live:-0}" = "1" ] && break
			sleep 3
		done
		if [ "${live:-0}" = "1" ]; then up=$((up + 1)); else down="$down $n"; fi
	done
	DF_DOWN="$down"
	echo "$up"
}

# ── 3. point the cluster at it ─────────────────────────────────────────────
#
# `cfg_write` + the restart below: the STARTUP path, because a runtime config
# change reaches the leader and not the followers (PLAN.md F8).
for n in "${NODES[@]}"; do
	cfg_write "$n" serve_rppd C true
	cfg_write "$n" datafusion_url C "$DF_URL"
done

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

# mp_t is the subject table, sharded exactly as in 97_mpp.sh so the layout this
# reads is the one that was proven to tile. df_t is only a trigger to dispatch
# the function; df_sink is where the function reports.
SHARD="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg \
	'shard=owner; outer=pin; recon=report' | tail -1)"
PYCFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'on_commit_python' | tail -1)"
[ -n "$SHARD" ] && [ -n "$PYCFG" ] \
	&& ok "the shard and on_commit_python configs encode" \
	|| { bad "--encode-table-cfg produced nothing"; summary; }

for n in "${NODES[@]}"; do
	q "$n" "$RPPD_DDL
	        drop table if exists mp_t;
	        create table mp_t (id bigint primary key, owner text, amount bigint);
	        drop table if exists df_t;
	        create table df_t (id bigint primary key, v text);
	        drop table if exists df_sink;
	        create table df_sink (id bigserial primary key, stage text, value text);" >/dev/null
done
register_table public.mp_t "$SHARD"
register_table public.df_t "$PYCFG"

# Seeded out of band, as in 97: the subject is the layout over a populated
# table, not replicating 2000 rows through 2PC.
echo "  seeding $ROWS rows on every node (out of band)..."
for n in "${NODES[@]}"; do
	trg="$(q "$n" "select tgname from pg_trigger where tgrelid='mp_t'::regclass and not tgisinternal and (tgtype & 1) = 1 limit 1")"
	q "$n" "alter table mp_t disable trigger ${trg:-user};
	        insert into mp_t (id, owner, amount)
	          select g, 'own-'||(g % 4), g from generate_series(1,$ROWS) g
	        on conflict do nothing;
	        alter table mp_t enable trigger ${trg:-user};" >/dev/null
done

FN="$(cat "$HERE/98_mpp_df.py")"
for n in "${NODES[@]}"; do
	q "$n" "delete from rppd_function where schema_table='public.df_t';
	        insert into rppd_function (code, checksum, schema_table, topic, fn_logging, verbose_debug)
	        values (\$fn\$$FN\$fn\$, 'na', 'public.df_t', '', true, true)" >/dev/null
done

restart_all
await_cluster
sleep 10

# ── 4. the scheduler, now that the containers have stopped moving ──────────
echo "  starting a Ballista scheduler + executor on ${#NODES[@]} nodes..."
DF_DOWN=""
dfup="$(df_up)"
[ "$dfup" = "${#NODES[@]}" ] \
	&& ok "a Ballista scheduler is listening on :$DF_PORT on all ${#NODES[@]} nodes" \
	|| bad "no scheduler on:$DF_DOWN ($dfup of ${#NODES[@]})"

# DataFusion answers, out of band - the equivalent of 94's "ClickHouse answers
# SELECT 1". If this fails nothing downstream is about ytserv.
df_probe="$( { rh "docker exec ${NODES[0]} python3 -c '
from ballista import BallistaSessionContext
print(BallistaSessionContext(\"$DF_URL\").sql(\"select 41+1 as a\").collect()[0].column(0)[0].as_py())
' 2>/dev/null" 2>/dev/null || true; } | tr -d ' \n')"
check "DataFusion answers a query on $DF_URL" "42" "$df_probe"

L=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in *Leader) L="$n";; esac
done
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }

# Read the LIVE config, not the table: `datafusion_url` written and not loaded
# is exactly the failure that would otherwise be blamed on Ballista.
check "$L is running with datafusion_url set" "$DF_URL" "$(info "$L" E cfg.datafusion_url)"
check "...and with serve_rppd on" "true" "$(info "$L" E cfg.serve_rppd)"

q "$L" "insert into rppd_config (host, host_name, master) values ('$L:7421','$L',true)
        on conflict do nothing" >/dev/null

# ── 4. trigger the function ────────────────────────────────────────────────
echo "  writing a row to df_t to dispatch the analytic..."
q "$L" "begin; insert into df_t values (1,'go'); select yt_complete(true); commit;" >/dev/null 2>&1

stages=0
for _ in $(seq 1 24); do
	stages="$(q "$L" "select count(*) from df_sink")"
	[ "${stages:-0}" -ge 1 ] && break
	sleep 5
done
if [ "${stages:-0}" -lt 1 ]; then
	err="$(q "$L" "select coalesce(error_msg,'<none>') from rppd_function_log order by id desc limit 1")"
	bad "the function never ran - df_sink is empty; last rppd error: ${err:-<no log row>}"
	summary
fi
ok "the server function ran and reported (${stages} stage rows)"

echo "  df_sink:"
q "$L" "select '     '||stage||' = '||value from df_sink order by id" || true

get() { q "$L" "select value from df_sink where stage='$1' order by id desc limit 1" 2>/dev/null; }

# ── 5. what it found ───────────────────────────────────────────────────────
bound="$(get df_bound)"
if [ "$bound" = "yes" ]; then
	ok "DF is bound in the server function - rppd dialled the scheduler"
else
	logline="$(rh "docker logs $L 2>&1 | grep -i 'datafusion\|ballista' | tail -2" 2>/dev/null || true)"
	bad "DF is NOT bound in the function (df_bound=[${bound:-<absent>}]) although \
datafusion_url is live and the scheduler answers out of band; ytserv log says: \
${logline:-<nothing about datafusion>}"
	summary
fi

check "DataFusion answered from inside the function" "42" "$(get df_probe)"
check "the function read the partition layout from yt_info" "$PARTS" "$(get partitions)"

# The payoff: PARTS partials, each executed by DataFusion, all in flight at
# once, summing to what PostgreSQL says for the whole table. A layout that
# overlapped would over-count and one with a gap would under-count - both
# silently, which is why this compares rather than just checks for a number.
#
# The emptiness guard is not defensive noise: when the function died before this
# stage, `check` compared "" against "" and reported the payoff assertion as a
# PASS. An equality test over two absent values is the easiest green in testing
# and measures nothing.
pg_whole="$(get pg_whole)"
combined="$(get df_combined)"
echo "     partials: $(get df_partials)   rows per partition: $(get part_rows)"
if [ -z "$pg_whole" ] || [ -z "$combined" ]; then
	bad "no aggregate to compare (pg_whole=[${pg_whole:-<absent>}] \
df_combined=[${combined:-<absent>}]) - the function did not reach the partials"
else
	check "the DataFusion partials sum to PostgreSQL's whole-table aggregate" \
		"$pg_whole" "$combined"
fi

fnerr="$(get error)"
[ -z "$fnerr" ] \
	&& ok "the function completed with no error" \
	|| bad "the function recorded an error: $fnerr"

summary
