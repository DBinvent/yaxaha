# Harness review — what runs today, and what should run instead

Written 2026-08-25 after building the image from this `Dockerfile` and
running `cargo make --env PG_VER=14 --env CNT=3` inside it against the
current `yaxaha` package from the local apt host. Everything under
"Findings" was observed, not read off the source — where I am guessing, it
says so.

## Status — four fixed, blocked on a fifth

Fixing findings 1 and 2 uncovered three more, each hidden behind the one
before it. Four are fixed; the fifth needs a decision (see "Questions").

| | | |
|---|---|---|
| 1 | `CREATE EXTENSION ytpgxt` → `yaxaha` | fixed, `it_init*.sql` |
| 2 | `psql_wait.sh` ran before the ytserv it waits for | fixed, `node.toml` |
| 2a | `ytserv_locator.sh` picked a binary that cannot run here | fixed, rewritten |
| 2b | ytserv's config-table argument was not being passed | fixed, `node.toml` + `node_runner.sh` |
| 2c | ytserv 0.12 requires a **UUID** node id; the harness uses `node1` | **blocked** |
| 8 | every wait was unbounded — the suite hung instead of failing | fixed, see below |

Each fix is confirmed by a real run: the extension is created, ytserv is
found, starts, and connects to its config table. It then panics on the node
id — and now **the suite says so and exits in 6 seconds** instead of
restarting it forever:

```
[IT] node1: …/ytserv-glibc2_35 exited 101 within 5s, 3 times running — not restarting again
[IT] node2: …
[IT] node3: …
```

with the same three lines in `error.msg`. Two consecutive runs, 6s each.

## The short version

**The suite does not run.** It hangs forever rather than failing, and it has
two independent reasons to. Once both are fixed, the assertions it would
then reach are vacuous — the wait loops that check replication never execute
a single iteration.

Separately, `cargo make` is being used as a process supervisor and a
distributed test runner, which is not what it is. The eight polling scripts
around it (`postgres_wait.sh`, `psql_wait.sh`, `yt_wait.sh`, `close_wait.sh`,
`node_runner.sh`, `le.sh`, and the two `ps | grep node | kill` loops) exist
to paper over that, and all of them go away under the container-per-node
model described at the bottom — which is also the shape the package already
deploys.

## Findings

### 1. `it_init.sql` creates an extension that no longer exists — the run hangs

```
psql:it_init.sql:28: ERROR: could not open extension control file
  "/usr/share/postgresql/14/extension/ytpgxt.control": No such file
```

The shipped extension is `yaxaha` 0.5:

```
$ psql -c "select name, default_version from pg_available_extensions where name like '%y%'"
 yaxaha | 0.5
```

`docker_post_bootstrap.sh` already says `create extension yaxaha`, so the
rename landed everywhere except here. `HEAD` is "fixed renaming and tests";
this file was missed.

**The failure mode is the serious part.** The `yt` task in `node.toml` runs

```sh
psql -p $port -h $wd -f ${INIT} -v ON_ERROR_STOP=on
./psql_wait.sh $port $wd $NID
```

with no `set -e`, so psql's non-zero exit is discarded and `psql_wait.sh`
polls `select count(*) from yt_info('R')` in a `while` loop with **no
iteration limit**. I counted **6,888 identical failures** before my own
10-minute timeout killed it. Run without a timeout, it waits forever. A
broken build should take a minute to diagnose, not a wall-clock eternity.

### 2. After fixing that, it deadlocks: the wait precedes what it waits for

Patching `ytpgxt` → `yaxaha` gets the extension loaded and produces a new
infinite loop:

```
LOG:   yaxaha: extension loaded (version 0.5)
ERROR: yt_info: curl error: Couldn't connect to server
```

`yt_info()` reaches `ytserv` over HTTP. In `node.toml`, `ytserv` is started
by `node_runner.sh` on the line **after** `psql_wait.sh` — so the wait can
only finish once the thing it is waiting for has started, and that cannot
happen until the wait finishes. `node_runner.sh` never printed its
"Starting …" line in either run.

