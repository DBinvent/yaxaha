# pgbench plan — single Postgres vs. a YaXAHA cluster

A ToDo, not a result. **None of §1's matrix has been run.** The only
measurements on disk are the three calibration anchors in
`bench/calibration.json` (§0a) — taken on an i5-4670 to give the TPS calculator
a constant that was measured rather than guessed. They are not the `S1`
baseline: one box, `-s 5`, live services running beside them.

**The question.** What does synchronisation cost against one plain Postgres,
and does adding nodes buy throughput back? Two numbers, and they pull in
opposite directions:

- **the synchronisation tax** — one node of the cluster against one plain
  Postgres, same box, same load. This should be *worse*, and by how much is
  the number a customer actually asks for.
- **the scale factor** — N nodes against one node of the same cluster, with
  the load split so the nodes are not fighting over the same rows. This
  should be near-linear, and where it stops being linear is the finding.

Reporting one without the other is what makes a benchmark an advertisement.

---

## 0. The rig

**Up to 10 hardware nodes.** That changes what this benchmark can answer.
On one 4-core box a three-node run is nine processes fighting for four cores
and a flat scale curve says nothing about YaXAHA; on ten machines the curve
is real, and the interesting part — *where it bends, and why* — becomes
measurable rather than arguable.

It also introduces a variable that loopback hid: **the network**. A
synchronous protocol pays round trips, so the tax is bounded below by RTT,
and a number from a 1GbE switch is not a number from 10GbE. Measure the wire
before measuring the database.

- [ ] **Still blocked: the UUID node id** (REVIEW.md 2c). `cargo make` fails
      in ~6s at the `ytserv` panic because the roster keys on `node1..3` and
      ytserv 0.12 wants a UUID. Ten hardware nodes make this *more* urgent,
      not less — the roster has to be generated per host anyway.
- [ ] **Record the rig, once, in the results header.** Per node: CPU model
      and core count, RAM, disk (model, and whether it has a write cache),
      PostgreSQL version, `yaxaha` version, kernel.
- [ ] **Say whether Alloy was scraping.** Since 2026-08-27 this host ships
      its own metrics to Grafana Cloud: one `alloy.service`, 15 targets,
      30s interval, ~80MB RSS (see `../raw/grafana.md`). Small, but it is on
      the box while the numbers are taken, so it belongs in the header with
      the rest of the rig — and it is the first thing to rule out if a run
      looks noisy at the second scale. `sudo systemctl stop alloy` for a
      clean-room run, and record that instead.
- [ ] **Homogeneous, or say so.** A synchronous protocol runs at the speed of
      its slowest participant. If the ten machines are not identical, the
      slowest one bounds every multi-node number, and a scale curve that
      bends when node 7 joins may be describing node 7.
- [ ] **Measure the network first.** `ping -c 100` (RTT median and p99) and
      `iperf3` (both directions) between every pair, or at least from each
      node to every other. Two things fall out: the floor under commit
      latency, and any asymmetric pair — one bad cable in a ten-node mesh is
      invisible in aggregate TPS and obvious here.
- [ ] **Clocks synchronised** (chrony/NTP, same source), and the residual
      offset recorded. `pgbench_history.mtime` comes from each node's own
      clock, so skew shows up as ordering noise in the convergence digest
      and as nonsense in any lag measurement.
- [ ] **One node is the baseline machine.** `S1`, `S1x` and `C1` all run on
      *the same* physical node, so the single-vs-cluster comparison is not
      also a comparison of two different computers.
- [ ] **pgbench runs on the node**, next to its Postgres, in every
      configuration including the baseline — that is the deployment being
      measured, and a remote client on the baseline against a local one on
      the cluster rigs the tax.

## 0a. Capacity per node — `bench/tps_calc.py`

§0 says "homogeneous, or say so". This is the *say so*: a TPS calculator keyed
on each node's estimated CPU TFLOPS, so the rig's machines can be compared
before a benchmark is run and measured results can be divided by capacity
afterwards.

    python3 bench/tps_calc.py cpu                      # what this box is worth
    python3 bench/tps_calc.py predict --config CN --nodes 10 --clients 8
    python3 bench/tps_calc.py normalize --tps 1846 --clients 8
    python3 bench/tps_calc.py required --tps 20000 --config CN --nodes 10
    python3 bench/tps_calc.py calibrate --measure --clients 8

