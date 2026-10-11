#!/usr/bin/env bash
# [concurrent] Agreement under concurrent writers. Not a benchmark: no rate is
# recorded or graded, the run lengths are fixed, and every assertion is about
# whether the nodes AGREE afterwards (PLAN.md, Group 6).
#
#   C10  100 small multi-row transactions, three origins taking turns: every
#        node identical, exactly the acknowledged rows, no `cluster_apply fail`
#   C12  a background writer loads table A; writes to an unrelated table B must
#        never be refused as "behind"
#   C11  a hot table of 10 rows, 8 concurrent writers incrementing random rows
#        from different origins for 30 s: every node identical afterwards
#
# ## C11 and C12 - known gaps until ytserv 0.20.61
#
# C11: concurrent increments of one row from different origins lost updates:
# the leader's checkin compared new images only, so two `v = v + 1` from the
# same base both shipped `v = 5` and were both admitted, and an image built on
# a stale copy was admitted too (the CAS apply then matched 0 rows on the
# others). Since 0.20.61 the first writer of a row wins ([rmw], checkin.rs):
# a later UPDATE/DELETE of a row another origin wrote and this origin has not
# applied is refused with 40001, and the client retries it. Refused increments
# are not acknowledged, so the sums still have to agree.
#
# C12: under load a row in flight read as a gap for about a second and refused
# writes to every synced table (`Recon::mark_outdated` is coarse on purpose).
# It passed in the 2026-10-10 nightly (0.17.58); kept as a regression check.
#
# Order is C10, C12, C11: least disruptive first, so each result is read against
# a cluster the previous one did not break. Between sections the cluster must
# become writable again before the next one starts.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== concurrent: do the nodes agree after concurrent writers? =="

# ── helpers (local: env.sh's q discards stderr, and these need the error) ────

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
lacking() { # lacking <table> <where> <want> -> nodes whose count(*) differs, as node=count
	local n c out=""
	for n in "${NODES[@]}"; do
		c="$(qt "$n" "select count(*) from $1 where $2")"
		[ "$c" = "$3" ] || out+="$n=${c:-?} "
	done
	printf '%s' "${out% }"
}
wait_all() { # wait_all <secs> <table> <where> <want>
	local deadline=$((SECONDS + $1))
	while :; do
		[ -z "$(lacking "$2" "$3" "$4")" ] && return 0
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 2
	done
}
# wait_converged <secs> <digest-sql> -> 0 once every node returns the same,
# non-empty digest (md5 of nothing is NULL, so empty tables never "converge")
wait_converged() {
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
lines() { # lines <file> -> its line count, 0 when absent
	if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi
}
host_now() { rh "date +%s" 2>/dev/null || date +%s; }
# apply_fails_since <unix-ts> -> `cluster_apply fail` lines logged by every node
# since then. An error-level line, so the fixture's log_level=warning keeps it.
apply_fails_since() {
	local n c total=0
	for n in "${NODES[@]}"; do
		c="$(rh "docker logs --since $1 $n 2>&1 | grep -c 'cluster_apply fail'" 2>/dev/null || true)"
		case "$c" in ''|*[!0-9]*) c=0 ;; esac
		total=$((total + c))
	done
	echo "$total"
}

TMP="$(mktemp -d)"
CLEANED=0
cleanup() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set +e
	local p
	for p in $(jobs -p); do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	for n in "${NODES[@]}"; do
		q "$n" "drop table if exists cc_t; drop table if exists hot_t;
		        drop table if exists ca_t; drop table if exists cb_t;" >/dev/null 2>&1
		for t in cc_t hot_t ca_t cb_t; do cfg_delete "$n" "public.$t" A >/dev/null 2>&1; done
	done
	rm -rf "$TMP"
	echo "  cleanup: cc_t hot_t ca_t cb_t dropped, their module-A rows removed"
}

# ── setup ────────────────────────────────────────────────────────────────────

[ "$NV" -ge 3 ] || { bad "needs three non-spare nodes, has $NV"; summary; }
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists cc_t;  create table cc_t  (id bigint primary key, v text);
	        drop table if exists hot_t; create table hot_t (id bigint primary key, v bigint not null default 0);
	        drop table if exists ca_t;  create table ca_t  (id bigint primary key, v text);
	        drop table if exists cb_t;  create table cb_t  (id bigint primary key, v text);" >/dev/null
