# YaXaHa integration tests (LXC)

Integration tests run in a disposable LXC container so install/purge cycles never
touch the host. Unit tests stay in the crates (`cargo test`); everything that needs
root + a real PostgreSQL runs here.

## Layout

```
lxc/
  (audit_locale.sh, the en.yml docs audit, stays in yt-pgxt/yxctl/tests/)
  lxc/
    env.sh            # shared config: container name, image, artifact paths
    00_create.sh      # launch container, install PostgreSQL
    10_push.sh        # push yxctl/ytserv binaries (or the .deb) into the container
    20_batch.sh       # batch mode: sudo yxctl --batch → assert service + yt_info
    30_purge.sh       # purge → assert clean → re-install (clean re-install cycle)
    40_cargo_ignored.sh # run root-gated cargo tests (--ignored) inside the container
    90_destroy.sh     # delete the container
    run_all.sh        # 00 → 10 → 20 → 30 (→ 40 with RUN_CARGO=1) → 90
```

## Usage

```sh
# full cycle (creates and destroys the container)
lxc/run_all.sh

# or step by step, keeping the container for inspection
lxc/00_create.sh
lxc/10_push.sh
lxc/20_batch.sh
lxc exec yxctl-test -- bash        # poke around
lxc/90_destroy.sh
```

Configuration via env vars (see `lxc/env.sh`): `YX_CONTAINER` (name),
`YX_IMAGE` (default `ubuntu:24.04`), `YX_DEB` (path to a built .deb — when unset,
binaries are pushed from `target/release`).

## Host prerequisites

- LXD initialized once: `lxd init --auto` (creates the default storage pool and
  the `lxdbr0` bridge).
- **Docker on the same host**: Docker sets the iptables `FORWARD` policy to DROP,
  which cuts the container off from the internet (DNS still works — dnsmasq is
  host-local — but apt downloads time out). Allow the LXD bridge through:

  ```sh
  sudo iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT
  sudo iptables -I DOCKER-USER -o lxdbr0 -j ACCEPT
  ```

  These rules do not survive a reboot; re-add or persist them (e.g.
  `iptables-persistent`) if the tests are run regularly.

  **No-root alternative:** `YX_NIC=macvlan lxc/run_all.sh` gives the container
  its own LAN address via DHCP (macvlan on the uplink interface), bypassing the host
  FORWARD chain entirely. The tests only use `lxc exec`, so the macvlan limitation
  (host cannot reach the container over IP) does not matter here.

## What the three modes need

- **batch** (`20_batch.sh`): fully scripted, asserted here.
- **purge + re-install** (`30_purge.sh`): fully scripted, asserted here.
- **setup TUI wizard** (`--setup`) and **control TUI**: interactive — verified manually
  inside the container (`lxc exec $YX_CONTAINER -- sudo yxctl --setup`). The wizard's
  non-interactive pre-checks (connect diagnostics, role/db bootstrap under sudo) are
  exercised by the batch scripts and unit tests.
