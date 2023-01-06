#!/bin/bash

socket=$2"/.s.PGSQL."$1
marker=$2"/.marker"

echo "Waiting for '$socket' existence"
while [ ! -e "$socket" ]
do
  sleep 1
done

echo "[IT] Probing Postgres for Node$3 at $2 $1..."

counter=1
while [ $counter -lt 10 ]
do
  sleep 1
  echo "psql -p $1 -h $2 -c select 1 -t -v ON_ERROR_STOP=on -U $USER postgres"

  psql -p $1 -h $2 -c "select 1" -t -v ON_ERROR_STOP=on -U postgres postgres
  if [ $? -eq 0 ]; then
    counter=0
    break
  fi
  psql -p $1 -h $2 -c "select 1" -t -v ON_ERROR_STOP=on -U $USER postgres
  if [ $? -eq 0 ]; then
    counter=0
    break
  fi
#  psql -p $1 -h $2 -c "select 1" -t -v ON_ERROR_STOP=on -U postgres postgres
# psql -p $1 -h $2 -U postgres -l -w -a -b -e -t -v ON_ERROR_STOP=on postgres
  ((counter++))
done

if [ $counter -eq 0 ]; then
  echo "[IT] PostgreSQL is ready for Node$3 ... "
else
  echo "[IT] PostgreSQL is NOT ready for Node$3 ... "
  exit 1
fi
