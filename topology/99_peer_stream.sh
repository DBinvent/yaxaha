#!/usr/bin/env bash
# [peer_stream] The bidi peer `sync()` stream (module-C `peer_stream`, default 0):
# one long-lived ordered stream per peer instead of a unary RPC per operation.
#
#   P1  peer_stream=1 on every node, restarted: serial writes from every origin
#       converge; then 200 back-to-back writes from 2 origins at once converge
#       within 60 s with nothing refused
#   P3  with the stream on and writes continuing, one follower is restarted:
#       no acknowledged row is lost on any node
#
# Finally peer_stream goes back to 0 - in an EXIT trap too, so a failed run
# never leaves the fixture on a flag that is off everywhere else.
#
# ## KNOWN GAP - the back-to-back half of P1 must FAIL today
#
# yt-pgxt ytserv/REFACTOR-streaming.md, "§1 peer bidi sync() stream - SHIPPED,
# default OFF", "Test outcome (peer_stream = 1)": serial writes pass, but
# back-to-back writes DIVERGE - the follower's single stream task is
# head-of-line blocked (`do_handle_apply` for op N stalls on the serialized
# apply, ops N+1... time out: "peer stream ack timeout"), `-c1 -t10` diverged
# and `-c1 -t30` wedged the node. The prerequisite named there - §4, ordered
# async apply - is not built. The back-to-back writes here are true
# back-to-back: one psql session per origin, no pause between transactions.
#
# Because that case is known to wedge a node, the cluster is restarted before
# P3 (peer_stream stays on), so P3 measures a restart under the stream and not
# the aftermath of the gap.
#
# ## min_cluster_size is a majority of the voters for this test
#
# "Writes continue" while a follower is restarted is only possible if the quorum
# survives losing one node, and at the fixture default (every voter) it does not
# (89_recover). Set on the startup path with peer_stream, restored with it.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== peer_stream: the peer sync() stream switched on =="

