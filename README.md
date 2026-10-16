# YaXAHA Cluster Integration Tests

We run our tests on Debian-based Linux distributions and can’t give any promises about the compatibility with many other versions and distros, except for those we use ourselves in development now. Last tests were made on Ubuntu 22.10 and Debian 11.

YaXAHA Cluster is written in Rust and out of habit we use cargo-make in the integration tests.

## Other tests and reports

Besides the cargo-make integration tests below, this repository holds these
tests, each with its write-up:

| | |
|---|---|
| [llm/](llm/README.md) | `yt_llm`: questions in plain language, answered by PostgreSQL, DataFusion or ClickHouse, on a docker cluster of three yaxaha and three ClickHouse nodes. The article: [llm/report.md](llm/report.md); the run: [llm/results.md](llm/results.md) |
| [rmc/](rmc/README.md) | resilience and membership under change: three linked clusters (one above two) keep every acknowledged write and their boundaries while nodes are added at runtime on every level, leadership moves, nodes restart, and a whole cluster is replaced one node at a time. The plan: [rmc/plan.md](rmc/plan.md); the run: [rmc/results.md](rmc/results.md) |
| [cluster-test1.md](cluster-test1.md) | where the time goes in a 3-node cluster, against PostgreSQL's own synchronous replication; harness [cluster-test1-matrix.sh](cluster-test1-matrix.sh) |
| [cluster-test2.md](cluster-test2.md) | HPC: subterm leases against the per-statement checkin round trip |
| [cluster-test3.md](cluster-test3.md) | the leader forced onto the node that originates the writes; harness [cluster-test3-matrix.sh](cluster-test3-matrix.sh) |
| [pgbench_single.md](pgbench_single.md) | one plain PostgreSQL per host: TPS per CPU TFLOPS |
| [BENCH.md](BENCH.md) | the plan for pgbench on one PostgreSQL against a cluster, not yet run; its tools are in [bench/](bench/), the multi-host driver in [bench/cluster/](bench/cluster/README.md) |
| [pipeline/](pipeline/README.md) | the on-commit chain pgbench → Python → etcd queue → Python → ClickHouse, and an etcd queue written straight into ClickHouse |
| [topology/](topology/README.md) | one cluster of seven nodes in docker (fixture A, `run_all.sh`): az, tier, shard, write zones, reshape, recon, alerts, blocking, recovery, partitions, rppd server functions, the etcd API, the ClickHouse sink, MPP and DataFusion, jsonb merge, SKV join, the commit path, concurrency, network splits, peer streaming. The plan: [topology/PLAN.md](topology/PLAN.md) |
| [hier/](hier/run_all.sh) | three linked clusters on one network: relations, quorum, dialling, tables across the boundary, neighbours, failover |
| [lxc/](lxc/README.md) | the package in a disposable LXC container: install, `yxctl --batch`, purge and reinstall, the failure cases of each |
| [topo/](topo/README.md) | the runtime topology jobs on the rmc layout: the job layer, az create/delete, moves with purge, approval from above and locks, split/combine, faults, refusals, membership |
| [llm/lab/](llm/lab/test-yt-llm.sh) | `yt_llm` and the models against a live cluster (`YT_LLM_NODES`), not docker - run by hand |
| [nightly/](nightly/nightly.sh) | every suite above but llm/lab, each night a watched repository changed; publishes the deb and the EL9 rpm when all pass. Results: [nightly/results.yaml](nightly/results.yaml); code coverage: [nightly/coverage.yaml](nightly/coverage.yaml) |

All of them build from a yt-pgxt checkout next to this one (`YT_PGXT` to point
elsewhere) and read their settings from `.env` (see [env.example](env.example));
rmc/ and llm/ keep their own `.env`.

## Nightly

`nightly/nightly.sh`, from cron at 05:00 UTC on the build host:

1. fingerprints the `.rs` files of every watched repository (yt-pgxt and the
   local repositories its build uses - rppd, rdbm, diff-doc-rs - plus etcd,
   yaxaha_dist, infra_apt; never this one), committed or not, and stops when no
   `.rs` file changed since the last tested run - then nothing is built, nothing
   appended to results.yaml, no package made;
2. bumps the deb's patch version when it is already published (and ytserv's, when
   ytserv changed since its version was published);
3. builds the extension for every PostgreSQL major and the PostgreSQL 18 package,
   and runs unit, topology, hier, lxc, llm, topo (t0-t4, t6), topo faults (t5),
   topo membership (t7) and rmc;
4. when every suite passed - a test of a known gap fails until the gap is fixed,
   so it blocks too - builds the release (every glibc target, EL9) and publishes
   the deb to the apt repository and the rpm to its `yum/el9`;
5. appends the run to `nightly/results.yaml`, oldest first, for a page to read in
   reverse.

`nightly.sh --dry-run` says what a run would do; `--force` runs with nothing
changed; `--no-publish` tests only.

### Coverage

A run that finds `nightly/coverage.yaml` missing - or written by a run of fewer
suites - also measures code coverage: the lines of yt-pgxt's Rust workspace that
the unit tests and every end-to-end suite ran. Rename or delete the file and the
next night measures again - with no `.rs`
change it runs for that alone, and publishes nothing. `--coverage` measures in the
run started by hand. [nightly/coverage.sh](nightly/coverage.sh) does the work:

- an instrumented ytserv and yxctl (yt-pgxt's own crates only) in a second
  package, which every suite installs instead of the plain one - topology, hier,
  llm, rmc and topo mount a docker volume per suite where the processes write their
  counts, every 5 s so a killed node keeps them; lxc pushes the instrumented
  binaries and copies the counts out before deleting its container;
- the unit tests under `cargo llvm-cov`;
- the report: `nightly/coverage.yaml` (total, per crate, per suite) and a
  `coverage:` percent in the run's results.yaml entry; per-file tables and HTML in
  the run's logs. ytserv's figure goes on the badge (`nightly/badge.py`, served as
  https://apt.dbinvent.com/paks/nightly/badge.svg), which dbinvent.com shows.

Needs `cargo-llvm-cov` and `rustup component add llvm-tools-preview` on the build host.

## Preparations

This instruction assumes that you have _sudo_ command installed and there is a sudo user in your system. If you have a fresh system installed, no sudo command, or no sudo user in the system, additional steps will be required.

Make sure the _sudo_ command is installed. Under _root_ user, run:

```shell
apt install -y sudo
```

Then create a new user and add it to the sudo group.

```shell
adduser username
adduser username sudo
```

After the log-in with the user created, you can copy-and-paste commands from the next steps and everything should go nice and smooth. To log in with the user created, please run:

```shell
su - username
```

Before you can start YaXAHA Cluster Integration Tests, you'll need to install [PostgreSQL](https://www.postgresql.org/download/linux/debian/) server with psql frontend, Rust, cargo-make tool with several dependencies and a few utilities we have adopted in the test scripts. Please run the following command:

```shell
sudo apt update && sudo apt install -y build-essential curl git uuid lsb-release postgresql
```

Now we can install Rust. To save time, we took the instructions from https://rustup.rs for supported Linux distributions. Run the following command:

```shell
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

![Installing Cargo](https://github.com/DBinvent/yaxaha/blob/main/images/cargo-installation.jpg?raw=true)

Before Rust will be installed, the script will ask you to specify the settings. Default settings should be OK, you can press ```Enter``` here.

![Configuring the current shell](https://github.com/DBinvent/yaxaha/blob/main/images/configure-shell-for-cargo.jpg?raw=true)

After Rust is installed, we need to configure current shell:

```shell
source "$HOME/.cargo/env"
```

In our last preparation step we need to install the _cargo-make_ tool that we heavily use in testing.

```shell
cargo install cargo-make
```

Now, everything is ready for the YaXAHA Cluster installation and running the integration tests.

## Installing YaXAHA Cluster

Please download and install the public signing key:

```shell
wget -O - https://www.dbinvent.com/dist/DBinventLLC.gpg.key | sudo apt-key add -
```

Add our repository to your sources.list:

```shell
echo "deb http://apt.dbinvent.com/ yaxaha restricted" > sudo /etc/apt/sources.list.d/dbinvent.list
```

Install the YaXAHA Cluster package:

```shell
sudo apt update && sudo apt install yaxaha
```

The package is dual-licensed: see [License](#license).

Then run ytsetup to install the PostgreSQL extension and finally enable YaXAHA Cluster.

```shell
sudo ytsetup
```

And now we are ready to perform the YaXAHA Cluster integration tests.

## Running the tests

Clone the repository:

```shell
git clone https://github.com/DBinvent/yaxaha.git
```

Then cd into the yaxaha directory.

```shell
cd yaxaha
```

Now you can run an integration test that will locally create three copies of PostgreSQL, run them on different ports as if they were three independent cluster nodes, then run some tests and shut down all nodes.

> Note: the `PG_VER` parameter specifies the PostgreSQL version installed. Different Linux distributions have different PostgreSQL versions onboard, for example, Debian 11 comes with PostgreSQL v.13, while Ubuntu 22.10 comes with v.14.

To run several nodes in parallel:

```shell
cargo make --env PG_VER=14 --env CNT=3
```

To run an individual node with ID=$NODE_ID and psql:
```shell
cargo make --makefile node.toml --env NID=$NODE_ID --env psql=1
```

To run a single node with ID=1 and psql:
```shell
cargo make --makefile node.toml --env NID=1 --env psql=1 --env CNT=1 --env INIT=it_init_single.sql
```

### The database is rebuilt every run

Nothing here keeps a database between runs, on purpose — a test that starts
from whatever the last run left behind is a test whose result depends on the
last run. There is no volume to mount and nothing to clean up: every node is
created from nothing each time, and the schema is created by SQL that runs
as part of starting the node.

Each node gets its own PostgreSQL data directory under `cluster/nodeN`,
created by `initdb` on first use and reused as-is afterwards. `cluster/` is
git-ignored. To start completely fresh — a different `PG_VER`, or a data
directory left in a bad state — delete it:

```shell
rm -rf cluster/
```

The schema is not in the data directory's lineage at all; it is three SQL
scripts, run in this order:

| script | what it creates |
|---|---|
| `it_init.sql` | the `public.yt_config` table, the cluster roster and settings rows in it, the `yt` schema, and `CREATE EXTENSION yaxaha` |
| `it_prepare_test.sql` | the `yt_config_test_trigger` on `yt_config`, which calls `yt_synchronize()` on every insert, update and delete — this is what puts a row on the wire |
| `it_test.sql` | a sample transaction, for running by hand. The automated cases in `testcases/` do their own inserts instead |

`it_init.sql` is run for you by `node.toml`'s `yt` task before the YT server
starts, so `cargo make` needs no separate setup step. Override which one
with `--env INIT=`; `it_init_single.sql` is the same thing with a one-node
roster, for `--env CNT=1`.

Two rows in `it_init.sql` are worth knowing about before you change
anything:

- the `'N'` rows are the **roster** — one per node, naming every node the
  cluster should expect. They are the same on every node, and a node missing
  from them is a node nobody talks to.
- the `'C'` rows are settings: `log_level`, `verbose`, `ping_tick_sleep_ms`
  and so on. Turning up the logging for a debugging session means editing
  this file, and it takes effect on the next run because the database is
  rebuilt.

### Running manually

You can also play around with the tests, make changes to the scripts, and run the tests manually. For example, you can change the debug level in the `it_init.sql` file.

In general, the script are executed in the following order:

1. `it_init.sql`
2. `it_prepare_test.sql`
3. `it_test.sql`

In three consoles, start a node with different `NID` by executing the following commands:

```shell
cargo make --env PG_VER=14 --makefile node.toml --env psql=1 --env YTSERV_BIN=$(./ytserv_locator.sh) --env NID=1
```
```shell
cargo make --env PG_VER=14 --makefile node.toml --env psql=1 --env YTSERV_BIN=$(./ytserv_locator.sh) --env NID=2
```
```shell
cargo make --env PG_VER=14 --makefile node.toml --env psql=1 --env YTSERV_BIN=$(./ytserv_locator.sh) --env NID=3
```

```shell
#
echo "PG_VER=14" > test.env
echo "psql=1" >> test.env
echo "YTSERV_BIN=$(./ytserv_locator.sh)" >> test.env

cargo make --makefile node.toml --env-file=test.env  --env NID=3
```

to bounce one node use this command to start: (after close psql by \q)
```shell
# for the node ID#3:
cargo make --makefile node.toml --env-file=test.env --env NID=3 --env INIT=select.sql
```


As a result, you should get the following:

- No ERROR messages when nodes have been started.
- You’ll get the node configuration listed in a table-like representation and a psql command line prompt.
- One of the consoles will display its node Leader status:
    ```
    cluster   | E  	| Term: 3, for 6sec., Leader
    ```
  
    While others will display the leader address and port:
    ```
    cluster   | E  	| Term: 3, for 6sec., Leader: 6e..65316e:127.0.0.1:28771
    ```

You can query current cluster state by running:
```
select * from json_to_recordset(yt_info('E')) as x(name text, module text, value text);
```
  
Now, you can run any SQL queries you like on one node and see how it affects the other nodes.

#### Playing with cluster

After you managed to successfully start three nodes of the cluster in the previous section, you can execute any SQL queries you like. [YaXAHA Cluster](https://dbinvent.local/cluster/) does not have a dedicated master node, so you can start on any node.

You can also execute an existed SQL script, for example, try running a simple test:

```
\i it_test.sql
```

Below is an example of a transaction. Here we will not go into details on how the cluster works, but basically every transaction in the cluster looks like this. On the transaction initiator node, simulate the following transaction:

```
begin;
insert into yt_config(name, value) values ('test0', 'test10');
select yt.yt_complete(true);
commit;
```

Now, check the result on other cluster nodes:

```
select * from yt_config where value = 'test10';
```

To stop a node, run this in the PostgreSQL command prompt:

``` 
\q
```

#### If something goes wrong

To abort tests, run:

```
cargo make killall
```

### Docker

If you have Docker installed, you can play around with tests in a container without messing up the system. In order to deploy the container with these tests, run:
```shell
./docker.sh
```

It builds the image and starts a container with this directory bind-mounted
at `/home/rust`, so the nodes' data directories land in `cluster/` on your
machine and the SQL and scripts you edit are the ones that run.

The container declares **no volume for PostgreSQL**, which is deliberate:
see "The database is rebuilt every run" above. The container is disposable,
and so is everything in it — `docker rm` leaves nothing behind but the
`cluster/` directory on your side of the mount.

The image installs the `yaxaha` package from the apt repository at build
time, so a container is only as current as the image. Rebuild it to pick up
a new package:

```shell
./docker.sh                      # rebuilds; the layers before apt are cached
APT_HOST=<host> ./docker.sh      # another apt repo; APT_HOST_IP=<address> if DNS doesn't know it
```

## License

The suites install and test the `yaxaha` deb package from apt.dbinvent.com; the
nightly also publishes it as an EL9 rpm. The package is dual-licensed:

1. **Free for noncommercial use**, under the
   [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0).
2. **A paid commercial license** from DBinvent LLC for commercial use, on the
   DBinvent Commercial License terms.

Both texts ship in the package, in `/usr/share/doc/yaxaha/`: `LICENSE` states
the dual license and holds the commercial terms, and
`PolyForm-Noncommercial-1.0.0.md` is the noncommercial license. See also
[Licensing](https://www.dbinvent.com/cluster/guide/licensing) on dbinvent.com.
