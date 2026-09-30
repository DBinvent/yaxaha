# Asking a yaxaha cluster in plain language: one question, three engines

*A test report, 2026-09-30*

A yaxaha cluster can answer a question written in plain language:

```sql
SELECT * FROM yt_llm('How many delivered orders were placed by customers of each country?')
         AS t(country text, orders bigint);
```

You don't write any SQL. The node asks a text-to-SQL model to write it, runs it
where the data is, and returns the rows. "Where the data is" matters in a
cluster. A table may be whole on the node you asked, or it may be sharded so
that each node holds only its own rows. It may live in ClickHouse, next to the
PostgreSQL cluster. It may also be a table you want computed by DataFusion
rather than PostgreSQL.

This report describes a test of exactly that on three yaxaha nodes and three
ClickHouse nodes in docker. It covers ten questions asked on every node, and the
bug the test found and that is now fixed. The final run was **101 checks, 101
passed**.

## How a node answers a question

`yt_llm` is a function of the yaxaha extension. The work happens in ytserv, the
node's cluster daemon, in five steps.

1. **The node describes what it can read, as three lists.** Each table goes on
   the list of the engine that can answer it exactly:

   | list | tables | answered by |
   |---|---|---|
   | `sql` | tables this node holds whole | the node's PostgreSQL |
   | `df` | tables named for DataFusion, and tables sharded over the nodes | DataFusion, over partitions of the rows the node copies out |
   | `ch` | ClickHouse's own catalog | ClickHouse |

2. **A small model picks the tables.** A 4-billion-parameter model gets the
   question and the table names, and answers with a JSON list of tables.
3. **The node decides the engine** from the lists those tables are on. The model
   picks tables; it never picks where a statement runs.
4. **That engine's model writes the statement**, in its dialect. PostgreSQL SQL
   and DataFusion SQL come from a text-to-SQL model tuned for PostgreSQL. ClickHouse
   SQL comes from a general coding model that knows ClickHouse's functions.
5. **The node checks the statement, then runs it** as the caller and read-only.
   PostgreSQL plans the statement without reading anything. ClickHouse parses it.
   DataFusion plans it over empty tables before a byte is copied. For DataFusion,
   the node fills a fixed script template with the model's SQL, so the model
   never writes code that runs.

One rule runs through all of it: **never a partial number.** Take a statement
over a table no engine here holds whole. It is answered where the whole table
is, or it is refused, and the refusal says why. It is never answered from one
node's share of the rows.

### What shards change

yaxaha can shard a table over its nodes, and it has two kinds of shard.

- **Pinned:** a column names the node that owns the row. A pinned table goes on
  the `df` list as "sharded". A question over it is answered from ClickHouse when
  ClickHouse has the whole table, and the answer says so. Otherwise it is refused,
  because running DataFusion across the shards is not built yet.
- **Ring hash:** rows are placed by hashing over the live nodes. The owners move
  when nodes come and go, so there is no stable split to read from, and the
  table goes on no list at all. If ClickHouse has a table of the same name, that
  table answers as a table of its own. A question that needs the PostgreSQL one
  is refused.

## The test setup

```
            ┌─────────────── docker network ───────────────┐
            │  yt1  yt2  yt3   yaxaha nodes: PostgreSQL 18, │
            │                  ytserv, DataFusion 54        │
            │  ch1  ch2  ch3   ClickHouse 26.9: 3 shards,   │
            │                  Keeper on all three          │
            └──────────────────────┬───────────────────────┘
                                   │ https, client certificate
                          model service (a separate box):
                          llama.cpp, three models, CPU only
```

- **Everything is found by name, not address.** Each yaxaha node shares a small
  private network with its ClickHouse node, which answers to the name `ch` there.
  So one cluster-wide setting, `http://ch:8123`, makes every node read its own
  ClickHouse. The ClickHouse queries are then spread over the three shards.
- **The configuration lives in the cluster's own config table.** That covers the
  node roster, the model service's address, and which tables DataFusion reads. It
  also holds the ClickHouse cluster definition: each yaxaha node renders it into
  the file its ClickHouse node reads, so an edit to that one row reconfigures
  ClickHouse without a restart. The client key for the model service and the
  ClickHouse password are stored encrypted with the node's app key, which is new
  for every run.
- **The models run on a separate host** behind a TLS proxy that only accepts
  clients with a certificate from its own CA:

  | job | model |
  |---|---|
  | pick the tables | Qwen3-4B-Instruct |
  | PostgreSQL and DataFusion SQL | XiYanSQL-QwenCoder-7B |
  | ClickHouse SQL | Qwen2.5-Coder-7B-Instruct |

  All three run on the CPU.

The data was generated deterministically, so every node computes the same rows
and a question has one right answer.

| table | where | what for |
|---|---|---|
| `shop.customers`, `shop.orders` | whole on every node | PostgreSQL questions |
| `shop.products`, `shop.order_items` | whole on every node, named for DataFusion | DataFusion questions |
| `analytics.page_views` | ClickHouse only, 30 000 rows over three shards | ClickHouse questions |
| `shop.web_events` | pinned shard (a third per node) and all rows in ClickHouse | fallback to ClickHouse |
| `shop.clicks` | pinned shard, not in ClickHouse | refusal |
| `shop.sessions` | ring-hash shard and all rows in ClickHouse | ClickHouse's own table answers |
| `shop.refunds` | ring-hash shard, not in ClickHouse | refusal |

## The questions

Every question was asked on each of the three nodes. An answer passes when three
things hold:
- the node reports the engine it should;
- a page of the answer's rows equals a query written by hand, compared as sets
  of values, since the model names columns as it likes;
- `yt_llm()` returns the same rows.

