# Comprehensive cluster feature test plan — Docker

Feature coverage, not performance. Nothing here measures throughput or latency;
where a test drives concurrent load it asserts **agreement**, never a rate.

Drafted 2026-09-24. Not yet executed.

---

## 1. What is on the docker host right now

Measured, not assumed:

| | |
|---|---|
| Docker | 29.1.3 |
| CPU / RAM / disk | 8 cores, 15 GB (13 GB available), 700 GB free |
| Running | `n1`–`n6` (`yxtopo-node`), up 4 days, **Term 1, healthy**, `min_cluster_size=6` |
| Images | `yxtopo-node` 643 MB, plus the pg16/pg18 builders |

Four facts from that survey shape everything below.

**1. The image predates this session.** `ytserv` in `yxtopo-node` is the
2026-09-17 deb. Every feature built since — the unix-socket rule, all six SKV
phases, peer TLS — is absent. And per the README's own warning, a rebuilt image
does **not** reach a running container: `00_build.sh` then `10_up.sh`, never
`00_build.sh` plus a restart.

**2. There is no `git` in the node image.** `docker exec n1 command -v git` →
nothing. `rppd_git::materialize` and rdbm's `source_git` both shell out to it,
so **git-sourced functions and git-sourced migrations have never been exercised
at all** and cannot be until the image changes.

**3. `serve_etcd` defaults to `false`** (`rmc.rs:861`) and the fixture does not
set it. `skv_etcd()` returns `None` without it, so every SKV flow is a no-op on
this fixture as it stands.

**4. `95_partition.sh` is about `yt_info('p:…')` — MPP partitions, not network
partitions.** Despite the name, **split-brain has never been tested**. That is
the largest uncovered correctness claim in the tree: `membership.md` §"Why
removing Off from `total` is not a split-brain hole" rests on
`ups > p_cnt / 2` with a roster denominator, and nothing checks it.

---

## 2. Fixtures and node count

Three fixtures, **13 containers**, ~700 MB — a twentieth of what the box has.
Two clusters rather than one because the SKV work needs settings that are
disruptive to everything else: `skv` changes whether joins are challenged, and
`peer_tls` is **all-or-nothing across a cluster** (a TLS listener does not speak
plaintext). Sequencing those on the main fixture would mean a restart storm
between every group and a real risk of a test passing because a previous one
left a row behind.

### A — `yxtopo`, 7 nodes + 1 git server

```
tier 0   top    n1 n2
tier 1   east   n3 n4          (minority zone: 2 of 6 participants)
tier 1   west   n5 n6
         —      n7             TCP-attached PostgreSQL: a FOREVER-SPARE
                gitsrv         git daemon on the same network
```

`skv=false`, `peer_tls=false`, `serve_etcd=true`.

**Why seven.** Two reasons, and neither is padding:

* **7 partitions 4/3** — odd, no tie, and a genuine minority. Six partitions 3/3,
  which is the degenerate case where neither side should elect and a bug that
  lets *both* elect looks the same as a bug that lets neither.
* **`n7` is the db-local test.** Its PostgreSQL is reached over TCP, so it must
  never leave `Spare` no matter how current it is. It is in the roster (an `N`
  row) but `min_cluster_size` stays **6** — which is itself the assertion: a
  7-node roster containing one forever-Spare must still form a 6-node cluster.

`gitsrv` is a container, not a host service, because the nodes must reach it by
container network name — and because a git server on a separate host (the earlier sketch)
would make a test depend on a machine outside the fixture.

**It speaks ssh only** (decided 2026-09-24), which is how the real deployments
authenticate. The consequence, stated rather than discovered: `git_credential_line`
returns `None` for an ssh remote **by design**, so Phase 6's git-credential
branch — `SecretFile` → `source_git_credentials` → `credential.helper=store` —
gets no integration coverage and stays on its unit tests alone. What *is*
covered, and matters more, is the database half of Phase 6 (`db_secret_name` →
`db_password` for a real migration) and the branch that says a
`source_secret_name` set on an ssh remote is **not** an error and must not break
a working ssh setup.

### B — `yxskv`, 4 nodes

```
s1 s2 s3 s4      skv=true, serve_etcd=true, flat
```

Four, not six: SKV has no zone dimension that is *implemented* — per-zone master
keys are §11.2, an open question, so a zoned SKV fixture would be testing
something known to be absent. Four is enough for genesis, a leader, a node taken
down across a rotation, and a node removed by §5.1b.

Peer TLS is flipped on this fixture only, in its own pass, and flipped back.

### C — `ch`, 1 ClickHouse container (optional, last)

Attached to B for the `on_commit_clickhouse` sink and the etcd `/q/ch:<table>/`
queue consumer. Optional because it is the only part that pulls a 1 GB image,
and it tests an integration rather than a cluster property.

---

## 3. Prerequisites — image and harness changes

These are code changes, not test runs, and every one of them is a prerequisite
for a test below rather than housekeeping.

**All DONE, 2026-09-24**, except the destructive half of P7 (see below).

| # | Change | Unblocks | |
|---|---|---|---|
| P0 | `ytpgc/dist/` symlinked to the `master` worktree's copy | `cargo deb --variant pg18` at all | **done** |
| P1 | `Dockerfile`: `git`, `openssh-client`, `iproute2` | rppd_git, sg `source_git`, partition tests | **done** |
| P2 | `node-entrypoint.sh`: `DB_URL` override, defaulting to today's socket URL | `n7`'s TCP-attached PostgreSQL | **done** |
| P3 | `env.sh`: `YX_NODES` / `YX_AZ` / `YX_TIER` / `YX_SPARE_NODES` overrides, `is_spare_node` | fixture B without a forked harness | **done** |
| P4 | `env.sh`: `partition`, `heal`, `node_down`, `node_up` | split-brain, rejoin, retired-key rejoin | **done** |
| P5 | `Dockerfile.gitsrv` + `gitsrv-entrypoint.sh` + `05_gitsrv.sh`: sshd + git, a deploy key, two seeded repos | groups 4 and 5 | **done** |
| P6 | `10_up.sh`: `serve_etcd=true` | every SKV flow, the etcd and queue tests | **done** |
| P6b | `pg_setup.sql`: `yt_join_gate`, byte-identical to `join_gate.rs::join_gate_sql` | `98_skv_join.sh` §5 | **done** |
| P6c | `10_up.sh`: spare nodes get a TCP `DB_URL`; `min_cluster_size` excludes them | `24_db_local.sh`, `35_queue_spare.sh` | **done** |
| P7a | `cargo build --release`, `cargo deb --variant pg18` → `yaxaha_0.14.1_amd64.deb` | everything | **done** |
| P7b | `00_build.sh` → image `6834e351`, 190 MB, carrying `git`/`ssh`/`ip` and the new binary | everything | **done** |
| P7c | `10_up.sh` — **recreates the containers, destroying `n1`–`n6`** | everything | **first step of the run** |

**P7c is deliberately not done.** It is the destructive half, and running it now
would leave a live cluster sitting idle until the matrix starts. The README's
warning still governs the order: a rebuilt image does **not** reach a running
container, so the run opens with `10_up.sh` — which is cheap and is where the
approved destruction belongs.

The deploy key for `gitsrv` is generated **on the docker host** and `docker
cp`-ed into each node; it never enters an image layer, because an image is
cached and often pushed and a key baked into one has been handed to everyone who
can pull it.

### The version bump, and what it broke

`etcds` 0.17.0 → **0.18.0**, plus a full `cargo update` in both lockfiles. Two
consequences, neither obvious:

**A patch applies only when it SATISFIES the requirement.** `ytserv` asked for
`^0.17`, which `0.18.0` does not match, so `[patch.crates-io]` silently stopped
applying — cargo fell back to the **registry** `etcds 0.17.0` for `rppd`, the
graph ended up with two `etcds`, and the failure surfaced as a type mismatch
between two structs of the same name. Fixed by bumping the requirement in
`ytserv/Cargo.toml` **and** `rppd/Cargo.toml` together; the workspace root now
carries a comment saying so.

**rppd standalone then could not build at all**, because `etcds 0.18` is not
published. Its own workspace root gained a `[patch.crates-io]`, the same
temporary measure `yt-pgxt` already uses for `schema_guard_tokio`. Both come out
when 0.18 ships.



**P0 and P6b were found, not assumed, and each would have failed late.**

`ytpgc/dist/` is **gitignored**, so it exists only in the `master` worktree —
`cargo deb` in this one dies on a missing `.so`. The extension itself needs no
rebuild: `ytpgc` compiles `base`, `db`, `diff_doc` and `rppc`, and the only
proto this session changed is `leader.proto`, which it does not.

The fixture never runs `yxctl --batch` — it bakes the extension into the image
and writes config rows by hand — so `JoinGateAction` never fires and
`yt_join_gate` does not exist. `98_skv_join.sh` §5 asserts that trigger refuses
an unarmed `ok`, and without P6b it would fail for a reason that has nothing to
do with the thing under test.

