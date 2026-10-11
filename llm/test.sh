#!/usr/bin/env bash
# The yt_llm test, on a cluster up.sh brought up:
#   1. the model service: each model answers through the mutual-TLS proxy with
#      the client certificate, and a connection without one is refused
#   2. the cluster: one leader, one cluster uuid, the ClickHouse cluster file on
#      every node, three shards in ClickHouse
#   3. plain-language questions (yt_llm_query / yt_llm) on TEST_NODES (default
#      all three), each graded against a hand-written query:
#        S*  PostgreSQL - tables whole on every node
#        D*  DataFusion - tables named in C llm_df_tables, read by ytserv
#        C*  ClickHouse - tables only ClickHouse has, over three shards
#        R1  a table pinned-sharded over the yaxaha nodes that ClickHouse also
#            has: answered from ClickHouse, and the answer says why
#        R2  a pinned-sharded table ClickHouse does not have: refused -
#            DataFusion over shards is not built (yt-pgxt llm/llm2.md P4, P5)
#        R3  a ring-hash-sharded table ClickHouse also has: left off yt_llm's
#            lists, so ClickHouse's copy answers as a table of its own
#        R4  a ring-hash-sharded table ClickHouse does not have: refused
# Output: results/run-<UTC time>.log. Exit status 0 when nothing FAILed, 77
# when the model service does not answer (probe.sh) and nothing was tested.
. "$(dirname "$0")/lib.sh"
state

mkdir -p "$HERE/results"
LOG="$HERE/results/run-$(date -u +%Y%m%d-%H%M%S).log"
exec > >(tee "$LOG") 2>&1
PASSED=0; FAILED=0
check() { # check <label> <1|0> <detail>
    if [ "$2" = 1 ]; then PASSED=$((PASSED + 1)); say "PASS $1: $3"; else FAILED=$((FAILED + 1)); say "FAIL $1: $3"; fi
}
say "== yt_llm test $(date -u '+%F %T') UTC, model service $LLM_HOST, questions on $TEST_NODES"
# a model service that does not answer: skipped (exit 77), not 30 failures
"$HERE/probe.sh" || exit $?

say "== 1. the model service"
resolve=(); [ -n "$LLM_HOST_IP" ] && resolve=(--resolve "$LLM_HOST:$LLM_HOST_IP")
for p in "" "$LLM_MODEL_ROUTE/" "$LLM_MODEL_CH/"; do
    r=$(curl -s -o /dev/null -w '%{http_code} %{time_total}s' --max-time 30 --cacert "$LLM_CA" \
        --cert "$LLM_CLIENT_CERT" --key "$LLM_CLIENT_KEY" "${resolve[@]}" "https://$LLM_HOST/${p}health")
    check "model.${p:-default/}health" "$([ "${r%% *}" = 200 ] && echo 1 || echo 0)" "https://$LLM_HOST/${p}health: $r"
done
r=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 --cacert "$LLM_CA" "${resolve[@]}" "https://$LLM_HOST/health")
check model.no_certificate "$([ "$r" != 200 ] && echo 1 || echo 0)" "without a client certificate: $r (refused)"

say "== 2. the cluster"
leaders=$(for n in "${NODES[@]}"; do info "$n" E leader; done | sort -u)
check cluster.leader "$([ "$(grep -c . <<< "$leaders")" = 1 ] && echo 1 || echo 0)" "all three nodes name the leader $leaders"
for n in "${NODES[@]}"; do
    u=$(q "$n" <<< "SELECT value FROM public.yt_config WHERE module = 'C' AND name = 'cluster'")
    check "cluster.$n.uuid" "$([ "$u" = "$CLUSTER_UUID" ] && echo 1 || echo 0)" "C cluster $u, term $(info "$n" E term), ytserv $(info "$n" E version)"
    s=$(info "$n" E clickhouse_cluster)
    check "cluster.$n.clickhouse_file" "$(case "$s" in written*|unchanged*) echo 1;; *) echo 0;; esac)" "$s"
done
for c in "${CHS[@]}"; do
    k=$(chq "$c" --query "SELECT count() FROM system.clusters WHERE cluster = 'yt'")
    check "clickhouse.$c.shards" "$([ "$k" = 3 ] && echo 1 || echo 0)" "$k shards of yt; here $(chq "$c" --query "SELECT count() FROM analytics.page_views_local") page views, $(chq "$c" --query "SELECT count() FROM shop.web_events_local") web events"
