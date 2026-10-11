# rmc test plan: resilience and membership under change

This test checks that a hierarchy of yaxaha clusters keeps every acknowledged
transaction, and keeps its boundaries, while its membership changes underneath a
running write load: nodes are added at runtime on every level, leadership is
moved, nodes are restarted, and old nodes are replaced one by one by new ones.
It measures correctness, not throughput: no transactions-per-second figure is
taken or compared anywhere.

The results of the last run are in [results.md](results.md). How to run it is in
[README.md](README.md).

## The layout

Three clusters on one docker network, each with its own cluster uuid and its own
`yt_config` (synced inside the cluster, never across a boundary):

| cluster | az | tier | nodes at start | relations, as this cluster sees the others |
|---|---|---|---|---|
| upper | `top` | 0 | `u1 u2 u3` | `eastc`, `westc`: LOWER (a sign-in key, no address) |
| east | `eastc` | 1 | `a1 a2 a3 a4` | `top`: UPPER; `westc`: NEIGHBOR |
| west | `westc` | 1 | `b1 b2 b3 b4` | `top`: UPPER; `eastc`: NEIGHBOR |

The link rules under test ("up/down/side"):

- **up**: only a lower cluster's leader dials upward, and never at the upper
  cluster's leader;
- **down**: the upper cluster holds no address for a lower one and never dials
  it; a lower cluster's leader signs in;
- **side**: a neighbour link is leader to leader only, and only a sharded table
  may cross it.

