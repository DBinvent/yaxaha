#!/usr/bin/env bash
# [schema] A schema change rolled across the running cluster, and the schema checked
# for consistency on every node before, during and after.
#
# DDL does not travel on the replication path (rumba.md §1): a schema change is
# applied to each node in turn - followers first, the leader last (the order
# rumba's `yt_migrate()` planner queues them) - while the application keeps
# writing. For as long as the roll takes, some nodes have the new shape and some
# the old, so a rolled change has to be an EXPAND step first (a nullable column,
# a column with a default, an index - rumba.md §6), the writes leave the new
# column alone until every node has it, and the CONTRACT step (dropping what the
# application no longer reads) comes last.
#
# A member never drops a column it does not have (decided 2026-10-12: strict).
# A row written on a node that has migrated carries the new column - NULL or its
# default - so while a party member lacks it, that write FAILS: the commit needs
# the party, and the member refuses the statement. Writes to the table during a
# roll are expected to fail on migrated nodes and are paused, or retried, by the
# application (rumba.md §6). What must hold is that a failed write leaves nothing
# behind anywhere, and that nothing fails once every node has the column.
#
# "The same schema" here is what an application and `to_jsonb(t.*)` see: every
# column with its type, nullability, default and position, the constraints, and
# the indexes with their names. Triggers are not compared - the sync triggers are
# installed per node by register_table.
#
# ## What is asserted
#
# S1 before: every node has the same schema and the same rows
# S2 during the roll: writes from nodes not yet migrated commit, and replicate to
#    migrated ones; a write that fails (a migrated origin, a member without the
#    column) fails cleanly - its row is on no node - and none fails after the roll
# S3 the schema gate sees the mixed window: a migrated follower reports the table
#    as "schema differs" (yt_info('W')) and names the new column
# S4 after the roll, every node has the same schema again
# S5 ...and the gate clears everywhere: no table left held out of recon; and recon
#    never compared rows of the two shapes - a node of the other shape answers
#    "shape differs" and is left out (the leader never gates itself) - so no row
#    ends up blocked for writes
# S6 writes that DO use the new column replicate it to every node
# S7 every row committed during and after the roll is on every node, identical
# S8 a second roll - an index, a NOT NULL column with a default - and the
#    contract step (drop the first column) leave schema and rows identical too
# S9 the gate judges by SchemaGuard's rules under the cluster's `sg_migration`
#    (ytserv state/schema.rs): with the leader as the target, a follower that
#    widened a column ahead of it is a size CUT to SchemaGuard - held out by
#    default, and not with `with_size_cut`; either way the gate clears after
#    the roll
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== schema change: rolled across the running cluster, checked for consistency =="

T=sc_t
TMP="$(mktemp -d)"
trap 'touch "$TMP/stop"; rm -rf "$TMP"' EXIT

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done
NV=${#VOTERS[@]}

qx() { # qx <node> <sql> [statement_timeout] -> psql's output WITH its errors
	local node="$1" sql="$2" to="${3:-60s}"
	printf '%s\n' "$sql" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=$to' $node \
psql -X -tAq -v ON_ERROR_STOP=1 -d $YX_DB 2>&1" 2>&1 || true
}
err_of() {
	printf '%s\n' "$1" | { grep -m1 -E 'ERROR:|FATAL:|PANIC:|psql: error|server closed the connection|connection to server|No such container|is not running' || true; }
}
cw() { # cw <node> <statements> [timeout] -> "" when the cluster write committed, else the error
	err_of "$(qx "$1" "begin; $2; select yt_complete(true); commit;" "${3:-60s}")"
}
ddl() { # ddl <node> <statement>: the node's own DDL, never replicated - fails the case on error
	local e
	e="$(err_of "$(qx "$1" "$2")")"
	[ -z "$e" ] || bad "DDL on $1 failed: $2 -> $e"
}

# the schema as one digest, and as text for the report
SCHEMA_SQL="select coalesce((select string_agg(format('%s:%s %s null=%s default=%s', ordinal_position,
            column_name, data_type, is_nullable, coalesce(column_default, '-')), ', ' order by ordinal_position)
          from information_schema.columns where table_schema='public' and table_name='$T'), '')
  || ' | ' || coalesce((select string_agg(pg_get_constraintdef(oid), '; ' order by pg_get_constraintdef(oid))
          from pg_constraint where conrelid='public.$T'::regclass), '')
  || ' | ' || coalesce((select string_agg(indexdef, '; ' order by indexdef)
          from pg_indexes where schemaname='public' and tablename='$T'), '')"
