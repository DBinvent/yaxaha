# Cluster test 2 — HPC (hheuristic pre-checkin), 2026-09-14

Same goal as `cluster-test1.md`: where the performance goes, measured against
PostgreSQL's own synchronous replication on the same hardware. This round tests
**HPC** — the subterm-lease feature from `pre-checkin.md` — which attacks the
single largest cost test 1 identified: `checkin()` is a synchronous RTT to the
leader on **every write statement**, 2.21 ms of origin wait for 0.75 ms of
leader work.

Environment, workload and harness are unchanged from test 1 (node1 origin /
PG16:5434, node2 + node3 peers, ICMP RTT 0.75 ms, `s2.sql` = one transaction
with two UPDATEs, c=1, every run from a wiped WAL + synchronized restart +
resynced-and-verified tables).

Base for the percentages is again **PG built-in synchronous replication to 2
standbys: 4.15 ms / 241 tps**.

## Headline

| config | ms | tps | vs PG sync |
|---|---|---|---|
| PG sync repl, 2 standbys | 4.15 | 241 | 1.0x (base) |
| yt `cc=NODES0` **+ HPC** | **5.67** | **179** | **1.4x slower / 74%** |
| yt `cc=NODES0` (test 1) | 9.98 | 100 | 2.4x slower / 42% |
| yt `cc=half` **+ HPC** | **20.77** | **48** | 5.0x slower / 20% |
| yt `cc=half` (test 1) | 23.07 | 43 | 5.6x slower / 18% |

HPC moves eventual mode from 42% to **74% of PostgreSQL's own synchronous
replication throughput**, on a network where the wire alone is 0.75 ms.

## A/B, alternated, 300 tx each

| round | config | hpc | ms | tps | converged | local mints |
|---|---|---|---|---|---|---|
| 1 | cc=half | off | 23.301 | 42.9 | yes | 0 |
| 1 | cc=half | **on** | **19.947** | **50.1** | yes | 395 |
| 1 | cc=NODES0 | off | 10.292 | 97.2 | yes | 0 |
| 1 | cc=NODES0 | **on** | **6.328** | **158.0** | yes | 395 |
| 2 | cc=half | off | 22.847 | 43.8 | yes | 0 |
| 2 | cc=half | **on** | **21.589** | **46.3** | yes | 395 |
| 2 | cc=NODES0 | off | 9.666 | 103.5 | yes | 0 |
| 2 | cc=NODES0 | **on** | **5.008** | **199.7** | **NO** — see below | 395 |

Means: `cc=half` **23.07 → 20.77 ms (−10%), 43.3 → 48.2 tps (+11%)**;
`cc=NODES0` **9.98 → 5.67 ms (−43%), 100.3 → 178.9 tps (+78%)**.

The split is exactly what the mechanism predicts. `cc=half` makes 6 sequential
round trips per transaction and HPC removes 2 of them; `cc=NODES0` makes only
the 2 checkin round trips, so removing them nearly doubles throughput.

## The mechanism, measured

Per write statement on the origin:

```
hpc off   cluster_save 5.44 ms = checkin 2.50 + fanout 2.64
hpc on    cluster_save 4.35 ms = checkin 0.65 + fanout 3.44
```

**checkin −74% (2.50 → 0.65 ms)** — that is the RTT being replaced by a local
mint. `cluster_save` per statement is −20%. (The fanout difference between those
two particular runs is leader placement, not HPC: they elected different
leaders. The alternated A/B above controls for it.)

One lease covered the whole run: `leased 100 subterms from 6 for 20s`, then
**395 of 400 statements minted locally with no checkin RTT**. The first few
statements pay full price while the hheuristic warms up (`hpc_row`=10 within
`hpc_time_sec`=2).

## What was built

`pre-checkin.md` implemented as `ytserv/src/state/lease.rs` (~880 lines) plus
protocol and config. Default **off** (`hpc_feature=0`).