Data crosses a boundary only by the relay (ytserv 0.20.22, `tpl2.md`, "The
relay"): a lower cluster's leader, over the link it already holds to a regular
upper node, fetches what the upper cluster committed to a table its az holds
and delivers it to its members (down), and delivers its own cluster's rows of a
table the upper cluster holds (up). Relayed rows are a read-only copy, applied
in the source cluster's order. Nothing is relayed sideways.

Nodes added during the run: `u4 u5` (upper), `a5 a6 a7 a8` (east), `b5 b6`
(west).

## The data

| table | routing (`yxctl --encode-table-cfg`) | written by | what it shows |
|---|---|---|---|
| `rmc_ledger` | `no_up; no_down` | the load, in every cluster, each in its own id range | durability and convergence inside a cluster; that no row crosses a boundary up, down or sideways |
| `rmc_down` | `az=top,eastc,westc; write=top` | probes on the upper leader | the **down** gate: a top write reaches both lower clusters by the relay, and a lower write is refused |
| `rmc_up` | `az=top,eastc; write=eastc; no_down` | probes on the east leader | the **up** gate: an east write reaches the upper cluster by the relay and never west, and a top or west write is refused |
| `rmc_side` | `az=eastc,westc` (not sharded) | probes on the east leader | the **side** gate: an unsharded table never crosses the neighbour link |
| `rmc_probe` | `no_up; no_down` | `up.sh`, to wait until each cluster commits | readiness only |

## The load

One writer per cluster runs for the whole test in a client container on the same
network (`load/writer.sh`). Each transaction inserts one row into `rmc_ledger`
(single-row: multi-row transactions are not what this test is about):

```
begin; insert into rmc_ledger ...; select yt_complete(true); commit;
```

The writer sends each transaction to the next member of its cluster in turn,
so every member starts writes (`RMC_ORIGIN=all`, the default). The first runs
found that a write starting on a follower broke the cluster (see
[results.md](results.md), finding 1), and sent the load through each cluster's
leader instead (`RMC_ORIGIN=leader`, which finds the leader by asking the
members and asks again after any failure). Follower writes are tested on their
own as well, last (P7).

Each attempt is logged with its outcome:

- **OK**: the commit returned success. The cluster has acknowledged it.
- **ERR**: a clean SQL error. Nothing should have been committed.
- **NOC**: no connection. Nothing was sent.
- **UNK**: the outcome cannot be known: the connection broke, or a timeout or
  cancel hit the commit. Either result is allowed, but every member must agree.
- **NOL**: no member reported itself leader, so nothing was sent.

A node leaves the writer's list before it is retired, and joins it once it has
caught up.

## The invariants

I1 to I6 and I8 are checked after every step, I7 at the end of each phase. The
writers pause while the checks run, so the cluster can settle; a check waits up
to a minute for the members to converge before it judges them.

| id | invariant | how it is checked |
|---|---|---|
| I1 | no acknowledged transaction is lost | every OK id is on every participating member |
| I2 | members converge | every member holds the same set of ledger ids (and at least one row, so two empty tables cannot "agree") |
| I3 | no phantom commits | an ERR id is on no member (UNK ids are counted and must agree, I2) |
| I4 | nothing crosses a boundary | a cluster's `rmc_ledger` holds only its own id range: the **up** and **side** data gates |
| I5 | one leader per cluster | each cluster has exactly one leader, the three are different nodes, and no node reports a collision or a leader discrepancy |
| I6 | clusters are independent | an election in one cluster leaves the other two clusters' leader and term unchanged |
| I7 | the gates hold | **down**: a top write to `rmc_down` reaches every lower member within a minute, a lower write is refused; **up**: an east write to `rmc_up` reaches every east and upper member within a minute and no west node, a top or west write is refused; **side**: an east write never reaches west or top; **dial**: no upper node holds a permitted link, each lower leader holds at least one permitted UPPER link that is not the upper leader, and a permitted NEIGHBOR link to the neighbour's leader (plus at most its two deputies), and no lower member holds a permitted link |
| I8 | the cluster stays writable | after each step a write on the leader commits and reaches another member within a minute; the writer's outcomes during the step are reported |
| I9 | a follower can start a write | P7 only: a write on a follower commits and reaches every member |

## The steps

Each step runs under the load, one change at a time, and ends with the
invariants.

| phase | steps | expected |
|---|---|---|
| **P1 baseline** | one minute of load | all invariants |
| **P2 grow, all levels** | add `u4` to upper, `a5` to east, `b5` to west, one at a time | the new node becomes a follower, catches up the ledger, takes writes; the linked clusters learn it at runtime (no restart anywhere) |
| **P3 shift leader** | in each cluster, move leadership to its new node with `yt_info('e:<node>')` | the new node leads; the term of that cluster goes up; the other clusters do not notice (I6); the dial gates follow the new leader |
| **P4 refresh** | restart one follower per cluster; then restart each cluster's leader | a follower rejoins and catches up; a cluster whose leader restarts elects another and keeps committing |
| **P5 turnover** | east: add `a6`, retire `a1`; add `a7`, retire `a2`; add `a8`, retire `a3`; retire `a4`. upper: add `u5`, retire `u1`. west: add `b6`, retire `b1` | the east cluster ends with none of its original nodes and every acknowledged transaction |
| **P6 after turnover** | move east's leadership once more; restart one of its new followers | the cluster still elects and rejoins with retired nodes in its history |
| **P7 follower writes** | six writes that start on followers, in each cluster; then the invariants again | each commits and reaches every member, and the leader still commits afterwards |

### Adding a node at runtime

ytserv's documented way to add a node (`ytserv/membership.md`, "Expansion") is a
physical copy of a running member: the copy carries the data and `yt_config`
with the roster and the member's position (`least`), and ytserv then pulls the
subterms the copy missed. The test does exactly that (`RMC_JOIN=clone`, the
default):

1. On the cluster's leader, in cluster transactions (one row each): the new
   node's `Z` row, then its `N` row. Every member adds the peer while running.
   `Z` first: a roster row without its placement row makes the node a member of
   whichever cluster holds the row.
2. Start the container as a `pg_basebackup` of a participating follower (not
   the leader, to keep the load off it). The copy carries the rows of step 1;
   the node drops the copied `leader_uuid` and gets its own range for new config
   ids, then ytserv starts.
3. Wait until the node is a follower of the cluster's leader, then until its
   ledger matches the leader's.
4. Only now, on each linked cluster's leader: the same `Z` and `N` rows, and its
   address added to that cluster's `<az>.host` row (UPPER, NEIGHBOR). The upper
   cluster needs nothing for a lower node: a lower cluster's leader signs in.
5. Give it writes.

`RMC_JOIN=empty` adds a node that starts from nothing instead: no data and no
position, only the leader's config rows without the runtime ones. Run 5 showed
what that gave: the node followed at once and took every write from then on,
but none of the rows written before it joined. Since ytserv 0.20.62 such a node
stays Spare and outside every party, copies every synced table from a member the
leader names, replays what came after the copy began, and only then follows
(ytserv/src/state/fill.rs, membership.md); topo T7 M2 has passed since.

### Retiring a node

1. Take it off the writer's list.
2. If it leads, move leadership to another member first: a leader cannot pause.
3. On the leader: `node_run = '<uuid8>:pause'`. The leader grants the pause only
   if quorum survives it. Wait until the node reports `Paused`.
4. Stop the container. Delete its `N` row, then its `Z` row, on its cluster
   and on the linked clusters, and remove it from their `<az>.host` rows.

## What the code suggests may break

From reading the code before the run; the run decides.

- **A dead leader may not be noticed.** The hierarchy fixture in yt-pgxt could
  not complete its failover test: the cluster kept naming the stopped leader.
  P4 restarts each leader.
- **The roster never shrinks while running.** A retired node stays a peer, and
  the election threshold counts peers. After P5 the east cluster has four
  retired nodes in its roster, which P6 exercises.
- **Catching up depends on the cluster WAL.** A new node is filled from the
  WAL of the others; a subterm it missed in a closed term is not re-sent.
- **Runtime config only applies through a cluster transaction** written on the
  leader; a plain local write changes nothing until a restart.

What the runs answered ([results.md](results.md)): a dead leader was indeed not
noticed (finding 13); the roster did not shrink (finding 25); catching up from
the cluster WAL failed in five different ways (findings 5, 11, 19, 26, 27); and
runtime config through a cluster transaction worked once its party was drawn
from the members (finding 3). All fixed by 0.20.21.

## Not covered

- throughput, latency, and any figure per second;
- network partitions (a node is stopped or restarted, never cut off);
- the package install path, which the single-node install tests cover;
- multi-row transactions and recon repair.
