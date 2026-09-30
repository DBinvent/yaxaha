#!/usr/bin/env bash
# bench/cluster/conditions.sh
#
#   ./conditions.sh <nodes-file> <nosync|sync|nodes1>
#
# Applies the sync condition to every node's $BENCH_DB, then (for a sync
# condition) restarts ytserver on all nodes together so the new module='A'
# rows load. Sourced pieces come from lib.sh.
#
#   nosync  tables not registered at all — per-node ceiling / denominator
#   sync    ClusterCommitAll (CgIaAA==) — every commit synchronous to ALL nodes:
#           it lands everywhere or the client gets an error to retry. No silent
#           divergence. This is the correct/consistent cluster condition.
#   nodes1  ClusterCommitNodes — origin-guarded + async fan-out (see cluster_commit.b64).
#
# Every registered table gets an EXPLICIT module='A' value — never empty (an
# empty value = def_cluster_commit fallback + the silent-divergence fast path).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

NODES_FILE=${1:?usage: conditions.sh <nodes-file> <cond>}
COND=${2:?usage: conditions.sh <nodes-file> <cond>}

BENCH_SYNC_TABLES=${BENCH_SYNC_TABLES:-"pgbench_branches pgbench_tellers pgbench_accounts"}
[ "${BENCH_SYNC_HISTORY:-0}" = 1 ] && BENCH_SYNC_TABLES="$BENCH_SYNC_TABLES pgbench_history"

# nodes1 = origin commits, checkin-guarded, async apply_all fan-out.
#   stock ytserv     : ClusterCommitNodes{at_least:1} (CgQiAggB) -> party_size 0
#   with the +1 patch: use {at_least:0} (CgIiAA==) instead — {1} then means
#                      origin + 1 synchronous peer. Override with BENCH_NODES1_B64.
: "${BENCH_NODES1_B64:=CgQiAggB}"
# ClusterCommitAll — every registered table commits synchronously to all nodes.
: "${BENCH_SYNC_B64:=CgIaAA==}"
case "$COND" in
  nosync)       CC_VALUE="__DROP__" ;;
  sync|all)     CC_VALUE="$BENCH_SYNC_B64" ;;
  nodes1)       CC_VALUE="$BENCH_NODES1_B64" ;;
  *) cl_die "unknown condition: $COND (want nosync|sync|nodes1)" ;;
esac

cl_read_nodes "$NODES_FILE"
cl_log "condition '$COND' on $N node(s); sync tables: ${BENCH_SYNC_TABLES:-none}"

apply_one() {
  local h=$1 port=$2 sql t
  if [ "$CC_VALUE" = "__DROP__" ]; then
    # unregister everything: drop all zytsync_* triggers + remove module='A'
    sql="select 1 from yt_setup('%.%','',false,'public.yt_config'); "
    sql+="delete from public.yt_config where module='A';"
  else
    sql=""
    for t in $BENCH_SYNC_TABLES; do
      sql+="select 1 from yt_setup('${BENCH_SCHEMA}.${t}','',true,'public.yt_config'); "
      sql+="update public.yt_config set name='${BENCH_SCHEMA}.${t}' "
      sql+="  where module='A' and name like '%.${BENCH_SCHEMA}.${t}'; "
    done
    sql+="update public.yt_config set value='${CC_VALUE}' where module='A'; "
  fi
  cl_ssh "$h" "$BENCH_ROLE_CMD psql -v ON_ERROR_STOP=1 -qtAX -h /var/run/postgresql -p $port -d $BENCH_DB -c \"$sql\"" \
    >/dev/null 2>&1 && cl_log "  $h: applied" || { cl_log "  $h: apply FAILED"; return 1; }
}

rc=0
for i in $(seq 0 $((N-1))); do
  apply_one "${NODE_SSH[$i]}" "${NODE_PGPORT[$i]}" || rc=1
done
[ $rc -eq 0 ] || cl_die "condition apply failed on one or more nodes"

# show the resulting A-rows on node 1
cl_log "module='A' rows on ${NODE_SSH[0]}:"
cl_psql "${NODE_SSH[0]}" "${NODE_PGPORT[0]}" \
  "select name, coalesce(nullif(value,''),'(default half)') from public.yt_config where module='A' order by name" \
  | sed 's/^/    /' >&2 || true

if [ "$COND" != nosync ]; then
  cl_log "restarting ytserver on all nodes together"
  pids=()
  for i in $(seq 0 $((N-1))); do
    cl_ssh "${NODE_SSH[$i]}" "$BENCH_YTSERVER_RESTART" >/dev/null 2>&1 &
    pids+=($!)
  done
  wait "${pids[@]}"
  # wait for a leader to be visible from every node (bounded). 2-node cold
  # start can take ~60-90s; raise BENCH_LEADER_TIMEOUT_S on a slow rig.
  local lt=${BENCH_LEADER_TIMEOUT_S:-150}
  leader_up() {
    local i
    for i in $(seq 0 $((N-1))); do
      cl_psql "${NODE_SSH[$i]}" "${NODE_PGPORT[$i]}" \
        "select 1 from json_to_recordset(yt_info('OTI')) as x(n text,v text,m text) where n='cluster' and v like '%Leader%'" \
        2>/dev/null | grep -q 1 || return 1
    done
  }
  if cl_wait_for "cluster leader on all nodes after restart" "$lt" leader_up; then
    cl_log "cluster has a leader on all nodes"
  else
    cl_fail "no leader ${lt}s after restart — cluster not forming (replication conditions need a healthy cluster)"
    exit 1
  fi
fi
cl_log "condition '$COND' ready"
