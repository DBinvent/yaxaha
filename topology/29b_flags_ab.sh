#!/usr/bin/env bash
# [flags-ab] The two flags that are off by default with documented bugs,
# `peer_stream` and `one_pc` (yt-pgxt TODO.md, "Known problems"), run against the
# default under one load: 29_concurrent's C11 hot table - 10 rows, 8 writers for
# 30 s - so a documented bug either shows again or is gone, and the throughput of
# each is on record.
#
#   B0  both flags off: the hot load committed by yt_complete(true), by a plain
#       COMMIT, and by yt_complete(true) on a table whose party is ONE node
#   PS  peer_stream=1 on every node: the first two loads again
#   OP  one_pc=1 on every node: the one-node-party load again - the only party
#       one_pc fires on (cluster_commit=nodes>=2: N counts the origin, so this is
#       one member; until 2026-10-16 the table had nodes>=1, which is NO member, and
#       one_pc never fired here), and yt_complete(true) is the only commit it fires
#       on (a plain COMMIT prepares the party at PRE_COMMIT).
#       Then that commit's origin is killed between yt_complete(true) and its
#       COMMIT (topo T5 J9): one_pc commits the member in the first phase, so the
#       member holds the row before the origin does.
#
# ## Measured, not graded
#
# Both flags are off in every shipped configuration, so a flag that still
# misbehaves must not stop a release of the default: every outcome is an INFO
# line, and the decision to default a flag on is read off the one AB line at the
# end, which the nightly copies into results.yaml. Graded is only what the next
# script depends on: the fixture back on its defaults, and writable.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== flags A/B: peer_stream and one_pc against the default, one hot load =="

# ── helpers (as 29_concurrent / 99_peer_stream) ──────────────────────────────

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
NV=${#VOTERS[@]}

qx() { # qx <node> <sql> [statement_timeout] -> psql's output WITH its errors
	local node="$1" sql="$2" to="${3:-60s}"
	printf '%s\n' "$sql" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=$to' $node \
psql -X -tAq -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d $YX_DB 2>&1" 2>&1 || true
}
err_of() {
	printf '%s\n' "$1" | { grep -m1 -E 'ERROR:|FATAL:|PANIC:|psql: error|server closed the connection|connection to server|No such container|Error response from daemon|is not running' || true; }
}
cw() { # cw <node> <statements> [timeout]: yt_complete(true), then COMMIT -> "" or the error
	err_of "$(qx "$1" "begin; $2; select yt_complete(true); commit;" "${3:-60s}")"
}
cwc() { # cwc: a plain COMMIT, the cluster commit is auto_complete's
	err_of "$(qx "$1" "begin; $2; commit;" "${3:-60s}")"
}
qt() { # env.sh's q plus a statement_timeout, so a wedged ytserv cannot hang a poll
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}
yinfo() { # yinfo <node> <letters> <name> -> one yt_info value
	local j
	j="$(qt "$1" "select yt_info('$2')")"
	printf '%s' "$j" | python3 -c "
import json,sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in rows:
    if r.get('name') == sys.argv[1]: print(r.get('value','')); break
" "$3" 2>/dev/null || true
}
leader_now() {
	local n v
	for n in "${NODES[@]}"; do
		v="$(yinfo "$n" O cluster)"
		case "$v" in *", Leader"|*", Leader, discrepancy"*) printf '%s' "$n"; return 0 ;; esac
	done
}
wait_converged() { # wait_converged <secs> <digest-sql>
	local deadline=$((SECONDS + $1)) n d first same
	while :; do
		first=""; same=1
		for n in "${NODES[@]}"; do
			d="$(qt "$n" "$2")"; d="${d:-<none>}"
			[ -n "$first" ] || first="$d"
			[ "$d" = "$first" ] || { same=0; break; }
		done
		[ "$same" = 1 ] && [ "$first" != "<none>" ] && return 0
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 3
	done
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
info_line() { echo "  INFO $1"; }
host_now() { rh "date +%s" 2>/dev/null || date +%s; }

TMP="$(mktemp -d)"
FLAGS_SET=0
CLEANED=0
drop_tables() {
	local n
	for n in "${NODES[@]}"; do
		q "$n" "drop table if exists ab_t; drop table if exists ab1_t;" >/dev/null 2>&1
		cfg_delete "$n" public.ab_t A >/dev/null 2>&1 || true
		cfg_delete "$n" public.ab1_t A >/dev/null 2>&1 || true
	done
}
flags_default() { # no row = the compiled default, 0 for both (ytserv rmc.rs)
	local n
	for n in "${NODES[@]}"; do
		cfg_delete "$n" peer_stream C >/dev/null 2>&1 || true
		cfg_delete "$n" one_pc C >/dev/null 2>&1 || true
	done
}
on_exit() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set +e
	local p
	for p in $(jobs -p); do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	if [ "$FLAGS_SET" = 1 ]; then
		echo "  (stopped before the end: flags back to their defaults, restarting)"
		flags_default
		drop_tables
		restart_all
		await_cluster
	else
		drop_tables
	fi
	rm -rf "$TMP"
}

