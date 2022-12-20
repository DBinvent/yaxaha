-- \echo "call yt_info with o e and table itself"


VACUUM FULL;

DROP TRIGGER IF EXISTS yt_config_test_trigger ON yt_config;
-- insert into yt_config(name, value) values ('test0', 'test');

delete from yt_config where name like '%yt_config';
-- see print_table_cfg_v1
insert into yt_config(name, module, value) values ('.'|| current_database() ||'.public.yt_config', 'A', '');

\echo prepare TRIGGER on yt_config

CREATE TRIGGER yt_config_test_trigger AFTER INSERT OR UPDATE OR DELETE ON yt_config FOR EACH ROW EXECUTE PROCEDURE yt_synchronize();

\echo "call yt_info with e and i"
select name, module, value from yt_config where module <> ' '
union all
select * from json_to_recordset(yt_info('EI')) as x(name text, module text, value text)
;
