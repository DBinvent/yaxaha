#!/usr/bin/env bash
# Launch the test container and install PostgreSQL.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

if lxc info "$YX_CONTAINER" >/dev/null 2>&1; then
	echo "Container $YX_CONTAINER already exists — reusing (90_destroy.sh to reset)."
else
	lxc init "$YX_IMAGE" "$YX_CONTAINER"
	if [ "$YX_NIC" = "macvlan" ]; then
		parent="$(ip route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
		echo "Using macvlan on $parent (Docker-on-host workaround, see tests/README.md)"
		lxc config device add "$YX_CONTAINER" eth0 nic nictype=macvlan parent="$parent" name=eth0
	fi
	lxc start "$YX_CONTAINER"
fi

wait_for_container

echo "Installing PostgreSQL..."
xc apt-get update -q
# libprotobuf-c1: runtime dep of the yaxaha extension .so (matches deb Depends)
xc env DEBIAN_FRONTEND=noninteractive apt-get install -qy postgresql postgresql-client libpq-dev binutils libprotobuf-c1
xc systemctl enable --now postgresql

assert "postgres accepts connections" xc sudo -u postgres psql -tc "select 1"
echo "Container $YX_CONTAINER ready."
