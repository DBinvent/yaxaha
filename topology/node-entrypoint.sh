#!/usr/bin/env bash
# [topology] Bring one node up: PostgreSQL, the extension, then ytserv.
#
# No systemd. ytserv takes `<db_url> <schema.table>` and that is the whole
# contract, so a container running it as PID 1's child is the same process a
# unit would have started - with none of the init overhead this test would
# otherwise pay N times over.
set -euo pipefail

NODE_UUID="${NODE_UUID:?NODE_UUID is required}"
DB="${DB:-yxtopo}"
CFG_TABLE="${CFG_TABLE:-public.yt_config}"
PGBIN="$(pg_config --bindir)"
PGDATA=/var/lib/postgresql/18/main

# yt.node is how ytserv picks its own row out of the N rows, and it MUST be a
# uuid - rppd parses it strictly and a non-uuid panics at startup.
# Written fresh, not appended: `docker restart` re-runs this entrypoint against
# the SAME filesystem, and appending grew a new pair of settings on every cycle.
cat > /etc/postgresql/18/main/conf.d/yt.conf <<EOF
max_prepared_transactions = 100
yt.node = '${NODE_UUID}'
EOF

# Same reason, and this one is fatal rather than untidy: ytserv refuses to start
# when its pid file is still there ("another process PID# N by .s.YT...pid"),
# and a restarted container always has one - nothing reaped the old process.
# On a real node systemd owns that lifecycle; here the entrypoint does.
rm -f /var/run/postgresql/.s.YT.*.pid

chown -R postgres:postgres /etc/postgresql/18/main/conf.d

# A CLEAN stop on `docker stop` / `docker restart`. PID 1 is this shell, and a
# shell as PID 1 ignores SIGTERM without a trap: docker waited out its timeout
# and SIGKILLed the container, PostgreSQL with it, so every start began with a
# crash recovery ("Removed stale pid file"). One took three minutes after
# 89_recover's stop and the node missed its whole 180 s window; one longer than
# the start wait below ended the entrypoint under `set -e` and the container
# with it ("container n1 is not running" in 93). ytserv first, then PostgreSQL
# in fast mode.
YT_PID=""
stop_node() {
    echo "[node] stopping: ytserv, then PostgreSQL (fast)"
    [ -n "$YT_PID" ] && kill -TERM "$YT_PID" 2>/dev/null || true
    pkill -TERM -f yaxaha/ytserv 2>/dev/null || true
    for _ in 1 2 3 4 5; do pgrep -f yaxaha/ytserv >/dev/null || break; sleep 0.2; done
    pg_ctlcluster 18 main stop -m fast 2>/dev/null || true
    exit 0
}
trap stop_node TERM INT

pg_ctlcluster 18 main start || true
# No fixed cap ending in a half-started node: a recovery replays the WAL and
# takes what it takes. Ten minutes, then say so and stay up for inspection.
pg_up=0
for i in $(seq 1 600); do
    if su postgres -c "psql -tAc 'select 1'" >/dev/null 2>&1; then pg_up=1; break; fi
    [ $((i % 30)) -eq 0 ] && echo "[node] PostgreSQL not answering yet (${i}s) - recovering?"
    sleep 1
done
[ "$pg_up" = 1 ] || { echo "[node] FATAL: PostgreSQL did not come up in 600s"; sleep infinity & wait $!; }

DB_URL="${DB_URL:-postgresql://postgres@localhost/${DB}?host=/var/run/postgresql}"
echo "[node] db_url=${DB_URL}"

# A TCP url needs a pg_hba line that lets it in. Debian's default is
# `host ... 127.0.0.1/32 scram-sha-256`, and the `postgres` role has no
# password, so ytserv just times out - the symptom is "Timed out in bb8",
# several layers from the cause.
#
# `trust` on loopback only, and only for a node deliberately configured this
# way. Acceptable in a throwaway fixture container where the alternative is
# putting a password in a URL that then appears in `docker inspect`; it would
# not be acceptable on a real node, which is why this is scoped to the TCP case
# rather than applied to the image.
case "$DB_URL" in
    *"?host="*) : ;;   # unix socket: peer auth, nothing to do
    *)
        HBA=/etc/postgresql/18/main/pg_hba.conf
        if ! grep -q '^host.*127.0.0.1/32.*trust' "$HBA"; then
            sed -i 's|^\(host\s*all\s*all\s*127.0.0.1/32\s*\)scram-sha-256|\1trust|' "$HBA"
            sed -i 's|^\(host\s*all\s*all\s*::1/128\s*\)scram-sha-256|\1trust|' "$HBA"
            pg_ctlcluster 18 main reload
            echo "[node] pg_hba: loopback TCP set to trust (this node is TCP-attached)"
        fi
        ;;
esac


su postgres -c "psql -tAc \"select 1 from pg_database where datname='${DB}'\"" | grep -q 1 \
    || su postgres -c "createdb ${DB}"

