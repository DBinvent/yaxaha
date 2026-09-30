# yt_llm test: plain-language questions over PostgreSQL, DataFusion and ClickHouse

A yaxaha cluster on docker that answers questions in plain language through
`yt_llm`. The node asks a text-to-SQL model which tables a question needs, then
answers it where those tables are. It uses PostgreSQL for tables it holds whole,
DataFusion for the tables named in `llm_df_tables`, and ClickHouse for ClickHouse's
tables and for sharded tables that ClickHouse has in full. Every answer is graded
against a query written by hand. [report.md](report.md) tells the story of the
test: how a question is routed, the results, and the bug it found. The detailed
record of the last run is in [results.md](results.md).

## What runs where

| name | what | where |
|---|---|---|
| `yt1`, `yt2`, `yt3` | yaxaha nodes: PostgreSQL 18, the yaxaha extension and ytserv, DataFusion in `/opt/llm-df` (`node/requirements.txt`) | docker (containers `ytllm-yt1`...) |
| `ch1`, `ch2`, `ch3` | ClickHouse 26.9: cluster `yt`, one shard per node, Keeper on all three | docker (`ytllm-ch1`...) |
| `gpc:8080` | the model service: llama.cpp behind a mutual-TLS proxy | the Windows box `gpc`, outside docker |

Everything is addressed by name, in plain docker (`lib.sh`; no compose needed).
All six containers share the network `ytllm` under their short names. Each `ytN`
is also on a private network with its `chN`, where `chN` is also named `ch`. The one cluster-wide
ClickHouse setting, `http://ch:8123`, therefore makes every node read its own
ClickHouse node.

## The model service

**Host:** `gpc`, port **8080**, https with mutual TLS. It is installed and running
with the models below. This test only connects to it; nothing here installs or
changes it.

| model selector | model | used for |
|---|---|---|
| (default) | XiYanSQL-QwenCoder-7B-2504 | `sql`, `df`: PostgreSQL-dialect SQL |
| `route` | Qwen3-4B-Instruct-2507 | which tables a question needs |
| `ch` | Qwen2.5-Coder-7B-Instruct | ClickHouse SQL |

All three run on the CPU (`-ngl 0`). An answer takes seconds, and a long one takes
up to about 100 s. The endpoints are the OpenAI-style `/v1/chat/completions`:
`https://gpc:8080/…` for the default model, and `/route/…` and `/ch/…` for the
others. `/health` answers for each.

**Access** needs a client certificate issued by the box's own CA; without one the
proxy refuses the connection.
1. On the box, issue a client certificate: `client-cert.ps1 <name>` (from the llm
   scripts below). You get `ca.crt`, `<name>.crt` and `<name>.key`.
2. Copy the three files to the docker host, for example `~/llm-client/`, and name them
   in `.env`: `LLM_CA`, `LLM_CLIENT_CERT`, `LLM_CLIENT_KEY`.
3. Check the connection from the docker host:
   `curl --cacert ca.crt --cert <name>.crt --key <name>.key https://gpc:8080/health`.

The server certificate is issued for the name `gpc`. If the docker host cannot
resolve it, put the box's address in `.env` as `LLM_HOST_IP`: `up.sh` then maps
the name in the node containers, and `curl` needs
`--resolve gpc:8080:<address>`. Addresses go in `.env` only, never in a
committed file.

**Rebuilding the box**, for reference only: the service was set up with the llm
scripts of yt-pgxt (`llm/`). `prepare.ps1` fetches llama.cpp, the models and
Caddy, and makes the CA and the server certificate. `service.ps1 install` runs
one llama-server per model plus the proxy, as Windows services. `llm.env` lists the
models, and `agent.md` explains all of it.

## Run it

Requirements, on the docker host: docker with its own daemon (compose is not
needed), python3, OpenSSL 3, curl, and about 3 GB of free RAM. You also need a
yaxaha package, 0.16.7 or newer. The llm2 targets came in 0.15, and the
ClickHouse fallback for a pinned shard (R1) works from 0.16.7. It is built in
yt-pgxt with `cargo deb -p yxctl --no-build`.

```
cp env.example .env     # the client certificate, the package; YTLLM_DOCKER_HOST
./build.sh              # the node image ytllm-node, and the ClickHouse image
./up.sh                 # a new cluster: nodes, data, config, ClickHouse (~2 min)
./test.sh               # the model service, the cluster, the questions (~12 min)
./down.sh               # remove it all
```

`test.sh` writes `results/run-<time>.log` and exits 0 when nothing failed. It asks
every question on all three nodes: each answers from its own view, meaning its own
ClickHouse node and its own third of each shard. Each node calls the model itself,
so `TEST_NODES=yt1` takes about a third of the time.

## What up.sh configures

The same rows go into `public.yt_config` on every node. The row `C cfg_ready` is
written last, and ytserv starts on it.

