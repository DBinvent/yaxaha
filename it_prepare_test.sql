-- \echo "call yt_info with o e and table itself"

DROP TRIGGER IF EXISTS yt_config_test_trigger ON yt_config; -- safe way before create

\echo prepare TRIGGER on yt_config

CREATE TRIGGER yt_config_test_trigger AFTER INSERT OR UPDATE OR DELETE ON yt_config FOR EACH ROW EXECUTE PROCEDURE yt_synchronize();

\echo "call yt_info with e and i"

select name, module, value from yt_config where module <> ' '
union all
select * from json_to_recordset(yt_info('EI')) as x(name text, module text, value text)
;