schema_of() { q "$1" "$SCHEMA_SQL"; }

# differing <sql>: nodes whose answer differs from the leader's, as `node=answer`
differing() {
	local ref n v out=""
	ref="$(q "$L" "$1")"
	for n in "${NODES[@]}"; do
		v="$(q "$n" "$1")"
		[ "$v" = "$ref" ] || out="$out $n=${v:-<none>}"
	done
	echo "${out# }"
}
# same_schema <case>: every node's schema equals the leader's
same_schema() {
	local d
	d="$(differing "select md5(($SCHEMA_SQL))")"
	if [ -z "$d" ]; then ok "$1: every node has the same schema"
	else
		bad "$1: the schema differs from the leader's on: $d"
		echo "     leader $L: $(schema_of "$L")"
		for n in "${NODES[@]}"; do [ "$n" = "$L" ] || echo "     $n: $(schema_of "$n")"; done
	fi
}
# same_rows <case> <digest sql> <min rows>: every node holds the leader's rows -
# waited for, since an apply lands a moment after the commit; never on empty tables
same_rows() {
	local desc="$1" sql="$2" min="$3" d="" c
	c="$(q "$L" "select count(*) from $T where id > 0")"
	if [ "${c:-0}" -lt "$min" ]; then bad "$desc: refusing to compare - the leader has ${c:-0} row(s), need >= $min"; return; fi
	for _ in $(seq 1 30); do
		d="$(differing "$sql")"
		[ -z "$d" ] && break
		sleep 2
	done
	[ -z "$d" ] && ok "$desc: every node holds the same $c row(s)" \
		|| bad "$desc: rows differ from the leader's ($c rows) on: $(differing "select count(*) from $T where id > 0")"
}
gate_of() { # the schema gate's report for the table on <node>, empty when not blocked
	local w
	w="$(info "$1" W "public.$T")"
	[ -n "$w" ] || w="$(info "$1" W "$YX_DB.public.$T")"
	echo "$w"
}
recon_of() { info "$1" E recon | { grep -oE '[0-9]+ divergent, [0-9]+ repaired, [0-9]+ critical, [0-9]+ blocked' || true; }; }

# a writer from every voter in turn, recording what committed: plain columns only
writer() {
	local i="$1" k=0 n e
	while [ ! -f "$TMP/stop" ]; do
		n="${VOTERS[$((k % NV))]}"; k=$((k + 1)); i=$((i + 1))
		e="$(cw "$n" "insert into $T (id, v) values ($i, 'w$i@$n')" 30s)"
		if [ -z "$e" ]; then echo "$i" >> "$TMP/ok"; else echo "$i $(date +%s) $n: $e" >> "$TMP/err"; fi
	done
}
writer_stop() {
	touch "$TMP/stop"; wait "$WPID" 2>/dev/null || true; rm -f "$TMP/stop"
	WOK=$(cat "$TMP/ok" 2>/dev/null | wc -l); WERR=$(cat "$TMP/err" 2>/dev/null | wc -l)
}
# failed_cleanly <case> <roll end, epoch s>: the writes that failed left no row on any
# node, and none failed after the roll ended (one write's timeout of slack)
failed_cleanly() {
	local desc="$1" end="$2" ids late d
	if [ "$WERR" -eq 0 ]; then ok "$desc: no write failed during the roll"; return; fi
	ids="$(cut -d' ' -f1 "$TMP/err" | paste -sd,)"
	for _ in $(seq 1 10); do
		d="$(differing "select count(*) from $T where id in ($ids)")"
		[ -z "$d" ] && break; sleep 2
	done
	[ -z "$d" ] && [ "$(q "$L" "select count(*) from $T where id in ($ids)")" = 0 ] \
		&& ok "$desc: the $WERR write(s) that failed during the roll left no row on any node" \
		|| bad "$desc: a failed write left a row behind: leader $(q "$L" "select count(*) from $T where id in ($ids)"), differing: ${d:-none}"
	late="$(awk -v e="$((end + 30))" '$2 > e' "$TMP/err" | wc -l)"
	[ "$late" -eq 0 ] && ok "$desc: no write failed after the roll ended" \
		|| { bad "$desc: $late write(s) failed after every node had the change"; awk -v e="$((end + 30))" '$2 > e' "$TMP/err" | head -3 | sed 's/^/     /'; }
}

