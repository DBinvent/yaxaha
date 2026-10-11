#!/usr/bin/env bash
# yt_llm() on the lab cluster: plain-language questions answered by the
# database itself, through the text-to-SQL service of this folder (agent.md).
#
#   ./test-yt-llm.sh [--deploy <yaxaha.so | dist dir>] [--no-llm] [node ...]
#
#   node      <ssh target>[/<pg port>[/<database>]] of a cluster node. Default:
#             YT_LLM_NODES from ../../.env (space separated), e.g.
#             "user@node1 user@node2 user@node3/5434".
#   --deploy  first put this build of the extension library on every node; from
#             a directory (ytpgc/dist) the one for the node's PostgreSQL major
#             and glibc. The one it replaces is kept as yaxaha.so.bak-<time>.
#   --no-llm  skip the questions to the model (step 5)
#
# yt_llm_query(nl, page, size) calls the node's ytserv, which does all of the
# model call - it describes the tables the caller may read (no sample values),
# asks the model, and answers with the SQL, or with a page of its rows read as
# the caller. yt_llm(nl) returns the rows: SELECT * FROM yt_llm(..) AS t(..).
# On every node, in $YT_DB:
#   1. install: yt_config.value becomes text (a PEM is ~600 bytes, it was
#      varchar(250)), then the [llm] block of ytpgc/yaxaha--0.5.sql, which
#      re-runs cleanly
#   2. configure ytserv in yt_config: module 'C' serve_llm, llm_host and the
#      NAMES of three module 'K' rows - the CA, the client certificate and its
#      key from llm-client.env, all three encrypted with the nodes' app key.
#      ytserv reads module 'C' at start: restart it when these change.
#   3. sample_data.sql, schema shop: deterministic, so every node holds the
#      same rows - checked, not assumed
#   4. what needs no model: the two functions and nothing else, yt_llm read-only,
#      who may call them, what yt_llm_query() refuses before it calls the node
#   5. questions through yt_llm_query() - the SQL, a page of rows, paging - and
#      through yt_llm(), compared with a hand-written query. The request.txt
#      question is reported, not graded (agent.md, "Model quality").
#   6. a cancel reaches the node - nothing on the way has a time limit but
#      connecting: statement_timeout ends the wait for the model at once, and a
#      page held up behind a table lock this test takes is cancelled on the
#      node when its caller is. ytserv's log, where YT_LOG can read it, shows
#      it hanging up on the model and cancelling the page.
#   7. [llm2] (llm2.md) when YT_CH_URL or YT_DF_PYTHON is set: module 'K' row
#      clickhouse (the ch target's ClickHouse, an encrypted JSON object) and
#      module 'C' for the df target and the models (YT_RESTART restarts ytserv
#      after a module 'C' change; module 'K' is read on every call), then questions the
#      node answers from ClickHouse (graded against ClickHouse by hand, through
#      YT_CH_CLIENT), from DataFusion over YT_DF_TABLES (graded against
#      PostgreSQL), a name ClickHouse and PostgreSQL both have (must stay sql),
#      and a cancel of a df answer while it copies its partitions. Where
#      ClickHouse has the view default.big_numbers (CREATE VIEW default.big_numbers
#      AS SELECT number AS n FROM numbers(100000000000) - made by hand, this test
#      writes nothing to ClickHouse), also a cancel of a ch answer mid-read.
#
# Config: llm-client.env next to this script (LLM_URL, LLM_CA, LLM_CLIENT_CERT,
# LLM_CLIENT_KEY). An environment variable of the same name wins, and a path
# that does not exist is looked up next to llm-client.env, so the bundle works
# unpacked here as well as in ~/llm-client.
# App key: the one the nodes' ytserv runs with (marg) - SECRET in the
# environment, or YT_APP_KEY=<file> for a node started with --key <file>. The
# passphrase of module 'K' is its hex: SHA3-256 of SECRET, or the file's bytes.
# Env: YT_DB (pgbench); YT_SSH (ssh -o BatchMode=yes ..., with the lab key when
# this machine has it); YT_PSQL (sudo -n -u postgres psql); YT_LOG, run on the
# node to print ytserv's [llm] log lines (grep -a '\[llm\]' on the ytserver
# unit's StandardOutput file, /var/log/yaxaha/ytserver.log).
# Step 7 env: YT_CH_URL (ClickHouse HTTP as the node reaches it), YT_CH_USER
# (llm_ro) and YT_CH_PASSWORD, YT_CH_DB (where unqualified names are looked up),
# YT_CH_DATABASES (comma-separated; none = every non-system one) - together module
# 'K' row clickhouse, encrypted, with YT_CH_CLUSTER_SECRET as its cluster_secret
# where the ClickHouse cluster.xml of yt_config needs one; YT_CH_CLIENT (runs ClickHouse SQL from stdin
# here, prints TSV; default curl to YT_CH_URL),
# YT_DF_PYTHON (the node's python with datafusion), YT_DF_TABLES (shop.products),
# YT_MODEL_ROUTE / YT_MODEL_CH (model selectors, default none), YT_RESTART (run
# on the node after a module 'C' change, e.g. sudo -n systemctl restart ytserver;
# steps 2 and 7 use it), YT_CH_PROCESSES (where the ch cancel check looks for
# queries left running: system.processes of YT_CH_CLIENT's server by default; a
# node reading its own server of a cluster needs clusterAllReplicas(<cluster>,
# system.processes)).
# Exit status 0 when nothing FAILed.
set -uo pipefail

TESTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Settings: yaxaha-tests/.env (not committed, see env.example); the environment wins.
if [ -f "$TESTS_ROOT/.env" ]; then
    _yx_keep="$(export -p)"; set -a; . "$TESTS_ROOT/.env"; set +a; eval "$_yx_keep"; unset _yx_keep
fi
# The yt-pgxt checkout: YT_PGXT, or a sibling of this repository. Its llm/ holds
# the client settings, the question file and the sample data this test reads.
ROOT="${YT_PGXT:-$(cd "$TESTS_ROOT/.." && pwd)/yt-pgxt}"
HERE="${LLM_DIR:-$ROOT/llm}"
EXT_SQL="$ROOT/ytpgc/yaxaha--0.5.sql"
ENV_FILE="${LLM_CLIENT_ENV:-$HERE/llm-client.env}"

YT_DB=${YT_DB:-pgbench}
if [ -z "${YT_SSH:-}" ]; then
    YT_SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
    # a key of its own for the cluster nodes, when they are not in ~/.ssh/config
    [ -n "${YT_SSH_KEY:-}" ] && [ -f "$YT_SSH_KEY" ] &&
        YT_SSH="$YT_SSH -o IdentitiesOnly=yes -i $YT_SSH_KEY"
fi
YT_PSQL=${YT_PSQL:-"sudo -n -u postgres psql"}
YT_LOG=${YT_LOG:-"grep -a '\\[llm\\]' /var/log/yaxaha/ytserver.log"}

# names of the module 'K' rows; module 'C' llm_ca/llm_cert/llm_key point at them
K_CA=llm.ca
K_CERT=llm.cert
K_KEY=llm.key

DEPLOY=""
ASK=1
NODES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --deploy) DEPLOY=${2:?--deploy needs a .so or a directory}; shift 2 ;;
        --no-llm) ASK=0; shift ;;
        -h|--help) sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
        *) NODES+=("$1"); shift ;;
    esac