# Errors here are REPORTED, not swallowed. A silent `|| true` on the extension
# step produced a node whose only symptom was ytserv saying yt_config did not
# exist, several layers away from the statement that actually failed.
su postgres -c "psql -v ON_ERROR_STOP=1 -q -d ${DB} -c 'create extension if not exists yaxaha'" \
    || { echo "[node] FATAL: create extension yaxaha failed"; sleep infinity & wait $!; }

# What the fixture adds on top of the extension (yt_setup() itself comes with
# the extension): the join gate. Advisory, but its errors still print.
su postgres -c "psql -q -d ${DB} -f /opt/pg_setup.sql" 2>&1 | grep -iE "^ERROR" | head -5 || true

tables=$(su postgres -c "psql -tAq -d ${DB} -c \"select count(*) from pg_tables where schemaname='public' and tablename='yt_config'\"")
echo "[node] yt_config present: ${tables}"
[ "${tables:-0}" = "1" ] || { echo "[node] FATAL: ${CFG_TABLE} was not created"; sleep infinity & wait $!; }

echo "[node] ${NODE_UUID} postgres up, waiting for config rows..."
# Wait for the SENTINEL the harness writes last, not for "any N row" - the
# roster is written one statement at a time, so an any-row test goes true
# halfway through and the node elects on a partial cluster.
#
# No timeout-then-start-anyway: coming up on a roster that was never finished is
# the failure this wait exists to prevent, so if it never arrives the container
# stays here and `docker logs` says why.
while :; do
    r=$(su postgres -c "psql -tAd ${DB} -c \"select value from ${CFG_TABLE} where module='C' and name='cfg_ready'\"" 2>/dev/null || true)
    [ "${r:-}" = "1" ] && break
    sleep 1
done

# The network interface before ytserv: it dials every peer the moment it
# starts, and after a `docker start` its first connects all failed with
# "transport error" for ~11 s - the interface was not up yet. An address on
# eth0 and every roster host resolving; and its own port free, so nothing left
# over is still holding it.
self_port=$(su postgres -c "psql -tAd ${DB} -c \"select split_part(value, ':', 2) from ${CFG_TABLE} where module='N' and name='${NODE_UUID}'\"" 2>/dev/null || true)
peers=$(su postgres -c "psql -tAd ${DB} -c \"select string_agg(split_part(value, ':', 1), ' ') from ${CFG_TABLE} where module='N'\"" 2>/dev/null || true)
net_ok=0
for i in $(seq 1 60); do
    if ip -4 -o addr show dev eth0 2>/dev/null | grep -q inet \
        && { [ -z "$peers" ] || getent hosts $peers >/dev/null; } \
        && { [ -z "$self_port" ] || [ -z "$(ss -ltnH "sport = :${self_port}" 2>/dev/null)" ]; }; then
        net_ok=1; break
    fi
    sleep 1
done
[ "$net_ok" = 1 ] && echo "[node] network ready (eth0 up, roster resolves, port ${self_port:-?} free)" \
    || echo "[node] WARN: network not ready after 60s (eth0/roster/port ${self_port:-?}) - starting ytserv anyway"

echo "[node] starting ytserv"
# [skv] ytserv's app key (marg SECRET), when the container was given one
# (10_up.sh): a join approval is an HMAC under it, and the node key is kept
# encrypted with it. Handed over in a 0600 file rather than on a command line;
# an unset SECRET starts ytserv without one, as before.
YT_ENV=/dev/null
if [ -n "${SECRET:-}" ]; then
    install -d -m 0700 -o postgres /run/yt
    ( umask 077; printf 'SECRET=%s\n' "$SECRET" > /run/yt/ytserv.env )
    chown postgres /run/yt/ytserv.env
    YT_ENV=/run/yt/ytserv.env
fi
# Not `exec`: when ytserv exits the container must STAY UP so `docker logs` and
# `docker exec` still work. A test node that vanishes on error takes its own
# evidence with it. (The `exec` below replaces the shell inside `su`, not this
# script.)
# [db-local] A node whose PostgreSQL is reached over TCP can never be Main
# (ytserv membership.md, Forever-Spare) but is a full etcd and rppd member. Set
# DB_URL to a tcp:// form to make one. The DEFAULT stays the unix socket, so an
# unset DB_URL is byte-for-byte the previous behaviour.
#
# `@localhost/${DB}`, not `@${DB}`: in a libpq URL the segment after @ is the
# HOST. Written the short way it connected to a database named after the user
# and reported yt_config missing - true, in the database it actually reached.
# The `?host=` override then points it at the unix socket. See
# ytserv/src/yt_config.rs sqlx_host_fix for why the placeholder host is needed.

#
# In the background with `wait`: a trap runs only between foreground commands,
# so a ytserv (or `sleep`) in the foreground kept SIGTERM from stop_node.
su postgres -s /bin/bash -c "set -a; . ${YT_ENV}; set +a; exec /usr/local/bin/yaxaha/ytserv '${DB_URL}' ${CFG_TABLE}" &
YT_PID=$!
wait "$YT_PID" || echo "[node] ytserv exited $? - container held open for inspection"
YT_PID=""
sleep infinity &
wait $!
