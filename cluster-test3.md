# Cluster test 3 — forced leader: node1 as PG main AND yt leader, 2026-09-14

## Thesis

Tests 1 and 2 ran with the yt leader on a *remote* node, so every write statement
paid a `checkin` round trip — the single largest cost those tests identified
(2.21 ms of origin wait for 0.75 ms of leader work, billed per statement).

This round pins the leader onto **node1**, the node that originates the writes,
via the `yt_info('e:<node>')` operator handover. `checkin_call()` then takes the
`HostOption::This` branch: the round trip is *removed*, not optimised.

Two configurations, both with `sc=0`:

- `nodes=half, wal=half` — synchronous cross-node 2PC
- `nodes=0, wal=half` — eventual on reads, strong on writes

Environment unchanged from tests 1–2: node1 PG16:5434 origin, node2 + node3
peers, ICMP RTT 0.75 ms. Every run starts from a wiped WAL + synchronized
restart + resync + verified-converged, then leadership forced to node1.

## Baseline

PostgreSQL built-in replication, re-measured this session:

```
fsync = on   full_page_writes = on   synchronous_commit = on
wal_sync_method = fdatasync
synchronous_standby_names = FIRST 2 (node2, node3)
  node2 streaming sync prio=1 | node3 streaming sync prio=2
```

**4.410 ms / 226.8 tps.** Both standbys flush WAL to disk before the primary
returns — a genuine disk-sync 2-node baseline.

## Results

Write-only, c=1:

| config | ms | tps | vs PG sync |
|---|---|---|---|
| **PG sync repl, 2 standbys** | **4.410** | **226.8** | 1.0x (base) |
| yt `nodes=0, wal=half, sc=0` | **2.577** | **388.0** | **1.7x faster / 171%** |
| yt `nodes=half, wal=half, sc=0` | 18.257 | 54.8 | 4.1x slower / 24% |

80/20 read/write mix, c=1 (the realistic shape):

| config | overall tps | read ms | write ms |
|---|---|---|---|
| no trigger (local PG) | 2360.3 | 0.153 | 1.471 |
| yt `nodes=0` | 1509.3 | 0.075 | 2.686 |
| PG sync repl | 932.7 | 0.196 | 4.366 |
| yt `nodes=half` | 263.2 | 0.179 | 16.134 |

Convergence after the ordering fix (below): **14/14 runs**, across both configs,
hot-row and multi-row workloads, c=1/4/8 and the 80/20 mix.

| workload | `nodes=0` | `nodes=half` |
|---|---|---|
| multi-row c=1 (x3) | 378 / 345 / 333 tps | 54.3 / 52.4 / 54.2 tps |
| hot-row c=1 | converged | 54.0 tps |
| multi-row c=4 | **496.8 tps** | 60.9 tps |
| multi-row c=8 | **577.8 tps** | 57.2 tps |
| 80/20 mix | 1509.3 tps | 263.2 tps |

### Where the time goes

Per write statement on the origin:

| stage | `nodes=0` | `nodes=half` | remote leader (test 1) |
|---|---|---|---|
| `cluster_save` total | **0.16** | **3.26** | 5.44 |
| ├ checkin | **0.12** | **0.27** | **2.50** |
| ├ set_data | 0.03 | 0.04 | 0.28 |
| └ fanout (send_modify) | 0.00 | 2.95 | 2.64 |
| `cluster_prepare` (per tx) | 0.00 | 3.62 | 3.05 |
| `cluster_complete` (per tx) | 0.09 | 4.10 | 5.11 |

Three ways of paying for checkin, all now measured:

| | origin checkin |
|---|---|
| remote leader | 2500 us |
| remote leader + HPC lease (test 2) | 650 us |
| **local leader (this test)** | **120–270 us** |

With the leader local, `nodes=half` is down to **4 remote round trips** per
transaction — 2 × fanout (5.9 ms) + prepare (3.6) + commit (4.1) ≈ 13.6 ms of the
18.3 measured. `nodes=0` has **none**.

## Findings and fixes

**1. `wal=half` is inert.** `push_wal_save` fired 0 times in every configuration;
the `wal` field of `CfgTabl` is still unwired. Both runs are really
`nodes=0` / `nodes=half` with the WAL setting ignored. *Not fixed — noted.*

