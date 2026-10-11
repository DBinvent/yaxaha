#!/usr/bin/env bash
# Shared by build.sh, up.sh, test.sh and down.sh. Source, do not execute.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/run"   # this run's state: who is a member where, the writers' logs
mkdir -p "$RUN"

# Settings: .env next to this file (not committed, see env.example). A variable
# already set in the environment wins over .env.
if [ -f "$HERE/.env" ]; then
    _pre="$(export -p)"
    set -a; . "$HERE/.env"; set +a
    eval "$_pre"
    unset _pre
fi
# the docker daemon to run on: RMC_DOCKER_HOST, when set, over the shell's DOCKER_HOST
[ -n "${RMC_DOCKER_HOST:-}" ] && export DOCKER_HOST="$RMC_DOCKER_HOST"

YAXAHA_DEB=${YAXAHA_DEB:-}
# How long one step may take to settle, in seconds: a new node to follow, a
# leader to be elected, members to converge.
RMC_WAIT=${RMC_WAIT:-180}
# The writers' pause between two transactions, in milliseconds. This is a load to
# change the cluster under, not a benchmark.
RMC_TX_MS=${RMC_TX_MS:-200}
# Where the writers send: `all` (every member in turn) or `leader` (each cluster's
# current leader). See plan.md, "The load".
RMC_ORIGIN=${RMC_ORIGIN:-all}
# How a node added at runtime gets the cluster's data: `clone` (a physical copy of
# a member, ytserv's documented expansion path) or `empty` (no data and no
# position: what ytserv does for a node that starts from nothing).
RMC_JOIN=${RMC_JOIN:-clone}
# ytserv's log level on every node: info, or debug to diagnose a step
RMC_LOG_LEVEL=${RMC_LOG_LEVEL:-info}
# The docker network's /24, private to the test. Every node gets a fixed address
# in it, so a retired node's address is never handed to a new one: the clusters
# resolve a roster name once, and a reused address would make a stopped node
# answer pings as somebody else.
RMC_SUBNET=${RMC_SUBNET:-10.231.7}

DB=rmc
CFG=public.yt_config
PORT=7421
IMAGE=rmc-node
NET=rmc
LOAD=load
# the namespace yxctl's --peers roster derives node uuids in: uuid5(ns, host name)
YAXAHA_NS=6a9f5c2e-1b3d-5e47-9a08-0bf99b3e0275

CLUSTERS=(upper east west)
declare -A AZ=([upper]=top [east]=eastc [west]=westc)
declare -A TIER=([top]=0 [eastc]=1 [westc]=1)
# fixed, so a log line from one run can be found in another
declare -A CUUID=(
    [upper]=aaaaaaaa-aaaa-5aaa-8aaa-aaaaaaaaaaaa
    [east]=bbbbbbbb-bbbb-5bbb-8bbb-bbbbbbbbbbbb
    [west]=cccccccc-cccc-5ccc-8ccc-cccccccccccc
)
declare -A START=([upper]="u1 u2 u3" [east]="a1 a2 a3 a4" [west]="b1 b2 b3 b4")
# each cluster's writer has its own id range in rmc_ledger: a row of one range
# found in another cluster has crossed a boundary
ID_SPAN=1000000000000
declare -A ID_BASE=([upper]=1000000000000 [east]=2000000000000 [west]=3000000000000)
# placeholder sign-in keys: the upper cluster holds one per child cluster. Nothing
# verifies a signature yet; what is tested is that a key, and no address, is held.
declare -A SIGNIN=([eastc]=eastc-signin-key-placeholder [westc]=westc-signin-key-placeholder)

say() { printf '%s\n' "$*"; }
die() { say "== STOP: $*" >&2; exit 1; }
now() { date -u +%H:%M:%S; }