**TFLOPS is a capacity index, not a claim.** pgbench executes no floating
point. `cores x clock x SIMD width` is used because it is the thing that
differs between machines, and it is monotone in the parts that do matter. The
constant relating it to TPS is never assumed — with no anchor the tool prints
no TPS at all and says why.

**The model, and the rule it had to throw away.**

    peak_tflops = sockets x cores x GHz x flops_per_cycle(ISA) / 1000
    tps         = A x peak_tflops x clients / (clients + c0)

The first version was `min(clients, cores)`: one client per busy backend,
cores as the ceiling. The first three anchors killed it. On four cores:

| clients | tps | what the discarded rule predicted |
|---|---|---|
| 4 | 1,159 | — (the anchor) |
| 8 | 1,846 | 1,159 — no gain past core count |
| 16 | 2,122 | 1,159 |

A 59% gain from oversubscribing four cores is backends blocking on WAL fsync
while others compute, so the curve needs a knee rather than a cliff. The
hyperbola fits the three points to 4.9% rms, `A = 13,389 tps/TFLOP`,
`c0 = 5.5 clients` — half the ceiling at about five clients, on this box.

- [ ] **Run `cpu` on all ten nodes before anything else** and put the number in
      the results header next to the CPU model. Two nodes differing by more
      than a few percent means §0's homogeneity item is already answered — no.
- [ ] **Report `normalize` beside raw TPS.** Equal tps-per-TFLOP means the
      nodes are the same machine as far as this benchmark cares; the low one is
      what bounds every synchronous commit.
- [ ] **Calibrate `C1` once it exists.** Until then the tool prices `C1`/`CN`
      off the S1 anchor times §7's *predicted* factors, and labels every such
      line PREDICTED. A measured `C1` anchor replaces the guess, and the gap
      between the two is §7's first verdict.
- [ ] Anchors cross-host are still an assumption: capacity scaling has only
      ever been measured on one machine, so the tool prints a CAUTION row when
      asked about a box more than 2x away from any anchor.

## 1. The configurations to measure

Four, and the third is the one that is easy to leave out and impossible to
reason without:

| id | what | why it exists |
|---|---|---|
| `S1` | plain Postgres, no `yaxaha` extension | the baseline everyone compares to |
| `S1x` | plain Postgres, extension installed, **no peers** | separates the *trigger and WAL* overhead from the *replication* cost. Without it, every millisecond gets blamed on the network |
| `C1` | one-node cluster, `ytserv` running | the synchronisation tax with nothing to synchronise *to* — the floor of the protocol's own cost |
| `CN` | N-node cluster, **N ∈ {2, 3, 5, 7, 10}**, load split per node | the scale factor, and where it stops |

`S1` and `S1x` differing tells you the extension costs something before any
peer exists. `S1x` and `C1` differing tells you what the daemon costs. Only
`CN` measures replication.

The sweep is not linear on purpose: 2, 3, 5, 7, 10 shows the *shape* of the
curve with five points, where 2, 3, 4 would spend the rig on the flat part.

### The question ten nodes can answer that three cannot

**What does a commit cost as the cluster grows — and where does that cost
land?** Three shapes are possible, they predict different curves, and the
measurement below tells them apart without reading a line of the engine:

| if replication is… | bytes per commit, per node, as N grows | curve |
|---|---|---|
| broadcast to every peer | grows ∝ (N−1) | per-node throughput decays; aggregate flattens |
| relayed or gossiped | roughly flat | aggregate stays near-linear until something else binds |
| routed through a coordinating node | flat on most nodes, ∝ N on one | that node saturates first, and its CPU shows it |

- [ ] Record **host network bytes in/out per node** (`/proc/net/dev` deltas
      over the run) alongside `pg_stat_wal`'s `wal_bytes`, at every N. The
      ratio `net_bytes / wal_bytes` per node, plotted against N, is the
      answer — and it is worth more than the TPS number it comes with,
      because it says *why* the curve bends rather than that it did.

## 2. The load: one data stream per node

pgbench's built-in `tpcb-like` is the wrong shape here and would produce a
misleading answer. Every transaction updates `pgbench_branches`, and with
`-s 1` that is **one row**: three nodes writing it is three nodes contending
for the same row, so the result would measure conflict resolution and could
not scale by construction, however good the replication is.

