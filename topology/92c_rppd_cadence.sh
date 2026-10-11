#!/usr/bin/env bash
# [server-functions] RPPD cadence: a pipeline that goes quiet is noticed.
#
# A pipeline process (pp) feeds an etcd queue `/q/<name>`. A row of `rppd_cron`
# with `cadence = true` names the queue's consumer function (`fn_id`) and the
# EXPECTED cadence as a cron expression. The rppd master - the cluster leader -
# evaluates every 5 s:
#
#   due      the SECOND cron fire after the last message seen (`last_seen`), or
#            after the master started when there never was one - i.e. the end of
#            the first full cron period. '* * * * *', last message 12:00:10 ->
#            next fire 12:01:00 -> due 12:02:00.
#   overdue  ok -> 'watch' (since=now, attempt=1, one message to watch_q), then
#            one more every retry_sec (attempt+1) while on watch;
#            since + watch_min minutes -> 'deadline', ONE message to deadline_q,
#            never repeated. watch_min = 0 goes straight from ok to deadline.
#   message  watch|deadline -> 'ok', attempt 0, and an 'ok' message (`was`,
#            `down_sec`) on the queue of the state it left.
#   bad row  fn not on a /q/ path, or a cron that does not parse: error_msg is
#            set and the row is never evaluated.
#
# Messages are etcd queue producer keys `<q>/producer/<rppd_cron.id>-<epoch_ms>`
# whose value is JSON: {pp, queue, fn_id, state, due_at, last_seen, late_sec,
# attempt} for watch/deadline, {pp, queue, fn_id, state:'ok', was, down_sec,
# last_seen} for ok.
#
# Fixture A, after 92_rppd.sh (serve_rppd, the rppd tables) and 93_etcd.sh
# (serve_etcd, the `yxetcd` client staged into every container).
#
# ## How the test sees what rppd did
#
# - The pp is driven from OUTSIDE, with `yxetcd put /q/<name>/producer/<n>` - the
#   same third-party etcd client 93_etcd.sh uses, so nothing here depends on the
#   code under test to produce its own input.
# - The watch and deadline queues are consumed by two observer functions that
#   insert each message's JSON value into `cad_seen`. A queue message goes to ONE
#   consumer (etcds queue.rs, first watcher that accepts) and that consumer can
#   be on any node, so every count below is a SUM over every node's `cad_seen`.
#   An exactly-once message is therefore exactly one row across the cluster.
# - State is read from `rppd_cron` on the current leader: that is the rppd master,
#   the node that evaluates and persists it.
#
# ## Why every node gets the functions and the rows, and why rppd_cron is synced
#
# rppd loads `rppd_function` and `rppd_cron` at STARTUP from the node's own
# database (no rppd_event triggers in this build - 92_rppd.sh), so the rows are
# written on every node with identical explicit ids before one `restart_all`.
# Any node may become master (C6), and a message carries `pp` = the row id, so
# the id must mean the same row everywhere.
#
# Every node also has its OWN PostgreSQL. A pp message consumed on a follower
# persists `last_seen` there, and the master re-reads `last_seen` from
# `rppd_cron` every tick - so the row has to replicate for the master to see it,
# and for a new master to continue a watch the old one started (C6). The test
# therefore puts `rppd_cron` under cluster sync (register_table); rppd's own
# bare COMMITs then become cluster commits through `yaxaha.auto_complete`.
# `CAD_SYNC=0` leaves it node-local: C1-C5 still mean something when every
# message happens to land on the master, C6's "state persisted" cannot pass.
#
# ## Quorum
#
# C6 stops the leader. At the fixture default (min_cluster_size = every voter)
# a cluster tolerates no node loss (89_recover.sh), so min_cluster_size is
# lowered to a majority for this script and put back on EXIT, with a final
# restart so the restored value and an rppd without the test's functions are
# what the next script starts from.
#
# Timing: ~18-20 min (setup ~2, C1 3, C2 ~5, C3-C5 ~1, C6 ~6, cleanup ~2).
# CAD_KEEP=1 skips the cleanup, for inspecting a failed run.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== rppd cadence: watch, deadline and recovery of a pipeline that goes quiet =="

CAD_SYNC="${CAD_SYNC:-1}"
CAD_KEEP="${CAD_KEEP:-0}"
FEED_SEC=40          # pp message interval: well inside one '* * * * *' period
C1_SEC=180           # how long C1 watches an on-time pp
C6_STOP_SEC=30       # how long the leader container stays stopped in C6

