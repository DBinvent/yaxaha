#!/bin/bash

#psql -p $1 -h $2 -c "select * from help_with_defaults"
psql -p $1 -h $2  -P pager=off -c "SELECT * FROM json_to_recordset(yt_info('H')) AS x(name text, module text, value text)"
