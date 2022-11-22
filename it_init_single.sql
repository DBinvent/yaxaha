drop EXTENSION if exists ytpgxt cascade;

create table if not exists public.yt_config (
    id serial primary key,
    name varchar(80),
    module char not null default ' ',
    value varchar(250) not null);

delete from public.yt_config where module in ('N', 'T', 'C') and name <> 'term';

insert into public.yt_config (name, module, value) values
 ('min_cluster_size','C','1'), -- cluster size set to 1 for single node cluster
 ('log_level','C','debug'),
 ('fs_dir','C','./cluster0'), -- store wal file
 ('cfg_level','C','5'), -- use: 'node uuid . IP . port' as logs prefix
 ('verbose','C','true'), -- extra logs
 ('verbose_each','C','0'), -- show ping stat every X pings (0 - do not show)
 ('fs_cache_days', 'C', '99'), -- load logs old days
 ('dir','T','/tmp/'); -- dir not use yet,nor now jsut example to show passing values into trigger

create schema if not exists yt;

CREATE EXTENSION ytpgxt;-- schema yt;

\echo "init completed for SINGLE CLUSTER NODE"

show yt.node;

\echo "select * from json_to_recordset(yt_info('OTI')) as x(name text, module text, value text); select * from yt_config where name = 'term';"
