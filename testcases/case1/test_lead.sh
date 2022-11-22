#!/bin/bash

SCRIPT_DIR=$(dirname $(realpath "$0"))

sql="begin; insert into yt_config(name, value) values ('$4', '$4'); select yt_complete(true); commit;"

$SCRIPT_DIR/../header.sh TestCase1 leader $3 "$sql"

psql -p $1 -h $2 -c "$sql" 2>&1 | grep ERROR >> error.msg

echo "TestCase1 completed"