# rppd_function ids and rppd_cron ids, explicit so they agree on every node
F_A=9201; F_B=9202; F_C=9203; F_E=9204; F_D=9205; F_W=9206; F_DL=9207
A=9211    # C1-C3: on time, then watch with retry, deadline, recovery
B=9212    # C4:    watch_min = 0
C=9213    # C6:    watch across a leader failover
D=9214    # C5:    fn on a plain table
E=9215    # C5:    cron that does not parse
Q_A=/q/cad_pp; Q_B=/q/cad_pp0; Q_C=/q/cad_pp6; Q_E=/q/cad_ppe
Q_W=/q/cad_watch; Q_DL=/q/cad_deadline
A_WATCH_MIN=2; A_RETRY=30
C_WATCH_MIN=3

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
NV=${#VOTERS[@]}
MAJ=$(( NV / 2 + 1 ))
[ "$NV" -ge 3 ] || { bad "needs three non-spare nodes for the failover phase, has $NV"; summary; }

TMP="$(mktemp -d)"
STOPPED=""
FEED_PID=""
L=""

# ── helpers ──────────────────────────────────────────────────────────────────

qt() { # qt <node> <sql> -> the value, or "" - never fails, never hangs a poll
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}

# The leader's own yt_info('O') ends in "Leader" with no colon; a follower's says
# "Leader: <uuid>" (24_db_local.sh). A stopped node is not asked.
leader_node() {
	local n
	for n in "${NODES[@]}"; do
		[ "$n" = "$STOPPED" ] && continue
		case "$(info "$n" O cluster 2>/dev/null)" in *Leader) printf '%s' "$n"; return 0;; esac
	done
	return 0
}

rowv() { # rowv <cron-id> <sql-expr> -> evaluated on the leader's rppd_cron row
	qt "$L" "select $2 from rppd_cron where id=$1"
}
row_now() { # same, but asks who leads right now (C6, where that changes)
	local l; l="$(leader_node)"
	qt "${l:-$L}" "select $2 from rppd_cron where id=$1"
}

# SQL over cad_seen.body that cannot error on a malformed message: a cast that
# fails would turn a count into "", read as 0, and blame the wrong thing.
num() { printf "(case when jsonb_typeof(body->'%s')='number' then (body->>'%s')::numeric end)" "$1" "$1"; }
tsf() { printf "(case when body->>'%s' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then (body->>'%s')::timestamptz end)" "$1" "$1"; }
mw() { # mw <watch|deadline> <cron-id> [state] -> where-clause for one row's messages
	local w="q='$1' and body->>'pp'='$2'"
	[ -n "${3:-}" ] && w="$w and body->>'state'='$3'"
	printf '%s' "$w"
}

seen() { # seen <where> -> matching cad_seen rows, summed over every node that answers
	local n c t=0
	for n in "${NODES[@]}"; do
		[ "$n" = "$STOPPED" ] && continue
		c="$(qt "$n" "select count(*) from cad_seen where $1")"
		[[ "$c" =~ ^[0-9]+$ ]] && t=$((t + c))
	done
	printf '%s' "$t"
}
seen_val() { # seen_val <expr> <where> -> the expression on the first matching row found
	local n v
	for n in "${NODES[@]}"; do
		[ "$n" = "$STOPPED" ] && continue
		v="$(qt "$n" "select $1 from cad_seen where $2 order by at limit 1")"
		[ -n "$v" ] && { printf '%s' "$v"; return 0; }
	done
	return 0
}
seen_dump() { # seen_dump <where> -> the matching messages, for a failure to be readable
	local n
	for n in "${NODES[@]}"; do
		[ "$n" = "$STOPPED" ] && continue
		qt "$n" "select '     $n '||q||' '||to_char(at,'HH24:MI:SS')||' '||coalesce(body::text, raw, k)
		         from cad_seen where $1 order by at"
	done
	return 0
}

