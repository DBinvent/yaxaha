#!/bin/bash
set -Eeu
# YT server runner support restart
if [ $# -lt 3 ]; then
  echo "No params"
  exit 1
fi
s=1
while [ -f node.env ]
do
  echo "Starting $1/ytserv $2 ..."
  $1/ytserv $2
  echo "Node$3 stopped"
  if [ -f node.env ]
  then
    echo "Node$3 will restart in $s sec...."
    sleep $s
  fi
done
