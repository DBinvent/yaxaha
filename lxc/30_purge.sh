#!/usr/bin/env bash
# Purge + clean re-install cycle: sudo yxctl --purge default must leave the host
# clean enough for a fresh --batch install to succeed (mode 1 + purge docs).
#
# What purge promises, and so what is asserted (yxctl README "Purge", en.yml
# arg-purge, yxctl/src/main.rs uninstall()):
#   - stop and disable ytserver, delete its unit                       (coded)
#   - delete yaxaha.so from `pg_config --pkglibdir`, yaxaha.control and
#     yaxaha--0.5.sql from `pg_config --sharedir`/extension              (coded)
#   - delete the working directory with the cluster WAL (/var/yaxaha)  (coded)
#   - exit 0 (it is the package pre-uninstall script)
# Purge does not touch the database. The cleanup it prints for that (`psql
# command> "..."`) is run as printed, after the purge - the library and the
# service are gone by then - and must remove the extension, the sync triggers
# and the config table.
#
# A failed purge check does not stop the script: the -U ytsvc re-install below is
# its own test. Every failure is counted and the script exits 1 at the end.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

failed=0
# check <description> <command...>: like assert, but carries on
check() {
	local desc="$1"; shift
	if "$@"; then
		echo "  OK: $desc"
	else
		echo "  FAIL: $desc" >&2
		failed=$((failed + 1))
	fi
}
# one value from the install database; fails when psql does, so a check on an
# empty answer cannot pass because PostgreSQL did not answer
pgval() { xc sudo -u postgres psql -X -tAq -v ON_ERROR_STOP=1 -c "$1"; }
absent() { ! xc test -e "$1"; }
present() { xc test -e "$1"; }
no_extension() { local v; v="$(pgval "select 1 from pg_extension where extname = 'yaxaha'")" || return 1; [ -z "$v" ]; }
no_config_table() { local v; v="$(pgval "select to_regclass('$YX_TARGET') is null")" || return 1; [ "$v" = "t" ]; }
no_sync_trigger() { local v; v="$(pgval "select count(*) from pg_trigger where tgname like 'zytsync\_%'")" || return 1; [ "$v" = "0" ]; }

# where `--purge default` resolves the extension files: pg_config, as yxctl does
# (cli.rs, pe_def). Read before the purge, and the files must be there to begin
# with - "deleted" is vacuous for a file that never existed.
pkglib="$(xc pg_config --pkglibdir 2>/dev/null || true)"
share="$(xc pg_config --sharedir 2>/dev/null || true)/extension"
check "pg_config answers in the container (pkglibdir=[$pkglib])" test -n "$pkglib"
check "before the purge: yaxaha.so installed in $pkglib" present "$pkglib/yaxaha.so"
check "before the purge: yaxaha.control installed in $share" present "$share/yaxaha.control"
check "before the purge: the working directory /var/yaxaha exists" present /var/yaxaha

echo "Purging..."
rc=0
purge_out="$(xc timeout -k 10 120 yxctl --purge default 2>&1)" || rc=$?
echo "$purge_out"
check "yxctl --purge default exits 0 (exit $rc; 124/137 = it hung)" test "$rc" -eq 0

check "ytserver stopped" \
	bash -c "! lxc exec $YX_CONTAINER -- systemctl is-active ytserver >/dev/null 2>&1"
# --purge must stop AND remove the service control: unit file gone, systemd reloaded
check "ytserver unit file deleted" \
	bash -c "! lxc exec $YX_CONTAINER -- test -f /lib/systemd/system/ytserver.service"
check "extension library deleted: $pkglib/yaxaha.so" absent "$pkglib/yaxaha.so"
check "extension control file deleted: $share/yaxaha.control" absent "$share/yaxaha.control"
check "extension script deleted: $share/yaxaha--0.5.sql" absent "$share/yaxaha--0.5.sql"
# a stale WAL is what a re-install on the same box would trip over ("Sub-term
# ... already exists"; 50_negative.sh L2 checks that end to end)
check "working directory /var/yaxaha (cluster WAL) deleted" absent /var/yaxaha

# purge does not touch the DB: clean it with the command the purge printed, in
# the install database (20_batch.sh's --db)
cleanup="$(sed -n 's/.*psql command> "\([^"]*\)".*/\1/p' <<< "$purge_out" | head -1)"
check "the purge prints the DB cleanup command ([$cleanup])" test -n "$cleanup"
echo "Documented DB cleanup: $cleanup"
rc=0
xc sudo -u postgres psql -X -v ON_ERROR_STOP=1 -c "$cleanup" || rc=$?
check "the documented DB cleanup succeeds after the purge (psql exit $rc)" test "$rc" -eq 0
check "after the DB cleanup: no zytsync_ trigger left" no_sync_trigger
check "after the DB cleanup: extension yaxaha dropped" no_extension
check "after the DB cleanup: config table $YX_TARGET dropped" no_config_table

echo "Re-installing after purge with -U ytsvc (service role auto-creation)..."
# the -U scenario: OS user exists, DB role does not — yxctl must create the role
# (as postgres, no password), run the service as ytsvc, and connect via peer auth
xc bash -c "id -u ytsvc >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin ytsvc"
assert "re-install --batch -U ytsvc exits 0" \
	xc yxctl -v --batch -t "$YX_TARGET" -U ytsvc \
		--db "postgresql://postgres@localhost/postgres?host=/var/run/postgresql"

assert "role ytsvc created" \
	xc sudo -u postgres psql -tc "select 1 from pg_roles where rolname = 'ytsvc'"
# the role's own database: plain `psql` as the user defaults to it
assert "database ytsvc created" \
	xc sudo -u postgres psql -tc "select 1 from pg_database where datname = 'ytsvc'"
assert "plain psql works for ytsvc" \
	xc sudo -u ytsvc psql -tc "select current_database()"
assert "ytserver active after re-install" xc systemctl is-active ytserver
# by MainPID, not `ps -C ytserv`: the comm name of a variant binary is truncated
# (ytserv-glibc2_35 → ytserv-glibc2_3) and would not match by name
assert "ytserver runs as ytsvc" \
	bash -c "lxc exec $YX_CONTAINER -- bash -c 'ps -o user= -p \$(systemctl show -n0 -p MainPID --value ytserver)' | grep -q ytsvc"
# end-to-end as the service user: the extension's yt_info('e') curls the running
# ytserver — proves the service is up AND accessible for that user (retry the
# startup window: the service may still be settling after the PG restart)
assert "yt_info('e') works for ytsvc (install db)" bash -c "
	for i in 1 2 3 4 5; do
		lxc exec $YX_CONTAINER -- sudo -u ytsvc psql -d postgres -tc \"select * from yt_info('e')\" >/dev/null 2>&1 && exit 0
		sleep 3
	done
	exit 1"
# extensions are per-database: the user's OWN db (plain psql, no -d) must have
# the extension too, or yt_info() does not exist there
assert "yt_info('e') works for ytsvc (own db, plain psql)" \
	xc sudo -u ytsvc psql -tc "select * from yt_info('e')"

if [ "$failed" -gt 0 ]; then
	echo "Purge + re-install (-U ytsvc): $failed purge check(s) FAILED" >&2
	exit 1
fi
echo "Purge + re-install (-U ytsvc): PASS"
