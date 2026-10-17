#!/bin/bash
# A yaxaha node: PostgreSQL first, then ytserv once the config says so.
#
# On the first start up.sh (or test.sh, for a node added later) writes the
# config; ytserv waits for the C row cfg_ready. On a restart the row is already
# there and ytserv starts right away, with the WAL it had: that is the refresh
# the test exercises.
set -euo pipefail
NODE_UUID="${NODE_UUID:?NODE_UUID is required}"
DB="${DB:-rmc}"
CFG_TABLE=public.yt_config

# PostgreSQL for the load client too: it connects over the test's own docker
# network, so any address on it is trusted. Nothing else can reach that network.
cat > /etc/postgresql/18/main/conf.d/yt.conf <<EOF
max_prepared_transactions = 100
listen_addresses = '*'
yt.node = '${NODE_UUID}'
EOF
grep -q '^host all all 0.0.0.0/0 trust' /etc/postgresql/18/main/pg_hba.conf \
    || echo 'host all all 0.0.0.0/0 trust' >> /etc/postgresql/18/main/pg_hba.conf
# replication too: a new node can be a physical clone of a member
grep -q '^host replication all 0.0.0.0/0 trust' /etc/postgresql/18/main/pg_hba.conf \
    || echo 'host replication all 0.0.0.0/0 trust' >> /etc/postgresql/18/main/pg_hba.conf
chown -R postgres:postgres /etc/postgresql/18/main/conf.d
# a socket lock left by the previous run of this container
rm -f /var/run/postgresql/.s.YT.*.pid

# CLONE_FROM=<member>: the expansion path of ytserv's membership.md - a physical
# copy of a running member, once, on the first start. It carries the data, the
# synced tables' triggers, and yt_config with the cluster's roster (the new
# node's own N row included, written before this) and the member's position
# (`least`), from which ytserv pulls what the copy missed. yt.node is outside
# the data directory (conf.d above), so the clone keeps its own identity.
PGDATA=/var/lib/postgresql/18/main
CLONED=""
if [ -n "${CLONE_FROM:-}" ] && [ ! -e "$PGDATA/.rmc-cloned" ]; then
    echo "[node] cloning ${CLONE_FROM}"
    rm -rf "${PGDATA:?}"/*
    su postgres -c "pg_basebackup -h ${CLONE_FROM} -U postgres -D $PGDATA -X stream -c fast" \
        || { echo "[node] FATAL: pg_basebackup from ${CLONE_FROM} failed"; sleep infinity; }
    touch "$PGDATA/.rmc-cloned" && chown postgres:postgres "$PGDATA/.rmc-cloned"
    CLONED=1
fi

# A restarted container keeps /var/run/postgresql, and the socket lock file in it
# names the old postmaster's pid. Inside a container pids are small and handed out
# again in the same order, so that pid is often alive - as some other process -
# and PostgreSQL refuses to start ("another postmaster (PID 17)"). Nothing runs
# here yet, so any lock left is stale.
rm -f /var/run/postgresql/.s.PGSQL.*.lock
pg_ctlcluster 18 main start
for _ in $(seq 1 30); do
    su postgres -c "psql -tAc 'select 1'" >/dev/null 2>&1 && break
    sleep 1
done
su postgres -c "psql -tAc \"select 1 from pg_database where datname='${DB}'\"" | grep -q 1 \
    || su postgres -c "createdb ${DB}"
su postgres -c "psql -v ON_ERROR_STOP=1 -q -d ${DB} -c 'create extension if not exists yaxaha'" \
    || { echo "[node] FATAL: create extension yaxaha failed"; sleep infinity; }

if [ -n "$CLONED" ]; then
    # Not the source's opinion of who leads (membership.md), and this node's own
    # residue for new config ids, so a row it creates never takes an id the
    # source's serial will produce (lib.sh seq_sql).
    su postgres -c "psql -q -d ${DB} -c \"begin; set local session_replication_role = replica; delete from ${CFG_TABLE} where module = 'C' and name = 'leader_uuid'; commit;\"" >/dev/null
    su postgres -c "psql -q -d ${DB} -c \"select setval('${CFG_TABLE}_id_seq', 100000 + ${SEQ_K:-0}, false); alter sequence ${CFG_TABLE}_id_seq increment by 100;\"" >/dev/null
    echo "[node] cloned from ${CLONE_FROM}: $(su postgres -c "psql -tAd ${DB} -c \"select count(*) from rmc_ledger\"" 2>/dev/null) ledger rows, least $(su postgres -c "psql -tAd ${DB} -c \"select value from ${CFG_TABLE} where module = 'C' and name = 'least'\"" 2>/dev/null)"
fi
echo "[node] ${NODE_UUID} postgres up, waiting for C cfg_ready..."
while :; do
    r=$(su postgres -c "psql -tAd ${DB} -c \"select value from ${CFG_TABLE} where module='C' and name='cfg_ready'\"" 2>/dev/null || true)
    [ "${r:-}" = "1" ] && break
    sleep 1
done
echo "[node] starting ytserv"
# [skv] ytserv's app key, when the container was given one (lib.sh node_run): the
# secret store and the link TLS a hierarchy runs on need it (skv-secrets.md H2, H7).
# Handed over in a 0600 file rather than on a command line.
YT_ENV=/dev/null
if [ -n "${SECRET:-}" ]; then
    install -d -m 0700 -o postgres /run/yt
    ( umask 077; printf 'SECRET=%s\n' "$SECRET" > /run/yt/ytserv.env )
    chown postgres /run/yt/ytserv.env
    YT_ENV=/run/yt/ytserv.env
fi
# not exec: when ytserv exits the container stays up, so its output can still be read
su postgres -s /bin/bash -c "set -a; . ${YT_ENV}; set +a; exec /usr/local/bin/yaxaha/ytserv 'postgresql://postgres@localhost/${DB}?host=/var/run/postgresql' ${CFG_TABLE}" \
    || echo "[node] ytserv exited $? - container held open for inspection"
sleep infinity