# ── setup ────────────────────────────────────────────────────────────────────
CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'recon=repair; recon_rows=1' | tail -1)"
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists $T; create table $T (id bigint primary key, v text, code varchar(20));" >/dev/null
done
register_table "public.$T" "$CFG"
restart_all
await_cluster
wait_writable "${VOTERS[0]}" "${VOTERS[1]}" "$T" || { bad "the cluster never became writable"; summary; }

L=""
for n in "${NODES[@]}"; do case "$(info "$n" O cluster)" in *Leader) L="$n";; esac; done
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }
ROLL=()
for n in "${NODES[@]}"; do [ "$n" = "$L" ] || ROLL+=("$n"); done
ROLL+=("$L")
echo "  roll order (followers first, the leader last): ${ROLL[*]}"

# ── S1 before ────────────────────────────────────────────────────────────────
for i in $(seq 1 12); do
	e="$(cw "${VOTERS[$((i % NV))]}" "insert into $T (id, v) values ($i, 'seed-$i')")"
	[ -z "$e" ] || bad "seed row $i from ${VOTERS[$((i % NV))]}: $e"
done
same_schema "S1 before the change"
same_rows "S1 before the change" "select md5(string_agg(format('%s|%s', id, v), ',' order by id)) from $T where id > 0" 12

declare -A REC0
for n in "${NODES[@]}"; do REC0[$n]="$(recon_of "$n")"; done

# ── S2/S3 the expand roll, under writes ──────────────────────────────────────
: > "$TMP/ok"; : > "$TMP/err"
writer 1000 & WPID=$!
sleep 4
FIRST="${ROLL[0]}"
for n in "${ROLL[@]}"; do
	echo "  $(date -u +%T) $n: alter table $T add column note text"
	ddl "$n" "alter table $T add column note text"
	if [ "$n" = "$FIRST" ]; then
		# the mixed window, seen by the gate on the node that has moved ahead of
		# the leader (the leader itself is the reference and never reports)
		sleep 6
		g="$(gate_of "$n")"
		case "$g" in
			*"schema differs"*) ok "S3 during the roll: $n reports $T as schema-blocked" ;;
			"") bad "S3 during the roll: $n, migrated ahead of the leader, does not report $T - the gate missed the mixed window" ;;
			*) bad "S3 during the roll: $T is listed on $n, but not as a schema difference: $g" ;;
		esac
		case "$g" in
			*note*) ok "S3 ...and names the new column (note)" ;;
			*) bad "S3 the gate's report does not name the new column: ${g:-<none>}" ;;
		esac
	fi
	sleep 3
done
ROLL_END=$(date +%s)
sleep 4
writer_stop
echo "  writer during the roll: $WOK committed, $WERR failed"
[ "$WOK" -gt 0 ] && ok "S2 writes kept committing during the roll ($WOK of $((WOK + WERR)) from $NV origins)" \
	|| bad "S2 no write committed during the roll"
failed_cleanly "S2" "$ROLL_END"

# ── S4/S5 after the roll ─────────────────────────────────────────────────────
same_schema "S4 after the roll"
cleared=""
for _ in $(seq 1 30); do
	still=""
	for n in "${NODES[@]}"; do [ -z "$(gate_of "$n")" ] || still="$still $n"; done
	[ -z "$still" ] && { cleared=1; break; }
	sleep 2
