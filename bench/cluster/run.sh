#!/usr/bin/env bash
# bench/cluster/run.sh — pgbench, cluster manner (BENCH.md §2, clusterTODO.md)
#
#   ./run.sh <nodes-file> <nosync|nodes1>
#
# One disjoint stream per node (../stream.sql), started together on a
# wall-clock barrier, then quiesced and checked for convergence. Writes one
# CSV row per (config,cond,nodes,node,run) to results/<suite>.csv and exits
# non-zero if any run diverged, timed out converging, or failed the TPC-B
# invariant.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

NODES_FILE=${1:?usage: run.sh <nodes-file> <nosync|nodes1>}
COND=${2:?usage: run.sh <nodes-file> <nosync|nodes1>}
case "$COND" in nosync|nodes1) ;; *) cl_die "cond must be nosync|nodes1" ;; esac

cl_read_nodes "$NODES_FILE"

BENCH_CLIENTS=${BENCH_CLIENTS:-8}
BENCH_JOBS=${BENCH_JOBS:-2}
BENCH_DURATION=${BENCH_DURATION:-60}
BENCH_RUNS=${BENCH_RUNS:-1}
BENCH_START_LEAD=${BENCH_START_LEAD:-15}
BENCH_SETTLE_S=${BENCH_SETTLE_S:-5}
BENCH_CONVERGE_TIMEOUT_S=${BENCH_CONVERGE_TIMEOUT_S:-120}
BENCH_WORKLOAD=${BENCH_WORKLOAD:-disjoint}       # disjoint | overlapping
BENCH_SUITE=${BENCH_SUITE:-$(date +%Y%m%dT%H%M%S)}
CSV="$HERE/results/${BENCH_SUITE}.csv"
: > "$BENCH_ERR"

CONFIG=$([ "$N" -eq 1 ] && echo S1 || echo "C$N")
NEFF=$N; [ "$BENCH_WORKLOAD" = overlapping ] && NEFF=1   # overlapping => every node hits the whole key space

if [ -z "${BENCH_SKIP_INIT:-}" ]; then
  "$HERE/init.sh" "$NODES_FILE" "$COND" || cl_die "init failed"
fi
SCALE=$(cat "$HERE/results/.scale" 2>/dev/null || echo "${BENCH_SCALE:-$(( N*10>20 ? N*10 : 20 ))}")

if [ ! -s "$CSV" ]; then
  echo "suite,config,cond,nodes,node,workload,run,clients,scale,duration_s,started_at,start_spread_s,tps,lat_avg_ms,lat_stddev_ms,failed,wal_bytes,xact_commit,xact_rollback,deadlocks,net_tx_bytes,net_rx_bytes,converged,converged_after_s,settle_s,invariant_ok" > "$CSV"
fi

# pgbench connection args by condition
conn_args() { # $1 = node index
  local port=${NODE_PGPORT[$1]}
  if [ "$COND" != nosync ] && [ "$BENCH_VIA_PGBOUNCER" = 1 ]; then
    echo "-h $BENCH_PGB_HOST -p $BENCH_PGB_PORT"     # XA patch injects yt_complete
  else
    echo "-h /var/run/postgresql -p $port"           # direct (nosync, or auto_complete on)
  fi
}

parse_pgbench() {  # stdin = pgbench output -> "tps|lat_avg|lat_stddev|failed"
  awk '
    /number of failed transactions:/ { split($0,a,":"); split(a[2],b,"("); failed=b[1]+0 }
    /^latency average/               { for(i=1;i<=NF;i++) if($i=="=") {lat=$(i+1); break} }
    /^latency stddev/                { for(i=1;i<=NF;i++) if($i=="=") {sd=$(i+1); break} }
    /tps = .*without initial/        { for(i=1;i<=NF;i++) if($i=="=") {tps=$(i+1); break} }
    END { printf "%s|%s|%s|%s", (tps==""?0:tps), (lat==""?"":lat), (sd==""?"":sd), (failed==""?0:failed) }
  '
}

overall_rc=0

for r in $(seq 1 "$BENCH_RUNS"); do
  cl_log "=== run $r/$BENCH_RUNS  cond=$COND  config=$CONFIG  scale=$SCALE  workload=$BENCH_WORKLOAD ==="
  [ "$r" -gt 1 ] && "$HERE/init.sh" "$NODES_FILE" "$COND"    # reset+re-register between runs

  # --- pre snapshot -------------------------------------------------------
  declare -a SNAP0
  for i in $(seq 0 $((N-1))); do SNAP0[$i]=$(cl_stat_snapshot "${NODE_SSH[$i]}" "${NODE_PGPORT[$i]}"); done

  # --- barrier-start pgbench on every node ------------------------------
  T0=$(( $(cl_now) + BENCH_START_LEAD ))
  STARTED_AT=$(date -u -d "@$T0" +%Y-%m-%dT%H:%M:%SZ)
  cl_log "start barrier at $(date -d "@$T0" +%H:%M:%S) (+${BENCH_START_LEAD}s)"
  pids=()
  for i in $(seq 0 $((N-1))); do
    node=$((i+1)); port=${NODE_PGPORT[$i]}; ca=$(conn_args "$i")
    tag="${BENCH_SUITE}_${r}_${node}"
    $BENCH_SSH "${NODE_SSH[$i]}" "bash -s" <<EOF >/dev/null 2>&1 &
