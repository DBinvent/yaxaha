# Cluster test 1 — replication cost profile, 2026-09-13

Where the time goes in a 3-node yaxaha cluster, measured against PostgreSQL's
own synchronous replication on the same hardware and network. Includes four
fixes made during the run and the evidence for each.

## Environment

| | |
|---|---|
| node1 | origin / tx source. Ubuntu 22.04, glibc 2.35, **PG 16.15** on port **5434**. Also PG18 `repl` on 5433 (the PG-replication primary). |
| node2 | peer. Ubuntu 26.04, glibc 2.43, PG 18. |
| node3 | peer. Ubuntu 26.04, glibc 2.43, PG 18. |
| network | 1000 Mb/s NICs, **ICMP RTT 0.75 ms** (min 0.63) — note: 4-8x slower than a healthy gigabit LAN (0.1-0.2 ms). TCP connect to :7421 mean 1.85 ms / min 0.68 ms. |
| clocks | in sync (same epoch); node1 logs **CDT**, peers **UTC** (peer time = node1 + 5 h). |

Workload throughout: `pgbench` scale 5, **c=1** unless stated, custom script
`s2.sql` = one transaction with **two** UPDATEs (`pgbench_branches` bid=1 +
`pgbench_tellers` tid=1), which is the worst case for row contention.

Every cluster run started from a known-good state: cluster WAL wiped
(so checkin cost is not skewed by WAL file size), synchronized restart of all
three `ytserver`s, leader elected, tables resynced and verified converged.

## Headline numbers

Base for the percentages is **PG built-in synchronous replication to 2 remote
standbys** (`synchronous_standby_names = FIRST 2 (node2, node3)`,
`synchronous_commit = on`) — the same boxes, same wire, same script.

| config | ms | tps | vs PG sync |
|---|---|---|---|
| PG async replication | 1.86 | 539 | 0.45x / 224% |
| **PG sync repl, 2 standbys** | **4.15** | **241** | **1.0x (base)** |
| PG sync repl, 1 standby | 4.03 | 248 | 1.0x / 103% |
| yt `cc=NODES at_least=0` (eventual) | 8.29 | 121 | 2.0x slower / **50%** |
| yt `cc=half` (synchronous 2PC) | 23.6 | 42 | 5.7x slower / **18%** |
| no trigger at all (reference) | 1.42 | 704 | — |

Comparing the cluster to a bare local transaction (the old "98% drop" figure)
is not meaningful — PG sync replication on this network already costs 2.9x a
local commit. Against the honest baseline the cluster is **2x** (eventual) to
**5.7x** (synchronous) slower.

## Why: round-trip count, not any single slow component

Per-transaction stage breakdown. "waits" is what the origin blocks on;
"work" is what the remote node reports it actually spent.

```
cc=half  (23.6 ms)
  per stmt: checkin 2.24   set_data 0.28   modify-fanout 3.43
  per tx  : checkin 4.48 | modify 6.86 | xa PREPARE 3.05 | xa COMMIT 5.11 = 19.50 waits
  remote  : leader 1.54 | party modify 4.12 | xa PREP 1.95 | xa COMMIT 3.60 = 11.20 work
  NETWORK WASTE 8.30 ms = 34% of tx

cc=NODES0 (8.3 ms)   <- only checkin is remote; no party, no 2PC
  per tx  : checkin 4.34 | modify 0.02 | xa 0.14                          =  4.50 waits
  remote  : leader 1.54                                                   =  1.54 work
  NETWORK WASTE 2.96 ms = 34% of tx
```

Waste is **34% in every configuration** — it tracks round-trip count and nothing
else. A 2-statement `cc=half` transaction makes **6 sequential remote round
trips**: checkin + modify-fanout per statement, then PREPARE, then COMMIT.

Cost scales with **statements, not transactions** — `checkin` is a synchronous
RTT to the leader on every write statement. Measured directly:

| statements / tx | 1 | 2 | 3 |
|---|---|---|---|
| latency | 22.70 ms | 39.31 ms | 44.08 ms |

fits **~11 ms fixed (2PC) + ~10.7 ms per statement**.