Two things that are **already** fine, checked rather than hoped: `etcds` is a
path dependency on `../etcd`, so the uncommitted prefix-policy work is in the
build; and `pgbench` is in the node image, so `29_concurrent.sh` needs no extra
package.

---

## 4. Test matrix

Numbers continue the existing scheme. **Bold** = written this session and not
yet run; the rest are new.

### Group 1 — regression baseline (fixture A, existing)

`15_setup` `20_flat` `30_az` `40_tier` `50_shard` `60_write_az` `70_reshape`
`80_recon` `85_alert` `88_quiescent` `95_partition` `96_jsonb_merge`

These must stay green on the rebuilt image. Any change in them is a regression
from this session's work, and finding that out **before** adding new tests is
the only way to attribute it.

### Group 2 — membership, elections, and the db-local rule (fixture A)

| script | asserts | the failure it catches |
|---|---|---|
| `21_membership.sh` | pause granted; pause refused when it would drop below `min_cluster_size`; `force` overrides; resume carries a position and is measured against the lease budget; leader demotes an unresponsive Follower | an operator draining nodes in sequence takes the cluster down on the one that crosses the line |
| `23_split.sh` | partition 4/3 → the **minority never elects** (`ups > p_cnt/2`, roster denominator), the majority keeps committing, heal reconverges with no divergence; then 3/4 the other way | two leaders, or neither — and the two look identical from one side |
| `24_db_local.sh` | `n7` never reaches Follower **or** Leader; `force` does not override; `yt_info('E')` reports `forever_spare` with a reason; the other six elect normally with `min_cluster_size=6` | a node that cannot originate a write is elected, and the failure surfaces later as commits that do not happen |

`23_split.sh` is the highest-value new test in this plan. It is also the one
most likely to fail.

### Group 3 — schema gate and config plumbing (fixture A)

| script | asserts |
|---|---|
| `25_schema_gate.sh` | a column added on one node blocks the write **before** any checksum; `ignore_sg` and `sg_ignore` each release it; the gate re-arms on a table config change |
| `26_cfgsync.sh` | with `--config-trigger`, a `C` write propagates and applies live; a restricted module (`C` `N` `A` `J` `K`) written on a follower is refused with the leader message; without the trigger the manual path still works |

`26` covers `CFGLC` for the two letters this session added, `J` and `K`, on the
same footing as the three that were already there.

### Group 4 — migrations and function bodies (fixture A + gitsrv)

| script | asserts |
|---|---|
| `27_sg_history.sh` | one-at-a-time ordering by `ORDER_KEY`; `all_together`; the `result` jsonb accumulating **one key per node** through `yt_diff_apply` (disjoint-path merge, not last-write-wins); a failed node does not stop the ones behind it; a skipped node does not hold the turn forever |
| `28_rppd_git.sh` | a function body materialised from `gitsrv`; **leader-only resolution** (a moving ref must not resolve to N different commits); `script_tag` pinning avoids a re-fetch; the schema guard holds a body back *before* the clone |

Both are first runs: neither has ever executed, because the image has no git.

### Group 5 — SKV, all six phases (fixture B)

| script | asserts |
|---|---|
| `97_skv.sh` | §10.2 items 1–7: push via `share/` and its disappearance; **`share` never reaches a peer**; the transport entry is sealed (grep the raw bytes for the plaintext and require no match) and expires; replace-not-insert; the local namespace does not propagate; AAD bound to the name; a truncated/unknown-version envelope rejected structurally; pull by inquiry; one answer not five; `/secret/` refused over the network while `/q/` and `/cluster/` still answer; durability follows `skv_storage`; the wrong MK fails at **boot** on the canary; the store table is refused a sync trigger |
| **`98_skv_join.sh`** | written. Negative control (skv off = unchallenged), refusal with skv on reaching **neither Follower nor Spare**, the `J` row and its challenge, challenge **stability across retries**, the fingerprint field, the trigger refusing an unarmed `ok`, `CFGLC` on a follower, a forged `ok` admitting nothing, the sweep, the `K` row and its leader restriction. Extend with Protocols B and A once genesis has run here |
| `99_skv_rotate.sh` | §10.2 items 14–20: mixed versions and **no read fails at any point**; a kill mid-pass loses nothing; two concurrent requests publish one version; advancing `keyver` early strands nobody; **no chain** — `MK_n` plus all of `@meta/` does not yield `MK_(n+1)`; removal (drop `N`, drop `K`, rotate) denies the new key, and the honest converse: what that node already read is still readable from its own store |
| `93_skv_tls.sh` | `peer_tls` on all four → the cluster forms; a node with it **off** cannot talk to one with it on (the all-or-nothing property, asserted rather than documented); an anchor in `<fs_dir>/peers/` whose key the `K` row does not name is **refused**; a stranger certificate is refused |
| `94_skv_consumers.sh` | `yxctl --skv put/get/ls/rm`; `db_secret_name` resolving into `db_password` for a real migration; `source_secret_name` producing a git credential file that a clone from `gitsrv` actually uses; a missing secret yielding **Pending** (row retried, not failed) and then succeeding once pushed; with `log_statement=all`, **no secret value anywhere** in the Postgres log, `pg_stat_statements`, or `~/.psql_history` |

The `log_statement=all` grep in `94` is the one that matters most: every other
claim in §6 about values not reaching SQL is a claim about code, and this is the
only check that looks at what actually got written.

### Group 6 — concurrency correctness (fixture A)

| script | asserts |
|---|---|
| `29_concurrent.sh` | a **fixed, small** number of concurrent writers against one replicated table; afterwards every node's digest **matches**; zero `cluster_apply fail`; no wedged WAL; the same at a second fixed width |

Explicitly **not** a benchmark: no tps is recorded, no threshold is asserted,
and the run length is fixed rather than tuned. The property under test is
agreement under concurrency, which the working notes record as historically
broken (`pgbench -c4` diverging, hot small tables still diverging after the
AB-BA lock-order fix). If it still diverges, that is a finding to record, not a
number to improve.

### Group 7 — the embedded services and the queue route (fixture A, and B for etcd/secret)

| script | asserts |
|---|---|
| `31_etcd.sh` | the prefix policy end to end: `local` does not propagate, `local_except` does, `local_only` is refused to a non-loopback caller while other prefixes answer, `zone` confines a key to one az; the in-process embedder API goes through the same `*_impl` path as a wire call, so an embedder cannot bypass a policy by not using the wire |
| `32_dns.sh` | records refresh on the ping tick; a leader change is reflected; the `dns_port` collision with avahi is avoided by configuration, not luck |
| `34_queue_route.sh` | `queue-p2p-route.md`, Phases 1/2/3/5 — see below |
| `35_queue_spare.sh` | a **forever-Spare** node is a first-class queue participant — see below |

#### `34_queue_route.sh` — the p2p route

| # | asserts | the failure it catches |
|---|---|---|
| 1 | a put to `/q/{name}` or `/q/{name}/c/{cid}` is stored as an **ordinary key** and is **not** enqueued — `count` on the queue stays 0 | the registry filling the queue it exists to route. This was the pre-existing behaviour and it would have made both registries unusable |
| 2 | first touch writes `/q/{name}` = a node id, and every node converges on the **same** value | no dispatcher at all, which is what left the broadcast fallback as the default path |
| 2b | **the dispatcher is an ENDPOINT.** A consumer's node claims on the **first watch**, with no delay; a producer claims only an unclaimed queue and does **not** take one away from a consumer's node; with consumer on B and producers on A and C, `/q/{name}` names **B** | a dispatcher at neither end — two hops for every producer instead of one, and invisible except as load |
| 3 | a producer on a node that is **not** the dispatcher sends **one** unicast, not `N-1`, and **one**, not two — counted by asserting the message never appears on the uninvolved nodes and never transits a third | a silent return to the broadcast, or a third-party dispatcher reintroducing the extra hop |
| 4 | a consumer registers `/q/{name}/c/{cid}` = its host; the dispatcher delivers **across nodes** to it; the ack deletes on the dispatcher | delivery that only ever worked when producer, dispatcher and consumer happened to share a node |
| 5 | drop the consumer's watcher → its registration is **withdrawn**, and the dispatcher stops unicasting into a node with nobody listening | a dead consumer that reads as a slow one |
| 6 | kill the dispatcher node → the next touch **re-elects** rather than routing to a peer that is no longer Online; no message is lost | a pinned dispatcher on a demoted peer, silently used |
| 7 | **Phase 5**: with producer, dispatcher and consumer on one node, nothing crosses the network at all | the single-node and dev case regressing invisibly, which is what `queue.md:17` warns about |
| 8 | **Phase 3 is RELOCATION, not placement**: move the consumer to a different node → the dispatcher follows it after `PIN_STABLE`, but **not** while a message is dispatched-but-unacked, and **not** while the consumer is flapping. Placement itself must already have happened at the first watch (2b) | a dispatcher that chases a reconnecting consumer and churns a replicated key cluster-wide; one that moves while messages are outstanding and strands them; and a 30-second wait to reach the *correct* placement, which would make the common case the slow one |
| 9 | a **zone-scoped** queue key is not unicast to a peer in another zone, nor to one whose zone is unknown | `unicast` bypassing the zone test by virtue of being targeted — the leak zoning exists to prevent |

