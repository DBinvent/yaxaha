#!/usr/bin/env bash
# Shared config for the LXC integration tests. Source, do not execute.
set -euo pipefail

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Settings: yaxaha-tests/.env (not committed, see env.example); the environment wins.
if [ -f "$TESTS_ROOT/.env" ]; then
	_yx_keep="$(export -p)"; set -a; . "$TESTS_ROOT/.env"; set +a; eval "$_yx_keep"; unset _yx_keep
fi
# The yt-pgxt checkout: YT_PGXT, or a sibling of this repository.
REPO_ROOT="${YT_PGXT:-$(cd "$TESTS_ROOT/.." && pwd)/yt-pgxt}"

YX_CONTAINER="${YX_CONTAINER:-yxctl-test}"
YX_IMAGE="${YX_IMAGE:-ubuntu:24.04}"
# path to a built .deb; when unset, raw binaries are pushed from target/release
YX_DEB="${YX_DEB:-}"
# config table used by the batch test
YX_TARGET="${YX_TARGET:-public.yt_config}"
# container NIC: "bridge" (lxdbr0, default) or "macvlan" (own LAN address via DHCP).
# Use macvlan when Docker runs on the host: its iptables FORWARD DROP policy cuts
# lxdbr0 off from the internet. All tests use `lxc exec`, so host<->container
# networking is not needed and macvlan is safe here.
YX_NIC="${YX_NIC:-bridge}"

xc() { lxc exec "$YX_CONTAINER" -- "$@"; }

wait_for_container() {
	# cloud images need a moment for networking + apt locks
	for _ in $(seq 1 30); do
		# bounded: `--wait` blocks until boot finishes, and a container that never
		# finishes (a full disk, no network) cost hours here, 30 tries of it
		if timeout 20 lxc exec "$YX_CONTAINER" -- systemctl is-system-running --wait >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	echo "container did not become ready" >&2
	return 1
}

assert() {
	# assert <description> <command...>
	local desc="$1"; shift
	if "$@"; then
		echo "  OK: $desc"
	else
		echo "  FAIL: $desc" >&2
		exit 1
	fi
}
