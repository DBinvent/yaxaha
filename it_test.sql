-- select * from json_to_recordset(yt_info('EI')) as x(name text, module text, value text);
\echo before
select * from yt_config where module = ' ';
select 'The leader node is: ' || value from json_to_recordset(yt_info('E')) as x(name text, value text) where name = 'leader';

-- select * from json_to_recordset(yt_info('i')) as x(name text, module text, value text);
begin;

insert into yt_config(name, value) values ('test1', 'test');

select yt_complete(true);
commit;

-- select pg_sleep(1);

-- select * from json_to_recordset(yt_info('i')) as x(name text, module text, value text);
\echo after

-- select * from json_to_recordset(yt_info('i')) as x(name text, module text, value text);
-- select value from yt_info('d') where name = 'leader'

select * from yt_config where module = ' ';
