# rmc test: resilience and membership under change

Three linked yaxaha clusters on docker, one above two, take a steady write load
while their membership changes underneath it. Nodes are added at runtime on
every level, leadership is moved, nodes and leaders are restarted or lost, and
one cluster has all of its original nodes replaced, one by one. After every
step the test checks that no acknowledged transaction was lost, that the members
agree, that nothing crossed a boundary it must not cross (up, down, sideways),
and that the clusters stayed independent of each other. It measures
correctness, not speed.

- [plan.md](plan.md): what is tested, the invariants, the steps, and how the
  load is spread over every member;
- [results.md](results.md): every run, what each found, and the fixes;
- `results/run-<time>.log`: the full output of each run.

YaXaHa itself: [articles](https://vkrinitsyn.github.io/yt/),
[product page](https://www.dbinvent.com/cluster/).

## What runs where

| name | what | cluster |
|---|---|---|
| `u1`…`u5` | yaxaha nodes: PostgreSQL 18, the yaxaha extension and ytserv | upper (az `top`, tier 0) |
| `a1`…`a8` | the same | east (az `eastc`, tier 1) |
| `b1`…`b6` | the same | west (az `westc`, tier 1) |
| `load` | the three writers (`load/writer.sh`), with psql | none |

Each node is a container `rmc-<name>` on the docker network `rmc`, at a fixed
address, so a retired node's address is never handed to a new node. The clusters
start with `u1 u2 u3`, `a1 a2 a3 a4` and `b1 b2 b3 b4`; the other nodes are added
by the test. Each cluster has its own cluster uuid and its own `yt_config`,
synced among its members only. East and west see the upper cluster as UPPER and
each other as NEIGHBOR; the upper cluster sees both as LOWER and holds only a
sign-in key for each.

## Run it

Requirements, on the docker host: docker (compose is not needed), python3, and
about 2 GB of free RAM for up to 18 containers. You also need a yaxaha package
for PostgreSQL 18, built in yt-pgxt with
`cargo deb -p yxctl --variant pg18 --no-build`.

The scripts can drive a remote docker daemon (`RMC_DOCKER_HOST`), but every check
is a `docker exec`, so they run several times faster on the docker host itself.

```
cp env.example .env     # the package; the docker daemon
./build.sh              # the node image rmc-node from the package
./up.sh                 # three new clusters, eleven nodes, the writers (~3 min)
./test.sh               # the phases P1 ... P7 (about an hour)
./down.sh               # remove the containers and the network
```

`test.sh` writes `results/run-<time>.log` and exits 0 when no check failed and
no `GAP` was reported. `./test.sh P4` runs one phase; the phases build on each
other, so a later phase expects the earlier ones to have run on the same
clusters. A `GAP` line is a limitation the design documents as not built yet: it
fails the run like a failed check (since 2026-10-07 - a gap blocks the nightly
publish until it is built). Since the relay (ytserv 0.20.22) no check reports one.

## Files

| file | what |
|---|---|
| `lib.sh` | settings, the layout, docker and psql helpers, the config rows |
| `steps.sh` | the checks (I1 to I9) and the steps: add, retire, move leadership, restart, lose a leader |
| `verify.py` | judges one cluster's ledger against its writer's log (I1 to I4) |
| `load/writer.sh` | one cluster's writer |
| `node/` | the node image: Dockerfile and entrypoint |
| `build.sh`, `up.sh`, `test.sh`, `down.sh` | as above |
