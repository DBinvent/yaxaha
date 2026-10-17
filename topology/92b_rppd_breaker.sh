#!/usr/bin/env bash
# [breaker] rppd's circuit breaker (yt-pgxt resilience.md, phase 1): a pipeline
# process (pp) whose function keeps failing is held, not hammered and not lost.
#
# The breaker lives in rppd, per function per node (D2): `breaker_fails` failures
# in a row open it, an open breaker holds the function's events (an etcd message
# stays unacknowledged), after `breaker_open_sec` one event goes through as a
# probe, and a probe that succeeds closes it and the held events run. With
# `max_attempts` a failed event is retried and, after the last attempt, goes to
# `dlq` (D3). Transitions go to `notify_q` as JSON, in cadence's format (D6), and
# to `rppd_function_state`, one row per function per node (D4).
#
# The settings are columns rppd.yaml declares; rppd adds them at startup with
# SchemaGuard (rppd schema.rs). This script creates rppd's tables WITHOUT them,
# so the first restart is what has to add them (B1).
#
# ## What is asserted
#
# B1 a restart brings rppd's tables up to date on every node: the breaker's
#    columns and rppd_function_state exist (SchemaGuard, no hand-written DDL)
# B2 a pp whose downstream is down (its function raises while bk_flag says so):
#    every node that ran it opens its breaker - one 'open' notice to notify_q
#    each, carrying the failures and the error; its state row says open
# B3 while open, more messages are put: none of them runs
# B4 the downstream recovers: the probe closes each breaker ('closed' notice,
#    state row closed) and EVERY message put - before and while open - is
#    processed: no event was dropped
# B5 max_attempts + dlq: a poison message is tried max_attempts times, then lands
#    in dlq with its key and last error; the messages around it flow
#
# Not here: the code-change reset (an UPDATE of the code half-opens at once) -
# embedded rppd reads rppd_function at startup only, so a runtime edit never
# reaches it; rppd's unit tests cover the transition (breaker.rs).
#
# Timing: ~8 min (two restarts to set up, one to clean up).
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== rppd breaker: a failing pipeline is held, probed and drained, nothing lost =="

BK_KEEP="${BK_KEEP:-0}"
F_P=9221; F_N=9222; F_X=9223; F_D=9224
Q_P=/q/bk_pp; Q_N=/q/bk_notify; Q_X=/q/bk_poison; Q_D=/q/bk_dlq
OPEN_SEC=20
N1=4     # messages that open the breakers
N2=6     # messages put while open

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
TMP="$(mktemp -d)"

qt() { # qt <node> <sql> -> the value, or "" - never fails, never hangs a poll
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}
sum() { # sum <sql returning one number> -> summed over every node
	local n c t=0
	for n in "${NODES[@]}"; do
		c="$(qt "$n" "$1")"
		[[ "$c" =~ ^[0-9]+$ ]] && t=$((t + c))
	done
	printf '%s' "$t"
}
seen() { sum "select count(*) from bk_seen where $1"; }
POLL_V=""; POLL_T=0
until_ge() { # until_ge <secs> <min> <cmd...> - every 3 s
	local secs="$1" min="$2"; shift 2
	local t0=$SECONDS
	while :; do
		POLL_V="$("$@" 2>/dev/null || true)"
		POLL_T=$((SECONDS - t0))
		if [[ "$POLL_V" =~ ^[0-9]+$ ]] && [ "$POLL_V" -ge "$min" ]; then return 0; fi
		[ "$POLL_T" -ge "$secs" ] && return 1
		sleep 3
	done
}
VIA="${VOTERS[0]}"
put() { # put <queue> <value> -> 0 when acknowledged
	local i
	for i in 1 2 3; do
		rh "docker exec $VIA /usr/local/bin/yxetcd $VIA:7421 put $1/producer/b$(date +%s%N) $2" >/dev/null 2>&1 && return 0
		sleep 2
	done
	return 1
}
diag() {
	local n
	echo "  diagnostics:"
	for n in "${NODES[@]}"; do
		qt "$n" "select '     $n state fn '||fn_id||' '||state||' attempt='||attempt||' held='||held||' '||coalesce(left(last_error,80),'')
		         from rppd_function_state where fn_id between $F_P and $F_D"
		qt "$n" "select '     $n seen '||q||' '||coalesce(body::text, k) from bk_seen where q <> 'pp' and q <> 'px' order by at"
		rh "docker logs --since 15m $n 2>&1 | { grep -E 'breaker' || true; } | tail -4 | sed 's/^/     $n log: /'" 2>/dev/null || true
	done
	return 0
}

