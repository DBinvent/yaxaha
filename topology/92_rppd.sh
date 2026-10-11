#!/usr/bin/env bash
# [server-functions] RPPD: Python triggered by a cluster commit.
#
#   "RPPD is the server-function runtime: Python triggered by insert, update and
#    delete, deployed as functions rather than as services - the shape of AWS
#    Lambda or Azure Functions, running next to the data and without the vendor.
#    Functions are registered in the configuration table and dispatched by the
#    node that observes the change, so there is no external event bus to operate."
#
# ## Which of the two dispatch paths this tests
#
# The rppd README drives functions from a per-row `rppd_event()` trigger. That
# path does NOT exist in this build: the C extension (`ytpgc`) exports no
# `rppd_event` - `nm -D` on the shipped `.so` lists `yt_complete`, `yt_info`,
# `yt_synchronize`, `yt_diff_apply` and friends and nothing else. The trigger
# form is pgrx-era (`ytpgxt.sql` still carries its DDL, referencing
# `src/pg_rppd.rs`).
#
# What this build has is `CfgTabl.on_commit_python` - "Use this flag instead of
# RPPD trigger for every row, so data will be available" - dispatched from
# `rppd_etcd.rs::send_to_rppd` after the CLUSTER commit rather than inside the
# row trigger. That is the path the product text describes ("dispatched by the
# node that observes the change") and the one asserted here.
#
# ## Requirements it has to set up itself
#
# `serve_rppd` is off by default, on purpose: "a cluster that silently starts
# executing rows a tool wrote into a table is the worst possible default"
# (`rmc.rs`). The `rppd_*` tables are not in `yaxaha--0.5.sql` either, so the
# fixture installs them - the columns ytserv actually selects, and no
# `rppd_event` triggers, since the function does not exist.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== server functions: a python function runs on a cluster commit =="

# Taken from `rppd/rppd-pg-c/pg_setup.sql`, the CURRENT schema - not from
# `ytpgc/ytpgxt.sql`, which is the pgrx-era copy and is missing
# `rppd_function_log.output`. That one column cost a whole run: the runtime died
# at startup with `column "output" does not exist`, nothing was dispatched, and
# the test reported "the python function did not run" - which was true, and had
# nothing to do with python.
#
# The two tables ytserv queries at startup, verbatim from its own SQL:
#   select id, host, host_name, active_since, master, max_db_connections from rppd_config ...
#   select id, code, checksum, schema_table, topic, queue, cleanup_logs_min,
#          priority, fn_logging, verbose_debug from rppd_function
RPPD_DDL="
create table if not exists rppd_config (
    id serial primary key,
    host varchar(64) not null unique,
    host_name varchar(64) not null unique,
    active_since timestamptz default current_timestamp,
    max_db_connections int not null default 10,
    master bool unique);
create table if not exists rppd_function (
    id serial primary key,
    code text not null,
    checksum varchar(64) not null,
    schema_table varchar(64) not null,
    topic varchar(64) not null default '',
    priority int not null default 1,
    queue bool not null default true,
    cleanup_logs_min int not null default 0,
    fn_logging bool not null default false,
    verbose_debug bool not null default false,
    env json, sign json);
create table if not exists rppd_function_log (
    id bigserial primary key,
    node_id int not null,
    fn_id int not null,
    trig_value json,
    trig_type int not null default 0,
    started_at timestamptz not null default current_timestamp,
    took_ms bigint,
    output text,
    error_msg text);
"

# The sink the function writes to, and the source that triggers it.
for n in "${NODES[@]}"; do
	q "$n" "$RPPD_DDL
	        drop table if exists sf_t; create table sf_t (id bigint primary key, v text);
	        drop table if exists sf_sink; create table sf_sink (id serial primary key, data text);" >/dev/null
	cfg_write "$n" serve_rppd C true
done

CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'on_commit_python' | tail -1)"
[ -n "$CFG" ] && ok "on_commit_python encodes to a config ($CFG)" \
	|| bad "--encode-table-cfg 'on_commit_python' produced nothing"
register_table public.sf_t "$CFG"
restart_all
await_cluster
wait_writable n1 n2 sf_t || { bad "cluster never became writable"; summary; }

L=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in *Leader) L="$n";; esac
done
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }

check "serve_rppd is on for $L" "true" \
	"$(q "$L" "select value from $YX_CFG where module='C' and name='serve_rppd'")"

# ── register the node, and let the cluster register the rest ───────────────
#
# One seed row, then ytserv fills in the roster itself - which is not what this
# test first assumed. It inserted `host_name='<container>'` on every node and
# then counted rows by that name, and got zero: ytserv REWRITES `host_name` to
# the node's uuid and adds a row per peer keyed by its IP. So the seed is one
# row and the assertion is about what the cluster did with it.
#
# `master` is a UNIQUE bool column, so `true` on a second node is a constraint
# violation rather than an election - exactly one seed carries it.
q "$L" "insert into rppd_config (host, host_name, master) values ('$L:7421','$L',true)
        on conflict do nothing" >/dev/null
