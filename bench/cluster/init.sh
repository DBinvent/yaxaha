#!/usr/bin/env bash
# bench/cluster/init.sh
#
#   ./init.sh <nodes-file> <cond> [scale]
#
# Idempotent per-node data setup:
#   1. ensure $BENCH_DB exists
#   2. pgbench -i -s <scale> --no-vacuum   (deterministic -> identical on every node)
#   3. push stream.sql + digest.sql to $BENCH_REMOTE_DIR on each node
#   4. apply the sync condition (conditions.sh)
#
# `pgbench -i` each run is the reset: it drops and recreates pgbench_*, so a
# prior run's writes and any stale triggers on those tables go with them
# (conditions.sh re-registers afterwards for nodes1).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

NODES_FILE=${1:?usage: init.sh <nodes-file> <cond> [scale]}
COND=${2:?usage: init.sh <nodes-file> <cond> [scale]}
cl_read_nodes "$NODES_FILE"
SCALE=${3:-${BENCH_SCALE:-$(( N*10 > 20 ? N*10 : 20 ))}}

cl_log "init: $N node(s), scale $SCALE, db $BENCH_DB"

init_one() {
  local h=$1 port=$2
  cl_ssh "$h" "mkdir -p $BENCH_REMOTE_DIR" || { cl_log "  $h: mkdir FAILED"; return 1; }
  # create the db if a connection to it fails (idempotent)
  cl_ssh "$h" "$BENCH_ROLE_CMD psql -tAc 'select 1' -h /var/run/postgresql -p $port -d $BENCH_DB >/dev/null 2>&1 \
    || $BENCH_ROLE_CMD createdb -h /var/run/postgresql -p $port $BENCH_DB" \
    >/dev/null 2>&1 || { cl_log "  $h: createdb FAILED"; return 1; }

  # ship the scripts. stream_run.sql is the one pgbench actually runs. Its
  # trailing `END;` is swapped for `COMMIT;` only when nodes1 goes through
  # PgBouncerXA (the XA patch keys on a bare COMMIT); nosync and the
  # auto_complete-direct path use stream.sql verbatim.
  $BENCH_SSH "$h" "cat > $BENCH_REMOTE_DIR/stream.sql" < "$HERE/../stream.sql" || return 1
  $BENCH_SSH "$h" "cat > $BENCH_REMOTE_DIR/digest.sql" < "$HERE/digest.sql"    || return 1
  if [ "$COND" != nosync ] && [ "$BENCH_VIA_PGBOUNCER" = 1 ]; then
    sed 's/^END;[[:space:]]*$/COMMIT;/' "$HERE/../stream.sql" \
      | $BENCH_SSH "$h" "cat > $BENCH_REMOTE_DIR/stream_run.sql" || return 1
  else
    $BENCH_SSH "$h" "cp $BENCH_REMOTE_DIR/stream.sql $BENCH_REMOTE_DIR/stream_run.sql" || return 1
  fi

  # pgbench -i  (quiet; --no-vacuum keeps it fast and deterministic)
  cl_ssh "$h" "$BENCH_ROLE_CMD pgbench -i -s $SCALE --no-vacuum -q -h /var/run/postgresql -p $port $BENCH_DB" \
    >/dev/null 2>&1 && cl_log "  $h: pgbench -i -s $SCALE ok" || { cl_log "  $h: pgbench -i FAILED"; return 1; }
}

rc=0
pids=()
for i in $(seq 0 $((N-1))); do
  init_one "${NODE_SSH[$i]}" "${NODE_PGPORT[$i]}" & pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ $rc -eq 0 ] || cl_die "init failed on one or more nodes"

echo "$SCALE" > "$HERE/results/.scale"
"$HERE/conditions.sh" "$NODES_FILE" "$COND"
