# Topology tests — 6 nodes in Docker

Exercises the rules in `topology.md` / `shard.md` / `az.md` against a real
cluster: az routing, the `no_up` / `no_down` tier filter, shard placement, and
the flat baseline that must stay byte-for-byte unchanged.

## Why Docker and not LXC

Measured on the docker host, not assumed:

| | per node |
|---|---|
| Docker, PostgreSQL running | **42 MB** |
| LXC, systemd only (before PostgreSQL) | **70 MB** |

A system container buys an init system this test does not want — ytserv is
started directly — and on a host that also runs Docker it needs the macvlan
workaround in `../lxc/env.sh`, because Docker's `FORWARD DROP` policy cuts
lxdbr0 off from the network. Six nodes cost ~256 MB and share one 170 MB image.

`../lxc/` stays as-is: it is a single-node `yxctl --batch` install test, a
different question.

## Layout

    tier 0   top    n1 n2     writes config down, never receives big tables
    tier 1   east   n3 n4     a MINORITY zone: 2 of 6
    tier 1   west   n5 n6

east being a minority is the point. Before the threshold fix
(`topology-todo.md` §2.0) a table routed there got `party_size` 3 from a 6-node
cluster, `select_party` could offer 1, and every write aborted.

## Running

    cargo build --release -p ytserv -p yxctl
    cargo deb -p yxctl --variant pg18 --no-build
    ./run_all.sh          # 00_build, 10_up, then every test below
    ./90_down.sh          # free the containers

`YX_HOST` selects the docker host: an ssh target, or `local` (the default) to run here. Set it in `../.env` (see `../env.example`).
Individual tests re-run against a live cluster without rebuilding.

**A new image does not reach a running container.** `00_build.sh` builds the
image; `restart_all` (and `docker restart`) reuse the container that already
exists, which was created from whatever image was current *then*. Only
`10_up.sh` recreates them (`docker rm -f` + `docker run`). So after changing any
Rust source the cycle is **`00_build.sh` then `10_up.sh`**, never `00_build.sh`
plus a restart — that combination silently tests the old binary, and the tests
look like they are exercising a fix that was never deployed. Check with:

    docker exec n1 grep -ac '<a string from your change>' /usr/local/bin/yaxaha/ytserv

## What each test asserts

