#!/bin/bash
# Waits until this node is a usable member of the cluster: extension
# answering, a leader elected, and this node reporting a good state.
#
#   ./yt_wait.sh <port-prefix> <dir-prefix> <node-id> <node-count>
. ./wait_common.sh

prefix=$1
dirprefix=$2
nid=$3
cnt=$4

port=$prefix$nid
wd=$dirprefix$nid

echo "[IT] Probing YT extension for Node$nid at $dirprefix $prefix..."

# Postgres up and the extension answering. Fatal here — without `|| exit 1`
# this script has no `set -e` and would carry on into waits that cannot
# possibly succeed.
./psql_wait.sh "$port" "$wd" "$nid" || exit 1

# Was unbounded. A cluster that never elects a leader — a roster pointing at
# the wrong port, a node id ytserv refuses, peers that cannot see each
# other — waited here for as long as anyone let it.
leader_elected() {
  [ "$(psql -p "$port" -h "$wd" -P pager=off -c "select * from yt_info('O')" -t \
       | grep -v None | grep -c Leader)" -ge 1 ]
}
it_wait_for "a leader to be elected (node$nid)" leader_elected

# Was unbounded. Same failure, one step later: a leader exists but this node
# is not in a state any test could run against.
node_is_good() {
  [ "$(psql -p "$port" -h "$wd" -P pager=off -f ./testcases/state_node.sql -t \
       | grep -v "other leader" | grep -c "Good\|Leader")" -ge 1 ]
}
it_wait_for "node$nid to report Good or Leader" node_is_good

# Already bounded, and deliberately left advisory: the test cases use
# first_node.sql in a `condition_script`, so if no node qualifies they skip
# rather than fail. That is its own problem (REVIEW.md, finding 3) — but it
# is a pass/fail question, not a hang, so this only says so out loud now
# instead of giving up in silence.
runs=0
probe=0
while [[ $runs -lt 10 && $probe -eq 0 ]]
do
  nid_probe=1
  while [[ $nid_probe -le $cnt ]]
  do
    probe=$(psql -p "$prefix$nid_probe" -h "$dirprefix$nid_probe" -P pager=off \
              -f ./testcases/first_node.sql -t | grep -c "-")
    if [[ $probe -ge 1 ]]
    then
      break
    fi
    nid_probe=$(( nid_probe + 1 ))
  done
  runs=$(( runs + 1 ))
  sleep 1
done

if [[ $probe -eq 0 ]]
then
  echo "[IT] WARNING: no node satisfied first_node.sql after ${runs}s." >&2
  echo "[IT] The test cases keyed on it will skip, and skipping looks like" >&2
  echo "[IT] passing. See REVIEW.md, finding 3." >&2
fi

echo
echo "[IT] YT Node $nid is ready... "
echo