cname() { echo "rmc-$1"; }
cluster_of() { case "$1" in u*) echo upper;; a*) echo east;; b*) echo west;; *) return 1;; esac; }
# u1..u9 -> .11-.19, a1..a9 -> .21-.29, b1..b9 -> .31-.39, the load client .5
node_ip() {
    case "$1" in
        u*) echo "$RMC_SUBNET.$((10 + ${1#u}))";;
        a*) echo "$RMC_SUBNET.$((20 + ${1#a}))";;
        b*) echo "$RMC_SUBNET.$((30 + ${1#b}))";;
        "$LOAD") echo "$RMC_SUBNET.5";;
    esac
}
node_uuid() { python3 -c 'import sys, uuid; print(uuid.uuid5(uuid.UUID(sys.argv[1]), sys.argv[2]))' "$YAXAHA_NS" "$1"; }
# the short form ytserv prints and matches (node_run, yt_info('e:...')): XX..YYYYYY
node_u8() { local u; u=$(node_uuid "$1"); echo "${u:0:2}..${u:30}"; }

# ── membership, as this run knows it ─────────────────────────────────────────
# run/members.<cluster>: the nodes that are in the cluster now (joined, not
# retired). The writers get their own copy, without a node that is still joining.
members() { echo $(cat "$RUN/members.$1" 2>/dev/null); }
set_members() { local c="$1"; shift; printf '%s\n' "$@" | grep -v '^$' > "$RUN/members.$c"; }
add_member() { local c="$1" n="$2"; set_members "$c" $(members "$c") "$n"; }
del_member() { local c="$1" n="$2" m out=(); for m in $(members "$c"); do [ "$m" = "$n" ] || out+=("$m"); done; set_members "$c" "${out[@]}"; }
# the nodes a cluster holds an address for, besides its own: the clusters it dials
linked() {
    case "$1" in
        upper) echo "";;
        east) echo "$(members upper) $(members west)";;
        west) echo "$(members upper) $(members east)";;
    esac
}

