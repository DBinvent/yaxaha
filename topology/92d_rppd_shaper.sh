#!/usr/bin/env bash
# [shaper] rppd's traffic shaper (yt-pgxt resilience.md, phase 2): how many calls
# of a pipeline process (pp) run at once, and how often, per function per node.
#
# Each function has an adaptive concurrency limit (`max_parallel` its ceiling,
# lowered while the function slows down past `target_ms`), a hard rate cap on top
# (`rate_per_sec`, `burst`) and a backlog notice (`max_backlog`). A call that may
# not start waits in the shaper; the other functions keep running.
#
# The functions record when each call ran (bk_run: node, function, start, end) in
# their node's own database, so every check is per node - the shaper is.
#
# ## What is asserted
#
# D1 the limit: a function with max_parallel = 2 whose calls take 1 s never runs
#    more than 2 at once on a node, and every message runs
# D2 the rate cap: rate_per_sec = 2 spaces the starts on a node at least ~0.5 s
#    apart, and every message runs
# D3 a capped function does not delay another: while D2's function has a
#    backlog, a third function's messages run at once
# D4 max_backlog: D2's function waiting over 3 sends one backlog 'over' notice
#    to notify_q, and one 'under' once it drained
#
# Not here: the limit's adaptation (it falls while calls slow down, climbs back,
# one outlier does not halve it, throttled/recovered) - rppd's unit tests drive it
# with scripted latencies (shaper.rs); a live downstream that slows on cue would
# measure the test's timing more than the shaper.
#
# Timing: ~7 min (two restarts to set up, one to clean up).
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== rppd shaper: concurrency limit, rate cap, backlog notice, per function per node =="

SH_KEEP="${SH_KEEP:-0}"
F_L=9231; F_R=9232; F_F=9233; F_N=9234
Q_L=/q/sh_limit; Q_R=/q/sh_rate; Q_F=/q/sh_free; Q_N=/q/sh_notify
NL=8; NR=10; NF=3

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
VIA="${VOTERS[0]}"

qt() { # qt <node> <sql> -> the value, or "" - never fails, never hangs a poll
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}
sum() {
	local n c t=0
	for n in "${NODES[@]}"; do c="$(qt "$n" "$1")"; [[ "$c" =~ ^[0-9]+$ ]] && t=$((t + c)); done
	printf '%s' "$t"
}
maxof() { # maxof <sql returning one number> -> the largest over every node
	local n c m=0
	for n in "${NODES[@]}"; do c="$(qt "$n" "$1")"; [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt "$m" ] && m="$c"; done
	printf '%s' "$m"
}
POLL_V=""; POLL_T=0
until_ge() {
	local secs="$1" min="$2"; shift 2
	local t0=$SECONDS
	while :; do
		POLL_V="$("$@" 2>/dev/null || true)"
		POLL_T=$((SECONDS - t0))
		if [[ "$POLL_V" =~ ^[0-9]+$ ]] && [ "$POLL_V" -ge "$min" ]; then return 0; fi
		[ "$POLL_T" -ge "$secs" ] && return 1
		sleep 2
	done
}
put() {
	local i
	for i in 1 2 3; do
		rh "docker exec $VIA /usr/local/bin/yxetcd $VIA:7421 put $1/producer/s$(date +%s%N) $2" >/dev/null 2>&1 && return 0
		sleep 1
	done
	return 1
}
diag() {
	local n
	echo "  diagnostics:"
	for n in "${NODES[@]}"; do
		qt "$n" "select '     $n run fn '||fn||' '||to_char(t0,'HH24:MI:SS.MS')||'-'||coalesce(to_char(t1,'HH24:MI:SS.MS'),'?') from bk_run order by t0"
		qt "$n" "select '     $n seen '||coalesce(body::text, raw) from sh_seen order by at"
		rh "docker logs --since 15m $n 2>&1 | { grep -E 'shaper' || true; } | tail -4 | sed 's/^/     $n log: /'" 2>/dev/null || true
	done
	return 0
}

