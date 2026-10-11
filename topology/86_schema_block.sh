#!/usr/bin/env bash
# [blocking:table] The TABLE scope of "Blocking: Row, Table, Node".
#
# `85_alert.sh` covers the ROW scope - a row nobody can vouch for is blocked
# cluster-wide and refused with 55000. This is the coarser one the product page
# states next to it:
#
#   "A table whose schemas have drifted between nodes is held out of comparison
#    until they converge - through Schema Guard, or by naming the differing
#    columns as ignored - because comparing rows across two different shapes
#    produces noise, not findings."
#
# ## Why it is a block and not a repair
#
# Recon compares a checksum over a row's columns. If one node has a column the
# others do not, every row of that table checksums differently on that node, and
# the comparison reports the whole table as divergent - thousands of findings,
# none of them real, and a repair pass that would happily rewrite good rows to
# match whichever copy won. The gate stops the round before any of that.
#
# The verdict is deliberately three-valued (`schema.rs::Verdict`): `Clear`,
# `Covered` (they differ, but every differing column is already in `ignore_col`,
# so what remains is still comparable), and `Differs`. A fourth, `Unknown`, is
# explicitly NOT a block - a gate that failed closed would stop recon
# cluster-wide every time the leader restarted.
#
# ## What is asserted
#
# 1. a drifted table is named by `yt_info('W')`, with the differing column
# 2. ...and the suggestion is usable: it names the column an operator would put
#    in `ignore_col`
# 3. recon does not compare it while it is blocked
# 4. converging the schema clears the gate on its own
# 5. an undrifted table is NOT blocked - the gate is not just "always on"
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== blocking/table: a schema-drifted table is held out of comparison =="

# recon=repair so a round would actually do something if the gate let it - a
# gate asserted against a table recon was never going to touch proves nothing.
CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'recon=repair; recon_rows=1' | tail -1)"

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists sb_t; create table sb_t (id bigint primary key, v text);
	        drop table if exists sb_ok; create table sb_ok (id bigint primary key, v text);" >/dev/null
done
register_table public.sb_t "$CFG"
register_table public.sb_ok "$CFG"
restart_all
await_cluster
wait_writable n1 n2 sb_t || { bad "cluster never became writable"; summary; }

# ## The drift has to be on a FOLLOWER, and the report read there
#
# `schema_check` returns `Clear` without asking anyone when this node IS the
# leader - there is no reference document to fetch, because it is the reference.
# So a leader can never report its own table as drifted, and a test that
# ALTERed the leader's copy and then read `yt_info('W')` on the leader would see
# a clean bill of health on a cluster it had just broken.
L=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in *Leader) L="$n";; esac
done
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }

# the drifted node, and a matching follower to check the gate discriminates
DRIFT=""; PEER=""
for n in "${NODES[@]}"; do
	is_spare_node "$n" && continue
	[ "$n" = "$L" ] && continue
	if [ -z "$DRIFT" ]; then DRIFT="$n"; elif [ -z "$PEER" ]; then PEER="$n"; fi
done
echo "  leader=$L  drift-node=$DRIFT  control-follower=$PEER"

# Seed both tables. The gate is about SCHEMA, not rows, but a table with no rows
# would also report "nothing to compare" and the two are worth telling apart.
for i in 1 2 3; do
	q "$L" "begin; insert into sb_t values ($i,'base-$i');
	        insert into sb_ok values ($i,'base-$i'); select yt_complete(true); commit;" >/dev/null
done
sleep 3
check "the seed reached $DRIFT" "3" "$(q "$DRIFT" "select count(*) from sb_t")"

# ── the drift ───────────────────────────────────────────────────────────────
#
# DDL is not replicated by this cluster, so one ALTER on one node IS the drift -
# no trigger juggling needed, unlike the row-level splits 85_alert has to stage.
echo "  adding a column to sb_t on $DRIFT only..."
q "$DRIFT" "alter table sb_t add column drift text" >/dev/null
check "$DRIFT has the extra column" "1" \
	"$(q "$DRIFT" "select count(*) from information_schema.columns where table_name='sb_t' and column_name='drift'")"
