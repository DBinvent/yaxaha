#!/usr/bin/env bash
# Negative and repeat-install paths of `yxctl --batch` / `--purge`. Runs after
# 30_purge.sh (any configured or purged state will do) and before 90_destroy.sh.
#
#   L5  --batch with a database that does not exist, and with PostgreSQL stopped:
#       each exits non-zero with a message naming the problem, never hangs, and
#       leaves no ytserver unit behind. --batch on an already configured node:
#       exit 0 and change nothing (main.rs install(): an existing ytserver unit
#       cancels the setup unless --force) - that is what the code guarantees.
#   L2  purge, then install again on the same container: ytserv starts, a local
#       write through the extension works, and the log has no
#       "Sub-term ... already exists" (what a stale cluster WAL would cause).
#   L3  --batch --peers <file with two names> --cluster <uuid> --bind <bare ip>:
#       the node's own module-N row carries the port (:7421).
#   L6  --batch --users-db: a missing database exits 33; an existing one gets the
#       extension, its tables in its own config table, and participates;
#       --purge --drop-extension drops the extension in every database.
#
# Every yxctl run is wrapped in `timeout`, so a hang is a FAIL (exit 124/137),
# not a stuck nightly. Every check prints OK:/FAIL: and the script carries on; it
# exits 1 when any failed. A precondition that does not hold is a FAIL, never a
# skip.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
# carry on past a failing command: each one that matters is checked explicitly
set +e

failed=0
ok()  { echo "  OK: $1"; }
bad() { echo "  FAIL: $1" >&2; failed=$((failed + 1)); }
# check <description> <command...>
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

UNIT=/lib/systemd/system/ytserver.service
YT_LOGS="/var/log/yaxaha/ytserver.log /var/log/yaxaha/ytserver_error.log"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

db_url() { echo "postgresql://postgres@localhost/$1?host=/var/run/postgresql"; }

# yx <secs> <yxctl args...>: yxctl in the container under `timeout`; its output is
# shown (indented, so it cannot be read as an OK:/FAIL: line) and kept in $OUT.
# Returns yxctl's exit status: 124, or 137 after the kill, means it hung.
yx() {
	local secs="$1" rc; shift
	echo "  \$ yxctl $*"
	xc timeout -k 10 "$secs" yxctl "$@" >"$OUT" 2>&1
	rc=$?
	sed 's/^/    | /' "$OUT"
	return $rc
}
hung() { [ "$1" -eq 124 ] || [ "$1" -eq 137 ]; }
failed_cleanly() { [ "$1" -ne 0 ] && ! hung "$1"; }