#### `35_queue_spare.sh` — the forever-Spare node as an etcd peer

`n7` reaches its PostgreSQL over TCP, so it can never be Main
(`membership.md` §Forever-Spare). The original rule says such a node
*"can be a forever spare for an etcd and rppd node"* — and **nothing checks
that second half.**

The trap this exists to catch is a **collision of one word**. `PeerState::Spare`
in `etcd/src/peer.rs` is that crate's own liveness state — a peer that timed out
or has not synced — and `broadcast_scoped` **skips Spare peers entirely**. If
anything ever conflated it with ytserv's `PingStateCode::Spare`, a forever-Spare
node would drop out of every etcd broadcast and out of queue routing, and the
symptom would be a node that is up, healthy, in the roster, and silently carries
no queue traffic.

| # | asserts |
|---|---|
| 1 | `n7` is `forever_spare` in `yt_info('E')` **and** is an etcd peer in `Online` state — the two states are independent |
| 2 | `n7` can **produce**: a message put on `n7` reaches a consumer on another node |
| 3 | `n7` can **host a consumer**: `/q/{name}/c/{cid}` names `n7`, and the dispatcher delivers to it across nodes |
| 4 | `n7` can **be the dispatcher**: touch a queue on `n7` first, and `/q/{name}` names it; other nodes route to it |
| 5 | with the consumer on `n7`, `/q/{name}` names `n7` **from the first watch** — a node that may never be the cluster's write master is chosen as the queue's endpoint immediately, not as a delayed optimization |
| 6 | a leader election that excludes `n7` does **not** disturb any of the above |

Items 4 and 5 are the sharp ones: a node that may never be the *cluster* leader
being the *queue* endpoint — chosen on the first watch, not eventually — is the
whole claim, and the two leaderships have nothing to do with each other.

Item 3 is where p2p is actually visible: producer on `n1`, consumer on `n7`,
`/q/{name}` = `n7`, and the message makes exactly **one** hop `n1 → n7`. If it
takes two, a third party is dispatching and the endpoint rule has regressed.

### Group 8 — ClickHouse (fixture C, optional, last)

`33_clickhouse.sh` — `on_commit_clickhouse` splits a row across `d`(PK)/`dd`(full);
every statement of a multi-statement transaction arrives (the `TxData::append`
case that was dead for statements 2..n); the etcd `/q/ch:<table>/` consumer
writes JSON straight through.

---

## 4a. Decisions taken 2026-09-24

| | |
|---|---|
| **git server** | **ssh only** — a deploy key, matching the real deployments. Phase 6's git-credential branch therefore has unit coverage only (see §2 A) |
| **on failure** | **record and carry on.** Every red is written up in §7 with evidence and a verdict — defect in the feature, or defect in the test — and the run continues. No source changes to ytserv/yxctl mid-run |
| **scope** | **all 8 groups, one pass** |
| **docker host** | `n1`–`n6` are destroyed and recreated (required by P7; nothing on them is preserved). All fixtures, including ClickHouse, are **left running** at the end so a red script can be re-run against live state without a rebuild. `90_down.sh` frees them |

---

## 5. Order, and why

1. **P1–P7** — rebuild and recreate. Nothing before this is meaningful.
2. **Group 1** on fixture A — the baseline. If this is not green, stop: every
   later failure would be unattributable.
3. **Group 2**, then **3**, then **4** — membership before schema before
   migrations, because each layer assumes the one under it.
4. **Group 6** — concurrency, after the features it stresses are known good.
5. Bring up **fixture B**; **Group 5** in the order 97 → 98 → 99 → 93 → 94.
   `93_skv_tls.sh` runs late because it flips a cluster-wide switch, and `94`
   after it because a consumer test over TLS is the realistic arrangement.
6. **Group 7** on whichever fixture the test names. `34_queue_route.sh` before
   `35_queue_spare.sh`: the second assumes the routing works and asks only
   *whether a forever-Spare node is allowed to take part in it*, so running it
   first would produce a red that says nothing about `n7`.
7. **Group 8** only if the rest is green.

Fixture A stays up between groups. Fixture B is torn down and recreated between
97 / 98 / 99, because each starts from a different key state and a leftover
`@meta/keyver` makes genesis a no-op.

---

## 6. What this plan does **not** cover, deliberately

Named here rather than left to be discovered missing.

* **Performance.** No throughput, latency or scaling measurement anywhere.
* **The ACL (§4.6).** Authorisation over `/secret/` is not implemented, so there
  is nothing to test. The 0600-file boundary that stands in for it *is* tested
  (`94`).
* **Per-zone master keys (§11.2).** An open question, not a feature.
* **Secret TTL and per-secret rotation (§11.2b).** Deferred by decision.
* **`MK` handoff over an authenticated channel at join (§2.2).** Genesis
  distributes over the KV plane and that is what is tested; the join-time
  handoff is bound by the fingerprint but the channel itself is only
  authenticated once `peer_tls` is on, which `93` covers separately.
* **pgbouncerxa.** Removed from the deb; the `yaxaha.auto_complete` GUC does the
  same at the extension level, and no test here needs a pooler.
* **Upgrade / mixed-version clusters.** A real gap, and a pass of its own.
* **`queue-p2p-route.md` Phase 4** — the persistent peer stream. Not built, so
  there is nothing to test. It reduces the cost *of* a hop rather than the
  *number* of hops, and the document orders it after Phase 3 for that reason.
  `34_queue_route.sh` counts hops, so it stays valid when Phase 4 lands.

---

## 7. Deliverables

* 16 new or first-run scripts under `yxctl/tests/topology/`.
* `env.sh` gaining the partition/up/down helpers and fixture parameterisation.
* `Dockerfile` + `gitsrv` image.
* `run_all.sh` split into `run_a.sh` / `run_b.sh`, since the two fixtures have
  different lifecycles.
* A results section appended to this file: what passed, what failed, and for
  each failure whether it is a defect in the feature or in the test.


---

## 7. Results

### Fixture bring-up — three defects in the harness itself

Found before a single feature test ran, and each would have made the whole run
unreadable rather than merely red.

**1. `clear_prepared` killed `env.sh` while it was being sourced.** It probes
every node for orphaned prepared transactions — and `10_up.sh` reaches it
*before it has created any container*. A command substitution's status is the
assignment's status, so under `set -e` a node that does not exist yet aborted the
sourcing **silently, with no output at all**, because nothing had been echoed
yet. Every script then reported `FAIL` with no reason. Latent since the fixture
was written and invisible while the six nodes happened to already exist; the
seventh made it fire every time. Fixed with `|| true` and a comment saying why.

**2. A TCP-attached node could not reach its own PostgreSQL.** Debian's default
`pg_hba.conf` is `host all all 127.0.0.1/32 scram-sha-256`, and the `postgres`
role has no password — so `n7`'s ytserv timed out in `bb8`, several layers from
the cause. The node entrypoint now sets loopback TCP to `trust`, **only** for a
node deliberately configured this way, rather than baking it into the image.

The first attempt put that block where `DB_URL` was defined — *after* the
"wait for config rows" loop, which can block indefinitely by design. It would
have worked, since it still precedes the ytserv launch, but a fix that only runs
once an unbounded wait completes is a fix you cannot confirm by looking. Moved
to sit directly after PostgreSQL starts, and verified in a throwaway container
rather than inferred from a passing run.

**3. One dead node stopped the other six electing.** A direct consequence of 2:
`n7` unreachable meant a cold start never completed, and the cluster sat at
`Term: 0, Leader: None!`. Worth recording because the symptom pointed at the
election and the cause was a `pg_hba` line.

**Not a defect, but worth recording:** the run was killed once by the dev box
running low on memory — an unrelated 8 GB process, not the suite, which is a
handful of `ssh` calls. Noted only so a gap in the log is not later read as a
test that hung.

### Feature results — run 1, 2026-09-24

`10_up` PASS · `05_gitsrv` PASS · **all 12 baseline scripts FAIL**

A uniform 12-of-12 failure is one cause, not twelve defects, so it was
attributed before being recorded.

#### F1 — a node whose PostgreSQL is not on a unix socket does not start at all

**The finding of the run, and it invalidates a design claim made earlier in this
work.** `main.rs:147`:

