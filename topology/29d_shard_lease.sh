#!/usr/bin/env bash
# [shard-lease] A node that keeps writing one shard leases the shard's subterms and
# issues them as the shard's holder; another node writing the shard checks in with
# the holder, sent there by the leader. yt-pgxt pre-checkin.md "Shard lease".
#
# Written 2026-10-16 without a run (full test runs were off for a dev session) and
# put in run_a.sh as it was, the owner's call: its first run is the next nightly.
#
# sl_t's shard is its `store` column, pinned (`outer=pin`): store 'top' is az top,
# n1 and n2 here, so both may write it, nobody else holds it. `hpc` puts the table
# at sequential_consistency 2, which any subterm lease needs.
#
#   L1  W, a top node that is not the leader, writes store 'top' fast: it comes to
#       hold the lease of shard top (yt_info('E') hpc_lease)
#   L2  O, the other top node, writes store 'top' while W holds it: every write
#       commits, and W issued them - its run's next subterm moved by as many
#   L3  n1 and n2 hold the same sl_t, exactly the acknowledged rows
#   L4  nobody writes for longer than the lease: it lapses, and O's next write is
#       admitted by the leader again
#   L5  W takes the lease again and drops off the network with it: O's writes of
#       the shard fail while they are sent to W, and commit again once the lease
#       lapsed - nothing waits for W for good (added 2026-10-16, unrun)
#   L6  W back on the network holds what O holds
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== shard lease: a shard's subterms issued by the node that writes it =="

qx() { # qx <node> <sql> [statement_timeout] -> psql's output WITH its errors
	local node="$1" sql="$2" to="${3:-60s}"
	printf '%s\n' "$sql" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=$to' $node \
psql -X -tAq -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d $YX_DB 2>&1" 2>&1 || true
}
err_of() {
	printf '%s\n' "$1" | { grep -m1 -E 'ERROR:|FATAL:|PANIC:|psql: error|server closed the connection|connection to server' || true; }
}
cwc() { err_of "$(qx "$1" "begin; $2; commit;" "${3:-60s}")"; }
qt() {
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}
yinfo() { # yinfo <node> <letters> <name> -> one yt_info value
	qt "$1" "select yt_info('$2')" | python3 -c "
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
lease_next() { # the holder's next subterm, from "... next N, ..."
	yinfo "$1" E hpc_lease | sed -nE 's/.* next ([0-9]+),.*/\1/p'
}

cleanup() {
	set +e
	local n
	# L5 takes the holder off the network: never leave it so
	[ -n "${W:-}" ] && node_up "$W" >/dev/null 2>&1
	for n in "${NODES[@]}"; do
		q "$n" "drop table if exists sl_t;" >/dev/null 2>&1
		cfg_delete "$n" public.sl_t A >/dev/null 2>&1 || true
	done
}

# ── setup ────────────────────────────────────────────────────────────────────
TOPS=(); for n in "${NODES[@]}"; do [ "${NODE_AZ[$n]:-}" = top ] && TOPS+=("$n"); done
[ "${#TOPS[@]}" -ge 2 ] || { bad "needs two nodes in az top, has ${#TOPS[@]}"; summary; }
CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'shard=store; outer=pin; hpc' | tail -1 || true)"
[ -n "$CFG" ] || { bad "yxctl --encode-table-cfg does not know 'hpc' (is $REPO_ROOT built?)"; summary; }
trap cleanup EXIT
cleanup
for n in "${NODES[@]}"; do
	q "$n" "create table sl_t (store text not null, id bigint not null, v bigint, primary key (store, id));" >/dev/null
done
register_table public.sl_t "$CFG"
restart_all
await_cluster
L="$(leader_now)"
# W: a top node that is not the leader - the leader leases to nobody, itself included
W=""; O=""
for n in "${TOPS[@]}"; do [ "$n" != "$L" ] && [ -z "$W" ] && W="$n"; done
for n in "${TOPS[@]}"; do [ "$n" != "$W" ] && [ -z "$O" ] && O="$n"; done
[ -n "$W" ] && [ -n "$O" ] || { bad "no top node to lease (leader $L, top ${TOPS[*]})"; summary; }
echo "  leader $L, lease writer $W, other writer $O"
# writable, and replicating to O: a fresh negative id per attempt, as wait_writable
for i in $(seq 1 24); do
	cwc "$W" "insert into sl_t values ('top', -$i, 0)" >/dev/null
	[ "$(qt "$O" "select count(*) from sl_t where id = -$i")" = 1 ] && break
	sleep 5