done
[ -n "$cleared" ] && ok "S5 the schema gate cleared on every node once the leader had the column" \
	|| bad "S5 $T is still held out of recon after the roll on:$still - $(gate_of "${still# }" | head -c 160)"
left_out=0
for n in "${NODES[@]}"; do
	c="$(rh "docker logs --since 4m $n 2>&1 | { grep -a '$T has another shape\|$T [^ ]* has another shape' | grep -c . || true; }" | tail -1)"
	left_out=$((left_out + ${c:-0}))
done
[ "$left_out" -gt 0 ] && ok "S5 recon left a node of the other shape out of its comparison ($left_out time(s) during the roll)" \
	|| bad "S5 no recon round left a node of the other shape out - rows of two shapes were compared, or no round ran"

# ── S6 the new column, written once every node has it ───────────────────────
for i in $(seq 1 $NV); do
	n="${VOTERS[$((i - 1))]}"
	e="$(cw "$n" "insert into $T (id, v, note) values ($((2000 + i)), 'new-$i', 'note from $n');
	              update $T set note = 'updated on $n' where id = $i")"
	[ -z "$e" ] || bad "S6 a write using the new column from $n: $e"
done
NOTED=$((2 * NV))
for _ in $(seq 1 30); do
	d="$(differing "select count(*) from $T where note is not null")"
	[ -z "$d" ] && break; sleep 2
done
check "S6 the leader holds the $NOTED rows written with the new column" "$NOTED" \
	"$(q "$L" "select count(*) from $T where note is not null")"
[ -z "$d" ] && ok "S6 every node holds the new column's values" \
	|| bad "S6 the new column's values did not reach: $d"

# ── S7 every row, everywhere ────────────────────────────────────────────────
same_rows "S7 after the roll" "select md5(string_agg(format('%s|%s|%s', id, v, note), ',' order by id)) from $T where id > 0" \
	$((12 + WOK + NV))
if [ "$WOK" -gt 0 ]; then
	ids="$(paste -sd, "$TMP/ok")"
	d="$(differing "select count(*) from $T where id in ($ids)")"
	[ -z "$d" ] && ok "S7 all $WOK rows committed during the roll are on every node" \
		|| bad "S7 rows committed during the roll are missing on: $d (of $WOK)"
fi

blocked_on=""
for n in "${NODES[@]}"; do
	r="$(recon_of "$n")"
	echo "     recon $n: before [${REC0[$n]}] after [$r]"
	case "$r" in *" 0 blocked"|"") ;; *) blocked_on="$blocked_on $n(${r##*critical, })" ;; esac
done
[ -z "$blocked_on" ] && ok "S7 recon blocked no row for writes across the roll" \
	|| bad "S7 recon blocked rows for writes on:$blocked_on"

# ── S8 a second roll, then the contract step ────────────────────────────────
: > "$TMP/ok"; : > "$TMP/err"
writer 3000 & WPID=$!
for n in "${ROLL[@]}"; do
	ddl "$n" "create index ${T}_note_idx on $T (note)"
	ddl "$n" "alter table $T add column qty int not null default 0"
	sleep 2
done
ROLL_END=$(date +%s)
writer_stop
[ "$WOK" -gt 0 ] && ok "S8 writes kept committing during the second roll ($WOK of $((WOK + WERR)))" \
	|| bad "S8 no write committed during the second roll"
failed_cleanly "S8" "$ROLL_END"
same_schema "S8 after an index and a NOT NULL column with a default"
for i in $(seq 1 $NV); do
	e="$(cw "${VOTERS[$((i - 1))]}" "update $T set qty = qty + $i where id <= 12")"
	[ -z "$e" ] || bad "S8 a write using qty from ${VOTERS[$((i - 1))]}: $e"
done
same_rows "S8 with qty" "select md5(string_agg(format('%s|%s|%s|%s', id, v, note, qty), ',' order by id)) from $T where id > 0" 12

