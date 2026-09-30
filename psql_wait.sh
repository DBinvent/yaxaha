#!/bin/bash
# Waits until the extension can answer, which means ytserv is up: yt_info()
# reaches it over HTTP, so this fails while ytserv is down.
#
#   ./psql_wait.sh <port> <working-dir> <node-id>
. ./wait_common.sh

port=$1
wd=$2
nid=$3

yt_answers() {
  psql -p "$port" -h "$wd" -P pager=off \
    -c "select count(*) from yt_info('R')" -t -v ON_ERROR_STOP=on
}

# Was an unbounded `while [ $status -ne 0 ]`. It is the loop that spun 6,888
# times against a `CREATE EXTENSION` that had failed, and the one that could
# never finish while it was called before ytserv started.
echo "[IT] Probing YTserver for Node$nid at $wd $port..."
it_wait_for "yt_info() to answer on node$nid (is ytserv running?)" yt_answers

echo "[IT] PostgreSQL psql is ready for Node$nid ... "
