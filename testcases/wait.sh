#!/bin/bash
#set -Eeu
# Will run on every node
# ожидание появление или изменения строки в таблице - окончание сценария, выполняется на каждой ноде
#script = "./testcases/wait.sh $port $wd $NID $CUID.X testcaseX"

sql="select value from yt_config where name = '$4' and value = '$4'"

echo "$5: Waiting for update at Node$3 with: $sql"

runs=0
lines=0
errors=0
expected=1

if [ $# -gt 4 ]; then
 expected=$5
fi

while [[ "$runs" -lt 10  &&  $lines -lt $expected && $errors -lt 1 ]]
do
  sleep 1

  # check lines
  lines=$(psql -p $1 -h $2 -c "$sql" -t | grep $4 | wc -l)

  # check errors
  errors=$(cat error.msg | grep -v "^[[:space:]]*$" | wc -l)

  # increment counter
  runs=$(( runs + 1 ))

done

#echo "$5: Done: Waiting for update at Node$3"
sql="select name, value from json_to_recordset(yt_info('i')) as x(name text, module text, value text)"
psql -p $1 -h $2 -c "$sql" -t
