-- return string for a leader
-- node=$(psql -p $1 -h $2 -f ./leader_node.sql -t | wc -l)
with info as (
 select name, value from json_to_recordset(yt_info('e'))
  as x(name text, module text, value text))
select name||'-'||value from info
where info.name = 'leader' and info.value = 'self'