Not a guess about `yt_info` — on the same container's default instance,
where the packaged `ytserv` *is* running, the identical query answers:

```
$ psql -tc "select count(*) from yt_info('R')"          →  1
$ psql -tc "select * from yt_info('O')"
 [{"name":"cluster","value":"Term: 1, for 20min., Leader","module":"O"}]
```

So the extension and the binary are fine; the ordering is wrong.

**Fixed** by deleting that `psql_wait.sh` call. The gate was not missing, it
was already in the right place — the parallel `test_and_close` task runs
`yt_wait.sh`, whose first act is the same `psql_wait.sh`, and which then also
waits for a leader. The `${INIT}` step is now fatal and writes to `error.msg`
as well, so a repeat of finding 1 reports itself instead of hanging.

### 2a. `ytserv_locator.sh` chose a binary that cannot run

Starting ytserv immediately made this visible:

```
/usr/local/bin/yaxaha/ytserv: error while loading shared libraries:
  libpython3.12.so.1.0: cannot open shared object file
```

The package ships three builds and they are not interchangeable:

```
ytserv            libpython3.12.so.1.0 => not found
ytserv-glibc2_35  libraries resolve
ytserv-musl       libraries resolve
```

`ls -l …/ytserv* | head -1` picks the first by name, which is the one that
cannot start on Ubuntu 22.04. `yxctl` picks `ytserv-glibc2_35` for the
packaged install, so the tests were aimed at a different binary from the
deployment even in the years they ran. **Fixed**: the locator now skips any
candidate with an unresolved library, prefers a suffixed glibc build, and
falls back to the static musl one.

### 2b. ytserv's config table was not being passed

With a runnable binary, ytserv connected and then queried this:

```
ERROR: syntax error at or near "-"
STATEMENT: select name, value from public.ytserv-glibc2_35 where module = $1
```

The config table is ytserv 0.12's **second argument**, and given only a
connection string it derives one from its own `argv[0]`. The packaged
bootstrap passes `public.yt_config`; the harness passed nothing. This is the
"worth confirming the harness is not relying on a default that changed"
note below — it was. **Fixed** in both branches of the `yt` task.
`node_runner.sh` now takes `<node-id> <command> [args…]` and runs `"$@"`, so
the next argument ytserv grows does not need an edit here.

### 2c. ytserv 0.12 wants a UUID node id — blocked

```
thread 'main' panicked at ytserv/src/state/mod.rs:1235:17:
called `Result::unwrap()` on an `Err` value:
  "parsing to uuid: [node1]: invalid character: found `n` at 0"
```

The `pg` task starts Postgres with `-c yt.node="node$NID"`, and `it_init.sql`
keys the roster on `node1`/`node2`/`node3`. The packaged install does not:

```
$ psql -c "show yt.node"
 0284d019-f47d-4ad5-87f2-b2ee1f63812c
```

`yxctl` generates a UUID at setup time. Making the harness match is not a
one-line change — the roster is shared, so three UUIDs have to be generated
once per run and templated into every node's `it_init.sql`, and the `'N'`
rows keyed on them. That is a change to the fixture design, so it is a
question rather than a patch. See "Questions" at the end.

Note this failure still **hangs** rather than reporting: ytserv panics,
`node_runner.sh` restarts it, and `yt_wait.sh` waits for a leader that will
never be elected. The unbounded `while` loops are still there — see step 1
of "Order to do it in".

### 3. The replication assertions never execute

`testcases/wait.sh` is what makes a test case a test — it polls until the row
inserted on one node appears on this one. It takes the expected row count as
its **sixth** argument and reads its **fifth**:

```sh
expected=1
if [ $# -gt 4 ]; then
 expected=$5          # $5 is "Test_Case_1"; the count is $6
fi
```