| module | rows | |
|---|---|---|
| `N` | `yt1:7421`, `yt2:7421`, `yt3:7421` | node uuids are uuid5 of the host name, like `yxctl --peers` |
| `C` | `cluster` | a new cluster uuid for each run |
| `C` | `min_cluster_size` 3, `tcp_timeout_ms` 2000, `log_level` info | |
| `C` | `serve_llm`, `llm_host` (`gpc:8080`), `llm_ca` / `llm_cert` / `llm_key` | the last three name the `K` rows |
| `C` | `llm_model_route` (`route`), `llm_model_ch` (`ch`) | `sql` and `df` use the default model |
| `C` | `llm_df_python` (`/opt/llm-df/bin/python`), `llm_df_tables` (`shop.products,shop.order_items`) | the df target |
| `C` | `clickhouse_cluster` = `cluster.xml` verbatim | ytserv fills in `<secret/>` and writes the file its ClickHouse node reads (`ch/wait-cluster.sh`) |
| `K` | `llm.ca`, `llm.cert`, `llm.key`, `clickhouse` | encrypted with ytserv's app key, which is new for each run (`run/`). `clickhouse` is the read-only user `llm_ro`, `http://ch:8123`, and the inter-server secret |
| `A` | `shop.customers`, `shop.orders`, `shop.products`, `shop.order_items` | synced, whole on every node |
| `A` | `shop.web_events`, `shop.clicks` | pinned shards: `shard=owner; outer=pin`. The `owner` column names the node that holds the row |
| `A` | `shop.sessions`, `shop.refunds` | ring-hash shards: `shard=id; outer=reject`. The owners follow the live ring, and a non-owner keeps nothing |

The sample data is `data/pg.sql` on every node and `data/ch.sql` in ClickHouse, both
deterministic. Each yaxaha node loads its own third of each sharded table, and a
pinned row names that node as its owner. ClickHouse holds all the rows of
`shop.web_events` and `shop.sessions`, and has no `shop.clicks` or `shop.refunds`.

**yt_llm treats the two kinds of shard differently.** A pinned table is on the
DataFusion list as "sharded: each holder has only its own rows". A question over
it goes to ClickHouse when ClickHouse has the table, and the answer says so.
Otherwise it is refused. A ring-hash table is left off every list, because its
owners follow the live ring and there is no stable split (yt-pgxt `df-todo.md`
§0.3). So ClickHouse's table of the same name answers as a table of its own, and
a question needing the PostgreSQL one is refused.

## The questions

| | question | answered by | graded against |
|---|---|---|---|
| S1 | How many customers are there in each country? | PostgreSQL | the same query by hand |
| S2 | How many delivered orders were placed by customers of each country? | PostgreSQL | a join by hand |
| D1 | How many products are there in each category? | DataFusion | PostgreSQL by hand |
| D2 | What is the total quantity ordered for each product category? | DataFusion | a join in PostgreSQL |
| C1 | How many page views came from each country? | ClickHouse | ClickHouse by hand |
| C2 | What is the total view duration in milliseconds for each device type? | ClickHouse | ClickHouse by hand |
| R1 | How many web events of each type are there? | ClickHouse, for a pinned shard | ClickHouse by hand; the answer must say "not whole on this node" |
| R2 | How many times was each button clicked? | nobody: a pinned shard ClickHouse does not have | the refusal names P4/P5 |
| R3 | How many sessions came from each channel? | ClickHouse's own table: the ring-hash shard is off the lists | ClickHouse by hand |
| R4 | What is the total refund amount for each reason? | nobody: a ring-hash shard ClickHouse does not have | a refusal ("no target here answers") |

For each answered question, the test checks:
- the engine that answered;
- the rows of a page (`yt_llm_query`);
- the rows of `yt_llm()`, compared as sets of values.

A df answer's plan and script are checked too.

**Not built, so tested as a refusal:** DataFusion over a table no node holds whole
(yt-pgxt `llm/llm2.md` P4, P5). A question over such a table is answered from
ClickHouse when ClickHouse has every table of it. Otherwise the node refuses; it
never gives a partial number. R4 depends on the model more than the others: the
table is on no list the model sees, so what it writes for the question is its
own guess, and the node refuses whatever that reads.

## Files

| file | |
|---|---|
| `lib.sh` | the six containers and their networks (`node_run`, `ch_run`), and the helpers |
| `node/` | the node image: `Dockerfile`, `entrypoint.sh`, `requirements.txt` (datafusion, pyarrow) |
| `ch/` | Keeper (`keeper.xml`), and the ClickHouse entrypoint that waits for the rendered cluster file |
| `cluster.xml` | the ClickHouse cluster, as stored in `yt_config` |
| `data/pg.sql`, `data/ch.sql` | the sample data |
| `data/grade.sql` | how an answer is graded |
| `build.sh`, `up.sh`, `test.sh`, `down.sh` | the scripts |
| `env.example` | the settings, to copy to `.env` |
| `report.md` | the article: how a question is routed, the test, its results and the bug it found |
| `results.md` | the last run, in detail |