PG sync replication does the same durability job in **one** round trip, and
ships to both standbys **in parallel** — which is why 1 standby (4.03 ms) and
2 standbys (4.15 ms) are nearly identical. 6:1 round trips ≈ the 5.7:1 latency.

### Is the waste network, protobuf, or Rust async?

`NODES0` isolates a single hop cleanly: **2.21 ms origin wait for 0.75 ms of
leader work → 1.46 ms transport per round trip.** Split:

| component | per round trip | share |
|---|---|---|
| wire (measured ICMP RTT) | 0.76 ms | **52%** |
| tonic / HTTP2 / tokio scheduling | ~0.70 ms | **48%** |
| protobuf ser/de | **0.0022 ms** | **0.15%** |

Roughly **50/50 network vs our async stack; protobuf is a rounding error.**
Protobuf measured directly — see `ytcluster-types/src/lib.rs::serde_cost`
(`cargo test -p ytct serde_cost --release -- --ignored --nocapture`): a
149-byte `DbInputEntity` costs 0.40 us encode / 0.70 us decode, so all four
operations of a round trip total 2.2 us. Serialization is not worth optimizing.

Half the wire cost is environmental — 0.75 ms RTT on gigabit is poor. On a
normal LAN (~0.15 ms) transport would be ~0.85 ms/hop instead of 1.46 ms,
putting `cc=half` near 20 ms. It does not change the ranking: PG pays the same
slow wire and still lands at 4.15 ms, because it crosses it once.

### The local (non-network) share

Client-side, with `cc=ignore` so nothing propagates, the trigger's own cost is
4 unix-socket gRPC calls/tx at ~415 us each. Of one call:

```
total 430 us = lock 0.15 + setup 7.9 + perform 415 + post 1.3 + codec 8.0
```

**96% is inside `curl_easy_perform`** — libcurl's own HTTP/2 work (~11 syscalls
per call, a 2x`getsockname` + 2x`poll(0)` reuse-check preamble, and a split
`sendto` for HEADERS then DATA). protobuf-c is 8 us. gRPC-over-HTTP2 is heavy
for a local unix-socket call to our own daemon.

## Fixes made during this test

### 1. `ModifyReply.skip_complete` — skip no-op completion calls

`db.proto` gains `bool skip_complete = 3`. True when the server registered no
`TxData`, so the matching `complete()` would take `cluster_complete`'s
`tx.remove() -> None` branch and do nothing. The trigger then leaves
`g_txn_dirty` unset and skips both the PREPARE and COMMIT round trips.

- Stamped once in a `cluster_save()` wrapper from the tx map — not at each of
  the five early returns inside, so a return added later cannot get it wrong.
- Client side is `if (!reply.skip_complete) g_txn_dirty = true;` — **OR-in,
  never clear**: a transaction can touch several tables, and one statement
  needing no completion must not undo an earlier one that does.
- Sense is deliberately negative so the proto3 default (false) = "call
  complete" = old behaviour, safe against version skew.
- **`ModifyReply.result` must NOT be used for this** — it is the peers' summed
  affected-row count, so a legitimate 0-row apply is indistinguishable.

Measured back-to-back A/B: **c=1 282 -> 358 tps (+27%), c=8 803 -> 1078 tps
(+34%)**. Verified 500 tx -> 1000 modify / **0** complete; at `cc=half` it
stays false (1 modify -> 2 complete) and all 3 nodes converge, 0 prepared-xact
leaks.

### 2. Apply ordering — the zero-row apply (the important one)

**Symptom:** at `cc=NODES0`, 298 of 300 applies logged
`cluster_event_applied: 0 rows` and were accepted as success; nodes never
converged. Same defect hit the non-party node under `cc=half`.

**Not a `build_sql` bug.** The generated SQL chain is perfectly sequential —
each apply's `WHERE <col> = <old>` exactly matches the previous apply's new
value:

```
-30499 -> -30433 -> -30376 -> -30340 -> -30264 -> -30210 -> -30112 -> -30109
```

and with a **2-second gap** between transactions the same path applied
**100% correctly** (verified step by step on all 3 nodes).

**Root cause:** `ytserv/src/ycluster/lib.rs` spawned *every* DB command:

```rust
Some(e) => { tokio::spawn(async move { cluster_event_handler(e, logc).await; }); }
```