# ── docker ───────────────────────────────────────────────────────────────────
net_up() {
    docker network inspect "$NET" >/dev/null 2>&1 \
        || docker network create --subnet "$RMC_SUBNET.0/24" "$NET" >/dev/null
}
node_run() { # node_run <name> [clone-from]
    local n="$1" from="${2:-}" k
    k=$(node_ip "$n"); k=${k##*.}
    docker rm -f "$(cname "$n")" >/dev/null 2>&1
    docker run -d --name "$(cname "$n")" --hostname "$n" --network "$NET" --ip "$(node_ip "$n")" \
        --network-alias "$n" -e NODE_UUID="$(node_uuid "$n")" -e DB="$DB" \
        -e CLONE_FROM="$from" -e SEQ_K="$k" "$IMAGE" >/dev/null
}
load_run() {
    docker rm -f "$(cname "$LOAD")" >/dev/null 2>&1
    docker run -d --name "$(cname "$LOAD")" --hostname "$LOAD" --network "$NET" --ip "$(node_ip "$LOAD")" \
        --entrypoint /bin/sleep "$IMAGE" infinity >/dev/null || return 1
    docker exec "$(cname "$LOAD")" mkdir -p /load
    docker cp "$HERE/load/writer.sh" "$(cname "$LOAD"):/load/writer.sh" >/dev/null
}
cluster_rm() {
    local c
    for c in $(docker ps -aq --filter "name=^rmc-"); do docker rm -f "$c" >/dev/null 2>&1; done
    docker network rm "$NET" >/dev/null 2>&1
    true
}

# psql on a node as postgres, SQL on stdin. Bounded: a statement that blocks fails
# instead of hanging the run (an orphaned prepared transaction holds its locks).
q() { # q <node> [psql args...]   (QT: seconds before giving up, default 120)
    local n="$1"; shift
    timeout "${QT:-120}" docker exec -i -u postgres -e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=60s' \
        "$(cname "$n")" psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"
}
# one cluster write on a node: begin; <sql>; yt_complete; commit. Prints psql's
# error, if any, and returns its status.
cwrite() { # cwrite <node> <sql>
    q "$1" -c "begin" -c "$2" -c "select yt_complete(true)" -c "commit" 2>&1 >/dev/null
}

# one value of yt_info
# A node whose request loop is blocked never answers yt_info: give up after 20s.
info() { # info <node> <letters> <name>
    QT=20 q "$1" <<< "select value from json_to_recordset(yt_info('$2')) as x(name text, value text, module text) where name = '$3'" 2>/dev/null
}
# state|term|leader-uuid|cluster-line of a node, from one yt_info('E')
node_status() {
    QT=20 q "$1" 2>/dev/null <<'SQL'
with e as (select * from json_to_recordset(yt_info('E')) as x(name text, value text, module text))
select coalesce((select split_part(v.value, ', ', 2) from e v, e s where s.name = 'self' and v.name = s.value), '')
    || '|' || coalesce((select value from e where name = 'term'), '')
    || '|' || coalesce((select value from e where name = 'leader'), '')
    || '|' || coalesce((select value from e where name = 'cluster'), '')
SQL
}
node_state() { node_status "$1" | cut -d'|' -f1; }
node_term() { node_status "$1" | cut -d'|' -f2; }

# The node that leads a cluster: the member that reports itself Leader. Empty if
# none does. Asks every member rather than trusting one member's pointer, which
# can name a node that has stepped down.
leader_of() { # leader_of <cluster>
    local n
    for n in $(members "$1"); do
        [ "$(node_state "$n")" = Leader ] && { echo "$n"; return 0; }
    done
    return 0
}

# wait_for <seconds> <command...>: until the command succeeds; returns 1 on timeout
wait_for() {
    local secs="$1"; shift
    local t=0
    until "$@" >/dev/null 2>&1; do
        t=$((t + 3)); [ "$t" -ge "$secs" ] && return 1
        sleep 3
    done
}

# ── config rows ──────────────────────────────────────────────────────────────
enc() { docker run --rm --entrypoint /usr/local/bin/yxctl "$IMAGE" --encode-table-cfg "$1" 2>/dev/null | tail -1 | tr -d '\r'; }

# The cluster's config rows: the same rows, with the same ids, on every member.
# The ids matter because yt_config is itself synced: a row written later on the
# leader carries the leader's id to every member, and a member whose own serial
# had already used it would refuse the row (each node's serial gets its own
# residue below, so new rows never collide).
cfg_sql() { # cfg_sql <cluster>
    local c="$1" id=0 p ex lvl hosts h oaz
    row() { id=$((id + 1)); printf "insert into %s (id, name, module, value) values (%d, '%s', '%s', '%s');\n" "$CFG" "$id" "$1" "$2" "$3"; }
    echo "begin;"
    # the config table's own sync trigger must not fire: ytserv is not running yet
    echo "set local session_replication_role = replica;"
    echo "delete from $CFG;"
    # N: the members, and the nodes of the clusters this one dials
    for p in $(members "$c") $(linked "$c"); do row "$(node_uuid "$p")" N "$p:$PORT"; done
    # C
    row min_cluster_size C 2
    row tcp_timeout_ms C 2000
    row log_level C "$RMC_LOG_LEVEL"
    row cluster C "${CUUID[$c]}"
    row az C "${AZ[$c]}"
    row node_run C ""
    # Z: where every node it knows is, the tiers, and the other clusters as this one sees them
    for p in $(members "$c") $(linked "$c"); do row "$(node_uuid "$p")" Z "${AZ[$(cluster_of "$p")]}"; done
    for oaz in top eastc westc; do row "$oaz.tier" Z "${TIER[$oaz]}"; done
    case "$c" in
        upper)
            row eastc.level Z LOWER; row eastc.pub Z "${SIGNIN[eastc]}"
            row westc.level Z LOWER; row westc.pub Z "${SIGNIN[westc]}";;
        east)
            row top.level Z UPPER; row top.host Z "$(host_list upper)"
            row westc.level Z NEIGHBOR; row westc.host Z "$(host_list west)";;
        west)
            row top.level Z UPPER; row top.host Z "$(host_list upper)"
            row eastc.level Z NEIGHBOR; row eastc.host Z "$(host_list east)";;
    esac
    # A: the synced tables
    row "$CFG" A ""
    row public.rmc_ledger A "$CFG_LOCAL"
    row public.rmc_probe A "$CFG_LOCAL"
    row public.rmc_down A "$CFG_DOWN"
    row public.rmc_up A "$CFG_UP"
    row public.rmc_side A "$CFG_SIDE"
    echo "commit;"
}
# The sentinel ytserv starts on (node/entrypoint.sh), with the same id on every
# member like every other row; up.sh writes it on all nodes at once.
READY_SQL="begin; set local session_replication_role = replica; delete from $CFG where module = 'C' and name = 'cfg_ready'; insert into $CFG (id, name, module, value) values (999, 'cfg_ready', 'C', '1'); commit;"
host_list() { local p out=""; for p in $(members "$1"); do out="${out:+$out,}$p:$PORT"; done; echo "$out"; }
# the routing of the test tables (plan.md), encoded once by up.sh into run/
table_cfg() { [ -s "$RUN/tables.env" ] && . "$RUN/tables.env"; }

