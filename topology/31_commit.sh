#!/usr/bin/env bash
# [commit] The commit path of a cluster write, end to end: what the client is
# told, what every node holds afterwards, and what is left open behind it.
#
#   C2   explicit yt_complete(true), then COMMIT: on every node, and the client
#        was told "committed" exactly when the row exists
#   C7   the auto_complete path (GUC yaxaha.auto_complete, ytpgc yaxaha.c):
#        a bare COMMIT and an autocommit INSERT replicate, a ROLLBACK leaves nothing
#   C8   yt_complete(false), then ROLLBACK: nothing anywhere
#   C13  an UPDATE of the primary key and a DELETE land the same on every node;
#        a TRUNCATE is either replicated or refused - never silently local-only
#   C3   a two-statement transaction whose second statement fails: nothing
#        anywhere, no party session left open, the key writable again
#   C1   a member VETOES: a constraint that exists on ONE node only fails the
#        write there - at PREPARE (a deferred unique constraint) and at the
#        statement (a CHECK). The client gets an error, no node has the row, and
#        nothing is left prepared or idle in transaction (0.20.54 / 0.20.55 fixes,
#        yt-pgxt topo-jobs.md "Found while building phase 5")
#   X1   [xa] a client's own two-phase commit (yt-pgxt ytpgc/README.md, 2026-10-16):
#        PREPARE TRANSACTION of a cluster-synced insert, COMMIT PREPARED from
#        another session - on every node; X2 ROLLBACK PREPARED - nowhere; X3 a
#        prepared transaction with no cluster side commits as before (written
#        2026-10-16, first run the next nightly)
#   C9   one transaction of 500 rows
#
# ## C9 and C13 - known gaps until ytserv 0.20.61
#
# C9: a cluster transaction of hundreds of rows outlasted its call's timeout.
# The tx timeout was added once more per statement (2^(n-1) s at n rows, a u32
# that wrapped to 0 at the 33rd), and the calls that carry the whole tx -
# PREPARE, COMMIT, the apply - got a one-statement timeout. Since 0.20.61 the
# aggregate is taken once, with a second per 50 rows ([tx-timeout],
# cluster.rs). C9 runs LAST: if it regresses, its fallout (a refused
# transaction that already took a subterm) is not what the other checks are
# about.
#
# C13: the sync trigger is `FOR EACH ROW` on insert/update/delete, so a
# TRUNCATE emptied the origin alone and the client was told it worked. Since
# 0.20.61 yt_setup (and env.sh register_table) also installs a statement-level
# TRUNCATE trigger: the TRUNCATE replicates as a DELETE, or is refused and rolls
# back. Either is acceptable; local-only is not.
#
# ## Why C1 has its own table, with cluster_commit=all
#
# A veto is only a veto if the node that refuses is IN the party. Under the
# cluster default (`half`) the party is drawn per write, so a constraint on one
# node would be in the party on some runs and receive the row later by the
# fan-out on others - a coin flip between "veto" and "divergence". `all` puts
# every participant in every party, so the refusing node is always asked. The
# other cases run on a table with the default config, which is what clients use.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== commit: what the client is told, what every node holds, what is left open =="

# ── helpers (local: env.sh's q discards stderr, and these need the error) ────

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done