done
# All four before ONE restart: a module-A row is read by the startup loader.
register_table public.cc_t
register_table public.hot_t
register_table public.ca_t
register_table public.cb_t
trap cleanup EXIT
restart_all
await_cluster
REF="${VOTERS[0]}"
wait_writable "$REF" "${VOTERS[1]}" cc_t || { bad "cluster never became writable"; summary; }
settle() {
	wait_writable "$REF" "${VOTERS[1]}" cc_t >/dev/null 2>&1 \
		|| bad "the cluster did not become writable again after $1"
}

# ── C10: small multi-row transactions, three origins in turn ─────────────────
ORIG=( "${VOTERS[@]:0:3}" )
echo "  -- C10: 100 three-row transactions, origins ${ORIG[*]} in turn"
T0="$(host_now)"
acked=0; refused=0; first=""
for i in $(seq 1 100); do
	o="${ORIG[$(( (i - 1) % 3 ))]}"
	b=$((i * 10))
	e="$(cw "$o" "insert into cc_t values ($((b+1)),'c10-$i-a-$o'), ($((b+2)),'c10-$i-b-$o'), ($((b+3)),'c10-$i-c-$o')" 30s)"
	if [ -z "$e" ]; then acked=$((acked + 1)); else refused=$((refused + 1)); [ -n "$first" ] || first="$e"; fi
done
echo "     acknowledged $acked of 100, refused $refused${first:+ - first: ${first:0:140}}"
[ "$acked" -gt 0 ] \
	&& ok "C10 transactions committed ($acked of 100)" \
	|| bad "C10 nothing committed - every comparison below would be vacuous"

DIG10="select md5(string_agg(id::text||':'||v, ',' order by id)) from cc_t where id > 0"
wait_converged 90 "$DIG10" || true
# Exactly the acknowledged rows: fewer is a lost ack, more is a write the client
# was told failed that committed anyway.
check "C10 $REF holds exactly the acknowledged rows" "$((acked * 3))" \
	"$(qt "$REF" "select count(*) from cc_t where id > 0")"
min10=$((acked * 3)); [ "$min10" -gt 0 ] || min10=1
for n in "${NODES[@]}"; do
	[ "$n" = "$REF" ] && continue
	check_same "C10 $n is identical to $REF" "$REF" "$n" "$DIG10" "$min10" cc_t
done
check "C10 no 'cluster_apply fail' logged on any node during C10" "0" "$(apply_fails_since "$T0")"
settle "C10"

# ── C12: an unrelated table, written while another is loaded ─────
OA="${VOTERS[0]}"
B_ORIG=()
for n in "${VOTERS[@]}"; do [ "$n" = "$OA" ] || B_ORIG+=("$n"); done
echo "  -- C12: $OA loads ca_t; cb_t written from ${B_ORIG[*]} meanwhile"
(
	end=$((SECONDS + 32)); i=0
	while [ "$SECONDS" -lt "$end" ]; do
		i=$((i + 1))
		e="$(cw "$OA" "insert into ca_t values ($i,'load-$i')" 20s)"
		if [ -z "$e" ]; then echo "$i" >> "$TMP/a.ok"; else echo "$e" >> "$TMP/a.err"; fi
	done
) &
APID=$!
sleep 2
b_try=0; b_gap=0; b_other=0; gap_first=""; other_first=""; k=0
end=$((SECONDS + 28))
while [ "$SECONDS" -lt "$end" ]; do
	o="${B_ORIG[$(( k % ${#B_ORIG[@]} ))]}"
	k=$((k + 1)); b_try=$((b_try + 1))
	e="$(cw "$o" "insert into cb_t values ($k,'b-$o')" 20s)"
	if [ -n "$e" ]; then
		case "${e,,}" in
			*"is behind"*|*"catching up"*|*outdated*|*gap*)
				b_gap=$((b_gap + 1)); [ -n "$gap_first" ] || gap_first="$o: $e" ;;
			*)
				b_other=$((b_other + 1)); [ -n "$other_first" ] || other_first="$o: $e" ;;
		esac
	fi
	sleep 0.2
