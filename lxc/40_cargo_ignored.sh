#!/usr/bin/env bash
# Run the root-gated cargo tests (marked #[ignore]) inside the container:
# install_uninstall + configuration_only need root and a live PostgreSQL.
# Heavy: installs rust + pushes the source tree. Opt-in via run_all RUN_CARGO=1.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

echo "Installing build deps (this is slow the first time)..."
xc env DEBIAN_FRONTEND=noninteractive apt-get install -qy build-essential curl pkg-config libssl-dev protobuf-compiler
xc bash -c 'command -v cargo >/dev/null || (curl -sSf https://sh.rustup.rs | sh -s -- -y)'

echo "Pushing source tree..."
tar -C "$REPO_ROOT" --exclude=target --exclude=.git -czf /tmp/yx-src.tgz .
lxc file push /tmp/yx-src.tgz "$YX_CONTAINER/tmp/yx-src.tgz"
xc bash -c 'rm -rf /root/yx-src && mkdir -p /root/yx-src && tar -C /root/yx-src -xzf /tmp/yx-src.tgz'

echo "Running ignored (root+postgres) tests..."
xc bash -c 'source $HOME/.cargo/env && cd /root/yx-src && cargo test -p yxctl --bins -- --ignored'
echo "Ignored cargo tests: PASS"
