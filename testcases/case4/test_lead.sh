#!/bin/bash
SCRIPT_DIR=$(dirname $(realpath "$0"))

sql="begin; insert into yt_config(name, value) values ('$4', '$4');  \
$($SCRIPT_DIR/../yt_complete.sh)  commit;"

$SCRIPT_DIR/../header.sh TestCase2 node $3 "$sql"

psql -p $1 -h $2  -P pager=off -c "$sql" 2>&1 | grep ERROR >> error.msg

echo "TestCase3 completed"
