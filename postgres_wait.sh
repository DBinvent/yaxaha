#!/bin/bash
# Waits until this node's Postgres is up and answering.
#
#   ./postgres_wait.sh <port> <working-dir> <node-id>
. ./wait_common.sh

port=$1
wd=$2
nid=$3
socket="$wd/.s.PGSQL.$port"

socket_exists() { [ -e "$socket" ]; }

# Was an unbounded `while [ ! -e "$socket" ]`. If Postgres failed to start —
# a bad initdb, a port already taken, a data directory from another major
# version — this waited for a socket that was never coming, forever.
echo "[IT] Waiting for '$socket'"
it_wait_for "the Postgres socket $socket (node$nid)" socket_exists

# Either role will do: `postgres` exists from initdb, `$USER` is created a
# moment later by the yt task. Whichever answers first means the server is
# accepting queries.
accepts_queries() {
  psql -p "$port" -h "$wd" -c "select 1" -t -v ON_ERROR_STOP=on -U postgres postgres ||
  psql -p "$port" -h "$wd" -c "select 1" -t -v ON_ERROR_STOP=on -U "$USER" postgres
}

echo "[IT] Probing Postgres for Node$nid at $wd $port..."
it_wait_for "Postgres to accept queries on node$nid" accepts_queries

echo "[IT] PostgreSQL is ready for Node$nid ... "