# pgq <db> <sql>: one value; fails when psql does
pgq() { xc sudo -u postgres psql -X -tAq -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
pg_up() { pgq postgres "select 1" >/dev/null 2>&1; }
pg_down() { ! pg_up; }
# db_absent <name>: PostgreSQL answered AND has no such database
db_absent() { local v; v="$(pgq postgres "select 1 from pg_database where datname = '$1'")" || return 1; [ -z "$v" ]; }
wait_pg() { local i; for i in $(seq 1 20); do pg_up && return 0; sleep 3; done; return 1; }
unit_absent() { ! xc test -e "$UNIT"; }
svc_active() { xc systemctl is-active --quiet ytserver; }
svc_inactive() { ! svc_active; }
wait_active() { local i; for i in $(seq 1 10); do svc_active && return 0; sleep 3; done; return 1; }
main_pid() { xc systemctl show -p MainPID --value ytserver 2>/dev/null; }

# fresh_db <name>: a database of its own, so no row left by an earlier install
# (purge never touches the DB) decides what this one writes
fresh_db() {
	pgq postgres "drop database if exists $1 with (force)" >/dev/null \
		&& pgq postgres "create database $1" >/dev/null
}

# purge <label>: --purge default, exit status checked
purge() {
	local rc
	yx 120 --purge default; rc=$?
	check "$1: yxctl --purge default exits 0 (exit $rc)" [ "$rc" -eq 0 ]
	check "$1: no ytserver unit after the purge" unit_absent
}

# log_offsets: the current size of each ytserv log, to read only what follows
log_offsets() {
	local f
	for f in $YT_LOGS; do xc stat -c %s "$f" 2>/dev/null || echo 0; done | tr '\n' ' '
}
# log_since <offsets>: what the ytserv logs gained since log_offsets. A log that
# shrank (rotated, recreated) is read whole rather than skipped.
log_since() {
	local offs=($1) i=0 f o s
	for f in $YT_LOGS; do
		o="${offs[$i]:-0}"; i=$((i + 1))
		s="$(xc stat -c %s "$f" 2>/dev/null || echo 0)"
		[ "$s" -lt "$o" ] && o=0
		xc tail -c +"$((o + 1))" "$f" 2>/dev/null
	done
}

# write_row <db> <id> <value>: an INSERT into public.yx_l2_t, a table with the
# extension's zytsync_ trigger - so it goes through yt_synchronize and commits as
# a cluster commit (yaxaha.auto_complete). Retried over ytserv's start-up window;
# every error is kept in $WERR, the last one in $WOUT.
WERR=""; WOUT=""
write_row() {
	local i
	for i in $(seq 1 10); do
		WOUT="$(xc sudo -u postgres psql -X -tAq -v ON_ERROR_STOP=1 -d "$1" \
			-c "insert into public.yx_l2_t values ($2, '$3')" 2>&1)" && return 0
		WERR="$WERR
$WOUT"
		sleep 3
	done
	return 1
}

echo "== negative and repeat installs =="

# ── start from an unconfigured node ─────────────────────────────────────────
echo "-- purge whatever 30_purge.sh left, so the failing installs meet an unconfigured node"
purge "setup"
check "setup: PostgreSQL accepts connections" wait_pg

# ── L5a: a database that does not exist ─────────────────────────────────────
echo "-- L5: --batch with a --db naming a database that does not exist"
BAD_DB=yx_no_such_db
check "L5: precondition: database $BAD_DB does not exist" db_absent "$BAD_DB"
yx 120 --batch -t "$YX_TARGET" --db "$(db_url "$BAD_DB")"; rc=$?
check "L5: --batch with a bad --db name exits non-zero without hanging (exit $rc)" failed_cleanly "$rc"
check "L5: ...and its message names the missing database $BAD_DB" grep -q "$BAD_DB" "$OUT"
check "L5: ...and leaves no ytserver unit behind (a later --batch would be cancelled as 'already configured')" unit_absent
check "L5: ...and no ytserver running" svc_inactive

# ── L5b: PostgreSQL stopped ─────────────────────────────────────────────────
echo "-- L5: --batch with PostgreSQL stopped"
xc systemctl stop postgresql
check "L5: precondition: PostgreSQL is stopped" pg_down
yx 120 --batch -t "$YX_TARGET" --db "$(db_url postgres)"; rc=$?
check "L5: --batch with PostgreSQL stopped exits non-zero without hanging (exit $rc)" failed_cleanly "$rc"
check "L5: ...and its message says it cannot connect to PostgreSQL" grep -qi "connect" "$OUT"
check "L5: ...and leaves no ytserver unit behind" unit_absent
xc systemctl start postgresql
check "L5: PostgreSQL is back after the restart" wait_pg

# ── L2, part 1: a configured node that has taken a write ────────────────────
#
# Its own database and a fixed node uuid (-i), the same for both installs: a
# re-install keeps the node's identity (as a host-derived --peers uuid does), and
# the database a purge leaves alone is then consistent with it - the one stale
# thing is the cluster WAL. /var/yaxaha is cleared HERE, before the first install,
# only so that this half starts clean; the purge in part 2 is what is under test.
echo "-- L2: install, take a write, purge, install again on the same container"
L2_DB=yx_l2
L2_NODE="$(xc cat /proc/sys/kernel/random/uuid)"
check "L2: fresh database $L2_DB" fresh_db "$L2_DB"
xc rm -rf /var/yaxaha
yx 600 -v --batch -t "$YX_TARGET" -i "$L2_NODE" --db "$(db_url "$L2_DB")"; rc=$?
check "L2: first install exits 0 (exit $rc)" [ "$rc" -eq 0 ]
check "L2: ytserver active after the first install" wait_active

# yt_setup() comes with the extension (the [setup] section of its script)
check "L2: yt_setup() installed with the extension" \
	test "$(pgq "$L2_DB" "select count(*) from pg_proc where proname = 'yt_setup'")" -ge 1
pgq "$L2_DB" "create table public.yx_l2_t (id int primary key, v text)" >/dev/null
pgq "$L2_DB" "select count(*) from yt_setup('public.yx_l2_t', '', true, '$YX_TARGET')" >/dev/null
check "L2: yx_l2_t carries the sync trigger" \
	test "$(pgq "$L2_DB" "select count(*) from pg_trigger where tgrelid = 'public.yx_l2_t'::regclass and tgname like 'zytsync\_%'")" = "1"
# ytserv reads module-A rows at start (as ../topology's register_table + restart_all)
xc systemctl restart ytserver
check "L2: ytserver active after the restart that loads the table's config" wait_active

if write_row "$L2_DB" 1 before-purge; then
	ok "L2: a local write through the extension works before the purge"
else
	bad "L2: a local write through the extension before the purge: ${WOUT:0:400}"
fi
check "L2: ...and the row reads back" \
	test "$(pgq "$L2_DB" "select v from public.yx_l2_t where id = 1")" = "before-purge"

# ── L5c: --batch again on the configured node ───────────────────────────────
echo "-- L5: --batch again on the configured node"
pid_before="$(main_pid)"
rows_before="$(pgq "$L2_DB" "select count(*) || '/' || coalesce(max(id), 0) from $YX_TARGET")"
yx 120 --batch -t "$YX_TARGET" -i "$L2_NODE" --db "$(db_url "$L2_DB")"; rc=$?
check "L5: --batch on a configured node exits 0 - setup cancelled, not failed (exit $rc)" [ "$rc" -eq 0 ]
says_why() { grep -q 'ytserver.service' "$OUT" && grep -q -- '--force' "$OUT"; }
same_pid() { [ -n "$pid_before" ] && [ "$pid_before" != 0 ] && [ "$(main_pid)" = "$pid_before" ]; }
check "L5: ...says why: it names the existing ytserver.service and --force" says_why
check "L5: ...left ytserver running and not restarted (MainPID ${pid_before:-none})" same_pid
same_rows() { local now; now="$(pgq "$L2_DB" "select count(*) || '/' || coalesce(max(id), 0) from $YX_TARGET")" || return 1; [ -n "$rows_before" ] && [ "$now" = "$rows_before" ]; }
check "L5: ...left the config table as it was (rows/max id ${rows_before:-?})" same_rows

# ── L2, part 2: purge and install again ─────────────────────────────────────
purge "L2"
check "L2: ytserver stopped by the purge" svc_inactive
offs="$(log_offsets)"
WERR=""
yx 600 -v --batch -t "$YX_TARGET" -i "$L2_NODE" --db "$(db_url "$L2_DB")"; rc=$?
check "L2: install after the purge exits 0 (exit $rc)" [ "$rc" -eq 0 ]
check "L2: ytserver active after the re-install" wait_active
if write_row "$L2_DB" 2 after-purge; then
	ok "L2: a local write through the extension works after purge + re-install"
else
	bad "L2: a local write through the extension after purge + re-install: ${WOUT:0:400}"
fi
check "L2: ...and the row reads back" \
	test "$(pgq "$L2_DB" "select v from public.yx_l2_t where id = 2")" = "after-purge"
# The stale-WAL symptom: it shows when the purge left /var/yaxaha behind
# (30_purge.sh checks that it does not).
newlog="$(log_since "$offs")"
check "L2: the ytserv log has lines since the re-install (what the next check reads)" test -n "$newlog"
subterm="$( { echo "$newlog"; echo "$WERR"; } | grep -m3 -E 'Sub-term .* already exists')"
check "L2: no 'Sub-term ... already exists' in the ytserv log or the writes since the re-install${subterm:+ - got: $subterm}" \
	test -z "$subterm"

# ── L3: --peers, --cluster and a bare --bind address ────────────────────────
#
# A bare `--bind <ip>` gets the default port, like a --peers line
# (yxctl/src/actions/config.rs bind_with_port): the node's own N-row is ip:7421.
echo "-- L3: --batch --peers <two names> --cluster <uuid> --bind <bare ip>"
purge "L3"
L3_DB=yx_l3
check "L3: fresh database $L3_DB" fresh_db "$L3_DB"
xc rm -rf /var/yaxaha
IP="$(xc hostname -I | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)"
check "L3: the container has an IPv4 address to bind" test -n "$IP"
L3_CLUSTER="$(xc cat /proc/sys/kernel/random/uuid)"
xc bash -c 'printf "%s\n" yx-peer-a.invalid yx-peer-b.invalid > /tmp/yx-peers'
# the node's own uuid as yxctl derives it with --peers and no -i: uuid v5 of the
# bind host in YAXAHA_NS (yxctl/src/consts.rs node_uuid)
SELF="$(python3 -c "import uuid,sys; print(uuid.uuid5(uuid.UUID('6a9f5c2e-1b3d-5e47-9a08-0bf99b3e0275'), sys.argv[1]))" "$IP" 2>/dev/null)"
check "L3: the node's derived uuid computed (python3 on the test host)" test -n "$SELF"
yx 600 -v --batch -t "$YX_TARGET" --db "$(db_url "$L3_DB")" \
	--peers /tmp/yx-peers --cluster "$L3_CLUSTER" --bind "$IP"; rc=$?
check "L3: install exits 0 (exit $rc)" [ "$rc" -eq 0 ]
self_row="$(pgq "$L3_DB" "select value from $YX_TARGET where module = 'N' and name = '$SELF'")"
echo "  N rows: $(pgq "$L3_DB" "select string_agg(name || '=' || value, ' ' order by id) from $YX_TARGET where module = 'N'")"
check "L3: the node's own N-row exists (name $SELF)" test -n "$self_row"
check "L3: the node's own N-row carries the port: expected [$IP:7421] got [$self_row]" \
	test "$self_row" = "$IP:7421"
check "L3: both --peers names have an N-row with the default port" \
	test "$(pgq "$L3_DB" "select count(*) from $YX_TARGET where module = 'N' and value in ('yx-peer-a.invalid:7421', 'yx-peer-b.invalid:7421')")" = "2"
check "L3: the cluster uuid is the one given with --cluster" \
	test "$(pgq "$L3_DB" "select value from $YX_TARGET where module = 'C' and name = 'cluster' order by id limit 1")" = "$L3_CLUSTER"
check "L3: ytserver active after the install (a bind address without a port would stop it starting)" wait_active

# ── L6: --users-db ──────────────────────────────────────────────────────────
#
# [dbreg] A users database beside the catalog (yt-pgxt combined-config.md, yxctl
# README "Users databases"). A missing one exits 33 without hanging - never
# created here; an existing one gets the extension, its tables registered in its
# OWN config table (none of the extension's), and ytserv replicates it
# (yt_info('U')); `--purge default --drop-extension` takes the extension out of
# every database ytserv replicates.
echo "-- L6: --batch --users-db"
purge "L6"
L6_DB=yx_l6
L6_APP=yx_l6_app
L6_MISSING=yx_l6_missing
check "L6: fresh database $L6_DB" fresh_db "$L6_DB"
pgq postgres "drop database if exists $L6_MISSING with (force)" >/dev/null
xc rm -rf /var/yaxaha
yx 600 -v --batch -t "$YX_TARGET" --db "$(db_url "$L6_DB")" --users-db "$L6_MISSING"; rc=$?
check "L6: --users-db naming a missing database exits 33 without hanging (exit $rc)" [ "$rc" -eq 33 ]
check "L6: ...and its message names it" grep -q "$L6_MISSING" "$OUT"
check "L6: ...and creates no database" db_absent "$L6_MISSING"
purge "L6b"
check "L6: fresh database $L6_DB" fresh_db "$L6_DB"
check "L6: fresh users database $L6_APP" fresh_db "$L6_APP"
pgq "$L6_APP" "create table public.yx_l6_t (id int primary key, v text)" >/dev/null
xc rm -rf /var/yaxaha
yx 600 -v --batch -t "$YX_TARGET" --db "$(db_url "$L6_DB")" --users-db "$L6_APP" --tables 'public.%'; rc=$?
check "L6: install with --users-db $L6_APP exits 0 (exit $rc)" [ "$rc" -eq 0 ]
check "L6: the extension in $L6_APP" \
	test "$(pgq "$L6_APP" "select count(*) from pg_extension where extname = 'yaxaha'")" = "1"
check "L6: yx_l6_t registered in $L6_APP's own config table" \
	test "$(pgq "$L6_APP" "select count(*) from public.yt_config where module = 'A' and name = 'public.yx_l6_t'")" = "1"
check "L6: ...with its sync trigger" \
	test "$(pgq "$L6_APP" "select count(*) from pg_trigger where tgrelid = 'public.yx_l6_t'::regclass and tgname like 'zytsync\_%'")" = "1"
check "L6: none of the extension's own tables registered there" \
	test "$(pgq "$L6_APP" "select count(*) from public.yt_config where module = 'A' and name in ('public.yt_config', 'public.yt_alert', 'public.yt_job', 'public.yt_stat')")" = "0"
check "L6: its config table keyed by (module, name)" \
	test "$(pgq "$L6_APP" "select count(*) from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey) where i.indrelid = 'public.yt_config'::regclass and i.indisprimary and a.attname in ('module', 'name')")" = "2"
