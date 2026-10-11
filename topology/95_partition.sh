#!/usr/bin/env bash
# [mpp] yt_info('p:<table>[/<n>]'): the partition layout a query planner slices by.
#
# The one invariant that matters: EXECUTING every partition's predicate must
# return each row exactly once. A planner that loses rows to a gap, or
# double-counts them through an overlap, produces a wrong answer that looks like
# a right one - which is the failure mode df-todo.md §0.4 calls the worst an
# analytics layer can have. So this test does not inspect the JSON and trust it;
# it runs the predicates and counts.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== partition: the layout tiles the table exactly once =="

ROWS=50
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists pt_t; create table pt_t (id bigint primary key, v text);" >/dev/null
	# the keyless table for the refusal case, registered in the SAME pass: a
	# module-A row is read by the startup loader, so anything registered after
	# the restart below is not in CONFIG and would be refused as "not
	# configured" - testing the wrong branch and passing while doing it
	q "$n" "drop table if exists pt_nokey; create table pt_nokey (a text, b text);" >/dev/null
done
# No az rule: every node holds every row. That is the case this surface is FOR -
# a partition is then a scheduling decision, not a placement fact, so any node
# may be handed any slice.
register_table public.pt_t
register_table public.pt_nokey
restart_all
await_cluster
wait_writable n1 n2 pt_t || { bad "cluster never became writable"; summary; }

echo "  seeding $ROWS rows with deliberately gappy ids..."
# Gappy on purpose. Equal-WIDTH slicing looks correct on dense ids and falls
# apart on real ones (deletes, sequence caches, per-node ranges); ntile splits by
# row count, and this is what tells the two apart.
for i in $(seq 1 $ROWS); do
	q n1 "begin; insert into pt_t values ($((i * i * 7)),'row-$i'); select yt_complete(true); commit;" >/dev/null
done
for _ in $(seq 1 12); do
	[ "$(q n2 "select count(*) from pt_t where id > 0")" = "$ROWS" ] && break
	sleep 5
done
check "the seed replicated" "$ROWS" "$(q n2 "select count(*) from pt_t where id > 0")"

# ── the layout ────────────────────────────────────────────────────────────────
# `p:` is prefix-dispatched and case sensitive, so it is NOT folded to upper case
# the way the yt_info('OTI') letters are.
#
# Parsed in python like the rest of the suite: yt_info returns a json ARRAY
# ([{name,value,module},...]), so `... as x(name,value,module)` errors with
# "a column definition list is only allowed for functions returning record".
# pfield <node> <spec> <name-suffix> -> the matching row values, one per line
pfield() {
	q "$1" "select yt_info('p:$2')" | python3 -c "
import json,sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in rows:
    if r.get('name','').endswith('$3'): print(r.get('value',''))
"
}
plan="$(pfield n1 "public.pt_t/4" ".plan")"
echo "  plan: $plan"
check "the planner is told the key column" "id" \
	"$(printf '%s' "$plan" | python3 -c 'import sys,json; print(json.load(sys.stdin)["key"])' 2>/dev/null)"
check "and the partition count it asked for" "4" \
	"$(printf '%s' "$plan" | python3 -c 'import sys,json; print(json.load(sys.stdin)["partitions"])' 2>/dev/null)"
check "and the true row count" "$ROWS" \
	"$(printf '%s' "$plan" | python3 -c 'import sys,json; print(json.load(sys.stdin)["rows"])' 2>/dev/null)"
check "and that this table is not sharded" "False" \
	"$(printf '%s' "$plan" | python3 -c 'import sys,json; print(json.load(sys.stdin)["sharded"])' 2>/dev/null)"

# ── execute the predicates ────────────────────────────────────────────────────
# Predicates contain spaces, so they are read a LINE at a time - never through
# word splitting.
mapfile -t preds < <(q n1 "select yt_info('p:public.pt_t/4')" | python3 -c "
import json,sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in rows:
    if '.part.' in r.get('name',''): print(json.loads(r['value'])['where'])
")
check "four partition predicates came back" "4" "${#preds[@]}"

total=0
for p in "${preds[@]}"; do
	c="$(q n1 "select count(*) from pt_t where $p")"
	echo "    [$p] -> ${c:-ERR}"
	total=$((total + ${c:-0}))
done
# Sum == total is gap-freedom AND overlap-freedom together: a gap makes the sum
# short, an overlap makes it long. Neither can hide the other.
check "the partitions sum to the whole table" "$ROWS" "$total"

# Belt and braces: the union counted as a SET, so a pathological overlap that
# happened to exactly balance a gap still fails here.
union=""
for p in "${preds[@]}"; do
	[ -n "$union" ] && union="$union union "
	union="$union select id from pt_t where $p"
done
check "the union of the partitions is the whole table" "$ROWS" "$(q n1 "select count(*) from ($union) u")"

# Every partition must be non-empty and roughly even - ntile's whole purpose.
# An equal-WIDTH split of these gappy ids would put almost everything in the
# last partition, and that is exactly what this catches.
mn=99999; mx=0
for p in "${preds[@]}"; do
	c="$(q n1 "select count(*) from pt_t where $p")"
	[ "${c:-0}" -lt "$mn" ] && mn="${c:-0}"
	[ "${c:-0}" -gt "$mx" ] && mx="${c:-0}"
done
if [ "$mn" -gt 0 ] && [ "$((mx - mn))" -le 1 ]; then
	ok "the split is by row count, not key width (min $mn, max $mx per partition)"
else
	bad "partitions are lopsided — min $mn, max $mx (equal-width slicing of gappy ids?)"
fi

# ── the honest-refusal cases ──────────────────────────────────────────────────
nokey="$(pfield n1 "public.pt_nokey" "error")"
case "$nokey" in
	*"no single integer primary key"*) ok "a table with no integer PK is refused, with the reason" ;;
	*) bad "expected a named refusal for a keyless table, got [$nokey]" ;;
esac
# and it must still say what CAN be done, or the refusal is a dead end
case "$nokey" in
	*hashtext*) ok "the refusal names the fallback a planner can use instead" ;;
	*) bad "the refusal gives no alternative — [$nokey]" ;;
esac

unknown="$(pfield n1 "public.not_a_table" "error")"
case "$unknown" in
	*"not configured for synchronisation"*) ok "an unsynced table is refused, with the reason" ;;
	*) bad "expected a named refusal for an unknown table, got [$unknown]" ;;
esac

summary