done
[ ${#NODES[@]} -gt 0 ] || read -r -a NODES <<< "${YT_LLM_NODES:-}"
[ ${#NODES[@]} -gt 0 ] || { echo "no nodes: name them, or set YT_LLM_NODES in $TESTS_ROOT/.env" >&2; exit 2; }

# The questions. Graded: the model gets these right, and the answer is exact.
Q1="How many customers are there in each country?"
R1="select country, count(*) from shop.customers group by country"
Q2="How many delivered orders were placed by customers of each country?"
R2="select c.country, count(*) from shop.orders o join shop.customers c on c.id = o.customer_id
    where o.status = 'delivered' group by c.country"
# Reported only: the question of request.txt, and its answer by hand.
Q3=$(sed -n '/^\[User question\]/{n;p;q}' "$HERE/request.txt")
R3="with d as (
      select c.country, o.id as order_id, p.category, oi.quantity * oi.unit_price as revenue
        from shop.orders o
        join shop.customers c on c.id = o.customer_id
        join shop.order_items oi on oi.order_id = o.id
        join shop.products p on p.id = oi.product_id
       where o.status = 'delivered' and o.order_date >= '2026-01-01' and o.order_date < '2027-01-01'),
    cat as (
      select country, category,
             row_number() over (partition by country order by sum(revenue) desc) as rn
        from d group by country, category)
    select d.country, sum(d.revenue) as total_revenue, count(distinct d.order_id) as orders,
           (select cat.category from cat where cat.country = d.country and cat.rn = 1) as top_category
      from d group by d.country order by total_revenue desc"

# [llm2] step 7: graded by ClickHouse (QC*), by PostgreSQL (QS*, QD*)
QC1="How many etcd events came from each source?"
RC1="SELECT source, count() FROM default.etcd_events GROUP BY source"
QC2="What is the total amount per node host in the bench analytics?"
RC2="SELECT node_host, sum(amount) FROM public.bench_analytics GROUP BY node_host"
QS1="What is the balance of each branch?"
RS1="select bid, bbalance from public.pgbench_branches"
QD1="How many products are there in each category?"
RD1="select category, count(*) from shop.products group by category"
QX="How many numbers in the big numbers view leave a remainder of 3 when divided by 7?"
QD2="What is the total quantity ordered for each product category?"
RD2="select p.category, sum(oi.quantity) from shop.order_items oi join shop.products p on p.id = oi.product_id
    group by p.category"
YT_CH_USER=${YT_CH_USER:-llm_ro}
YT_DF_TABLES=${YT_DF_TABLES:-shop.products}
LLM2_C="'llm_df_python', 'llm_df_tables', 'llm_model_route', 'llm_model_ch'"
# what step 7 no longer writes, taken out where an earlier run left it
LLM2_OLD_C="'llm_ch_url', 'llm_ch_user', 'llm_ch_databases'"

PASSED=0
FAILED=0

say() { printf '%s\n' "$*"; }

# PASS / FAIL / INFO lines of one node's psql output, counted and printed
tally() {
    local who=$1 line
    while IFS= read -r line; do
        line=${line#NOTICE:  }
        case "$line" in
            PASS*) PASSED=$((PASSED + 1)); say "  $who  $line" ;;
            FAIL*) FAILED=$((FAILED + 1)); say "  $who  $line" ;;
            ERROR:*|FATAL:*|psql:*|sudo:*|ssh:*)
                FAILED=$((FAILED + 1)); say "  $who  FAIL $line" ;;
            "") ;;
            *) say "  $who  $line" ;;
        esac
    done
}

check() {  # who label ok(0/1) detail
    if [ "$3" = 1 ]; then PASSED=$((PASSED + 1)); say "  $1  PASS $2: $4"
    else FAILED=$((FAILED + 1)); say "  $1  FAIL $2: $4"; fi
}