POLL_V=""; POLL_T=0
until_is() { # until_is <secs> <want> <cmd...> - every 5 s; POLL_V/POLL_T say how it went
	local secs="$1" want="$2"; shift 2
	local t0=$SECONDS
	while :; do
		POLL_V="$("$@" 2>/dev/null || true)"
		POLL_T=$((SECONDS - t0))
		[ "$POLL_V" = "$want" ] && return 0
		[ "$POLL_T" -ge "$secs" ] && return 1
		sleep 5
	done
}
until_ge() { # until_ge <secs> <min> <cmd...> - numeric
	local secs="$1" min="$2"; shift 2
	local t0=$SECONDS
	while :; do
		POLL_V="$("$@" 2>/dev/null || true)"
		POLL_T=$((SECONDS - t0))
		if [[ "$POLL_V" =~ ^[0-9]+$ ]] && [ "$POLL_V" -ge "$min" ]; then return 0; fi
		[ "$POLL_T" -ge "$secs" ] && return 1
		sleep 5
	done
}
in_range() { # in_range <value> <lo> <hi>
	[[ "$1" =~ ^-?[0-9]+$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

# ── the pp: puts from outside, through an ordinary etcd client ──────────────
#
# Through a FOLLOWER (`$TMP/via`), not the leader: C6 stops the leader, and a
# feeder pointed at it would silence the pps C6 is not about.
pp_put() { # pp_put <queue> -> 0 when the put was acknowledged
	local via; via="$(cat "$TMP/via" 2>/dev/null || true)"
	[ -n "$via" ] || return 1
	rh "docker exec $via /usr/local/bin/yxetcd $via:7421 put $1/producer/t$(date +%s%3N) tick" >/dev/null 2>&1
}
pp_put_retry() {
	local i
	for i in 1 2 3; do pp_put "$1" && return 0; sleep 2; done
	return 1
}

# The background feeder: one message to every queue listed in $TMP/feed, every
# FEED_SEC (5 s after a failed put, so a restart does not cost a whole period).
# The list is re-read each round; feed_add / feed_drop are how a phase starts or
# ends a silence. `mapfile`, not `while read <file`: in remote mode `rh` is ssh,
# which would swallow the rest of the list from stdin.
feeder() {
	set +e
	local qs qp failed
	while :; do
		failed=0
		mapfile -t qs < "$TMP/feed"
		for qp in "${qs[@]}"; do
			[ -n "$qp" ] || continue
			if pp_put "$qp"; then echo "$qp $(date +%s)" >> "$TMP/fed"; else failed=1; fi
		done
		if [ "$failed" = 1 ]; then sleep 5; else sleep "$FEED_SEC"; fi
	done
}
feed_add()  { grep -qxF "$1" "$TMP/feed" 2>/dev/null || echo "$1" >> "$TMP/feed"; return 0; }
feed_drop() { { grep -vxF "$1" "$TMP/feed" || true; } > "$TMP/feed.new"; mv "$TMP/feed.new" "$TMP/feed"; }
fed_count() { { grep -c "^$1 " "$TMP/fed" 2>/dev/null || true; } | head -1; }

pick_via() { # pick_via <not-this-node> -> a voter other than the given one
	local n
	for n in "${VOTERS[@]}"; do [ "$n" != "$1" ] && { echo "$n" > "$TMP/via"; return 0; }; done
	return 0
}

rows_dump() {
	qt "${L:-${VOTERS[0]}}" "select '     row '||id||' state='||state||' attempt='||attempt
	        ||' since='||coalesce(to_char(since,'HH24:MI:SS'),'-')
	        ||' last_seen='||coalesce(to_char(last_seen,'HH24:MI:SS'),'-')
	        ||' error='||coalesce(left(error_msg,80),'-')
	        from rppd_cron where id between $A and $E order by id"
	return 0
}

diag() {
	echo "  diagnostics:"
	rows_dump
	local n
	for n in "${NODES[@]}"; do
		[ "$n" = "$STOPPED" ] && continue
		qt "$n" "select '     $n fn '||fn_id||': '||left(error_msg,160) from rppd_function_log
		         where fn_id between $F_A and $F_DL and error_msg is not null order by id desc limit 2"
	done
	[ -n "$L" ] && rh "docker logs --since 30m $L 2>&1 | { grep -iE 'cadence|rppd_cron' || true; } | tail -8 | sed 's/^/     log: /'" 2>/dev/null || true
	return 0
}

# ── cleanup ──────────────────────────────────────────────────────────────────

MCS_ORIG="$(qt "${NODES[0]}" "select value from $YX_CFG where module='C' and name='min_cluster_size' limit 1")"
declare -A CRON_PRE=()
CLEANED=0
on_exit() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set +e
	if [ -n "$FEED_PID" ]; then kill "$FEED_PID" 2>/dev/null; wait "$FEED_PID" 2>/dev/null; fi
	if [ -n "$STOPPED" ]; then
		rh "docker start $STOPPED >/dev/null" 2>/dev/null
		echo "  cleanup: started $STOPPED again"
		STOPPED=""
		for _ in $(seq 1 24); do [ "$(qt "${NODES[0]}" "select 1")" = 1 ] && break; sleep 5; done
	fi
	if [ "$CAD_KEEP" = 1 ]; then
		echo "  CAD_KEEP=1: rows, functions and cad_* tables left in place"
		rm -rf "$TMP"
		return 0
	fi
	local n
	for n in "${NODES[@]}"; do
		q "$n" "alter table rppd_cron disable trigger user;
		        delete from rppd_cron where id between $A and $E;
		        alter table rppd_cron enable trigger user;
		        drop trigger if exists zytsync_public_rppd_cron_trigger on rppd_cron;
		        delete from rppd_function where id between $F_A and $F_DL;
		        delete from rppd_function_log where fn_id between $F_A and $F_DL;
		        drop table if exists cad_seen;
		        drop table if exists cad_plain;
		        drop table if exists cad_probe;" >/dev/null 2>&1
		# only a table this script created goes; one that was there stays
		[ "${CRON_PRE[$n]:-1}" = "0" ] && q "$n" "drop table if exists rppd_cron;" >/dev/null 2>&1
		cfg_delete "$n" public.rppd_cron A >/dev/null 2>&1
		cfg_delete "$n" public.cad_probe A >/dev/null 2>&1
		if [ -n "$MCS_ORIG" ]; then cfg_write "$n" min_cluster_size C "$MCS_ORIG"
		else cfg_delete "$n" min_cluster_size C; fi
	done
	rm -rf "$TMP"
	# rppd keeps functions, watchers and cadence rows in memory until it restarts;
	# without this the next script inherits a master still emitting messages to
	# observers whose table is gone.
	echo "  cleanup: rows, functions and cad_* tables removed; min_cluster_size back to [${MCS_ORIG:-none}]; restarting"
	restart_all
	await_cluster
}
trap on_exit EXIT

# ── setup ────────────────────────────────────────────────────────────────────

# The client 93_etcd.sh staged. `docker restart` keeps it; a fresh 10_up does not.
have=0
for n in "${NODES[@]}"; do
	rh "docker exec $n test -x /usr/local/bin/yxetcd" >/dev/null 2>&1 && have=$((have+1))
done
if [ "$have" -lt "${#NODES[@]}" ]; then
	YXETCD_SRC="${YXETCD_SRC:-$REPO_ROOT/../etcd/target/release/examples/yxetcd}"
	[ -x "$YXETCD_SRC" ] || { bad "yxetcd is on $have of ${#NODES[@]} nodes and there is no \
binary at $YXETCD_SRC to stage (cargo build --release --example yxetcd in etcd)"; summary; }
	STAGE=/tmp/yxetcd-stage
	if [ "$YX_HOST" = "local" ]; then cp "$YXETCD_SRC" "$STAGE"
	else scp -q "$YXETCD_SRC" "$YX_HOST:$STAGE" || { bad "could not stage yxetcd on $YX_HOST"; summary; }; fi
	have=0
	for n in "${NODES[@]}"; do
		rh "docker cp $STAGE $n:/usr/local/bin/yxetcd" >/dev/null 2>&1 && have=$((have+1))
	done
fi
check "the yxetcd client is on every node" "${#NODES[@]}" "$have"

# 92_rppd.sh's tables, plus rppd_cron with the cadence columns.
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
create table if not exists rppd_cron (
    id serial primary key, fn_id int not null, cron varchar(64) not null,
    column_name varchar(64) not null, column_value text,
    cadence bool not null default false, timeout_sec int,
    finished_at timestamptz, started_at timestamptz, error_msg text);
alter table rppd_cron add column if not exists watch_min int not null default 0;
alter table rppd_cron add column if not exists retry_sec int not null default 0;
alter table rppd_cron add column if not exists watch_q varchar(256);
alter table rppd_cron add column if not exists deadline_q varchar(256);
alter table rppd_cron add column if not exists state varchar(16) not null default 'ok';
alter table rppd_cron add column if not exists last_seen timestamptz;
alter table rppd_cron add column if not exists since timestamptz;
alter table rppd_cron add column if not exists attempt int not null default 0;
drop trigger if exists zytsync_public_rppd_cron_trigger on rppd_cron;
drop table if exists cad_seen;
create table cad_seen (id serial primary key, q text not null, k text, raw text,
    body jsonb, at timestamptz not null default clock_timestamp());
drop table if exists cad_plain; create table cad_plain (id bigint primary key, v text);
drop table if exists cad_probe; create table cad_probe (id bigint primary key, v text);
"

# The observers: each message's value, as JSON when it parses, so a malformed
# message is still counted (raw) rather than lost to a failed cast.
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
cur.execute("insert into cad_seen (q, k, raw, body) values (%s, %s, %s, %s::jsonb)", ("$1", str(KEY), raw, body))
DB.commit()
print("cadence observer $1:", KEY)
PY
}
# The pp consumers: trivial, but they leave a trace so "the queue reached
# rppd at all" is separable from "cadence did not track it".
pp_code() {
	cat <<PY
cur = DB.cursor()
cur.execute("insert into cad_seen (q, k) values (%s, %s)", ("pp:$1", str(KEY)))
DB.commit()
PY
}
FN_SQL="delete from rppd_function where id between $F_A and $F_DL;
insert into rppd_function (id, code, checksum, schema_table, topic, fn_logging, verbose_debug) values
 ($F_A,  \$fn\$$(pp_code A)\$fn\$, 'na', '$Q_A', '', true, true),
 ($F_B,  \$fn\$$(pp_code B)\$fn\$, 'na', '$Q_B', '', true, true),
 ($F_C,  \$fn\$$(pp_code C)\$fn\$, 'na', '$Q_C', '', true, true),
 ($F_E,  \$fn\$$(pp_code E)\$fn\$, 'na', '$Q_E', '', true, true),
 ($F_D,  \$fn\$print('cad_plain')\$fn\$, 'na', 'public.cad_plain', '', true, true),
 ($F_W,  \$fn\$$(obs_code watch)\$fn\$, 'na', '$Q_W', '', true, true),
 ($F_DL, \$fn\$$(obs_code deadline)\$fn\$, 'na', '$Q_DL', '', true, true);"

CRON_SQL="alter table rppd_cron disable trigger user;
delete from rppd_cron where id between $A and $E;
insert into rppd_cron (id, fn_id, cron, column_name, cadence, watch_min, retry_sec, watch_q, deadline_q) values
 ($A, $F_A, '* * * * *',  '', true, $A_WATCH_MIN, $A_RETRY, '$Q_W', '$Q_DL'),
 ($B, $F_B, '* * * * *',  '', true, 0, 0, '$Q_W', '$Q_DL'),
 ($C, $F_C, '* * * * *',  '', true, $C_WATCH_MIN, 0, '$Q_W', '$Q_DL'),
 ($D, $F_D, '* * * * *',  '', true, 1, 0, '$Q_W', '$Q_DL'),
 ($E, $F_E, 'not a cron', '', true, 1, 0, '$Q_W', '$Q_DL');
alter table rppd_cron enable trigger user;"

for n in "${NODES[@]}"; do
	CRON_PRE[$n]="$(qt "$n" "select (to_regclass('public.rppd_cron') is not null)::int")"
	q "$n" "$RPPD_DDL" >/dev/null
	q "$n" "$FN_SQL" >/dev/null
	cfg_write "$n" serve_rppd C true
	cfg_write "$n" min_cluster_size C "$MAJ"
done
[ "$CAD_SYNC" = 1 ] && register_table public.rppd_cron
register_table public.cad_probe
# out of band, after the sync trigger exists: identical rows on every node
for n in "${NODES[@]}"; do q "$n" "$CRON_SQL" >/dev/null; done
check "the five cadence rows are on every node" "${#NODES[@]}" \
	"$(for n in "${NODES[@]}"; do qt "$n" "select count(*) from rppd_cron where id between $A and $E and cadence"; done | grep -cx 5 || true)"
check "the seven functions are on every node" "${#NODES[@]}" \
	"$(for n in "${NODES[@]}"; do qt "$n" "select count(*) from rppd_function where id between $F_A and $F_DL"; done | grep -cx 7 || true)"
echo "  min_cluster_size -> $MAJ (majority of $NV voters; was ${MCS_ORIG:-unset}); rppd_cron sync: $CAD_SYNC"

# rppd loads functions and cron rows at startup
restart_all

# Feed A and C from the moment rppd can start. A row with no message is due
# 60-120 s after the master starts; waiting for the cluster to settle first
# could already make them late, and C1 would fail for a reason that is setup.
: > "$TMP/feed"; : > "$TMP/fed"
echo "${VOTERS[1]}" > "$TMP/via"
feed_add "$Q_A"; feed_add "$Q_C"
feeder &
FEED_PID=$!

await_cluster
L="$(leader_node)"
[ -n "$L" ] && ok "the cluster has a leader ($L) - it is the rppd master" || { bad "no leader"; summary; }
pick_via "$L"
W="$(cat "$TMP/via")"
echo "  pp messages go in through $W"
wait_writable "$L" "$W" cad_probe || bad "cluster writes never succeeded - rppd_cron cannot replicate"
check "serve_rppd is live on $L" "true" "$(info "$L" E cfg.serve_rppd)"
if until_is 60 1 qt "$L" "select count(*) from rppd_config where master"; then
	ok "exactly one rppd_config row is master"
else
	bad "rppd_config on $L has [${POLL_V:-?}] master row(s) after 60 s"
fi
if until_ge 90 1 seen "q='pp:A'"; then
	ok "the $Q_A consumer runs ($POLL_V message(s) consumed so far)"
else
	bad "nothing consumed $Q_A in 90 s ($(fed_count "$Q_A") put) - the queue never reached rppd, \
so every cadence check below is measuring an absent input"
fi

# ── C1: on time ──────────────────────────────────────────────────────────────
echo
echo "-- C1 on time: $Q_A gets a message every ${FEED_SEC}s for ${C1_SEC}s, cron '* * * * *'"
notok=0; polls=0; ls1=""; prev_b=""
t0=$SECONDS
while [ $((SECONDS - t0)) -lt "$C1_SEC" ]; do
	st="$(rowv "$A" state)"
	polls=$((polls+1))
	if [ "$st" != "ok" ]; then
		notok=$((notok+1))
		echo "     +$((SECONDS - t0))s A state [${st:-<none>}]"
	fi
	if [ -z "$ls1" ] && [ $((SECONDS - t0)) -ge 50 ]; then
		ls1="$(rowv "$A" "extract(epoch from last_seen)::bigint")"
		ls1="${ls1:-none}"
	fi
	# C4's row runs alongside, silent from the start; its transition is noted here
	bst="$(rowv "$B" state)"
	if [ "$bst" != "$prev_b" ]; then echo "     +$((SECONDS - t0))s B (watch_min=0) state [${bst:-<none>}]"; prev_b="$bst"; fi
	sleep 5
done
ls2="$(rowv "$A" "extract(epoch from last_seen)::bigint")"
age="$(rowv "$A" "extract(epoch from now() - last_seen)::int")"
echo "     $(fed_count "$Q_A") put to $Q_A so far, $(seen "q='pp:A'") consumed"
check "C1 A stayed 'ok' at every poll ($polls polls)" "0" "$notok"
if [[ "$ls1" =~ ^[0-9]+$ ]] && [[ "$ls2" =~ ^[0-9]+$ ]] && [ $((ls2 - ls1)) -ge 60 ]; then
	ok "C1 last_seen advanced with the messages (+$((ls2 - ls1))s over the window)"
else
	bad "C1 last_seen did not advance: [${ls1:-none}] at +50 s, [${ls2:-none}] at the end"
fi
in_range "${age:-x}" 0 $((FEED_SEC + 20)) \
	&& ok "C1 last_seen is current (${age}s old, messages every ${FEED_SEC}s)" \
	|| bad "C1 last_seen is [${age:-null}]s old with a message every ${FEED_SEC}s"
check "C1 attempt stays 0" "0" "$(rowv "$A" attempt)"
check "C1 no watch message for A" "0" "$(seen "q='watch' and body->>'pp'='$A'")"
check "C1 no deadline message for A" "0" "$(seen "q='deadline' and body->>'pp'='$A'")"
check "C1 no message for C either (also fed)" "0" "$(seen "body->>'pp'='$C'")"
rows_dump

# ── C2: watch with retry, then the deadline ──────────────────────────────────
echo
echo "-- C2 watch with retry: $Q_A goes quiet (watch_min=$A_WATCH_MIN, retry_sec=$A_RETRY)"
feed_drop "$Q_A"
sleep 3   # a round already in flight may put once more; last_seen says when
# Due is the end of the first full period after the last message: 60-120 s,
# plus a 5 s tick, plus up to one feed interval since that message.
if until_is 170 watch rowv "$A" state; then
	ok "C2 A went to 'watch' ${POLL_T}s after its feed stopped"
else
	bad "C2 A never went to 'watch' within 170 s of its feed stopping (state [${POLL_V:-<none>}])"
fi
sw="$(rowv "$A" "extract(epoch from since)::bigint")"
gap="$(rowv "$A" "extract(epoch from since - last_seen)::int")"
in_range "${gap:-x}" 61 135 \
	&& ok "C2 the watch began ${gap}s after the last message - after the SECOND cron fire, not the first" \
	|| bad "C2 since - last_seen = [${gap:-null}]s; due is the second fire after last_seen, so 61..125 s"
check "C2 attempt is 1 on entering watch" "1" "$(rowv "$A" attempt)"

w1="$(mw watch "$A" watch) and $(num attempt) = 1"
until_ge 30 1 seen "$w1" || true
check "C2 one watch message with attempt 1 on $Q_W" "1" "$(seen "$w1")"
check "C2 ...it names the pp's queue and function" "1" \
	"$(seen "$w1 and body->>'queue'='$Q_A' and body->>'fn_id'='$F_A'")"
check "C2 ...late_sec >= 0" "1" "$(seen "$w1 and $(num late_sec) >= 0")"
due="$(seen_val "extract(epoch from $(tsf due_at) - $(tsf last_seen))::int" "$w1")"
dsec="$(seen_val "extract(second from $(tsf due_at))::int" "$w1")"
if in_range "${due:-x}" 61 120 && [ "${dsec:-x}" = "0" ]; then
	ok "C2 due_at is a cron fire ${due}s after last_seen - the end of the first full period"
else
	bad "C2 due_at - last_seen = [${due:-?}]s, seconds = [${dsec:-?}]; expected 61..120 s on a whole minute"
fi

t1="$(seen_val "extract(epoch from at)::bigint" "$w1")"
w2="$(mw watch "$A" watch) and $(num attempt) = 2"
if until_ge 60 1 seen "$w2"; then
	t2="$(seen_val "extract(epoch from at)::bigint" "$w2")"
	g=$(( ${t2:-0} - ${t1:-0} ))
	in_range "$g" 20 55 \
		&& ok "C2 the watch message repeated ${g}s later with attempt 2 (retry_sec=$A_RETRY)" \
		|| bad "C2 attempt 2 came ${g}s after attempt 1, expected ~$A_RETRY s"
else
	bad "C2 no second watch message (attempt 2) within 60 s - retry_sec=$A_RETRY did not repeat it"
fi

if until_is 150 deadline rowv "$A" state; then
	ok "C2 A went to 'deadline'"
else
	bad "C2 A never reached 'deadline' (state [${POLL_V:-<none>}]) - watch_min=$A_WATCH_MIN"
fi
sd="$(rowv "$A" "extract(epoch from since)::bigint")"
d=$(( ${sd:-0} - ${sw:-0} ))
in_range "$d" 110 140 \
	&& ok "C2 the deadline came ${d}s after the watch began (watch_min=$A_WATCH_MIN)" \
	|| bad "C2 the deadline came ${d}s after the watch began, expected ~$((A_WATCH_MIN * 60)) s"
wd="$(mw deadline "$A" deadline)"
until_ge 30 1 seen "$wd" || true
check "C2 one deadline message on $Q_DL" "1" "$(seen "$wd")"
check "C2 ...naming the pp's queue and function" "1" \
	"$(seen "$wd and body->>'queue'='$Q_A' and body->>'fn_id'='$F_A'")"
nw="$(seen "$(mw watch "$A" watch)")"
echo "     watch messages for A while on watch: $nw"
sleep 60
check "C2 the deadline message is never repeated (still 1 after 60 s)" "1" "$(seen "$wd")"
check "C2 no watch message after the deadline" "$nw" "$(seen "$(mw watch "$A" watch)")"
check "C2 A stays in 'deadline'" "deadline" "$(rowv "$A" state)"

# ── C3: recovery ─────────────────────────────────────────────────────────────
echo
echo "-- C3 recovery: one message to $Q_A"
pp_put_retry "$Q_A" || bad "C3 could not put the recovery message"
if until_is 30 ok rowv "$A" state; then
	ok "C3 A is back to 'ok' ${POLL_T}s after the message"
	[ "$POLL_T" -le 20 ] \
		&& ok "C3 ...within 20 s" \
		|| bad "C3 ...but only after ${POLL_T}s (persist <= 5 s + one 5 s tick)"
else
	bad "C3 A is still [${POLL_V:-<none>}] 30 s after a message arrived"
fi
wo="$(mw deadline "$A" ok) and body->>'was'='deadline'"
until_ge 30 1 seen "$wo" || true
check "C3 one 'ok' message on $Q_DL with was='deadline'" "1" "$(seen "$wo")"
check "C3 ...down_sec > 0 and last_seen set" "1" \
	"$(seen "$wo and $(num down_sec) > 0 and $(tsf last_seen) is not null")"
check "C3 no 'ok' message on $Q_W - A left deadline, not watch" "0" "$(seen "$(mw watch "$A" ok)")"
check "C3 attempt back to 0" "0" "$(rowv "$A" attempt)"
[ "$(seen "$wo")" = "1" ] || seen_dump "q in ('watch','deadline') and body->>'pp'='$A'"
feed_add "$Q_A"   # keep A quiet for the rest of the run

# ── C4: watch_min = 0 ────────────────────────────────────────────────────────
echo
echo "-- C4 watch_min=0: $Q_B has had no message since the master started"
if until_is 60 deadline rowv "$B" state; then
	ok "C4 B is in 'deadline'"
else
	bad "C4 B is [${POLL_V:-<none>}], never 'deadline', minutes after it was due"
fi
bage="$(rowv "$B" "extract(epoch from now() - since)::int")"
if [[ "${bage:-x}" =~ ^[0-9]+$ ]] && [ "$bage" -lt 60 ]; then sleep $((60 - bage)); fi
wbd="$(mw deadline "$B" deadline)"
check "C4 exactly one deadline message, never repeated" "1" "$(seen "$wbd")"
check "C4 ...with last_seen null - nothing ever arrived" "1" \
	"$(seen "$wbd and jsonb_typeof(body->'last_seen') = 'null'")"
check "C4 no watch message at all - straight from ok to deadline" "0" "$(seen "q='watch' and body->>'pp'='$B'")"
pp_put_retry "$Q_B" || bad "C4 could not put the recovery message"
if until_is 30 ok rowv "$B" state; then
	ok "C4 B is back to 'ok' ${POLL_T}s after a message"
else
	bad "C4 B is still [${POLL_V:-<none>}] 30 s after a message arrived"
fi
wbo="$(mw deadline "$B" ok) and body->>'was'='deadline'"
until_ge 30 1 seen "$wbo" || true
check "C4 one 'ok' message on $Q_DL with was='deadline'" "1" "$(seen "$wbo")"
check "C4 ...down_sec > 0" "1" "$(seen "$wbo and $(num down_sec) > 0")"
check "C4 still nothing on $Q_W for B" "0" "$(seen "q='watch' and body->>'pp'='$B'")"
feed_add "$Q_B"

# ── C5: rows that must not be evaluated ──────────────────────────────────────
echo
echo "-- C5 bad rows: D's function is on a plain table, E's cron does not parse"
for r in "$D" "$E"; do
	case "$r" in "$D") why="fn on public.cad_plain";; *) why="cron 'not a cron'";; esac
	em="$(rowv "$r" "coalesce(error_msg,'')")"
	[ -n "$em" ] \
		&& ok "C5 row $r ($why) has error_msg: ${em:0:120}" \
		|| bad "C5 row $r ($why) has no error_msg"
	check "C5 row $r stays 'ok'" "ok" "$(rowv "$r" state)"
	check "C5 no cadence message names row $r" "0" "$(seen "body->>'pp'='$r'")"
