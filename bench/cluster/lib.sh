#!/usr/bin/env bash
# bench/cluster/lib.sh — sourced by run.sh / init.sh / conditions.sh.
# Bounded waits only (wait_common.sh rationale): a hang reports nothing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BENCH_SSH=${BENCH_SSH:-"ssh -o BatchMode=yes -o ConnectTimeout=8"}
BENCH_DB=${BENCH_DB:-pgbench}
BENCH_ROLE_CMD=${BENCH_ROLE_CMD:-"sudo -n -u postgres"}
BENCH_PGPORT=${BENCH_PGPORT:-5432}
# How a nodes1 transaction gets completed into the cluster:
#   BENCH_VIA_PGBOUNCER=0 (default) — connect direct; the extension's
#       `yaxaha.auto_complete` GUC (default on) fires yt_complete at
#       PRE_COMMIT, so a plain COMMIT is a cluster commit. No PgBouncer.
#   BENCH_VIA_PGBOUNCER=1 — legacy path: drive the load through a patched
#       PgBouncer so a bare COMMIT is turned into `yt_complete(true); COMMIT`
#       by the XA patch. Only needed if auto_complete is disabled.
BENCH_VIA_PGBOUNCER=${BENCH_VIA_PGBOUNCER:-0}
BENCH_PGB_HOST=${BENCH_PGB_HOST:-127.0.0.1}
BENCH_PGB_PORT=${BENCH_PGB_PORT:-6432}
BENCH_REMOTE_DIR=${BENCH_REMOTE_DIR:-/tmp/yaxaha_bench}
BENCH_ERR=${BENCH_ERR:-"$HERE/results/error.msg"}
BENCH_SCHEMA=${BENCH_SCHEMA:-public}
BENCH_YTSERVER_RESTART=${BENCH_YTSERVER_RESTART:-"sudo -n systemctl restart ytserver"}

mkdir -p "$HERE/results"

# --- output -----------------------------------------------------------------
cl_log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
cl_fail() { echo "[bench] $*" >&2; echo "[bench] $*" >> "$BENCH_ERR"; return 1; }
cl_die()  { cl_fail "$*"; exit 1; }

# --- node list ------------------------------------------------------------------
# reads a nodes file -> arrays NODE_SSH[] NODE_PGPORT[] ; sets N
cl_read_nodes() {
  local f=$1 line host port
  NODE_SSH=(); NODE_PGPORT=()
  [ -r "$f" ] || cl_die "nodes file not readable: $f"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    read -r host port <<<"$line"
    [ -n "${host:-}" ] || continue
    NODE_SSH+=("$host")
    NODE_PGPORT+=("${port:-$BENCH_PGPORT}")
  done < "$f"
  N=${#NODE_SSH[@]}
  [ "$N" -ge 1 ] || cl_die "no nodes in $f"
}

# --- remote exec --------------------------------------------------------------
cl_ssh() { local h=$1; shift; $BENCH_SSH "$h" "$@"; }

# psql on node $1 (ssh target), port $2, SQL on stdin or via -c "$3"
cl_psql() {
  local h=$1 port=$2 sql=${3:-}
  if [ -n "$sql" ]; then
    cl_ssh "$h" "$BENCH_ROLE_CMD psql -v ON_ERROR_STOP=1 -tAF'|' -h /var/run/postgresql -p $port -d $BENCH_DB -c \"$sql\""
  else
    cl_ssh "$h" "$BENCH_ROLE_CMD psql -v ON_ERROR_STOP=1 -tAF'|' -h /var/run/postgresql -p $port -d $BENCH_DB"
  fi
}

# --- wall-clock barrier -------------------------------------------------------
cl_now() { date +%s; }

# emit a tiny sh snippet that busy-waits to epoch $1 then execs "$@" (rest)
cl_barrier_runner() {
  local t0=$1; shift
  printf 'while [ "$(date +%%s)" -lt %s ]; do sleep 0.2; done; exec %s\n' "$t0" "$*"
}

# --- bounded poll (it_wait_for, explicit timeout) ---------------------------
# cl_wait_for "<what>" <timeout_s> <cmd...>   -> 0 on success, 1 on timeout
cl_wait_for() {
  local what=$1 timeout=$2; shift 2
  local waited=0
  while ! "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$timeout" ]; then
      cl_log "gave up on: $what (${timeout}s). last attempt:"
      "$@" >&2 || true
      return 1
    fi
    sleep 1; waited=$((waited+1))
  done
  return 0
}

# --- pg stat snapshots (one line: wal_bytes|xact_commit|xact_rollback|deadlocks|net_tx|net_rx) ---
cl_stat_snapshot() {
  local h=$1 port=$2
  local pg net
  pg=$(cl_psql "$h" "$port" "select
      (select wal_bytes from pg_stat_wal),
      (select xact_commit from pg_stat_database where datname='$BENCH_DB'),
      (select xact_rollback from pg_stat_database where datname='$BENCH_DB'),
      (select deadlocks from pg_stat_database where datname='$BENCH_DB')" 2>/dev/null | tr -d ' ')
  net=$(cl_ssh "$h" "awk -F'[: ]+' '/:/{if(\$2!~/lo/){rx+=\$3;tx+=\$11}} END{print tx\"|\"rx}' /proc/net/dev" 2>/dev/null)
  echo "${pg:-0|0|0|0}|${net:-0|0}"
}

# delta of two "a|b|c|d|e|f" lines
cl_stat_delta() {
  awk -F'|' -v a="$1" -v b="$2" 'BEGIN{
    na=split(a,A,"|"); nb=split(b,B,"|"); out="";
    for(i=1;i<=nb;i++){d=B[i]-A[i]; out=out (i>1?"|":"") d}
    print out}'
}

# --- digest / convergence --------------------------------------------------
# echo the digest of node $1:$2 (rel lines only, sorted) ; used for compare
cl_digest() {
  local h=$1 port=$2
  cl_ssh "$h" "$BENCH_ROLE_CMD psql -v ON_ERROR_STOP=1 -tAF'|' -h /var/run/postgresql -p $port -d $BENCH_DB \
      -v 'ON_ERROR_STOP=1' <<'SQL'
set search_path to $BENCH_SCHEMA;
$(cat "$HERE/digest.sql")
SQL" 2>/dev/null | sort
}
