#!/bin/bash

socket=$2"/.s.PGSQL."$1
marker=$2"/.marker"

echo "Waiting for '$socket' existence"
while [ ! -e "$socket" ]
do
  sleep 1
done

echo "[IT] Probing Postgres for Node$3 at $2 $1..."

status=1
while [ $status -ne 0 ]
do
  sleep 1
#  echo "psql -p $1 -h $2 -c select 1 -t -v ON_ERROR_STOP=on postgres"
  psql -p $1 -h $2 -l -w -a -b -e -t -v ON_ERROR_STOP=on
  status=$?
done

echo "[IT] PostgreSQL is ready for Node$3 ... "
