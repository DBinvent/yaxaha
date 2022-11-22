#!/bin/bash
SCRIPT_DIR=$(dirname $(realpath "$0"))

lc=$(psql -p $1 -h $2 -f $SCRIPT_DIR/$3 -t | grep "-" | wc -l)

#echo "check $3 at $1 $lc"

if [[ $lc -ge 1 ]]
then
#echo OK $3 for $1
exit 0
fi
#echo not $3 for $1
exit 1