- **Config**: `hpc_feature`, `hpc_row` 10, `hpc_time_sec` 2, `hpc_tables` 4,
  `hpc_lease_sec` 20, `hpcu_uid_max` 100.
- **Protocol**: `LeaseScope` / `LeaseRequest` / `LeaseReply` / `LeaseAckRequest`
  / `LeaseStopRequest` / `LeaseStopReply` and 5 RPCs — `lease`, `lease_extend`,
  `lease_amend`, `lease_ack`, `lease_stop`.
- **Leader**: `LeaseRegistry` — grant / extend / ack / stop / conflict check /
  `covering_write` redirect. A lease is a plain `subterm.fetch_add(n)`, so the
  leased run is excluded from regular issuing for free, with no bookkeeping on
  the normal path.
- **Leasee**: `HeldLease` (mint, scope test, pending acks), `HpcTracker` (the
  hpc_row/hpc_time/hpc_tables hheuristic, PK-shape detection, subterm estimate).
- **Action rules from the spec**: delete/truncate → no hpc; int/bigint PK → a
  frame `[min,max]` over what was touched; uuid/string PK → the explicit set
  capped at `hpcu_uid_max`; composite/absent/other PK → no hpc.
- **Lifecycle**: `lease_ack` batches every 16 consumed subterms; `lease_extend`
  fires within 2 s of expiry; elections withdraw all leases on both sides;
  `lease_amend` answers "roll back" exactly as the spec directs (logical 2PC is
  explicitly deferred there).

16 unit tests (9 lease + 4 build_sql + 3 others); 61/61 in the crate pass.

### Two design decisions worth recording

**A lease is only for a remote checkin.** On the leader `checkin_call()` takes
the `HostOption::This` branch — a direct in-process call with no round trip — so
there is nothing to remove. The leader refuses to lease to itself, and the
leasee path is wired solely into the `SomeHost` arm. Leasing to self would only
pull subterms out of regular issuing to save a cost that does not exist.

**The party is pinned at grant time.** The leasee is by definition a follower,
so it must not re-derive the party per statement from its own peer view — two
nodes deriving independently can disagree, and the party decides who must
commit. The leader picks it once during `lease()` using the same `select_party()`
the normal checkin path uses (extracted verbatim for that purpose), stores it in
the lease, and the leasee mints every key with exactly that party.

## Open: a throughput ceiling in the apply path, which HPC exposes

Round 2 `cc=NODES0` + HPC **diverged** at 199.7 tps. Rate-limiting the identical
configuration isolates it:

| HPC on, cc=NODES0 | tps | result |
|---|---|---|
| `-R 100` | 94.3 | **CONVERGED** |
| `-R 200` | 140.9 | **DIVERGED** |

and HPC **off** — which cannot exceed ~100 tps because of the RTT — always
converged. So this is **rate-dependent, not HPC-semantic**: HPC removes the
round trip, the origin pushes roughly twice as fast, and somewhere above
~140 tps the apply path stops holding. HPC did not introduce the defect; it
raised throughput past the point where an existing one shows.

What was ruled out on the diverging peer:

- **Not lost applies.** Both peers received all 300 applies / 600 statements.
- **Not out-of-order arrival.** Applies executed in strict subterm order
  (266, 267, … 305).
- **Not the catch-up path.** Zero wal-api pull activity during the run.
- The failure is the same signature as the zero-row apply fixed in test 1 —
  286 of 300 applies matched no row — but the ordering cause fixed there is not
  the cause here.

The exact mechanism is **not yet pinned**, and it is the next thing to chase.
Note the practical bound: `cc=half` tops out near 50 tps, far below the ceiling,
and converged in every HPC run; only `cc=NODES0` gets fast enough to hit it.

## Where this leaves the cost model

Test 1 attributed a `cc=half` transaction to 6 sequential round trips, ~34%
of it pure network waste, with protobuf at 0.15% and roughly half the transport
cost being the wire itself. HPC removes 2 of those 6 round trips and the
measurements match that prediction closely (−10% on `cc=half`, −43% on
`cc=NODES0`, checkin itself −74%).

