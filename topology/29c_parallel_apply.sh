#!/usr/bin/env bash
# [par-apply] A table's `parallel` flag (CfgTabl.parallel_apply): the nodes that
# receive its transactions by apply run them in parallel instead of one at a time
# in subterm order - but only a transaction whose every table, and every table one
# foreign key away from them, has the flag. A miss (an update matching no row, an
# insert finding its row, a foreign key not there yet) is applied again in order.
# yt-pgxt ytserv/src/state/par_apply.rs.
#
# The flagged tables commit on no party at all - cluster_commit=nodes>=1, and N
# counts the origin - so the origin commits alone and every other voter receives
# the transaction by apply: the path the flag changes.
#
#   P1  par_ev, flagged, no keys: 8 writers insert for 30 s from every voter.
#       The nodes agree, and the receivers say they applied in parallel.
#   P2  par_c1 flagged, its parent par_p1 not: the children stay in order, and
#       the receivers name the parent as the reason. Nothing runs in parallel.
#   P3  par_p2 and par_c2 both flagged: each parent and its child are written
#       by two transactions, back to back. The nodes agree - a child applied
#       ahead of its parent misses its key and is applied again in order.
#   P4  par_hot, flagged: 29_concurrent's hot load (10 rows, 8 writers, 30 s).
#       The nodes agree and the sum is what was acknowledged.
#
# And no node logs a CLUSTER DIVERGENCE while it runs.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== parallel apply: the flag, its foreign-key rule, and agreement under load =="

# ── helpers (as 29b_flags_ab) ────────────────────────────────────────────────

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
cwc() { # a plain COMMIT, the cluster commit is auto_complete's -> "" or the error
	err_of "$(qx "$1" "begin; $2; commit;" "${3:-60s}")"
}
qt() { # q plus a statement_timeout, so a wedged ytserv cannot hang a poll
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
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
host_now() { rh "date +%s" 2>/dev/null || date +%s; }

# par_counts: PA PR PF = subterms in parallel, applied again in order, refused
# (a flagged table's, in order because of another table), summed over every node
# from yt_info('E')'s parallel_apply line; LAST_WHY: the refusal reasons. Globals,
# not output: a command substitution would lose LAST_WHY in its subshell.
par_counts() {
	local n j out x y z why
	PA=0; PR=0; PF=0; LAST_WHY=""
	for n in "${NODES[@]}"; do
		j="$(qt "$n" "select yt_info('E')")"
		out="$(printf '%s' "$j" | python3 -c "
import json, re, sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in rows:
    if r.get('name') == 'parallel_apply':
        v = r.get('value', '')
        m = re.match(r'(\\d+) subterm.*?(\\d+) of them applied again.*?(\\d+) of a flagged table in order', v)
        w = re.search(r'\\(last: (.*)\\);', v)
        if m: print(m.group(1), m.group(2), m.group(3), w.group(1) if w else '')
        break
" 2>/dev/null)"
		[ -n "$out" ] || continue
		read -r x y z why <<< "$out"
		PA=$((PA + x)); PR=$((PR + y)); PF=$((PF + z))
		[ -z "$why" ] || LAST_WHY+="$n: $why | "
	done
}

# load <label> <writers> <secs> <body-fn>: <body-fn> <writer> <origin> <i> runs one
# transaction and prints its error, or nothing when it committed
load() {
	local L="$1" W="$2" S="$3" F="$4" w o pids=() acked=0 refused=0 first=""
	rm -f "$TMP"/w*.ok "$TMP"/w*.err
	for w in $(seq 0 $((W - 1))); do
		o="${VOTERS[$(( w % NV ))]}"
		(
			RANDOM=$((w * 7919 + 17)); i=0
			end=$((SECONDS + S))
			while [ "$SECONDS" -lt "$end" ]; do
				i=$((i + 1))
				e="$("$F" "$w" "$o" "$i")"
				if [ -z "$e" ]; then echo "$i" >> "$TMP/w$w.ok"; else echo "$e" >> "$TMP/w$w.err"; fi
			done
		) &
		pids+=($!)
	done
	for p in "${pids[@]}"; do wait "$p" || true; done
	for w in $(seq 0 $((W - 1))); do
		acked=$((acked + $(lines "$TMP/w$w.ok")))
		refused=$((refused + $(lines "$TMP/w$w.err")))
		[ -n "$first" ] || [ ! -s "$TMP/w$w.err" ] || first="$(head -1 "$TMP/w$w.err")"
	done
	ACKED=$acked
	echo "     $L: $acked acknowledged, $refused refused${first:+ - first: ${first:0:160}}"
}

TMP="$(mktemp -d)"
TABLES="par_c2 par_p2 par_c1 par_p1 par_ev par_hot"
CLEANED=0
drop_tables() {
	local n t
	for n in "${NODES[@]}"; do
		for t in $TABLES; do
			q "$n" "drop table if exists $t;" >/dev/null 2>&1
			cfg_delete "$n" "public.$t" A >/dev/null 2>&1 || true
		done
	done
}
on_exit() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set +e
	local p
	for p in $(jobs -p); do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	drop_tables
	rm -rf "$TMP"
}