# the parts of a node argument: <ssh target>[/<pg port>[/<database>]]
node_ssh()  { say "${1%%/*}"; }
node_port() { local r=${1#*/}; [ "$r" = "$1" ] && say 5432 || say "${r%%/*}"; }
node_db()   { local r=${1#*/}; r=${r#*/}; [ "$r" = "${1#*/}" ] && say "$YT_DB" || say "$r"; }

# psql on a node, SQL on stdin; notices and errors come back on stdout
node_sql() {
    local n=$1 stop=${2:-1}
    $YT_SSH "$(node_ssh "$n")" "$YT_PSQL -X -q -At -v ON_ERROR_STOP=$stop -v VERBOSITY=terse \
        -v SHOW_CONTEXT=never -p $(node_port "$n") -d $(node_db "$n")" 2>&1
}

# ── config ─────────────────────────────────────────────────────────────────────

# llm-client.env, with the environment on top (the llm.env rule of agent.md)
load_env() {
    local line key val
    [ -r "$ENV_FILE" ] || { say "no $ENV_FILE"; exit 2; }
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(LLM_[A-Z_]+)=(.*)$ ]] || continue
        key=${BASH_REMATCH[2]}
        val=${BASH_REMATCH[3]}
        [ -n "${!key:-}" ] && continue
        val=${val%\"}; val=${val#\"}; val=${val%\'}; val=${val#\'}
        val=${val//\$\{HOME\}/$HOME}
        val=${val//\$HOME/$HOME}
        printf -v "$key" '%s' "$val"
    done < "$ENV_FILE"
}

# a path of llm-client.env, or the same file next to it
resolve() {
    local near
    near="$(dirname "$ENV_FILE")/$(basename "$1")"
    if [ -f "$1" ]; then say "$1"; elif [ -f "$near" ]; then say "$near"; else say "$1"; fi
}

load_env
: "${LLM_URL:?LLM_URL is not set in $ENV_FILE}"
CA=$(resolve "${LLM_CA:?}")
CERT=$(resolve "${LLM_CLIENT_CERT:?}")
KEY=$(resolve "${LLM_CLIENT_KEY:?}")
# llm_host is host:port; https is implied
LLM_HOST=${LLM_URL#https://}
LLM_HOST=${LLM_HOST%%/*}

say "== config: $ENV_FILE"
say "  llm_host $LLM_HOST"
ok=1
for f in "$CA" "$CERT" "$KEY"; do
    grep -q -- "-----BEGIN " "$f" 2>/dev/null || { ok=0; say "  not PEM: $f"; }
done
grep -q ENCRYPTED "$KEY" 2>/dev/null && ok=0
case "$LLM_URL" in https://*) ;; *) ok=0 ;; esac
re='^[][A-Za-z0-9.:-]+$'   # host:port, [v6]:port - safe to put in SQL as is
[[ "$LLM_HOST" =~ $re ]] || ok=0
check config pem "$ok" "https host:port; $(basename "$CA") $(basename "$CERT") $(basename "$KEY") are PEM"
[ "$ok" = 1 ] || exit 1
if [ "$(openssl x509 -in "$CERT" -noout -pubkey 2>/dev/null | openssl md5)" = \
     "$(openssl pkey -in "$KEY" -pubout 2>/dev/null | openssl md5)" ]; then
    check config key_pair 1 "$(basename "$KEY") is the key of $(basename "$CERT")"
else
    check config key_pair 0 "$(basename "$KEY") is not the key of $(basename "$CERT")"
fi
v=$(openssl verify -CAfile "$CA" "$CERT" 2>&1)
check config signed "$([ "${v##*: }" = OK ] && echo 1 || echo 0)" "$v"

# the app key, and the three values as module 'K' keeps them: encrypted with it
if [ -n "${YT_APP_KEY:-}" ]; then
    YT_LLM_PASS=$(sed '/^-----/d' "$YT_APP_KEY" | tr -d ' \r\n' | base64 -d 2>/dev/null | od -An -tx1 -v | tr -d ' \n')
    from="file $YT_APP_KEY"
elif [ -n "${SECRET:-}" ]; then
    YT_LLM_PASS=$(printf '%s' "$SECRET" | openssl dgst -sha3-256 -r | cut -d' ' -f1)
    from="SECRET"
else
    YT_LLM_PASS=""
    from="none: set SECRET, or YT_APP_KEY=<file>, to what the nodes' ytserv runs with"
fi
export YT_LLM_PASS
check config app_key "$([ ${#YT_LLM_PASS} = 64 ] && echo 1 || echo 0)" "$from"
[ ${#YT_LLM_PASS} = 64 ] || exit 1
ENC="openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -md sha256 -salt -a -A -pass env:YT_LLM_PASS"
KEY_ENC=$(openssl pkcs8 -topk8 -v2 aes-256-cbc -in "$KEY" -passout env:YT_LLM_PASS 2>&1)
CA_ENC=$($ENC -in "$CA" 2>&1)
CERT_ENC=$($ENC -in "$CERT" 2>&1)
ok=0
if [[ "$KEY_ENC" == "-----BEGIN ENCRYPTED PRIVATE KEY-----"* ]] &&
   openssl pkey -passin env:YT_LLM_PASS -noout 2>/dev/null <<< "$KEY_ENC" &&
   [ "$($ENC -d <<< "$CA_ENC" 2>/dev/null)" = "$(cat "$CA")" ] &&
   [ "$($ENC -d <<< "$CERT_ENC" 2>/dev/null)" = "$(cat "$CERT")" ]; then
    ok=1
fi
check config k_encrypted "$ok" "key as ENCRYPTED PRIVATE KEY, certificates by openssl enc; all open with the app key"
[ "$ok" = 1 ] || exit 1
LLM2=0
CH_ENC=""
if [ -n "${YT_CH_URL:-}${YT_DF_PYTHON:-}" ]; then
    LLM2=1
    if [ -n "${YT_CH_URL:-}" ]; then
        : "${YT_CH_PASSWORD:?YT_CH_URL needs YT_CH_PASSWORD, the password of $YT_CH_USER}"
        # module 'K' row clickhouse: the JSON object ytserv reads, encrypted
        CH_JSON=$(URL=$YT_CH_URL DB=${YT_CH_DB:-} DBS=${YT_CH_DATABASES:-} RO=$YT_CH_USER PW=$YT_CH_PASSWORD \
            CS=${YT_CH_CLUSTER_SECRET:-} python3 -c 'import json, os
e = os.environ
k = {"url": e["URL"], "db": e["DB"], "databases": [d.strip() for d in e["DBS"].split(",") if d.strip()],
     "username_ro": e["RO"], "password_ro": e["PW"]}
if e["CS"]:
    k["cluster_secret"] = e["CS"]
print(json.dumps(k))')
        CH_ENC=$(printf '%s' "$CH_JSON" | $ENC)
        YT_CH_CLIENT=${YT_CH_CLIENT:-"curl -sS --fail-with-body --data-binary @- -u $YT_CH_USER:$YT_CH_PASSWORD $YT_CH_URL/?readonly=1"}
        [ -n "$CH_JSON" ] && [ "$($ENC -d <<< "$CH_ENC" 2>/dev/null)" = "$CH_JSON" ] && ok=1 || ok=0
        check config ch_encrypted "$ok" "K clickhouse opens with the app key: ClickHouse $YT_CH_URL as $YT_CH_USER"
        v=$(echo "SELECT count() FROM system.tables WHERE database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema') FORMAT TSV" | $YT_CH_CLIENT 2>&1)
        check config ch_reachable "$([[ "$v" =~ ^[0-9]+$ ]] && echo 1 || echo 0)" "$v tables through YT_CH_CLIENT"
    fi
fi
if [ "$ASK" = 1 ]; then
    # From here, not from a node: tells a node's network trouble from a config one.
    h=$(curl -sS --max-time 20 --cacert "$CA" --cert "$CERT" --key "$KEY" "$LLM_URL/health" 2>&1)
    say "  INFO service from here: ${h:-no answer}"
fi

# ── the SQL ────────────────────────────────────────────────────────────────────

# yt_config.value to text; a view on the column (pg_setup.sql's yt_tables_cfg)
# blocks that, so it is dropped and put back as it was
widen_sql() {
    cat <<SQL
SET lock_timeout = '10s';
SELECT set_config('yt_llm.cfg', '$1.yt_config', false) \\g /dev/null
DO \$\$
DECLARE
    cfg   regclass := current_setting('yt_llm.cfg')::regclass;
    v     record;
    a     record;
    again text[] := '{}';
    s     text;
BEGIN
    IF (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
         WHERE attrelid = cfg AND attname = 'value') = 'text' THEN
        RETURN;
    END IF;
    FOR v IN SELECT c.oid, c.oid::regclass AS name, c.relowner, c.relacl
               FROM pg_class c
              WHERE c.oid IN (SELECT r.ev_class FROM pg_depend d JOIN pg_rewrite r ON r.oid = d.objid
                               WHERE d.classid = 'pg_rewrite'::regclass AND d.refobjid = cfg
                                 AND r.ev_class <> cfg)
    LOOP
        again := again || format('CREATE VIEW %s AS %s', v.name, pg_get_viewdef(v.oid))
                       || format('ALTER VIEW %s OWNER TO %I', v.name, pg_get_userbyid(v.relowner));
        FOR a IN SELECT * FROM aclexplode(v.relacl) x WHERE x.grantee <> v.relowner LOOP
            again := again || format('GRANT %s ON %s TO %s', a.privilege_type, v.name,
                CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END);
        END LOOP;
        EXECUTE format('DROP VIEW %s', v.name);
    END LOOP;
    EXECUTE format('ALTER TABLE %s ALTER COLUMN value TYPE text', cfg);
    FOREACH s IN ARRAY again LOOP
        EXECUTE s;
    END LOOP;
    RAISE NOTICE 'INFO install: %.value is text now (% view statements re-run)', cfg, cardinality(again);
END
\$\$;
SQL
}

# the [llm] block as CREATE EXTENSION would run it, then made the extension's own.
# First out: the functions of earlier versions of the block, members or not
# (yt_llm returned SETOF json then, which CREATE OR REPLACE cannot change).
install_sql() {
    widen_sql "$1"
    cat <<SQL
DO \$\$
DECLARE f regprocedure;
    name text;
BEGIN
    FOR f IN SELECT p.oid FROM pg_proc p
              WHERE p.pronamespace = '$1'::regnamespace
                AND (p.proname IN ('yt_llm_request', 'yt_llm_ask', 'yt_llm_run', 'yt_llm_sql',
                                   'yt_llm_prompt', 'yt_llm_complete')
                     OR (p.proname = 'yt_llm' AND p.prorettype <> 'record'::regtype))
    LOOP
        IF EXISTS (SELECT 1 FROM pg_depend d
                    WHERE d.classid = 'pg_proc'::regclass AND d.objid = f AND d.deptype = 'e') THEN
            EXECUTE format('ALTER EXTENSION yaxaha DROP FUNCTION %s', f);
        END IF;
        name := f::text;  -- once it is gone, regprocedure prints only the oid
        EXECUTE format('DROP FUNCTION %s', f);
        RAISE NOTICE 'INFO install: dropped %', name;
    END LOOP;
END
\$\$;
SQL
    sed -n '/^-- \[llm\] begin/,/^-- \[llm\] end/p' "$EXT_SQL" |
        sed "s/@extschema@/$1/g; s|'MODULE_PATHNAME'|'\$libdir/yaxaha'|g"
    cat <<SQL
DO \$\$
DECLARE f regprocedure;
BEGIN
    FOR f IN SELECT p.oid FROM pg_proc p
              WHERE p.pronamespace = '$1'::regnamespace AND p.proname LIKE 'yt\\_llm%'
                AND NOT EXISTS (SELECT 1 FROM pg_depend d
                                 WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid
                                   AND d.deptype = 'e')
    LOOP
        EXECUTE format('ALTER EXTENSION yaxaha ADD FUNCTION %s', f);
    END LOOP;
END
\$\$;
SELECT 'PASS install: ' || string_agg(p.proname, ', ' ORDER BY p.proname)
  FROM pg_proc p WHERE p.pronamespace = '$1'::regnamespace AND p.proname LIKE 'yt\\_llm%';
SQL
}

# ytserv's side: module 'C' names module 'K', module 'K' holds the values encrypted.
# Reports whether module 'C' changed, since ytserv reads it at start.
config_sql() {
    local x=$1
    cat <<SQL
SELECT md5(coalesce(string_agg(name || '=' || value, ',' ORDER BY name), '')) AS c_before
  FROM $x.yt_config WHERE module = 'C'
   AND name IN ('serve_llm', 'llm_host', 'llm_ca', 'llm_cert', 'llm_key') \\gset
BEGIN;
DELETE FROM $x.yt_config WHERE (module = 'C' AND name IN ('serve_llm', 'llm_host', 'llm_ca', 'llm_cert', 'llm_key'))
    OR (module = 'K' AND name IN ('$K_CA', '$K_CERT', '$K_KEY', 'llm.url'));
INSERT INTO $x.yt_config (name, module, value) VALUES
    ('serve_llm', 'C', 'true'),
    ('llm_host',  'C', '$LLM_HOST'),
    ('llm_ca',    'C', '$K_CA'),
    ('llm_cert',  'C', '$K_CERT'),
    ('llm_key',   'C', '$K_KEY'),
SQL
    printf "    ('%s', 'K', \$yt_llm\$%s\$yt_llm\$),\n" "$K_CA" "$CA_ENC"
    printf "    ('%s', 'K', \$yt_llm\$%s\$yt_llm\$),\n" "$K_CERT" "$CERT_ENC"
    printf "    ('%s', 'K', \$yt_llm\$%s\n\$yt_llm\$);\n" "$K_KEY" "$KEY_ENC"
    cat <<SQL
COMMIT;
SELECT CASE WHEN count(*) = 3 AND bool_and(value NOT LIKE '%-----BEGIN CERTIFICATE%'
                                           AND value NOT LIKE '%-----BEGIN PRIVATE KEY%')
            THEN 'PASS' ELSE 'FAIL' END || ' k_rows: '
       || coalesce(string_agg(name || ' (' || length(value) || ' B, encrypted)', ', ' ORDER BY name), 'none')
  FROM $x.yt_config WHERE module = 'K' AND name IN ('$K_CA', '$K_CERT', '$K_KEY');
SELECT 'PASS c_rows: ' || string_agg(name || '=' || value, ' ' ORDER BY name)
  FROM $x.yt_config WHERE module = 'C' AND name IN ('serve_llm', 'llm_host', 'llm_ca', 'llm_cert', 'llm_key');
SELECT 'INFO c_rows: changed - ytserv reads module C at start: restart it on this node'
  FROM $x.yt_config WHERE module = 'C' AND name IN ('serve_llm', 'llm_host', 'llm_ca', 'llm_cert', 'llm_key')
HAVING md5(string_agg(name || '=' || value, ',' ORDER BY name)) <> :'c_before';
SQL
}

digest_sql() {
    cat <<'SQL'
SELECT md5(string_agg(x, '|' ORDER BY x)) FROM (
    SELECT 'c' || md5(string_agg(t::text, ',' ORDER BY id)) AS x FROM shop.customers t
    UNION ALL SELECT 'p' || md5(string_agg(t::text, ',' ORDER BY id)) FROM shop.products t
    UNION ALL SELECT 'o' || md5(string_agg(t::text, ',' ORDER BY id)) FROM shop.orders t
    UNION ALL SELECT 'i' || md5(string_agg(t::text, ',' ORDER BY order_id, product_id)) FROM shop.order_items t) d;
SQL
}

# pg_temp: gone with the session, nothing left on the node
helpers_sql() {
    cat <<'SQL'
CREATE FUNCTION pg_temp.check(label text, ok boolean, detail text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    RAISE NOTICE '% %: %', CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END, label, detail;
END $f$;

-- stmt must fail, with a message matching pattern
CREATE FUNCTION pg_temp.expect(label text, stmt text, pattern text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN query_canceled OR others THEN
        RAISE NOTICE '% %: %', CASE WHEN SQLERRM ~* pattern THEN 'PASS' ELSE 'FAIL' END, label, SQLERRM;
        RETURN;
    END;
    RAISE NOTICE 'FAIL %: it ran - %', label, stmt;
END $f$;

-- a question, against a hand-written query: first a page of rows run by the
-- node (yt_llm_query, data), then yt_llm() typed the way that page describes
-- its columns. Rows compare as the sorted values of each: names and column
-- order are the model's to choose.
CREATE FUNCTION pg_temp.ask(label text, nl text, ref text, graded boolean) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE
    t0   timestamptz := clock_timestamp();
    d    json;
    defs text;
    got  text[];
    want text[];
    secs numeric;
    tag  text := CASE WHEN graded THEN 'FAIL' ELSE 'INFO' END;
    ext  text := (SELECT extnamespace::regnamespace::text FROM pg_extension WHERE extname = 'yaxaha');
BEGIN
    EXECUTE format('SELECT array_agg(s ORDER BY s) FROM (SELECT (SELECT string_agg(v, ''|'' ORDER BY v)
                      FROM json_each_text(row_to_json(t)) x(k, v)) AS s FROM (%s) t) a', ref)
       INTO want;
    BEGIN
        EXECUTE format('SELECT %s.yt_llm_query($1, 0, 1000)', ext) INTO d USING nl;
        SELECT array_agg(s ORDER BY s) INTO got
          FROM (SELECT (SELECT string_agg(v, '|' ORDER BY v) FROM json_each_text(r) x(k, v)) AS s
                  FROM json_array_elements(d->'data') r) a;
        secs := round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
        IF d->>'type' = 'data' AND got IS NOT DISTINCT FROM want
           AND (d->>'total_rows')::int = coalesce(cardinality(want), 0) THEN
            RAISE NOTICE 'PASS %.data: % rows, the same as by hand, columns % %, % s', label,
                d->>'total_rows', d->'column_names', d->'column_desc', secs;
        ELSE
            RAISE NOTICE '% %.data: not the rows by hand (% s): got % want %', tag, label, secs, got, want;
            RETURN;
        END IF;
    EXCEPTION WHEN query_canceled OR others THEN
        RAISE NOTICE '% %.data: %', tag, label, SQLERRM;
        RETURN;
    END;

    SELECT string_agg(format('%I %s', n, t), ', ' ORDER BY i) INTO defs
      FROM json_array_elements_text(d->'column_names') WITH ORDINALITY AS a(n, i)
      JOIN json_array_elements_text(d->'column_desc') WITH ORDINALITY AS b(t, j) ON i = j;
    t0 := clock_timestamp();
    BEGIN
        EXECUTE format('SELECT array_agg(s ORDER BY s) FROM (SELECT (SELECT string_agg(v, ''|'' ORDER BY v)
                          FROM json_each_text(row_to_json(t)) x(k, v)) AS s FROM %s.yt_llm($1) AS t(%s)) a',
                       ext, defs)
           INTO got USING nl;
        secs := round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
        IF got IS NOT DISTINCT FROM want THEN
            RAISE NOTICE 'PASS %.rows: yt_llm(..) AS t(%): % rows, the same as by hand, % s',
                label, defs, coalesce(cardinality(got), 0), secs;
        ELSE
            RAISE NOTICE '% %.rows: not the rows by hand (% s): got % want %', tag, label, secs, got, want;
        END IF;
        -- yt_llm ran read-only; its caller did not
        IF current_setting('transaction_read_only') = 'off' THEN
            RAISE NOTICE 'PASS %.read_write: the caller is read-write again after yt_llm()', label;
        ELSE
            RAISE NOTICE 'FAIL %.read_write: yt_llm() left the transaction read-only', label;
        END IF;
    EXCEPTION WHEN query_canceled OR others THEN
        RAISE NOTICE '% %.rows: yt_llm(..) AS t(%): %', tag, label, defs, SQLERRM;
    END;
END $f$;
SQL
}

# step 4: nothing here calls the model
offline_sql() {
    local x=$1
    helpers_sql
    cat <<SQL
SELECT pg_temp.check('install.functions',
        string_agg(p.oid::regprocedure::text || ' -> ' || pg_get_function_result(p.oid), '; ' ORDER BY p.proname)
          = 'yt_llm(text) -> SETOF record; yt_llm_query(text,integer,integer) -> json',
        string_agg(p.oid::regprocedure::text || ' -> ' || pg_get_function_result(p.oid), '; ' ORDER BY p.proname))
  FROM pg_proc p WHERE p.pronamespace = '$x'::regnamespace AND p.proname LIKE 'yt\_llm%';
-- The read-only block of yt_llm(), run on a statement we choose: a write is
-- refused inside, the rows get out, and the caller is read-write after.
SELECT pg_temp.check('yt_llm.read_only_block', prosrc LIKE '%set_config(''transaction_read_only'', ''on'', true)%'
                     AND prosrc LIKE '%RAISE SQLSTATE ''YTLLM''%', 'yt_llm() sets read-only and rolls it back')
  FROM pg_proc WHERE oid = '$x.yt_llm(text)'::regprocedure;
CREATE FUNCTION pg_temp.ro(q text) RETURNS SETOF record LANGUAGE plpgsql AS \$f\$
BEGIN
    BEGIN
        PERFORM set_config('transaction_read_only', 'on', true);
        RETURN QUERY EXECUTE q;
        RAISE SQLSTATE 'YTLLM';
    EXCEPTION WHEN SQLSTATE 'YTLLM' THEN
        NULL;
    END;
END \$f\$;
SELECT pg_temp.check('read_only.rows_out', count(*) = 3, count(*) || ' of 3 rows got out of the rolled back block')
  FROM pg_temp.ro('select generate_series(1, 3)') AS t(n int);
SELECT pg_temp.expect('read_only.write_refused',
    \$q\$SELECT * FROM pg_temp.ro('select nextval(''shop.orders_id_seq'')') AS t(n bigint)\$q\$, 'read-only transaction');
DO \$\$
BEGIN
    PERFORM count(*) FROM pg_temp.ro('select 1') AS t(n int);
    RAISE NOTICE '% read_only.caller_read_write: transaction_read_only is % after the block',
        CASE WHEN current_setting('transaction_read_only') = 'off' THEN 'PASS' ELSE 'FAIL' END,
        current_setting('transaction_read_only');
END
\$\$;
SELECT pg_temp.check('query.null', $x.yt_llm_query(NULL) IS NULL, 'no question, no call');
SELECT pg_temp.expect('query.page', \$q\$SELECT $x.yt_llm_query('x', -1)\$q\$, 'page must be 0 or more');
SELECT pg_temp.expect('query.size', \$q\$SELECT $x.yt_llm_query('x', 0, 0)\$q\$, 'size 1 or more');

-- who may call them. In a transaction that is rolled back: the role and its
-- grants are gone again after.
BEGIN;
CREATE ROLE yt_llm_probe NOLOGIN;
GRANT USAGE ON SCHEMA shop TO yt_llm_probe;
GRANT SELECT ON ALL TABLES IN SCHEMA shop TO yt_llm_probe;
SET LOCAL ROLE yt_llm_probe;
SELECT pg_temp.expect('rights.query_not_public',
    \$q\$SELECT $x.yt_llm_query('x')\$q\$, 'permission denied for function yt_llm_query');
SELECT pg_temp.expect('rights.yt_llm_needs_query',
    \$q\$SELECT * FROM $x.yt_llm('x') AS t(x int)\$q\$, 'permission denied for function yt_llm_query');
RESET ROLE;
ROLLBACK;
SQL
}

# step 5: the model
ask_sql() {
    local x=$1 first=$2
    helpers_sql
    cat <<SQL
SET search_path = shop;
SELECT CASE WHEN d->>'type' = 'data' AND json_array_length(d->'data') = 2 AND (d->>'page')::int = 1
             AND (d->>'page_size')::int = 2 AND (d->>'total_rows')::int = 6 THEN 'PASS' ELSE 'FAIL' END
       || ' llm.paging: page ' || (d->>'page') || ' of ' || (d->>'page_size') || ', '
       || json_array_length(d->'data') || ' of ' || (d->>'total_rows') || ' rows'
  FROM (SELECT $x.yt_llm_query(\$q\$$Q1\$q\$, 1, 2) AS d) q;
SELECT pg_temp.ask('llm.q1', \$q\$$Q1\$q\$, \$q\$$R1\$q\$, true);
SELECT pg_temp.ask('llm.q2', \$q\$$Q2\$q\$, \$q\$$R2\$q\$, true);
SQL
    [ "$first" = 1 ] && cat <<SQL
SELECT pg_temp.ask('llm.request_txt', \$q\$$Q3\$q\$, \$q\$$R3\$q\$, false);
SQL
}

# step 6: a cancel reaches the node. First the wait for the model: the model
# takes seconds at the least, statement_timeout fires within one. Not Q1 itself:
# with llm2's lists the node keeps an answer (llm_cache_sec), and a question
# that is always cancelled is never answered, so never kept.
cancel_model_sql() {
    local x=$1
    cat <<SQL
SET search_path = shop;
SET statement_timeout = '1s';
DO \$d\$
DECLARE
    t0 timestamptz := clock_timestamp();
BEGIN
    PERFORM $x.yt_llm_query(\$q\$$Q1 (a cancel check)\$q\$);
    RAISE NOTICE 'INFO cancel.model: the node answered within 1 s - nothing was left to cancel';
EXCEPTION WHEN query_canceled THEN
    RAISE NOTICE '% cancel.model: "%" after % s, with the model still thinking',
        CASE WHEN clock_timestamp() - t0 < interval '5 s' THEN 'PASS' ELSE 'FAIL' END,
        SQLERRM, round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
END
\$d\$;
RESET statement_timeout;
SQL
}

# Then the page the node runs. The node's statement reads shop.customers, which
# the session marked yt_llm_cancel_lock holds locked; once it waits there, the
# caller (marked yt_llm_cancel_call) is cancelled, and the node's backend must
# leave the lock wait - only the node can have cancelled it.
cancel_page_sql() {
    cat <<'SQL'
DO $d$
DECLARE
    t0     timestamptz := clock_timestamp();
    page   int;
    caller int;
    seen   boolean := false;
    secs   numeric;
BEGIN
    -- the caller's session starts in the background: it counts as ended only
    -- once it has been seen
    LOOP
        PERFORM pg_stat_clear_snapshot();
        SELECT pid INTO caller FROM pg_stat_activity WHERE datname = current_database()
           AND state = 'active' AND query LIKE '%yt_llm_cancel_call%' AND pid <> pg_backend_pid();
        SELECT pid INTO page FROM pg_stat_activity WHERE datname = current_database()
           AND wait_event_type = 'Lock' AND query LIKE 'SELECT * FROM (%' AND pid <> pg_backend_pid();
        seen := seen OR caller IS NOT NULL;
        EXIT WHEN page IS NOT NULL OR (seen AND caller IS NULL)
               OR clock_timestamp() - t0 > CASE WHEN seen THEN interval '300 s' ELSE interval '60 s' END;
        PERFORM pg_sleep(0.5);
    END LOOP;
    IF page IS NULL OR caller IS NULL THEN
        RAISE NOTICE 'FAIL cancel.page: no statement of the node waited behind the lock within % s (the caller %)',
            round(extract(epoch FROM clock_timestamp() - t0)::numeric),
            CASE WHEN NOT seen THEN 'never started'
                 WHEN caller IS NULL THEN 'ended first - did the model''s statement read shop.customers?'
                 ELSE 'still waits' END;
    ELSE
        PERFORM pg_cancel_backend(caller);
        t0 := clock_timestamp();
        LOOP
            PERFORM pg_stat_clear_snapshot();
            EXIT WHEN NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = page AND wait_event_type = 'Lock')
                   OR clock_timestamp() - t0 > interval '15 s';
            PERFORM pg_sleep(0.2);
        END LOOP;
        secs := round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
        PERFORM pg_stat_clear_snapshot();
        IF EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = page AND wait_event_type = 'Lock') THEN
            RAISE NOTICE 'FAIL cancel.page: the node''s statement (pid %) still waits % s after its caller was cancelled', page, secs;
        ELSE
            RAISE NOTICE 'PASS cancel.page: its caller cancelled, the node''s statement (pid %) was cancelled % s later', page, secs;
        END IF;
    END IF;
    -- and the lock goes with the session that holds it
    PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database()
       AND query LIKE '%yt_llm_cancel_lock%' AND pid <> pg_backend_pid();
END
$d$;
SQL
}

# ytserv's [llm] log lines on a node (YT_LOG)
node_log() {
    $YT_SSH "$(node_ssh "$1")" "$YT_LOG" 2>/dev/null
}

cancel_step() {
    local n=$1 x=$2 log0 log1 have lock_out call_out lock_job call_job
    log0=$(node_log "$n") && have=1 || have=0

    tally "$n" <<< "$(cancel_model_sql "$x" | node_sql "$n" 0)"

    lock_out=$(mktemp) call_out=$(mktemp)
    node_sql "$n" 0 > "$lock_out" <<SQL &
BEGIN;
LOCK TABLE shop.customers IN ACCESS EXCLUSIVE MODE;
SELECT /* yt_llm_cancel_lock */ pg_sleep(600);
ROLLBACK;
SQL
    lock_job=$!
    sleep 2
    node_sql "$n" 0 > "$call_out" <<SQL &
SET search_path = shop;
SELECT /* yt_llm_cancel_call */ $x.yt_llm_query(\$q\$$Q1\$q\$, 0, 10);
SQL
    call_job=$!
    tally "$n" <<< "$(cancel_page_sql | node_sql "$n" 0)"
    # whatever the check above got to: neither session outlives it
    node_sql "$n" 0 > /dev/null <<'SQL'
SELECT pg_cancel_backend(pid) FROM pg_stat_activity
 WHERE query LIKE '%yt_llm_cancel_call%' AND pid <> pg_backend_pid();
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE query LIKE '%yt_llm_cancel_lock%' AND pid <> pg_backend_pid();
SQL
    wait "$call_job" "$lock_job"
    check "$n" cancel.caller "$(grep -q 'canceling statement due to user request' "$call_out" && echo 1 || echo 0)" \
        "$(grep -m1 -E 'ERROR|\{' "$call_out" | cut -c1-160)"
    rm -f "$lock_out" "$call_out"

    if [ "$have" = 1 ] && log1=$(node_log "$n") && grep -q '\[llm\]' <<< "$log1"; then
        check "$n" cancel.log.model "$([ "$(grep -c 'the caller cancelled: hanging up' <<< "$log1")" -gt \
            "$(grep -c 'the caller cancelled: hanging up' <<< "$log0")" ] && echo 1 || echo 0)" \
            "$(grep 'the caller cancelled: hanging up' <<< "$log1" | tail -1 | cut -c1-160)"
        check "$n" cancel.log.page "$([ "$(grep -c 'the caller cancelled: cancelling the page' <<< "$log1")" -gt \
            "$(grep -c 'the caller cancelled: cancelling the page' <<< "$log0")" ] && echo 1 || echo 0)" \
            "$(grep 'the caller cancelled: cancelling the page' <<< "$log1" | tail -1 | cut -c1-160)"
    else
        say "  $n  INFO cancel.log: no [llm] lines in ytserv's log here (YT_LOG: $YT_LOG)"
    fi
}

# the dist file for a node: its PostgreSQL major, the newest glibc not above its own
pick_so() {
    local dir=$1 major=$2 glibc=$3 f t best="" bt=0
    for f in "$dir"/yaxaha*-pg"$major"-glibc*.so; do
        [ -f "$f" ] || continue
        t=${f##*-glibc}; t=${t%.so}; t=${t/_/.}
        [ "$(printf '%s\n%s\n' "$t" "$glibc" | sort -V | tail -1)" = "$glibc" ] || continue
        [ "$(printf '%s\n%s\n' "$t" "$bt" | sort -V | tail -1)" = "$t" ] && { best=$f; bt=$t; }
    done
    say "$best"
}

deploy() {
    local n=$1 ssh lib so major glibc tmp out
    ssh=$(node_ssh "$n")
    lib=$(node_sql "$n" <<< "SELECT setting FROM pg_config WHERE name = 'PKGLIBDIR'")
    so=$DEPLOY
    if [ -d "$DEPLOY" ]; then
        major=$(node_sql "$n" <<< "SELECT current_setting('server_version_num')::int / 10000")
        glibc=$($YT_SSH "$ssh" "ldd --version | head -1" | awk '{print $NF}')
        so=$(pick_so "$DEPLOY" "$major" "$glibc")
        [ -n "$so" ] || { check "$n" deploy 0 "no yaxaha*-pg$major-glibc*.so for glibc $glibc in $DEPLOY"; return; }
    fi
    tmp=/tmp/yaxaha.so.$$
    out=$($YT_SSH "$ssh" "cat > $tmp" < "$so" && $YT_SSH "$ssh" "set -e
        sudo -n install -m 0755 $tmp $lib/yaxaha.so.new
        sudo -n cp -p $lib/yaxaha.so $lib/yaxaha.so.bak-\$(date +%Y%m%d%H%M%S)
        sudo -n mv -f $lib/yaxaha.so.new $lib/yaxaha.so
        rm -f $tmp
        md5sum $lib/yaxaha.so" 2>&1)
    check "$n" deploy "$([ "${out%% *}" = "$(md5sum < "$so" | cut -d' ' -f1)" ] && echo 1 || echo 0)" \
        "$(basename "$so") -> $lib/yaxaha.so"
}

# ── [llm2] step 7 ─────────────────────────────────────────────────────────────

# module 'K' row clickhouse for the ch target, module 'C' for the df target and
# the models; reports a module 'C' change (module 'K' is read on every call)
llm2_config_sql() {
    local x=$1 rows=()
    [ -n "${YT_DF_PYTHON:-}" ] && rows+=("('llm_df_python', 'C', '$YT_DF_PYTHON')" "('llm_df_tables', 'C', '$YT_DF_TABLES')")
    [ -n "${YT_MODEL_ROUTE:-}" ] && rows+=("('llm_model_route', 'C', '$YT_MODEL_ROUTE')")
    [ -n "${YT_MODEL_CH:-}" ] && rows+=("('llm_model_ch', 'C', '$YT_MODEL_CH')")
    cat <<SQL
SELECT md5(coalesce(string_agg(name || '=' || value, ',' ORDER BY name), '')) AS c_before
  FROM $x.yt_config WHERE module = 'C' AND name IN ($LLM2_C) \\gset
BEGIN;
DELETE FROM $x.yt_config WHERE (module = 'C' AND name IN ($LLM2_C, $LLM2_OLD_C))
    OR (module = 'K' AND name IN ('clickhouse', 'llm.ch'));
SQL
    [ ${#rows[@]} -gt 0 ] && echo "INSERT INTO $x.yt_config (name, module, value) VALUES $(IFS=,; echo "${rows[*]}");"
    [ -n "$CH_ENC" ] && printf "INSERT INTO %s.yt_config (name, module, value) VALUES ('clickhouse', 'K', \$yt_llm\$%s\$yt_llm\$);\n" "$x" "$CH_ENC"
    cat <<SQL
COMMIT;
SELECT CASE WHEN value NOT LIKE '%password_ro%' THEN 'PASS' ELSE 'FAIL' END || ' k_clickhouse: clickhouse ('
       || length(value) || ' B, encrypted)'
  FROM $x.yt_config WHERE module = 'K' AND name = 'clickhouse';
SELECT 'PASS c_rows2: ' || string_agg(name || '=' || value, ' ' ORDER BY name)
  FROM $x.yt_config WHERE module = 'C' AND name IN ($LLM2_C);
SELECT 'INFO c_rows2: changed' FROM $x.yt_config WHERE module = 'C' AND name IN ($LLM2_C)
HAVING md5(string_agg(name || '=' || value, ',' ORDER BY name)) <> :'c_before';
SQL
}

# rows a hand-written query gives, as ClickHouse prints them (TSV)
ch_hand() {
    printf '%s FORMAT TSV\n' "$1" | $YT_CH_CLIENT 2>&1
}

llm2_helpers_sql() {
    cat <<'SQL'
-- rows as sorted value strings: from a PostgreSQL query, from ClickHouse's TSV
CREATE FUNCTION pg_temp.want_sql(ref text) RETURNS text[] LANGUAGE plpgsql AS $f$
DECLARE w text[];
BEGIN
    EXECUTE format('SELECT array_agg(s ORDER BY s) FROM (SELECT (SELECT string_agg(v, ''|'' ORDER BY v)
                      FROM json_each_text(row_to_json(t)) x(k, v)) AS s FROM (%s) t) a', ref) INTO w;
    RETURN w;
END $f$;
CREATE FUNCTION pg_temp.want_tsv(tsv text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT array_agg(s ORDER BY s) FROM (
        SELECT (SELECT string_agg(v, '|' ORDER BY v) FROM unnest(string_to_array(line, E'\t')) v) AS s
          FROM unnest(string_to_array(tsv, E'\n')) line WHERE line <> '') a
$f$;

-- a question the node answers from `engine`: the statement's type (and for df
-- its script and plan), a page of rows read there - the statement kept, not
-- asked again - and yt_llm(), typed by that page
CREATE FUNCTION pg_temp.ask2(label text, nl text, engine text, want text[]) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE
    t0   timestamptz := clock_timestamp();
    s    json;
    d    json;
    got  text[];
    defs text;
    secs numeric;
    ext  text := (SELECT extnamespace::regnamespace::text FROM pg_extension WHERE extname = 'yaxaha');
BEGIN
    BEGIN
        EXECUTE format('SELECT %s.yt_llm_query($1)', ext) INTO s USING nl;
    EXCEPTION WHEN query_canceled OR others THEN
        RAISE NOTICE 'FAIL %.type: %', label, SQLERRM;
        RETURN;
    END;
    secs := round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
    RAISE NOTICE '%', format('%s %s.type: %s in %s s: %s%s', CASE WHEN s->>'type' = engine THEN 'PASS' ELSE 'FAIL' END,
        label, s->>'type', secs, replace(s->>'sql', E'\n', ' '), coalesce(' - notes ' || (s->'notes')::text, ''));
    IF s->>'type' IS DISTINCT FROM engine THEN
        RETURN;
    END IF;
    IF engine = 'df' THEN
        RAISE NOTICE '%', format('%s %s.script: %s table(s), %s partitions in the plan, CREATE EXTERNAL TABLE %s',
            CASE WHEN s->>'script' LIKE '%CREATE EXTERNAL TABLE%' AND json_array_length(s->'plan'->'tables') > 0
                 THEN 'PASS' ELSE 'FAIL' END, label, json_array_length(s->'plan'->'tables'),
            (SELECT sum(json_array_length(t->'parts')) FROM json_array_elements(s->'plan'->'tables') t),
            CASE WHEN s->>'script' LIKE '%CREATE EXTERNAL TABLE%' THEN 'in the script' ELSE 'missing' END);
    END IF;

    t0 := clock_timestamp();
    BEGIN
        EXECUTE format('SELECT %s.yt_llm_query($1, 0, 1000)', ext) INTO d USING nl;
        SELECT array_agg(x ORDER BY x) INTO got
          FROM (SELECT (SELECT string_agg(v, '|' ORDER BY v) FROM json_each_text(r) e(k, v)) AS x
                  FROM json_array_elements(d->'data') r) a;
        secs := round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
        IF d->>'type' = 'data' AND d->>'engine' = engine AND got IS NOT DISTINCT FROM want THEN
            RAISE NOTICE 'PASS %.data: % rows read by %, the same as by hand, columns % %, % s', label,
                d->>'total_rows', engine, d->'column_names', d->'column_desc', secs;
        ELSE
            RAISE NOTICE 'FAIL %.data: engine %, % s: got % want %', label, d->>'engine', secs, got, want;
            RETURN;
        END IF;
    EXCEPTION WHEN query_canceled OR others THEN
        RAISE NOTICE 'FAIL %.data: %', label, SQLERRM;
        RETURN;
    END;

    SELECT string_agg(format('%I %s', n, t), ', ' ORDER BY i) INTO defs
      FROM json_array_elements_text(d->'column_names') WITH ORDINALITY AS a(n, i)
      JOIN json_array_elements_text(d->'column_desc') WITH ORDINALITY AS b(t, j) ON i = j;
    t0 := clock_timestamp();
    BEGIN
        EXECUTE format('SELECT array_agg(s ORDER BY s) FROM (SELECT (SELECT string_agg(v, ''|'' ORDER BY v)
                          FROM json_each_text(row_to_json(t)) x(k, v)) AS s FROM %s.yt_llm($1) AS t(%s)) a',
                       ext, defs)
           INTO got USING nl;
        secs := round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
        RAISE NOTICE '% %.rows: yt_llm(..) AS t(%): % rows, % s', CASE WHEN got IS NOT DISTINCT FROM want
            THEN 'PASS' ELSE 'FAIL' END, label, defs, coalesce(cardinality(got), 0), secs;
    EXCEPTION WHEN query_canceled OR others THEN
        RAISE NOTICE 'FAIL %.rows: yt_llm(..) AS t(%): %', label, defs, SQLERRM;
    END;
END $f$;
SQL
}

llm2_ask_sql() {
    local x=$1
    llm2_helpers_sql
    say "SET search_path = shop, public;"
    if [ -n "${YT_CH_URL:-}" ]; then
        cat <<SQL
SELECT pg_temp.ask2('llm2.ch1', \$q\$$QC1\$q\$, 'ch', pg_temp.want_tsv(\$t\$$(ch_hand "$RC1")\$t\$));
SELECT pg_temp.ask2('llm2.ch2', \$q\$$QC2\$q\$, 'ch', pg_temp.want_tsv(\$t\$$(ch_hand "$RC2")\$t\$));
SELECT pg_temp.ask2('llm2.both', \$q\$$QS1\$q\$, 'sql', pg_temp.want_sql(\$q\$$RS1\$q\$));
SQL
    fi
    if [ -n "${YT_DF_PYTHON:-}" ]; then
        cat <<SQL
SELECT pg_temp.ask2('llm2.df1', \$q\$$QD1\$q\$, 'df', pg_temp.want_sql(\$q\$$RD1\$q\$));
SELECT pg_temp.ask2('llm2.df2', \$q\$$QD2\$q\$, 'df', pg_temp.want_sql(\$q\$$RD2\$q\$));
SQL
    fi
}

# a df answer cancelled while it copies: its partition COPY waits behind a lock
# on shop.products; once it does, its caller is cancelled, and the COPY must go
cancel_df_step() {
    local n=$1 x=$2 log0 log1 have lock_out call_out lock_job call_job
    log0=$(node_log "$n") && have=1 || have=0
    lock_out=$(mktemp) call_out=$(mktemp)
    node_sql "$n" 0 > "$lock_out" <<SQL &
BEGIN;
LOCK TABLE shop.products IN ACCESS EXCLUSIVE MODE;
SELECT /* yt_llm_cancel_lock */ pg_sleep(600);
ROLLBACK;
SQL
    lock_job=$!
    sleep 2
    node_sql "$n" 0 > "$call_out" <<SQL &
SET search_path = shop, public;
SELECT /* yt_llm_cancel_call */ $x.yt_llm_query(\$q\$$QD1\$q\$, 0, 10);
SQL
    call_job=$!
    tally "$n" <<< "$(cancel_page_sql | sed "s/'SELECT \* FROM (%'/'COPY (SELECT %'/; s/cancel\.page/cancel.df_copy/g; \
        s/did the model''s statement read shop.customers?/did the df answer read shop.products?/" | node_sql "$n" 0)"
    node_sql "$n" 0 > /dev/null <<'SQL'
SELECT pg_cancel_backend(pid) FROM pg_stat_activity
 WHERE query LIKE '%yt_llm_cancel_call%' AND pid <> pg_backend_pid();
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE query LIKE '%yt_llm_cancel_lock%' AND pid <> pg_backend_pid();
SQL
    wait "$call_job" "$lock_job"
    check "$n" cancel.df_caller "$(grep -q 'canceling statement due to user request' "$call_out" && echo 1 || echo 0)" \
        "$(grep -m1 -E 'ERROR|\{' "$call_out" | cut -c1-160)"
    rm -f "$lock_out" "$call_out"
    if [ "$have" = 1 ] && log1=$(node_log "$n") && grep -q '\[llm\]' <<< "$log1"; then
        check "$n" cancel.log.df "$([ "$(grep -c 'cancelling the df partition copy' <<< "$log1")" -gt \
            "$(grep -c 'cancelling the df partition copy' <<< "$log0")" ] && echo 1 || echo 0)" \
            "$(grep 'cancelling the df partition copy' <<< "$log1" | tail -1 | cut -c1-160)"
    fi
}

# ytserv reads module 'C' at start
restart_node() {
    if [ -n "${YT_RESTART:-}" ]; then
        $YT_SSH "$(node_ssh "$1")" "$YT_RESTART" > /dev/null 2>&1
        sleep 3
        say "  $1  INFO restart: ytserv restarted (YT_RESTART) to read module C"
    else
        say "  $1  INFO restart: set YT_RESTART, or restart ytserv on this node - it reads module C at start"
    fi
}

# a replicated yt_config takes the rows once, on the first node (as step 2)
# a ch answer cancelled mid-read: statement_timeout on a count over a hundred
# billion rows; ClickHouse must have no query of the user left moments later
cancel_ch_step() {
    local n=$1 x=$2 log0 log1 have t left
    [ "$(ch_hand "SELECT count() FROM system.tables WHERE database = 'default' AND name = 'big_numbers'")" = 1 ] || {
        say "  $n  INFO cancel.ch: no view default.big_numbers in ClickHouse - skipped"; return; }
    log0=$(node_log "$n") && have=1 || have=0
    t=$(node_sql "$n" 0 <<SQL
SET search_path = shop, public;
SELECT CASE WHEN d->>'type' = 'ch' THEN 'PASS' ELSE 'FAIL' END || ' cancel.ch_statement: ' || (d->>'type') || ' '
       || coalesce(d->>'sql', '')
  FROM (SELECT $x.yt_llm_query(\$q\$$QX\$q\$) AS d) q;
SQL
)
    tally "$n" <<< "$t"
    [[ "$t" == PASS* ]] || return
    tally "$n" <<< "$(node_sql "$n" 0 <<SQL
SET search_path = shop, public;
SET statement_timeout = '4s';
DO \$d\$
DECLARE
    t0 timestamptz := clock_timestamp();
BEGIN
    PERFORM $x.yt_llm_query(\$q\$$QX\$q\$, 0, 10);
    RAISE NOTICE 'INFO cancel.ch: ClickHouse answered within 4 s - nothing was left to cancel';
EXCEPTION WHEN query_canceled THEN
    RAISE NOTICE 'PASS cancel.ch_caller: "%" after % s, with ClickHouse still reading', SQLERRM,
        round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
END
\$d\$;
SQL
)"
    sleep 3
    left=$(ch_hand "SELECT count() FROM ${YT_CH_PROCESSES:-system.processes} WHERE user = '$YT_CH_USER' AND query LIKE '%big_numbers%'")
    check "$n" cancel.ch_gone "$([ "$left" = 0 ] && echo 1 || echo 0)" \
        "$left queries of $YT_CH_USER on big_numbers still run in ClickHouse 3 s after the cancel"
    if [ "$have" = 1 ] && log1=$(node_log "$n") && grep -q '\[llm\]' <<< "$log1"; then
        check "$n" cancel.log.ch "$([ "$(grep -c 'killing ClickHouse query' <<< "$log1")" -gt \
            "$(grep -c 'killing ClickHouse query' <<< "$log0")" ] && echo 1 || echo 0)" \
            "$(grep 'killing ClickHouse query' <<< "$log1" | tail -1 | cut -c1-160)"
    fi
}

llm2_step() {
    local n=$1 x=$2 synced=$3 first=$4 out changed=0
    if [ "$synced" = 0 ] || [ "$first" = 1 ]; then
        out=$(llm2_config_sql "$x" | node_sql "$n")
        tally "$n" <<< "$out"
        if grep -q 'c_rows2: changed' <<< "$out"; then
            changed=1
            [ "$synced" = 0 ] || C2_CHANGED=1
        fi
    else
        sleep 5
        say "  $n  INFO config2: yt_config is replicated here, written once on the first node"
    fi
    [ "$changed" = 1 ] || { [ "$synced" != 0 ] && [ "$C2_CHANGED" = 1 ]; } && restart_node "$n"
    tally "$n" <<< "$(llm2_ask_sql "$x" | node_sql "$n" 0)"
    [ -n "${YT_DF_PYTHON:-}" ] && cancel_df_step "$n" "$x"
    [ -n "${YT_CH_URL:-}" ] && cancel_ch_step "$n" "$x"
}

# ── run ────────────────────────────────────────────────────────────────────────

declare -A DIGEST=() SQLMD5=()
first=1
C_CHANGED=0
C2_CHANGED=0
for n in "${NODES[@]}"; do
    say "== $n"
    [ -n "$DEPLOY" ] && deploy "$n"

    x=$(node_sql "$n" <<< "SELECT extnamespace::regnamespace FROM pg_extension WHERE extname = 'yaxaha'")
    if ! [[ "$x" =~ ^[a-z_][a-z0-9_]*$ ]]; then
        check "$n" extension 0 "no yaxaha extension in $(node_db "$n"): $x"
        continue
    fi
    tally "$n" <<< "$(node_sql "$n" <<< "SELECT 'INFO node: PostgreSQL ' || current_setting('server_version')
        || ', yaxaha ' || extversion || ' in schema $x of ' || current_database() FROM pg_extension WHERE extname = 'yaxaha'")"

    # 1
    tally "$n" <<< "$(install_sql "$x" | node_sql "$n")"

    # 2 - a replicated yt_config takes the rows once, and the rest must see them
    synced=$(node_sql "$n" <<< "SELECT count(*) FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE t.tgrelid = '$x.yt_config'::regclass AND p.proname = 'yt_synchronize'")
    [[ "$synced" =~ ^[0-9]+$ ]] || synced=0
    changed=0
    if [ "$synced" = 0 ] || [ "$first" = 1 ]; then
        out=$(config_sql "$x" | node_sql "$n")
        tally "$n" <<< "$out"
        if grep -q 'c_rows: changed' <<< "$out"; then
            changed=1
            [ "$synced" = 0 ] || C_CHANGED=1
        fi
    else
        for _ in $(seq 30); do
            [ "$(node_sql "$n" <<< "SELECT count(*) FROM $x.yt_config WHERE module = 'K'
                AND name IN ('$K_CA', '$K_CERT', '$K_KEY')")" = 3 ] && break
            sleep 1
        done
        say "  $n  INFO config: yt_config is replicated here, written once on the first node"
    fi
    [ "$changed" = 1 ] || { [ "$synced" != 0 ] && [ "$C_CHANGED" = 1 ]; } && restart_node "$n"

    # 3
    out=$(node_sql "$n" < "$HERE/sample_data.sql")
    if grep -q '^ERROR:' <<< "$out"; then
        tally "$n" <<< "$out"
    else
        say "  $n  INFO data: $(grep '|' <<< "$out" | tr '\n' ' ')"
    fi
    DIGEST[$n]=$(digest_sql | node_sql "$n")

    # 4
    tally "$n" <<< "$(offline_sql "$x" | node_sql "$n" 0)"

    # 5
    if [ "$ASK" = 1 ]; then
        # the first call: the statement, and on the way everything the node needs
        t=$(node_sql "$n" <<SQL
\\set VERBOSITY default
SET search_path = shop;
SELECT CASE WHEN d->>'type' = 'sql' AND d->>'sql' ~* '^\s*(select|with)\M' THEN 'PASS' ELSE 'FAIL' END
       || ' llm.sql: md5 ' || md5(d->>'sql') || ' ' || replace(d->>'sql', E'\n', ' ')
  FROM (SELECT $x.yt_llm_query(\$q\$$Q1\$q\$) AS d) q;
SQL
)
        tally "$n" <<< "$t"
        SQLMD5[$n]=$(sed -n 's/.*PASS llm.sql: md5 \([0-9a-f]*\) .*/\1/p' <<< "$t")
        if [[ "$t" == PASS* ]]; then
            tally "$n" <<< "$(ask_sql "$x" "$first" | node_sql "$n" 0)"
            # 6
            cancel_step "$n" "$x"
            # 7
            [ "$LLM2" = 1 ] && llm2_step "$n" "$x" "$synced" "$first"
        else
            say "  $n  INFO the other questions are skipped here: they would fail the same way"
        fi
    fi
    first=0
done

if [ ${#NODES[@]} -gt 1 ]; then
    say "== across nodes"
    d=$(printf '%s\n' "${DIGEST[@]}" | sort -u)
    check all same_data "$([ "$(wc -l <<< "$d")" = 1 ] && [ -n "$d" ] && echo 1 || echo 0)" \
        "schema shop digest $(tr '\n' ' ' <<< "$d")on ${#DIGEST[@]} nodes"
    if [ ${#SQLMD5[@]} -gt 1 ]; then
        # the same catalog on every node, so the same prompt, so - at temperature
        # 0.1 - the same statement
        r=$(printf '%s\n' "${SQLMD5[@]}" | sort -u)
        say "  all  INFO same_sql: statement md5 $(tr '\n' ' ' <<< "$r")on ${#SQLMD5[@]} nodes"
    fi
fi

say "== $PASSED PASS, $FAILED FAIL"
[ "$FAILED" = 0 ]