# qx <node> <sql> [statement_timeout] -> psql's output WITH its errors.
# ON_ERROR_STOP, so the first failing statement ends the session and the
# transaction with it - the way a client that checks errors behaves. Verbose,
# so an error line carries its SQLSTATE in a fixed place (see sqlstate_of).
qx() {
	local node="$1" sql="$2" to="${3:-60s}"
	printf '%s\n' "$sql" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=$to' $node \
psql -X -tAq -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d $YX_DB 2>&1" 2>&1 || true
}
# err_of <output> -> the first error line, or nothing when every statement succeeded
err_of() {
	printf '%s\n' "$1" | { grep -m1 -E 'ERROR:|FATAL:|PANIC:|psql: error|server closed the connection|connection to server|No such container|Error response from daemon|is not running' || true; }
}
# sqlstate_of <output> -> the SQLSTATE field of the first error (VERBOSITY=verbose)
sqlstate_of() {
	printf '%s\n' "$1" | { grep -m1 'ERROR:' || true; } | sed -n 's/^.*ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p'
}
# cw <node> <statements> [timeout] -> "" when the cluster write committed, else the error
cw() {
	local o
	o="$(qx "$1" "begin; $2; select yt_complete(true); commit;" "${3:-60s}")"
	err_of "$o"
}
# qt: env.sh's q plus a statement_timeout, so a wedged ytserv cannot hang a poll
qt() {
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}
# yinfo <node> <letters> <name> -> one yt_info value, over qt
yinfo() {
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
# lacking <table> <where> <want> -> the nodes whose count(*) differs from <want>,
# as node=count ("?" when the node did not answer - never read as a match)
lacking() {
	local n c out=""
	for n in "${NODES[@]}"; do
		c="$(qt "$n" "select count(*) from $1 where $2")"
		[ "$c" = "$3" ] || out+="$n=${c:-?} "
	done
	printf '%s' "${out% }"
}
# wait_all <secs> <table> <where> <want> -> 0 once every node agrees
wait_all() {
	local deadline=$((SECONDS + $1))
	while :; do
		[ -z "$(lacking "$2" "$3" "$4")" ] && return 0
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 2
	done
}
prepared_on() {
	local n c out=""
	for n in "${NODES[@]}"; do
		c="$(qt "$n" "select count(*) from pg_prepared_xacts where database = current_database()")"
		[ "$c" = "0" ] || out+="$n=${c:-?} "
	done
	printf '%s' "${out% }"
}
# Sessions left `idle in transaction` - the shape a party member's open
# transaction takes when nobody tells it the origin gave up. Every one is
# printed on failure, so a red line names the statement that was left open.
idle_tx_on() {
	local n c out=""
	for n in "${NODES[@]}"; do
		c="$(qt "$n" "select count(*) from pg_stat_activity
		              where datname = current_database() and pid <> pg_backend_pid()
		                and state like 'idle in transaction%'")"
		[ "$c" = "0" ] || out+="$n=${c:-?} "
	done
	printf '%s' "${out% }"
}
idle_tx_detail() {
	local n
	for n in "${NODES[@]}"; do
		qt "$n" "select '$n pid '||pid||' '||state||' for '||round(extract(epoch from now()-state_change))||'s: '
		                ||left(regexp_replace(query, '\s+', ' ', 'g'), 90)
		         from pg_stat_activity
		         where datname = current_database() and pid <> pg_backend_pid()
		           and state like 'idle in transaction%'" | sed 's/^/     /'
	done
}
leaks_check() { # leaks_check <label> - the two "nothing left open" assertions
	local p i
	p="$(prepared_on)"; i="$(idle_tx_on)"
	check "$1: no prepared transaction on any node" "" "$p"
	check "$1: no idle-in-transaction session on any node" "" "$i"
	[ -z "$i" ] || idle_tx_detail
}
settle() { # a section's fallout must not be the next section's failure
	wait_writable "$O" "$W" cm_t >/dev/null 2>&1 \
		|| bad "the cluster did not become writable again after $1"
}

CLEANED=0
cleanup() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set +e
	for n in "${NODES[@]}"; do
		q "$n" "drop table if exists cm_t; drop table if exists cm_v;" >/dev/null 2>&1
		cfg_delete "$n" public.cm_t A >/dev/null 2>&1
		cfg_delete "$n" public.cm_v A >/dev/null 2>&1
	done
	echo "  cleanup: cm_t and cm_v dropped, their module-A rows removed"
}

# ── setup ────────────────────────────────────────────────────────────────────

[ "${#VOTERS[@]}" -ge 2 ] || { bad "needs two non-spare nodes, has ${#VOTERS[@]}"; summary; }
ALL_CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'cluster_commit=all' | tail -1 || true)"
[ -n "$ALL_CFG" ] || { bad "yxctl --encode-table-cfg produced nothing (is $REPO_ROOT built?)"; summary; }

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists cm_t; create table cm_t (id bigint primary key, v text);
	        drop table if exists cm_v; create table cm_v (id bigint primary key, v text);" >/dev/null
done
register_table public.cm_t
register_table public.cm_v "$ALL_CFG"
trap cleanup EXIT
restart_all
await_cluster