done
check "C5 the valid rows carry no error_msg" "0" \
	"$(qt "$L" "select count(*) from rppd_cron where id in ($A,$B,$C) and error_msg is not null")"

# ── C6: a watch that outlives its master ─────────────────────────────────────
echo
echo "-- C6 failover: $Q_C goes quiet, the leader is stopped while C is on watch (watch_min=$C_WATCH_MIN)"
L="$(leader_node)"
[ -n "$L" ] || { bad "C6 no leader to stop"; diag; summary; }
L6="$L"
pick_via "$L6"
echo "  leader $L6; pp messages now go in through $(cat "$TMP/via")"
feed_drop "$Q_C"
sleep 3
if until_is 170 watch rowv "$C" state; then
	ok "C6 C went to 'watch' ${POLL_T}s after its feed stopped"
else
	bad "C6 C never went to 'watch' (state [${POLL_V:-<none>}]) - nothing to fail over"
	diag; summary
fi
sw6="$(rowv "$C" "extract(epoch from since)::bigint")"
wc6="$(mw watch "$C" watch)"
until_ge 30 1 seen "$wc6" || true
check "C6 one watch message for C before the failover" "1" "$(seen "$wc6")"

# The state must be on another voter before the master goes, or this measures
# replication lag rather than whether a new master continues.
if [ "$CAD_SYNC" = 1 ]; then
	if until_is 20 watch qt "$(cat "$TMP/via")" "select state from rppd_cron where id=$C"; then
		ok "C6 the watch state replicated to $(cat "$TMP/via")"
	else
		bad "C6 C's 'watch' did not replicate to $(cat "$TMP/via") in 20 s (there: [${POLL_V:-?}])"
	fi
