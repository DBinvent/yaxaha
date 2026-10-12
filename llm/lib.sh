#!/usr/bin/env bash
# Shared by build.sh, up.sh, test.sh and down.sh. Source, do not execute.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/run"   # per cluster: the app key, passwords, uuids - never committed
mkdir -p "$RUN"

# Settings: .env next to this file (not committed, see env.example). A variable
# already set in the environment wins over .env.
if [ -f "$HERE/.env" ]; then
    _pre="$(export -p)"
    set -a; . "$HERE/.env"; set +a
    eval "$_pre"
    unset _pre
fi
# the docker daemon to run on: YTLLM_DOCKER_HOST, when set, over the shell's DOCKER_HOST
[ -n "${YTLLM_DOCKER_HOST:-}" ] && export DOCKER_HOST="$YTLLM_DOCKER_HOST"

# The model service: llama.cpp behind a mutual-TLS proxy (README.md). Its NAME
# only; an address, where the name does not resolve, comes from .env.
LLM_HOST=${LLM_HOST:-gpc:8080}
LLM_HOST_IP=${LLM_HOST_IP:-}
LLM_CA=${LLM_CA:-$HOME/llm-client/ca.crt}
LLM_CLIENT_CERT=${LLM_CLIENT_CERT:-$HOME/llm-client/linux.crt}
LLM_CLIENT_KEY=${LLM_CLIENT_KEY:-$HOME/llm-client/linux.key}
LLM_MODEL_ROUTE=${LLM_MODEL_ROUTE:-route}
LLM_MODEL_CH=${LLM_MODEL_CH:-ch}
YAXAHA_DEB=${YAXAHA_DEB:-}
TEST_NODES=${TEST_NODES:-yt1 yt2 yt3}

DB=ytllm
NODES=(yt1 yt2 yt3)
CHS=(ch1 ch2 ch3)
IMAGE=ytllm-node
# the namespace yxctl's --peers roster derives node uuids in: uuid5(ns, host name)
YAXAHA_NS=6a9f5c2e-1b3d-5e47-9a08-0bf99b3e0275

say() { printf '%s\n' "$*"; }
die() { say "== STOP: $*" >&2; exit 1; }

node_uuid() { python3 -c 'import sys, uuid; print(uuid.uuid5(uuid.UUID(sys.argv[1]), sys.argv[2]))' "$YAXAHA_NS" "$1"; }

# The six containers, in plain docker - no compose needed. Everything is found
# by name, never by address:
# - network ytllm: every container, under its short name (yt1..yt3, ch1..ch3):
#   the yaxaha roster (ytN:7421) and the ClickHouse cluster (chN:9000);
# - networks ytllm-pairN (internal): ytN and chN only, where chN is also `ch`.
#   So the one cluster-wide module K row clickhouse (http://ch:8123) makes every
#   yaxaha node read its own ClickHouse node;
# - the model host: by its name (LLM_HOST); where that does not resolve, .env's
#   LLM_HOST_IP is mapped to it in the yaxaha containers (--add-host).
CH_IMAGE=clickhouse/clickhouse-server:26.9
cname() { echo "ytllm-$1"; }

net_up() {
    local i
    docker network inspect ytllm >/dev/null 2>&1 || docker network create ytllm >/dev/null
    for i in 1 2 3; do
        docker network inspect "ytllm-pair$i" >/dev/null 2>&1 || docker network create --internal "ytllm-pair$i" >/dev/null
    done
}

# YX_COV_MOUNT: a coverage run's volume for the instrumented ytserv's counts
# (nightly/coverage.sh); unset otherwise.
node_run() { # node_run <1|2|3>
    local i="$1" n="yt$1" uuid_var="YT$1_UUID" add=()
    [ -n "$LLM_HOST_IP" ] && add=(--add-host "${LLM_HOST%:*}:$LLM_HOST_IP")
    docker run -d --name "$(cname "$n")" --hostname "$n" --network ytllm --network-alias "$n" \
        -e NODE_UUID="${!uuid_var}" -e SECRET="$YT_SECRET" -e DB="$DB" \
        -v "ytllm-chcfg$i:/etc/yaxaha/clickhouse" ${YX_COV_MOUNT:-} "${add[@]}" "$IMAGE" >/dev/null || return 1
    docker network connect "ytllm-pair$i" "$(cname "$n")"
}