CLEANED=0
on_exit() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set +e
	if [ "$SH_KEEP" = 1 ]; then echo "  SH_KEEP=1: functions and tables left in place"; return 0; fi
	local n
	for n in "${NODES[@]}"; do
		q "$n" "delete from rppd_function where id between $F_L and $F_N;
		        delete from rppd_function_log where fn_id between $F_L and $F_N;
		        delete from rppd_function_state where fn_id between $F_L and $F_N;
		        drop table if exists bk_run; drop table if exists sh_seen;" >/dev/null 2>&1
	done
	echo "  cleanup: functions and tables removed; restarting"
	restart_all
	await_cluster
}
trap on_exit EXIT

# ── setup ────────────────────────────────────────────────────────────────────
have=0
for n in "${NODES[@]}"; do rh "docker exec $n test -x /usr/local/bin/yxetcd" >/dev/null 2>&1 && have=$((have+1)); done
if [ "$have" -lt "${#NODES[@]}" ]; then
	YXETCD_SRC="${YXETCD_SRC:-$REPO_ROOT/../etcd/target/release/examples/yxetcd}"
	[ -x "$YXETCD_SRC" ] || { bad "yxetcd is on $have of ${#NODES[@]} nodes and there is no binary at $YXETCD_SRC"; summary; }
	STAGE=/tmp/yxetcd-stage
	if [ "$YX_HOST" = "local" ]; then cp "$YXETCD_SRC" "$STAGE"; else scp -q "$YXETCD_SRC" "$YX_HOST:$STAGE"; fi
	have=0
	for n in "${NODES[@]}"; do rh "docker cp $STAGE $n:/usr/local/bin/yxetcd" >/dev/null 2>&1 && have=$((have+1)); done
fi
check "the yxetcd client is on every node" "${#NODES[@]}" "$have"

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
drop table if exists bk_run;
create table bk_run (id serial primary key, fn int not null, k text, t0 timestamptz not null, t1 timestamptz);
drop table if exists sh_seen;
create table sh_seen (id serial primary key, raw text, body jsonb, at timestamptz not null default clock_timestamp());
"
for n in "${NODES[@]}"; do q "$n" "$RPPD_DDL" >/dev/null; cfg_write "$n" serve_rppd C true; done
# the first restart adds the breaker's and the shaper's columns (SchemaGuard)
restart_all
await_cluster
cols="$(for n in "${NODES[@]}"; do qt "$n" "select count(*) from information_schema.columns
	where table_name = 'rppd_function' and column_name in ('max_parallel','min_parallel','target_ms','rate_per_sec','burst','max_backlog')"; done | grep -cx 6 || true)"
check "rppd added the shaper's six columns on every node" "${#NODES[@]}" "$cols"

run_code() { # records when it ran; sleeps $2 s
	cat <<PY
import time
cur = DB.cursor()
cur.execute("insert into bk_run (fn, k, t0) values (%s, %s, clock_timestamp()) returning id", ($1, str(KEY)))
rid = cur.fetchone()[0]
DB.commit()
time.sleep($2)
cur.execute("update bk_run set t1 = clock_timestamp() where id = %s", (rid,))
DB.commit()
PY
}
obs_code() {
	cat <<PY
import json
raw = VALUE.decode('utf-8') if isinstance(VALUE, (bytes, bytearray)) else str(VALUE)
try:
    json.loads(raw)
    body = raw
except Exception:
    body = None
cur = DB.cursor()
cur.execute("insert into sh_seen (raw, body) values (%s, %s::jsonb)", (raw, body))
DB.commit()
PY
}
FN_SQL="delete from rppd_function where id between $F_L and $F_N;
insert into rppd_function (id, code, checksum, schema_table, topic, queue, fn_logging,
    max_parallel, min_parallel, target_ms, rate_per_sec, burst, max_backlog, notify_q) values
 ($F_L, \$fn\$$(run_code $F_L 1)\$fn\$, 'na', '$Q_L', '', false, false, 2, 1, 60000, 0, 1, 0, null),
 ($F_R, \$fn\$$(run_code $F_R 0.05)\$fn\$, 'na', '$Q_R', '', false, false, 0, 1, 0, 2, 1, 3, '$Q_N'),
 ($F_F, \$fn\$$(run_code $F_F 0.05)\$fn\$, 'na', '$Q_F', '', false, false, 0, 1, 0, 0, 1, 0, null),
 ($F_N, \$fn\$$(obs_code)\$fn\$, 'na', '$Q_N', '', false, false, 0, 1, 0, 0, 1, 0, null);"