O="${VOTERS[0]}"   # the origin for every single-origin case
W="${VOTERS[1]}"   # a second voter: witness, veto node, second origin
wait_writable "$O" "$W" cm_t || { bad "cluster never became writable (cm_t)"; summary; }
wait_writable "$O" "$W" cm_v || { bad "cluster never became writable (cm_v)"; summary; }
echo "  leader: $(leader_now || true) - origin $O, second node $W (neither depends on it)"

# ── C2: explicit yt_complete(true), then COMMIT ──────────────────────────────
#
# One write from EVERY voter, the leader among them: the 0.20.54 defect was an
# origin-specific path (a party of one, judged by a gate that saw the whole
# cluster), and which node leads is not this test's to choose.
echo "  -- C2: explicit yt_complete(true), then COMMIT, once from each voter"
c2_ids=(); c2_org=(); c2_err=()
i=0
for o in "${VOTERS[@]}"; do
	i=$((i + 1)); id=$((200 + i))
	c2_ids+=("$id"); c2_org+=("$o")
	c2_err+=("$(cw "$o" "insert into cm_t values ($id,'c2-$o')")")
done
acked=""; nacked=0
for k in "${!c2_ids[@]}"; do
	[ -z "${c2_err[$k]}" ] && { acked+="${acked:+,}${c2_ids[$k]}"; nacked=$((nacked + 1)); }
done
[ "$nacked" -gt 0 ] && { wait_all 30 cm_t "id in ($acked)" "$nacked" || true; }
sleep 3   # a refused write that committed anyway has had time to show up
for k in "${!c2_ids[@]}"; do
	id="${c2_ids[$k]}"; o="${c2_org[$k]}"; e="${c2_err[$k]}"
	if [ -z "$e" ]; then
		miss="$(lacking cm_t "id=$id" 1)"
		[ -z "$miss" ] \
			&& ok "C2 write from $o: committed, and on all ${#NODES[@]} nodes" \
			|| bad "C2 write from $o: the client was told it COMMITTED, but it is missing on: $miss"
	else
		have="$(lacking cm_t "id=$id" 0)"
		[ -z "$have" ] \
			&& bad "C2 write from $o: refused (honestly - no node holds it): ${e:0:160}" \
			|| bad "C2 write from $o: the client was told it FAILED, yet it committed on: $have - ${e:0:120}"
	fi
done

# ── C7: auto_complete - the client never calls yt_complete ───────────────────
echo "  -- C7: auto_complete (bare COMMIT, autocommit INSERT, ROLLBACK)"
# yt_info('T') first: it loads the extension without a server call, and the GUC
# exists only once the library is loaded in this session.
ac="$(qt "$O" "select yt_info('T') is not null; select current_setting('yaxaha.auto_complete', true);" | tail -1)"
check "C7 precondition: yaxaha.auto_complete is on" "on" "$ac"

e="$(err_of "$(qx "$O" "begin; insert into cm_t values (701,'c7-bare-commit'); commit;")")"
check "C7 a bare COMMIT with no yt_complete() is accepted" "" "$e"
wait_all 30 cm_t "id=701" 1 || true
check "C7 ...and the row is on every node" "" "$(lacking cm_t "id=701" 1)"

e="$(err_of "$(qx "$O" "insert into cm_t values (702,'c7-autocommit');")")"
check "C7 an autocommit single INSERT is accepted" "" "$e"
wait_all 30 cm_t "id=702" 1 || true
check "C7 ...and the row is on every node" "" "$(lacking cm_t "id=702" 1)"

e="$(err_of "$(qx "$O" "begin; insert into cm_t values (703,'c7-rollback'); rollback;")")"
check "C7 an explicit ROLLBACK is accepted" "" "$e"
sleep 5
check "C7 ...and the rolled-back row is on no node" "" "$(lacking cm_t "id=703" 0)"

# ── C8: yt_complete(false), then ROLLBACK ────────────────────────────────────
echo "  -- C8: yt_complete(false), then ROLLBACK"
e="$(err_of "$(qx "$O" "begin; insert into cm_t values (801,'c8'); select yt_complete(false); rollback;")")"
[ -z "$e" ] || echo "     (the client saw: ${e:0:160})"
sleep 5
check "C8 yt_complete(false) + ROLLBACK leaves the row on no node" "" "$(lacking cm_t "id=801" 0)"

