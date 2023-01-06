#!/bin/bash
set -Eeu

if [[ ${PGBOUNCER:-} == "XA" ]]; then
  sql="select yt_complete(true); "
else
  sql=""
fi

echo $sql
