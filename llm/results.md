# yt_llm test: results

**Run of 2026-09-30, 14:55 UTC, on the docker host, with every question asked on
all three nodes: 101 PASS, 0 FAIL.** On every node, every answered question came back
from the engine it should, with exactly the rows of a query written by hand, and
both refusals gave the reason they should.

The package was yaxaha 0.16.7 (ytserv 0.19.7). It carries the fix for the one bug
this test found, the ClickHouse fallback for a pinned shard (below). The raw
output is `results/run-20260930-145549.log`, which is not committed.

## What ran

| | |
|---|---|
| node image `ytllm-node` | Ubuntu 26.04, PostgreSQL 18, yaxaha 0.16.7 (ytserv 0.19.7), datafusion 54.0.0, pyarrow 25.0.1 |
| yaxaha cluster | `yt1`, `yt2`, `yt3`: one leader, term 1, one cluster uuid on all three. Each node wrote the ClickHouse cluster file from `yt_config`, the same text on all three |
| ClickHouse | 26.9.6.6, cluster `yt` of three shards, Keeper on all three |
| model service | `gpc:8080`, the Windows box: default XiYanSQL-QwenCoder-7B (`sql`, `df`), `route` Qwen3-4B-Instruct, `ch` Qwen2.5-Coder-7B-Instruct, all on the CPU |

The data, as the nodes held it:

| | on each yaxaha node | in ClickHouse |
|---|---|---|
| `shop.customers`, `shop.orders`, `shop.products`, `shop.order_items` | all rows: 50, 400, 20, 997 | - |
| `shop.web_events` (pinned shard) | a third: 300 of 900 | all 900: 314 / 295 / 291 per shard |
| `shop.clicks` (pinned shard) | a third: 200 of 600 | - |
| `shop.sessions` (ring-hash shard) | a third: 200 of 600 | all 600 |
| `shop.refunds` (ring-hash shard) | a third: 100 of 300 | - |
| `analytics.page_views` | - | 30000: 10030 / 10093 / 9877 per shard |

## Results

| | checks | |
|---|---|---|
| the model service | 4 PASS | `/health` of the default, `route` and `ch` models through the mutual-TLS proxy, each in about 10 ms. Without a client certificate the connection is refused |
| the cluster | 10 PASS | one leader for all three; the cluster uuid; the ClickHouse file on each node; three shards seen from each ClickHouse node |
| the questions | 87 PASS | 10 questions, each on the three nodes, 29 checks per node; below |

The questions, all PASS on every node. The times are for the statement: the
calls to the model plus the node's checks, on yt1, yt2 and yt3. Reading the rows
afterwards took 0.1 to 0.4 s, because the statement is kept and the model is not
asked again.

| | question | answered by | the model's statement (yt1) | time, s |
|---|---|---|---|---|
| S1 | How many customers are there in each country? | PostgreSQL | `SELECT country, COUNT(id) AS customer_count FROM shop.customers GROUP BY country ORDER BY customer_count DESC` | 18.4, 11.6, 10.2 |
| S2 | How many delivered orders were placed by customers of each country? | PostgreSQL | `SELECT c.country, COUNT(o.id) … FROM shop.orders o JOIN shop.customers c ON o.customer_id = c.id WHERE o.status = 'delivered' GROUP BY c.country` | 16.8, 15.1, 14.9 |
| D1 | How many products are there in each category? | DataFusion: 1 table, 4 partitions | `SELECT category, COUNT(id) AS product_count FROM shop.products GROUP BY category` | 12.9, 11.0, 10.9 |
| D2 | What is the total quantity ordered for each product category? | DataFusion: 2 tables, 5 partitions | `SELECT p.category, SUM(oi.quantity) … FROM shop.order_items oi JOIN shop.products p ON oi.product_id = p.id GROUP BY p.category` | 18.6, 17.3, 17.0 |
| C1 | How many page views came from each country? | ClickHouse, over three shards | `SELECT country, COUNT(*) AS page_views FROM analytics.page_views GROUP BY country` | 17.5, 18.0, 17.5 |
| C2 | What is the total view duration in milliseconds for each device type? | ClickHouse | `SELECT device, SUM(duration_ms) AS total_duration_ms FROM analytics.page_views GROUP BY device` | 13.5, 13.7, 13.7 |
| R1 | How many web events of each type are there? | ClickHouse, for a pinned shard; the answer says "not whole on this node" | `SELECT event_type, COUNT(*) AS event_count FROM shop.web_events GROUP BY event_type` | 13.4, 13.8, 13.2 |
| R2 | How many times was each button clicked? | refused: a pinned shard ClickHouse does not have | refused: "…shop.clicks (sharded: each holder has only its own rows) - not whole on this node, and DataFusion on another holder or over shards is not built yet (llm/llm2.md P4, P5); ClickHouse does not have…" | 12.3, 8.8, 8.9 |
| R3 | How many sessions came from each channel? | ClickHouse's own `shop.sessions` | `SELECT channel, COUNT(id) AS session_count FROM shop.sessions GROUP BY channel` | 13.0, 12.7, 13.2 |
| R4 | What is the total refund amount for each reason? | refused: a ring-hash shard ClickHouse does not have | refused: "the statement reads what no target here answers: shop.refunds (sharded by RING_HASH: owners follow the live ring, so no stable split exists (df-todo.md §0.3))" | 10.8, 9.0, 9.1 |