# ── helpers ──────────────────────────────────────────────────────────────────

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
NV=${#VOTERS[@]}
MAJ=$(( NV / 2 + 1 ))

qx() { # qx <node> <sql> [statement_timeout] -> psql's output WITH its errors
	local node="$1" sql="$2" to="${3:-60s}"
	printf '%s\n' "$sql" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=$to' $node \
psql -X -tAq -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d $YX_DB 2>&1" 2>&1 || true
}
err_of() {
	printf '%s\n' "$1" | { grep -m1 -E 'ERROR:|FATAL:|PANIC:|psql: error|server closed the connection|connection to server|No such container|Error response from daemon|is not running' || true; }
}
cw() { # cw <node> <statements> [timeout] -> "" when the cluster write committed, else the error
	local o
	o="$(qx "$1" "begin; $2; select yt_complete(true); commit;" "${3:-60s}")"
	err_of "$o"
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
# missing_report <table> <ids...> -> for every node that lacks some of <ids>,
# node=how-many ("?" when the node did not answer)
missing_report() {
	local rel="$1"; shift
	[ $# -gt 0 ] || return 0
	local arr n c out=""
	arr="$(IFS=,; echo "$*")"
	for n in "${NODES[@]}"; do
		c="$(qt "$n" "select count(*) from unnest(array[$arr]::bigint[]) a(id)
		              where not exists (select 1 from $rel t where t.id = a.id)")"
		[ "$c" = "0" ] || out+="$n=${c:-?} "
	done
	printf '%s' "${out% }"
}
wait_none_missing() { # wait_none_missing <secs> <table> <ids...>
	local deadline=$((SECONDS + $1)); shift
	while :; do
		[ -z "$(missing_report "$@")" ] && return 0
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 3
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
# b2b_sql <first-id> <count> <tag> -> one psql script of <count> cluster
# transactions back to back. Each is preceded by a `tx:<id>` marker, so the
# output says which ones COMMITted (the tag psql prints only for a commit that
# happened; an aborted one prints ROLLBACK or an error). Bounded by the
# database's own clock: past 150 s every remaining transaction is skipped, so a
# wedged stream cannot hold the session for <count> statement timeouts.
b2b_sql() {
	local first="$1" count="$2" tag="$3" i id s
	s="select (clock_timestamp() + interval '150 seconds') as dl \\gset"$'\n'
	for i in $(seq 0 $((count - 1))); do
		id=$((first + i))
		s+="select clock_timestamp() < :'dl'::timestamptz as go \\gset"$'\n'
		s+="\\if :go"$'\n'
		s+="select 'tx:$id';"$'\n'
		s+="begin;"$'\n'"insert into ps_t values ($id,'$tag');"$'\n'
		s+="select yt_complete(true);"$'\n'"commit;"$'\n'
		s+="\\endif"$'\n'
	done
	printf '%s' "$s"
}
acked_of() { # acked_of <b2b output file> -> the ids that COMMITted
	awk '/^tx:/ { id = substr($0, 4); next }
	     /^COMMIT$/ { if (id != "") print id; id = "" }
	     /^ROLLBACK$/ { id = "" }' "$1"
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

MCS_ORIG=""
TMP="$(mktemp -d)"
RESTORED=0
CLEANED=0
restore_settings() { # back to the fixture's settings; live after the next restart
	local n
	for n in "${NODES[@]}"; do
		cfg_delete "$n" peer_stream C     # no row = the compiled default, 0 (ytserv rmc.rs)
		if [ -n "$MCS_ORIG" ]; then cfg_write "$n" min_cluster_size C "$MCS_ORIG"
		else cfg_delete "$n" min_cluster_size C; fi
	done
}
drop_tables() {
	local n
	for n in "${NODES[@]}"; do
		q "$n" "drop table if exists ps_t; drop table if exists ps_r;" >/dev/null 2>&1
		cfg_delete "$n" public.ps_t A >/dev/null 2>&1
		cfg_delete "$n" public.ps_r A >/dev/null 2>&1
	done
	echo "  cleanup: ps_t and ps_r dropped, their module-A rows removed"
}
on_exit() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set +e
	local p
	for p in $(jobs -p); do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	if [ "$RESTORED" != 1 ]; then
		echo "  (stopped before the end: putting peer_stream back to 0 and restarting)"
		restore_settings
		drop_tables
		restart_all
		await_cluster
	else
		drop_tables
	fi
	rm -rf "$TMP"
}

# ── setup ────────────────────────────────────────────────────────────────────

[ "$NV" -ge 3 ] || { bad "needs three non-spare nodes, has $NV"; summary; }
MCS_ORIG="$(qt "${NODES[0]}" "select value from $YX_CFG where module='C' and name='min_cluster_size' limit 1")"
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists ps_t; create table ps_t (id bigint primary key, v text);
	        drop table if exists ps_r; create table ps_r (id bigint primary key, v text);" >/dev/null
done
register_table public.ps_t
register_table public.ps_r
trap on_exit EXIT
for n in "${NODES[@]}"; do
	cfg_write "$n" peer_stream C 1
	cfg_write "$n" min_cluster_size C "$MAJ"
done
echo "  peer_stream -> 1, min_cluster_size -> $MAJ (was ${MCS_ORIG:-unset}), restarting"
restart_all
await_cluster
wait_writable "${VOTERS[0]}" "${VOTERS[1]}" ps_t || { bad "cluster never became writable with peer_stream=1"; summary; }

# The flag must be LIVE, not merely written: yt_info('E') lists a live value as
# cfg.<name> when it differs from the compiled default.
off=""
for n in "${NODES[@]}"; do
	v="$(yinfo "$n" E cfg.peer_stream)"
	[ "$v" = "1" ] || off+="$n=${v:-0} "
done
check "P1 precondition: peer_stream is live on every node" "" "${off% }"

# ── P1: serial writes from every origin ──────────────────────────────────────
echo "  -- P1: 20 serial writes, every voter an origin in turn"
SER=(); ser_first=""
for i in $(seq 1 20); do
	o="${VOTERS[$(( (i - 1) % NV ))]}"
	e="$(cw "$o" "insert into ps_t values ($i,'serial-$o')" 30s)"
	if [ -z "$e" ]; then SER+=("$i"); else [ -n "$ser_first" ] || ser_first="$o: $e"; fi
	sleep 0.5
done
check "P1 all 20 serial writes are acknowledged" "20" "${#SER[@]}"
[ -z "$ser_first" ] || echo "     first refusal: ${ser_first:0:200}"
if [ "${#SER[@]}" -gt 0 ]; then
	wait_none_missing 60 ps_t "${SER[@]}" || true
	check "P1 serial: every node holds every acknowledged row within 60 s" "" \
		"$(missing_report ps_t "${SER[@]}")"
	DIG1="select md5(string_agg(id::text||':'||v, ',' order by id)) from ps_t where id between 1 and 20"
	wait_converged 30 "$DIG1" || true
	for n in "${NODES[@]}"; do
		[ "$n" = "${VOTERS[0]}" ] && continue
		check_same "P1 serial: $n is identical to ${VOTERS[0]}" "${VOTERS[0]}" "$n" "$DIG1" "${#SER[@]}" ps_t
	done
fi

# ── P1 [KNOWN GAP]: back-to-back from two origins at once ───────────────────
B1="${VOTERS[0]}"; B2="${VOTERS[1]}"
echo "  -- P1 [KNOWN GAP]: 2 x 100 back-to-back transactions, $B1 and $B2 at once"
for pair in "$B1:1001" "$B2:2001"; do
	o="${pair%%:*}"; first="${pair#*:}"
	(
		b2b_sql "$first" 100 "b2b-$o" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=20s' $o \
psql -X -tA -v VERBOSITY=terse -d $YX_DB 2>&1" > "$TMP/b2b-$o.out" 2>&1 || true
	) &
done
wait || true
mapfile -t ACK1 < <(acked_of "$TMP/b2b-$B1.out")
mapfile -t ACK2 < <(acked_of "$TMP/b2b-$B2.out")
for o in "$B1" "$B2"; do
	f="$(grep -m1 -E 'ERROR:|FATAL:|psql: error' "$TMP/b2b-$o.out" || true)"
	[ -z "$f" ] || echo "     $o first error: ${f:0:200}"
done
ACKB=( "${ACK1[@]}" "${ACK2[@]}" )
check "P1 [KNOWN GAP] back-to-back: nothing refused ($B1 ${#ACK1[@]}/100, $B2 ${#ACK2[@]}/100)" \
	"200" "${#ACKB[@]}"
if [ "${#ACKB[@]}" -gt 0 ]; then
	wait_none_missing 60 ps_t "${ACKB[@]}" || true
	check "P1 [KNOWN GAP] back-to-back: every node holds every acknowledged row within 60 s" "" \
		"$(missing_report ps_t "${ACKB[@]}")"
	DIG2="select md5(string_agg(id::text||':'||v, ',' order by id)) from ps_t where id between 1001 and 2100"
	for n in "${NODES[@]}"; do
		[ "$n" = "$B1" ] && continue
		check_same "P1 [KNOWN GAP] back-to-back: $n is identical to $B1" "$B1" "$n" "$DIG2" "${#ACKB[@]}" ps_t
	done
else
	bad "P1 [KNOWN GAP] back-to-back: nothing was acknowledged, so there is nothing to compare"
fi

# ── restart before P3 (peer_stream stays on) ────────────────────────────────
echo "  -- restarting the cluster: P3 must not measure the back-to-back aftermath"
restart_all
await_cluster
wait_writable "${VOTERS[0]}" "${VOTERS[1]}" ps_r || { bad "P3 the cluster never became writable after the restart"; summary; }

# ── P3: restart one follower while the stream is on and writes continue ──────
L="$(leader_now || true)"
F=""; O=""
for n in "${VOTERS[@]}"; do
	[ "$n" = "$L" ] && continue
	if [ -z "$F" ]; then F="$n"; elif [ -z "$O" ]; then O="$n"; fi
done
[ -n "$F" ] && [ -n "$O" ] || { bad "P3 needs two followers (leader: ${L:-unknown})"; summary; }
echo "  -- P3: leader ${L:-unknown}; $O writes for 75 s, $F is restarted at ~15 s"
(
	end=$((SECONDS + 75)); i=0
	while [ "$SECONDS" -lt "$end" ]; do
		i=$((i + 1)); id=$((30000 + i))
		e="$(cw "$O" "insert into ps_r values ($id,'p3-$O')" 20s)"
		if [ -z "$e" ]; then echo "$id" >> "$TMP/p3.ok"; else echo "$id $e" >> "$TMP/p3.err"; fi
		sleep 0.3
	done
) &
WPID=$!
sleep 15
rh "docker restart -t 2 $F >/dev/null" 2>/dev/null || true
echo "     $F restarted"
wait "$WPID" || true

back=0
for _ in $(seq 1 36); do
	[ -n "$(yinfo "$F" O cluster)" ] && { back=1; break; }
	sleep 5
done
[ "$back" = 1 ] \
	&& ok "P3 $F answers yt_info again after its restart" \
	|| { bad "P3 $F never came back within 180 s of its restart"; summary; }
check "P3 $F came back with peer_stream still on" "1" "$(yinfo "$F" E cfg.peer_stream)"
st=""
for _ in $(seq 1 36); do
	st="$(yinfo "$F" E state)"
	case "$st" in Good|Leader|*Main*) break ;; esac
	sleep 5
done
case "$st" in
	Good|Leader|*Main*) ok "P3 $F rejoined as a participant (state: $st)" ;;
	*) bad "P3 $F came back but is stuck in [${st:-?}] after 180 s" ;;
esac

mapfile -t P3 < <(cat "$TMP/p3.ok" 2>/dev/null || true)
echo "     acknowledged ${#P3[@]}, refused $(lines "$TMP/p3.err")"
if [ "${#P3[@]}" -gt 0 ]; then
	ok "P3 the writer had ${#P3[@]} acknowledged row(s) to account for"
	wait_none_missing 180 ps_r "${P3[@]}" || true
	check "P3 no acknowledged row is lost: every node holds all ${#P3[@]}" "" \
		"$(missing_report ps_r "${P3[@]}")"
	# Not graded: a write the client was told failed that committed anyway is a
	# different defect (C2 in 31_commit), but it belongs in the output.
	extra="$(qt "$O" "select count(*) from ps_r where id > 30000 and id not in ($(IFS=,; echo "${P3[*]}"))")"
	[ "${extra:-0}" = "0" ] || echo "     NOTE: $extra row(s) on $O whose writes were reported as refused"
else
	bad "P3 nothing was acknowledged during the restart window - nothing to account for"
fi

# ── restore ─────────────────────────────────────────────────────────────────
echo "  -- restoring peer_stream=0 and min_cluster_size=${MCS_ORIG:-unset}"
restore_settings
RESTORED=1
restart_all
await_cluster
on=""
for n in "${NODES[@]}"; do
	v="$(yinfo "$n" E cfg.peer_stream)"
	[ -z "$v" ] || [ "$v" = "0" ] || on+="$n=$v "
done
check "peer_stream is off again on every node" "" "${on% }"
wait_writable "${VOTERS[0]}" "${VOTERS[1]}" ps_r >/dev/null 2>&1 \
	&& ok "the cluster is writable with peer_stream off" \
	|| bad "the cluster is not writable after peer_stream was turned off"

on_exit
summary