CLEANED=0
on_exit() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set +e
	if [ "$BK_KEEP" = 1 ]; then echo "  BK_KEEP=1: functions and bk_* tables left in place"; rm -rf "$TMP"; return 0; fi
	local n
	for n in "${NODES[@]}"; do
		q "$n" "delete from rppd_function where id between $F_P and $F_D;
		        delete from rppd_function_log where fn_id between $F_P and $F_D;
		        delete from rppd_function_state where fn_id between $F_P and $F_D;
		        drop table if exists bk_seen; drop table if exists bk_flag;" >/dev/null 2>&1
	done
	rm -rf "$TMP"
	# rppd keeps its functions and watchers until it restarts
	echo "  cleanup: functions and bk_* tables removed; restarting"
	restart_all
	await_cluster
}
trap on_exit EXIT

# ── setup ────────────────────────────────────────────────────────────────────

# the etcd client 93_etcd.sh stages (a fresh 10_up has none)
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

# rppd's tables as 92_rppd.sh makes them: without the breaker's columns
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
drop table if exists bk_seen;
create table bk_seen (id serial primary key, q text not null, k text, raw text,
    body jsonb, at timestamptz not null default clock_timestamp());
drop table if exists bk_flag;
create table bk_flag (id int primary key, fail bool not null);
insert into bk_flag values (1, true);
"
for n in "${NODES[@]}"; do
	q "$n" "$RPPD_DDL" >/dev/null
	cfg_write "$n" serve_rppd C true
done

# ── B1: the first restart adds the breaker's columns ────────────────────────
restart_all
await_cluster
cols="$(for n in "${NODES[@]}"; do qt "$n" "select count(*) from information_schema.columns
	where table_name = 'rppd_function' and column_name in ('breaker_fails','breaker_slow_ms','breaker_open_sec',
	'breaker_open_max_sec','max_attempts','notify_q','dlq')"; done | grep -cx 7 || true)"
check "B1 rppd added the breaker's seven columns to rppd_function on every node (SchemaGuard at startup)" "${#NODES[@]}" "$cols"
st="$(for n in "${NODES[@]}"; do qt "$n" "select (to_regclass('public.rppd_function_state') is not null)::int"; done | grep -cx 1 || true)"
check "B1 rppd_function_state exists on every node" "${#NODES[@]}" "$st"