fi

echo "  stopping $L6 for ${C6_STOP_SEC}s..."
# -t 20: a clean stop (node-entrypoint.sh traps SIGTERM), no crash recovery at the start
rh "docker stop -t 20 $L6 >/dev/null" 2>/dev/null || true
STOPPED="$L6"
ts=$SECONDS
L7=""
for _ in $(seq 1 24); do
	L7="$(leader_node)"
	[ -n "$L7" ] && break
	sleep 5
done
if [ -n "$L7" ]; then
	ok "C6 $L7 leads with $L6 stopped ($((SECONDS - ts))s)"
	L="$L7"
else
	bad "C6 no new leader within 120 s of stopping $L6"
fi
left=$((C6_STOP_SEC - (SECONDS - ts)))
[ "$left" -gt 0 ] && sleep "$left"
rh "docker start $L6 >/dev/null" 2>/dev/null || true
node_ready "$L6" 600 || true   # PostgreSQL answering, network up
STOPPED=""
echo "  $L6 started again"

# Persisted, not re-derived: a master that rebuilt C from scratch would start a
# NEW watch - a later since, a second attempt-1 message, a later deadline.
if [ -n "$L7" ]; then
	now6="$(qt "$L7" "select extract(epoch from now())::bigint")"
	if [[ "${now6:-x}" =~ ^[0-9]+$ ]] && [[ "${sw6:-x}" =~ ^[0-9]+$ ]] \
		&& [ "$now6" -lt $((sw6 + C_WATCH_MIN * 60 - 10)) ]; then
		check "C6 the new leader's row is still on watch" "watch" "$(qt "$L7" "select state from rppd_cron where id=$C")"
		check "C6 ...with the since the old master set" "$sw6" \
			"$(qt "$L7" "select extract(epoch from since)::bigint from rppd_cron where id=$C")"
	else
		echo "     (too close to the deadline to inspect the watch on $L7)"
	fi
	echo "     rppd master on $L7: $(qt "$L7" "select host_name from rppd_config where master")"
	echo "     $L7's node uuid:    $(node_uuid "$L7")"