so applies had no ordering. Apply N+1 read the row before apply N committed,
its optimistic WHERE matched nothing, and the 0-row result was swallowed. Only
visible under rate, which is why it looked like a concurrency bug.

**Fix:** a dedicated single-consumer queue for `DbCmd::Apply` (awaited inline,
never spawned), so applies are strictly ordered among themselves while
`Modify` / `Status` / `DataVersion` stay fully concurrent.
`APPLY_QUEUE_SIZE = 1024` bounds the burst before back-pressuring the peer —
the correct response to a node that cannot keep up, rather than reordering its
writes.

**Result:**

| | before | after |
|---|---|---|
| `cc=NODES0` zero-row applies | 298 / 300 | **0 / 300** |
| `cc=NODES0` convergence | DIVERGED | **CONVERGED** |
| `cc=NODES0` throughput | 8.71 ms / 115 tps | **8.29 ms / 121 tps** |

Slightly *faster*, because ordering is on the async apply path, not the
origin's critical path. Convergence now also holds **under concurrency**:

| config | c=4 | c=8 |
|---|---|---|
| `cc=NODES0` | 110.8 tps, **CONVERGED** | 93.3 tps, **CONVERGED** |
| `cc=half` | 41.1 tps, **CONVERGED** | 42.7 tps, **CONVERGED** |

all with 0 failed transactions. This closes the long-standing "concurrent load
diverges on hot small tables" issue.

### 3. `cluster_wal` — make the cluster WAL's disk writes optional

New `SmCfg.cluster_wal`, module-`C` row, default `2`. `2` = full disk WAL;
`1`/`0` = memory-only (the in-memory cache is still maintained, so conflict
detection and `data_version` keep working; only the file append and state patch
are skipped — not recoverable across restart). One `wal_to_disk()` helper
guards the two disk seams in `state/wal.rs`.

Motivation: the leader's `do_handle_checkin` spends ~93% of its service time in
`insert_with_state`'s file write, and checkin is on the critical path of every
write statement:

```
do_handle_checkin total 894us = scan 33 (scanned 2 of cache 2) + mid 19 + wal 833
```

Repeated alternating A/B:

| `cluster_wal` | latency | tps | leader checkin | of which WAL |
|---|---|---|---|---|
| 2 (disk) | 24.10 / 24.60 ms | 41.5 / 40.6 | 1061 / 772 us | 997 / 719 us |
| 1 (memory) | 19.03 / 20.36 ms | 52.5 / 49.1 | 80 / 73 us | 35 / 34 us |

**+24% throughput**; the WAL write itself drops 25x and leader checkin 12x. But
total latency improves only 19%, because checkin is one of six hops — which
bounds the WAL's contribution as real but secondary.

**Not hot-reloadable** — verified: changing the row on a running cluster does
nothing, `ytserver` must be restarted. Same limitation as the other C-module
knobs blocked in `upgrade_cfg_table_cache`.

### 4. `clear_cache()` retain was inverted

`state/wal.rs` — `retain` keeps what matches, so `k <= to_subterm` kept every
subterm already completed cluster-wide and dropped the in-flight ones, the
opposite of both `set_subterm_state`'s `retain(k >= least)` and the
commented-out correct form in `update_cluster_completed`. Now `k > to_subterm`.

Correctness fix only — **no measurable performance effect.** An earlier
hypothesis that an unbounded conflict scan was the checkin cost was **refuted**
by instrumenting it: the scan visits ~2 cached subterms and costs 33 us;
eviction works. (The earlier observation that wiping the WAL gave +75% is real
but is WAL *file size* making `push_record` slower, not cache growth.)

## Configuration notes

`cluster_commit` / `wal` live in the module-`A` row as base64 `ConfigValue`:

| config | base64 |
|---|---|
| cc=half, wal=none | `CgYSAhABGgA=` |
| cc=half, wal=half | `CggSAhABGgIQAQ==` |
| cc=NODES at_least=0, wal=none | `CgYSAhACGgA=` |
| cc=NODES at_least=0, wal=half | `CggSAhACGgIQAQ==` |
| cc=ignore, wal=ignore | `CgQSABoA` |

Read back live (no restart) with `yt_info('a:<schema.table>')`.

