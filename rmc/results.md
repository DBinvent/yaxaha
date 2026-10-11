# rmc results

What the [plan](plan.md) found, run by run, on three linked clusters in docker
(eleven nodes at start, up to seventeen), 2026-10-04 and 05. Each run's full
output is in `results/`.

## In short

- **The last run passes everything, with the relay**: run 35, yaxaha 0.17.31
  (ytserv 0.20.31), all seven phases, 883 checks passed, none failed, no `GAP`.
  Three linked clusters grew at runtime on every level by physical copy, each
  copy following in 3 to 4 s and caught up within a second; leadership moved to
  each new node within a second; every follower restarted and was back in 7 s,
  every leader restarted and a leader again in 5 to 6 s, every leader stopped
  for a minute, replaced in 19 to 24 s and back as a follower holding every row;
  the east cluster was turned over entirely - three copies added, all four
  original nodes retired one by one under load - and upper and west one node
  each; writes that start on followers committed, 6 of 6 in every cluster.
  Across the boundaries: a top write reached every member of both lower clusters
  by the relay a second later, an east write reached the upper cluster within 0
  to 5 s and never west, and every write a cluster may not make was refused.
  Throughout: no acknowledged row lost, every cluster's members converged, no
  phantom commit, nothing crossed a boundary it may not cross, and the dial rules
  held. The writers made about 14,300 writes; 91 (0.6%) were refused while a
  leader changed, and none of them was ever acknowledged.
- **Thirty-five runs found 43 faults and a few smaller ones, and 31 ytserv
  releases fixed them** (0.20.1 to 0.20.31, yaxaha 0.17.1 to 0.17.31). Runs 1 to
  24 brought the clusters to a clean run with the relay still missing; 0.20.22
  built the relay, and runs 25 to 35 found what carrying data across a boundary,
  and the fixes on the way, uncovered (findings 32 to 43). Most faults predate
  this work - the first run failed the same way on a repacked 0.16.7 - and four
  were introduced or exposed by a fix and found by a later run (findings 17, 23,
  41 and 42). Every fix that can be reproduced without a cluster has a unit test;
  259 ytserv tests pass.