# A node's own serial for yt_config: its residue mod 100, so rows it creates never
# take an id another member's serial can produce.
seq_sql() { # seq_sql <node>
    local k; k=$(node_ip "$1"); k=${k##*.}
    echo "select setval('${CFG}_id_seq', 100000 + $k, false); alter sequence ${CFG}_id_seq increment by 100;"
}

# The test tables and their sync triggers: local DDL, on every node.
schema_sql() {
    cat <<SQL
set client_min_messages = warning;
create table if not exists rmc_ledger (id bigint primary key, node text not null, at timestamptz not null default now(), v text);
create table if not exists rmc_probe (id bigint primary key, v text);
create table if not exists rmc_down (id bigint primary key, v text);
create table if not exists rmc_up (id bigint primary key, v text);
create table if not exists rmc_side (id bigint primary key, v text);
SQL
    local t
    for t in rmc_ledger rmc_probe rmc_down rmc_up rmc_side yt_config; do
        echo "drop trigger if exists zytsync_${t}_trigger on public.$t;"
        echo "create trigger zytsync_${t}_trigger after insert or update or delete on public.$t for each row execute procedure public.yt_synchronize();"
    done
}

# A config change while running: one row per cluster transaction, on the
# cluster's leader - a member's config write is refused, and a plain local write
# is not applied until a restart.
cfg_tx() { # cfg_tx <cluster> <sql>
    local c="$1" sql="$2" l err
    l=$(leader_of "$c"); [ -n "$l" ] || { say "  cfg_tx $c: no leader"; return 1; }
    err=$(cwrite "$l" "$sql") || { say "  cfg_tx $c on $l: ${err//$'\n'/ }"; return 1; }
}

# ── the load ─────────────────────────────────────────────────────────────────
lq() { docker exec -i "$(cname "$LOAD")" "$@"; }
load_members() { # load_members <cluster> <node...>: who the writer sends to
    local c="$1"; shift
    printf '%s\n' "$@" | lq sh -c "cat > /load/members-$c"
}
load_start() { # load_start <cluster>
    lq rm -f "/load/stop-$1" "/load/pause-$1"
    docker exec -d "$(cname "$LOAD")" /bin/bash /load/writer.sh "$1" "${ID_BASE[$1]}" "$RMC_TX_MS" "$RMC_ORIGIN"
}
load_pause() { # load_pause <cluster>: returns once the writer is between transactions
    lq touch "/load/pause-$1"
    local t=0
    until lq test -e "/load/paused-$1"; do
        t=$((t + 1)); [ "$t" -ge 60 ] && { say "  WARN: the $1 writer did not pause"; return 1; }
        sleep 1
    done
}
load_resume() { lq rm -f "/load/pause-$1"; }
load_stop() { lq touch "/load/stop-$1"; }
# outcome counts since a line number of the writer's log: OK ERR NOC UNK
load_counts() { # load_counts <cluster> [from-line]
    lq sh -c "tail -n +${2:-1} /load/ledger-$1.log 2>/dev/null" \
        | awk '{c[$4]++} END {printf "OK=%d ERR=%d NOC=%d UNK=%d NOL=%d", c["OK"], c["ERR"], c["NOC"], c["UNK"], c["NOL"]}'
}
load_lines() { lq sh -c "wc -l < /load/ledger-$1.log 2>/dev/null || echo 0" | tr -d ' '; }

# ── checks ───────────────────────────────────────────────────────────────────
pass=0; fail=0; known=0
ok()   { say "  OK    $1"; pass=$((pass + 1)); }
bad()  { say "  FAIL  $1"; fail=$((fail + 1)); }
# a gap the design documents as not built yet: counted apart from FAIL in the
# summary ("G gap"), but a failure all the same - test.sh exits non-zero when any
# GAP was reported, so a run with one is never green
gap()  { say "  GAP   $1"; known=$((known + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi; }