fi

if until_is $((C_WATCH_MIN * 60 + 60)) deadline row_now "$C" state; then
	ok "C6 C reached 'deadline' under the new master"
else
	bad "C6 C never reached 'deadline' after the failover (state [${POLL_V:-<none>}])"
fi
sd6="$(row_now "$C" "extract(epoch from since)::bigint")"
d6=$(( ${sd6:-0} - ${sw6:-0} ))
in_range "$d6" $((C_WATCH_MIN * 60 - 10)) $((C_WATCH_MIN * 60 + 20)) \
	&& ok "C6 the deadline came ${d6}s after the original watch began - the schedule survived" \
	|| bad "C6 the deadline came ${d6}s after the original watch began, expected ~$((C_WATCH_MIN * 60)) s"

# every observer table counts, so wait for the restarted node's PostgreSQL
for _ in $(seq 1 24); do [ "$(qt "$L6" "select 1")" = 1 ] && break; sleep 5; done
wd6="$(mw deadline "$C" deadline)"
until_ge 30 1 seen "$wd6" || true
dage="$(row_now "$C" "extract(epoch from now() - since)::int")"
if [[ "${dage:-x}" =~ ^[0-9]+$ ]] && [ "$dage" -lt 60 ]; then sleep $((60 - dage)); fi
check "C6 exactly one deadline message for C across the failover" "1" "$(seen "$wd6")"
check "C6 still exactly one watch message - the new master did not restart the watch" "1" "$(seen "$wc6")"
check "C6 C stays in 'deadline'" "deadline" "$(row_now "$C" state)"
[ "$(seen "$wd6")" = "1" ] || seen_dump "q in ('watch','deadline') and body->>'pp'='$C'"

[ "$fail" -gt 0 ] && diag
summary
