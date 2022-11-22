#!/bin/bash
echo "[IT] Probing YT extension for Node$3 at $2 $1..."
#set -Eeu

port=$1$3
wd=$2$3


# waiting for Postgres up and extension created
./psql_wait.sh $port $wd $3

# waiting for YTserver and leader
leader=0

while [[ $leader -lt 1 ]]
do
 sleep 1
 leader=$(psql -p $port -h $wd -c "select * from yt_info('O')" -t | grep -v None | grep Leader | wc -l)
done

# waiting nodes up
node=0
while [[ $node -lt 1 ]]
do
  sleep 1
  node=$(psql -p $port -h $wd -f ./testcases/state_node.sql -t | grep -v "other leader" | grep "Good\|Leader" | wc -l)
done

# waiting at least one node selectable with a good recognized status by first_node.sql
runs=0
probe=0
while [[ $runs -lt 10 && $probe -eq 0 ]]
do
  nid=1
  while [[ $nid -le $4 ]]
  do
   probe=$(psql -p $1$nid -h $2$nid -f ./testcases/first_node.sql -t | grep "-" | wc -l)
   if [[ $probe -ge 1 ]]
   then
     break
   fi
   nid=$(( nid + 1 ))

  done
  runs=$(( runs + 1 ))
  sleep 1
done

echo
echo "[IT] YT Node $3 is ready... "
echo