# set_flag <name> <value>: on every node, live after one synchronised restart
# (neither flag is hot-reloadable). Returns 1 when the value is not live everywhere:
# yt_info('E') lists a live value as cfg.<name> when it differs from the default.
set_flag() {
	local name="$1" val="$2" n off=""
	for n in "${NODES[@]}"; do cfg_write "$n" "$name" C "$val"; done
	FLAGS_SET=1
	restart_all || true
	await_cluster || true
	wait_writable "${VOTERS[0]}" "${VOTERS[1]}" ab_t -1000 0 >/dev/null 2>&1 || true
	for n in "${NODES[@]}"; do
		[ "$(yinfo "$n" E "cfg.$name")" = "$val" ] || off+="$n "
	done
	[ -z "$off" ] && return 0
	info_line "$name=$val is not live on: ${off% }"
	return 1
}

# hot_ab <label> <writer> <table> <first id>: C11's load - 10 rows from <first id>,
# 8 writers for 30 s, every increment one transaction committed by <writer> (cw or
# cwc). Leaves "<rate>/s <verdict>" in AB_OUT, <verdict> one of:
#   ok        every node agrees and the sum is exactly the acknowledged increments
#   diverged  a node disagrees, or the sum is not what was acknowledged
#   idle      nothing was acknowledged, so there is nothing to compare
hot_ab() {
	local L="$1" W="$2" T="$3" lo="$4" hi=$(($4 + 9)) w o p pids=() acked=0 refused=0 first="" n s
	local R="id between $lo and $hi" verdict=ok refsum="" diffs="" agree=""
	for i in $(seq "$lo" "$hi"); do cw "${VOTERS[0]}" "insert into $T values ($i, 0)" >/dev/null; done
	wait_converged 30 "select count(*)::text || ':' || sum(v)::text from $T where $R" || true
	rm -f "$TMP"/w*.ok "$TMP"/w*.err
	for w in 0 1 2 3 4 5 6 7; do
		o="${VOTERS[$(( w % NV ))]}"
		(
			RANDOM=$((w * 7919 + 17))
			end=$((SECONDS + 30))
			while [ "$SECONDS" -lt "$end" ]; do
				id=$((RANDOM % 10 + lo))
				e="$("$W" "$o" "update $T set v = v + 1 where id = $id" 20s)"
				if [ -z "$e" ]; then echo "$id" >> "$TMP/w$w.ok"; else echo "$e" >> "$TMP/w$w.err"; fi
			done
		) &
		pids+=($!)
	done
	for p in "${pids[@]}"; do wait "$p" || true; done
	for w in 0 1 2 3 4 5 6 7; do
		acked=$((acked + $(lines "$TMP/w$w.ok")))
		refused=$((refused + $(lines "$TMP/w$w.err")))
		[ -n "$first" ] || [ ! -s "$TMP/w$w.err" ] || first="$(head -1 "$TMP/w$w.err")"
	done
	if [ "$acked" -eq 0 ]; then
		verdict=idle
	else
		agree=yes
		wait_converged 60 "select md5(string_agg(id::text||':'||v, ',' order by id)) from $T where $R" \
			|| { agree=no; verdict=diverged; }
		refsum="$(qt "${VOTERS[0]}" "select coalesce(sum(v),0) from $T where $R")"
		[ "$refsum" = "$acked" ] || verdict=diverged
		for n in "${NODES[@]}"; do
			s="$(qt "$n" "select coalesce(sum(v),0) from $T where $R")"
			[ "$s" = "$refsum" ] || diffs+="$n=${s:-?} "
		done
	fi
	AB_OUT="$(awk -v a="$acked" 'BEGIN { printf "%.1f", a / 30 }')/s $verdict"
	info_line "$L: $acked acknowledged, $refused refused; nodes agree: ${agree:-n/a}; sum ${refsum:-n/a} for $acked acknowledged - $AB_OUT${diffs:+ (sums: ${diffs% })}${first:+ - first refusal: ${first:0:140}}"
}