check "the leader $L does not" "0" \
	"$(q "$L" "select count(*) from information_schema.columns where table_name='sb_t' and column_name='drift'")"

# `yt_info('W')` runs the gate over every synced table before reporting
# (`stat.rs` -> `schema_check_all`), so it answers even though no round has run.
# Give the peers a tick to re-read the catalog first.
sleep 5

w="$(info "$DRIFT" W)"
echo "  yt_info('W') on $DRIFT:"
printf '%s' "$w" | python3 -c "
import json,sys
try: rows=json.load(sys.stdin)
except Exception: print('     <unparseable>'); sys.exit()
for r in rows: print('     %s = %s' % (r['name'], r['value'][:100]))" 2>/dev/null

# ── 1/2. the drifted table is named, with a usable suggestion ───────────────
blocked="$(info "$DRIFT" W "public.sb_t")"
[ -z "$blocked" ] && blocked="$(info "$DRIFT" W "$YX_DB.public.sb_t")"
case "$blocked" in
	*"schema differs"*)
		ok "yt_info('W') reports sb_t as schema-blocked" ;;
	"")  bad "yt_info('W') does not mention sb_t at all - the gate did not fire, \
or it reports under a different key than the table name" ;;
	*)   bad "sb_t is listed but not as a schema difference: $blocked" ;;
esac
case "$blocked" in
	*drift*) ok "the suggestion names the differing column (ignore_col: drift)" ;;
	*) bad "the suggestion does not name 'drift', so an operator cannot act on it: $blocked" ;;
esac

# ── 5. and the UNDRIFTED table is not blocked ───────────────────────────────
#
# Without this the test passes on a gate that blocks everything.
ok_tbl="$(info "$DRIFT" W "public.sb_ok")"
[ -z "$ok_tbl" ] && ok_tbl="$(info "$DRIFT" W "$YX_DB.public.sb_ok")"
[ -z "$ok_tbl" ] \
	&& ok "sb_ok, whose schema matches, is NOT blocked" \
	|| bad "sb_ok is blocked too - the gate is not discriminating: $ok_tbl"

# ...and the leader, which is the reference, reports no discrepancy for either.
lw="$(info "$L" W checked)"
[ -n "$lw" ] \
	&& ok "the leader reports no discrepancy (it is the reference): $lw" \
	|| bad "the leader lists a blocked table - it has nothing to compare against"

# ── 3. recon does not compare it while blocked ──────────────────────────────
#
# Read from the node that HAS the drift: the gate is evaluated where the round
# runs, and n4 is the node whose catalog differs.
echo "  making sb_t due and waiting for a round..."
for i in 4 5 6; do
	q "$L" "begin; insert into sb_t values ($i,'base-$i'); select yt_complete(true); commit;" >/dev/null
done
sleep 25

# `grep -c` exits 1 on a count of zero, so `rh ... || echo 0` appended a second
# line and `[` saw "0\n0". Swallow it inside the remote command instead.
gate_log="$(rh "docker logs --since 3m $DRIFT 2>&1 | { grep -c 'SCHEMA GATE' || true; }" | tail -1)"
[ "${gate_log:-0}" -gt 0 ] \
	&& ok "$DRIFT logged the SCHEMA GATE, so the round stopped before comparing" \
	|| bad "no SCHEMA GATE line on $DRIFT - either no round ran, or it compared anyway"

# The counters must show the table was not checked. A gate that logs and then
# compares anyway would satisfy the line above and nothing else.
rec="$(info "$DRIFT" E recon)"
echo "     $DRIFT recon: ${rec:-<none>}"

# ── 4. converging clears it, with no operator action beyond the DDL ─────────
echo "  dropping the column again..."
q "$DRIFT" "alter table sb_t drop column drift" >/dev/null
sleep 8

after="$(info "$DRIFT" W "public.sb_t")"
[ -z "$after" ] && after="$(info "$DRIFT" W "$YX_DB.public.sb_t")"
[ -z "$after" ] \
	&& ok "the gate cleared once the schemas converged" \
	|| bad "sb_t is still blocked after the column was dropped: $after — the \
verdict is cached and nothing invalidated it"

summary