| | question | should be answered by |
|---|---|---|
| S1 | How many customers are there in each country? | PostgreSQL |
| S2 | How many delivered orders were placed by customers of each country? | PostgreSQL (a join) |
| D1 | How many products are there in each category? | DataFusion |
| D2 | What is the total quantity ordered for each product category? | DataFusion (a join) |
| C1 | How many page views came from each country? | ClickHouse, three shards |
| C2 | What is the total view duration in milliseconds for each device type? | ClickHouse |
| R1 | How many web events of each type are there? | ClickHouse, for a pinned shard, saying so |
| R2 | How many times was each button clicked? | refused: pinned shard, not in ClickHouse |
| R3 | How many sessions came from each channel? | ClickHouse's own table, for a ring-hash shard |
| R4 | What is the total refund amount for each reason? | refused: ring-hash shard, not in ClickHouse |

## Results

**101 of 101 checks passed.**

| part | checks |
|---|---|
| the model service: its three models answer through the proxy, and a connection without a certificate is refused | 4 |
| the cluster: one leader, one cluster id, each node's ClickHouse file, three shards | 10 |
| the questions: 29 checks on each of the three nodes | 87 |

A few of the statements the models wrote:

```sql
-- S2, PostgreSQL
SELECT c.country, COUNT(o.id) AS delivered_orders_count FROM shop.orders o
  JOIN shop.customers c ON o.customer_id = c.id WHERE o.status = 'delivered' GROUP BY c.country
-- D2, DataFusion: 2 tables in 5 partitions
SELECT p.category, SUM(oi.quantity) AS total_quantity FROM shop.order_items oi
  JOIN shop.products p ON oi.product_id = p.id GROUP BY p.category
-- R1, ClickHouse, with the note "read from ClickHouse, which has every table of the
-- statement: shop.web_events (sharded: each holder has only its own rows) - not whole on this node"
SELECT event_type, COUNT(*) AS event_count FROM shop.web_events GROUP BY event_type
```

The two refusals said exactly why:
- **R2:** "the statement reads shop.clicks (sharded: each holder has only its own
  rows) - not whole on this node, and DataFusion on another holder or over shards
  is not built yet (llm/llm2.md P4, P5); ClickHouse does not have shop.clicks".
- **R4:** "the statement reads what no target here answers: shop.refunds (sharded by
  RING_HASH: owners follow the live ring, so no stable split exists (df-todo.md
  §0.3))".

**Time:** 9 to 19 s per question. That is the calls to CPU-bound models, which
dominate. Reading the rows afterwards took 0.1 to 0.4 s: the node keeps the
statement, so paging through the answer asks no model.

## What the test found

The test was not green on the first try, and one failure was a real bug.

**First run: the test was wrong.** It used ring-hash shards only, and it failed
twice.
- R1 expected an answer "from ClickHouse, because the table is not whole here".
  Ring-hash tables never produce that answer: they are on no list, so ClickHouse's
  table of the same name answers directly. The code does this on purpose.
- R2 asked "How many clicks were recorded on each page?", meaning to reach the
  sharded clicks table. The events table also has click events per page, and the
  model used it. That is a fair reading of the question.

So the test now covers both kinds of shard, and R2 asks about buttons, which only
one table has.

**Second run: the bug.** With a pinned shard that ClickHouse also has, R1 failed
on every node with *"asked again for ch, the model's statement still reads
tables ch does not have"*. ClickHouse did have the table, and the statement was
right. This is what happened:
1. The node correctly decided that the table was not whole here and that
   ClickHouse had it, and it asked the ClickHouse model to write the statement.
2. Then it checked that statement with the same lookup it uses for the first
   decision, which prefers PostgreSQL's lists.
3. There, the sharded PostgreSQL table shadows ClickHouse's table of the same
   name. So the ClickHouse statement looked like a PostgreSQL one again, the model
   was asked a second time, and the node gave up.

The fallback to ClickHouse could never succeed, and no earlier test had reached
it.

**The fix** is a few lines in ytserv's router. A statement the node had written
for ClickHouse now looks its tables up among ClickHouse's own tables, shadowed
ones included, and runs there when ClickHouse has them all. It has a unit test,
and it shipped in yaxaha 0.16.7. The third run passed 101 of 101, and the fix is
on our three-node lab cluster.

## Lessons

- **Grade values, not text.** The models named the same column
  `total_view_duration`, `total_view_duration_ms` and `total_duration_ms` on
  different nodes. The values were identical. A test that compared SQL text or
  column names would have failed on correct answers.
- **An ambiguous question gets a reasonable, different answer.** "Clicks per page"
  had two honest readings, and the model took the one the test did not mean. Word
  a test question so that exactly one table answers it.
- **A refusal is a correct answer.** Half of the shard questions are supposed to
  be refused, and the refusal text is part of what is checked. A partial number
  would have been the real failure.
- **Every path needs a case.** The ClickHouse fallback was designed, reviewed and
  documented, but no test had a table that took it. One docker cluster with one
  pinned shard found the bug in its first run.
- **Keep the model on the side.** The models run on another host, reached by name
  with a client certificate. The cluster under test carries no model, no GPU and
  no local addresses, and it rebuilds from scratch in about two minutes.

## What is not built yet

DataFusion does not yet run over a table that no node holds whole: either a table
held on another node, or one sharded over several. Until it does, such a question
is answered from ClickHouse when ClickHouse has the whole table, and refused
otherwise.

## Run it yourself

This folder holds the whole test: [README.md](README.md) explains how to set it
up, [results.md](results.md) is the detailed record, and the scripts are in the
folder:

```
cp env.example .env     # the model service's client certificate, the yaxaha package
./build.sh              # the node image
./up.sh                 # a new cluster: nodes, data, config, ClickHouse (~2 min)
./test.sh               # the questions on all three nodes (~12 min)
```
