# bench/cluster — pgbench, cluster manner

The runnable side of yt-pgxt's `clusterTODO.md` and `../../BENCH.md` §2/§8. A
multi-host driver that runs `../stream.sql` — one disjoint data stream per
node — across the real hardware cluster, started together, then quiesced and
checked for convergence.

`cargo make` / `node.toml` is a single-box process supervisor and cannot
drive N machines (REVIEW.md, BENCH.md §8.2). This is bash + `ssh` instead of
Ansible on purpose: it matches the rest of this suite's idiom and needs no
control-node setup. Everything it does on a node is a `psql` / `pgbench` /
`systemctl` call over `ssh`.

## The goal

Two numbers, from one rig:

1. **Data reliability.** After the load stops and the cluster settles, every
   node holds identical data (`digest.sql` compare) and pgbench's TPC-B
   invariant holds on each node. A disagreement **fails the run** — a
   throughput number from a cluster that lost or diverged a write is not a
   result (BENCH.md §5).
2. **Performance degradation.** `nosync` per-node TPS is the denominator;
   `nodes1` is the numerator. The `tps` gap in the CSV between
   the `nosync` rows and the `nodes1` rows — same box, same script,
   same scale — is the synchronisation tax, separately for the two
   consistency levels.

## The conditions

`stream.sql` gives every node a disjoint `bid` range, so the tables never
collide *by workload* and the only cross-node work is whatever the sync mode
asks for. What changes between runs is **how the `pgbench_*` tables are
registered with YaXaHa** — i.e. the per-table `cluster_commit`:

| cond | `cluster_commit` | client's COMMIT returns after… | write-time consistency guard | measures |
|---|---|---|---|---|
| `nosync` | (table not registered) | local commit only | none | per-node capacity, daemon idle — the denominator |
| `nodes1` | `ClusterCommitNodes{at_least:1}` (base64 `CgQiAggB`) — see `cluster_commit.b64` for the coupling with the ytserv `+1` patch | **origin only**, but after `checkin` conflict-check + ordering | **yes** — a write that would collide with a concurrent write on another node is aborted at commit; peers get it via async `apply_all` | eventual-but-guarded replication throughput + end-of-load convergence lag |

`nodes1` is **not plain async replication**: the origin runs `checkin`
(conflict detection + `term.subterm` ordering) before the local commit, so
the cluster cannot silently diverge the way two async primaries would — the
async part is only the fan-out of an already-vetted, ordered change. It sits
between async replication and synchronous quorum. `ClusterCommit::Ignore`
(base64 `CgIqAA==`) is the "not replicated at all" mode — a table opted out
of sync entirely — and is **not** a bench condition here.

The base64 in `cluster_commit.b64` is a `ConfigValue{ table{ cluster_commit } }`
protobuf; `yt_ct_encode()` is a stub, so these are precomputed.

## What `nodes1` needs from the engine (`nosync` needs none of this)

`nosync` is a plain pgbench target and runs today. `nodes1` needs two pieces,
both now handled:

1. **`at_least` — handled by config, no patch required.** The bench encodes
   `ClusterCommitNodes{at_least:1}` (`CgQiAggB`), which on **stock ytserv**
   gives `party_size` / `min_commit` = 0 → origin-only commit + async
   `apply_all`. The `{at_least:0}` value (`CgIiAA==`) hits a `0usize - 1`
   underflow on stock ytserv and only works with the `+1` patch in
   `checkin.rs` / `cluster.rs` — with that patch deployed, set
   `BENCH_NODES1_B64=CgIiAA==` (then `{at_least:1}` means origin + 1
   *synchronous* peer instead). `cluster_commit.b64` has the full table.

2. **Transaction completion — no PgBouncer needed.** `ytpgc/src/yaxaha.c`
   does `RegisterXactCallback` in `_PG_init` behind a `yaxaha.auto_complete`
   GUC (default on): a transaction that fired `yt_synchronize()` is completed
   into the cluster at `XACT_EVENT_PRE_COMMIT` (rollback at
   `XACT_EVENT_ABORT`), so a plain `COMMIT` is a cluster commit with **no
   explicit `yt_complete()` and no PgBouncer**. Verified on node2/node3
   (`case1`/`case2`: node=1 async and node=2 sync both propagate). The harness
   defaults to `BENCH_VIA_PGBOUNCER=0` — direct connect — so `nodes1` is a
   byte-for-byte copy of the `nosync` pgbench target, only the sync
   registration differs. `BENCH_VIA_PGBOUNCER=1` is a legacy fallback that
   routes through a patched PgBouncer (`:6432`, XA patch injects
   `yt_complete`) for a build with `auto_complete` disabled.