- **What held in every run**: a lower cluster could never write a table it may
  not write. The rest held from a release on: nothing crossed a boundary it may
  not cross from 0.20.5 (runs 3 and 7 found another cluster's rows, finding 8);
  no phantom commit from 0.20.9 (run 10 found them, finding 10); acknowledged
  rows missing on a member - runs 7 to 23, 31 and 33, each traced to a finding -
  not since 0.20.30; and the relay in every phase since run 27, but for run 29
  (finding 38).
- **Still open**: a roster row naming a host that does not resolve is refused
  when it is written, and stops a node from starting - a node whose roster names
  a stopped container's host exits at startup (see Smaller findings).
- **The harness** was fixed three times on the way: it no longer stops a node
  that has not handed over its leadership or paused (an operator would not); a
  restarted container clears a stale PostgreSQL socket lock, which a reused pid
  inside the container otherwise turned into a refusal to start; and the writer
  counts a connection lost mid-transaction ("connection to server was lost") as
  an unknown outcome, not a refusal - run 30 restarted a node between a write's
  `yt_complete` and its commit's answer, and the committed row read as a phantom.

## The runs

| run | yaxaha (ytserv) | new nodes | outcome | log |
|---|---|---|---|---|
| 1 | 0.17.0 (0.20.0) | empty | follower writes break replication; via the leader only: P1 holds, P2 fails (runtime config writes refused, lower leaders stop answering) | [run-20261004-171919](results/run-20261004-171919.log) |
| 3 | 0.17.1 (0.20.1) | empty | P1 holds, but half the follower writes time out; P2: lower clusters lose their leaders, upper rows on the west leader | [run-20261004-175208](results/run-20261004-175208.log) |
| 4 | 0.17.2 (0.20.2) | empty | P1: every member takes writes, all invariants hold; P2 blocked by the party leak | [run-20261004-185718](results/run-20261004-185718.log) |
| 5 | 0.17.3 (0.20.3) | empty | P2: runtime grow works on all levels; a new node gets no history and jams applies to it | [run-20261004-191317](results/run-20261004-191317.log) |
| 7 | 0.17.4 (0.20.4) | physical copy | copies miss writes; P3 leaves two clusters leaderless | [run-20261004-195542](results/run-20261004-195542.log) |
| 8, 9 | 0.17.5 to 0.17.7 (0.20.5 to 0.20.7) | physical copy | P1 clean; P2 stops at the east copy, which never catches up (two self-deadlocks, findings 5 and 9) | [run-20261004-234205](results/run-20261004-234205.log), [run-20261005-001342](results/run-20261005-001342.log) |
| 10 | 0.17.8 (0.20.8) | physical copy | P1, P2 clean; P3 three false promote refusals; P4 phantom commits on every follower restart | [run-20261005-002846](results/run-20261005-002846.log) |
| 11 | 0.17.9 (0.20.9) | physical copy | P1 to P3 clean, no phantoms; P4: a follower restart leaves the cluster unwritable, a restarted follower lacks 11 rows, a stopped leader is never replaced | [run-20261005-010539](results/run-20261005-010539.log) |
| 12 | 0.17.10 (0.20.10) | physical copy | P1 to P3 clean, follower restarts clean; leader restarts reissue subterm numbers (one row lost), a stopped leader is never replaced | [run-20261005-015458](results/run-20261005-015458.log) |
| 13 | 0.17.11 (0.20.11) | physical copy | P1 to P3 clean; follower restarts and one leader restart clean (a new leader elected); the upper and west clusters stay unwritable after their leader restarts; the first leader stop freezes the followers | [run-20261005-022554](results/run-20261005-022554.log) |
| 14 | 0.17.12 (0.20.12) | physical copy | P1 to P3 clean; P4: every cluster writable through leader restarts and leader loss, a new leader in 25 s; restarted and returning leaders lack rows; P5's first add and retire clean | [run-20261005-030621](results/run-20261005-030621.log) |
| 15 | 0.17.13 (0.20.13) | physical copy | P1 to P3 clean; P4: returning leaders hold every row, new leaders in 23 to 31 s; restarted leaders still lack two rows; west left without a working leader after losing its leader | [run-20261005-034834](results/run-20261005-034834.log) |
| 16 | 0.17.14 (0.20.14) | physical copy | P1 to P3 clean; P4 220 of 221: every restart and leader loss without a lost row, new leaders in 14 to 41 s; the new west leader dials no upper node; P5: a promote to a fresh copy refused, and the harness stopped the leader anyway | [run-20261005-042243](results/run-20261005-042243.log) |
| 17 | 0.17.15 (0.20.15) | physical copy | P1, P2 clean; P3: each promote to a copy crashed the copy's request handling (a panic in the 0.20.15 promote check) | [run-20261005-045235](results/run-20261005-045235.log) |
| 18 | 0.17.16 (0.20.16) | physical copy | P1 to P3 clean; P4: restarted followers never came back - PostgreSQL in the restarted container refused to start on a stale socket lock (a harness fault, fixed in the node image) | [run-20261005-050731](results/run-20261005-050731.log) |
| 19 | 0.17.16 (0.20.16) | physical copy | P1 to P4 clean, 221 of 221 in P4; P5: a member never learned a new node (a config row's id taken by a local row), and a retired node, still a peer, held the east cluster "behind" | [run-20261005-052917](results/run-20261005-052917.log) |
| 20 | 0.17.17 (0.20.17) | physical copy | P1 to P4 clean; P5: the first add clean; a copy re-applied a row its snapshot already held, failed on the duplicate key, and held its cluster "behind" once it led; retirement still not seen at runtime | [run-20261005-061145](results/run-20261005-061145.log) |
| 21 | 0.17.18 (0.20.18) | physical copy | P1 to P4 clean; P5: retirement now taken at runtime; the second copy never caught up - it held a prepared transaction copied from its source | [run-20261005-064811](results/run-20261005-064811.log) |
| 22 | 0.17.19 (0.20.19) | physical copy | the first run through all seven phases: 837 checks passed, 7 failed. P1 to P3 and P5 clean; P4: an election stuck for minutes; P6: an election after the turnover could not reach its majority; P7: follower writes refused after the turnover. No acknowledged row lost, no phantom, every cluster converged | [run-20261005-072153](results/run-20261005-072153.log) |
| 23 | 0.17.20 (0.20.20) | physical copy | 840 passed, 3 failed: P5 and P7 clean; P4: a leader back from a stop caught up only once the next write reached it, after the check; P6: a lower leader permitted one sideways target too many | [run-20261005-080634](results/run-20261005-080634.log) |
| 24 | 0.17.21 (0.20.21) | physical copy | **all seven phases: 843 passed, 0 failed** (6 `GAP`, the relay) | [run-20261005-084223](results/run-20261005-084223.log) |
| 25 | 0.17.22 (0.20.22) | physical copy | the first relay run: down reached every lower member in a second; up failed, an east write to the shared table had upper nodes in its commit party; P2: a copy lacked 21 rows | [run-20261005-130947](results/run-20261005-130947.log) |
| 26 | 0.17.23 (0.20.23) | physical copy | up and down refused on every tick for a cursor at the start; P3: two elections on one node undid each other, `a5` a candidate for seven minutes | [run-20261005-132534](results/run-20261005-132534.log) |
| 27 | 0.17.24 (0.20.24) | physical copy | 880 passed, 1 failed: **every relay check passes**; P5: a west follower cleared its newly confirmed leader and elected itself five minutes later, during an east step (I6) | [run-20261005-134731](results/run-20261005-134731.log) |
| 28 | 0.17.25 (0.20.25) | physical copy | **all seven phases with the relay: 881 passed, 0 failed, no `GAP`**; one upper follower named no leader for two minutes after its leader restarted, and refused the writes it started (finding 37) | [run-20261005-142033](results/run-20261005-142033.log) |
| 29 | 0.17.26 (0.20.26) | physical copy | 881 passed, 2 failed: finding 37 fixed, a third of run 28's refused writes gone; P6: east's new leader signed in through the upper leader and then a node retired above, and no relay reached east or came from it | [run-20261005-144919](results/run-20261005-144919.log) |
| 30 | 0.17.27 (0.20.27) | physical copy | P1 to P3 clean, every new lower leader signed in through a regular upper node; P4: a write whose connection broke at the commit, after the cluster had decided it, was logged as refused - a harness fault, the row rightly on every member; stopped | [run-20261005-152632](results/run-20261005-152632.log) |
| 31 | 0.17.27 (0.20.27) | physical copy | 879 passed, 2 failed: findings 38 and 39 fixed - east's new leader dropped the retired nodes and signed in through a regular upper node, and every relay check passed; P4: a leader back from its minute down lacked the term's last row until the next write (finding 40) | [run-20261005-153713](results/run-20261005-153713.log) |
| 32 | 0.17.28 (0.20.28) | physical copy | P1 to P3 clean; P4: the upper leader, restarted, refused its own WAL file and exited - a pull before the WAL load had written a new term file over an old one (finding 41); stopped | [run-20261005-160712](results/run-20261005-160712.log) |
| 33 | 0.17.29 (0.20.29) | physical copy | P1 to P3 clean; P4: leaders back from a restart or a stop pulled nothing of the term elected without them - one lacked 25 rows, one stayed a spare (finding 42); stopped and reproduced on the live clusters | [run-20261005-163117](results/run-20261005-163117.log) |
| 34 | 0.17.30 (0.20.30) | physical copy | 883 passed, 1 failed: finding 42 fixed - every leader back from a restart or a stop pulled the term elected without it within 10 ms of its load; the fewest refused writes yet (83); P5: a config write right after a node was stopped refused once (finding 43) | [run-20261005-172153](results/run-20261005-172153.log) |
| 35 | 0.17.31 (0.20.31) | physical copy | **all seven phases with the relay: 883 passed, 0 failed, no `GAP`** | [run-20261005-175356](results/run-20261005-175356.log) |
| 36 | 0.17.35 (0.20.35) | physical copy | regression after the runtime job layer and az jobs (yt-pgxt `topo-jobs.md`, phases 0 and 1): **all seven phases, 881 passed, 0 failed, no `GAP`** | [run-20261006-010428](results/run-20261006-010428.log) |
| 37 | 0.17.40 (0.20.40) | physical copy | regression after phase 2 of the topology jobs (yt-pgxt `topo-jobs.md`: table moves that copy before they flip, stale-row cleanup, and every scoped write now reaching the members outside its party): **all seven phases, 881 passed, 0 failed, no `GAP`** | [run-20261006-040018](results/run-20261006-040018.log) |
| 38 | 0.17.46 (0.20.46) | physical copy | regression after phases 3 and 4 of the topology jobs (yt-pgxt `topo-jobs.md`: approval from above and participation locks; split and combine of members) and a fix it found older than them - a check-in that failed after issuing its sub-term left a hole that blocked writes while a member was down: **all seven phases, 881 passed, 0 failed, no `GAP`** | [run-20261006-153646](results/run-20261006-153646.log) |
| 39 | 0.17.55 (0.20.55) | physical copy | regression after phase 5 of the topology jobs (yt-pgxt `topo-jobs.md`: every job kind under faults) and the fixes it found older than them - a commit on a party member the client was told failed, after an explicit `yt_complete(true)`; a party transaction left open, with its locks, after a refused prepare or a failed statement: **all seven phases, 883 passed, 0 failed, no `GAP`**, in 28 minutes | [run-20261006-210959](results/run-20261006-210959.log) |

Runs 2 and 6 were stopped within minutes for harness reasons (a repeat of run
1's baseline; a roster row written by host name before the host existed) and
are not kept. Runs 11 to 21, 25, 26, 30, 32 and 33 were stopped once their failures were
understood: the later phases would have measured their wreckage.

From run 3 on, the load is round-robin over every participating member, so
writes start on followers as often as on the leader. From run 7 on, a new node
joins the documented way, as a physical copy of a follower.

## The fixes

| ytserv | the run showed | the fix | unit test |
|---|---|---|---|
| 0.20.1 | a write started on a follower: the next applies to it wait out the timeout, then gaps and a write stall | the origin marks its own subterm settled in the apply order (`mark_origin_settled`) | `an_origin_settled_subterm_does_not_hold_the_next_apply` |
| 0.20.2 | half the follower writes still time out | a commit whose fan-out goes asynchronous rebuilds the origin's data versions and records the close | (flat 3-node cluster: 217 of 217 writes, all converge) |
| 0.20.3 | an unrouted table's commit party took other clusters' nodes; runtime config writes failed, lower clusters lost their leaders | an unrouted table's party, threshold and fan-out come from the members whenever links exist | `an_unrouted_table_is_held_by_members_and_never_by_a_link` |
| 0.20.4 | a node joining or restarting mid-term made every apply to it wait out the timeout | a missing predecessor costs one wait, then is given up for ordering (`settle_through`) | `a_hole_costs_one_wait_not_one_per_later_apply`, `settle_through_absorbs_what_arrived_ahead` |
| 0.20.5 | the WAL pull and term pull reached other clusters; a Spare never joined; deputies only accumulated; a forced promote picked a node lacking data; a copy's own writes collided with the origin's subterms | members only for both pulls; Spare admitted by `is_current` and allowed to pull; a linked cluster's deputy pair replaced, from its leader only; promote refused by a target that is behind; the transaction map filed on the origin only | `a_linked_clusters_replaced_deputy_is_no_longer_admissible`, `a_forced_promote_is_refused_by_a_node_that_is_behind`, `a_party_member_does_not_file_the_origins_transaction` |
| 0.20.6 | a copy never got the writes between its copy and its join | the copy keeps its seeded position and pulls that window by number; the apply-order wait is half the SQL timeout, inside the sender's deadline | |
| 0.20.7 | the copy's catch-up stalled the node | the window pull and its follow-up leave the internal bus's own task (it waited on itself when full) | |
| 0.20.8 | the east copy jammed in every run | a broadcast's reply channel holds every recipient (ten slots, more than ten peers, joined before read: a deadlock) | `a_broadcast_to_more_than_ten_peers_returns` |
| 0.20.9 | phantom commits after every follower restart | a party member's WAL state follows the command it got (prepare, commit, rollback); only a committed state is served as commit; promote counts holes from a copy's seed | `only_a_committed_subterm_is_served_as_commit` |
| 0.20.10 | a follower restart left a subterm nobody holds, and the cluster unwritable; a restarted follower pulled only part of what it missed | every batch of a pull is sent (only the first ten per term were); a node pulls its own gaps; a pull asks for outcomes, not records; a subterm no member holds is rolled back by the leader after a grace period; a pulled rollback with no rows is recorded; in-doubt transactions are decided at startup | `a_pulled_rollback_with_no_rows_is_recorded`, `an_abandoned_subterm_is_rolled_back_after_the_grace_period` |
| 0.20.10 | upward pings to regular upper nodes refused; deputies and refusals logged every tick | a relayed sign-in is admitted on the relaying node too; deputies keep their place while eligible; DNS, the rppd roster and reconciliation use members only; a peer naming another cluster is a link everywhere, and its cluster-internal calls are refused | `a_sitting_deputy_keeps_its_place_while_eligible`, `a_peer_naming_another_cluster_is_a_link_everywhere` |
| 0.20.11 | a restarted leader reissued its term's subterm numbers; a stopped leader was never replaced | the subterm count survives resuming the same term; a ping that cannot connect counts as failed | `resuming_the_same_term_keeps_the_subterm_count` |
| 0.20.12 | a cluster unwritable after its leader restarted; a new leader "behind" on its own term for good; the first leader stop froze the followers | a node decides its own undecided writes while running too; a range complete without a break is complete through its last subterm; a commit marker is served as a commit, never as a rollback; the election is called outside the peer lock | `a_range_complete_without_a_break_has_no_missed_tail`, `a_hole_right_after_the_mark_is_missed` |
| 0.20.13 | a restarted leader lacked rows its followers held; a leader back after a minute down lacked every row written meanwhile | a commit with rows reopens a record held undecided and not prepared; a hole at the start of a term is missed, and pulled; a copy's term is marked complete up to its seed; a term held complete is not pulled again | `a_commit_for_an_undecided_record_is_applied_not_dropped` |
| 0.20.14 | a restarted leader still lacked two rows; a cluster that lost its leader was left with a node naming itself leader and refusing writes | a checkout leaves the leader's unapplied check-in copy for the apply; an election already won through the ping loop counts as won, and a lost one never leaves a node naming itself leader | |
| 0.20.15 | a new lower leader dialled no upper node; a promote to a complete copy was refused | rule 1 avoids the upper cluster's current leader only, as that cluster last answered, not its deputies or a stale record; a promote counts holes above the node's own least mark only | `a_promote_counts_holes_above_the_least_mark_only` |
| 0.20.16 | the 0.20.15 promote check panicked whenever a node was complete through its last subterm | the bound is checked before the range is taken | (the same test, with the mark at and past the last subterm) |
| 0.20.17 | a member never learned a new node; a retired node stayed a peer and held a cluster "behind" | a node's own runtime config rows take ids no replicated row can carry, and old ones are moved at startup | |
| 0.20.18 | a copy failed on a row its snapshot already held; a deleted roster row still changed nothing at runtime | an applied insert of a row already present counts as applied, and a failed apply is logged; the running roster is reconciled with the config table's roster rows | |
| 0.20.19 | a copy never caught up | a node that starts with no cluster WAL rolls back the cluster's prepared transactions it finds in its database | |
| 0.20.20 | an election stuck for minutes; elections and commit parties after a turnover counted retired nodes | a candidate that won its votes and already leads has won; a follower whose leader answers as a follower stops following it; retired nodes are out of every election, quorum and new commit party | |
| 0.20.21 | a node back from a stop pulled nothing until a write reached it; a lower leader permitted a sideways target too many | a node whose members are ahead of it in a term pulls, from the ping round; the sideways and downward rules follow the far cluster's current leader and deputies | |
| 0.20.22 | (the relay was not built: `GAP` in every phase) | the relay, down and up (`state/relay.rs`, `relay.proto`); a member that takes a subterm by apply keeps its rows in its cluster WAL, so any node can serve it | `a_routed_table_crosses_down_to_an_az_that_holds_it`, `a_relayed_row_is_accepted_only_from_an_az_that_may_write_it`, `a_collect_takes_crossing_rows_in_order_and_stops_at_the_undecided`, `a_position_round_trips_and_orders_by_term_first` |
| 0.20.23 | a lower cluster's commit party took upper nodes; a copy took the hole above its seed for complete | a routed table's party comes from the members only; the completed mark moves only over a record that follows it | `a_completed_record_above_a_hole_does_not_move_the_mark` |
| 0.20.24 | a relay cursor at the start refused for good; two elections on one node undid each other; a confirmed-away candidate stayed a candidate | a position before the first term starts at the first term; a lost election leaves a node that leads the same or a newer term alone; a candidate confirmed for another node follows it | |
| 0.20.25 | a follower cleared its new leader for the old one's failed ping | the leader is cleared only if it is still the one that failed | |
| 0.20.26 | a leaderless follower never took back its own term's leader, nor asked for an election | a node with no leader takes its own term's leader once it answers as leader; a leader learned from the ping round marks the cluster up | `a_leaderless_node_takes_the_leader_of_its_own_term_back` |
| 0.20.27 | a new lower leader signed in only through the upper leader, then failed on a gone node every tick; a node retired above stayed in the lower rosters | the sign-in skips the leader its cluster named and tries a node that failed lately last; a cross-cluster peer listed by a row goes with the row | `a_sign_in_avoids_the_far_leader_and_moves_on_from_a_failed_node` |
| 0.20.28 | a node back from a stop lacked the last subterm of the term elected without it until the next write | a pull of a term held without a gap asks through the members' last complete subterm, not one short of it | `generate_lists_the_term_through_its_last_subterm` |
| 0.20.29 | a restarted node wrote a new term file over one it had still to load, and could not start again | a WAL file is created only under a free name; no pull before the node's own WAL is loaded | `a_new_wal_file_never_opens_an_existing_one` |
| 0.20.30 | a node back into a term elected without it never pulled that term | the ping loop starts after the WAL load; the load never lowers the highest term; a pull asks for every term found missing; a node that pulls because it is behind says so | (reproduced and verified on the live clusters) |
| 0.20.31 | a config write refused after a node was stopped: every write's apply still went to it; a follower under load read itself behind every two seconds | the apply skips paused and retired nodes and links; "behind" is measured against the members' last complete subterm | |

## The findings

### 1. A write that starts on a follower broke replication (fixed, 0.20.1 and 0.20.2)

With the load spread over all members, the first write on a follower committed,
and every later follower write failed with `Network: Timeout expired` after one
second. Members diverged (a three-node flat cluster ended with 14, 8 and 14
rows). The same on a repacked 0.16.7 and on a plain three-node cluster with no
hierarchy.

The apply order is enforced by a per-term mark of the subterms a node has
applied (`applied_hwm`), which only advances over a contiguous run. It was
marked where a subterm *arrives* and never where it *starts*: a node's own write
left a hole in its own sequence for good, so every later apply to it waited the
whole `def_sql_timeout_sec`, the sender gave up first, and the outdated-table
gate held every write. With that fixed, half the follower writes still timed
out: a commit whose fan-out went asynchronous never rebuilt the origin's data
versions, so the leader's own last write showed as missing in its own view.

Three-node flat cluster, round-robin: 0.16.7 and 0.17.0 one follower write then
none, 0.17.1 about half, 0.17.2 and later 217 of 217, all converged.

### 2. A node that missed the cold start stayed a Spare (fixed, 0.20.5)

One node of each four-node cluster came up `Spare-` and never joined: its
leader refused it every ten seconds (`1.0 is older than this leader
remembers`), because admission looked the node's position up by exact match in
the ring of closed subterms. And a Spare's own pull was refused while it was
not up, so its position never moved. Admission now uses `is_current`, as the
leader drift check does, and a Spare may pull.

### 3. An unrouted table's party took in other clusters' nodes (fixed, 0.20.3)

A table with no routing rule drew its commit party from every peer,
cross-cluster links included. In this layout that is the config table itself:
the upper leader put a signed-in lower leader, held at `0.0.0.0:0`, in the party
of a config write, which failed, and a lower leader's party took real nodes of
the other clusters, which is when those clusters lost their leaders. Since
0.20.3 every runtime config write on every level succeeds.

### 4. A node joining or restarting mid-term jammed applies (fixed, 0.20.4)

`applied_hwm` lives in memory, so a node that joins or restarts mid-term has no
mark for the subterms before its first one, and they never come. Each apply to
it waited the full second (run 5: 348 waits on the new upper node, 516 apply
timeouts on its leader, the east leader stopped answering). A missing
predecessor is now given up for ordering once its wait has expired; a late one
still applies.

### 5. A physical copy missed writes (fixed, 0.20.5 to 0.20.8)

The documented way to add a node is a physical copy of a member
(`membership.md`, "Expansion"). Four faults stood between that and a working
copy, found one behind the other:

- party members filed the origin's transaction under its transaction id, so the
  copy's own transaction with the same id reused a foreign subterm (`Sub-term
  1119 version 2 already exists`);
- the writes between the copy's position and its join were never pulled: the
  copy has no cluster WAL, and its seeded position was replaced by the first
  rebuild of its data versions;
- the pull of that window ran on the internal bus's own task and every apply
  sends that bus a message: once full, it waited on itself;
- a broadcast to more than ten peers deadlocked (finding 9), and a lower
  cluster's broadcast reaches twelve.

From run 10 on, each copy follows within seconds and holds every row.

### 6. Deputies of a linked cluster were never forgotten (fixed, 0.20.5 and 0.20.10)

A lower leader may dial a neighbour's leader and that cluster's two deputies.
Every deputy ever reported was kept, so the set only grew (`may dial 4 sideways
targets`). The pair is now replaced, and taken from the far leader only. And a
leader picked its deputies by ping latency on every tick, so two healthy peers
swapped places every few seconds: deputies now keep their place while they can
take over.

### 7. A forced promote did not check the target (fixed, 0.20.5 and 0.20.9)

`yt_info('e:<node>')` moved leadership to a copy that lacked 280 acknowledged
rows. The target now refuses unless it participates, has loaded the cluster's
history, and holds the term without holes; holes are counted from a copy's
seeded position (0.20.5 counted them from the start of the term and refused
complete copies, run 10).

### 8. The WAL pull crossed cluster boundaries (fixed, 0.20.5 and 0.20.10)

A node that found itself behind pulled the missing subterms of a term from
every peer in its roster, cross-cluster links included; another cluster's term
N is a different term N, so whatever it returned was applied as this cluster's
(run 3: five upper rows on the west leader; run 7: four on each lower copy). The
pulls and broadcasts now go to members only, and since 0.20.10 a member also
refuses a commit, apply, election or pull from a link.

### 9. A broadcast to more than ten peers never returned (fixed, 0.20.8)

The reply channel had ten slots, and every send task was joined before any
reply was read. A lower cluster's `bg_ping_all` reaches twelve peers, links
included: the east copy in runs 8 and 9.

### 10. Phantom commits after a follower restart (fixed, 0.20.9)

A party member set a subterm's WAL state to committed for any command it
received, rollback included, and a node serving its WAL served every saved
state as commit. A restarted party member re-applied, from its own WAL, a
transaction its origin had rolled back, and held the row alone (I3, every
follower restart in run 10).

### 11. A follower restart could leave a cluster unwritable (fixed, 0.20.10)

Run 11, the first to reach P4 with every member taking writes. Three faults:

- **A subterm nobody holds.** The leader issues a subterm at check-in, and the
  origin saves it right after; a follower restarted in between leaves a number
  that exists nowhere. Every node counts it as a gap, the outdated-table gate
  holds every write to every synced table, and nothing closed it. The leader
  now rolls such a subterm back once every member has answered that it holds no
  record of it, twice, a grace period apart (at least ten seconds), and the
  members pull that outcome. A rollback pulled that way carries no rows, which
  the database side never answered: it was not recorded, so even a known
  rollback left the gap open. It is now recorded where it arrives.
- **Only the first ten.** A restarted follower pulls what it missed in batches
  of ten; the batch was filled once and never sent again, so it got the first
  ten subterms of each term and no more (run 11: 21 missed, 11 acknowledged rows
  missing for good).
- **Nobody asked again.** A pull ran only when a node's own check-in came back
  "behind"; a member that took no write kept its gaps for minutes. A node now
  pulls its own gaps from the reconciliation poll.

A transaction left prepared or undecided by a restart is decided too: the
origin asks its database on startup (`txid_status`), and a member holding it
prepared finishes it by name (`COMMIT PREPARED` or `ROLLBACK PREPARED`) from
the outcome it pulls. A pull asks for outcomes: a record still in progress,
this node's own or a peer's, is not taken as found.

### 12. A restarted leader reissued its term's subterm numbers (fixed, 0.20.11)

A leader that restarts takes its term back within a second: the leader is kept
in the config for that. Its subterm count was loaded from its WAL, one past the
highest it holds, and then reset to one when the term was set. It issued
numbers the term had used: each write failed with `Sub-term N version 1 already
exists` until the count passed the old ones, and a member that already held a
reused number dropped the real apply as a duplicate (run 12: one acknowledged
row missing on the east leader). The count now restarts only for a term it does
not count for, and a leader also continues past the highest subterm its
members report.

### 13. A stopped leader was never replaced (fixed, 0.20.11)

The plan expected this one, from the hierarchy fixture in yt-pgxt. Stopped for
a minute, the leader stayed the leader of all its followers for three minutes
and more, in runs 11 and 12. A follower counts failed pings to its leader and
calls an election after the third. The first two failed over pooled
connections; then the pool was cleared, and a ping that could not connect at all
was logged and skipped without being counted. It now counts.

### 14. A failed write left its record undecided for good (fixed, 0.20.12)

A leader that had just restarted took a write before it had rejoined, which
failed (`not joined cluster yet`) after its check-in. Its record stayed `New`,
nothing ever decided it, and every node counted the subterm as a gap: the upper
cluster was unwritable from then on (run 13). The rule for abandoned subterms
rightly stood back, since a record existed. A node now also decides its own
undecided writes while running, from its database's answer; a transaction still
running answers "in progress" and is left alone.

### 15. A complete range was reported incomplete (fixed, 0.20.12)

A node reports which subterms of a term it is missing. With no break anywhere,
it reported the range complete only through the mark it started from, and that
mark moves only on a state change: a record that arrives already committed, the
marker an applying member writes, does not move it. So the tail past the mark
always showed as missing. It flapped on every node with every write (`1 subterm
gap(s)` every half second), held writes behind the outdated-table gate each time,
and in a closed term it never cleared: a new leader was "behind" on its own
previous term for good (run 13).

### 16. A committed subterm was served as rolled back (fixed, 0.20.12)

Found reading the code while tracing finding 15. A member that took a subterm by
the asynchronous apply keeps only a commit marker, without the rows, and served
it to a pull as a rollback. Until 0.20.10 the puller recorded nothing for a
rollback, so the gap only stayed open; with 0.20.10 recording rollbacks, the
puller would have skipped a committed row. A marker is now served as a commit
without rows: it finishes a transaction the puller holds prepared, and is no
answer to a puller that lacks the row, which keeps asking.

### 17. The fix for finding 13 froze the followers (fixed, 0.20.12)

With the third failed ping finally counted, the election call ran for the first
time, and it took the state machine's lock while holding the peer's: the order
opposite to every other path. The upper followers froze on the first leader
stop of run 13. The lock order is restored.

### 18. A restarted leader dropped rows it had prepared (fixed, 0.20.13)

A leader that restarts mid-transaction holds a party record still undecided,
with nothing prepared in its database. When the commit then arrived, rows and
all, the apply dropped it as "existing data" (run 14: each restarted leader
lacked two acknowledged rows). Such a record is now reopened, and the commit is
applied and recorded in place.

### 19. A node that missed the start of a term never pulled it (fixed, 0.20.13)

A leader stopped for a minute comes back into the term its followers elected
meanwhile; the first subterm it receives is, say, 106, and 1 to 105 were never
reported missing, because a hole was counted only after an element above 1 (run
14: the returning leaders lacked 104, 92 and 110 rows). A hole at the start of a
term is now counted and pulled. A physical copy, which holds its term up to the
seeded position in the database it was copied with, is marked complete up to
there, so it does not pull those rows again.

### 20. A checkout closed the leader's copy before its rows arrived (fixed, 0.20.14)

The leader keeps a copy of every subterm it issues, with the rows, until the
apply brings them in. A checkout from a party member could overtake the origin's
apply, and it closed any record that was not complete yet, that copy included;
the apply then found the subterm closed and dropped it. Rare while the leader is
in the party; frequent for a leader just restarted, outside it (runs 14 and 15:
two rows on each restarted leader). A checkout now leaves that copy for the
apply when the table is routed to the leader, and closes it as before when it
is not.

### 21. An election won through the ping loop was taken for a failure (fixed, 0.20.14)

A candidate that won its votes sends the confirm, and the followers' next ping
tells it that it leads, which makes it leader at once. The election then saw a
node that was no longer a candidate, called its win a failure, and put its state
back while it still named itself leader: it refused every write as "not a
cluster leader", and a follower that had been a candidate too kept electing
alone (run 15, west after losing its leader). A node already leading now counts
as having won, and a lost election never leaves a node naming itself leader.

### 22. A new lower leader dialled no upper node (fixed, 0.20.15)

Rule 1 sends a lower cluster's leader to a regular upper node, never the upper
leader. It asked whether an upper node "leads" the way the downward and sideways
rules do, which counts a deputy as leading: with four upper nodes, a leader and
two deputies left one, and the new west leader had that one recorded as leader
from before it had been stopped itself, a record nothing refreshed, because rule
1 refused the ping that would have (run 16). Rule 1 now asks for the upper
cluster's current leader, as that cluster last answered.

### 23. A promote to a complete copy was refused (fixed, 0.20.15)

The promote check counts the subterms a node holds in its term since its seed.
It counted them in the WAL cache, and the cache drops everything below the
cluster's completed mark, held or not: under load the mark passed a fresh copy's
seed within seconds, and the copy "lacked 11 of 137" (run 16). The node is now
taken as holding everything up to its own least mark, and only holes above it
count. The run then stopped a leader that had not handed over, which an operator
would not do: the harness now ends a retirement there.

The 0.20.15 version of this check took a range of the cache that is empty when a
node is complete through its last subterm, which is the healthy case, and an
empty range given that way panics. Run 17's promotes each crashed the copy's
request handling: the process stayed up, answering every request "no cluster
receiver available". Fixed in 0.20.16, with the test extended to that case.

### 24. A member never learned a new node (fixed, 0.20.17)

A node keeps a few rows of runtime state in the config table, its own and never
replicated: the term, the leader, its position. They took their ids from the
table's sequence like any row, and the same ids are what the leader's config rows
carry when they are replicated: on a copy, which keeps its source's sequence
state for a while, a runtime row took an id the leader's next config row then got
too. That row - the new node's roster row - failed on the duplicate key on that
member at every retry, and the member never added the node (run 19). Runtime rows
now have fixed ids below zero, which no sequence yields, and rows written before
are moved onto them at startup, which frees the id for the retry.

### 25. A retired node stayed a member (fixed, 0.20.18)

The plan expected this one: "the roster never shrinks while running". Deleting a
node's roster row changed nothing at runtime, so a retired node stayed a peer: it
was pinged every tick, and it was a member that never answers. The rule for
abandoned subterms waits for every member, so the first subterm nobody held left
the east cluster "behind" for good after its turnover (run 19). The first fix
read the deleted row from the delete itself, and a delete carries only the row's
key (run 20); now every node reconciles its running roster with the roster rows
its config table holds, every few seconds and right after a delete: a member
whose row is gone is retired - not dialled, not counted, not waited for - and a
row written again brings it back.

### 26. A copy failed on a row it already held (fixed, 0.20.18)

A physical copy pulls from the position it adopted, and that position trails the
snapshot it was copied from: it is persisted every few seconds. The first rows it
pulled were often already in its database, and an insert of one failed on the
duplicate key - at every retry, silently, with the subterm never recorded. The
copy that later led held its cluster "behind" (run 20). An applied insert of a
row already present now counts as applied, and the row goes to the reconciler,
which compares it; in the party's prepare a duplicate key still fails, since
there it is a real conflict. A failed apply is now logged.

### 27. A copy inherited its source's prepared transactions (fixed, 0.20.19)

`pg_basebackup` copies prepared transactions with the data, so a copy taken while
its source had a two-phase commit in flight starts with that transaction
prepared - one it was never a party to, which nothing would ever finish. It held
its row locks: the first subterm the copy pulled that touched such a row waited
on it, and with it the copy's single apply lane, for good (run 21: the copy
lacked 532 rows and was rightly refused the leadership). A node that starts with
no cluster WAL now rolls back the cluster's prepared transactions in its
database; what committed arrives by the pull.

### 28. An election stuck between won and lost (fixed, 0.20.20)

A refinement of finding 21. A candidate won its votes, and one confirm of its
announcement failed - to the node stopped a moment before. It took that for a
lost election and stepped back, while the followers its confirm had reached
named it their leader and refused every vote for the next term: the cluster had
no leader for five minutes (run 22). A candidate that won its votes and already
leads has won; and a follower whose leader answers its ping as a follower, a few
seconds after the term began, stops following it.

### 29. Elections and commit parties counted retired nodes (fixed, 0.20.20)

With finding 25 fixed, a retired node was no longer pinged, but it still counted:
in the election's majority (after the east turnover an election needed 4 of 6
votes when four of the eight peers were retired, run 22), and in the size of the
commit party, which the live members then could not fill (a third of the east
writes failed after the turnover, "no response from any nodes"). A retired node
is now out of every election, quorum and new party. A party carried over within
a transaction is left as it is: its members hold the transaction's earlier
statements, and one that stopped answering fails the transaction, as it should.

### 30. A node back into a new term waited for a write (fixed, 0.20.21)

A leader stopped for a minute comes back into the term elected without it. It
holds nothing of that term, so it sees no gap and pulls nothing - until an apply
of the term reaches it. With the writers paused for the checks, none did: it
lacked the minute's rows through the whole convergence wait, and caught up a
second after the next write (run 23). A node now compares its holdings with its
members' data versions on every ping round, and pulls when they are ahead.

### 31. A stale record let a lower leader dial a target too many (fixed, 0.20.21)

The sideways rule permits a neighbour's leader and its two deputies. Whether a
neighbour node leads was read from its recorded state, and a node that had led
once kept counting: after west's leadership had moved twice, east's leader held
four permitted sideways targets (run 23). Finding 22's remedy, applied to the
sideways and downward rules: the far cluster's current leader, as it last
answered, and its current deputies.

### 32. A lower cluster's commit party took in upper nodes (fixed, 0.20.23)

The first relay run (run 25). `rmc_up` is held by `top` and `eastc`, and the
party of a routed table was every peer whose az the table crosses to - the
upper nodes too, which are links of the east cluster, not members. Every east
write to it went to nodes that refuse a link's cluster-internal calls, and
failed "no response from any nodes". A routed table's party now comes from the
members only, like an unrouted one's since finding 3; what crosses to another
cluster is the relay's.

### 33. A copy's catch-up stopped at a hole above its seed (fixed, 0.20.23)

A physical copy in run 25 lacked 21 rows for good. Its term's completed mark is
raised to the seed at startup (finding 19), and the next completed record moved
the mark on if it was the first record looked at, contiguous or not - so the
window between the seed and the first subterm the copy received was taken for
complete, and never pulled. The mark now moves only over a record that follows
it. Unit test: `a_completed_record_above_a_hole_does_not_move_the_mark`.

### 34. A relay cursor at the start was read as a position before history (fixed, 0.20.24)

A receiver with nothing yet stores its cursor as `0.0`. The source read that as
a request for history before its first term, "no history before term 1", and
refused it on every tick: the down feed reached only one lower cluster and the
up feed none (run 26). A position before the first term now starts at the first
term; only a physical copy whose seed is ahead of the position still refuses -
it holds what precedes its seed in its database, not in its WAL - and the leader
then relays through another node.

### 35. Two elections on one node undid each other (fixed, 0.20.24)

A forced promote and a follower's own re-election ran at once on the same node
(run 26, P3). One won; the other, which lost because the voters had just voted
for the first, then put the node's state back - dropping the leadership it had
just taken. Separately, a candidate that got the winner's confirm stayed a
candidate, and the move of east's leadership to `a5` timed out with `a5` a
candidate for seven minutes. A lost election no longer undoes a node that leads
the same or a newer term, and a candidate that is confirmed for another node
follows it.

### 36. A lost leader was cleared after its successor was confirmed (fixed, 0.20.25)

A follower whose ping to its leader failed noted the leader, then took the state
lock and cleared whatever leader it held by then - the new one, confirmed in
between. West's `b1` named no leader for five minutes after its leader was
stopped, until the term timer let it win an election of its own: an election in
west during an east step, which I6 reports (run 27, P5). The follower now clears
its leader only if it is still the one that failed.

### 37. A leaderless node never took back its own term's leader (fixed, 0.20.26)

A follower restarted and learned its leader from the ping round, which sets the
leader and the term but not the flag an election or a confirm sets, that the
cluster is up. Its leader then restarted; the follower dropped it and ran an
election, which failed while the leader came back, still leading the same term.
The ping loop took a leader only for a newer term, and without the flag the
follower never asked for another election: `u1` refused every write it started
for two minutes, until the next term (runs 27 and 28; about 26 refusals in every
step until then, which read as the other clusters' steps hurting the upper
writer). A node with no leader now takes the leader of its own term once that
leader answers as leader, and a leader learned from the ping round marks the
cluster up. Unit test: `a_leaderless_node_takes_the_leader_of_its_own_term_back`.

### 38. A new lower leader signed in through the wrong node (fixed, 0.20.27)

Every node of the cluster above refuses a lower leader's pings until one of them
has admitted its sign-in, and only that node and the upper leader admit it. A
node that has never led therefore knows nothing about the cluster above when it
takes over, and the sign-in skipped only a node whose recorded state was
`Leader`. `a8`, east's leader after the last move in P6, took the last node it
held: the upper leader, which admitted it there and nowhere else. From the next
tick on, with that leader known, it took the last node left - `u1`, retired from
the upper cluster in P5 and gone - and failed on it every tick. No regular upper
node ever admitted `a8`, and the relay, which goes only through one that answers,
had none: east's cursor stood still, and neither feed reached east or came from
it (run 29, P6). The sign-in now also skips the node its cluster last named as
leader, and tries a node it failed through in the last 30 s only after the
others; a sign-in that landed on the leader moves to a regular node on the next
tick. Unit test: `a_sign_in_avoids_the_far_leader_and_moves_on_from_a_failed_node`.

### 39. A node retired above stayed in the lower clusters' rosters (fixed, 0.20.27)

The harness deletes a retired node's roster row on every cluster that lists it,
as an operator would. A member goes with its row (finding 25), but the roster
check skipped every cross-cluster peer, because a lower leader that signed in
holds no row there. So `u1` stayed in east's and west's running rosters, pinged
and failing every tick - a critical alert for its errors on `a8` - and finding
38's sign-in kept choosing it. A cross-cluster peer with an address, one listed
by a row, now goes with its row like a member; one signed in from below, held
without an address, stays.

### 40. A returning node never asked for a term's last subterm (fixed, 0.20.28)

West's leader `b5` came back from its minute down and pulled the term elected
without it, 47 subterms, within three seconds - but not the 48th, the term's last,
which held the last row written before it returned. It got it about 90 s later, once
the next write arrived, after the check had given up: one acknowledged row
missing on one member (run 31, P4). A node whose term has no gap asks the
members for the subterms their data version lists, and that list stopped one
short of the last subterm; the ping round saw the node behind every two seconds
and the pull found nothing to ask for. Earlier runs passed only because a write
reached the returning node before the check and made the last subterm a gap,
which is asked for correctly. The list now runs through the last subterm complete
on the most advanced member. Unit test:
`generate_lists_the_term_through_its_last_subterm`.

### 41. A restarted node wrote a new term file over an old one (fixed, 0.20.29)

The upper leader `u4`, restarted under load, never came back: ytserv refused its
own WAL file at startup and exited (run 32, P4). The file held two first pages -
the term's own, after the original header, and a second near the end with
subterms 1 to 10 - and a header 38 bytes shorter than the one it replaced: one
leader uuid, missing because the node had no leader yet. Seven milliseconds after
the start, before the load of its own WAL files had reached that file, the first
ping round pulled ten subterms of the term; with nothing of the term in memory,
the pull made a new term file. Its name comes from an in-memory counter that the
load syncs only as it opens each file, so it was the name of the next file still
to load - and the file was opened without truncation, its header written over
the old one. When the load reached the file, it looked for the first page where
the shorter header ended, in the middle of the old one. A WAL file is now
created only under a name that is
free, the next one taken otherwise, and nothing pulls before this node's own
WAL is loaded. Finding 40's fix made the early pull find work more often, which
is likely why 31 runs had not hit it. Unit test:
`a_new_wal_file_never_opens_an_existing_one`.

### 42. A node back into a new term pulled nothing of it (fixed, 0.20.30)

With finding 41 fixed, leaders back from a restart or a minute down stopped
catching up: `u4` lacked 25 rows until a write reached it a minute and a half
later, and `b5`, back as a spare, held nothing of the term elected without it
and was refused as a follower for good, its position older than anything the
new leader remembered (run 33, P4). Reproduced on the live clusters with a log
line added: every ping round said the node was behind - holding nothing of the
new term, the members through 74 - and no pull ever followed. The first ping
round runs beside the startup load of the node's own WAL; it took the leader's
newer term, and the load, finishing a moment later, stored its own highest term
back over it. The pull asked for every term up to that one, so the new term was
never asked for, and nothing said so. Before 0.20.29 the first round's own pull,
made before the load, happened to fetch the term - and was what wrote over a
WAL file in finding 41. The ping loop now starts once the WAL is loaded, the load
never lowers the highest term, and the pull asks for every term it found
anything missing in. On the live clusters the west leader, stopped for a minute
and started into the term elected without it, pulled it within 5 ms of its load
and held all 3,708 rows.

### 43. Every write still went to a node paused and stopped (fixed, 0.20.31)

Retiring a node is: pause it, stop it, delete its roster row, then its placement
row. The placement row's delete failed, "no response from any nodes" (run 34,
P5). The members took the node's retirement about two seconds after its roster
row went, and until then every write's apply went to it - stopped, so each one
cost a connect timeout. A member that waited on one stalled long enough for a
party it was in to time out, and the write that needed that party was refused.
Nothing was lost; an operator would retry it. A write's party already left out
paused and stopped nodes; its apply did not. The apply now skips a node that is
paused or retired, and a link to another cluster, which refuses it anyway.

### Smaller findings

- **Upward pings to regular upper nodes were refused** (`no peer`), and the
  lower leader logged them demoted every tick: a lower leader signs in through
  an upper node that relays to its leader, and only the leader admitted it.
  The relaying node admits it too since 0.20.10, and a link is never logged as
  demoted.
- **A roster row is resolved when it is written, and at startup** (open). An `N`
  row naming a host that does not resolve yet is refused (`Lookup host: u4
  failed`), so the expansion order, row first and copy second, needs an address;
  and a node whose roster names a host that no longer resolves - a stopped
  container's - exits at startup (`Lookup host: b4 failed`, seen while
  reproducing finding 42 by hand). The harness writes addresses.
- **A node with no `N` row of its own binds 127.0.0.1** and still reports itself
  a follower (run 4). Since 0.20.10 it says so at error level on every config
  load.
- **A term held complete was pulled whole again** on every pull, and every row
  dropped as already present (8,500 such log lines on one node in ten minutes,
  run 14). Fixed in 0.20.13.
- **Found reading the code, not by a run**: the DNS records, the rppd roster and
  reconciliation took cross-cluster links for members, as the pulls did; a peer
  that named another cluster on its pings was a link to the ping handler only.
  Fixed with the rest of the link layer in 0.20.10.

## The relay

Until run 24 a top write to the top-only table reached every top member and
never a lower cluster: cross-cluster data had no carrier, and the test reported
it as `GAP`. Since ytserv 0.20.22 the relay carries it (`tpl2.md`, "The relay").
The lower cluster's leader drives both directions over the link it already
holds to a regular upper node, so nothing new is dialled:

- **down**: it fetches what the upper cluster committed to a table its az holds,
  applies it, and delivers it to its members;
- **up**: it delivers its own cluster's rows of a table the upper cluster holds
  to that upper node, which applies them and delivers them to its members.

Relayed rows are a read-only copy, applied in the source cluster's order outside
the receiving cluster's consensus; every node keeps a cursor per source cluster.
Any node of the source serves the rows from its cluster WAL. Nothing is relayed
sideways.

What the test checks, at the end of every phase (I7): a top write to `rmc_down`
reaches every member of both lower clusters, a second after the write in nearly
every phase of runs 27 to 35, and a lower write to it is refused; an east write to
`rmc_up` reaches every east and every upper member within 0 to 5 s and never a
west node, and a top or west write to it is refused. The feed held through
every step the clusters went through: new nodes, leadership moves, restarts,
leaders lost for a minute, and the east turnover; east's leader, the node that
drives its relay, changed four times (a1, a5, a4, a5, a8).

## Run 35 by phase

Physical-copy joins, round-robin load on every member, yaxaha 0.17.31.

| phase | ok / failed / gap | what happened |
|---|---|---|
| P1 baseline | 47 / 0 / 0 | A minute of load on every member of the three clusters; every invariant; the relay down in 1 s and up in 5 s. |
| P2 grow | 114 / 0 / 0 | `u4`, `a5`, `b5` added at runtime, one at a time, each as a physical copy of a follower: each followed its leader in 3 to 4 s, caught up within a second, and was in the running roster of its cluster and of the linked clusters without a restart. |
| P3 leadership | 98 / 0 / 0 | Leadership moved to each new node within a second; that cluster's term went from 1 to 2, the other two kept their leader and term; the relay followed each new lower leader. |
| P4 refresh | 227 / 0 / 0 | A follower restarted in each cluster, back in 7 s; each leader restarted, a leader again in 5 to 6 s; each leader stopped for a minute, replaced in 21, 24 and 19 s, and back as a follower holding every row - it pulled the term elected without it within milliseconds of loading its WAL. |
| P5 turnover | 299 / 0 / 0 | East: `a6`, `a7`, `a8` added and `a1` to `a4` retired one by one under load, leadership moved off a retiring leader first; upper: `u5` added, `u1` retired; west: `b6` added, `b1` retired. Every retired node paused with its leader's approval and was retired on every member and in the linked clusters' rosters; every copy caught up within a second. |
| P6 after turnover | 74 / 0 / 0 | East's leadership moved again (term 4 to 5) to a node that had never led - it signed in through a regular upper node and carried the relay - and a new follower restarted, with four retired nodes in the cluster's history. |
| P7 follower writes | 24 / 0 / 0 | Six writes started on followers in each cluster: all committed and reached every member; the final invariants on every cluster. |