**`wal` is still unwired** — `push_wal_save` fired **0** times in every
configuration tested, so `wal=half` and `wal=none` are the same run twice. The
2-5% gaps between those pairs are run-to-run noise.

**`cc=ignore` with `at_least=0` is OFF, not eventual.** `catalog/mod.rs` sets
`propagate = false` for it, so the write never enters `cluster_save`: nothing is
recorded, and nothing is ever applied — confirmed by polling 5 minutes with
zero applies. The eventual mode is **`cc=NODES` with `at_least=0`** (or
`cc=ignore` with `at_least > 0`, which parks the record on N peers).

`peer_stream` (yt streaming) is on by default here and was on for every
measurement above. Streaming vs unary at `cc=half`, alternated:

| | ms | tps |
|---|---|---|
| `peer_stream=0` (unary) | 25.65 | 39.1 |
| `peer_stream=1` (stream) | 23.69 | 42.2 |

**~8% better with streaming.**

## What is left

- **Cut round trips.** The best remaining lever: one checkin per *transaction*
  instead of per statement, and overlapping checkin with the modify fan-out
  (strictly sequential today). Worth ~3-5 ms of the 23.6. Matching PG's single
  ack round trip is a protocol change, not tuning.
- **A 0-row apply is still silently accepted.** Ordering removes the cause seen
  here, but the swallow remains: it should raise divergence
  (`EntityState::Collision` + the `divergent` counter + audit) so a genuine
  conflict is detected rather than lost.
- **`wal` field unwired** (above).
- **`cluster_wal` not hot-reloadable** (above).
- The local trigger path still costs ~415 us/call, 96% inside
  `curl_easy_perform`. gRPC-over-HTTP2 is heavy for a local unix socket; a
  length-prefixed protobuf straight over the socket would be ~20 us.

## Reproducing

Harness used for every cluster row above (wipe WAL, synchronized restart, wait
for leader, resync, verify converged, run, collect all three node logs):

```
NODE1=<address> NODE2=<address> NODE3=<address> \
  bash cluster-test1-matrix.sh <label> <A-row base64> <tx count>
```

`NODE1` is the write origin (PostgreSQL on port 5434, the workload at
`/tmp/s2.sql`), and each address is the one the cluster's N rows give the node.

Per-stage numbers come from `[YT_CHAIN]` lines in `ytserver.log` on all three
nodes, correlated with `[YT_CALL]` start/end markers the C extension writes to
the PostgreSQL log when `YAXAHA_PROF` is set in the postmaster environment
(Debian/Ubuntu: `/etc/postgresql/<ver>/<cluster>/environment`).

## Appendix — hot-path async/lock cleanup (same session)

Driven by the profile above: `before_save_cmt` runs on every write statement and
`checkin` on every statement cluster-wide, so redundant guard acquires and
needless futures there are paid per statement.

**Removed redundant lock acquires**

- `checkin.rs do_handle_checkin` — `CcMode::All` re-locked `self.nodes` to get a
  length already computed two lines above as `n`.
- `cluster.rs before_save_cmt` — took `self.nodes.read()` once for `.len()` on a
  throwaway guard, then again to walk the peers. Now one guard, still scoped so
  it is released before the `sm`/`api1` work (holding it longer would widen
  contention with `nodes.write()`).
- `wal.rs insert_with_state` — one `cfg.read()` now serves both the
  `cluster_wal` durability check and the `fs_max_file_size` roll limit (the
  second acquire had been introduced with `wal_to_disk()`).

**Made sync (were `async` with no `.await` in the body)**

- `SmVo::api1()` — pure struct constructor; built on every write statement and
  every wal-api/checkout message. 13 call sites updated.
  `StateMachine::api1()` stays async — it does `self.sm.read().await`.
- `update_term_stats()` — atomics only; runs on every apply.
- `maps_len()` — `try_read()` is non-blocking.

**Aggregated conditionals**

- `before_save_cmt` — `PeerState::Off(_)` was listed in its own arm *and* in the
  next one, so the second copy was unreachable and both returned the same
  message. One arm now, and it names the state.
