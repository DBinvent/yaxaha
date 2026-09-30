#!/usr/bin/env bash
# Register the two pipeline functions and arm on_commit_python on bench_src.
# Run on the ORIGIN node (the one pgbench writes to) - on_commit fires there.
#
#   sudo -u postgres PSQL="psql -p 5434 -d pgbench" bash 02_register.sh
set -eu
SP="$(cd "$(dirname "$0")" && pwd)"
PSQL="${PSQL:-psql -p 5434 -d pgbench}"

# One script, because psql interpolates :'var' only from a file, never from -c.
cat > "$SP/.register.psql" <<PSQL_EOF
\\set ON_ERROR_STOP on
\\i $SP/01_schema.sql

-- rppd_config is NOT written here any more: ytserv maintains it from the
-- cluster's own roster on every heartbeat, one row per node, with master on
-- whichever node the cluster elected leader (sync_rppd_config). Leave the table
-- empty and it fills itself in within a tick or two.

DELETE FROM public.rppd_function WHERE schema_table IN ('public.bench_src', '/q/analytics');

-- fn1: driven by on_commit_python on the source table. topic '.id' = per-row queue.
\\set code \`cat $SP/fn1_src_to_queue.py\`
INSERT INTO public.rppd_function
  (code, checksum, schema_table, topic, verbose_debug, fn_logging, cleanup_logs_min)
  VALUES (:'code', 'na', 'public.bench_src', '.id', true, true, 100);

-- fn2: etcd queue watcher. '/q/' marks a queue for the Rust etcd implementation.
\\set code2 \`cat $SP/fn2_queue_to_clickhouse.py\`
INSERT INTO public.rppd_function
  (code, checksum, schema_table, topic, verbose_debug, fn_logging, cleanup_logs_min)
  VALUES (:'code2', 'na', '/q/analytics', '', true, true, 100);

-- Node config: rppd + etcd + clickhouse all on.
DELETE FROM public.yt_config WHERE module='C' AND name IN ('serve_rppd','serve_etcd','rppd_schema');
INSERT INTO public.yt_config(name, module, value) VALUES
  ('serve_rppd','C','true'), ('serve_etcd','C','true'), ('rppd_schema','C','public');

-- The cluster-sync trigger. yt_setup() lives in ytpgc/pg_setup.sql and is not
-- part of the installed extension, so create it directly - that is all it does
-- for a table besides writing the A-row below.
DROP TRIGGER IF EXISTS z_bench_src ON public.bench_src;
CREATE TRIGGER z_bench_src AFTER INSERT OR UPDATE OR DELETE ON public.bench_src
  FOR EACH ROW EXECUTE FUNCTION yt_synchronize();

-- A-row: cluster_commit=half, wal=half, on_commit_python.
-- base64 of ConfigValue{Table{cluster_commit:Half, wal:Half, on_commit_python:true}}
-- yt_config has no unique on (name,module), so delete-then-insert, not upsert.
DELETE FROM public.yt_config WHERE module='A' AND name='public.bench_src';
INSERT INTO public.yt_config(name, module, value)
VALUES ('public.bench_src','A','CgoSAhABGgIQAUAB');

SELECT id, schema_table, topic, length(code) AS code_bytes FROM public.rppd_function ORDER BY id;
PSQL_EOF

$PSQL -f "$SP/.register.psql"
rm -f "$SP/.register.psql"
echo "registered; restart ytserver on every node to load the functions"
