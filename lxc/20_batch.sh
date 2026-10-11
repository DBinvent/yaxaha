#!/usr/bin/env bash
# Batch mode install: sudo yxctl --batch (mode 1 of 3).
# Asserts: exit code, config table exists, ytserver service unit present & active,
# extension installed in the DB.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

echo "Running batch install (-t $YX_TARGET)..."
xc yxctl -v --batch -t "$YX_TARGET" \
	--db "postgresql://postgres@localhost/postgres?host=/var/run/postgresql"

assert "config table $YX_TARGET exists" \
	xc sudo -u postgres psql -tc "select 1 from $YX_TARGET limit 1"
assert "yaxaha extension present in DB" \
	xc sudo -u postgres psql -tc "select 1 from pg_extension where extname like 'ya%' or extname like 'yt%'"
assert "ytserver unit exists" xc test -f /lib/systemd/system/ytserver.service
assert "ytserver active" xc systemctl is-active ytserver

echo "Batch install: PASS"