- `update_term_stats` — both branches built the same `EntityKey` with the same
  `term`; only subterm/version differed. Folded to one construction over a
  `(subterm, version)` match, and `data.last()` replaces `data[data.len()-1]`.

**Deliberately left alone**

- `wal.rs` `insert_with_state` / `set_subterm_state` double `cache` acquire —
  the `[wal-lock-order]` invariant requires releasing `cache` before taking
  `pm`/`file`; merging would recreate the AB-BA deadlock that was fixed earlier.
- `cluster_complete`'s two `nodes.read()` — separate 2PC phases split by network
  awaits; one guard would hold the lock across RTTs.
- `cluster_save_inner` / `cluster_prepare` double `tx.write()` — mutually
  exclusive match arms doing different things (insert vs remove) inside a loop
  that awaits.
- `paging.rs get_or_load_page_locked` — its `None` branch is `unimplemented!()`
  and will need disk I/O, so it must stay async.
- `to_vo`, `drop_page`, `end_file` — zero callers.

**Regression after the refactor** (deployed to all three nodes):

| config | c=1 | c=4 | c=8 |
|---|---|---|---|
| `cc=half` | 41.5 tps CONVERGED | 41.3 CONVERGED | 43.2 CONVERGED |
| `cc=NODES0` | 111.0 tps CONVERGED | 96.5 CONVERGED | 93.9 CONVERGED |

0 failed transactions throughout; throughput unchanged within run-to-run noise.

## Appendix 2 — prepared statements (2026-09-14)

**Question: were prepared statements in use, and what was the hit rate?**
No, and **0.0%**: `0 hit / 0 prep / 1260 raw` on both peers, `pg_prepared_statements`
empty on every node. The `[stmt-cache]` machinery was shipped and enabled
(`stmt_cache_size=10`, warmup 10/10s) but could never fire, for two independent
reasons:

1. **`build_sql` inlined literals.** Its signature returned a params vec, but
   `let params = vec![];` was never appended to and it was called as
   `execute(&build_sql(e), &[])`. Both `STMT_CACHE` and its `STMT_WARMUP` gate
   are keyed by the **full SQL text**, so every statement was a new key and the
   "same shape 10x in 10s" gate was never reachable.
2. **The column order was not stable.** `old_data`/`new_data` are proto `map<>`
   (HashMap) and `hash_to_str` iterated the data map, so the same statement came
   out as `set bbalance = .., bid = ..` one time and `set bid = .., bbalance = ..`
   the next.

Worse than useless: with 100% unique keys, every apply took the `STMT_WARMUP`
mutex, allocated `sql.to_string()`, and ran an O(n) `retain` over every distinct
statement seen in the last 10 s (~2300 entries at 115 tps) — and promoted nothing.

**Cost of not having it**, measured (trigger off, same 2-statement script,
3000 tx): `-M simple` 1.563 ms / 640 tps vs `-M prepared` 1.371 ms / 729 tps =
**~0.096 ms of parse+plan per statement**, i.e. ~0.19 ms per `cc=half`
transaction — **under 1% of 23.6 ms**. Not a latency lever; it is peer CPU.

### Fix 1 — `build_sql` is now parameterised, with a stable shape

```
update public.pgbench_branches set bid = $1, bbalance = $2  where bid = $3 and bbalance = $4
update public.pgbench_tellers  set tid = $1, tbalance = $2  where tid = $3 and tbalance = $4
```

- New owned `SqlVal` enum implementing `ToSql`. Owned because the Rust type has
  to match the column's Postgres type (an `int4` column will not accept an
  `i64`), so the converted value needs somewhere to live.
- `bind_param(atttypid, v)` picks the exact type from the column's type OID
  (bool/int2/int4/int8/float4/float8/text/varchar/bpchar). **Anything unmapped
  returns None and keeps being inlined as a literal**, so an exotic column type
  costs a cache miss, never a broken apply.
- The walk is driven from `columns` (a `BTreeMap`, attnum order) instead of the
  data `HashMap`, making the shape deterministic.
- SET placeholders are pushed before WHERE ones so `$n` order matches textual
  order. Covered by 4 unit tests in `ycluster::core::build_sql_param_tests`
  (ordering, shape stability across differing values, unmapped-type fallback,
  insert/delete).

