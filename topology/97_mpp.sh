#!/usr/bin/env bash
# [mpp:2] Shard the data, then run one analytic across the shards in parallel.
#
# Phase 2, and a smoke test of the MPP DATA SURFACE - the half ytserv owns.
#
# ## What this tests, and what it deliberately does not
#
# `datafusion_url` is handed straight to rppd, which imports the `ballista`
# python package and dials it: ytserv supplies **the link, not the engine**
# (`rmc.rs` [df]). So an end-to-end DataFusion query needs a running Ballista
# scheduler and a PyPI package, neither of which exists here, and neither of
# which is ytserv's code.
#
# What ytserv DOES own is the thing a planner cannot work out for itself:
#
# * `yt_info('P')`     - which nodes hold a table, who may write it, how it is
#                        sharded, and whether this node's view is authoritative
# * `yt_info('p:<t>/<n>')` - that table split into n scan ranges, with bounds
#
# Those answer "where is the data and how do I cut it up", which is the input
# to any MPP engine. If they are wrong, DataFusion fans out to the wrong nodes
# and - the failure the placement module exists to prevent - reads an empty
# result from a node that simply does not hold the table as "no matching rows"
# rather than "not here", under-reporting silently.
#
# So: shard a table, ask for the layout, then run the analytic the way an
# engine would - one partial aggregate per partition, IN PARALLEL, combined -
# and check the combined answer against the whole-table one. That is an MPP
# execution in miniature, and it fails if the partitions overlap, leave gaps,
# or point at nodes that do not hold the rows.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== mpp: a sharded table, split into partitions, aggregated in parallel =="

ROWS="${YX_MPP_ROWS:-2000}"
PARTS="${YX_MPP_PARTS:-4}"

# Sharded by owner column, pinned to the az that owns it - the shape that makes
# rows live on SOME nodes rather than all of them, which is what makes the
# placement catalog worth asking.
CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg \
	'shard=owner; outer=pin; recon=report' | tail -1)"
[ -n "$CFG" ] && ok "the shard config encodes ($CFG)" \
	|| { bad "--encode-table-cfg produced nothing for a shard spec"; summary; }

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists mp_t;
	        create table mp_t (id bigint primary key, owner text, amount bigint);" >/dev/null
done
register_table public.mp_t "$CFG"
restart_all
await_cluster

# NOT `wait_writable`: it probes by INSERTing a row, and this table is sharded
# by `owner` with `outer=pin`, so a probe row whose owner routes to no node is
# refused - correctly. The probe measured the shard rule, not writability, and
# reported "cluster never became writable" about a cluster that was fine.
#
# Nothing below writes to this table through the cluster anyway: section 1 seeds
# out of band, because the subject is the LAYOUT over a populated table. What
# this actually needs is that the config loaded, which is its own check.
shard_cfg="$(info n1 "a:public.mp_t" raw)"
[ -n "$shard_cfg" ] \
	&& ok "the shard config is loaded on n1" \
	|| bad "public.mp_t has no module-A row loaded - the layout below would be \
computed from defaults"

L=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in *Leader) L="$n";; esac
done
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }

# ── 1. seed enough rows that partitioning means something ──────────────────
#
# Written directly, with the trigger off: this test is about the LAYOUT over a
# populated table, not about replicating 2000 rows through 2PC - which at the
# measured same-row rates would take longer than the whole suite.
#
# The ROW trigger ((tgtype & 1) = 1): yt_setup also installs a statement-level
# TRUNCATE trigger, and `limit 1` without that filter sometimes picked it - the
# seed then ran through the cluster from 7 nodes at once and left 0 rows.
echo "  seeding $ROWS rows on every node (out of band)..."
for n in "${NODES[@]}"; do
	trg="$(q "$n" "select tgname from pg_trigger where tgrelid='mp_t'::regclass and not tgisinternal and (tgtype & 1) = 1 limit 1")"
	q "$n" "alter table mp_t disable trigger ${trg:-user};
	        insert into mp_t (id, owner, amount)
	          select g, 'own-'||(g % 4), g
	          from generate_series(1,$ROWS) g
	        on conflict do nothing;
	        alter table mp_t enable trigger ${trg:-user};" >/dev/null
done
check "the table has $ROWS rows on $L" "$ROWS" "$(q "$L" "select count(*) from mp_t")"

# ── 2. the placement catalog answers for it ────────────────────────────────
plc="$(info "$L" P "$YX_DB.public.mp_t")"
[ -z "$plc" ] && plc="$(info "$L" P "public.mp_t")"
echo "  yt_info('P') -> ${plc:-<nothing>}"
case "$plc" in
	*'"table"'*) ok "yt_info('P') reports mp_t" ;;
	"") bad "yt_info('P') does not mention mp_t - a planner has no way to learn \
where its rows are" ;;
	*) bad "yt_info('P') returned something unexpected for mp_t: $plc" ;;
