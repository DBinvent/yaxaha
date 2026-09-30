#!/usr/bin/env bash
# Bring up the yt_llm test cluster on docker - a new one each run: the previous
# cluster, its volumes and its secrets go first.
#
#   1. the three yaxaha nodes, PostgreSQL only: ytserv waits for C cfg_ready
#   2. the sample data (data/pg.sql) on each node
#   3. the cluster config, the same rows on every node - the roster (N), the
#      cluster and llm settings (C), the model service's client keys and the
#      ClickHouse connection encrypted with the app key (K), the synced tables
#      with their shard rules (A) - and last C cfg_ready, on which ytserv starts
#   4. wait: one leader for all three, and each node rendered the ClickHouse
#      cluster file from C clickhouse_cluster
#   5. the three ClickHouse nodes (each waits for that file), Keeper, then
#      data/ch.sql with the read-only user llm_ro
. "$(dirname "$0")/lib.sh"

docker image inspect "$IMAGE" >/dev/null 2>&1 || die "no image $IMAGE - run build.sh first"
for f in "$LLM_CA" "$LLM_CLIENT_CERT" "$LLM_CLIENT_KEY"; do
    [ -r "$f" ] || die "the model service's client bundle: $f is not readable (LLM_CA, LLM_CLIENT_CERT, LLM_CLIENT_KEY in .env)"
done
openssl verify -CAfile "$LLM_CA" "$LLM_CLIENT_CERT" >/dev/null 2>&1 || die "$LLM_CLIENT_CERT is not issued by $LLM_CA"

say "== a new cluster, docker ${DOCKER_HOST:-(default)}"
cluster_rm
new_state

say "== 1. yaxaha nodes ${NODES[*]}"
net_up
for i in 1 2 3; do node_run "$i" || die "docker run yt$i"; done
ext_ready() { [ "$(q "$1" <<< "select count(*) from pg_extension where extname = 'yaxaha'" 2>/dev/null)" = 1 ]; }
for n in "${NODES[@]}"; do
    wait_for 180 "$n: PostgreSQL with the extension" ext_ready "$n"
    say "  $n: PostgreSQL 18, extension yaxaha"
done

say "== 2. sample data (data/pg.sql)"
i=0
for n in "${NODES[@]}"; do
    uv="YT$((i + 1))_UUID"
    out=$(q "$n" -v node_index=$i -v node_uuid="${!uv}" < "$HERE/data/pg.sql") || die "$n: data/pg.sql"
    say "  $n: $(echo "$out" | tr '\n' ' ')"
    i=$((i + 1))
done

