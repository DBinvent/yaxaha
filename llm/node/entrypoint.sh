#!/usr/bin/env bash
# One node: PostgreSQL with the extension, then - once up.sh has written the
# cluster config and its sentinel C cfg_ready - ytserv.
#
# No systemd: ytserv takes `<db url> <config table>` and that is its whole
# contract. The container stays up when ytserv exits, so `docker logs` and
# `docker exec` still show why.
set -euo pipefail

NODE_UUID="${NODE_UUID:?NODE_UUID is required}"
DB="${DB:-ytllm}"
CFG_TABLE=public.yt_config

# yt.node is how ytserv finds its own row among the N rows; a uuid. Written
# fresh: a restarted container re-runs this against the same filesystem.
cat > /etc/postgresql/18/main/conf.d/yt.conf <<EOF
max_prepared_transactions = 100
yt.node = '${NODE_UUID}'
EOF
chown -R postgres:postgres /etc/postgresql/18/main/conf.d
# a restarted container keeps the old pid file, and ytserv refuses to start on it
rm -f /var/run/postgresql/.s.YT.*.pid

# The ClickHouse cluster file ytserv renders from C clickhouse_cluster: this
# directory is a volume its ClickHouse node reads too. Group 101 is ClickHouse's
# in the official image; setgid, so the 0640 file ytserv writes stays readable.
chown postgres:101 /etc/yaxaha/clickhouse
chmod 2750 /etc/yaxaha/clickhouse

# ytserv's app key (marg SECRET): it decrypts the module K rows. Handed over in a
# file rather than on a command line.
install -d -m 0700 -o postgres /run/yt
( umask 077; printf 'SECRET=%s\n' "${SECRET:?SECRET is required}" > /run/yt/ytserv.env )
chown postgres /run/yt/ytserv.env

pg_ctlcluster 18 main start
for _ in $(seq 1 30); do
    su postgres -c "psql -tAc 'select 1'" >/dev/null 2>&1 && break
    sleep 1
done
su postgres -c "psql -tAc \"select 1 from pg_database where datname='${DB}'\"" | grep -q 1 \
    || su postgres -c "createdb ${DB}"
su postgres -c "psql -v ON_ERROR_STOP=1 -q -d ${DB} -c 'create extension if not exists yaxaha'" \
    || { echo "[node] FATAL: create extension yaxaha failed"; sleep infinity; }
echo "[node] ${NODE_UUID} postgres up, waiting for C cfg_ready..."

# Waits for the sentinel up.sh writes LAST: a node that started on a half-written
# roster would elect on it.
while :; do
    r=$(su postgres -c "psql -tAd ${DB} -c \"select value from ${CFG_TABLE} where module='C' and name='cfg_ready'\"" 2>/dev/null || true)
    [ "${r:-}" = "1" ] && break
    sleep 1
done

echo "[node] starting ytserv"
su postgres -s /bin/bash -c "set -a; . /run/yt/ytserv.env; set +a; exec /usr/local/bin/yaxaha/ytserv \
    'postgresql://postgres@localhost/${DB}?host=/var/run/postgresql' ${CFG_TABLE}" \
    || echo "[node] ytserv exited $? - container held open for inspection"
sleep infinity