mkdir -p $BENCH_REMOTE_DIR
while [ "\$(date +%s)" -lt $T0 ]; do sleep 0.2; done
echo "START \$(date +%s.%N)" > $BENCH_REMOTE_DIR/start_${tag}.txt
$BENCH_ROLE_CMD pgbench -n -M prepared -P 5 --progress-timestamp \
  -f $BENCH_REMOTE_DIR/stream_run.sql -D node=$node -D nodes=$NEFF -D scale=$SCALE \
  -c $BENCH_CLIENTS -j $BENCH_JOBS -T $BENCH_DURATION $ca $BENCH_DB \
  > $BENCH_REMOTE_DIR/out_${tag}.txt 2>&1
echo "RC \$?" >> $BENCH_REMOTE_DIR/out_${tag}.txt
EOF
    pids+=($!)
  done
  wait "${pids[@]}"
  cl_log "load finished; settle ${BENCH_SETTLE_S}s"

  # --- post snapshot + fetch outputs -----------------------------------
  declare -a SNAP1 OUT START
  for i in $(seq 0 $((N-1))); do
    node=$((i+1)); tag="${BENCH_SUITE}_${r}_${node}"
    SNAP1[$i]=$(cl_stat_snapshot "${NODE_SSH[$i]}" "${NODE_PGPORT[$i]}")
    OUT[$i]=$($BENCH_SSH "${NODE_SSH[$i]}" "cat $BENCH_REMOTE_DIR/out_${tag}.txt" 2>/dev/null)
    START[$i]=$($BENCH_SSH "${NODE_SSH[$i]}" "cat $BENCH_REMOTE_DIR/start_${tag}.txt" 2>/dev/null | awk '{print $2}')
  done
  # observed start spread
  spread=$(printf '%s\n' "${START[@]}" | awk 'NR==1{mn=mx=$1} {if($1<mn)mn=$1; if($1>mx)mx=$1} END{printf "%.3f", mx-mn}')
  cl_log "observed start spread: ${spread}s"

  sleep "$BENCH_SETTLE_S"

  # --- convergence (nodes1 only) --------------------------------
  converged=NA; converged_after=""
  if [ "$COND" != nosync ]; then
    ref=$(cl_digest "${NODE_SSH[0]}" "${NODE_PGPORT[0]}" | grep -v '^INVARIANT')
    t=0; converged=false; disagree=""
    while [ "$t" -le "$BENCH_CONVERGE_TIMEOUT_S" ]; do
      disagree=""
      for i in $(seq 1 $((N-1))); do
        d=$(cl_digest "${NODE_SSH[$i]}" "${NODE_PGPORT[$i]}" | grep -v '^INVARIANT')
        [ "$d" = "$ref" ] || disagree="$disagree $((i+1))"
      done
      [ -z "$disagree" ] && { converged=true; converged_after=$t; break; }
      sleep 2; t=$((t+2))
      ref=$(cl_digest "${NODE_SSH[0]}" "${NODE_PGPORT[0]}" | grep -v '^INVARIANT')
    done
    if [ "$converged" = true ]; then
      cl_log "converged after ${converged_after}s"
    else
      converged_after=$BENCH_CONVERGE_TIMEOUT_S
      cl_fail "run $r did NOT converge in ${BENCH_CONVERGE_TIMEOUT_S}s; disagreeing nodes:$disagree"
      overall_rc=1
    fi
  fi

  # --- per-node CSV rows ---------------------------------------------
  for i in $(seq 0 $((N-1))); do
    node=$((i+1))
    IFS='|' read -r tps lat sd failed <<<"$(printf '%s\n' "${OUT[$i]}" | parse_pgbench)"
    IFS='|' read -r d_wal d_xc d_xr d_dl d_tx d_rx <<<"$(cl_stat_delta "${SNAP0[$i]}" "${SNAP1[$i]}")"
    # TPC-B invariant on this node
    inv=$(cl_digest "${NODE_SSH[$i]}" "${NODE_PGPORT[$i]}" | awk -F'|' '/^INVARIANT/{print ($2==$3 && $3==$4 && $4==$5)?"true":"false"}')
    [ "$inv" = false ] && { cl_fail "run $r node $node: TPC-B invariant broken"; overall_rc=1; }
    echo "$BENCH_SUITE,$CONFIG,$COND,$N,$node,$BENCH_WORKLOAD,$r,$BENCH_CLIENTS,$SCALE,$BENCH_DURATION,$STARTED_AT,$spread,$tps,$lat,$sd,$failed,$d_wal,$d_xc,$d_xr,$d_dl,$d_tx,$d_rx,$converged,${converged_after:-},$BENCH_SETTLE_S,${inv:-NA}" >> "$CSV"
  done
  unset SNAP0 SNAP1 OUT START
done

# --- summary --------------------------------------------------------------
echo
echo "==== $BENCH_SUITE  cond=$COND  config=$CONFIG  ===="
awk -F, 'NR==1{next}
  { n[$5]=1; tps[$5]+=$13; f[$5]+=$16; runs[$5]++; conv=$23; caf=$24; inv=$25 }
  END{
    agg=0;
    for(k in n){ printf "  node %s: mean tps %.1f  failed %d  (%d run rows)\n", k, tps[k]/runs[k], f[k], runs[k]; agg+=tps[k]/runs[k] }
    printf "  aggregate mean tps: %.1f\n", agg
  }' "$CSV"
echo "  converged: $converged   invariant: $( [ $overall_rc -eq 0 ] && echo ok || echo FAIL )"
echo "  csv: $CSV"
[ -s "$BENCH_ERR" ] && { echo; echo "failures:"; sed 's/^/  /' "$BENCH_ERR"; }
exit $overall_rc