**2. Applies could land out of order, and one inversion was unrecoverable.**
The origin fans applies out from a per-transaction `tokio::spawn`, so two could
reach a peer reordered. The apply SQL is optimistic
(`WHERE pk = .. AND col = old`), so the early one matched no row, was accepted as
success, and the row then never reached the value later applies expected — every
subsequent write to that row failed too. Measured exactly: one inversion
(subterm 408 before 407) at position 253 of 351 applies → 351−253 = 98 lost, and
the run lost exactly 98.

*Fixed:* applies are now enforced in **natural subterm order** — a subterm waits
until every subterm before it has landed locally. The signal is `applied_hwm`
(an `AppliedMark` per term): a contiguous high-water mark of locally materialised
subterms, with out-of-order arrivals held until the gap fills.

The subtlety worth keeping: it must be marked from **both** paths a subterm can
reach a node — the async apply *and* the synchronous party `modify`. In `cc=half`
a peer receives each subterm through exactly one of the two, so marking only the
apply path leaves permanent holes that stall everything after them. A bounded
timeout remains, logging "applying N out of order" so a genuine hole is loud
rather than silent.

Per-ROW ordering — only what actually conflicts, allowing more parallelism — is
deliberately *not* attempted here; that is `speculative-subterm-exec.md`.

**3. Two false starts on that fix, both from wrong signals rather than wrong
logic.** Worth recording because the second cost three rounds:

- The barrier first read `least_completed_subterm`, which only `set_subterm_state`
  advances — and `insert_with_state` calls it only for a subterm that *already
  existed*. A replicated apply is a fresh insert, so 94% bypassed it (1692
  `insert_with_state` vs 103 `set_subterm_state`, zero `data_version` activity)
  and every barrier timed out instead of holding.
- An earlier per-row variant only captured statement 1's dependency, because the
  `if !contains_key` guard skips statements 2..n of a transaction.

The second stayed invisible because `cluster_event_applied: N rows` counts rows
per **apply**, and an apply carries both statements — one where branches landed
and tellers did not still reported "effective, zero-row=0". A per-**table** digest
exposed it in a single run: branches identical on all three nodes, tellers
different on all three. The harness now digests per table.

## Conclusions

1. **Put the yt leader on the node that originates writes.** The cheapest win
   across all three tests: checkin 2500 → ~200 us, `nodes=half` from 18% to 24%
   of PG sync-replication throughput, with no code change — just
   `yt_info('e:<node>')`.

2. **Synchronous cluster commit is 4.1x PostgreSQL's own sync replication.**
   PG ships one WAL record and waits for two standbys **in parallel**;
   `nodes=half` makes 4 sequential round trips. Closing that is a protocol
   change, not tuning.

3. **`nodes=0` is not "weaker durability for speed".** It is eventual on reads
   and strong on writes: a peer serving stale reads still blocks before writing
   those rows, whereas a PG standby cannot accept a write at all. The honest
   framing is **3 writable nodes at 388 tps against 1 writable node at 227 tps**.
   What it gives up is read freshness on the peers, not write safety.

4. **An 80/20 transaction mix is not an 80/20 time mix.** At `nodes=half`,
   80 reads × 0.179 ms = 14 ms against 20 writes × 16.1 ms = 323 ms — writes are
   **96% of elapsed time** (PG sync repl 85%, no-trigger 71%). Degradation vs
   no-trigger improves only from −91.7% (write-only) to −86.9% (80/20). Reads
   themselves are free: 0.179 ms with the cluster vs 0.153 ms without.

5. **Ordering removed a ceiling rather than costing throughput.** `nodes=0` now
   reaches 497 tps at c=4 and 578 at c=8 — far above the ~200 tps region where it
   previously diverged intermittently. Unresolved: the 80/20 figures are ~9–15%
   below the pre-fix measurements, which single samples cannot separate from
   run-to-run variance.

## Reproducing

```
NODE1=<address> NODE2=<address> NODE3=<address> \
  bash cluster-test3-matrix.sh <label> <A-row base64> <tx count>
```

Wipes the WAL, restarts all three nodes, waits for a leader, resyncs and
verifies, then **forces leadership to node1** via `yt_info('e:<node1 address>')`.

| config | base64 |
|---|---|
| `nodes=0, wal=half, sc=0` | `CggSAhACGgIQAQ==` |
| `nodes=half, wal=half, sc=0` | `CggSAhABGgIQAQ==` |

`yt_info('a:<table>')` renders `nodes>=1` for `at_least=0` (the display adds
self); `sequential_consistency` reads `0 (no sc, no hpc)` / `1 (sc)` /
`2 (sc + hpc)`.