# ── setup ────────────────────────────────────────────────────────────────────

[ "$NV" -ge 3 ] || { bad "needs three non-spare nodes, has $NV"; summary; }
ONE_CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'cluster_commit=nodes>=2' | tail -1 || true)"
[ -n "$ONE_CFG" ] || { bad "yxctl --encode-table-cfg produced nothing (is $REPO_ROOT built?)"; summary; }
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists ab_t;  create table ab_t  (id bigint primary key, v bigint not null default 0);
	        drop table if exists ab1_t; create table ab1_t (id bigint primary key, v bigint not null default 0);" >/dev/null
done
register_table public.ab_t
register_table public.ab1_t "$ONE_CFG"
trap on_exit EXIT
flags_default
restart_all
await_cluster
wait_writable "${VOTERS[0]}" "${VOTERS[1]}" ab_t -1000 0 || { bad "cluster never became writable"; summary; }
ok "setup: ab_t (default party) and ab1_t (a party of one) on every node, both flags at their defaults"

# ── B0: both flags off ───────────────────────────────────────────────────────
hot_ab "B0 yt_complete(true)" cw ab_t 1;        B0_CW="$AB_OUT"
hot_ab "B0 plain COMMIT" cwc ab_t 11;           B0_CWC="$AB_OUT"
hot_ab "B0 one-node party" cw ab1_t 1;          B0_ONE="$AB_OUT"

# ── PS: peer_stream=1 ────────────────────────────────────────────────────────
PS_CW="not live"; PS_CWC="not live"
if set_flag peer_stream 1; then
	hot_ab "PS yt_complete(true)" cw ab_t 21;    PS_CW="$AB_OUT"
	hot_ab "PS plain COMMIT" cwc ab_t 31;        PS_CWC="$AB_OUT"
fi
for n in "${NODES[@]}"; do cfg_delete "$n" peer_stream C >/dev/null 2>&1 || true; done