The user's framing — *a data stream source per node* — is also the fix.
Give each node a disjoint key range, so the only cross-node work is
replication:

```sql
-- bench/stream.sql — run with -D node=<n> -D nodes=<N> -D scale=<s>
\set branches_per_node  (:scale / :nodes)
\set tellers_per_node   (10 * :scale / :nodes)
\set accounts_per_node  (100000 * :scale / :nodes)

\set bid random((:node - 1) * :branches_per_node + 1, :node * :branches_per_node)
\set tid random((:node - 1) * :tellers_per_node  + 1, :node * :tellers_per_node)
\set aid random((:node - 1) * :accounts_per_node + 1, :node * :accounts_per_node)
\set delta random(-5000, 5000)

BEGIN;
UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid;
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
UPDATE pgbench_tellers  SET tbalance = tbalance + :delta WHERE tid = :tid;
UPDATE pgbench_branches SET bbalance = bbalance + :delta WHERE bid = :bid;
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime)
     VALUES (:tid, :bid, :aid, :delta, CURRENT_TIMESTAMP);
END;
```

- [ ] `-s` (scale) at least `N × 10` so every node owns ≥10 branches;
      otherwise the split is not a split.
- [ ] Run the **same script** against `S1` with `-D node=1 -D nodes=1`, so
      the baseline executes the identical statements. Comparing a custom
      script against builtin `tpcb-like` compares two workloads.
- [ ] A second, deliberately *overlapping* run (all nodes on the whole key
      space) as a contrast case. That is the honest upper bound on what
      synchronisation costs when the workload does not partition — and it is
      the shape a customer's workload may actually have.

## 3. Rules that decide whether the numbers mean anything

- [ ] **pgbench runs next to Postgres on every configuration, including the
      baseline.** Co-locating the client costs CPU; if `S1` gets a remote
      client and `CN` a local one, the tax is measured against a rigged
      baseline.
- [ ] Dataset **smaller than `shared_buffers`**, so this measures
      synchronisation rather than the disk. Record both settings.
- [ ] Identical `postgresql.conf` across configurations —
      `shared_buffers`, `max_connections`, `wal_level`, `synchronous_commit`,
      `fsync`. If `yaxaha` requires a different value for any of them, that
      difference *is* part of the tax and belongs in the writeup, not
      silently in the config.
- [ ] `-T 300 -P 5`, not `-t`: a fixed transaction count finishes at
      different times per node and the last node runs alone.
- [ ] Discard the first 30s (ramp) and the last 5s (drain) from every run.
- [ ] Three runs per configuration, report the **median and the spread**.
      One run is an anecdote.
- [ ] **Start together.** Ten hosts starting a 300s run 20s apart measure
      ten different overlapping workloads. Drive it from one place with a
      barrier — Ansible `async` + a common `at`-style start time, or a
      simple "wait until this wall-clock second" line at the top of the
      per-node runner — and record the observed start spread. If the spread
      is more than a second or two, the ramp discard has to grow to cover it.
- [ ] **Collect centrally.** Each node writes one CSV row per run; pull them
      to one host and key them by `(config, N, node, run)`. Reading ten
      terminals is not a method.
- [ ] Two client sweeps, and they answer different questions:
      - **fixed clients per node** (`-c 8` on each of N) — does capacity add?
      - **fixed clients in total** (`-c 24` split across N) — does the same
        offered load get served faster?

## 4. What to record, per run

| from | what |
|---|---|
| pgbench | tps excluding connections, latency avg / p95 / p99, failed transactions |
| `pg_stat_database` | `xact_commit`, `xact_rollback`, `deadlocks`, `conflicts` (delta over the run) |
| `pg_stat_wal` | `wal_records`, `wal_bytes` — the replication volume the tax buys |
| `yt_info` | leader identity, node states, and any lag counter it exposes |
| host | per-container CPU and IO (`docker stats` sampled, or `pidstat 1`) |

The CPU column is not decoration: on 4 cores it is what tells you whether a
flat scale curve is YaXAHA's ceiling or the host's.

## 5. The final check — do the nodes agree?

A throughput number from a cluster that silently lost writes is worse than no
number. After every `CN` run:

- [ ] **Quiesce, in three steps, and the order is the whole point.**
      Comparing before the cluster has settled measures replication lag and
      reports it as data loss.

      1. **Stop the load on *every* node first**, and wait for the last one.
         The runs end within a second or two of each other (§3's start
         barrier), but one node still writing means the others can never
         match it — a comparison that begins while any generator is alive is
         chasing a moving target.
      2. **Settle: a few seconds, deliberately.** `BENCH_SETTLE_S`, default
         **5**. The last commits are in flight when pgbench prints its
         summary, and they are exactly the ones a dump taken immediately
         would miss. This is a floor, not the whole wait.
      3. **Then poll until the nodes agree, bounded.** Take the digest below
         on every node and compare; repeat every second until they match or
         `BENCH_CONVERGE_TIMEOUT_S` (default 120) expires. Bounded, via
         `wait_common.sh`'s `it_wait_for` — never an unbounded loop
         (REVIEW.md finding 1).

      **Record how long step 3 took** as `converged_after_s`, alongside the
      settle. That number is not bookkeeping: it is the replication lag at
      the end of load, measured instead of assumed, and it is one of the more
      interesting things this benchmark produces — a cluster that converges
      in 200ms at N=3 and 9s at N=10 has said something about the protocol
      that the TPS curve did not.

      A fixed sleep on its own would be a guess dressed as a method: too
      short and every run fails as "divergence", too long and every run pays
      for the worst case. Floor plus poll costs the floor when things are
      fast and still gives a real answer when they are not.

- [ ] **Take every node's dump at the same point.** Once the poll says the
      cluster agrees, take the comparison snapshots **in parallel** across
      nodes. Serially over ten hosts, node 1 is read at T+5 and node 10 at
      T+40; if they differ, nothing in the result says whether that is
      divergence or thirty-five seconds of ordinary work — and the run is
      quiesced, so there should be no ordinary work at all. Parallel removes
      the question rather than arguing about it.

- [ ] **Timing out is a failure, not a retry.** If the cluster has not
      converged inside the cap, record the run as failed with the digests as
      they stood and *which* relations differed. Re-running until it passes
      would turn the one check that protects every other number into a
      formality.
- [ ] **The TPC-B invariant, per node.** pgbench's own consistency property,
      and it catches a lost or duplicated update even where a hash comparison
      would be ambiguous:

```sql
SELECT (SELECT sum(abalance) FROM pgbench_accounts) AS accounts,
       (SELECT sum(bbalance) FROM pgbench_branches) AS branches,
       (SELECT sum(tbalance) FROM pgbench_tellers)  AS tellers,
       (SELECT sum(delta)    FROM pgbench_history)  AS history;
```

      All four must be equal, on every node.

- [ ] **Row-level agreement between nodes.** Same digest on every node:

```sql
SELECT 'accounts' AS rel, count(*), sum(abalance),
       md5(string_agg(md5(aid || ':' || abalance), '' ORDER BY aid))
  FROM pgbench_accounts
UNION ALL SELECT 'branches', count(*), sum(bbalance),
       md5(string_agg(md5(bid || ':' || bbalance), '' ORDER BY bid))
  FROM pgbench_branches
UNION ALL SELECT 'tellers', count(*), sum(tbalance),
       md5(string_agg(md5(tid || ':' || tbalance), '' ORDER BY tid))
  FROM pgbench_tellers
UNION ALL SELECT 'history', count(*), sum(delta),
       md5(string_agg(md5(mtime || tid || bid || aid || delta), ''
                      ORDER BY mtime, tid, bid, aid, delta))
  FROM pgbench_history;
```

      `pgbench_history` has no primary key and rows arrive from every node,
      so its digest must be order-insensitive — hence the full ORDER BY. If
      only `history` disagrees while the balances match, that is a
      replication *ordering* difference and not a lost write; say which.

- [ ] **Compare against one reference node, not pairwise.** Ten nodes is 45
      pairs; comparing each to node 1 is nine comparisons and answers the
      same question. Report *which* nodes differ, not just that some did — a
      single odd node out is a different bug from a split into two groups,
      and the set membership is the whole diagnosis.
- [ ] **A disagreement fails the run.** Not a footnote in the results table:
      a cluster that did not converge has no throughput number worth
      publishing, and the run should exit non-zero the way a test does.