done
cwc "$W" "delete from sl_t where id < 0" >/dev/null
# batch <node> <first id> <count>: that many inserts of store 'top' in ONE psql
# session, each its own transaction (autocommit; auto_complete makes each a cluster
# commit) - one docker exec per statement is too slow for the hheuristic's 10 writes
# in 2 s. Sets BATCH_N, how many of the ids are on the node afterwards, and
# BATCH_ERR - globals, not output: a command substitution would lose BATCH_ERR.
batch() {
	local sql="" i
	for i in $(seq "$2" $(($2 + $3 - 1))); do sql+="insert into sl_t values ('top', $i, $i);"$'\n'; done
	BATCH_ERR="$(err_of "$(qx "$1" "$sql" 120s)")"
	BATCH_N="$(qt "$1" "select count(*) from sl_t where id between $2 and $(($2 + $3 - 1))")"
}

# ── L1: the writer comes to hold the lease ──────────────────────────────────
# 40: past the 10 the lease is asked after, well inside the run it is given (the
# rate over the window times hpc_lease_sec - about 200)
batch "$W" 1 40; acked="${BATCH_N:-0}"
check "L1 $W's 40 writes of shard top committed" "40" "${acked:-0}${BATCH_ERR:+ - $BATCH_ERR}"
case "$(yinfo "$W" E hpc_lease)" in
	*"holds shard top of public.sl_t"*) ok "L1 $W holds the lease of shard top: $(yinfo "$W" E hpc_lease)" ;;
	*) bad "L1 $W does not hold shard top: [$(yinfo "$W" E hpc_lease)]" ;;
esac

# ── L2: the other top node's writes go through the holder ───────────────────
n0="$(lease_next "$W")"
batch "$O" 1001 10; o_acked="${BATCH_N:-0}"
n1="$(lease_next "$W")"
check "L2 every write of $O to shard top committed" "10" "${o_acked:-0}${BATCH_ERR:+ - $BATCH_ERR}"
if [ -n "$n0" ] && [ -n "$n1" ]; then
	[ "$((n1 - n0))" -ge 10 ] && ok "L2 $W issued them: its run moved from $n0 to $n1" \
		|| bad "L2 $W's run moved from $n0 to $n1 for 10 writes of $O - not issued by the holder"
else
	bad "L2 $W holds no lease any more to read its run from: [$(yinfo "$W" E hpc_lease)]"
fi

# ── L3: the two top nodes agree ─────────────────────────────────────────────
want=$(( ${acked:-0} + ${o_acked:-0} ))
for _ in $(seq 1 20); do
	a="$(qt "${TOPS[0]}" "select count(*) from sl_t where id > 0")"; b="$(qt "${TOPS[1]}" "select count(*) from sl_t where id > 0")"
	[ "$a" = "$want" ] && [ "$b" = "$want" ] && break
	sleep 3
done
check "L3 ${TOPS[0]} holds exactly the acknowledged rows" "$want" "$a"
check "L3 ${TOPS[1]} holds exactly the acknowledged rows" "$want" "$b"
check "L3 the two agree on sl_t" "$(qt "${TOPS[0]}" "select md5(string_agg(store||id||':'||v, ',' order by id)) from sl_t")" \
	"$(qt "${TOPS[1]}" "select md5(string_agg(store||id||':'||v, ',' order by id)) from sl_t")"

# ── L4: the lease lapses, and the leader takes the shard again ──────────────
sleep 25
case "$(yinfo "$W" E hpc_lease)" in
	*"holds shard top"*"spent or past its time"*|*"holds none"*) ok "L4 the lease lapsed: $(yinfo "$W" E hpc_lease)" ;;
	*) bad "L4 the lease is still held 25 s after the writing stopped: [$(yinfo "$W" E hpc_lease)]" ;;
esac
check "L4 $O's write after the lapse committed" "" "$(cwc "$O" "insert into sl_t values ('top', 2001, 1)")"

# ── L5: the holder goes away under its lease ────────────────────────────────
batch "$W" 3001 40
case "$(yinfo "$W" E hpc_lease)" in
	*"holds shard top of public.sl_t"*) ok "L5 $W holds the lease of shard top again" ;;
	*) bad "L5 $W did not take the lease again: [$(yinfo "$W" E hpc_lease)]" ;;
esac
node_down "$W"
t0=$(date +%s); back=""; e=""
for i in $(seq 1 24); do
	e="$(cwc "$O" "insert into sl_t values ('top', $((4000 + i)), $i)" 30s)"
	[ -z "$e" ] && { back=$(( $(date +%s) - t0 )); break; }
	sleep 5
done
[ -n "$back" ] && ok "L5 with the holder gone, $O's write of shard top committed again after ${back}s" \
	|| bad "L5 $O's writes of shard top never committed in 2 min with the holder $W off the network: [$e]"
node_up "$W"

# ── L6: the holder back holds what the others hold ──────────────────────────
a=""; b=""
for _ in $(seq 1 30); do
	a="$(qt "$O" "select md5(string_agg(store||id||':'||v, ',' order by id)) from sl_t")"
	b="$(qt "$W" "select md5(string_agg(store||id||':'||v, ',' order by id)) from sl_t")"
	[ -n "$a" ] && [ "$a" = "$b" ] && break
	sleep 5
done
check "L6 $W back on the network holds what $O holds" "$a" "$b"
summary