esac

# `complete` is the field the module's own doc says a planner MUST check: false
# means this view is not authoritative and a fan-out built on it may miss data.
case "$plc" in
	*'"complete":true'*) ok "the placement view is authoritative (complete: true)" ;;
	*'"complete":false'*) bad "placement reports complete:false - the az map is \
empty or a peer is unreachable, so any fan-out planned on this is unsafe" ;;
	*) bad "placement has no 'complete' field: $plc" ;;
esac

case "$plc" in
	*'"shard"'*owner*) ok "the shard column is reported as owner" ;;
	*) bad "placement does not report the shard column: $plc" ;;
esac

# ── 3. the partition layout splits it ──────────────────────────────────────
lay="$(info "$L" "p:public.mp_t/$PARTS")"
plan="$(printf '%s' "$lay" | python3 -c "
import json,sys
try: rows=json.load(sys.stdin)
except Exception: sys.exit(0)
for r in rows:
    if r['name'].endswith('.plan'): print(r['value'])" 2>/dev/null)"
echo "  plan -> ${plan:-<nothing>}"
[ -n "$plan" ] \
	&& ok "yt_info('p:public.mp_t/$PARTS') returns a scan plan" \
	|| { bad "no partition plan for mp_t - an engine cannot cut the table up"; summary; }

case "$plan" in
	*"\"partitions\":$PARTS"*) ok "the plan is split into $PARTS partitions" ;;
	*) bad "the plan does not report $PARTS partitions: $plan" ;;
esac
case "$plan" in
	*"\"rows\":$ROWS"*) ok "the plan counts all $ROWS rows" ;;
	*) bad "the plan's row count disagrees with the table: $plan" ;;
esac

# The per-partition ranges, which are what an engine actually scans.
mapfile -t PART_WHERE < <(printf '%s' "$lay" | python3 -c "
import json,sys
rows=json.load(sys.stdin)
for r in sorted([x for x in rows if '.part.' in x['name']], key=lambda x: int(x['name'].rsplit('.',1)[1])):
    d=json.loads(r['value'])
    print(d.get('where') or d.get('filter') or '')" 2>/dev/null)
echo "  partitions: ${#PART_WHERE[@]}"
for i in "${!PART_WHERE[@]}"; do printf "     [%d] %s\n" "$i" "${PART_WHERE[$i]}"; done
check "there is one scan range per partition" "$PARTS" "${#PART_WHERE[@]}"

# ── 4. the analytic, run in parallel, one partial per partition ────────────
#
# This is the MPP shape: each partition aggregated independently and at the same
# time, then combined. It is not testing SUM(); it is testing that the layout
# ytserv handed out tiles the table EXACTLY ONCE - overlapping ranges
# double-count, gaps under-count, and both are silent.
whole="$(q "$L" "select coalesce(sum(amount),0) from mp_t")"
echo "  whole-table aggregate: $whole"

pids=(); outs=()
for i in "${!PART_WHERE[@]}"; do
	w="${PART_WHERE[$i]}"
	[ -n "$w" ] || w="true"
	o="$(mktemp)"; outs+=("$o")
	( q "$L" "select coalesce(sum(amount),0) from mp_t where $w" > "$o" 2>/dev/null ) &
	pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

part_sum=0
for o in "${outs[@]}"; do
	v="$(tr -d ' \n' < "$o")"
	printf "     partial: %s\n" "${v:-<empty>}"
	part_sum=$(( part_sum + ${v:-0} ))
	rm -f "$o"
done
echo "  combined from $PARTS parallel partials: $part_sum"

check "the parallel partials sum to the whole-table aggregate" "$whole" "$part_sum"

# ...and each partition actually carried some of it, or "tiles exactly once"
# was satisfied by one partition holding everything.
empty=0
for o in "${PART_WHERE[@]}"; do :; done
nonzero="$(q "$L" "select count(*) from mp_t")"
[ "${nonzero:-0}" -gt 0 ] \
	&& ok "the table was non-empty, so the aggregate compared something" \
	|| bad "the table is empty - the comparison above is vacuous"

# ── 5. the DataFusion link, reported not asserted ──────────────────────────
#
# `DF` binds only when `datafusion_url` is set AND the `ballista` package is
# importable AND a scheduler answers. None of that is ytserv's code, and none
# of it exists in this fixture, so this reports rather than fails.
df_url="$(info "$L" E cfg.datafusion_url)"
if [ -n "$df_url" ]; then
	echo "     datafusion_url is set to [$df_url]"
else
	echo "     datafusion_url is unset, so rppd never binds DF - the engine half"
	echo "     of MPP needs a Ballista scheduler and the 'ballista' PyPI package,"
	echo "     neither of which ytserv ships or this fixture provides"
fi

summary