obs_code() { # an observer: the message's value as JSON, by queue
	cat <<PY
import json
raw = VALUE.decode('utf-8') if isinstance(VALUE, (bytes, bytearray)) else str(VALUE)
try:
    json.loads(raw)
    body = raw
except Exception:
    body = None
cur = DB.cursor()
cur.execute("insert into bk_seen (q, k, raw, body) values (%s, %s, %s, %s::jsonb)", ("$1", str(KEY), raw, body))
DB.commit()
PY
}
pp_code() { # the pp: raises while its downstream (bk_flag) is down
	cat <<PY
cur = DB.cursor()
cur.execute("select fail from bk_flag where id = 1")
if cur.fetchone()[0]:
    DB.rollback()
    raise Exception("downstream down")
cur.execute("insert into bk_seen (q, k) values (%s, %s)", ("pp", str(KEY)))
DB.commit()
PY
}
px_code() { # raises on one message only
	cat <<PY
raw = VALUE.decode('utf-8') if isinstance(VALUE, (bytes, bytearray)) else str(VALUE)
if raw == 'poison':
    raise Exception("poison message")
cur = DB.cursor()
cur.execute("insert into bk_seen (q, k, raw) values (%s, %s, %s)", ("px", str(KEY), raw))
DB.commit()
PY
}
FN_SQL="delete from rppd_function where id between $F_P and $F_D;
insert into rppd_function (id, code, checksum, schema_table, topic, fn_logging, verbose_debug,
    breaker_fails, breaker_open_sec, breaker_open_max_sec, max_attempts, notify_q, dlq) values
 ($F_P, \$fn\$$(pp_code)\$fn\$, 'na', '$Q_P', '', true, false, 3, $OPEN_SEC, 60, 1000, '$Q_N', null),
 ($F_N, \$fn\$$(obs_code notify)\$fn\$, 'na', '$Q_N', '', false, false, 0, 30, 900, 0, null, null),
 ($F_X, \$fn\$$(px_code)\$fn\$, 'na', '$Q_X', '', true, false, 0, 30, 900, 3, null, '$Q_D'),
 ($F_D, \$fn\$$(obs_code dlq)\$fn\$, 'na', '$Q_D', '', false, false, 0, 30, 900, 0, null, null);"
for n in "${NODES[@]}"; do q "$n" "$FN_SQL" >/dev/null; done
check "the four functions are on every node" "${#NODES[@]}" \
	"$(for n in "${NODES[@]}"; do qt "$n" "select count(*) from rppd_function where id between $F_P and $F_D"; done | grep -cx 4 || true)"
# rppd reads its functions at startup
restart_all
await_cluster
sleep 5

# ── B2: the downstream is down - the breakers open ──────────────────────────
echo
echo "-- B2 $Q_P's downstream is down: $N1 messages"
for i in $(seq 1 "$N1"); do put "$Q_P" "m$i" || bad "B2 put m$i to $Q_P failed"; done
# A call leaves its log row with an error (a retried failure) or took_ms (done);
# a held event's row, written when it arrived, has neither
RUN="fn_id = $F_P and (error_msg is not null or took_ms is not null)"
ran_nodes() { # nodes whose rppd ran the pp at least once
	local n c=0
	for n in "${NODES[@]}"; do
		[ "$(qt "$n" "select count(*) > 0 from rppd_function_log where $RUN")" = t ] && c=$((c+1))
	done
	printf '%s' "$c"
}
open_rows() { sum "select count(*) from rppd_function_state where fn_id = $F_P and state = 'open'"; }
if until_ge 60 1 seen "q='notify' and body->>'state'='open'"; then
	ok "B2 a breaker opened: an 'open' notice reached $Q_N after ${POLL_T}s"
else
	bad "B2 no 'open' notice on $Q_N in 60 s"; diag
fi
sleep 5
RAN="$(ran_nodes)"
echo "     the pp ran on $RAN node(s)"
check "B2 one 'open' notice per node that ran it" "$RAN" "$(seen "q='notify' and body->>'state'='open' and body->>'pp'='$F_P'")"
check "B2 every such node's rppd_function_state row is open" "$RAN" "$(open_rows)"
check "B2 the notice carries the 3 failures" "$RAN" "$(seen "q='notify' and body->>'state'='open' and body->>'fails'='3'")"
check "B2 ...and the function's error" "$RAN" "$(seen "q='notify' and body->>'state'='open' and body->>'error' like '%downstream down%'")"
check "B2 nothing processed while the downstream is down" "0" "$(seen "q='pp'")"

