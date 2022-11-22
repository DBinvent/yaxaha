-- select * from json_to_recordset(yt_info('EI')) as x(name text, module text, value text);
\echo before

select * from json_to_recordset(yt_info('i')) as x(name text, module text, value text);
begin;

insert into yt_config(name, value) values ('test1', 'test');

select yt_complete(true);
commit;

select pg_sleep(1);

select * from json_to_recordset(yt_info('i')) as x(name text, module text, value text);
\echo after