## 6. Seeing it — Grafana

Five configurations, a five-point node sweep, two workload shapes, three runs
each and ten nodes reporting is on the order of a thousand rows. That is past
the point where a terminal is a way of looking at results.

**Results go into Postgres, not into CSV files.** Grafana's Postgres
datasource is core — no plugin to install, no CSV-over-HTTP shim — and every
question here is relational: *this* config against *that* one, at the same N,
on the same node, median over runs. A directory of CSVs cannot join.

```sql
CREATE SCHEMA bench;

-- One row per pgbench invocation.
CREATE TABLE bench.run (
  id            bigserial PRIMARY KEY,
  suite         text NOT NULL,        -- a label for one sitting of the whole matrix
  config        text NOT NULL,        -- S1 | S1x | C1 | CN
  nodes         int  NOT NULL,        -- 1..10
  node          int  NOT NULL,        -- which one reported this row
  workload      text NOT NULL,        -- disjoint | overlapping
  clients       int  NOT NULL,
  scale         int  NOT NULL,
  started_at    timestamptz NOT NULL,
  duration_s    int  NOT NULL,
  tps           numeric NOT NULL,     -- excluding connections establishing
  lat_avg_ms    numeric,
  lat_p95_ms    numeric,
  lat_p99_ms    numeric,
  failed        bigint,
  wal_bytes     bigint,               -- pg_stat_wal delta
  net_tx_bytes  bigint,               -- /proc/net/dev delta
  net_rx_bytes  bigint,
  cpu_pct       numeric,
  host          jsonb                 -- cpu, ram, disk, pg version, yaxaha version
);

-- One row per `-P 5` progress line: the shape of a run, not just its number.
CREATE TABLE bench.sample (
  run_id  bigint REFERENCES bench.run(id) ON DELETE CASCADE,
  at      timestamptz NOT NULL,
  tps     numeric,
  lat_ms  numeric
);

-- §5's verdict, so a fast run that lost writes cannot be read as a good one.
CREATE TABLE bench.convergence (
  suite             text NOT NULL,
  nodes             int  NOT NULL,
  checked_at        timestamptz NOT NULL,
  converged         boolean NOT NULL,
  settle_s          int,              -- the floor waited before looking at all
  converged_after_s numeric,          -- how long the poll then took: the real
                                      -- end-of-load replication lag
  disagreeing       int[],            -- which nodes, not just how many
  detail            jsonb
);

-- The integration cases (it1..it4) on the same rig, so "does it work" and
-- "how fast is it" are two panels of one dashboard rather than two worlds.
CREATE TABLE bench.case_run (
  suite      text NOT NULL,
  case_id    text NOT NULL,           -- it1 | it2 | it3 | it4
  node       int,
  started_at timestamptz NOT NULL,
  passed     boolean NOT NULL,
  duration_s numeric,
  detail     text
);
```

**Not Prometheus, for this.** A benchmark is a batch job with a beginning and
an end; Prometheus scrapes things that are always there, and the fact that
Pushgateway exists to bridge that gap is the argument. Prometheus earns its
place around the *services* — see `../raw/grafana.md` — not around a run that
produces a thousand rows and stops.

### Dashboards, and each one answers a question already asked here

- [ ] **Scale curve** — aggregate TPS (`sum(tps)` over nodes) against N, one
      series per workload. The disjoint and overlapping lines on one axis
      *is* the tradeoff, in a single picture.
- [ ] **The synchronisation tax** — `S1`, `S1x`, `C1` side by side at the
      same clients and scale. Three bars that separate the extension from the
      daemon from the replication.
- [ ] **Per-node timeline** from `bench.sample` — TPS and p99 per node during
      one run. This is where an unfair start spread, a slow node, or a
      mid-run stall becomes visible; the aggregate hides all three.
- [ ] **`net_bytes / wal_bytes` against N** — §1's topology signal, and the
      panel most likely to explain a bend in the scale curve.
- [ ] **Convergence** — a stat panel, red on any `converged = false`, with
      the disagreeing node list, and beside it `converged_after_s` plotted
      against N. The second panel is a result in its own right: how long the
      cluster needs to agree once the writing stops, and how that grows with
      the node count. Pinned next to the TPS panels on purpose: a
      throughput number from a cluster that did not converge is not a result.
