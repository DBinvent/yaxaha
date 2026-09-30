#!/bin/bash
set -Eeu
# Keeps a node's YT server running, so a test case can kill it and watch the
# cluster recover. Exits once node.toml's `close` task removes node.env.
#
#   ./node_runner.sh <node-id> <command> [args...]
#
# The command is taken as the whole of "$@" rather than a fixed $1 $2, so
# arguments can be added to ytserv without editing this file — which is how
# `public.yt_config` came to be missing when ytserv started requiring it.
. ./wait_common.sh

if [ $# -lt 2 ]; then
  echo "usage: $0 <node-id> <command> [args...]" >&2
  exit 1
fi

nid=$1
shift

# A restart is a test case; a crash loop is a broken build. The difference
# is how long the process stayed up: a server killed by case3 has been
# serving for a while, one that panics on its own config never gets going.
# Without this the run does not fail, it spins — ytserv panicking on a node
# id it will not accept restarts here forever while yt_wait.sh waits for a
# leader that is never coming.
max_crashes=${IT_MAX_RESTARTS:-5}
min_uptime=${IT_MIN_UPTIME:-5}

s=1
crashes=0

while [ -f node.env ]
do
  echo "Starting $* ..."
  started=$(date +%s)
  rc=0
  # Deliberately not fatal: the server exiting is a test case, not an error.
  "$@" || rc=$?
  ran=$(( $(date +%s) - started ))
  echo "Node$nid stopped after ${ran}s (exit $rc)"

  if [ "$rc" -ne 0 ] && [ "$ran" -lt "$min_uptime" ]
  then
    crashes=$(( crashes + 1 ))
    if [ "$crashes" -ge "$max_crashes" ]
    then
      it_fail "node$nid: $1 exited $rc within ${min_uptime}s, $crashes times running — not restarting again"
    fi
    echo "Node$nid crashed ($crashes/$max_crashes) ..."
  else
    # Stayed up long enough to count as a real run; forget earlier crashes.
    crashes=0
  fi

  if [ -f node.env ]
  then
    echo "Node$nid will restart in $s sec...."
    sleep $s
  fi
done
