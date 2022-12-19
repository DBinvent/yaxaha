drop EXTENSION if exists ytpgxt cascade;

create table if not exists public.yt_config (
    id serial primary key,
    name varchar(80),
    module char not null default ' ',
    value varchar(250) not null);

delete from public.yt_config where module in ('N', 'T', 'C') and name <> 'term';

insert into public.yt_config (name, module, value) values
 ('node1','N','127.0.0.1:28771'), -- -6e6f6465316e
 ('node2','N','127.0.0.1:28772'), -- -6e6f6465326e
 ('node3','N','127.0.0.1:28773'), -- -6e6f6465336e
 ('ping_tick_sleep_ms','C','5000'), -- delay between pings
 ('log_level','C','debug'),
 ('fs_dir','C','./cluster'),
 ('cfg_level','C','5'), -- use: 'node uuid . IP . port' as logs prefix
 ('verbose','C','true'), -- extra logs
 ('verbose_each','C','0'), -- show ping stat every X pings (0 - do not show)
 ('fs_cache_days', 'C', '99'), -- load logs old days
 ('dir','T','/tmp/'); -- dir not use yet, now just example to show passing values into trigger

create schema if not exists yt;


CREATE EXTENSION ytpgxt;-- schema yt;

\echo "init completed for"
show yt.node;

\echo "select * from json_to_recordset(yt_info('OTI')) as x(name text, module text, value text); select * from yt_config where name = 'term';"