| script | asserts |
|---|---|
| `15_setup.sh` | `yt_setup` registers a table on **every** node, leader or not — the §2.6d fix (the one test that uses `yt_setup` rather than `register_table`) |
| `20_flat.sh` | an unrouted table replicates to all 6 — `topology.md` invariant 6 |
| `30_az.sh` | a minority-zone write is accepted, lands on both east nodes, reaches none of the other four |
| `40_tier.sh` | `no_up` keeps a tier-1 table off tier 0 |
| `50_shard.sh` | `az_node_uuid` puts each row only in its owner's zone |
| `60_write_az.sh` | `writable_az`: east holds the table, only top may originate writes |
| `70_reshape.sh` | moving a table east → east+west loses no row and duplicates none |
| `80_recon.sh` | a row corrupted out of band is detected and repaired from the majority |
| `85_alert.sh` | an unrepairable split-vote row is blocked and filed to `yt_alert` |
| `88_quiescent.sh` | a table nobody writes to still heals, on the age trigger alone |
| `95_partition.sh` | `yt_info('p:<table>/<n>')` slices a table into partitions that tile it exactly once — executed, not just inspected |
| `96_jsonb_merge.sh` | concurrent disjoint patches of one jsonb row from several nodes all survive, the nodes agree |
| `96b_merge_more.sh` | `merge_all_fields`: counters (a numeric column and a jsonb number) incremented from several nodes keep every committed increment, never 55409; `merge_text`: a line patch composes with a different line changed elsewhere, the same line is refused; arrays: an element update and an append compose, a middle insert against a diverged array is refused |
| `31_commit.sh` | the commit path: explicit and automatic completion, rollback, a prepare vetoed on one member, a failed statement mid-transaction (nothing left open anywhere), PK update / delete / truncate, a 500-row transaction |
| `86_schema_block.sh`, `87_node_block.sh`, `89_recover.sh` | blocking at table and node scope, a node gone and back |
| `32_schema_change.sh` | a schema change rolled across the running cluster (followers first, the leader last, rumba.md) under writes: the same schema on every node before and after (columns, defaults, positions, constraints, indexes), writes across the mixed window, the schema gate reporting it and clearing, the new column replicating, then an index, a NOT NULL default column and the contract step; S9 the gate judging a widened column by SchemaGuard's rules, defaults and `sg_migration=with_size_cut` |
| `23_split.sh` | a real network split (routes cut inside the containers): 4/3 - the minority never leads or commits, heals; 3/3 - neither side commits, one leader after |
| `92_rppd.sh`, `93_etcd.sh`, `94_clickhouse.sh` | Python server functions on commit, the etcd API v3 surface, the ClickHouse sink |
| `91_otel.sh` | OpenTelemetry: a collector on the fixture network gets `yt.tx` root spans (service.name ytserv), one transaction's spans from two nodes in one trace, and the metrics yt.term, yt.leader, yt.peer.rtt, yt.queue.depth, yt.tx.duration and rppd.contexts |
| `92b_rppd_breaker.sh` | rppd circuit breaker: a restart adds its columns (SchemaGuard); a pp whose downstream is down opens a breaker on every node that ran it ('open' to notify_q, state row open), holds what arrives, and after the back-off a probe closes it and every message - before and while open - is processed; a poison message is tried max_attempts times, then lands in dlq |
| `92d_rppd_shaper.sh` | rppd traffic shaper, per function per node: max_parallel = 2 never runs more than 2 at once; rate_per_sec = 2 spaces the starts; a capped function does not delay another; max_backlog sends one 'over' and one 'under' |
| `92c_rppd_cadence.sh` | rppd cadence: a pp queue fed on time stays ok; silence -> watch messages (retried), one deadline message, ok on recovery; watch 0 -> deadline at once; bad rows refused; the watch survives the leader stopping |
| `97_mpp.sh`, `98_mpp_df.sh`, `98_skv_join.sh` | the MPP partition layout and DataFusion, the SKV join challenge |
| `34_skv_store.sh` | the secret store (yt-pgxt ytserv/skv-secrets.md): genesis on the leader, put/get/rm through yxctl, no plaintext in any row, the etcd `/secret/` mirror refused to remote callers, every node enrolling and approved, rotation with readers that never fail (the old key retired only once every node confirmed the new one), retirement with the honest converse, recovery with an offline recovery key. Not in the nightly yet (needs the skv build) |
| `35_skv_mtls.sh` | `peer_tls`: the cluster CA and a certificate per node, TLS required once every member has one (plaintext peer RPCs refused, `register`/`skv_enroll`/`ping` still answered), a peer's certificate on the wire, a **cold start with TLS required**, a rotation under load falling back between two certificate versions, `peer_tls` off again. Not in the nightly yet |
| `36_skv_rppd.sh` | a python server function reading `SECRET.get(name)` for the names its `rppd_function.secret_names` lists, refused any other, the plaintext in no table. Not in the nightly yet |
| `skv_lib.sh` | helpers the three share (sourced) |
| `29_concurrent.sh` | 100 multi-row transactions from three origins; a hot table under 8 writers and writes to another table under load |
| `99_peer_stream.sh` | `peer_stream=1`: serial and back-to-back writes, a follower restarted under the stream |
| `25_cross_db.sh` | its own three nodes: ytserv's instance config in the `postgres` database, a users database holding its tables, their `yt_config` (A rows) and the rppd configuration - replication, a table config change, rppd firing, nothing leaking across (the rppd database is resolved, prepared transactions finish in their own database - ytserv 0.20.57) |
| `24_db_local.sh` | a node on TCP PostgreSQL is a forever-spare: a member, never a leader |

`run_a.sh` runs all of them on fixture A (seven nodes, n7 the spare), in that
order and carrying on past a failure; `run_all.sh` builds the image first and
ends with the line the nightly reads. `PLAN.md` is the plan they came from.

## Things that will bite you again

Each of these cost a debugging cycle here and will behave the same on a real
node:

- **`apt-get install ./file.deb`, never `dpkg -i`.** The deb's `Depends` name
  `libcurl4` and `libpq-dev`; `dpkg -i` unpacks, fails, and the follow-up
  `apt -f install` *removes* the package — leaving a build that succeeds and an
  image containing nothing.
- **`libexpat1` is not in the deb's Depends** but the vendored libpython3.12
  links it. ytserv exits 127 on a minimal image. The Dockerfile fails the build
  on any unresolved link rather than letting the first test run discover it.
- **A libpq URL's `@<x>` is the HOST.** `postgresql://postgres@mydb?host=/sock`
  connects to a database named after the *user*, then reports `yt_config` does
  not exist — truthfully, about a database you did not mean. Use
  `@localhost/<db>?host=…`.
- **ytserv refuses to start on a stale `.s.YT.*.pid`**, and a restarted
  container always has one. systemd owns that lifecycle on a real node; here the
  entrypoint clears it.
- **Clear `/var/yaxaha` when you restart to pick up config**, or writes abort
  with `Sub-term 1 version 1 already exists` — the same collision a purge leaves
  behind on a real node.
- **`yt_setup`'s 4th argument is the CONFIG table**, not the table being set up:
  `yt_setup('public.t', '', true, 'public.yt_config')`.
- **A table's module-`A` row is read by the startup loader.** `yt_setup` creates
  it after ytserv is running and a direct `UPDATE` does not travel through
  `re_config`, so a config change needs a synchronised restart — `restart_all`.
- **`yt_setup` cannot register a table on a non-leader once `yt_config` is
  itself synced.** It creates the trigger and writes the module-`A` row in ONE
  transaction; the write is refused ("require call from cluster leader") and the
  rollback takes the `CREATE TRIGGER` with it. The node then has neither, looks
  registered from the leader's side, and every write there fails with
  `yt_complete: not connected` — naming neither the table nor the reason. Use
  `register_table` / `cfg_write` / `cfg_delete` from `env.sh`.
  **FIXED 2026-09-19 in `ytpgc/pg_setup.sql`** — the config write now suppresses
  the config table's trigger and sits in its own subtransaction, so it can no
  longer roll back the `CREATE TRIGGER`. `15_setup.sh` proves it. The fixtures
  keep using `register_table` anyway, and `10_up.sh`'s bootstrap deliberately
  does too: the harness's bring-up must not depend on the feature under test.
  Before the fix the suite's result depended on which node won the election —
  `40_tier` and `85_alert` both failed on a freshly recreated cluster while
  passing on the previous one.
- **`yt_info` returns `json`** in this build. An older build needed
  `as x(name,value,module)`, which now errors with "a column definition list is
  only allowed for functions returning record".
- **A killed run poisons the next one through 2PC, not through the WAL.**
  `rm -rf /var/yaxaha/*` is not a full reset: a cluster write that dies between
  PREPARE and COMMIT leaves a `PREPARE TRANSACTION` behind, those survive a
  PostgreSQL restart by design, and they hold their table locks forever. The
  next test's opening `drop table if exists …` then blocks and the run produces
  **no output at all** — which reads as a slow cluster, not a wedged one.
  `env.sh` now sweeps them (`clear_prepared`, on source and inside
  `restart_all`) and `q` sets `lock_timeout=30s` so a blocked statement fails
  loudly instead of hanging. **Never leave two runs going at once** — they
  restart the same six containers and drop each other's tables.
- **`reshape_run` is consumed by the flip, so a killed move leaves it set.** The
  monitor reads a value still present at startup as "resume an unfinished move",
  which is right — but it means a stale row fires a reshape during the *next*
  run's setup phase. `70_reshape.sh` clears it before its first restart.
- **Nodes run at `log_level=warning`** (`10_up.sh`, for the ~11% it costs at
  `debug`), so anything logged at `info!` is invisible in `docker logs`. A
  once-per-operation result line that a test needs to read has to be `warn!`.
  `logs_all` in `env.sh` greps every node's output, which is what a
  cluster-wide decision needs: it is logged by whichever node was leader, and
  grepping the node you guessed is how a real line gets read as absent.
