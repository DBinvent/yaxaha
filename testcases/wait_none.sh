#!/bin/bash
set -Eeu
# ожидание удаления строки из таблице - окончание сценария, выполняется на каждой ноде
#script = "./testcases/wait.sh $port $wd $NID $CUID.X testcaseX"

sql="select value from yt_config where name = '$4' and value = '$4'"

echo "$5: Waiting for cleanup/emptying at Node$3 with: $sql"

runs=0
lines=1
errors=0

while [[ "$runs" -lt 10  &&  $lines -lt 0 && $errors -lt 1 ]]
do
  sleep 1

  # check lines
  lines=$(psql -p $1 -h $2 -c "$sql" -t | grep $4 | wc -l)

  # check errors
  errors=$(cat error.msg | grep -v "^[[:space:]]*$" | wc -l)

  # increment counter
  runs=$(( runs + 1 ))

done