sleep 8

rows="$(q "$L" "select count(*) from rppd_config")"
echo "     rppd_config rows: ${rows:-0} (seeded 1)"
[ "${rows:-0}" -ge "${#NODES[@]}" ] \
	&& ok "ytserv registered the roster in rppd_config ($rows rows for ${#NODES[@]} nodes)" \
	|| bad "rppd_config has ${rows:-0} row(s) for ${#NODES[@]} nodes - the runtime \
did not pick up the cluster"

masters="$(q "$L" "select count(*) from rppd_config where master")"
check "exactly one node is the rppd master" "1" "$masters"

# The function itself. Deliberately minimal: `DB` is the one binding every rppd
# example relies on, so a failure here is "python did not run", not "the test
# guessed a variable name wrong". The marker proves execution; `fn_logging`
# gives a second, code-independent witness in rppd_function_log.
FN='cur = DB.cursor()
cur.execute("insert into sf_sink (data) values (%s)", ("ran",))
DB.commit()
print("rppd test function ran")'

# On EVERY node: rppd_function is a plain local table, and the function runs on
# the rppd master - the leader the restart below elects, which need not be the
# node that leads now (a function on one node ran only when leadership stayed).
for n in "${NODES[@]}"; do
	q "$n" "delete from rppd_function where schema_table='public.sf_t';
        insert into rppd_function (code, checksum, schema_table, topic, fn_logging, verbose_debug)
        values (\$fn\$$FN\$fn\$, 'na', 'public.sf_t', '', true, true)" >/dev/null
done
check "the function is registered" "1" \
	"$(q "$L" "select count(*) from rppd_function where schema_table='public.sf_t'")"

# ytserv caches rppd_function at startup; the row was written after it started.
restart_all
await_cluster
sleep 10
# The leader again: a restart elects afresh, and functions run on the rppd master,
# which is the leader NOW (a non-master's rppd hands the event to it). This test
# picked the leader before the restart and checked only that node - it passed
# while functions ran wherever the client wrote, and failed once they ran where
# the cluster elected (2026-10-11: n4 written to and read, n1 leading).
L=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in *Leader) L="$n";; esac
done
[ -n "$L" ] || { bad "no leader after the restart"; summary; }

# ── the commit that should dispatch it ─────────────────────────────────────
echo "  writing a row to public.sf_t on $L..."
q "$L" "begin; insert into sf_t values (1,'hello'); select yt_complete(true); commit;" >/dev/null
sleep 12

sink="$(q "$L" "select count(*) from sf_sink where data='ran'")"
if [ "${sink:-0}" -gt 0 ]; then
	ok "the python function ran and wrote to the sink"
else
	bad "the python function did not run - sf_sink is empty after a committed \
write to a table configured with on_commit_python"
fi

logged="$(q "$L" "select count(*) from rppd_function_log")"
echo "     rppd_function_log rows: ${logged:-0}"
if [ "${logged:-0}" -gt 0 ]; then
	err="$(q "$L" "select coalesce(error_msg,'<none>') from rppd_function_log order by id desc limit 1")"
	echo "     last error_msg: $err"
	[ "$err" = "<none>" ] \
		&& ok "the execution log records a run with no error" \
		|| bad "the function was dispatched but failed: $err"
else
	bad "nothing in rppd_function_log - the dispatch never reached the runtime"
fi

# ## The python runtime itself
#
# Checked explicitly because it is the most likely single cause of everything
# above failing, and the least obvious from a log line. ytserv links
# `libpython3.12.so.1.0`, which the deb VENDORS - Ubuntu 26.04 dropped python
# 3.12 from its archive entirely (only 3.14 is available). A shared library is
# not an interpreter: `Py_Initialize` needs the standard library, starting with
# `encodings`, and if the deb ships the `.so` without it there is nowhere for
# the runtime to come from.
echo "  python runtime on $L:"
rh "docker exec $L sh -c 'ls /usr/local/lib/yaxaha/ 2>/dev/null | sed \"s/^/     lib: /\"; \
	ls -d /usr/lib/python3.1* 2>/dev/null | sed \"s/^/     stdlib: /\" || echo \"     stdlib: NONE\"'" 2>/dev/null

stdlib="$(rh "docker exec $L sh -c 'ls -d /usr/lib/python3.12 /usr/local/lib/yaxaha/python3.12 2>/dev/null | head -1'" 2>/dev/null || true)"
[ -n "$stdlib" ] \
	&& ok "a python 3.12 standard library is present ($stdlib)" \
	|| bad "libpython3.12 is vendored with NO standard library, and 26.04 has no \
python3.12 package to supply one - Py_Initialize cannot succeed, so server \
functions cannot run from this deb"

pyerr="$(rh "docker logs --since 5m $L 2>&1 | { grep -iE 'python|rppd' || true; } | tail -5" 2>/dev/null || true)"
[ -n "$pyerr" ] && printf '     %s\n' "$pyerr"

summary