# contract: the application stopped reading `note`; drop it everywhere (and its index with it)
for n in "${ROLL[@]}"; do ddl "$n" "alter table $T drop column note"; done
same_schema "S8 after the contract step (note dropped)"
# A table that has had a column dropped keeps it in its descriptor (attisdropped,
# "........pg.dropped.N........"). The trigger used to send it, and every member's
# INSERT named it and failed with a syntax error - on every node, for good (fixed
# in yaxaha.c, deb 1.18.84). UPDATE and DELETE send only changed and key columns;
# all three are asserted, each from another origin.
e="$(cw "${VOTERS[0]}" "insert into $T (id, v, qty) values (4000, 'after-contract', 7)")"
[ -z "$e" ] && ok "S8 an INSERT after the drop commits (from ${VOTERS[0]})" \
	|| bad "S8 an INSERT after the drop: $e"
e="$(cw "${VOTERS[1]}" "update $T set v = 'updated-after-contract', qty = qty + 100 where id = 1")"
[ -z "$e" ] && ok "S8 an UPDATE after the drop commits (from ${VOTERS[1]})" \
	|| bad "S8 an UPDATE after the drop: $e"
e="$(cw "${VOTERS[2]}" "delete from $T where id = 2")"
[ -z "$e" ] && ok "S8 a DELETE after the drop commits (from ${VOTERS[2]})" \
	|| bad "S8 a DELETE after the drop: $e"
check "S8 the leader holds all three" "1|updated-after-contract|0" \
	"$(q "$L" "select (select count(*) from $T where id = 4000) || '|' || (select v from $T where id = 1) || '|' || (select count(*) from $T where id = 2)")"
same_rows "S8 after the contract step" "select md5(string_agg(format('%s|%s|%s', id, v, qty), ',' order by id)) from $T where id > 0" 12

# ── S9 the gate by SchemaGuard's rules ──────────────────────────────────────
# roll_type <case> <type> <expect: blocked|clear>: widen `code` followers first,
# the leader last, and read the gate on the first follower before the leader moves
roll_type() {
	local desc="$1" ty="$2" want="$3" g still
	for n in "${ROLL[@]}"; do
		ddl "$n" "alter table $T alter column code type $ty"
		if [ "$n" = "$FIRST" ]; then
			sleep 6
			g="$(gate_of "$n")"
			case "$want:$g" in
				blocked:*code*) ok "$desc: $n, wider than the leader, is held out - a size cut to SchemaGuard" ;;
				blocked:*) bad "$desc: $n should be held out (SchemaGuard would cut code back), the gate says: ${g:-<nothing>}" ;;
				clear:) ok "$desc: $n, wider than the leader, is NOT held out - SchemaGuard would amend it" ;;
				clear:*) bad "$desc: $n is held out although SchemaGuard would amend code: $g" ;;
			esac
		fi
		sleep 2
	done
	same_schema "$desc after the roll"
	for _ in $(seq 1 30); do
		still=""
		for n in "${NODES[@]}"; do [ -z "$(gate_of "$n")" ] || still="$still $n"; done
		[ -z "$still" ] && break; sleep 2
	done
	[ -z "$still" ] && ok "$desc: the gate is clear everywhere after the roll" \
		|| bad "$desc: still held out after the roll on:$still"
}
roll_type "S9a defaults (no sg_migration)" "varchar(100)" blocked

# the cluster's SchemaGuard options: a C row written through the cluster, on the leader
e="$(cw "$L" "delete from $YX_CFG where module='C' and name='sg_migration';
              insert into $YX_CFG (name, module, value) values ('sg_migration', 'C', 'with_size_cut')")"
[ -z "$e" ] || bad "S9 writing C sg_migration on $L: $e"
seen=""
for _ in $(seq 1 30); do
	seen=""
	for n in "${NODES[@]}"; do [ "$(info "$n" E cfg.sg_migration)" = "with_size_cut" ] || seen="$seen $n"; done
	[ -z "$seen" ] && break; sleep 2
done
[ -z "$seen" ] && ok "S9 every node runs sg_migration=with_size_cut" \
	|| bad "S9 sg_migration did not reach the live config on:$seen"
roll_type "S9b sg_migration=with_size_cut" "varchar(200)" clear
e="$(cw "$L" "delete from $YX_CFG where module='C' and name='sg_migration'")"
[ -z "$e" ] || bad "S9 removing C sg_migration on $L: $e"

summary
