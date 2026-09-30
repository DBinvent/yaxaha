# Pipeline test: pgbench → Python → etcd queue → Python → ClickHouse

Exercises the full on-commit chain end to end on the 3-node lab cluster:

```
pgbench INSERT into public.bench_src
   │  cluster commit (cc=half), then CfgTabl.on_commit_python
   ▼
fn1  fn1_src_to_queue.py        reads the row, ETCD.put → /q/analytics/producer/<id>
   │  etcd queue
   ▼
fn2  fn2_queue_to_clickhouse.py reads live cluster ping status via yt_info('E'),
   │                            joins it with the original pgbench row,
   ▼                            and writes both through the CH python client
ClickHouse public.bench_analytics
```

`CH` is the ClickHouse client bound alongside `DB`/`ETCD` when the node has
`serve_clickhouse` on — the piece this test is really here to prove.

## Direct route: etcd queue straight into ClickHouse

A queue named **`/q/ch:<table>/`** or **`/queue/clickhouse:<table>/`** is
consumed by the etcd server itself — each message's JSON value is written into
that ClickHouse table as JSONEachRow, batched, with **no Python function, no
watcher and no PostgreSQL** anywhere in the path. `etcd_ch_queue_test.py` needs
nothing but an etcd client:

```bash
python3 etcd_ch_queue_test.py --etcd node1:7421 --ch node3:8123 \
                              --table etcd_events --count 200
```

```python
c.put("/q/ch:etcd_events/producer/1", json.dumps({"id": 1, "source": "etcd-client"}))
```

`ch:events` uses the configured database, `ch:analytics.events` names its own.
Needs the `clickhouse` cargo feature on ytserv (which turns on the etcds
`clickhouse` feature) and `clickhouse_url` in the module-`C` config. With no
endpoint configured the queue behaves like an ordinary one rather than dropping
messages, and a failed insert leaves the rows queued for the next attempt.

**Result: 200 of 200** produced messages landed in ClickHouse, both spellings
work, and ordinary watcher-driven queues are unaffected.

One bug this surfaced, in `etcds`: `get_or_create_queue` held a `queues.read()`
guard as the match scrutinee and took `queues.write()` inside the create arm —
a self-deadlock that wedged the whole node. It had never fired because every
queue used to be created by `create_watcher` (which takes the write lock
directly); a queue nothing watches is created by its first *put*, and hit it
immediately.

## Files

| file | what it is |
|---|---|
| `etcd_ch_queue_test.py` | etcd client -> `/q/ch:<table>/` -> ClickHouse, no Python function or PostgreSQL |
| `01_schema.sql` | rppd tables + `public.bench_src`, minus the `rppd_event()` triggers |
| `fn1_src_to_queue.py` | step 1, driven by `on_commit_python` |
| `fn2_queue_to_clickhouse.py` | step 2, driven by the etcd queue watcher |
| `02_register.sh` | registers both functions and arms the node config |
| `bench_insert.sql` | pgbench driver, one INSERT per transaction |

## Running it

On the **origin** node (the one pgbench writes to — `on_commit` fires there).
Note `rppd_config` is no longer set up here: ytserv fills it from the cluster
roster and puts `master` on the elected leader.

```bash
sudo -u postgres PSQL="psql -p 5434 -d pgbench" bash 02_register.sh
# then, synchronized on every node:
sudo systemctl restart ytserver
sudo -u postgres pgbench -p 5434 -n -c 2 -j 2 -t 10 -f bench_insert.sql pgbench
```

Prerequisites on the node that runs the Python (the embedded interpreter, so
system-wide, not a venv):

```bash
sudo python3 -m pip install psycopg2-binary etcd3 clickhouse_connect
```

and ClickHouse reachable from that node — it binds `127.0.0.1` out of the box,
so a remote origin needs a `<listen_host>` drop-in.

## Results (2026-09-15, ytserv 0.14.0, ClickHouse 26.8.4.11)

**The queue and the executor are fixed and lossless. What remains is upstream:
`on_commit_python` does not fire for every committed row under concurrency.**

| stage | result |
|---|---|
| pgbench → cluster commit | 20/20 and 30/30 transactions, 0 failed |
| `on_commit_python` → fn1 | **fires for every row**: 30 runs / 0 errors, 26 runs / 0 errors, 20 runs / 0 errors across runs |
| fn1 → `ETCD.put` | keys land; the queue drains to 0 afterwards |
| etcd queue → fn2 | **fixed and lossless** — every queued message is delivered, executed and acknowledged |
| fn2 → ClickHouse | works every time it is reached — table created, 1 row per cluster node |

What lands in ClickHouse per source row, one row per cluster node:

```
┌─src_id─┬─bid─┬─amount─┬─note───┬─node_uuid────────────────────────────┬─node_host─────┬─node_state─┬─rtt─┬─load─┬─cerr─┐
│      2 │   9 │    555 │ probe2 │ 923317b9-2117-576c-81d3-a7a9e997bc06 │ node1         │ Good       │   0 │    0 │    0 │
│      2 │   9 │    555 │ probe2 │ b069fece-2d5c-51b2-bf4d-67c940d504cf │ node2         │ Good       │  13 │    0 │    0 │
│      2 │   9 │    555 │ probe2 │ b8fac1a5-7c40-5dc0-a033-6c5aa173661d │ node3         │ Leader     │  23 │    0 │    0 │
└────────┴─────┴────────┴────────┴──────────────────────────────────────┴───────────────┴────────────┴─────┴──────┴──────┘
```