say "== 3. cluster config (the same rows on every node)"
# the two kinds of yaxaha shard (data/pg.sql): pinned by an owner column, and ring hash
pin=$(docker exec "$(cname yt1)" yxctl --encode-table-cfg 'shard=owner; outer=pin' | tail -1 | tr -d '\r')
ring=$(docker exec "$(cname yt1)" yxctl --encode-table-cfg 'shard=id; outer=reject' | tail -1 | tr -d '\r')
[ -n "$pin" ] && [ -n "$ring" ] || die "yxctl --encode-table-cfg gave nothing"
# module K: encrypted with ytserv's app key. The passphrase is the hex SHA3-256 of
# SECRET; certificates by openssl enc, the key as an encrypted PKCS#8 PEM.
export YT_LLM_PASS=$(printf '%s' "$YT_SECRET" | openssl dgst -sha3-256 -r | cut -d' ' -f1)
ENC=(openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -md sha256 -salt -a -A -pass env:YT_LLM_PASS)
k_ca=$("${ENC[@]}" -in "$LLM_CA") || die "encrypting $LLM_CA"
k_cert=$("${ENC[@]}" -in "$LLM_CLIENT_CERT") || die "encrypting $LLM_CLIENT_CERT"
k_key=$(openssl pkcs8 -topk8 -v2 aes-256-cbc -in "$LLM_CLIENT_KEY" -passout env:YT_LLM_PASS) || die "encrypting $LLM_CLIENT_KEY"
# the ch target's ClickHouse, and the secret for the cluster file's empty <secret/>.
# `ch` is each node's own ClickHouse node (lib.sh, networks ytllm-pairN).
k_ch=$(python3 -c 'import json, os
print(json.dumps({"url": "http://ch:8123", "db": "default", "databases": ["analytics", "shop"],
                  "username_ro": "llm_ro", "password_ro": os.environ["CH_RO_PASSWORD"],
                  "cluster_secret": os.environ["CH_CLUSTER_SECRET"]}))' | "${ENC[@]}") || die "encrypting the ClickHouse row"
unset YT_LLM_PASS

TABLES="shop.customers shop.orders shop.products shop.order_items shop.web_events shop.clicks shop.sessions shop.refunds"
cfg_sql() {
    cat <<SQL
BEGIN;
DELETE FROM public.yt_config WHERE module IN ('N', 'K', 'A') OR module = 'C';
INSERT INTO public.yt_config (name, module, value) VALUES
    ('$YT1_UUID', 'N', 'yt1:7421'),
    ('$YT2_UUID', 'N', 'yt2:7421'),
    ('$YT3_UUID', 'N', 'yt3:7421'),
    ('min_cluster_size', 'C', '3'),
    ('tcp_timeout_ms', 'C', '2000'),
    ('log_level', 'C', 'info'),
    ('cluster', 'C', '$CLUSTER_UUID'),
    ('serve_llm', 'C', 'true'),
    ('llm_host', 'C', '$LLM_HOST'),
    ('llm_ca', 'C', 'llm.ca'),
    ('llm_cert', 'C', 'llm.cert'),
    ('llm_key', 'C', 'llm.key'),
    ('llm_model_route', 'C', '$LLM_MODEL_ROUTE'),
    ('llm_model_ch', 'C', '$LLM_MODEL_CH'),
    ('llm_df_python', 'C', '/opt/llm-df/bin/python'),
    ('llm_df_tables', 'C', 'shop.products,shop.order_items'),
    ('clickhouse_cluster', 'C', \$xml\$$(cat "$HERE/cluster.xml")\$xml\$),
    ('llm.ca', 'K', '$k_ca'),
    ('llm.cert', 'K', '$k_cert'),
    ('llm.key', 'K', \$key\$$k_key\$key\$),
    ('clickhouse', 'K', '$k_ch'),
    ('shop.customers', 'A', ''),
    ('shop.orders', 'A', ''),
    ('shop.products', 'A', ''),
    ('shop.order_items', 'A', ''),
    ('shop.web_events', 'A', '$pin'),
    ('shop.clicks', 'A', '$pin'),
    ('shop.sessions', 'A', '$ring'),
    ('shop.refunds', 'A', '$ring');
SQL
    for t in $TABLES; do
        echo "CREATE TRIGGER zytsync_${t//./_}_trigger AFTER INSERT OR UPDATE OR DELETE ON $t FOR EACH ROW EXECUTE PROCEDURE public.yt_synchronize();"
    done
    echo "COMMIT;"
}
for n in "${NODES[@]}"; do
    cfg_sql | q "$n" >/dev/null || die "$n: the cluster config"
done
for n in "${NODES[@]}"; do   # the sentinel last, on all three at once: one synchronized start
    q "$n" <<< "INSERT INTO public.yt_config (name, module, value) VALUES ('cfg_ready', 'C', '1')" || die "$n: cfg_ready"
done
say "  $(q yt1 <<< "SELECT string_agg(module || ':' || n, ' ' ORDER BY module) FROM (SELECT module, count(*) n FROM public.yt_config GROUP BY module) m") rows on each node; pinned shards: shop.web_events, shop.clicks; ring-hash shards: shop.sessions, shop.refunds"

say "== 4. waiting for the cluster"
one_leader() {
    local l n seen=""
    for n in "${NODES[@]}"; do
        l=$(info "$n" E leader); [ -n "$l" ] || return 1
        [ -z "$seen" ] || [ "$seen" = "$l" ] || return 1
        seen=$l
    done
}
wait_for 240 "one leader for ${NODES[*]}" one_leader
chfile() { case "$(info "$1" E clickhouse_cluster)" in written*|unchanged*) return 0;; esac; return 1; }
for n in "${NODES[@]}"; do
    wait_for 60 "$n: the ClickHouse cluster file" chfile "$n"
    say "  $n: term $(info "$n" E term), leader $(info "$n" E leader | cut -c1-8), $(info "$n" E clickhouse_cluster)"
done

say "== 5. ClickHouse nodes ${CHS[*]}"
for i in 1 2 3; do ch_run "$i" || die "docker run ch$i"; done
ch_up() { [ "$(chq "$1" --query 'SELECT 1' 2>/dev/null)" = 1 ]; }
keeper_ok() { chq "$1" --query "SELECT count() FROM system.zookeeper WHERE path = '/'" >/dev/null 2>&1; }
for c in "${CHS[@]}"; do wait_for 180 "$c: ClickHouse" ch_up "$c"; done
for c in "${CHS[@]}"; do wait_for 120 "$c: Keeper" keeper_ok "$c"; done
for c in "${CHS[@]}"; do
    say "  $c: $(chq "$c" --query "SELECT version()"), $(chq "$c" --query "SELECT count() FROM system.clusters WHERE cluster = 'yt'") shards of yt"
done
out=$(sed "s/@CH_RO_PASSWORD@/$CH_RO_PASSWORD/" "$HERE/data/ch.sql" \
      | chq ch1 --multiquery --distributed_ddl_output_mode=none) || die "data/ch.sql"
say "  $(echo "$out" | tr '\t\n' '= ')"
for c in "${CHS[@]}"; do
    say "  $c holds $(chq "$c" --query "SELECT count() FROM analytics.page_views_local") page views, $(chq "$c" --query "SELECT count() FROM shop.web_events_local") web events"
done
say "== up: ./test.sh asks the questions"
