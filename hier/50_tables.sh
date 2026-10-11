#!/usr/bin/env bash
# [tpl2 items 1-2, the per-table half] The two table configurations, across a
# REAL cluster boundary.
#
# `az.rs`'s unit tests already cover `role_for` thoroughly, and ../topology/30_az
# and 60_write_az cover it within one cluster. What neither can cover is the
# question tpl2.md actually asked:
#
#   1. a table where ONE level writes and every other level receives it as an
#      update, with no manual writes there;
#   2. a table that does NOT propagate to another level at all.
#
# Within a single cluster those are statements about zones. Across a boundary they
# are statements about clusters, and the difference is that the boundary is where
# the link rules, the quorum exclusion and the tier filter all have to agree at
# once. A rule that works between two azs of one cluster and not across a boundary
# is exactly the "wired into one arrival path" failure this tree keeps finding.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== tables: write-by-top-only, and not-propagated-at-all =="

enc() { "$REPO_ROOT"/target/release/yxctl --encode-table-cfg "$1" 2>/dev/null | tail -1; }

CFG_TOP="$(enc 'az=top,eastc,westc; write=top')"
CFG_PINNED="$(enc 'az=eastc; no_up; no_down')"
[ -n "$CFG_TOP" ] && [ -n "$CFG_PINNED" ] \
	&& ok "both table configurations encode" \
	|| { bad "--encode-table-cfg produced nothing (top=[$CFG_TOP] pinned=[$CFG_PINNED])"; summary; }

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists t_top; create table t_top (id bigint primary key, v text);
	        drop table if exists t_pin; create table t_pin (id bigint primary key, v text);" >/dev/null
done
register_table public.t_top "$CFG_TOP"
register_table public.t_pin "$CFG_PINNED"
restart_all 30
await_clusters

UP="$(leader_of upper)"; EA="$(leader_of east)"; WE="$(leader_of west)"
[ -n "$UP" ] && [ -n "$EA" ] \
	&& ok "clusters settled after the restart (upper=$UP east=$EA west=$WE)" \
	|| { bad "no leader: upper=[$UP] east=[$EA]"; summary; }

# ── 1. the config is LOADED where it has to be enforced ────────────────────
#
# A module-A row present and not loaded is the failure that looks like a routing
# bug, so this reads the running server rather than the table.
for n in "$UP" "$EA"; do
	raw="$(info "$n" "a:public.t_top" raw)"
    [ -n "$raw" ] \
		&& ok "$n loaded t_top's routing config" \
		|| bad "$n has no module-A row loaded for t_top - every branch below would \
collapse to FLAT and this test would pass for the wrong reason"
done

# ── 2. write by top only ───────────────────────────────────────────────────
#
# top holds and writes; eastc and westc hold and READ. The "no manual writes there"
# half of item 1 is the second assertion: a write ORIGINATING below must be refused,
# not silently accepted and then lost.
echo "  writing from the top cluster..."
q "$UP" "begin; insert into t_top values (1,'from-top'); select yt_complete(true); commit;" >/dev/null 2>&1 || true

landed=0
for _ in $(seq 1 12); do
	landed=0
	for n in "$EA" "$WE"; do
		[ "$(q "$n" "select v from t_top where id=1")" = "from-top" ] && landed=$((landed+1))
	done
	[ "$landed" -ge 2 ] && break
	sleep 5
done
[ "$landed" -ge 2 ] \
	&& ok "a write originated at the top reached BOTH lower clusters as an update" \
	|| bad "the top's write reached $landed of 2 lower clusters within 60s. The relay \
carries cross-boundary rows since ytserv 0.20.22 (tpl2.md 'The relay'): each lower \
leader fetches what the upper cluster committed to a table its az holds and \
delivers it to its members, outside consensus. So a lower cluster without the row \
is a relay failure - not driven by that cluster's leader, not reaching its members, \
or never fetched - and not a missing feature."

echo "  attempting a write from below (must be refused, not lost)..."
below="$(q "$EA" "begin; insert into t_top values (2,'from-east'); select yt_complete(true); commit;" 2>&1 || true)"
# Read back on the ORIGINATING node: a refused write must leave nothing behind
# there either, because a row that exists locally and nowhere else is the silent
# divergence this rule exists to prevent.
local_row="$(q "$EA" "select count(*) from t_top where id=2")"
other_row="$(q "$UP" "select count(*) from t_top where id=2")"
if [ "${local_row:-0}" = "0" ] && [ "${other_row:-0}" = "0" ]; then
	ok "a write from a non-writable level was refused everywhere"
elif [ "${other_row:-0}" = "0" ]; then
	bad "the write was kept on $EA (${local_row} row) and propagated nowhere - a \
non-writable level accepted a write locally, which is divergence rather than refusal"
else
	bad "a non-writable level's write propagated: $EA=$local_row $UP=$other_row"
fi

# ── 3. not propagated at all ───────────────────────────────────────────────
#
# `az=eastc; no_up; no_down` - the shard-local case. The load-bearing rule from
# topology.md is that NOT PROPAGATED MEANS NOT READABLE: nothing forwards a read to
# where the rows live, so a node outside eastc must simply not have them.
echo "  writing to the pinned table inside eastc..."
q "$EA" "begin; insert into t_pin values (1,'east-only'); select yt_complete(true); commit;" >/dev/null 2>&1 || true
sleep 12

inside="$(q "$EA" "select v from t_pin where id=1")"
check "the pinned row is present inside its own az" "east-only" "$inside"

leaked=""
for n in ${CLUSTER_NODES[upper]} ${CLUSTER_NODES[west]}; do
	c="$(q "$n" "select count(*) from t_pin where id=1")"
	[ "${c:-0}" != "0" ] && leaked="$leaked $n"
done
[ -z "$leaked" ] \
	&& ok "the pinned row reached no node outside eastc, up or sideways" \
	|| bad "a table with no_up AND no_down leaked to:$leaked - this is the \
regression state/cluster.rs:1996 records, where the leader carried a no_up table \
through the apply path"

# ── 4. and the pinned table's peers inside eastc DO have it ────────────────
#
# The inverse: "not propagated" must not degrade into "not replicated anywhere",
# which would pass section 3 while breaking the table.
inside_cnt=0
for n in ${CLUSTER_NODES[east]}; do
	[ "$(q "$n" "select count(*) from t_pin where id=1")" = "1" ] && inside_cnt=$((inside_cnt+1))
done
[ "$inside_cnt" -ge 2 ] \
	&& ok "the pinned row replicated within eastc ($inside_cnt of 3 nodes)" \
	|| bad "the pinned row is on $inside_cnt of 3 eastc nodes - no_up/no_down stopped \
replication inside the az as well as across the boundary"

summary