### Fix 2 — the statement cache is now OFF by default, because it is unsound

Turning the shapes stable made the cache actually promote statements for the
first time — and that exposed a **pre-existing latent bug**:

| | applies | zero-row | result |
|---|---|---|---|
| cache ON (`stmt_cache_size=10`) | 10 effective | **290** | **DIVERGED** |
| cache OFF (`stmt_cache_size=0`) | 150-200 effective | **0** | **CONVERGED** |

Failure begins at exactly the 11th execute of a shape — i.e. the moment
`STMT_CACHE_WARMUP=10` promotes it from raw to prepared. Logged parameters are
provably correct across the transition (a clean chain
`484827 -> 484850 -> ... -> 485346 -> 485426`), so the SQL and the bound values
are right; only the *prepared* execution returns 0 rows.

Root cause: a tokio_postgres `Statement` is only valid on the Client it was
prepared on, but `conn_id()` keys the cache on that Client's **pointer address**,
which bb8 recycles when a pooled connection is dropped and remade — so a "hit"
can hand back a statement belonging to a different physical connection. The apply
path uses the shared pool (`max_size` = `max_prepared_transactions`, floor 32).
Corroborating: **25 "stale statement" retries** and **437 prepares for only 2
distinct shapes** in one 300-tx run.

Honest limit: the cache is *proven* to cause the divergence (on/off is decisive)
and cross-connection reuse is strongly evidenced, but the exact path by which a
mismatched statement yields **0 rows rather than an error** was not pinned down.

`stmt_cache_size` now defaults to **0**, with the reasoning recorded in
`rmc.rs`. The sound fix is to hold the statement map **inside** the connection
object — a custom bb8 manager wrapping `Client` + its own
`HashMap<String, Statement>` — or to give the now-serialised apply path a single
dedicated connection. Either makes a cross-connection hit structurally
impossible. Given the measured payoff is under 1% of transaction latency, that
was not worth doing blind in this pass.

### Fix 3 — dedicated apply connection; cache is sound and back ON

The apply path now runs on **one dedicated non-pooled connection per database**
(`ycluster::core::ApplyConn`), with the prepared-statement map held **inside**
it. `conn_id()` (the pointer-address key) and the global `STMT_CACHE` are gone,
so a statement can only be reached through the very Client that prepared it —
the mismatch is not guarded against, it is unrepresentable.

This composes with [apply-order] rather than duplicating it: applies were already
single-consumer, so the pool was buying nothing there — a checkout per subterm
for work that never ran concurrently. The guard is taken per `WalData`, not per
batch, so `yt_info`'s `stmt_cache_stats` is not blocked behind a whole batch.
`STMT_WARMUP` stays global and SQL-keyed on purpose: "is this shape hot" is a
workload property; only the `Statement` is connection-local.

**Verified 2026-09-14 with `stmt_cache_size=10`:**

| | before (pooled, pointer-keyed) | after (ApplyConn) |
|---|---|---|
| hit rate | 24.2% | **98.4%** (1240 hit / 2 prep / 18 raw) |
| prepares for 2 shapes | **437** | **2** |
| live statements | 2 | 2 |
| stale-statement retries | 25 | **0** |
| zero-row applies | 290 / 300 | **0 / 300** |
| result | **DIVERGED** | **CONVERGED** |

Convergence also holds under load — `cc=half` c=1/4/8 = 43.0 / 41.9 / 41.8 tps
and `cc=NODES0` c=1/4/8 = 133.2 / 93.5 / 96.5 tps, all CONVERGED, 0 failed.
`stmt_cache_size` now defaults to 10 again.

Two notes. The 18 raw and 2 prep are one-time warm-up (10 executes per shape
before promotion), so steady state is ~100%. And the prepares are **wire-level**
(extended protocol), so they do not appear in `pg_prepared_statements` — that
view only lists SQL-level `PREPARE`s.

**Net:** SQL is parameterised and deterministic, the statement cache is sound and
at ~98% hit, and the apply path is correct — 300/300 effective, 0 zero-row,
CONVERGED at every concurrency tested. As predicted this does not move
transaction latency (the cache is on the async apply path, off the origin's
critical path); the gain is peer CPU — parse+plan was ~0.096 ms per applied
statement.