# ── C13: UPDATE of the key, DELETE, TRUNCATE ─────────────────────────────────
echo "  -- C13: UPDATE of a primary key, DELETE, TRUNCATE"
cw "$O" "insert into cm_t values (1301,'c13-moves')" >/dev/null
cw "$O" "insert into cm_t values (1302,'c13-goes')" >/dev/null
wait_all 30 cm_t "id in (1301,1302)" 2 || true
check "C13 setup: both rows on every node" "" "$(lacking cm_t "id in (1301,1302)" 2)"

# The key the replicated UPDATE must FIND is the old one. An apply that builds
# its WHERE from the new image matches nothing on a peer and the row stays put.
e="$(cw "$O" "update cm_t set id = 1391 where id = 1301")"
check "C13 UPDATE of the primary key (1301 -> 1391) committed" "" "$e"
wait_all 30 cm_t "id=1391" 1 || true
wait_all 10 cm_t "id=1301" 0 || true
check "C13 ...every node holds the row under its new key" "" "$(lacking cm_t "id=1391" 1)"
check "C13 ...and no node still holds the old key" "" "$(lacking cm_t "id=1301" 0)"

e="$(cw "$O" "delete from cm_t where id = 1302")"
check "C13 DELETE committed" "" "$e"
wait_all 30 cm_t "id=1302" 0 || true
check "C13 ...and the row is gone from every node" "" "$(lacking cm_t "id=1302" 0)"

# TRUNCATE (predicted to fail today - see the header). An autocommit statement,
# the way a client issues it; auto_complete is what would carry it.
before="$(qt "$O" "select count(*) from cm_t")"
out="$(qx "$O" "truncate cm_t;")"
e="$(err_of "$out")"; code="$(sqlstate_of "$out")"
if [ -z "$e" ]; then
	if wait_all 30 cm_t "true" 0; then
		ok "C13 TRUNCATE replicated: every node is empty"
	else
		bad "C13 TRUNCATE was silently LOCAL-ONLY: $O was told it worked (it had $before rows), \
but these nodes still hold rows: $(lacking cm_t "true" 0)"
	fi
else
	case "$code" in
		55P03|57014)
			bad "C13 TRUNCATE could not take its lock - something still holds cm_t open: ${e:0:160}" ;;
		*)
			after="$(qt "$O" "select count(*) from cm_t")"
			[ "$after" = "$before" ] \
				&& ok "C13 TRUNCATE is refused with an error, and nothing was truncated: ${e:0:120}" \
				|| bad "C13 TRUNCATE was refused, yet $O went from $before to $after rows: ${e:0:120}" ;;
	esac
fi
settle "C13"

# ── C3: a failing second statement ───────────────────────────────────────────
#
# The FIRST statement reached the party - its row is open on every member. The
# second fails on the origin (duplicate key), which aborts the client's
# transaction; the party must be told, or it holds the first row's lock for good
# and every later write of that key waits on it (0.20.55).
echo "  -- C3: a two-statement transaction whose second statement fails"
cw "$O" "insert into cm_t values (3000,'c3-existing')" >/dev/null
wait_all 30 cm_t "id=3000" 1 || true
check "C3 setup: key 3000 exists on every node" "" "$(lacking cm_t "id=3000" 1)"

out="$(qx "$O" "begin;
	insert into cm_t values (3001,'c3-first');
	insert into cm_t values (3000,'c3-duplicate');
	select yt_complete(true); commit;")"
check "C3 the second statement fails with a duplicate key (23505)" "23505" "$(sqlstate_of "$out")"
sleep 5
check "C3 the first statement's row is on no node" "" "$(lacking cm_t "id=3001" 0)"
i="$(idle_tx_on)"
check "C3 no idle-in-transaction session on any node after 5 s" "" "$i"
[ -z "$i" ] || idle_tx_detail

