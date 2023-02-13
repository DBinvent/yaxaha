-- select * from json_to_recordset(yt_info('EI')) as x(name text, module text, value text);
\echo "use with --env INIT=select.sql"
select * from yt_config where module = ' ';