# ── setup ────────────────────────────────────────────────────────────────────

[ "$NV" -ge 3 ] || { bad "needs three non-spare nodes, has $NV"; summary; }
PAR_CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'parallel; cluster_commit=nodes>=1' | tail -1 || true)"
ONE_CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'cluster_commit=nodes>=1' | tail -1 || true)"
[ -n "$PAR_CFG" ] && [ -n "$ONE_CFG" ] && [ "$PAR_CFG" != "$ONE_CFG" ] \
	|| { bad "yxctl --encode-table-cfg does not know 'parallel' (is $REPO_ROOT built?)"; summary; }
trap on_exit EXIT
drop_tables
for n in "${NODES[@]}"; do
	q "$n" "create table par_ev  (id bigint primary key, origin text, v bigint not null default 0);
	        create table par_hot (id bigint primary key, v bigint not null default 0);
	        create table par_p1  (id bigint primary key, name text);
	        create table par_c1  (id bigint primary key, parent_id bigint not null references par_p1(id), v bigint);
	        create table par_p2  (id bigint primary key, name text);
	        create table par_c2  (id bigint primary key, parent_id bigint not null references par_p2(id), v bigint);" >/dev/null
done
register_table public.par_ev  "$PAR_CFG"
register_table public.par_hot "$PAR_CFG"
register_table public.par_p1  "$ONE_CFG"
register_table public.par_c1  "$PAR_CFG"
register_table public.par_p2  "$PAR_CFG"
register_table public.par_c2  "$PAR_CFG"
restart_all
await_cluster
wait_writable "${VOTERS[0]}" "${VOTERS[1]}" par_ev -1000 0 >/dev/null 2>&1 || { bad "the cluster never became writable"; summary; }
v="$(qt "${VOTERS[1]}" "select yt_info('a:public.par_ev')" | python3 -c "
import json,sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in rows:
    if r.get('name') == 'parallel_apply': print(r.get('value','')); break
" 2>/dev/null)"
check "setup: par_ev carries the flag as the node loaded it (yt_info('a:public.par_ev'))" "true" "$v"
T0="$(host_now)"
par_counts; A0=$PA; R0=$PR; F0=$PF

# ── P1: inserts, no keys ─────────────────────────────────────────────────────
ev_tx() { cwc "$2" "insert into par_ev values ($(( ($1 + 1) * 1000000 + $3 )), '$2', $3)" 20s; }
load "P1 inserts into par_ev" 8 30 ev_tx
P1_ACKED=$ACKED
if wait_converged 120 "select count(*)::text || ':' || coalesce(sum(v), 0)::text from par_ev where id > 0"; then
	ok "P1 every node holds the same par_ev ($(qt "${VOTERS[0]}" "select count(*) from par_ev where id > 0") rows)"
else
	bad "P1 the nodes disagree on par_ev: $(for n in "${NODES[@]}"; do printf '%s=%s ' "$n" "$(qt "$n" "select count(*) from par_ev where id > 0")"; done)"
fi
check "P1 par_ev holds exactly the acknowledged inserts" "$P1_ACKED" "$(qt "${VOTERS[0]}" "select count(*) from par_ev where id > 0")"
par_counts; A1=$PA; R1=$PR; F1=$PF
[ "$((A1 - A0))" -gt 0 ] && ok "P1 the receivers applied $((A1 - A0)) subterm(s) in parallel ($((R1 - R0)) again in order)" \
	|| bad "P1 nothing was applied in parallel (counters $A0 -> $A1)"