```rust
let run = x.is_single_master();   // false for a TCP url
if !run {
    error!(log, "{}", t!("err-user-action-required-d"));
    return ExitCode::from(12);     // hard exit
}
```

`is_single_master()` is false whenever `db_url` does not name this PostgreSQL's
socket directory, and that is a **hard exit**, not a degraded mode. Observed on
`n7`: connects to the database successfully, reads `public.yt_config`, fails,
exits 12 — on every restart.

The original requirement was *"non unix socket can not be Main, because can't
act as master node on postgres write. But can be a forever spare for a etcd and
rppd node."* The first half is implemented and correct — `can_be_main`, the five
election gates, the `forever_spare` row in `yt_info('E')`. **The second half is
not reachable**, because such a node never finishes starting. Everything built
for it this session is correct and currently moot.

Verdict: **defect in the feature.** `24_db_local.sh` was written to catch
exactly this and the fixture found it first.

*Not the whole story, and worth separating:* the `relation "public.yt_config"
does not exist` line that precedes the exit is misleading. `psql` on the
identical URL sees the table and 37 rows. The `no table config in database
postgres` line after it is **informational** — the loader scanning other
databases in the instance — and reads like the cause. Three log lines, none of
which name the actual reason.

#### F2 — one dead roster node blocked the cold start of the other six

`min_cluster_size` is 6 and six nodes were healthy, but the cluster sat at
`Term: 0, Leader: None!` for ninety minutes, with `n1` logging a continuous ping
failure to `n7`. Every baseline test then failed on `cluster did not settle`,
and every row assertion returned `[]` — no leader, no replication, nothing to
compare.

Verdict at the time: **not attributed**, deliberately — whether a cold start
legitimately requires every roster member needs reading the election path.

**Resolved by the F1 fix, 2026-09-24.** With `n7` running, all seven nodes
reached `Term: 1` on one leader within ninety seconds. F2 was a *consequence* of
F1, not a separate defect: the six healthy nodes were waiting on a roster member
that could never start. Leaving it unattributed rather than guessing was the
right call — the guess "cold start requires every member" would have been wrong,
and would have sent someone into the election code for nothing.

#### What this run did and did not establish

It did **not** establish a baseline: the twelve scripts never reached the
behaviour they test, so nothing about az routing, shards, reshape, recon or the
jsonb merge was measured. Their result is "not run", not "broken".

It did establish F1, which is a real defect in a claim this session had already
written into `membership.md`, and it did so before the test written to find it
existed. That is the run working as intended — and it is the eleventh entry in
the catalogue the article is built from: **the feature that was correct,
documented, and unreachable.**

### Run 2, 2026-09-24 — after the F1 fix

**The fix.** `is_single_master() -> Result<bool, _>` became
`start_mode() -> Result<StartMode, _>` with three outcomes —
`WriteMaster`, `Attached`, `SocketBusy` — and only the last refuses to run. The
socket and pid file are claimed in **both** running modes: the unix socket is
how the extension delivers trigger callbacks *and* how `yt_info` answers an
operator, and an attached node needs the second even though nothing will use the
first. Skipping it would have reproduced the very symptom being diagnosed
(`yt_info: curl error: Could not connect to server`).

An attached node now also says why at `warn` on every start, so the answer is in
its first ten log lines rather than inferred weeks later from a node that simply
never asks.

**Confirmed on the cluster:**

```
n1..n7   Term: 1, Leader: 81..1ccb70:172.18.0.3:7421
n7       WARN PostgreSQL is reached over TCP, so this node cannot be the
              write master; it serves replication, etcd and rppd
n7       yt_info answers over its local socket
10_up.sh PASS
```

`24_db_local.sh` still has to be written — this is the fixture demonstrating the
role exists, not a test asserting it — but the role is now reachable, which it
was not when this session documented it.

#### Baseline — 12 of 14 green

**Final: 13 of 14**, then **14 of 14** once the feature the last red was about
was built (see "F3 — resolved" below).

| | |
|---|---|
| **PASS** | `10_up` `05_gitsrv` `15_setup` `20_flat` `30_az` `40_tier` `50_shard` `60_write_az` `70_reshape` `80_recon` `85_alert` `88_quiescent` `95_partition` **`24_db_local`** **`96_jsonb_merge`** |
| **FAIL** | — |

Every red that was a *test* defect is fixed and re-run green. The single
remaining red was the only one that was ever about the product, and it is now
green because the product changed, not the assertion.

`24_db_local.sh` was written during this run, as the regression guard the F1 fix
did not have, and passes: `n7` runs, logs why it is ineligible, reports
`forever_spare` in `yt_info('E')` **and nowhere else**, is never elected, is
excluded from quorum, and still receives replication.

**T4 — `96_jsonb_merge` measured a coin flip, and the coin was not merge.**
Found by running the same binary twice: **24/24** alone on a fresh cluster,
**16 passed / 9 failed** in-suite after `85_alert` and `95_partition`. The
failing assertions all said "a merge dropped them" — and the nodes' logs carried
**no `[cas-miss]` at all**, only `1 subterm gap(s) - writes to synced tables
will wait and retry until they close`.

The cause is not merge and is not new: a write that is **refused still took a
subterm from the leader at checkin**, and that subterm is then never applied
anywhere. It is a permanent hole, and every node behind it waits on a record
that is not coming. Seven writers contending for one row produce several, so how
many nodes converge depends on how many writers happened to time out — which is
the coin.

Three changes, and the first two are the general lesson:

* **A missing row is not evidence of a lost write until the apply path has
  caught up.** `wal_gap` (in `yt_info('E')`'s `health.metrics`) is now a
  precondition, checked before the writes and again before the count.
* **Assert over the nodes that are caught up; report the rest.** On a node with
  no gap the statement is exact — it has received everything that was sent, so a
  committed writer's key is either there or a merge dropped it. Nodes still
  behind are printed with their gap and excluded, visibly, not silently.
* `gap_of` returns **`-1` for "has not reported yet"**, not `0`.
  `health.metrics` does not exist until the health monitor's first tick, and a
  restart is exactly when it has not ticked — so the first version read that
  absence as "caught up" and waited for nothing. Same silent-pass shape as T5
  below: an absent answer read as a good one.

**T5 — assertions that matched the message instead of the field.** `85_alert`
checked its SQLSTATE with `case $out in *55000*)`, which matched the code where
ytserv had printed it in the *message text* while the actual SQLSTATE field was
still `08006`. It reported `OK the blocked row is refused with SQLSTATE 55000,
not 08006` for a build where nothing of the sort was happening. Both that script
and `96_jsonb_merge` now parse the code positionally out of `ERROR:  <code>: `
under `VERBOSITY=verbose`. A glob over an error message cannot tell the field a
driver acts on from prose a human reads.

Two more of the same family, both in scripts that had never reached their own
assertions: a `grep -m1 '^ERROR:'` that killed the script under
`set -euo pipefail` on the **success** path — and in `85_alert`, on the one
branch that reports "the blocked row ACCEPTED a write" — and a `check` whose
expected and actual arguments were reversed, so a failure read
`expected [1] got [7]` for a node holding one key.

### Group 2 — the capabilities the product page names (2026-09-25)

Coverage was measured against dbinvent.com's own "Platform Capabilities" list
rather than against the scripts that happened to exist. Four of them had no
cluster test at all; these are the scripts for three of them, and the defects
they found.

| capability | script | verdict |
|---|---|---|
| Blocking: **row** | `85_alert` | 16/16 — already covered |
| Blocking: **table** (schema gate) | **`86_schema_block`** | **10/10 PASS** — found and fixed F4 |
| Blocking: **node** | **`87_node_block`** | **12 pass / 2 fail** — pause works, `follow` cannot reach a paused node (F9) |
| **Server Functions** (RPPD) | **`92_rppd`** | **9/9 PASS** — after three undeclared python deps |
| **etcd Interface** | **`93_etcd`** | **11/11 PASS** — five bugs; the last (F12) was the peer state machine |
| **ClickHouse sink + rppd** | **`94_clickhouse`** | **11/11 PASS** |
| **MPP: the layout** | **`97_mpp`** | **13/13 PASS** — the partition ranges tile a sharded table exactly once |
| **MPP: the DataFusion engine** | **`98_mpp_df`** | **14/14 PASS** — DF binds in a server function and computes the partials; found F11 |

**F9 — `node_run …:pause` is a one-way door.** The pause itself works: the node
reports `Paused`, only the addressed node acts, and the cluster keeps committing
without it. `follow` then never arrives, and the live-config probe says exactly
why:

```
expected [81..1ccb70:follow]  got [81..1ccb70:pause]
```

`checkin.rs` selects the party and the fan-out with `peer.state.up()`, and
`Pause` makes that false - so a paused node receives neither `modify` nor the
apply fan-out, including the config row carrying the command that would resume
it. The row does reach its TABLE later, through the history pull, but that path
does not trigger `re_config`; the live config stays at `:pause` and the grow
loop sees no change. Only a restart brings the node back.

Same shape as F8: the config reload is wired to some arrival paths and not
others. F8 fixed the party and apply paths; the history-pull path is the third.

**F4 — the schema gate could not see a drift for fifteen minutes, and recon
repaired across it meanwhile.** `SchemaGate` cached a verdict for 900s keyed to
nothing but the table name, so an `ALTER TABLE ... ADD COLUMN` on a follower was
invisible to the gate for the whole TTL — and recon, which consults the same
cache, spent it comparing rows across two different shapes and **repairing the
differences it found**. Measured on the seven-node fixture: `83 divergent, 18
repaired` from one added column, where the gate exists precisely to stop that.

Fixed by keying the cached verdict on a fingerprint of the LOCAL column list
(name, type, typmod, order). The cache still saves the expensive half — the
leader round trip — but a DDL change voids it at once. After the fix the same
run reads `0 divergent, 0 repaired`, and the gate reports within seconds with
an SG-ready fragment and the `ignore_col` suggestion.

Note the shape of it: the gate was *implemented, surfaced and correct*, and a
cache in front of it made it answer about a table that no longer existed in that
form. Nothing logged anything wrong.

**F5 — `--encode-table-cfg` accepted four fields and discarded them.**
`merge`, `cluster_commit`, `filter` and `db_source` were parsed onto the struct
and then dropped by `..CfgTabl::default()`. Two were worse than "ignored":
`document_merge` was already read by `decode()`, so opening a merge-enabled
table in the TUI and saving it unchanged **turned merge off**; `decode()`
hardcoded `cluster_commit: None`, so a table with a replication rule opened as
"unset" and saving wrote the cluster default over it. Both directions wired,
with `model.rs::table_cfg_round_trip` as the guard — a round trip being the only
shape of test that notices a field which never reached the bytes.

**F6 — server functions needed three python dependencies the deb never declared.**
Each was found by running, and each hid the next:

1. `libpython3.12-stdlib` — the deb vendors `libpython3.12.so.1.0` (Ubuntu 26.04
   dropped python 3.12 and ytserv links it through pyo3, so the node will not
   start without it) but shipped no stdlib. `Py_Initialize` died with
   `init_fs_encoding: failed to get the Python codec of the filesystem encoding`.
2. `python3-psycopg2` — how rppd binds `DB`, the handle every example uses.
3. `python3-etcd3` — how it binds `ETCD`, imported with `?` during CONNECT, so a
   missing etcd3 failed EVERY function including ones that never touch etcd.
   (The ClickHouse binding beside it is optional by design; ETCD arguably should
   be too.)

All three are now hard `Depends`, per the decision to require python 3.12
specifically rather than "a python3" - a 3.14 stdlib cannot serve a 3.12 core,
whose extension modules are named `*.cpython-312-*.so`. That made the deb
uninstallable on 26.04, so the fixture moved to **Ubuntu 24.04 + PostgreSQL 18
from PGDG**, where the dependency is satisfiable; the Dockerfile fails the build
if `/usr/lib/python3.12/encodings/__init__.py` is absent. `92_rppd` then passed
9/9: the function ran, wrote to its sink, and logged a clean execution.

ytserv also says so at startup now: `serve_rppd` on with no 3.12 stdlib logs the
cause and the package name, instead of an operator finding a fatal python error
on stdout days later with nothing pointing at the config that caused it.

**F6a — the original diagnosis, kept because the shape recurs.**
`libpython3.12.so.1.0` (9MB) is vendored into `/usr/local/lib/yaxaha/` because
Ubuntu 26.04 dropped python 3.12 from its archive — but only the `.so` is
shipped, and a shared library is not an interpreter: `Py_Initialize` needs the
stdlib, starting with `encodings`. On 26.04 there is nowhere for it to come
from; `apt-cache policy python3` offers **3.14 only**, and `python3.12` and
`libpython3.12-stdlib` do not exist as packages. So "Server Functions" — a
headline capability — cannot run from the shipped deb on the newest LTS the
cluster targets. Fix is a 42–55MB stdlib in the deb (or a per-distro build
against the target's python); it is a package-size decision, not a code one.

**F7 — the etcd surface: four bugs, one family.** `93_etcd.sh` drives a live
node with `etcd-client`, the ordinary third-party crate, because the claim is
about what a stranger's tooling sees and the crate's own tests only ever talked
to an in-process node.

| # | bug | what a client saw |
|---|---|---|
| 1 | `get_impl` ignored `range_end` | a prefix range returned `count: 0` — indistinguishable from "nothing registered" |
| 2 | `delete_impl` ignored `range_end` | a prefix delete removed nothing, reported `deleted: 0`; the peer broadcast DID forward `range_end`, so every node stayed consistently wrong |
| 3 | `create_watcher` ignored `range_end` | every prefix WATCH was silent — the watcher sat under its literal start key |
| 4 | `response_header()` hardcoded `cluster_id: 0` | `EtcdPeers::connect` refuses a peer whose id differs from its own, so **no two embedded etcds ever peered** |

1–3 are the same mistake in three places: a request carrying a range answered as
an exact key. Prefix reads and prefix watches are how service discovery works,
and how rppd registers a queue consumer (`schema_table` beginning with `/`), so
all of it read as "nothing here". 4 is the one that made the KV per-node:
with no peers `broadcast_scoped` returns early on an empty list, and anything
built on the surface sees a different world on each node. Its log line —
`wrong cluster, running on ClusterID [N], but connecting node from 0` — reads
as somebody else's misconfiguration rather than as the code always saying zero.

**How three of them stayed invisible:** `tests/testing.rs` carried
`TESTING_RANGE = false` and `TESTING_PREFIX = false`, and `client.rs` gates its
range and prefix assertions on them. The tests existed and were switched off.
Both are `true` now; the etcd suite is 43 tests and green, including two new
prefix-watch tests — one that it fires, one that a key outside the prefix does
NOT, so the fix is not "wake on everything".

**F8 — a runtime config change never reached any node's live config.**
`check_re_config` had exactly one caller, `cluster_save_inner`, on the ORIGIN
path. Applied to `node_run` that is fatal to a documented operator control: the
command must be written on the leader (a follower refuses a restricted config
write), it addresses a FOLLOWER by uuid8, the follower stored the row and kept
its old `recent_cfg`, and on restart the deliberate arm-do-not-run rule ignores
a value already in the table. So `<uuid8>:pause` could never pause anything.

Two observability gaps kept it hidden, and both are closed:

* **A node's own state was not reportable.** `yt_info('O')` gives the term and
  who the leader is — Paused, Spare, Off and Main all print the same line — and
  the state existed only inside `yt_info('E')`'s row keyed by the full uuid,
  which you would have to know in advance. `E -> state` now answers it.
* **A node's LIVE config was not readable at all.** `yt_info('D')` reports
  `SmCfg::default()`, the values compiled in; the config table reports what
  somebody wrote. Neither is what the node is using, and that gap is precisely
  where a config change that did not take effect hides. `E` now reports every
  live value that DIFFERS from its default as `cfg.<name>` — differences only,
  so "not listed" means "stock".

**F10 — a node stopped for ten seconds loses those transactions PERMANENTLY and
rejoins as a full participant.** `89_recover.sh`, written to the user's
scenario: stop the container, write while it is down, start it again.

```
n1   1:before                                  <- stopped for 10s
n2   1:before 4:during-4 5:during-5
n6   1:before 4:during-4 5:during-5
```

`0 of 2` recovered, 180s after rejoining, with `recon=repair recon_rows=1` on the
table and the table kept due throughout. The node reports `state: Good`, so
nothing in the cluster treats it as degraded.

**ROOT CAUSE (2026-09-25, after two failed fixes): "behind" is only
representable as a HOLE, never as a SHORT TAIL.**

`DataVersion::missed_vec()` walks the subterms a node HAS and returns the
numbers between them - `if p > 1 && *x > p + 1`. It finds interior gaps. A node
that was absent does not have an interior gap: its list simply ENDS earlier.
Measured, same cluster, same moment:

| node | `last` | `completed` | `missed` |
|---|---|---|---|
| `n6` stayed up | 7 | 3, 5, 6, 7 | **[4]** - a hole, reported |
| `n1` stopped 10s | 3 | 3 | **[]** - the list just ends |

So `n1` reports `wal_gap 0` and believes it is current. Every "am I behind"
signal in the system reads that as healthy: `missed_vec`, the health metric,
recon's gap count, and the admission check - which is why the node is let back
in as `Good`.

The information exists, on the LEADER: `closed_at.is_current(least_term,
least_subterm)` is exactly this comparison and drives `demote_if_adrift`. The
follower never acts on it. A fix has to compare the node's tail against the
leader's position; it cannot be derived from the node's own record, which is
what both attempts below got wrong.

**Two attempts, both reverted:**

1. `no_history_go()` gated `pull_history` on `state.up()`, false for `Spare` -
   the recovering state. Allowing Spare removed hundreds of `state is not UP`
   rejections and recovered **0 of 2**. Reverted on the owner's call.
2. The ping loop asks for history once, while `load == WalFilesLoaded`; the
   retry past that was commented out with `TODO FIXME NOW ... how many times?`.
   Answering it with "while `missed_vec()` is non-empty" recovered **0 of 3**:
   the retry never fires, because `missed_vec()` is empty for exactly this case.
   Reverted, with the finding left in the TODO so the next attempt does not
   repeat it.

**Why neither repair path closes it:**

* **recon cannot see it.** Recon walks the rows it HAS, in keyset pages, and
  compares their checksums. A row that is entirely absent is not walked, so
  recon detects divergent VALUES and never missing ROWS. The log shows it busy
  comparing `row [1]` while 4 and 5 simply do not exist locally.
* **the subterm gap is never closed.** The node knows: `[recon] 1 subterm gap(s)
  - writes to synced tables will wait and retry until they close`. Nothing
  fills it, and it is still open when the node is admitted as `Good`.

**A guard that contradicted its own purpose, fixed but NOT sufficient.**
`no_history_go()` gated `pull_history` on `state.up()`, which is false for
`Spare` - the state a recovering node is in. So the mechanism documented as
"called at startup and on node recovery" was refused exactly when needed,
logging `request for upgrade_data_logs rejected, because the state is not UP`
hundreds of times. It now allows anything trying to participate (Spare
included) and still refuses `Off`, `Pause`, `TermCollision`, `TxConflict`.

That removed the rejections - 0 afterwards, against hundreds before - **and the
node still recovered 0 of 2.** The change is defensible on its own terms and has
no measured benefit; it is consensus-adjacent and should be kept or reverted on
the owner's judgement, not on mine.

**Secondary, from the same script:** commit success with one node down is
erratic even at a majority quorum - 4 of 5 on one run, 2 of 5 on the next. At
the SUPPORTED default it is 0 of 5: `yxctl --peers` seeds
`min_cluster_size = 1 + peers`, the whole roster, so a cluster built the
documented way tolerates zero failures. For a product page that says "Nothing to
promote, so nothing to fail over", that is worth a deliberate decision.

#### Three test-side defects, all exposed by the seventh node

Recorded separately from feature results because they are defects in the
*harness*, and two of them were introduced by this session's own changes.

**T1 — `15_setup` counted triggers, not nodes.** Summed every non-internal
trigger on `yt_config` against a hardcoded `6`. P6b's `yt_join_gate` is a
second, legitimate trigger, so a 7-node cluster reported 14 and failed a
precondition that was satisfied. Now counts nodes carrying the *sync* trigger,
against `${#NODES[@]}`. The same miscount lived in `10_up.sh`, which is what the
`WARN: n6 has 2 trigger(s)` line had been telling us.

**T2 — `85_alert` could not produce a tie.** It split a row with a literal
`n4 n5 n6`, which on seven nodes is 3-vs-**4**. Recon found a majority and
**correctly repaired** the row, and the test reported a failure for a cluster
that had just done the right thing:

```
row [3] repaired from 05..0c59d3 (2 distinct value(s) across 7 node(s))
```

The split is now computed from `NODES`; an odd cluster cannot tie, so one node
is left out of the vote *and* removed from the row, or it breaks the tie from
outside. Passes 14/14, and `05..0c59d3` is `n7` — the forever-Spare supplied the
winning value, which is a third independent confirmation that it is a full
member.

**T3 — `96_jsonb_merge` could never have passed.** `wait_writable` inserts a
hardcoded `'probe'`, valid for `text` and **not valid for `jsonb`**. `jm_t` is
`(id int, doc jsonb)`, so all 24 attempts died on
`invalid input syntax for type json` and the test never reached an assertion.
This is why it was recorded as *"written but never run"* — it had been written,
committed, and was structurally incapable of running. The probe default is now
`{}`, legal for `text`, `json` and `jsonb` alike; a fifth argument overrides it.

The first failure of 96 looked like a settling problem — `1 subterm gap`, two
peers pinging out in the window. Declining to attribute it was right: that
reading was wrong, exactly as the F2 guess would have been.

#### F3 — concurrent disjoint jsonb patches are lost, and the nodes diverge

**The most significant feature finding of the run**, and it only became visible
once T3 was fixed.

The primitive is sound — `yt_diff_apply` / `yt_diff_encode` are commutative and
create absent keys, all three checks pass. The **cluster path** is not:

```
7 nodes patching one row at the same instant...
FAIL n1 sees all 7 node keys — expected [2] got [7]
FAIL n3 sees all 7 node keys — expected [3] got [7]
FAIL n1 and n2 hold the identical merged document — 16c0edd6… vs 77728a0c…
FAIL n1 and n3 hold the identical merged document — 16c0edd6… vs 7f60ff23…
```

Each node kept two or three of the seven patches, and the cluster settled into
**three different documents**. This is precisely the failure the script's own
header describes: a replicated row image carries the whole row, so without a
merge a later apply silently overwrites an earlier one — no error, no conflict,
no log line, one node's write simply gone.

**Cause — and this corrects a first, wrong attribution.** I initially read this
as the known *"hot small tables diverge under concurrency"* and pointed at the
serialized `process_call` consumer. That is not what is happening. The
per-table merge is **not implemented at all**:

`CfgTabl.merge` (`ClusterCommitMerge`, `cluster.proto:155`) is read in exactly
one place in ytserv — `usd_proxy.rs:277` — and only to *print* it in
`yt_info('a:<table>')`. Nothing on the apply path reads it. The field is
declared, surfaced to operators, and never acted on: the same shape as
`Queue::dispatcher` (never written) and `ConfigModule::Keys` (never read).

So replication carries whole row images and the last writer wins, exactly as
`96_jsonb_merge.sh`'s own header says it would. There is no concurrency bug to
find; there is a feature that was specified and not built.

Verdict: **not implemented**, which is a different and more useful answer than
"broken". Design written up in `ytserv/merge.md`; not built at the time, because
it turned on two semantic decisions that were not mine to take (§5 there).

**F3 — resolved (2026-09-24, later the same day).** Both §5 decisions were taken
by the user — overlapping paths are REJECTED, and with `55409` (class 55, do not
retry) rather than `40409` (class 40, which instructs every driver in the stack
to do the one thing that cannot converge) — and the feature was then built:
per-path patch and per-path precondition, `ytserv/src/ycluster/merge.rs`.
`96_jsonb_merge.sh` is rewritten around the new semantics and passes **25/25**.

The rewrite's own lesson is T4 below: the merge guarantee is now proven with no
race at all. One node's copy is diverged out of band, one ordinary write patches
a *different* path, and that node must end up holding both — the patch composing
with a value its origin never saw. Under the whole-column CAS that write matched
zero rows there and was dropped, silently. The concurrent seven-way write stays,
because it is the shape the bug was found in, but its outcome is now printed
rather than graded.

Two further defects of the "declared, surfaced, never acted on" kind turned up
while building it, and both were found by running rather than reading:

* **A peer's `55409` was logged as a `WARN` and dropped**, because that peer was
  an *optional* party member. The write committed, the refusing node stayed
  diverged, and the client was told `no response from any nodes`. Availability
  and verdict are different things; `types::is_verdict` now makes any
  SQLSTATE-carrying peer error fatal regardless of `must`.
* **`AppError`'s `Display` buried the SQLSTATE** behind its variant name, so
  `55000: recon…` reached the client as `08006` with the real code sitting in
  the message *text* — where the `85_alert` assertion's `*55000*` glob happily
  matched it and reported a pass. Codes are now hoisted to position 0 and read
  positionally from `ERROR:  <code>: `.

**And the mechanism is not what either of us assumed.** It is not last-write-wins.
`ycluster/core.rs:1026` builds `update t set <new_data> where <pk> and
<old_data>` — a **compare-and-set on the whole column**, using the `old_data`
the trigger sends. Two nodes patching disjoint keys of one document both carry
`old = {}`; the second to land matches **zero rows**, and `core.rs:334` says so:

```
[cas-miss] modify <key> matched 0 rows on <table> - this node's row
           differs from the origin's, it needs an audit
```

The transaction still commits by design — rolling back a cluster 2PC over one
row would take the other statements with it — so the patch is dropped, a counter
increments, and nothing fails.

That is better than "silently overwrites" and worse than it looks. Better,
because a node never accepts a write built on a state it does not hold. Worse,
because for a *document* column the precondition is far too coarse: two edits
touching nothing in common still fail it, and which of the seven survives
depends on arrival order. Hence three distinct documents across seven nodes.

**The consumer is affected more directly than it looks.** `sg.rs::sg_report`
merges with `yt_diff_apply` *inside the UPDATE statement*, which makes the write
atomic **on the node running it** — and the resulting row then replicates as a
whole image. Two nodes reporting concurrently therefore still lose one report.
The design comment at `sg.rs:430` claims commutativity for disjoint paths; that
holds for the primitive and does **not** hold across the cluster today.

**It has a consumer.** `sg_history.result` accumulates one key per node through
`yt_diff_apply` precisely so that concurrent per-node reports merge rather than
overwrite (`sg.rs::sg_report`). On this evidence that merge loses reports under
concurrency, which makes `27_sg_history.sh`'s "one key per node" assertion the
next thing to run, not a formality.

---

### MPP Analytics (2026-09-25) — the layout, then the engine

The user split this in two: "1. ClickHouse cluster query: check ch is up and
operational - mostly smoke test of rppd+ch. 2. Real mpp: shard data and build a
cluster. Run analytics function in parallel. This not for testing how function
works, but smoke test a df. Also from rppd is ok."

Phase 1 is `94_clickhouse.sh`, **11/11**. Phase 2 is two scripts, because the
data surface and the engine link fail for entirely different reasons.

#### `97_mpp.sh` — the layout tiles the table exactly once (13/13 PASS)

`public.mp_t` sharded `shard=owner; outer=pin; recon=report`, 2000 rows, seven
nodes. `yt_info('P')` reports every node as holding it, `complete:true`, and the
shard column; `yt_info('p:public.mp_t/4')` returns a plan
(`partitions:4, rows:2000, key:id, sharded:true`) with four ranges:

```
[0] id < 501            [1] id >= 501 and id < 1001
[2] id >= 1001 and id < 1501   [3] id >= 1501
```

Run as four concurrent partial `SUM(amount)` queries: `125250 + 375250 + 625250
+ 875250 = 2001000`, identical to the whole-table aggregate. That is the
assertion worth having — overlapping ranges over-count and a gap under-counts,
both silently, so comparing the combined partials against the whole is the only
thing that proves a tiling.

#### `98_mpp_df.sh` — DataFusion is reachable after all

The earlier note in `97_mpp.sh` said an end-to-end DataFusion query "needs a
running Ballista scheduler and a PyPI package, neither of which exists here".
Both turned out to be available: `ballista` 54.1.0 is on PyPI, it exposes the
`BallistaSessionContext` that rppd imports (`py.rs` `DATAFUSION_PY`), **and** it
ships `BallistaScheduler`/`BallistaExecutor`, so the scheduler runs inside the
node container on `127.0.0.1:50050` — no new service, no image change, nothing
crossing the docker network since rppd dials it from the same container.

Measured, in order: `datafusion_url` reaches the running node
(`yt_info('E') -> cfg.datafusion_url`), rppd binds `DF`, and a server function
gets a live session — `df_bound = yes`, `df_probe = 42` **from inside the
function**. So the `[df]` link works end to end; what limits it is not ytserv.

**The real constraint on the engine half: a Ballista query cannot read an
in-memory table.** `ctx.from_pydict(...)` registers one, and Ballista must
serialise the logical plan to hand it to an executor:

```
Exception: DataFusion error: Error serializing custom table
caused by: This feature is not implemented: LogicalExtensionCodec is not provided
```

A distributed engine needs a source its executors can resolve for themselves, so
the partition has to be materialised where they can see it. The function
therefore `COPY`s each range to a CSV (`copy_expert`, client-side, so no server
file privilege) and `register_csv`s it. That is not a quirk of the python
binding — it is what "MPP over a Postgres cluster" actually requires, and it is
worth stating on the product page: the placement catalog says where the rows
are, but something still has to put them where an executor can read them.

With that, the four partials run in parallel **through the Ballista scheduler**
and come back `[125250, 375250, 625250, 875250]` = `2001000` — the same four
numbers PostgreSQL produced in `97_mpp.sh`, computed by DataFusion instead.

#### F11 — a server function body cannot use a helper function

rppd execs the body as `py.run(code, None, Some(&locals))` (`py.rs:244`):
globals is None, locals is a separate dict. Every top-level assignment in a
function body lands in locals, and a nested `def` or `lambda` resolves its free
names through **globals** — so it never sees anything the body assigned.

```python
exec("x = 5\ndef f(): return x\nf()", globals_dict, locals_dict)
# NameError: name 'x' is not defined
```

This is silent in the worst way. A one-line `def put(stage, value)` wrapper
around a sink INSERT raised `NameError` on its first call; the `except` handler
called the same wrapper and raised again; `rppd_function_log` recorded the
function as having run with **no output and no error**, and the sink was empty.
Comprehensions are safe on python 3.12 (they are inlined), so the trap is
specifically `def`/`lambda`. The working forms are straight-line code, or
binding what a callable needs as **default arguments** (`def f(n, ctx=ctx):`),
which are evaluated at def time in the body's own frame.

Worth documenting for anyone writing server functions, and arguably worth
fixing: passing the same dict as globals and locals would make the surface
behave like ordinary python. Note this is a constraint on *authoring*, not a
defect that broke a shipped feature — but the silence is a real reporting gap.

#### Harness traps this phase produced, all of the same family

Each of these produced a green or a silent death that measured nothing:

- **`wait_writable` on a sharded table.** It probes by INSERTing a row; with
  `shard=owner; outer=pin` a probe row whose owner routes to no node is refused,
  correctly — and the script reported "cluster never became writable" about a
  perfectly healthy cluster. A test that never writes to the table through the
  cluster should assert the config **loaded** (`yt_info('a:<table>') -> raw`)
  instead.
- **`rh` is `ssh $YX_HOST`.** Writing a file locally and `docker cp`-ing it in
  the next `rh` call cannot work; the missing file killed the script under
  `set -e` with nothing printed. Stage through base64 in the remote command.
- **`pgrep -f /tmp/dfd.py` matches its own `sh -c`**, whose command line
  contains that path — so the guard always found a running daemon and never
  started one. (The same self-match then bit a `pkill -f` typed at this session's
  own shell, which killed the shell issuing it.)
- **`grep -q "executor started" /tmp/dfd.log` survives a container restart**, so
  after `restart_all` it reported a dead daemon as alive. Probe the **port**.
- **Anything started before `restart_all` is gone after it** — `restart_all`
  restarts containers. The scheduler now starts after `await_cluster`; rppd
  rebuilds its python context per dispatch (`TIMEOUT_MS = 1000`, `is_alive()`),
  so a scheduler that comes up after ytserv is still picked up.
- **`check "" ""` passes.** When the function died early, the payoff assertion
  compared two absent values and reported PASS. An equality test over two empty
  strings is the easiest green in testing and measures nothing; the aggregate
  comparison now refuses to run unless both sides are present.
- **psycopg2 parses json columns.** `json.loads(cur.fetchone()[0])` on a
  `yt_info()` result raises `TypeError: the JSON object must be str, bytes or
  bytearray, not list` — it is already a list.

---

### F12 — cross-node etcd KV: the peer state machine had no way in (2026-09-25)

`93_etcd.sh`'s one remaining failure — "n1 does not see n3's key" — survived four
earlier fixes (`cluster_id: 0` in `response_header`, `parse_uuid("")` inventing a
per-node cluster, no connect retry, `range_end` ignored in three places). This is
the actual cause, and it is the same shape as every other finding this session.

**The peer list was right all along.** The node logs show it:

```
ERRO [etcd] connecting endpoint http://172.18.0.3:7421 with error transport error
```

Correct field, correct scheme, correct port — those connects fail only because
the whole fixture starts at once and nobody is listening yet, which is exactly
what `spawn_peer_retry` exists for. The retry then succeeded and logged at
`info!`, invisible at `log_level=warning`, so it looked like nothing happened.

**What actually broke: `add_connections` pushes every verified peer as
`PeerState::Spare`, and `broadcast_scoped` builds `send_indices` from `Online` +
`InProgress` only.** The only caller of `promote_to_syncing` / `promote_to_online`
in the entire crate is `member_promote` — the etcd **admin gRPC API**, which
ytserv never calls and no client in this division calls either. So:

1. every node connects to every other node, and the cluster looks healthy;
2. `send_indices` is empty, so `broadcast_scoped` returns `Ok(())` immediately;
3. every `put` succeeds, locally;
4. nothing is logged, at any level, ever.

A capability wired to one arrival path — here, an operator-driven admin call —
and not to the one that actually runs. Exactly F8/F9's shape.

**Fix, in `../etcd/src/peer.rs`.** A peer reaches the push only after answering
`status` with a matching cluster id, so it is a *verified member of this
cluster*; it enters as `InProgress`, the state that already means "receives
writes, does not yet gate the commit" (`quorum_total` counts only `Online`, and
`quorum_total == 0` returns `Ok(())`, so an unproven peer cannot stall a write).
The first successful replication then promotes it to `Online` — the mirror of the
`demote_to_spare`-on-timeout that was already there and was the only half of the
cycle wired up.

**Regression test: `cluster.rs::peering_tests`, three cases, in-process.** One
node serves on a free port, the other is pointed at it, and they peer during
`init`:

| | asserts |
|---|---|
| `a_connected_peer_is_not_left_in_a_state_nothing_sends_to` | the state is not `Spare` |
| `a_key_written_on_one_node_reaches_the_other` | the put crosses — the same thing `93_etcd` asserts across containers |
| `replicating_successfully_promotes_the_peer_to_online` | the peer reaches `Online` |

**All three fail on the unfixed code and pass on the fixed code** — verified by
reverting the two changes and re-running, because a test that passes either way
is the trap this plan has hit repeatedly. Crate total 37 → 40 passing.

Two diagnostics came out of it, both because the failure was invisible:

- `spawn_peer_retry`'s `urls.is_empty()` branch used to `continue` silently. It
  now warns (once, then every 10 min) and prints both fields `peers()` derives
  from, since a peer list in the wrong field or without an `http://` scheme
  silently becomes no peers at all.
- The in-process test uses a printing `slog::Drain`, not `Discard`:
  `add_connections` reports every refusal through `error!` and returns `Ok(0)`,
  so a discarding logger turns a fully diagnosable failure into an unexplained
  zero. That cost one debugging round on the test itself.

**Verified 2026-09-25 on a rebuilt image: `93_etcd.sh` is 11/11 PASS**, including
the assertion that had failed every run this session —

```
OK   n1 sees the key n4 wrote - the kv propagates across the cluster
```

So the etcd Interface capability is now cluster-wide, not per-node.

---

### F13 — a reshape's progress is not durable, and one unreachable target stalls it forever

Found by the full-suite run of 2026-09-25 (`70_reshape.sh`, **8 pass / 1 fail**).
It had passed 9/0 on 09-24, so it read as a regression; it is not one — it is a
pre-existing defect that the 7-node fixture and a longer run finally exposed.

**Every data assertion passed.** West caught up to all 40 rows, east kept every
row, top held none, east and west agreed exactly by digest, and Copy logged 15
non-zero backfill lines. Only the flip never happened.

**What the leader logged, on a 5s tick, verdict-on-change:**

```
22:25:21  compare failed: ... 172.18.0.8:7421 Connection refused
22:25:26  frame counts differ (16 here, 0 there) - still filling
22:25:31  05dc610d matched (16 frame(s) agree, 40 row(s))
22:25:36  171a2142 matched (16 frame(s) agree, 40 row(s))
22:25:41  4ef9d487 matched (16 frame(s) agree, 40 row(s))
22:25:46  a target node is unreachable          <- and stays here for 7 minutes
22:32:43  05dc610d matched (16 frame(s) agree, 40 row(s))   <- the SAME node, again
22:32:53  171a2142 matched ...
22:33:03  4ef9d487 matched ...
22:33:08  a target node is unreachable
```

Two distinct problems, and the second is the one that matters:

**1. One unreachable target blocks the flip indefinitely.** `reshape_flip` runs
only when `incoming` is empty, and a node that cannot be reached never matches,
so the move waits with no timeout, no abort, and no way to drop a target.
172.18.0.8 is `n7` — the TCP-attached forever-Spare node — and it was
unreachable for ~7 minutes, which covers the test's whole 180s wait. Note that
targeting a Spare node is *not* obviously wrong: a Spare still stores replicated
rows, it just cannot be elected Main. The defect is the absence of a deadline,
not the membership.

**2. The matched set is in-memory only, so a restart discards the progress.**
`self.reshape.matched()` removes a node from `incoming`, but that set lives in
`self.reshape`, not in the config table. `reshape_run` meanwhile stays set —
deliberately, so `reshape_monitor` can "resume an unfinished move" — so after any
node restart the leader begins the move again from scratch and the three nodes
that already matched have to match again. Across the 90-minute suite run the
cluster re-announced this same move on every restart (`reshape started:
yxtopo.public.rs_t -> 5 node(s)` at 22:32, 22:35, 22:38, 22:41, 22:44, 22:50,
22:52, 23:13, 23:16, 23:19, 23:21, 23:27, 23:30 on every node) and re-compared
the same three nodes each time. A move that cannot finish is therefore not
merely stuck: it is permanently re-executed work with an unbounded lifetime.

The fix is a design decision, not a one-liner, so it is recorded rather than
applied: it needs either a deadline on the move (abort and clear `reshape_run`,
with the reason), or durable per-node match state (a module-`C` row per matched
uuid) so a resume continues instead of restarting — probably both.

`70_reshape.sh`'s wait loop is not at fault: it already waits 180s for *both* the
row count and the COMPLETE line, with a comment explaining that earlier runs
"simply won" the race. This run lost it for a real reason.

---

### F14 — the reshape flip deadlocks on the comparing node's OWN uuid

This is the actual cause of `70_reshape.sh`'s failure. F13 above described the
symptom and the durability problem around it; this is the mechanism, and it is
deterministic, not a race and not an environment flake. **Reproduced standalone
on a freshly built cluster with no other script running.**

**The two lines that do it.** `reshape_begin` puts this node into the target set:

```rust
if self.az_role(&tk).await.holds { incoming.insert(self.sm.read().await.uuid.as_uuid()); }
```

with a comment explaining why — `shard_holds` asks `incoming.contains(me)` to
decide whether to store rows it does not own yet, and without this the one node
that most needs to hold the incoming rows cannot tell it is a target. That
reasoning is sound. But the comparison round then resolves each target through
`peer_by_uuid`, which iterates `self.peers` — a collection that never contains
this node:

```rust
let uuid = match mv.incoming.iter().next() { ... };      // ONE target per round
let verdict = match self.peer_by_uuid(&uuid).await {
    None => "a target node is unreachable".to_string(),
```

So the round that picks the self uuid resolves to `None`, reports
**"a target node is unreachable"**, and marks nothing matched.

**And it is a deadlock, not a slow round.** The target is chosen as
`incoming.iter().next()`. Once that lands on an unresolvable member it lands on
the same member every tick, the remaining members are never compared, `incoming`
never empties, and `reshape_flip` — which runs only on an empty set — never runs.

**Measured twice, and the second run says it outright.** With the diagnostic in
place, the stuck node names itself:

```
n3   target bdc228b6 is THIS node
```

`bdc228b6` is n3's own uuid8. Note it is **not** the leader — n3 is `east`, the
current owner, and the leader that run was a different node. So this is not a
leader-only fault: ANY node that runs the comparison round while being itself in
the destination scope deadlocks on itself. `70_reshape.sh` stayed at 8 pass /
1 fail, exactly as predicted.

The first run showed the same shape before the message was fixed: n4 was leader
with uuid `9b3a914c-52c0-5cf0-a1c5-228eb9f2b0ec`, the backfill went to four
*peers* (`05dc610d`, `171a2142`, `4ef9d487`, `bdc228b6`), so `incoming` was those
four plus the comparing node itself — exactly the "-> 5 node(s)" in the log.
Three peers matched, and then:

```
23:54:17  171a2142 matched (16 frame(s) agree, 40 row(s))
23:54:22  4ef9d487 matched (16 frame(s) agree, 40 row(s))
23:54:27  a target node is unreachable        <- and never anything else
```

while `rs_t` held all 40 rows on n3, n4, n5 and n6, n7 had the table, and
`n7:7421` answered a TCP connect from n4. **The "unreachable" node was up,
holding the data, and answering on its own port** — it was the reporting node
itself. That message is what sent this session to check the network of a healthy
cluster, twice.

**What was changed: the message only.** It now names the uuid and says when the
target is this node, pointing at this entry. The behavioural fix is *not* applied,
because the obvious version is unsound: self is in `incoming` precisely when the
new rule routes the table here, which includes the case where this node is a NEW
target that has not finished filling — so marking self "matched" without
comparing would hand ownership over mid-fill. Doing it properly means comparing
self against the reference through the LOCAL path (`recon_bounds` / `recon_frames`,
which already exist beside the remote ones), and deciding what the reference is
when the candidate and the reference are the same node — the `reshape_reference`
self-reference question that F-earlier already flagged as "table is empty" and
fixed once with a four-state `Reference`.

That is an ownership-transfer decision, so it is the owner's call, not a guess
made inside a test run. Two changes, both small, once that call is made:

1. compare a self target through the local frame path instead of `peer_by_uuid`;
2. make the round skip to the next resolvable member instead of taking
   `incoming.iter().next()` unconditionally — a single stuck member currently
   starves every other member's comparison, which is a bug independent of (1).

Until then `70_reshape.sh` is expected to fail its last assertion on any fixture
where the leader is inside the destination scope, with all eight data assertions
green: the rows move correctly, only ownership never transfers.
