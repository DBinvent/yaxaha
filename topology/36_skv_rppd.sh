#!/usr/bin/env bash
# [skv] The secret store's first consumer, phase P6 (yt-pgxt ytserv/skv-secrets.md,
# "Who may read"): a python server function reads a value as SECRET.get(name),
# for the names its rppd_function.secret_names lists and no other. The value is
# opened in ytserv's memory with the cluster master key (rppd gets ytserv's opener
# as a handle) and reaches the interpreter only.
#
# ## What is asserted
#
# R1 the store on, genesis, every node approved, the secret put on the leader
# R2 a commit on a table with on_commit_python runs the function on the rppd
#    master: it read the listed secret - the sink holds the value's SHA-256
# R3 a name it does not list is refused (PermissionError)
# R4 the plaintext is in no table: not the sink, not rppd_function_log, not the
#    config table
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/skv_lib.sh"
echo "== skv rppd: a server function reads a secret, and only the ones it lists =="

# As 92_rppd.sh, with the [skv] column rppd.yaml declares (rppd 0.2.13+).
RPPD_DDL="
create table if not exists rppd_config (
    id serial primary key,
    host varchar(64) not null unique,
    host_name varchar(64) not null unique,
    active_since timestamptz default current_timestamp,
    max_db_connections int not null default 10,
    master bool unique);
drop table if exists rppd_function_log;
drop table if exists rppd_function;
create table rppd_function (
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
    env json, sign json,
    secret_names text);
create table rppd_function_log (
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
V="rppd-secret-$RANDOM-$RANDOM"
WANT="sha:$(printf '%s' "$V" | sha256sum | cut -d' ' -f1)"
FN='import hashlib
cur = DB.cursor()
v = SECRET.get("fn_secret")
cur.execute("insert into skv_sink (data) values (%s)", ("sha:" + hashlib.sha256(v.encode()).hexdigest(),))
try:
    SECRET.get("not_listed")
    cur.execute("insert into skv_sink (data) values (%s)", ("LEAK",))
except PermissionError:
    cur.execute("insert into skv_sink (data) values (%s)", ("refused",))
DB.commit()'

for n in "${NODES[@]}"; do
	q "$n" "$RPPD_DDL
	        drop table if exists skv_t; create table skv_t (id bigint primary key, v text);
	        drop table if exists skv_sink; create table skv_sink (id serial primary key, data text);
	        insert into rppd_function (code, checksum, schema_table, topic, fn_logging, verbose_debug, secret_names)
	        values (\$fn\$$FN\$fn\$, 'na', 'public.skv_t', '', true, true, 'fn_secret');" >/dev/null
	cfg_write "$n" serve_rppd C true
done
CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'on_commit_python' | tail -1)"
[ -n "$CFG" ] || { bad "--encode-table-cfg 'on_commit_python' produced nothing"; summary; }
register_table public.skv_t "$CFG"
# ytserv reads the A row and rppd_function at startup
restart_all
await_cluster
L="$(leader)"
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }
q "$L" "insert into rppd_config (host, host_name, master) values ('$L:7421','$L',true) on conflict do nothing" >/dev/null
sleep 8

# ── R1 ───────────────────────────────────────────────────────────────────────
skv_cleanup
if skv_setup; then ok "R1 the store on, genesis, every node approved: all hold v1"; else bad "R1 v1 not held on:$(not_holding 1)"; fi
o="$(printf '%s' "$V" | yx "$L" --skv put fn_secret)"
case "$o" in *"sealed under"*) ok "R1 fn_secret put on the leader" ;; *) bad "R1 put: $(echo "$o" | tail -1)" ;; esac
sleep 4 # every node's store refreshed from the new row

# ── R2, R3 ───────────────────────────────────────────────────────────────────
L="$(leader)"
q "$L" "begin; insert into skv_t values ($RANDOM,'go'); select yt_complete(true); commit;" >/dev/null
for _ in $(seq 1 20); do [ "$(q "$L" "select count(*) from skv_sink")" -ge 2 ] 2>/dev/null && break; sleep 2; done
check "R2 the function read the listed secret: the sink holds its SHA-256" "t" \
	"$(q "$L" "select count(*) > 0 from skv_sink where data='$WANT'")"
check "R3 a name it does not list is refused" "t" "$(q "$L" "select count(*) > 0 from skv_sink where data='refused'")"
check "R3 ...and nothing was opened for it" "0" "$(q "$L" "select count(*) from skv_sink where data='LEAK'")"
err="$(q "$L" "select coalesce(error_msg,'') from rppd_function_log order by id desc limit 1")"
[ -z "$err" ] && ok "R2 the run logged no error" || bad "R2 the run failed: $err"

# ── R4 ───────────────────────────────────────────────────────────────────────
leak=""
for n in "${NODES[@]}"; do
	c="$(q "$n" "select (select count(*) from skv_sink where data like '%$V%')
	           + (select count(*) from rppd_function_log where coalesce(output,'') like '%$V%' or coalesce(error_msg,'') like '%$V%')
	           + (select count(*) from $YX_CFG where value like '%$V%')")"
	[ "${c:-1}" = 0 ] || leak="$leak $n"
done
[ -z "$leak" ] && ok "R4 the plaintext is in no table, on any node" || bad "R4 the plaintext found on:$leak"

skv_cleanup
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists skv_t; drop table if exists skv_sink; delete from rppd_function where schema_table='public.skv_t'" >/dev/null
	cfg_delete "$n" public.skv_t A
done
summary