# ── P2: a flagged child of an unflagged parent ──────────────────────────────
for i in $(seq 1 20); do cwc "${VOTERS[0]}" "insert into par_p1 values ($i, 'p$i')" >/dev/null; done
wait_converged 60 "select count(*)::text from par_p1" || true
c1_tx() { cwc "$2" "insert into par_c1 values ($(( ($1 + 1) * 1000000 + $3 )), $(( $3 % 20 + 1 )), $3)" 20s; }
load "P2 children of par_p1 into par_c1" 4 15 c1_tx
P2_ACKED=$ACKED
wait_converged 120 "select count(*)::text || ':' || coalesce(sum(v), 0)::text from par_c1" \
	&& ok "P2 every node holds the same par_c1" || bad "P2 the nodes disagree on par_c1"
check "P2 par_c1 holds exactly the acknowledged inserts" "$P2_ACKED" "$(qt "${VOTERS[0]}" "select count(*) from par_c1")"
par_counts; A2=$PA; R2=$PR; F2=$PF
check "P2 nothing ran in parallel: par_c1's parent par_p1 has no flag" "0" "$((A2 - A1))"
[ "$((F2 - F1))" -gt 0 ] && ok "P2 $((F2 - F1)) subterm(s) of par_c1 went in order because of another table" \
	|| bad "P2 no subterm was refused parallel (counters $F1 -> $F2)"
case "$LAST_WHY" in
	*public.par_p1*) ok "P2 the reason names the parent: ${LAST_WHY%% | *}" ;;
	*) bad "P2 the reason does not name public.par_p1: [${LAST_WHY:0:300}]" ;;
esac

# ── P3: parent and child in two transactions, both flagged ──────────────────
p2_tx() {
	local k=$(( ($1 + 1) * 1000000 + $3 )) e
	e="$(cwc "$2" "insert into par_p2 values ($k, 'p$k')" 20s)"
	[ -z "$e" ] || { echo "$e"; return; }
	cwc "$2" "insert into par_c2 values ($k, $k, $3)" 20s
}
load "P3 parents into par_p2, then their children into par_c2" 8 30 p2_tx
P3_ACKED=$ACKED
wait_converged 120 "select (select count(*) from par_p2)::text || ':' || count(*)::text || ':' || coalesce(sum(v), 0)::text from par_c2" \
	&& ok "P3 every node holds the same par_p2 and par_c2" \
	|| bad "P3 the nodes disagree: $(for n in "${NODES[@]}"; do printf '%s=%s/%s ' "$n" "$(qt "$n" "select count(*) from par_p2")" "$(qt "$n" "select count(*) from par_c2")"; done)"
check "P3 par_c2 holds exactly the acknowledged children" "$P3_ACKED" "$(qt "${VOTERS[0]}" "select count(*) from par_c2")"
par_counts; A3=$PA; R3=$PR; F3=$PF
[ "$((A3 - A2))" -gt 0 ] && ok "P3 $((A3 - A2)) subterm(s) in parallel, $((R3 - R2)) of them again in order" \
	|| bad "P3 nothing was applied in parallel (counters $A2 -> $A3)"

# ── P4: the hot load ────────────────────────────────────────────────────────
for i in $(seq 1 10); do cwc "${VOTERS[0]}" "insert into par_hot values ($i, 0)" >/dev/null; done
wait_converged 60 "select count(*)::text from par_hot" || true
hot_tx() { cwc "$2" "update par_hot set v = v + 1 where id = $(( RANDOM % 10 + 1 ))" 20s; }
load "P4 hot updates of par_hot" 8 30 hot_tx
P4_ACKED=$ACKED
wait_converged 120 "select md5(string_agg(id::text || ':' || v, ',' order by id)) from par_hot" \
	&& ok "P4 every node holds the same par_hot" \
	|| bad "P4 the nodes disagree on par_hot: $(for n in "${NODES[@]}"; do printf '%s=%s ' "$n" "$(qt "$n" "select coalesce(sum(v),0) from par_hot")"; done)"
check "P4 sum(v) is the acknowledged increments" "$P4_ACKED" "$(qt "${VOTERS[0]}" "select coalesce(sum(v), 0) from par_hot")"
par_counts; A4=$PA; R4=$PR; F4=$PF
echo "     P4: $((A4 - A3)) subterm(s) in parallel, $((R4 - R3)) of them again in order"

# ── no divergence logged ────────────────────────────────────────────────────
div=""
for n in "${NODES[@]}"; do
	c="$(rh "docker logs --since $T0 $n 2>&1 | grep -c 'CLUSTER DIVERGENCE'" 2>/dev/null)"
	[ "${c:-0}" = 0 ] || div+="$n=$c "
done
check "no node logged a CLUSTER DIVERGENCE" "" "${div% }"
echo "  PAR: in parallel $((A4 - A0)), again in order $((R4 - R0)), refused $((F4 - F0))"
on_exit
summary