`node.toml` calls it as `wait.sh $port $wd $NID $CUID.1 Test_Case_1` and, for
cases 3 and 4, `… Test_Case_3 3`. So `expected` becomes the string
`Test_Case_1`. Inside `[[ … -lt … ]]` bash evaluates both sides
arithmetically; an unset identifier is `0`, so the guard is `0 -lt 0` and the
loop body **never runs once**:

```sh
$ lines=0; expected="Test_Case_1"; runs=0
$ [[ "$runs" -lt 10 && $lines -lt $expected ]] && echo run || echo "never runs"
never runs
```

What remains is `error.msg`: a case "passes" unless the insert itself printed
`ERROR`. Nothing checks that the write reached any other node — which is the
only property the cluster exists to provide.

### 4. Half the test cases are unreachable

```toml
[tasks.it]
run_task = { name = ["it1", "it2"] }
```

`it3` (restart the leader) and `it4` (restart a follower) are fully written
and never invoked. They are also the two cases that would catch a real
consensus bug.

While reading them: `case3/test_node.sh` runs the same
`insert into yt_config(name, value) values ('$4','$4')` three times, and
`case3/test_lead.sh` is labelled `TestCase2` in its header call. Neither has
run, so neither has been shaken out.

### 5. `CNT` above 3 cannot work

`Makefile.toml` offers `node1` … `node9` and `CNT` defaults to 3, but
`it_init.sql` hardcodes the roster:

```sql
('node1','N','127.0.0.1:28771'),
('node2','N','127.0.0.1:28772'),
('node3','N','127.0.0.1:28773'),
```

Nodes 4–9 start a Postgres and a `ytserv` that no peer has ever heard of.
Six of the nine tasks are decoration.

**A question, not a finding:** that roster names ports `2877N`, while
`prepare_port` starts Postgres on `2876N` and nothing binds `2877N` unless
`PGBOUNCER` is set — `[task.check_pgb_port]` (which is a typo for `tasks`,
and therefore dead) is the only other place `2877N` appears. Is `2877N`
meant to be ytserv's peer port, or is the roster pointing at a pgbouncer
that is not running by default?

### 6. `ps | grep node | kill` is the teardown

`close_wait.sh`, `Makefile.toml:killall` and `node.toml:cleaning` all find
processes by grepping the whole process table for the string `node`, with
accumulated exclusions for `grep`, `nodev`, `mount` and `externals/node`.
Three exclusions is evidence it has already misfired. On a developer machine
running anything Node.js-shaped, it kills unrelated processes — and it runs
`kill` without checking ownership.

### 7. Smaller things

- `docker_post_bootstrap.sh` runs `psql -c "…"` with no `-P pager=off`. With
  a tty attached the pager opens and the bootstrap never completes, which
  makes the container unusable non-interactively. Found the hard way: it is
  why `record.sh` probes with a query instead of grepping the logs.
- `[tasks.pgbouncer]`: `sed -i 's/%port%/$port/' -i "$wd/pgbouncer.ini"` —
  single quotes, so `$port` is never expanded, and `-i` is passed twice. The
  template substitution has never worked.
- `[tasks.remove_wals]` is in no dependency chain.
- **The Dockerfile's `PGDATA` and `VOLUME` were dead, and took a `COPY` with
  them** — fixed. `/var/lib/postgresql/data` held nothing: the test nodes
  are `initdb`'d into `./cluster/nodeN`, and the package's own instance
  lives at `/var/lib/postgresql/14/main`. `VOLUME` on that path left an
  anonymous volume behind after every `docker run`, and
  `COPY pg_hba.conf $PGDATA/pg_hba.conf` came *after* it — Docker discards
  writes to a declared volume path made in later build steps, so that file
  never reached an image at all. What actually opens up authentication is
  the `sed s/peer/trust/` against the packaged cluster's config; each test
  node gets initdb's own default. Verified after removal: no volume
  declared, none created per container, and a run from an empty `cluster/`
  behaves identically.
  `pg_hba.conf` in the repo root is now referenced by nothing — left in
  place rather than deleted, but it is dead.