# "Within 10 s" is counted from the end of the 5-second checks above. From a
# DIFFERENT origin: its party includes the members that held the first row, so a
# lock still held there is exactly what blocks it. An upsert, so a refused
# attempt that committed somewhere cannot turn the retry into a duplicate key.
deadline=$((SECONDS + 10)); tries=0; e="never tried"
while [ "$SECONDS" -lt "$deadline" ]; do
	tries=$((tries + 1))
	e="$(cw "$W" "insert into cm_t values (3001,'c3-again')
	              on conflict (id) do update set v = excluded.v" 8s)"
	[ -z "$e" ] && break
	sleep 1
done
check "C3 key 3001 is writable again within 10 s (from $W, $tries attempt(s))" "" "${e:0:200}"
wait_all 30 cm_t "id=3001 and v='c3-again'" 1 || true
check "C3 ...and the rewrite is on every node" "" "$(lacking cm_t "id=3001 and v='c3-again'" 1)"
settle "C3"

# ── C1: a member vetoes ──────────────────────────────────────────────────────
echo "  -- C1: a constraint on ONE member ($W) vetoes the write from $O"
cw "$O" "insert into cm_v values (1,'taken')" >/dev/null
wait_all 30 cm_v "id=1" 1 || true
check "C1 setup: the seed row is on every node, $W included" "" "$(lacking cm_v "id=1" 1)"

# On $W alone, with the sync trigger untouched - DDL fires no row trigger, so the
# cluster never hears of these. The unique constraint is DEFERRED, so it is
# checked when $W runs PREPARE TRANSACTION, not when the row is applied: that is
# a prepare veto. The CHECK fails the statement on $W as it is applied.
qt "$W" "alter table cm_v add constraint cm_v_veto_u unique (v) deferrable initially deferred;
         alter table cm_v add constraint cm_v_veto_c check (v <> 'forbidden');" >/dev/null
check "C1 setup: the two constraints exist on $W and not on $O" "2 0" \
	"$(qt "$W" "select count(*) from pg_constraint where conrelid='cm_v'::regclass and conname like 'cm_v_veto_%'") \
$(qt "$O" "select count(*) from pg_constraint where conrelid='cm_v'::regclass and conname like 'cm_v_veto_%'")"

veto_case() { # veto_case <label> <id> <sql>
	local label="$1" id="$2" sql="$3" e
	e="$(err_of "$(qx "$O" "$sql")")"
	[ -n "$e" ] \
		&& ok "C1 $label: the client gets an error (${e:0:120})" \
		|| bad "C1 $label: the client was told it COMMITTED over a member's veto"
	sleep 5
	check "C1 $label: the row is on no node" "" "$(lacking cm_v "id=$id" 0)"
	leaks_check "C1 $label"
}
veto_case "prepare veto, explicit yt_complete(true)" 11 \
	"begin; insert into cm_v values (11,'taken'); select yt_complete(true); commit;"
settle "the first veto"
veto_case "prepare veto, bare COMMIT (auto_complete)" 12 \
	"begin; insert into cm_v values (12,'taken'); commit;"
settle "the second veto"
veto_case "statement veto (CHECK)" 13 \
	"begin; insert into cm_v values (13,'forbidden'); select yt_complete(true); commit;"
settle "the third veto"

# Everything above together: whatever path a case took, nothing may be left open.
leaks_check "before C9, after every case above"

# ...and the cluster writable again before the big one. A vetoed write above took
# a subterm, and until every node has settled it the outdated gate refuses writes
# with "behind on this node - catching up, retry" - correct and retryable, but C9
# is about a transaction of 500 rows, not about that gap (seen 2026-10-10, ytserv
# 0.20.69: C9 refused once right after the vetoes, green in the runs before).
wait_writable "$O" "$W" cm_t -9000 || true

# ── X1-X3: a client's own two-phase commit ──────────────────────────────────
xa_cleanup() { q "$O" "rollback prepared 'yt_test_xa1'; " >/dev/null 2>&1; q "$O" "rollback prepared 'yt_test_xa2';" >/dev/null 2>&1;
	q "$O" "rollback prepared 'yt_test_xa3';" >/dev/null 2>&1; true; }
xa_cleanup
out="$(q "$O" "begin; insert into cm_t values (91001, 'xa'); prepare transaction 'yt_test_xa1';" 2>&1)"
case "$out" in *ERROR*) bad "X1 PREPARE TRANSACTION of a cluster-synced insert refused: $out" ;;
	*) ok "X1 PREPARE TRANSACTION of a cluster-synced insert: the cluster side prepared with it" ;; esac
