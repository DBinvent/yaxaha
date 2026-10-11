-- RPPD tables, minus the rppd_event() cache-invalidation triggers: this
-- pipeline never uses a PostgreSQL trigger, so the rppd C extension is not
-- needed. Step 1 is driven by yaxaha's on_commit_python (ytserv calls rppd
-- directly) and step 2 by an etcd queue watcher. Restart ytserver to pick up
-- rppd_function changes instead of relying on the triggers.

CREATE TABLE IF NOT EXISTS public.rppd_config (
    id serial primary key,
    host varchar(64) not null unique,
    host_name varchar(64) not null unique,
    active_since timestamptz default current_timestamp,
    max_db_connections int not null default 10,
    master bool unique
);

CREATE TABLE IF NOT EXISTS public.rppd_function (
    id serial primary key,
    code text not null,
    checksum varchar(64) not null,
    schema_table varchar(64) not null,
    topic varchar(64) not null default '',
    priority int not null default 1,
    queue bool not null default true,
    cleanup_logs_min int not null default 0,
    fn_logging bool not null default false,
    verbose_debug bool not null default false,
    env json,
    sign json
);

CREATE TABLE IF NOT EXISTS public.rppd_function_log (
    id bigserial primary key,
    node_id int not null,
    fn_id int not null,
    trig_value json,
    trig_type int not null default 0,
    started_at timestamptz not null default current_timestamp,
    took_ms bigint,
    output text,
    error_msg text
);

CREATE TABLE IF NOT EXISTS public.rppd_cron (
    id serial primary key,
    fn_id int not null,
    cron varchar(64) not null,
    column_name varchar(64) not null,
    column_value text,
    cadence bool not null default false,
    timeout_sec int,
    finished_at timestamptz,
    started_at timestamptz,
    error_msg text,
    watch_min int not null default 0,
    retry_sec int not null default 0,
    watch_q varchar(256),
    deadline_q varchar(256),
    state varchar(16) not null default 'ok',
    last_seen timestamptz,
    since timestamptz,
    attempt int not null default 0
);

-- The table pgbench INSERTs into. on_commit_python fires fn #1 for each row.
CREATE TABLE IF NOT EXISTS public.bench_src (
    id     serial primary key,
    bid    int  not null,
    amount int  not null,
    note   text
);