ch_run() { # ch_run <1|2|3>
    local i="$1" c="ch$1"
    docker run -d --name "$(cname "$c")" --hostname "$c" --network ytllm --network-alias "$c" \
        -e KEEPER_ID="$i" -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
        -v "ytllm-chcfg$i:/etc/yaxaha/clickhouse:ro" \
        -v "$HERE/ch/keeper.xml:/etc/clickhouse-server/config.d/yt-keeper.xml:ro" \
        -v "$HERE/ch/wait-cluster.sh:/usr/local/bin/wait-cluster.sh:ro" \
        --ulimit nofile=262144:262144 --entrypoint /bin/bash \
        "$CH_IMAGE" /usr/local/bin/wait-cluster.sh >/dev/null || return 1
    docker network connect --alias ch "ytllm-pair$i" "$(cname "$c")"
}

# the whole cluster away: containers, the volumes with the rendered cluster
# files, the networks
cluster_rm() {
    local i
    for i in 1 2 3; do docker rm -f "$(cname "yt$i")" "$(cname "ch$i")" >/dev/null 2>&1; done
    for i in 1 2 3; do docker volume rm "ytllm-chcfg$i" >/dev/null 2>&1; done
    for i in 1 2 3; do docker network rm "ytllm-pair$i" >/dev/null 2>&1; done
    docker network rm ytllm >/dev/null 2>&1
    true
}

# psql on a yaxaha node as postgres, SQL on stdin
q() { # q <node> [psql args...]
    local n="$1"; shift
    docker exec -i -u postgres "$(cname "$n")" psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"
}

# clickhouse-client on a ClickHouse node (its default user, from inside), SQL on stdin
chq() { # chq <node> [clickhouse-client args...]
    local n="$1"; shift
    docker exec -i "$(cname "$n")" clickhouse-client "$@"
}

# one value of yt_info, e.g. info yt1 E clickhouse_cluster
info() { # info <node> <letters> <name>
    q "$1" <<< "SELECT value FROM json_to_recordset(yt_info('$2')) AS x(name text, value text, module text) WHERE name = '$3'" 2>/dev/null
}

# wait_for <seconds> <description> <command...>: until the command succeeds
wait_for() {
    local secs="$1" what="$2"; shift 2
    local t=0
    until "$@" >/dev/null 2>&1; do
        t=$((t + 2)); [ "$t" -ge "$secs" ] && die "$what: not within ${secs}s"
        sleep 2
    done
}

# The cluster's own secrets and identities, made once per cluster by up.sh:
# ytserv's app key (it decrypts module K), the ClickHouse passwords, the cluster
# uuid. Node uuids are derived from the host names, like yxctl --peers does.
state() {
    [ -s "$RUN/state.env" ] || die "no $RUN/state.env - run up.sh first"
    set -a; . "$RUN/state.env"; set +a
    YT1_UUID=$(node_uuid yt1); YT2_UUID=$(node_uuid yt2); YT3_UUID=$(node_uuid yt3)
    export YT1_UUID YT2_UUID YT3_UUID
}
new_state() {
    ( umask 077
      { echo "YT_SECRET=$(openssl rand -hex 24)"
        echo "CLUSTER_UUID=$(python3 -c 'import uuid; print(uuid.uuid4())')"
        echo "CH_RO_PASSWORD=$(openssl rand -hex 16)"
        echo "CH_CLUSTER_SECRET=$(openssl rand -hex 16)"
      } > "$RUN/state.env" )
    state
}
