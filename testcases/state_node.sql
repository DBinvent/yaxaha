-- возвращает статус-cтроку ноды, используется в yt_wait.sh
-- node=$(psql -p $1 -h $2 -f ./state_node.sql -t | grep "Good\|Leader" | wc -l)
select value from json_to_recordset(yt_info('e'))
 as x(name text, module text, value text)
where name = (select value from json_to_recordset(yt_info('e'))
   as x(name text, module text, value text)
    where name = 'self');
