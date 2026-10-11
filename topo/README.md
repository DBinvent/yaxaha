# topo test: runtime topology jobs

Tests for the runtime topology jobs of yaxaha - a table's move between azs and
shards, the cleanup of stale copies, az create and delete, and cluster split and
combine - all carried by one job layer: a synced `yt_job` table, decided by the
cluster leader, one active job per table. Every step runs under a write load,
and the invariants of the [rmc test](../rmc/README.md) are checked after it.

It reuses the rmc harness (`../rmc/lib.sh`, `steps.sh`, the writers and
`verify.py`) and, so far, its three linked clusters.

| script | what |
|---|---|
| `lib.sh` | what the scripts share: the rmc harness, the job helpers, `jobs_on` (syncs `yt_job`) |
| `t0_jobs.sh` | the job layer: a job asked for on a follower is decided by the leader; one active job per table; kinds not built yet refused; cancel; a job survives the loss of the leader; a move job runs to its flip; every member holds the same job rows |
| `t1_az.sh` | az create and delete at runtime: a zone and a linked cluster's catalogue entry created and seen by every member without a restart; a second create, a delete of a zone a table is routed to and of a zone a live node is placed in, refused with the reason; each deleted once unused and gone from every member's map, again without a restart |
| `t2_move.sh` | a table's move between two zones of one cluster, and its stale copies: a move without purge deletes nothing and its old holders stop receiving the table's writes; a cleanup during the move is refused; a cleanup reports the stale rows, and with `purge` deletes them only where another node holds the same row, keeping the one no other node holds; a move back with purge, under updates to the table, ends with the new holders complete and the old ones empty |
| `t3_group.sh` | jobs that span linked clusters: the top cluster's leader approves its own group job, a lower cluster's is approved by its upper (which keeps a record) and refused while the upper takes part in a group job on the same table; a cluster taking part in another cluster's job refuses its own jobs on the table until released; a job takes every participant's lock or none; two jobs racing for the same clusters - one wins, the other is refused naming the holder and gets it on retry |
| `t4_split.sh` | split and combine of members (destructive - run it last): a zone of west is refused while a table both sides hold cannot cross, then split off as a cluster below west - approved by top, the zone's table going with it, a shared table crossing the relay both ways, the new cluster electing its own leader and its group jobs approved by west, never top; then combined back - its nodes members of west again, in their zone, with the rows written while apart |
| `t5_faults.sh` | the jobs under faults (destructive - run it last, on its own): a move loses a target to a restart mid-fill, a move back loses its leader for a minute; a group job loses its own cluster's leader, then a participant's; a split loses a node of its zone during the cut, the cluster it made loses its leader during the combine back, a second split loses the leader of the cluster it splits during its cut - each job resumes and ends as it would have; then every job row on every cluster is finished with a reason, and no lock is left |
| `t6_negative.sh` | refusals and border cases of the job layer (not destructive - after t3, before t4): unknown kinds, unsynced tables, unknown zones and uuids, a forged state on a follower, cancel in each state, empty / no-op / one-node moves, cleanup with the only other holder down, a split of a one-node zone or under a move, a move whose target stays down - several fail today, each a gap in `topo-jobs.md` |
| `t7_membership.sh` | membership under change (destructive - on a fresh layout, on its own): pausing the leader is refused, a paused follower follows again, a dead node removed without a pause, two nodes added at once, a node joined empty - two fail today (F9, the empty join) |

## Run it

On the docker host, with the rmc test set up (see its README):

```
../rmc/up.sh       # three new clusters and the writers
./t0_jobs.sh       # writes results/t0-<time>.log, exits 0 when no check failed
./t1_az.sh         # results/t1-<time>.log
./t2_move.sh       # results/t2-<time>.log
./t3_group.sh      # results/t3-<time>.log
./t4_split.sh      # results/t4-<time>.log - last: it leaves west changed
../rmc/up.sh && ./t5_faults.sh   # results/t5-<time>.log - on a fresh layout, like t4
./t6_negative.sh                 # after t3, before t4 (the nightly runs it there)
../rmc/up.sh && ./t7_membership.sh   # on a fresh layout, like t5
```

## Asking for a job

Insert a row on any node; the leader decides it, in order, and writes every
later state:

```
begin;
insert into yt_job (kind, tabl, params) values ('move', 'mydb.public.orders', '');
select yt_complete(true);
commit;

select id, kind, tabl, state, reason, approved_by from yt_job order by id;   -- follow it
update yt_job set state = 'cancel' where id = ...;                             -- stop it (as a cluster write)
```

`state`: `requested` -> `approved` | `refused`, `approved` -> `running` ->
`done` | `failed`, or `cancel` -> `cancelled`. `reason` says why it was refused,
how it ended, or what a cancel left behind.

The az kinds take their arguments in `params`: `az_create` with `name=<az>` and
what the az is - `tier=<n>` and/or `nodes=<uuid,...>` for a zone of this
cluster, or `level=UPPER|NEIGHBOR` with `host=<host:port,...>`, or `level=LOWER`
with `pub=<key>`, for another cluster; `az_delete` with `name=<az>` and, for an
az whose placed nodes are all out of the roster, `force`. Both need the config
table synced (its trigger), since an az is its `Z` rows.

`move` takes the table in `tabl` and the new rule in `params`: `cfg=<the table's
A value>` and, to delete the moved rows from the old holders after the flip,
`purge`. Without `purge` the old holders keep their rows - stale, no longer
written to. `cleanup` on a table reports how many stale rows its nodes hold, and
with `purge` deletes them, each only once another node in the table's scope
answers that it holds the same row; a row no other node holds is kept, and the
job's `reason` counts it. A move or cleanup is refused while another job holds
the table.

A job that spans linked clusters - `split` and `combine`, once built, and
`group_noop`, which exercises the path - names the other clusters taking part in
`with=` (their az names) and is approved from above: by its own leader when its
cluster has no upper cluster, otherwise by the leader of any direct upper,
reached through a regular node there. Each cluster taking part records its part
as a `participate` row in its own `yt_job`, which holds the table there like any
job; the upper records an `approval` row. A lower cluster is never dialled, so a
job takes part only with its uppers and neighbours:

```
begin;
insert into yt_job (kind, tabl, params) values ('group_noop', 'mydb.public.orders', 'with=eastc;hold=30');
select yt_complete(true);
commit;
```

`split` takes `az=<zone>` and `level=LOWER|NEIGHBOR|UPPER` - the new cluster's
place as this one sees it: the nodes of the zone leave and form a cluster of their
own, linked at that level, each starting again in its own process. `combine`, asked
for on the cluster that ends, takes `into=<the cluster joined>` - its upper or
neighbour - and its nodes join that cluster as members of a zone named as it was.
Both refuse, naming the table, a table both sides would hold that never crosses
between them.