done
wait "$APID" || true
a_ok="$(lines "$TMP/a.ok")"
[ "$a_ok" -ge 10 ] \
	&& ok "C12 the load was real: $a_ok rows committed to ca_t from $OA ($(lines "$TMP/a.err") refused)" \
	|| bad "C12 the load committed only $a_ok row(s) to ca_t - the case under test did not happen"
[ "$b_try" -ge 20 ] \
	&& ok "C12 $b_try writes to cb_t were attempted during the load" \
	|| bad "C12 only $b_try writes to cb_t were attempted - too few to mean anything"
check "C12 no write to cb_t is refused as behind/outdated (of $b_try)" "0" "$b_gap"
[ -z "$gap_first" ] || echo "     first such refusal: ${gap_first:0:200}"
[ "$b_other" -eq 0 ] || echo "     other refusals (not this check's subject): $b_other - first: ${other_first:0:200}"
settle "C12"

# ── C11: a hot small table under 8 concurrent writers ────────────
echo "  -- C11: 10 hot rows, 8 writers for 30 s"
# Seeded one row per transaction: the seed is setup, so it must not be the
# flaky part (80_recon's lesson).
for i in $(seq 1 10); do cw "$REF" "insert into hot_t values ($i, 0)" >/dev/null; done
wait_all 30 hot_t "id > 0 and v = 0" 10 || true
check "C11 setup: 10 hot rows, all zero, on every node" "" "$(lacking hot_t "id > 0 and v = 0" 10)"

pids=()
for w in 0 1 2 3 4 5 6 7; do
	o="${VOTERS[$(( w % NV ))]}"
	(
		RANDOM=$((w * 7919 + 17))   # each writer its own sequence of rows
		end=$((SECONDS + 30))
		while [ "$SECONDS" -lt "$end" ]; do
			id=$((RANDOM % 10 + 1))
			e="$(cw "$o" "update hot_t set v = v + 1 where id = $id" 20s)"
			if [ -z "$e" ]; then echo "$id" >> "$TMP/w$w.ok"; else echo "$e" >> "$TMP/w$w.err"; fi
		done
	) &
	pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
hacked=0; hrefused=0; hfirst=""
for w in 0 1 2 3 4 5 6 7; do
	hacked=$((hacked + $(lines "$TMP/w$w.ok")))
	hrefused=$((hrefused + $(lines "$TMP/w$w.err")))
	[ -n "$hfirst" ] || [ ! -s "$TMP/w$w.err" ] || hfirst="$(head -1 "$TMP/w$w.err")"
done
echo "     acknowledged $hacked increments, refused $hrefused${hfirst:+ - first: ${hfirst:0:140}}"
[ "$hacked" -gt 0 ] \
	&& ok "C11 the writers committed ($hacked increments acknowledged)" \
	|| bad "C11 no increment committed - the comparison below would be vacuous"

HDIG="select md5(string_agg(id::text||':'||v, ',' order by id)) from hot_t where id > 0"
wait_converged 60 "$HDIG" || true
for n in "${NODES[@]}"; do
	[ "$n" = "$REF" ] && continue
	check_same "C11 $n agrees with $REF on the hot table" "$REF" "$n" "$HDIG" 10 hot_t
done
refsum="$(qt "$REF" "select coalesce(sum(v),0) from hot_t where id > 0")"
diff=""
for n in "${NODES[@]}"; do
	s="$(qt "$n" "select coalesce(sum(v),0) from hot_t where id > 0")"
	[ "$s" = "$refsum" ] || diff+="$n=${s:-?} "
done
check "C11 sum(v) is the same on every node ($REF has $refsum)" "" "${diff% }"
# Every acknowledged increment is one, and only acknowledged ones count: fewer is
# a lost update, more is an increment the client was told failed.
check "C11 sum(v) on $REF equals the acknowledged increments" "$hacked" "$refsum"

# ── leave the cluster writable for the next script ──────────────────────────
if ! wait_writable "$REF" "${VOTERS[1]}" cc_t >/dev/null 2>&1; then
	echo "  NOTE: not writable after C11 - restarting the cluster"
	restart_all
	await_cluster
fi
cleanup
summary