# ── OP: one_pc=1 ─────────────────────────────────────────────────────────────
OP_ONE="not live"; OP_KILL="not run"
if set_flag one_pc 1; then
	hot_ab "OP one-node party" cw ab1_t 11;      OP_ONE="$AB_OUT"

	# The origin dies between yt_complete(true) and its COMMIT. A follower, so the
	# cluster keeps its leader; the member one_pc committed in the first phase holds
	# the row, and the origin's restart must apply it from its own WAL.
	L="$(leader_now || true)"
	O=""; for n in "${VOTERS[@]}"; do [ "$n" = "$L" ] || { O="$n"; break; }; done
	KID=900001
	rh "docker exec -d -u postgres $O psql -d $YX_DB -X -q -At -c begin \
	    -c \"insert into ab1_t (id, v) values ($KID, 7)\" -c 'select yt_complete(true)' \
	    -c 'select pg_sleep(120)' -c commit" >/dev/null 2>&1 || true
	slept=""
	for _ in $(seq 1 30); do
		[ "$(qt "$O" "select count(*) from pg_stat_activity where query = 'select pg_sleep(120)'")" = 1 ] && { slept=1; break; }
		sleep 1
	done
	if [ -z "$slept" ]; then
		OP_KILL="no commit to kill"
	else
		KT="$(host_now)"
		rh "docker kill $O >/dev/null" 2>/dev/null || true
		sleep 10
		rh "docker start $O >/dev/null" 2>/dev/null || true
		# Its SQL back first, and said when it is not: nightly 20261016 waited out
		# this whole block (16 min) on an origin whose PostgreSQL never answered,
		# read that as "diverged", and the flags could not be put back on it either.
		t_up=$SECONDS
		if ! node_ready "$O" 600 2>"$TMP/ready.err"; then
			OP_KILL="the origin did not come back: no SQL $((SECONDS - t_up)) s after its start"
			info_line "OP origin $O: $(tr '\n' ' ' < "$TMP/ready.err" | cut -c1-200)"
			rh "docker logs --since $KT $O 2>&1 | tail -15" 2>/dev/null | sed 's/^/  INFO   origin log: /' | cut -c1-260 || true
			rh "docker exec $O sh -c 'tail -8 /var/log/postgresql/postgresql-18-main.log'" 2>/dev/null \
				| sed 's/^/  INFO   origin pg log: /' | cut -c1-260 || true
		else
		for _ in $(seq 1 36); do [ -n "$(info "$O" O cluster)" ] && break; sleep 5; done
		held=""; agree=""
		for _ in $(seq 1 40); do
			held=""; for n in "${VOTERS[@]}"; do [ "$(qt "$n" "select count(*) from ab1_t where id = $KID")" = 1 ] && held+="$n "; done
			if [ -z "$held" ] || [ "$(echo $held)" = "$(echo "${VOTERS[@]}")" ]; then agree=1; break; fi
			sleep 3
		done
		stale=0
		for n in "${VOTERS[@]}"; do
			c="$(qt "$n" "select count(*) from pg_prepared_xacts where prepared < now() - interval '30 seconds'")"
			stale=$((stale + ${c:-0}))
		done
		if [ -n "$agree" ] && [ "$stale" = 0 ]; then OP_KILL="ok (row on $([ -n "$held" ] && echo "every voter" || echo "none"))"
		elif [ -n "$agree" ]; then OP_KILL="agree, $stale stale prepared"
		else OP_KILL="diverged (held by ${held% })"; fi
		fi
	fi
	info_line "OP origin $O killed after yt_complete(true): $OP_KILL"
	[ -z "${KT:-}" ] || rh "docker logs --since $KT $O 2>&1 | grep -E '2pc-recovery|own-open' | tail -4" 2>/dev/null \
		| sed 's/^/  INFO   origin log: /' | cut -c1-260 || true
fi

# ── back to the defaults ─────────────────────────────────────────────────────
# Every node answering first, or a row it holds survives the delete and is read at
# the restart below (the origin above, when it did not come back).
for n in "${NODES[@]}"; do
	[ "$(qt "$n" "select 1")" = 1 ] && continue
	echo "  NOTE: $n does not answer SQL - restarting it before the flags go"
	rh "docker restart $n >/dev/null" 2>/dev/null || true
	node_ready "$n" 600 >/dev/null 2>&1 || echo "  WARN: $n still does not answer"
done
flags_default
left=""
for n in "${NODES[@]}"; do
	c="$(qt "$n" "select count(*) from $YX_CFG where module='C' and name in ('peer_stream','one_pc')")"
	[ "$c" = 0 ] || left+="$n=${c:-?} "
done
[ -z "$left" ] || { echo "  NOTE: flag rows left after the delete (${left% }) - deleting again"; flags_default; }
restart_all || true
await_cluster || true
FLAGS_SET=0
off=""
for n in "${NODES[@]}"; do
	for f in peer_stream one_pc; do [ -z "$(yinfo "$n" E "cfg.$f")" ] || off+="$n:$f "; done
done
check "the fixture is back on the defaults (no flag live)" "" "${off% }"
wait_writable "${VOTERS[0]}" "${VOTERS[1]}" ab_t -1000 0 >/dev/null 2>&1 \
	&& ok "the cluster is writable for the next script" \
	|| bad "the cluster is not writable after the A/B"
on_exit

echo "  AB: base cw $B0_CW, cwc $B0_CWC, one-node $B0_ONE | peer_stream cw $PS_CW, cwc $PS_CWC | one_pc one-node $OP_ONE, kill $OP_KILL"
summary