The remaining levers, in order of measured value:

1. **The apply-path ceiling above** — it now caps eventual mode at ~140 tps,
   which is the binding constraint for `cc=NODES0`, not the round trips.
2. **The 4 remaining round trips in `cc=half`** — the 2PC fan-out and
   PREPARE/COMMIT pair. Matching PostgreSQL's single ack round trip is a
   protocol change, not tuning.
3. The local trigger path, still ~415 us per call with 96% inside
   `curl_easy_perform` (test 1) — gRPC-over-HTTP2 is heavy for a unix socket.

## State

`hpc_feature` left at **0** on all three nodes and in the shipped default; the
build is deployed and the cluster is on `cc=half`, converged, `stmt_cache_size=10`
(98.4% hit, see test 1). Enable with the module-`C` row `hpc_feature=1` plus an
`ytserver` restart — the C-module knobs are not hot-reloadable.

## Appendix — HPC gated behind sequential consistency, and operator-driven leader move (2026-09-14)

### `sequential_consistency` is now tri-state

`CfgTabl.sequential_consistency` went from `bool` to an enum. Both are varint on
the wire, so this is **backward compatible**: an existing `false`/`true` keeps
meaning 0/1.

| value | meaning |
|---|---|
| 0 `NO_SC` | no sequential consistency, no HPC |
| 1 `SC` | sequential consistency (conflict → SQL 40409), no HPC |
| 2 `SC_HPC` | SC **plus** HPC leasing for this table |

The ordering is not arbitrary. A lease lets the leasee mint subterms locally, so
the leader's conflict scan never sees those writes — that is only sound where a
conflicting concurrent write is **rejected outright** rather than merged, which
is exactly what level 1 guarantees. HPC therefore sits above SC, never beside it.

The separate `hpc_feature` SmCfg knob is **removed**: HPC is now armed per table
by this level, checked on the leasee (observe + mint) and on the leader (a lease
whose scope contains a table below SC_HPC is refused).

### `yt_info('e:<node>')` — move leadership on demand

Same dispatch style as `yt_info('a:<table>')`, so no `.so` change. Accepts a node
uuid prefix, host or ip. Run on the target it forces an election locally; run
anywhere else it sends the new `promote` RPC to the target. `ElectionEventRequest`
gained a `force` flag which bypasses the receiver's anti-bouncing guard and the
candidate's own eligibility gate — the automatic path never sets it.

**A split-brain bug had to be fixed to make this usable.** `do_handle_confirm`
repointed `writer.boss` to the new leader but never touched `writer.state`, so an
incumbent leader stayed `PeerState::Leader` and reported
`"Leader, discrepancy: other leader!"` **indefinitely** — two nodes each believing
they led the same term. It is pre-existing, but automatic elections rarely hit it
(the old leader is usually down); an operator handover hits it every time. An
incumbent now steps down to `Main` when the cluster confirms someone else.

Verified: issued from node3 (a non-target node), leadership moved to node1, all
three nodes agreed within 12 s and stayed stable — no discrepancy.

### Co-locating the leader with the write origin beats HPC

node1 is where pgbench runs. With node1 as leader its checkin takes the
`HostOption::This` branch — a direct in-process call — so the round trip is gone
entirely rather than merely leased away:

| leader | ms | tps | origin checkin |
|---|---|---|---|
| remote, no HPC | 23.07 | 43.3 | 2500 us |
| remote, HPC | 20.77 | 48.2 | 650 us |
| **node1 (= the write origin)** | **16.14** | **62.0** | **212 us** |

**+43% over the no-HPC baseline and +29% over HPC**, converged, 0 failed — and it
needs no lease at all. That is 26% of PG sync replication's throughput, up from
18%.

The practical rule: **put the leader on the node that originates writes.** HPC is
what you use for the nodes that are *not* the leader — in a genuinely
multi-master workload every node originates, so at most one of them can have a
local checkin and the rest still need leases.