The `.so` with `auto_complete` is built by `ytpgc/build-all-ytpgc.sh 18` and
shipped in the `yxctl` deb — a cluster node never compiles it.

## Run

```sh
cp nodes.example nodes            # edit: one ssh target per line
BENCH_SSH='ssh -i ~/.ssh/lab_cluster_ed25519 -o BatchMode=yes' \
  ./run.sh nodes nosync
./run.sh nodes nodes1
```

Output: one CSV row per `(config, cond, nodes, node, run)` in
`results/<suite>.csv`, plus a summary. Exit is non-zero if any run diverged,
timed out converging, or failed the TPC-B invariant — a throughput number
from a cluster that lost writes is not a result (BENCH.md §5).

### Env

| var | default | |
|---|---|---|
| `BENCH_SSH` | `ssh -o BatchMode=yes -o ConnectTimeout=8` | ssh command prefix |
| `BENCH_DB` | `pgbench` | database on each node |
| `BENCH_ROLE_CMD` | `sudo -n -u postgres` | how to become the pg superuser on a node (prefix for `psql`/`pgbench`) |
| `BENCH_PGPORT` | `5432` | Postgres port on each node (overridable per line in `nodes`) |
| `BENCH_SCALE` | `max(20, nodes*10)` | pgbench `-s`; BENCH.md wants ≥ `nodes*10` |
| `BENCH_CLIENTS` / `BENCH_JOBS` | `8` / `2` | pgbench `-c` / `-j`, per node |
| `BENCH_DURATION` | `60` | pgbench `-T` seconds |
| `BENCH_RUNS` | `1` | repeats per invocation (BENCH.md wants 3 for a real number) |
| `BENCH_START_LEAD` | `15` | seconds between "go" and the wall-clock start barrier |
| `BENCH_SETTLE_S` | `5` | floor wait after load stops, before looking (BENCH.md §5) |
| `BENCH_CONVERGE_TIMEOUT_S` | `120` | bound on the convergence poll; hitting it fails the run |
| `BENCH_SYNC_TABLES` | `pgbench_branches pgbench_tellers pgbench_accounts` | which tables `nodes1` registers (`pgbench_history` has no PK — opt in with `BENCH_SYNC_HISTORY=1`) |
| `BENCH_YTSERVER_RESTART` | `sudo -n systemctl restart ytserver` | run on every node, together, after a sync condition is applied |
| `BENCH_VIA_PGBOUNCER` | `0` | `0` = direct connect, rely on `yaxaha.auto_complete`; `1` = legacy route through a patched PgBouncer on `:6432` |
| `BENCH_SKIP_INIT` | unset | reuse the existing `pgbench -i` data and registration |

## Status (2026-09-09)

Both conditions are runnable. `nosync` is a plain pgbench target. `nodes1`
replicates on the node2/node3 cluster via `yaxaha.auto_complete` (direct
connect, no PgBouncer) — `case1`/`case2` confirm a single write crosses in
both `cluster_commit` modes. Sustained concurrent same-table load can still
diverge (serialized `process_call` consumer); the convergence gate catches
that and exits non-zero rather than printing a throughput number for a
cluster that lost writes.

## What it records (per run, per node)

`suite, config, cond, nodes, node, workload, run, clients, scale,
duration_s, started_at, start_spread_s, tps, lat_avg_ms, lat_p95_ms,
lat_p99_ms, failed, wal_bytes, xact_commit, xact_rollback, deadlocks,
net_tx_bytes, net_rx_bytes, converged, converged_after_s, settle_s,
invariant_ok`

`converged_after_s` is the end-of-load replication lag, measured not assumed
(BENCH.md §5 / task.md). Loading these into the `bench.*` Postgres schema for
Grafana (BENCH.md §6) is left as-is — this writes the CSV those rows come
from.