For each answered question there are three checks:
- the engine the node reports;
- the rows of a page of `yt_llm_query`;
- the rows of `yt_llm()`.

D1 and D2 have a fourth, the plan and the script, and so does R1, the note in
its answer. A refused question has one check: the refusal and its reason. That
makes 29 per node.

Rows are compared with the query by hand as sets of values. The model does not
always name a column the same way: on yt1, C2's column was `total_duration_ms`
here and `total_view_duration` in the previous run. The values were the same,
and the values are what is compared.

## The bug this test found, fixed in ytserv 0.19.7

**Symptom, with ytserv 0.19.6:** R1 failed on every node with `yt_llm_query:
asked again for ch, the model's statement still reads tables ch does not have:
SELECT event_type, COUNT(*) AS event_count FROM shop.web_events GROUP BY
event_type`. ClickHouse does have `shop.web_events`, and that statement is the
right answer.

**Cause:** in yt-pgxt `ytserv/src/llm.rs`, `route()`.
1. The node decided correctly: `shop.web_events` is not whole here and ClickHouse
   has it, so it had the `ch` model write the statement.
2. It then checked that ClickHouse statement with the same `route::decide()`.
   That function looks names up in the PostgreSQL lists first, where the pinned
   shard shadows ClickHouse's table of the same name.
3. So the statement read as the sharded PostgreSQL table again, the model was
   asked a second time, and the node gave up. The fallback never ran.

No earlier test reached this path. The lab test's name "both have" is a table
whole in PostgreSQL, which rightly stays `sql`.

**Fix:** `route::decide_written`. A statement the node had written for ClickHouse
looks its tables up among ClickHouse's own, the shadowed ones included, and runs
there when ClickHouse has them all. Anything else is decided as before. It has a
unit test in `route.rs`, and ytserv's tests pass: 232. It ships as yaxaha
0.16.7. With it, R1 is answered in one call to the model, about 13 s. The answer
carries the note "read from ClickHouse, which has every table of the statement:
shop.web_events (sharded: each holder has only its own rows) - not whole on this
node".

## The three runs of the day

| run (UTC) | package | shard kinds, nodes | result | |
|---|---|---|---|---|
| 13:51 | 0.16.6 | ring hash only, `yt1` | 37 PASS, 2 FAIL | both failures were the test's own; see below |
| 14:23 | 0.16.6 | both kinds, all three nodes | 89 PASS, 3 FAIL | R1 on every node: the bug above |
| 14:55 | 0.16.7 | both kinds, all three nodes | **101 PASS, 0 FAIL** | |

The first run taught two things about the test:
- That R1 expected the "not whole" note, which ring-hash tables never produce.
- That R2 asked "clicks per page", which `shop.web_events` answers too, so the
  model used it.

## What the runs showed about shards

yt_llm treats yaxaha's two kinds of shard differently, as the code means to:
- **pinned** (`shard=owner; outer=pin`): the table is on the DataFusion list as
  "sharded". When ClickHouse has it, the question is answered from ClickHouse,
  and the answer says why (R1). When ClickHouse does not, it is refused naming
  P4/P5 (R2).
- **ring hash** (`shard=id; outer=reject`): the table is on no list, because its
  owners follow the live ring (`df-todo.md` §0.3). ClickHouse's table of the same
  name answers as a table of its own (R3), and a question needing the PostgreSQL
  table is refused (R4).

DataFusion over a table no node holds whole is not built (yt-pgxt
`llm/llm2.md` P4, P5). The node answers from ClickHouse or refuses; it never
gives a partial number.

## Also noted

- D2: ytserv read `shop.order_items` as one partition, and said why in the
  answer's notes: it has no single integer primary key to split on (its key is
  `order_id, product_id`).
- The yaxaha nodes' ClickHouse file names no shard for them. Its hosts are
  `ch1`-`ch3` and the nodes are `yt1`-`yt3`, so ytserv adds no `<macros>`. Nothing
  here needs them: the tables are `Distributed` over `MergeTree`, with no
  `{shard}` macro.
- R4 depends on the model more than the others. The ring-hash table is on no
  list the model sees, so it guessed the name `shop.refunds`, which the node then
  refused with the reason that table is excluded.

## Reproduce

```
cp env.example .env && $EDITOR .env    # client certificate, package (0.16.7 or newer), YTLLM_DOCKER_HOST
./build.sh && ./up.sh && ./test.sh     # ~2 min + ~12 min
```

The cluster from this run is still up on the docker host, as containers
`ytllm-yt1..3` and `ytllm-ch1..3`. To ask your own questions:

```
docker exec -it -u postgres ytllm-yt1 psql -d ytllm
SELECT yt_llm_query('How many orders are there per status?');
```

`./down.sh` removes it.