- ~~`ytserv_locator.sh` takes whichever name sorts first~~ — promoted to
  finding 2a; it was picking an unrunnable binary. Fixed.
- ~~The harness invokes `ytserv` without the packaged bootstrap's second
  argument~~ — promoted to finding 2b; it was. Fixed.
- `testcases/yt_complete.sh` emits `select yt_complete(true);` **only** when
  `PGBOUNCER=XA`, so the automated cases commit without it — while
  `it_test.sql` and the README both call it unconditionally. One of the two
  is wrong and I do not know which.
- `.github/workflows/build.yml` is 26 lines and runs `df -h`. Nothing here
  runs in CI, which is why items 1–3 could all be true at once.

### 8. Every wait was unbounded — fixed

The reason findings 1, 2, 2a, 2b and 2c could all be true at once and none
of them reported: each ended in a `while` with no way out. A build that is
broken in five places should take a minute to find out, not a weekend.

`wait_common.sh` (new) holds the convention — `it_wait_for "<what>" <cmd>`
polls once a second up to `IT_WAIT_TIMEOUT` (90s, overridable), and on
giving up re-runs the probe once with output shown, prints why, appends to
`error.msg` and exits non-zero. Appending matters as much as the exit code:
several callers have no `set -e` and drop it.

| loop | was | now |
|---|---|---|
| `postgres_wait.sh` — socket appears | unbounded | `it_wait_for`, then the existing probe loop folded into a second one |
| `psql_wait.sh` — `yt_info()` answers | unbounded | `it_wait_for` |
| `yt_wait.sh` — a leader is elected | unbounded | `it_wait_for` |
| `yt_wait.sh` — node reports Good/Leader | unbounded | `it_wait_for` |
| `yt_wait.sh` — `first_node.sql` selects | bounded, silent | bounded, warns (see below) |
| `close_wait.sh` — kill until nothing is left | unbounded `SIGTERM` | `SIGTERM` for `IT_STOP_TIMEOUT`, then `SIGKILL` for `IT_KILL_TIMEOUT`, then reports what it could not stop |
| `node_runner.sh` — restart the node | unbounded | a restart is a test case, a crash loop is not: `IT_MAX_RESTARTS` (5) exits within `IT_MIN_UPTIME` (5s) and it gives up |

Two deliberate non-changes:

- **`first_node.sql`'s probe stays advisory.** It was already bounded, and
  the test cases use it in a `condition_script`, so no qualifying node means
  they skip rather than fail. Making that fatal is a pass/fail decision
  (finding 3), not a hang, so it now prints a warning saying skipping looks
  like passing — and nothing else.
- **A fast failure still leaves Postgres running.** cargo-make aborts the
  parallel run before `default`'s `close_wait.sh` script is reached. That is
  survivable because `node.toml`'s `default` depends on `cleaning`, which
  runs at the *start* of the next run — verified by running twice in a row.

Verified rather than assumed: `it_wait_for` timing out (exits 1 in 3s,
writes `error.msg`), and `close_wait.sh` escalating to `SIGKILL` against a
process that traps `SIGTERM`.

## What to use instead

### The target shape

The package already answers this. `yxctl` writes exactly this into the
container's bootstrap, and it is running right now:

```sh
sudo su -c "/usr/local/bin/yaxaha/ytserv-glibc2_35 \
    'postgresql://postgres@/postgres?host=/var/run/postgresql&port=5432' \
    public.yt_config" >> /var/log/yaxaha/ytserver.log postgres &
```

`ytserv` as a background job, as `postgres`, over the local socket, beside
the Postgres it belongs to. **One container per cluster node, each an
ordinary single-node install**, is therefore both the realistic shape and the
simple one:

| today | container per node |
|---|---|
| ports `2876N`, sockets in `./cluster/nodeN` | every node on 5432, its own socket |
| roster `127.0.0.1:2877N` | roster `node1:5432, node2:5432, …` over a docker network |
| `ps \| grep node \| kill` | `docker compose down` |
| restart = kill the pid in `.s.YT.$port.pid` | `docker compose restart node2` |
| partition = not expressible | `docker network disconnect` |
| all nodes share one filesystem and one `error.msg` | isolated by construction |

### Compose owns lifecycle, Ansible owns the scenario

They are not alternatives; they do different halves.

- **Compose** (or Ansible's `community.docker.docker_container`) creates
  node1…nodeN on one network. That is the whole of what `run_task
  parallel = true`, `le.sh` and the nine `nodeN` tasks are doing.
- **Ansible** prepares each node and runs the scenario: install the package,
  template the roster, create the extension, start `ytserv`, wait for a
  leader with `until`/`retries` — and then **assert**, per case, with a real
  pass/fail instead of grepping a shared file for `ERROR`.

The `wait_for`/`until` + `assert` trio replaces `postgres_wait.sh`,
`psql_wait.sh`, `yt_wait.sh` and `testcases/wait.sh` outright, with a retry
limit that cannot be forgotten — which is finding 1's real fix, not the
one-word rename.

The two things this buys that matter most:

1. **A case that cannot run fails.** Today, "the wait loop never executed"
   and "the data replicated" produce identical output. An `assert` with
   `until: rows == expected` and `retries: 20` cannot pass without having
   looked.
2. **The restart cases become writable.** `it3`/`it4` exist because someone
   wanted them; they are unreachable partly because killing a pid inside a
   shared process table and hoping `node_runner.sh` restarts it is a hard
   thing to make reliable. `docker compose restart node2` is not.

This is the same pattern `../trust-atria-srv/eval/ansible` uses against a
throwaway systemd container, so there is a worked example next door.

**Keep `cargo make` for building the Rust crates.** The argument here is only
against using it as a process supervisor.

**The alternative I am not recommending**, for completeness: write the
harness in Rust, the way `../trust-atria-srv/crates/atria-proxy/tests/e2e.rs`
and its `common/processes.rs` do — real test names, real assertions,
`cargo test`. It is a good pattern and this org already runs it. It loses on
this job because half of what needs testing *is* the deployment (the apt
package, `ytsetup`, the systemd unit, a node restarting), and a Rust test
harness has to reimplement container lifecycle to get at it.

### Order to do it in

Value lands early and nothing below depends on the rewrite:

1. **Unbreak it.** `ytpgxt` → `yaxaha`, start `ytserv` before waiting on it,
   the two that fell out of those (2a, 2b), and a cap on every wait (8) —
   **done**. Still open: the UUID node id (2c), which needs a decision about
   the fixtures rather than a patch.
2. **Make the assertions real.** `wait.sh` `$5` → `$6`; add `it3`/`it4` to
   `[tasks.it]`; fix `case3`'s triple insert and its `TestCase2` header. Now
   a green run means something.
3. **Wire it into CI** — the 26-line workflow is why 1 and 2 were invisible.
4. **Then** container-per-node + Compose + Ansible, and delete the eight
   polling scripts.

Doing 4 first is tempting and wrong: a rewrite that inherits vacuous
assertions is a rewrite you cannot tell is working.

## Recordings

`tapes/` holds two VHS tapes and `record.sh` drives them:

| | |
|---|---|
| `tapes/cluster.tape` | the three-node suite running end to end |
| `tapes/single-node.tape` | one node and a psql prompt — leader state, an insert, the row coming back |

`record.sh` builds the image, boots and bootstraps a container off-camera
(the entrypoint spends a minute on apt and `ytsetup`, which nobody wants to
watch), then records. Needs `vhs`, `ttyd` and `ffmpeg`.

**Neither has been recorded.** This host has none of the three, and — more
to the point — `cluster.tape` records a suite that currently hangs, so it
cannot produce anything worth publishing until finding 1 and 2 are fixed.
Every `Sleep` in both tapes is a guess at how long the real thing takes, and
should be trimmed against the first real recording.
