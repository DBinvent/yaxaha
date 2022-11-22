-- return string for a only first node (non leader)
-- node=$(psql -p $1 -h $2 -f ./first_node.sql -t | wc -l)

with info as (
 select name, value from json_to_recordset(yt_info('e'))
  as x(name text, module text, value text)
  where name not in ('cluster', 'nodes') and value not like '%Leader%')
select ii.name, ii.value from
    (select info.name, info.value from info
        where info.name like '%-%'
        order by name limit 1) as ii
where ii.name = (select info.value from info where info.name = 'self')
    and not exists (select info.name from info
        where info.name = 'leader' and info.value = 'self' )