# ── B3: while open nothing runs ──────────────────────────────────────────────
echo
echo "-- B3 $N2 more messages while open"
# counted on the nodes whose breaker is open: a node that gets its first message
# only now is closed, and runs it (and opens) as B2's nodes did
OPEN_NODES=()
for n in "${NODES[@]}"; do
	[ "$(qt "$n" "select count(*) from rppd_function_state where fn_id = $F_P and state = 'open'")" = 1 ] && OPEN_NODES+=("$n")
done
runs_on_open() {
	local n c t=0
	for n in "${OPEN_NODES[@]}"; do
		c="$(qt "$n" "select count(*) from rppd_function_log where $RUN")"
		[[ "$c" =~ ^[0-9]+$ ]] && t=$((t + c))
	done
	printf '%s' "$t"
}
before="$(runs_on_open)"
for i in $(seq 1 "$N2"); do put "$Q_P" "h$i" || bad "B3 put h$i failed"; done
sleep 6
check "B3 on the ${#OPEN_NODES[@]} open node(s) the held messages did not run" "$before" "$(runs_on_open)"
OPENED="$(seen "q='notify' and body->>'state'='open' and body->>'pp'='$F_P'")"
[ "${OPENED:-0}" -ge "$RAN" ] && ok "B3 the breakers are still open ($(open_rows) open rows, $OPENED 'open' notices)" \
	|| bad "B3 [$OPENED] 'open' notices, fewer than B2's $RAN"

# ── B4: the downstream recovers - probe, close, drain ───────────────────────
echo
echo "-- B4 the downstream recovers"
for n in "${NODES[@]}"; do q "$n" "update bk_flag set fail = false" >/dev/null; done
TOTAL=$((N1 + N2))
if until_ge $((OPEN_SEC * 3 + 30)) "$TOTAL" sum "select count(distinct k) from bk_seen where q='pp'"; then
	ok "B4 every message put ($TOTAL: $N1 before the breaker opened, $N2 while open) was processed, ${POLL_T}s after the recovery"
else
	bad "B4 only [${POLL_V:-0}] of $TOTAL messages processed after recovery - an event was lost"; diag
fi
# every breaker that opened closes once: as many 'closed' notices as 'open' ones
OPENED="$(seen "q='notify' and body->>'state'='open' and body->>'pp'='$F_P'")"
until_ge 30 "$OPENED" seen "q='notify' and body->>'state'='closed' and body->>'pp'='$F_P'" \
	&& ok "B4 every breaker closed: $POLL_V 'closed' notice(s) for $OPENED 'open'" \
	|| { bad "B4 [${POLL_V:-0}] 'closed' notices for $OPENED 'open'"; diag; }
check "B4 no rppd_function_state row is still open" "0" "$(open_rows)"

# ── B5: max_attempts, then dlq ──────────────────────────────────────────────
echo
echo "-- B5 a poison message among good ones (max_attempts=3, dlq=$Q_D)"
put "$Q_X" ok1; put "$Q_X" poison; put "$Q_X" ok2
if until_ge 60 1 seen "q='dlq'"; then
	ok "B5 the poison message reached $Q_D after ${POLL_T}s"
else
	bad "B5 nothing reached $Q_D in 60 s"; diag
fi
until_ge 30 2 seen "q='px'" && ok "B5 the good messages around it were processed ($POLL_V)" \
	|| bad "B5 [${POLL_V:-0}] of 2 good messages processed"
check "B5 one dead letter" "1" "$(seen "q='dlq'")"
check "B5 it carries its 3 attempts" "1" "$(seen "q='dlq' and body->>'attempts'='3'")"
# the key as the queue delivered it, which is under the queue's path
check "B5 ...its key" "1" "$(seen "q='dlq' and body->>'key' like '$Q_X%'")"
check "B5 ...and its last error" "1" "$(seen "q='dlq' and body->>'error' like '%poison message%'")"
check "B5 its log row is done with its error (one row: the retries reuse it)" "1" \
	"$(sum "select count(*) from rppd_function_log where fn_id = $F_X and error_msg like '%poison message%' and took_ms is not null")"

summary