- [ ] **Case history** — `it1..it4` pass/fail over time, per node. The
      integration cases and the benchmark run on the same rig; showing them
      apart invites reading a fast number from a broken cluster.

### Provisioned as code, not clicked

- [ ] `grafana/provisioning/datasources/bench.yaml` and
      `grafana/dashboards/*.json` in this repo, mounted into the container.
      A dashboard someone assembled by hand and never exported is a dashboard
      that dies with its volume — and one that cannot be reviewed in a diff
      when a panel starts lying.
- [ ] Self-hosted on the lab box (port 3000 is free there; note that **9090
      is not** — `mock-target-e2e` has it). Grafana Cloud is the alternative
      and the tradeoff is stated rather than assumed: it makes dashboards
      reachable without the tunnel, and it means benchmark results leave the
      lab. For this repo, local.

## 7. Predictions, written before the run

State them now so the benchmark can contradict them. A benchmark that cannot
fail is a demo.

- [ ] `C1` is 20–60% below `S1` — the protocol's cost with no peer.
- [ ] `CN` with disjoint streams reaches **≥ 0.8 × N** of `C1`'s throughput
      at N = 3, and the curve **bends somewhere between 3 and 10**. Naming
      where is the point of having ten machines; the `net_bytes / wal_bytes`
      ratio from §1 says whether the bend is replication fan-out, a
      coordinating node, or the disk.
- [ ] Commit latency at every N stays within a small multiple of the
      measured network RTT. If p99 is orders above RTT, the cost is not the
      wire and the network measurement has done its job by ruling itself
      out.
- [ ] `CN` with *overlapping* streams does **not** scale, and may fall below
      `C1`. If it does not fall, the conflict path is doing something
      interesting and worth a second look.
- [ ] p99 latency degrades faster than mean under synchronisation. Mean-only
      reporting is how a system with a bad tail passes a benchmark.

## 8. Order of work

0. [x] `bench/tps_calc.py` + `bench/stream.sql`, and three calibration anchors
       on an i5-4670 (§0a). The stream script is written and exercised; the
       anchors are a constant for the calculator, not a baseline.
1. [ ] Unblock §0 (UUID node id, and where it runs), and run
       `bench/tps_calc.py cpu` on every node while you are on it.
2. [~] **A multi-host driver.** Ten hosts cannot be driven by `cargo make`,
       which is a single-box process supervisor — this is the same step 4
       REVIEW.md already argues for. First cut landed as `bench/cluster/`
       (bash + `ssh`, not Ansible: matches this suite's idiom, no control
       node): it ships `stream.sql`, applies a **sync condition**, runs the
       bench with a wall-clock start barrier, quiesces, polls convergence,
       and writes CSV. Conditions: `nosync` (no trigger — the denominator)
       and `nodes1` (`ClusterCommit::Nodes{at_least:0}` — origin commits
       after a `checkin` conflict/order check, async fan-out). An Ansible
       play is still the right end state for provisioning the package +
       roster; `bench/cluster/` is the scenario side and runs today.
3. [~] `bench/cluster/run.sh` takes a condition, runs one disjoint stream per
       node, and writes one CSV row per `(config,cond,nodes,node,run)` —
       results as data. `S1`/`S1x`/`C1`/`CN` matrix sweep and the Postgres
       results schema (§6) still to wire on top.
4. [ ] `S1` and `S1x` first. They need no cluster, so they are the earliest
       real numbers available and they set the baseline everything else is
       read against.
5. [ ] `C1`, then 2, 3, 5, 7, 10 — in that order, so the curve is drawn
       from the cheap end and a bend is visible before the last run.
6. [ ] Grafana up with the schema above and the datasource provisioned, so
       results are readable while the matrix is still running rather than
       after it. `bench/run.sh` inserts, it does not print.
7. [ ] Convergence check wired into `run.sh` so no result is recorded
       without it.
8. [ ] Write up: a table, the hardware header, the network measurements,
       and every prediction marked held or broken.

## What this plan is not

Not a TPC-B result and not comparable to one — a custom script, a
partitioned key space and a co-located client all put it outside the spec.
It is an internal comparison between four configurations on a known rig, and
any number leaving this repo should carry its hardware header with it — a
scale factor without a node count, a NIC and an RTT is not a result.