done
for n in "${NODES[@]}"; do
    say "INFO $n holds $(q "$n" <<< "SELECT (SELECT count(*) FROM shop.customers) || ' customers, ' || (SELECT count(*) FROM shop.orders) || ' orders, '
        || (SELECT count(*) FROM shop.web_events) || ' of 900 web events, ' || (SELECT count(*) FROM shop.clicks) || ' of 600 clicks, '
        || (SELECT count(*) FROM shop.sessions) || ' of 600 sessions, ' || (SELECT count(*) FROM shop.refunds) || ' of 300 refunds'")"
done

say "== 3. questions"
# what ClickHouse answers by hand, as TSV, for the C*, R1 and R3 questions
ch_tsv() { printf '%s FORMAT TSV\n' "$1" | chq ch1; }
W_C1=$(ch_tsv "SELECT country, count() FROM analytics.page_views GROUP BY country")
W_C2=$(ch_tsv "SELECT device, sum(duration_ms) FROM analytics.page_views GROUP BY device")
W_R1=$(ch_tsv "SELECT event_type, count() FROM shop.web_events GROUP BY event_type")
W_R3=$(ch_tsv "SELECT channel, count() FROM shop.sessions GROUP BY channel")
questions() {
    cat "$HERE/data/grade.sql"
    cat <<SQL
SET search_path = shop, public;
SELECT pg_temp.ask('$1.S1', \$q\$How many customers are there in each country?\$q\$, 'sql',
    pg_temp.want_sql(\$r\$select country, count(*) from shop.customers group by country\$r\$));
SELECT pg_temp.ask('$1.S2', \$q\$How many delivered orders were placed by customers of each country?\$q\$, 'sql',
    pg_temp.want_sql(\$r\$select c.country, count(*) from shop.orders o join shop.customers c on c.id = o.customer_id
                           where o.status = 'delivered' group by c.country\$r\$));
SELECT pg_temp.ask('$1.D1', \$q\$How many products are there in each category?\$q\$, 'df',
    pg_temp.want_sql(\$r\$select category, count(*) from shop.products group by category\$r\$));
SELECT pg_temp.ask('$1.D2', \$q\$What is the total quantity ordered for each product category?\$q\$, 'df',
    pg_temp.want_sql(\$r\$select p.category, sum(oi.quantity) from shop.order_items oi
                           join shop.products p on p.id = oi.product_id group by p.category\$r\$));
SELECT pg_temp.ask('$1.C1', \$q\$How many page views came from each country?\$q\$, 'ch',
    pg_temp.want_tsv(\$t\$$W_C1\$t\$));
SELECT pg_temp.ask('$1.C2', \$q\$What is the total view duration in milliseconds for each device type?\$q\$, 'ch',
    pg_temp.want_tsv(\$t\$$W_C2\$t\$));
SELECT pg_temp.ask('$1.R1', \$q\$How many web events of each type are there?\$q\$, 'ch',
    pg_temp.want_tsv(\$t\$$W_R1\$t\$), 'not whole on this node');
SELECT pg_temp.refused('$1.R2', \$q\$How many times was each button clicked?\$q\$,
    'DataFusion on another holder or over shards is not built yet');
SELECT pg_temp.ask('$1.R3', \$q\$How many sessions came from each channel?\$q\$, 'ch',
    pg_temp.want_tsv(\$t\$$W_R3\$t\$));
SELECT pg_temp.refused('$1.R4', \$q\$What is the total refund amount for each reason?\$q\$,
    'no target here answers');
SQL
}
for n in $TEST_NODES; do
    say "-- on $n"
    out=$(questions "$n" | docker exec -i -u postgres "$(cname "$n")" psql -X -q -At -d "$DB" 2>&1)
    while IFS= read -r line; do
        l=$(sed -n 's/^.*NOTICE: *//p' <<< "$line")
        [ -n "$l" ] || { case "$line" in *ERROR*) FAILED=$((FAILED + 1)); say "FAIL $n: $line";; esac; continue; }
        case "$l" in
            PASS*) PASSED=$((PASSED + 1));;
            FAIL*) FAILED=$((FAILED + 1));;
        esac
        say "$l"
    done <<< "$out"
done

say "== $PASSED PASS, $FAILED FAIL (log: results/$(basename "$LOG"))"
[ "$FAILED" = 0 ]