# ytserv takes the database in by itself, not at once: the announce (yt_info('U+'),
# made by the extension's script and by yxctl) has a pass probe it every second for
# 30 s - yxctl says "does not replicate ... yet" when it is not in by its end
for _ in $(seq 1 20); do
	u="$(pgq "$L6_DB" "select x.value from json_to_recordset(yt_info('U')) as x(name text, value text) where x.name = '$L6_APP'")"
	[ "${u%% *}" = "participant" ] && break
	sleep 2
done
check "L6: ytserv replicates $L6_APP within the announce's 30 s (yt_info('U'): $u)" test "${u%% *}" = "participant"
yx 120 --purge default --drop-extension -d "$L6_DB"; rc=$?
check "L6: --purge default --drop-extension exits 0 (exit $rc)" [ "$rc" -eq 0 ]
check "L6: ...the extension is gone from $L6_APP" \
	test "$(pgq "$L6_APP" "select count(*) from pg_extension where extname = 'yaxaha'")" = "0"
check "L6: ...and from $L6_DB" \
	test "$(pgq "$L6_DB" "select count(*) from pg_extension where extname = 'yaxaha'")" = "0"
check "L6: ...and the purge stopped ytserver" svc_inactive

if [ "$failed" -gt 0 ]; then
	echo "Negative + repeat installs: $failed check(s) FAILED" >&2
	exit 1
fi
echo "Negative + repeat installs: PASS"