for n in "${NODES[@]}"; do q "$n" "$FN_SQL" >/dev/null; done
restart_all
await_cluster
sleep 5

# ── D1: the limit ────────────────────────────────────────────────────────────
echo
echo "-- D1 max_parallel = 2, calls of 1 s: $NL messages at once"
for i in $(seq 1 "$NL"); do put "$Q_L" "l$i" || bad "D1 put l$i failed"; done
until_ge 60 "$NL" sum "select count(*) from bk_run where fn = $F_L and t1 is not null" \
	&& ok "D1 every message ran ($POLL_V) in ${POLL_T}s" || { bad "D1 [${POLL_V:-0}] of $NL ran"; diag; }
# the most calls of F_L running at one instant on a node: at each start, the calls
# that started earlier (or then) and had not ended
conc="$(maxof "select coalesce(max(c), 0) from (select (select count(*) from bk_run b where b.fn = $F_L
	and b.t0 <= a.t0 and b.t1 > a.t0) c from bk_run a where a.fn = $F_L) x")"
[ "${conc:-9}" -le 2 ] && [ "${conc:-0}" -ge 1 ] && ok "D1 never more than 2 at once on a node (most seen: $conc)" \
	|| { bad "D1 up to [$conc] calls ran at once on a node with max_parallel = 2"; diag; }

# ── D2-D4: the rate cap, another function, the backlog notice ────────────────
echo
echo "-- D2 rate_per_sec = 2: $NR messages at once; D3 meanwhile $NF to an uncapped function"
for i in $(seq 1 "$NR"); do put "$Q_R" "r$i" || bad "D2 put r$i failed"; done
sleep 1
t_free="$(date +%s%3N)"
for i in $(seq 1 "$NF"); do put "$Q_F" "f$i" || bad "D3 put f$i failed"; done
until_ge 20 "$NF" sum "select count(*) from bk_run where fn = $F_F and t1 is not null" \
	&& ok "D3 the uncapped function's messages ran in ${POLL_T}s while the capped one waited" \
	|| { bad "D3 [${POLL_V:-0}] of $NF ran"; diag; }
until_ge 60 "$NR" sum "select count(*) from bk_run where fn = $F_R and t1 is not null" \
	&& ok "D2 every capped message ran ($POLL_V) in ${POLL_T}s" || { bad "D2 [${POLL_V:-0}] of $NR ran"; diag; }
# the tightest spacing of consecutive starts on a node, in ms
gap="$(for n in "${NODES[@]}"; do qt "$n" "select coalesce(min(extract(epoch from t0 - p) * 1000)::int, 99999) from
	(select t0, lag(t0) over (order by t0) p from bk_run where fn = $F_R) x where p is not null"; done | sort -n | head -1)"
[ "${gap:-0}" -ge 400 ] && ok "D2 starts on a node at least ${gap} ms apart (cap: 2 per second)" \
	|| { bad "D2 two starts only [$gap] ms apart with rate_per_sec = 2"; diag; }
until_ge 30 1 sum "select count(*) from sh_seen where body->>'kind'='backlog' and body->>'state'='over'" \
	&& ok "D4 a backlog 'over' notice reached $Q_N" || { bad "D4 no backlog 'over' notice"; diag; }
until_ge 30 1 sum "select count(*) from sh_seen where body->>'kind'='backlog' and body->>'state'='under'" \
	&& ok "D4 ...and one 'under' once it drained" || { bad "D4 no backlog 'under' notice"; diag; }
over="$(sum "select count(*) from sh_seen where body->>'kind'='backlog' and body->>'state'='over'")"
under="$(sum "select count(*) from sh_seen where body->>'kind'='backlog' and body->>'state'='under'")"
check "D4 as many 'under' as 'over' notices - one each per node that went over" "$over" "$under"

summary
