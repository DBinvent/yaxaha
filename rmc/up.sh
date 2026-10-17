#!/usr/bin/env bash
# Bring up the three clusters - a new set each run: the previous containers, the
# network and this run's state go first.
#
#   1. eleven nodes (PostgreSQL only: ytserv waits for C cfg_ready) and the load client
#   2. the test tables and their sync triggers, on every node
#   3. each cluster's config, the same rows with the same ids on its members
#   4. cfg_ready on all nodes at once: one synchronised cold start
#   5. wait: a leader in each cluster, and a write that commits and replicates
#   5b. the secret store and TLS in every cluster, the links set up and approved:
#      a hierarchy runs on them (yt-pgxt skv-secrets.md H2, store.sh)
#   6. the three writers start
. "$(dirname "$0")/lib.sh"
. "$HERE/store.sh"

docker image inspect "$IMAGE" >/dev/null 2>&1 || die "no image $IMAGE - run build.sh first"

say "== $(now) a new set of clusters"
cluster_rm
rm -rf "$RUN" && mkdir -p "$RUN"
for c in "${CLUSTERS[@]}"; do set_members "$c" ${START[$c]}; done
ALL=$(for c in "${CLUSTERS[@]}"; do members "$c"; done | tr '\n' ' ')

say "== 1. nodes: $ALL"
net_up
for n in $ALL; do node_run "$n" || die "docker run $n"; done
load_run || die "docker run the load client"
ext_ready() { [ "$(q "$1" <<< "select count(*) from pg_extension where extname = 'yaxaha'" 2>/dev/null)" = 1 ]; }
for n in $ALL; do wait_for 180 ext_ready "$n" || die "$n: PostgreSQL with the extension"; done
say "  every node: PostgreSQL 18, extension yaxaha ($(docker exec "$(cname u1)" dpkg-query -W -f='${Version}' yaxaha))"

say "== 2. tables"
{
    echo "CFG_LOCAL='$(enc 'no_up; no_down')'"
    echo "CFG_DOWN='$(enc 'az=top,eastc,westc; write=top')'"
    echo "CFG_SIDE='$(enc 'az=eastc,westc')'"
    echo "CFG_UP='$(enc 'az=top,eastc; write=eastc; no_down')'"
} > "$RUN/tables.env"
table_cfg
[ -n "$CFG_LOCAL" ] && [ -n "$CFG_DOWN" ] && [ -n "$CFG_SIDE" ] && [ -n "$CFG_UP" ] || die "yxctl --encode-table-cfg gave nothing"
for n in $ALL; do schema_sql | q "$n" >/dev/null || die "$n: schema"; done
say "  rmc_ledger, rmc_probe: no_up; no_down   rmc_down: az=top,eastc,westc; write=top   rmc_up: az=top,eastc; write=eastc; no_down   rmc_side: az=eastc,westc"

say "== 3. config"
for c in "${CLUSTERS[@]}"; do
    for n in $(members "$c"); do
        { cfg_sql "$c"; seq_sql "$n"; } | q "$n" >/dev/null || die "$n: config"
    done
    say "  $c (${AZ[$c]}, tier ${TIER[${AZ[$c]}]}, cluster ${CUUID[$c]:0:8}): $(members "$c"): $(q "$(members "$c" | cut -d' ' -f1)" <<< "select string_agg(module || ':' || n, ' ' order by module) from (select module, count(*) n from $CFG group by module) m") rows"
done

say "== 4. cfg_ready everywhere"
for n in $ALL; do q "$n" <<< "$READY_SQL" >/dev/null || die "$n: cfg_ready"; done

say "== 5. waiting for the clusters"
three() { local c; for c in "${CLUSTERS[@]}"; do [ -n "$(leader_of "$c")" ] || return 1; done; }
wait_for "$RMC_WAIT" three || die "not every cluster elected within ${RMC_WAIT}s"
probe=0
commits() {
    local c="$1" l w id
    l=$(leader_of "$c"); w=$(members "$c" | tr ' ' '\n' | grep -vx "$l" | head -1)
    probe=$((probe + 1)); id=$(( ${ID_BASE[$c]} + probe ))
    cwrite "$l" "insert into rmc_probe values ($id, 'up')" >/dev/null || return 1
    sleep 2
    [ "$(q "$w" <<< "select count(*) from rmc_probe where id = $id")" = 1 ]
}
for c in "${CLUSTERS[@]}"; do
    wait_for "$RMC_WAIT" commits "$c" || die "$c does not commit and replicate"
    say "  $c: leader $(leader_of "$c"), term $(node_term "$(leader_of "$c")"), writable"
done

say "== 5b. the store and TLS, the links (H2)"
store_up || die "the clusters are not on the secret store and TLS"

say "== 6. writers"
for c in "${CLUSTERS[@]}"; do
    load_members "$c" $(members "$c")
    load_start "$c"
done
sleep 10
for c in "${CLUSTERS[@]}"; do say "  $c: $(load_counts "$c")"; done
say "== up: ./test.sh runs the phases"