`rtt`/`load`/`cerr` are 0 for the local node because `yt_info('E')` reports
those only for *peers*; the self row carries `Pings: uptime/recent/took` instead.

### Root cause: three bugs, all fixed

**1. The etcd queue dispatcher dropped every wake but the first.**
`etcds` `queue.rs` guarded dispatch with `if x.idx > 0 && r != x.idx { continue }`.
`put` pushes to the **front** and notifies with the idx it just queued; the
dispatcher reads the **oldest** from the back. Those match only while exactly one
message is outstanding, so the second producer put stalled the queue for good.
The guard also threw away the kick `delete` sends after an acknowledge (it sends
`0`, never a real idx), so draining never restarted delivery either. The
notification is now only a wake-up: the dispatcher walks the backlog oldest
first, marking each message handed over. Dispatch is also bounded by a timeout
and drops a consumer that will not accept, so one dead watcher cannot wedge a
queue others are reading.

**2. An acknowledge deleted every message below it.**
`delete` did `retain(|v| v.idx > idx)` — a cumulative ack. But a consumer
acknowledges one specific key, and acks come back badly out of order (a burst
acked 2, 3, 1, 8, 9, 7, ...). Acking a high idx therefore silently discarded
every lower message still waiting to be dispatched. Now `retain(|v| v.idx != idx)`.

**3. rppd stalled permanently, and took the node with it.**
Two faults, both in `rd_config.rs`:
- *Drive-token leak.* The executor is token driven: each completed execution
  sends `None`, which picks the next queued item. Both paths that shelve an event
  because the context pool is at capacity returned without putting a token back,
  so every such event destroyed one. Once the in-flight work drained, the count
  hit zero and the node stopped executing while its queue still held work.
  `respawn_drive()` now guarantees one comes back (single outstanding retry).
- *Blocking Python on the async runtime.* `invoke()` runs the function
  synchronously and was called straight from an async task. The origin node has
  **one core**, so that blocked the only runtime worker for the whole call —
  starving the completions that return contexts and send tokens, the gRPC server
  (`curl error: Timeout was reached` on every INSERT) and the cluster ping/apply
  loops (`peer stream ack timeout`). Now wrapped in `block_in_place`.

Before: runs delivered 18, then 0, 0, 0, and the daemon stopped answering.
After: every run delivers and the cluster stays healthy throughout.

### Verified lossless, stage by stage

One pgbench run, counted at every hop:

| stage | count |
|---|---|
| pgbench inserted | 20 |
| etcd queue puts | 13 |
| dispatched | 13 |
| acknowledged | 13 |
| fn2 executed | 13 |
| ClickHouse rows | **13** |

**Every message that enters the queue now comes out the far end.** The queue,
the dispatcher, the acknowledge path and the executor are lossless.

### Still open: on_commit_python misses rows under load

The remaining shortfall is upstream of the queue: only 13 of 20 committed rows
fired `on_commit_python` at all. That is the `notify_data` / on-commit path in
ytserv (`cluster.rs`), not the etcd queue and not the rppd executor — both of
which are clean. Serial inserts do not show it; it appears with concurrent
clients.

## Three traps this test surfaced

1. **`rppd_config` is now maintained by ytserv, not by hand.** It used to need a
   hand-written row with `master = true`, or rppd answered every event with
   `[py] Internal error "not a master"`. `sync_rppd_config` now mirrors the
   cluster roster into the table on every heartbeat — one row per node, keyed by
   `host`, named by node UUID — and puts `master` on whichever node the cluster
   elected leader, calling `rppd.set_master()` so the running instance follows
   without a restart. Verified: forcing leadership with `yt_info('e:<node>')`
   moved `rppd_config.master` to the new leader **within 15 s**.

   The underlying trap it removes: a node that cannot find *itself* in
   `rppd_config` gets `id = 0`, so `start_bg`'s `select master … where id = $1`
   returns no row, `started` is never set, and every later event is refused with
   that same misleading "not a master".

2. **`rppd_function_log` broke rppd startup** — fixed in rppd: `SELECT_LOG`
   omitted `output` while `RpFnLog` has the field, so a restart with any row in
   the log table failed with `no column found for name: output`, left `started`
   false, and then reported the *misleading* `"not a master"` for every event.

3. **A read-only Python function must still end its transaction.** psycopg2
   opens one on the first `execute`, and rppd reuses the connection, so without
   a `DB.commit()` the backend sits `idle in transaction` holding ACCESS SHARE —
   enough to block `TRUNCATE`/DDL on the table indefinitely. Both functions here
   commit after reading; the note is in the code.

Also worth knowing: `yt_info()` returns **JSON**, not a record set, so
`SELECT … FROM yt_info('E') AS x(name text, …)` fails with *"a column definition
list is only allowed for functions returning record"*. Expand it with
`json_array_elements` instead.