out="$(q "$O" "commit prepared 'yt_test_xa1';" 2>&1)"
case "$out" in *ERROR*) bad "X1 COMMIT PREPARED (another session) refused: $out" ;;
	*) ok "X1 COMMIT PREPARED from another session" ;; esac
wait_all 30 cm_t "id = 91001" 1 && ok "X1 the prepared insert is on every node" \
	|| bad "X1 the prepared insert is missing: $(lacking cm_t "id = 91001" 1)"
q "$O" "begin; insert into cm_t values (91002, 'xa'); prepare transaction 'yt_test_xa2';" >/dev/null 2>&1
out="$(q "$O" "rollback prepared 'yt_test_xa2';" 2>&1)"
case "$out" in *ERROR*) bad "X2 ROLLBACK PREPARED refused: $out" ;; *) ok "X2 ROLLBACK PREPARED" ;; esac
sleep 5
check "X2 the rolled-back insert is on no node" "" "$(lacking cm_t "id = 91002" 0)"
# a transaction that synced nothing: no cluster side, its gid unknown to ytserv
q "$O" "drop table if exists cm_local; create table cm_local (id int primary key);" >/dev/null 2>&1
q "$O" "begin; insert into cm_local values (1); prepare transaction 'yt_test_xa3';" >/dev/null 2>&1
out="$(q "$O" "commit prepared 'yt_test_xa3';" 2>&1)"
case "$out" in *ERROR*) bad "X3 a prepared transaction with no cluster side did not commit: $out" ;;
	*) check "X3 a prepared transaction with no cluster side commits as before" "1" "$(q "$O" "select count(*) from cm_local")" ;; esac
check "X1-X3 nothing is left prepared under a test gid" "0" \
	"$(q "$O" "select count(*) from pg_prepared_xacts where gid like 'yt_test_xa%'")"
q "$O" "drop table if exists cm_local;" >/dev/null 2>&1
xa_cleanup

# ── C9: 500 rows in one transaction ──────────────────────────────
#
# Retried on 40001, as a driver would; anything else fails at once. Until
# ytserv 0.20.76 the leader's outdated gate counted every subterm still in
# flight as a gap, so a poll inside this transaction refused its next row with
# 40001 by its own subterm - and every retry the same way (12 of 12 on
# 2026-10-11; the nightly that morning, with no retry, failed on the first).
echo "  -- C9: one transaction of 500 rows (INSERT ... SELECT generate_series)"
for c9try in $(seq 1 12); do
	out="$(qx "$O" "begin;
		insert into cm_t select g, 'c9-'||g from generate_series(100001, 100500) g;
		select yt_complete(true); commit;" 180s)"
	e="$(err_of "$out")"
	case "$e" in *"40001:"*) e1="${e1:-$e}"; sleep 5 ;; *) break ;; esac
done
[ "$c9try" -gt 1 ] && echo "  C9: $((c9try - 1)) retr(ies) on 40001 - ${e1:0:120}"
check "C9 a 500-row transaction commits" "" "${e:0:200}"
if [ -z "$e" ]; then
	wait_all 60 cm_t "id between 100001 and 100500" 500 || true
	check "C9 every node holds all 500 rows within 60 s" "" \
		"$(lacking cm_t "id between 100001 and 100500" 500)"
else
	# Refused, so it must be refused WHOLE: a partial copy anywhere is worse than
	# the gap itself.
	sleep 5
	check "C9 the refused transaction left no partial copy on any node" "" \
		"$(lacking cm_t "id between 100001 and 100500" 0)"
fi

# ── leave the cluster writable for the next script ──────────────────────────
#
# Not an assertion: C9's fallout is the known gap, already counted. A restart is
# what every next script begins with anyway; doing it here only when needed keeps
# a wedge from costing the next script its first two minutes.
if ! wait_writable "$O" "$W" cm_t >/dev/null 2>&1; then
	echo "  NOTE: not writable after C9 - restarting the cluster"
	restart_all
	await_cluster
fi
cleanup
summary
