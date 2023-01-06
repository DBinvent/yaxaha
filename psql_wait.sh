#!/bin/bash
echo "[IT] Probing YTserver for Node$3 at $2 $1..."
#set -Eeu

status=1
while [ $status -ne 0 ]
do
  sleep 1
  psql -p $1 -h $2  -P pager=off -c "select count(*) from yt_info('R')" -t -v ON_ERROR_STOP=on
  status=$?
done

echo "[IT] PostgreSQL psql is ready for Node$3 ... "
