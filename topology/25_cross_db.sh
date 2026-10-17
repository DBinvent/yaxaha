#!/usr/bin/env bash
# [cross-db] Instance config in `postgres`; table config and rppd config in a
# users database.
#
# ## The layout under test
#
#   postgres  (ytserv's STARTUP database)  public.yt_config: the N roster, the C
#             cluster knobs (min_cluster_size, serve_etcd, serve_rppd, cluster
#             uuid, az), the Z az map, and the config table's own sync row.
#             Nothing else of ours - only same-named EMPTY decoy tables (below).
#
#   $APPDB    (a users database)           the extension, the synced tables, its
#             OWN public.yt_config holding module-'A' rows only, and the rppd_*
#             tables (rppd_config, rppd_function, rppd_function_log, rppd_cron).
#
# ytserv reads module-'A' rows from EVERY database's config table at startup
# and keys them `A.<db>.<schema>.<table>` (ytserv/src/yt_config.rs, "[C4] Table
# config is PER DATABASE"), and the trigger sends its database with every row
# (ytpgc/src/yaxaha.c, get_database_name). So the table half of this layout is
# meant to work, and so is the rppd half since ytserv 0.20.57 - see below.
#
# ## Its own fixture
#
# Three containers of its own ($XDB_NODES, default xdb1 xdb2 xdb3) on $YX_NET
# from $YX_IMAGE, with their own cluster uuid and roster, started with
# DB=postgres: node-entrypoint.sh then skips createdb (postgres exists), creates
# the extension - and with it public.yt_config - in postgres, waits for
# `cfg_ready` THERE, and starts ytserv with
# `postgresql://postgres@localhost/postgres?host=/var/run/postgresql`. That is
# the whole mechanism: nothing in the image had to change. Fixture A (n1..n7)
# is not touched, and the containers go in an EXIT trap (XDB_KEEP=1 keeps them).
#
#   xdb1 az=top (tier 0)    xdb2, xdb3 az=east (tier 1)
#
# The az split exists for check 3: it makes a module-'A' change observable.
#
# Same-named tables public.cx_t/cx_r/cx_py/cx_sink are created in postgres too,
# EMPTY and unregistered. Without them "the rows did not land in postgres" is
# unfalsifiable - a write applied to the wrong database would just error.
#
# ## Checks
#
#   1  the cluster comes up from the instance config in postgres: ytserv got the
#      postgres URL, loaded the config table's own row as A.postgres.*, one
#      leader, every node Good.
#   2  appdb.cx_t (A row in appdb, trigger in appdb) replicates a write from a
#      follower to every node's appdb - NOT into postgres's cx_t - and leaves no
#      prepared transaction behind in appdb.
#   3  a module-'A' change in appdb's yt_config takes effect: cx_r goes from
#      unrouted (row 1 reaches all three) to `az=east` (row 2 reaches xdb2+xdb3,
#      NOT xdb1). Changed the startup way - row written, synchronized restart -
#      which is the documented path the rest of this suite uses for A rows.
#   4  a python function in appdb.rppd_function on appdb.cx_py (on_commit_python)
#      fires on a cluster commit: one marker row in appdb.cx_sink on the rppd
#      master (= the cluster leader, state/mod.rs sync_rppd_config), exactly
#      once cluster-wide, and appdb.rppd_function_log records it.
#   5  no leak either way: postgres has no A row and no in-memory A.postgres.*
#      key for appdb's tables, no rppd function/log rows, and its decoys are
#      empty; appdb's yt_config holds nothing but A rows (the cluster ran without
#      any C/N/Z row there).
#   6  after a restart of ytserv on every node, 1-4 again with fresh ids.
#   7  [dbreg] yt_info('U'): postgres the catalog, appdb a participant, a database
#      without the extension skipped and never pooled (B10); a database whose
#      extension comes at runtime participates within seconds and replicates, no
#      restart; skipped by `databases = *, -app2` (written locally) it is let go
#      of, can be dropped (B9), and leaves the list.
#   8  [natural-key] a cluster insert from the leader applies on a node that wrote
#      rows of its own (trigger off) first; a value UPDATE on the leader takes
#      effect on the leader too (yt_info('c:tcp_timeout_ms')).
#   9  [D4] appdb's own def_sql_timeout_sec is its tables' fallback and theirs only
#      (yt_info('c:..@appdb'), a: source.timeout_sec); a catalog setting written in
#      appdb is ignored (yt_info('U') ignored=1) and changes nothing.
#  10  [D12] the yt_config_effective view in appdb; yxctl --config-lint finds the
#      misplaced row (exit 34) and no longer once it is gone.
#  11  [D5] C recon_batch_max@<uuid> written on the leader applies on that node
#      alone; deleted, the node takes the plain value again.
#  13  [D11] one rppd per database (yt-pgxt combined-config.md D11, 2026-10-16, not
#      run yet): app4 listed in C rppd_dbs - ytserv creates rppd's tables there by
#      SchemaGuard; a function in app4 starts an instance of its own (its queues
#      /q/app4/...), which runs it on a commit of an app4 table - on the leader,
#      once, recorded in app4's rppd_function_log - and appdb's instance does not
#  12  a users database (app3) with a synced config table: a catalog setting
#      written there is refused and stored nowhere, a database setting applies
#      live everywhere; yxctl --db-remove on the leader detaches it on every
#      node, which then lets it be dropped.
#
# ## Gaps this found, fixed in ytserv 0.20.57
#
# CHECK 4 - rppd read only ytserv's startup database (`impl Into<RppdConfig>`
# handed it cfg_db_url, .../postgres here), and the roster sync wrote rppd_config
# there too: with the rppd tables in appdb, no roster, no master, no function.
# Now ytserv resolves the rppd database at startup (rmc.rs resolve_rppd_db): the
# C row `rppd_db` when set, else the startup database when it has the rppd tables,
# else the one database that has them - appdb here, with no setting at all.
#
# CHECKS 2, 3, 6 - a party PREPAREs an appdb transaction on an appdb session, and
# the COMMIT/ROLLBACK PREPARED that follows ran on a startup-database connection,
# which PostgreSQL refuses ("prepared transaction belongs to another database").
# Every finish by name now looks the transaction up in pg_prepared_xacts and runs
# in its own database (ycluster/core.rs finish_by_gid) - the session-lost commit
# and rollback, the in-doubt recovery, and the inherited prepares of a copy.
#
# NOT covered: a LIVE (no-restart) A-row change in appdb - its yt_config is not
# itself synced here. (complete_cfg_update used to look an UPDATE's name/module up
# by id in the startup database - another row - and reads its own now, 0.20.57.)
#
# Standalone: needs the node image (00_build.sh) and REPO_ROOT's release yxctl
# for --encode-table-cfg, not a running fixture A.

# ── this fixture's settings, BEFORE env.sh ──────────────────────────────────
#
# EXPORTED, not just set: env.sh restores only exported variables over .env,
# and run_a.sh exports its own YX_NODES / YX_SPARE_NODES - which must lose here.
XDB_NODES="${XDB_NODES:-xdb1 xdb2 xdb3}"
read -r -a _xn <<< "$XDB_NODES"
if [ "${#_xn[@]}" -ne 3 ]; then
	echo "XDB_NODES must name exactly three containers, got [$XDB_NODES]" >&2
	exit 1
fi
export YX_NODES="$XDB_NODES"
export YX_AZ="${_xn[0]}=top,${_xn[1]}=east,${_xn[2]}=east"
export YX_TIER="top=0,east=1"
export YX_SPARE_NODES=""
export YX_DB=postgres
# The startup loader reads the SAME-named table in every database, and the
# extension creates public.yt_config in each - so this is not a free choice.
export YX_CFG=public.yt_config
# its own cluster: a shared uuid would let these three peer with fixture A
export YX_CLUSTER_UUID="${XDB_CLUSTER_UUID:-7a1c0000-0000-5000-8000-000000000025}"
# env.sh would otherwise sweep NODES for prepared xacts before they exist
export YX_NO_SWEEP=1
APPDB="${XDB_APPDB:-appdb}"

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== cross-db: instance config in postgres, table + rppd config in $APPDB =="

[ "$APPDB" != "postgres" ] || { echo "XDB_APPDB must not be postgres" >&2; exit 1; }
[ "${#NODES[@]}" -eq 3 ] || { echo "env.sh did not take YX_NODES=[$YX_NODES]" >&2; exit 1; }

TOP="${_xn[0]}"
EAST1="${_xn[1]}"

cleanup() {
	if [ -n "${XDB_KEEP:-}" ]; then
		echo "  XDB_KEEP set: leaving ${NODES[*]} running"
		return 0
	fi
	local n
	for n in "${NODES[@]}"; do rh "docker rm -f $n >/dev/null 2>&1; true" || true; done
	echo "  removed ${NODES[*]}"
}
trap cleanup EXIT

# ── helpers ─────────────────────────────────────────────────────────────────

# psql in the USERS database. Mirrors env.sh's q(), plus a statement_timeout:
# ytserv calls from the extension carry no deadline of their own, and if the
# cross-database 2PC prediction above is right a cluster commit here can wait on
# an orphaned prepared xact. A bounded failure beats a run that never ends.
aq() { # aq <node> <sql>
	local node="$1" sql="$2"
	local opt="-c lock_timeout=30s -c statement_timeout=${XDB_STMT_TIMEOUT:-120s}"
	if [ "$YX_HOST" = "local" ]; then
		printf '%s\n' "$sql" | docker exec -i -u postgres -e PGOPTIONS="$opt" "$node" \
			psql -tAq -d "$APPDB" 2>/dev/null || true
	else
		printf '%s\n' "$sql" | "${YX_SSH[@]}" "$YX_HOST" \
			"docker exec -i -u postgres -e PGOPTIONS='$opt' $node psql -tAq -d $APPDB" 2>/dev/null || true
	fi
}
# psql in postgres, the startup database
pq() { q "$1" "$2" postgres || true; }

# module-'A' row in APPDB's config table. That table has no sync trigger in
# this layout, so this is a plain local write; the trigger switch is only so a
# future layout that syncs it does not turn this into a leader-gated write.
app_cfg_write() { # <node> <name> <module> <value>
	aq "$1" "alter table public.yt_config disable trigger user;
	         delete from public.yt_config where module='$3' and name='$2';
	         insert into public.yt_config (name,module,value) values ('$2','$3','$4');
	         alter table public.yt_config enable trigger user;" >/dev/null
}

# env.sh's register_table, in APPDB: trigger AND A row, both in the users DB
app_register() { # <node> <schema.table> [A value]
	local n="$1" rel="$2" val="${3:-}" tname
	tname="zytsync_${rel//./_}_trigger"
	aq "$n" "drop trigger if exists $tname on $rel;
	         create trigger $tname after insert or update or delete on $rel
	         for each row execute procedure yt_synchronize();" >/dev/null
	app_cfg_write "$n" "$rel" A "$val"
}

# env.sh's wait_writable, in APPDB. Fresh negative ids per attempt; `base`
# differs per phase so a probe left behind by one phase cannot collide.
app_wait_writable() { # <writer> <witness> <table> <base>
	local w="$1" wit="$2" rel="$3" base="$4" i id
	for i in $(seq 1 24); do
		id=$((base - i))
		aq "$w" "begin; insert into $rel values ($id,'probe'); select yt_complete(true); commit;" >/dev/null
		if [ "$(aq "$wit" "select count(*) from $rel where id=$id")" = "1" ]; then
			aq "$w" "begin; delete from $rel where id < 0; select yt_complete(true); commit;" >/dev/null
			return 0
		fi
		sleep 5
	done
	return 1
}

# Replaces env.sh's clear_prepared, which restart_all calls by name. That one
# runs ROLLBACK PREPARED from YX_DB for every gid in pg_prepared_xacts - and
# PostgreSQL refuses it for a gid prepared in another database, so every orphan
# in APPDB would survive the reset and hold its locks into the next phase.
clear_prepared() {
	local n g d
	for n in "${NODES[@]}"; do
		while IFS='|' read -r g d; do
			[ -n "$g" ] || continue
			q "$n" "rollback prepared '$g'" "$d" >/dev/null || true
			echo "  reset: rolled back orphaned prepared xact $g in $n/$d"
		done < <(pq "$n" "select gid, database from pg_prepared_xacts")
	done
}

# The node whose own yt_info('O') ends in "Leader" with no colon. A follower
# says "Leader: <uuid8>:<host>", and a node with none says "Leader: None!" -
# which env.sh's await_cluster (`*Leader*`) counts as settled, so it is not
# used here.
x_leader() {
	local n
	for n in "${NODES[@]}"; do
		case "$(info "$n" O cluster || true)" in *Leader) printf '%s' "$n"; return 0;; esac
	done
}

x_await_leader() {
	local i n o leaders none
	for i in $(seq 1 30); do
		leaders=0; none=0
		for n in "${NODES[@]}"; do
			o="$(info "$n" O cluster || true)"
			case "$o" in
				*Leader) leaders=$((leaders + 1)) ;;
				*"Leader: None"*) none=$((none + 1)) ;;
				*"Leader: "*) : ;;
				*) none=$((none + 1)) ;;
			esac
		done
		[ "$leaders" -eq 1 ] && [ "$none" -eq 0 ] && return 0
		sleep 5
	done
	return 1
}

# This node's own PeerState as yt_info('E') prints it: the row named after the
# node's uuid is "<uuid8>:<bind>:<port>, <state>, <load>, Pings: ...", where
# state is Good / Leader / Spare±: ... (state/peer.rs Display for PeerState).
node_state() {
	q "$1" "select yt_info('E')" 2>/dev/null | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
me = next((r.get("value", "") for r in rows if r.get("name") == "self"), "")
for r in rows:
    if me and r.get("name") == me:
        parts = [p.strip() for p in r.get("value", "").split(",")]
        print(parts[1] if len(parts) > 1 else "")
        break
' || true
}

# sum of one integer query over every node's APPDB
sum_app() {
	local n v s=0
	for n in "${NODES[@]}"; do
		v="$(aq "$n" "$1")"
		s=$((s + ${v:-0}))
	done
	printf '%s' "$s"
}

# writer = a FOLLOWER (the origin the leader gate and 2PC party are about),
# witness = any other node
pick_roles() {
	local n
	# restart_all's fixed sleep is not an election; wait for one (check_up grades it)
	x_await_leader || true
	L="$(x_leader)"
	W=""; WIT=""
	for n in "${NODES[@]}"; do [ "$n" != "$L" ] && { W="$n"; break; }; done
	for n in "${NODES[@]}"; do [ "$n" != "$W" ] && { WIT="$n"; break; }; done
	echo "  leader=${L:-none}  writer=$W  witness=$WIT  east writer=$EAST1"
}

# ── the checks, as functions: 6 runs 1-4 again ──────────────────────────────

check_up() { # <tag>
	local tag="$1" n o seen="" distinct bad_states i s
	if x_await_leader; then
		ok "$tag: exactly one leader, and no node is without one"
	else
		bad "$tag: the cluster never settled on one leader from the postgres config"
	fi
	for n in "${NODES[@]}"; do
		o="$(info "$n" O cluster || true)"
		printf "     %-5s %s\n" "$n" "${o:-<no answer>}"
		case "$o" in
			*Leader) : ;;
			*"Leader: "*) seen="$seen${o##*Leader: }"$'\n' ;;
		esac
	done
	distinct="$(printf '%s' "$seen" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
	check "$tag: every follower names the same leader" "1" "$distinct"
	bad_states=""
	for i in $(seq 1 12); do
		bad_states=""
		for n in "${NODES[@]}"; do
			s="$(node_state "$n")"
			case "$s" in Good|Leader) : ;; *) bad_states="$bad_states $n=[${s:-?}]" ;; esac
		done
		[ -z "$bad_states" ] && break
		sleep 5
	done
	check "$tag: every node is Good (or the Leader)" "" "$bad_states"
}

check_replication() { # <tag> <id>
	local tag="$1" id="$2" n all i left
	aq "$W" "begin; insert into cx_t values ($id,'from-$W'); select yt_complete(true); commit;" >/dev/null
	for i in $(seq 1 12); do
		all=1
		for n in "${NODES[@]}"; do
			[ "$(aq "$n" "select count(*) from cx_t where id=$id")" = "1" ] || all=0
		done
		[ "$all" = "1" ] && break
		sleep 5
	done
	for n in "${NODES[@]}"; do
		check "$tag: $APPDB.cx_t row $id from $W reached $n" "from-$W" \
			"$(aq "$n" "select v from cx_t where id=$id")"
	done
	for n in "${NODES[@]}"; do
		check "$tag: postgres.public.cx_t on $n (same name, unregistered) stayed empty" "0" \
			"$(pq "$n" "select count(*) from cx_t")"
	done
	# A transient prepare is normal mid-commit, so it gets time to finish.
	local v
	for i in $(seq 1 6); do
		left=0
		for n in "${NODES[@]}"; do
			v="$(pq "$n" "select count(*) from pg_prepared_xacts where database='$APPDB'")"
			left=$((left + ${v:-0}))
		done
		[ "$left" = "0" ] && break
		sleep 5
	done
	check "$tag: no 2PC transaction left PREPARED in $APPDB on any node (a nonzero count \
is the party's COMMIT PREPARED run from the startup database - ycluster/core.rs \
cluster_event_complete)" "0" "$left"
}

check_routing() { # <tag> <id> all|east
	local tag="$1" id="$2" mode="$3" n i all holds
	for n in "${NODES[@]}"; do
		check "$tag: ytserv on $n holds cx_r's config under $APPDB" "A.$APPDB.public.cx_r" \
			"$(info "$n" "a:$APPDB.public.cx_r" table || true)"
	done
	if [ "$mode" = "east" ]; then
		for n in "${NODES[@]}"; do
			check "$tag: the in-memory cx_r config on $n is $APPDB's az=east row" "$AZCFG" \
				"$(info "$n" "a:$APPDB.public.cx_r" raw || true)"
		done
	fi
	aq "$EAST1" "begin; insert into cx_r values ($id,'from-$EAST1'); select yt_complete(true); commit;" >/dev/null
	for i in $(seq 1 12); do
		all=1
		for n in "${NODES[@]}"; do
			[ "$mode" = "east" ] && [ "${NODE_AZ[$n]}" != "east" ] && continue
			[ "$(aq "$n" "select count(*) from cx_r where id=$id")" = "1" ] || all=0
		done
		[ "$all" = "1" ] && break
		sleep 5
	done
	sleep 3   # a row that should NOT arrive gets the same chance to show up
	for n in "${NODES[@]}"; do
		holds=1
		[ "$mode" = "east" ] && [ "${NODE_AZ[$n]}" != "east" ] && holds=0
		if [ "$holds" = "1" ]; then
			check "$tag: cx_r row $id reached $n (az ${NODE_AZ[$n]})" "from-$EAST1" \
				"$(aq "$n" "select v from cx_r where id=$id")"
		else
			check "$tag: cx_r row $id did NOT reach $n (az ${NODE_AZ[$n]}) - $APPDB's A row \
routes cx_r to east" "" "$(aq "$n" "select v from cx_r where id=$id")"
		fi
	done
}

check_rppd() { # <tag> <id>
	local tag="$1" id="$2" n i seen tot_b tot_a dm dt log_b log_d err
	local -A before=()
	[ -n "$L" ] || { bad "$tag: no leader, so no rppd master to check"; return 0; }
	for n in "${NODES[@]}"; do before[$n]="$(aq "$n" "select count(*) from cx_sink")"; before[$n]="${before[$n]:-0}"; done
	tot_b="$(sum_app "select count(*) from cx_sink")"
	log_b="$(sum_app "select count(*) from rppd_function_log")"

	aq "$W" "begin; insert into cx_py values ($id,'py-$id'); select yt_complete(true); commit;" >/dev/null
	# the trigger for the function must itself have committed, or "it did not
	# run" would be about the write, not about rppd
	seen=0
	for i in $(seq 1 6); do
		[ "$(aq "$WIT" "select count(*) from cx_py where id=$id")" = "1" ] && { seen=1; break; }
		sleep 5
	done
	check "$tag: the write to $APPDB.cx_py that should fire the function committed and replicated" "1" "$seen"

	for i in $(seq 1 6); do
		tot_a="$(sum_app "select count(*) from cx_sink")"
		[ "$tot_a" -gt "$tot_b" ] && break
		sleep 5
	done
	sleep 3   # a second (duplicate) run gets the chance to land too
	tot_a="$(sum_app "select count(*) from cx_sink")"
	dt=$((tot_a - tot_b))
	dm="$(aq "$L" "select count(*) from cx_sink")"
	dm=$(( ${dm:-0} - ${before[$L]} ))
	check "$tag: the python function ran on the rppd master ($L): one marker row in its \
$APPDB.cx_sink [the rppd database resolved to appdb - ytserv 0.20.57, see the header]" "1" "$dm"
	check "$tag: ...and exactly once cluster-wide (marker rows added, all nodes)" "1" "$dt"

	log_d=$(( $(sum_app "select count(*) from rppd_function_log") - log_b ))
	if [ "$log_d" -ge 1 ]; then
		ok "$tag: $APPDB.rppd_function_log records the run ($log_d row(s))"
		err="$(aq "$L" "select coalesce(error_msg,'<none>') from rppd_function_log order by id desc limit 1")"
		check "$tag: ...with no error" "<none>" "$err"
	else
		bad "$tag: nothing new in $APPDB.rppd_function_log - the dispatch never reached \
an rppd that reads $APPDB"
	fi

	if [ "$dt" -ne 1 ]; then
		# not graded: where the runtime actually looked
		echo "     diagnostics:"
		echo "       rppd tables in postgres on $L: $(pq "$L" "select coalesce(string_agg(relname, ','), 'none') from pg_class where relkind='r' and relname like 'rppd\_%'")"
		echo "       $APPDB.rppd_config on $L: $(aq "$L" "select coalesce(string_agg(host || case when master then '*' else '' end, ' '), 'empty') from rppd_config")"
		echo "       postgres decoy cx_sink rows (a run against the wrong DB): $(pq "$L" "select count(*) from cx_sink")"
		{ logs_all | { grep -iE 'rppd|\[py\]|python|\[job\]' || true; } | tail -6 | sed 's/^/       log: /'; } || true
	fi
}

check_leaks() {
	local n t v mem rp ex c
	for n in "${NODES[@]}"; do
		check "5: postgres.yt_config on $n has no A row for $APPDB's tables" "0" \
			"$(pq "$n" "select count(*) from public.yt_config where module='A'
			            and (name like 'public.cx\_%' or name like 'public.rppd\_%')")"
		mem=""
		for t in cx_t cx_r cx_py; do
			v="$(info "$n" "a:postgres.public.$t" table || true)"
			[ -n "$v" ] && mem="$mem $v"
		done
		check "5: ytserv on $n attributes none of $APPDB's tables to postgres in memory" "" "$mem"
		rp=0
		for t in rppd_function rppd_function_log rppd_cron; do
			ex="$(pq "$n" "select to_regclass('public.$t') is not null")"
			if [ "$ex" = "t" ]; then
				c="$(pq "$n" "select count(*) from public.$t")"
				rp=$((rp + ${c:-0}))
			fi
		done
		check "5: postgres on $n holds no rppd function or log rows" "0" "$rp"
		check "5: postgres's same-named decoys on $n are all still empty" "0" \
			"$(pq "$n" "select (select count(*) from cx_t) + (select count(*) from cx_r)
			                 + (select count(*) from cx_py) + (select count(*) from cx_sink)")"
		check "5: $APPDB.yt_config on $n holds table config only - no C/N/Z or runtime row \
was needed or written there" "0" \
			"$(aq "$n" "select count(*) from public.yt_config where module <> 'A'")"
	done
}

# ── table configs ───────────────────────────────────────────────────────────
AZCFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'az=east' 2>/dev/null | tail -1 || true)"
PYCFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'on_commit_python' 2>/dev/null | tail -1 || true)"
[ -n "$AZCFG" ] && ok "az=east encodes to a table config" \
	|| bad "--encode-table-cfg 'az=east' produced nothing (is REPO_ROOT's release yxctl built?)"
[ -n "$PYCFG" ] && ok "on_commit_python encodes to a table config" \
	|| bad "--encode-table-cfg 'on_commit_python' produced nothing"

# ── fixture: three nodes, startup database = postgres ───────────────────────
rh "docker network inspect $YX_NET >/dev/null 2>&1 || docker network create $YX_NET >/dev/null" || true

echo "Starting ${NODES[*]} (DB=postgres)..."
for n in "${NODES[@]}"; do
	u="$(node_uuid "$n")"
	rh "docker rm -f $n >/dev/null 2>&1; true" || true
	if ! rh "docker run -d --name $n --hostname $n --network $YX_NET \
		-e NODE_UUID=$u -e DB=postgres -e CFG_TABLE=$YX_CFG ${YX_COV_MOUNT:-} $YX_IMAGE >/dev/null"; then
		bad "docker run $n from $YX_IMAGE failed"
		summary
	fi
done

# `select 1` in postgres answers BEFORE the entrypoint has created the
# extension there (with DB=yxtopo, 10_up's wait gets that ordering for free from
# createdb). Wait for pg_setup.sql's last object instead: then yt_config exists
# and the entrypoint is parked on cfg_ready.
echo "Waiting for the entrypoint to set up postgres..."
for n in "${NODES[@]}"; do
	r=""
	for _ in $(seq 1 60); do
		r="$(pq "$n" "select count(*) from pg_trigger where tgname='yt_join_gate'")"
		[ "$r" = "1" ] && break
		sleep 2
	done
	c="$(pq "$n" "select to_regclass('$YX_CFG') is not null")"
	printf "  %-5s yt_config in postgres=%s pg_setup=%s\n" "$n" "${c:-?}" "${r:-?}"
	[ "$c" = "t" ] || { bad "$n: the entrypoint never created $YX_CFG in postgres - see docker logs $n"; summary; }
done

echo "Writing the INSTANCE config into postgres (N, C, Z)..."
for n in "${NODES[@]}"; do
	sql="delete from $YX_CFG where module in ('N','Z');
	     delete from $YX_CFG where module='C' and name in ('min_cluster_size','log_level','cfg_ready',
	         'az','serve_etcd','serve_rppd','cluster','tcp_timeout_ms');"
	for p in "${NODES[@]}"; do
		sql+="insert into $YX_CFG (name,module,value) values ('$(node_uuid "$p")','N','$p:$YX_PORT');"
	done
	sql+="insert into $YX_CFG (name,module,value) values ('min_cluster_size','C','${#NODES[@]}');"
	# rppd embedded needs the embedded etcd; serve_rppd is off by default (rmc.rs)
	sql+="insert into $YX_CFG (name,module,value) values ('serve_etcd','C','true');"
	sql+="insert into $YX_CFG (name,module,value) values ('serve_rppd','C','true');"
	sql+="insert into $YX_CFG (name,module,value) values ('cluster','C','$YX_CLUSTER_UUID');"
	sql+="insert into $YX_CFG (name,module,value) values ('log_level','C','warning');"
	sql+="insert into $YX_CFG (name,module,value) values ('tcp_timeout_ms','C','2000');"
	for p in "${NODES[@]}"; do
		sql+="insert into $YX_CFG (name,module,value) values ('$(node_uuid "$p")','Z','${NODE_AZ[$p]}');"
	done
	for az in "${!AZ_TIER[@]}"; do
		sql+="insert into $YX_CFG (name,module,value) values ('$az.tier','Z','${AZ_TIER[$az]}');"
	done
	sql+="insert into $YX_CFG (name,module,value) values ('az','C','${NODE_AZ[$n]}');"
	pq "$n" "$sql" >/dev/null
	# the decoys: same names and columns as appdb's tables, never registered
	pq "$n" "create table if not exists cx_t (id bigint primary key, v text);
	         create table if not exists cx_r (id bigint primary key, v text);
	         create table if not exists cx_py (id bigint primary key, v text);
	         create table if not exists cx_sink (id serial primary key, data text);" >/dev/null
done

# rppd schema: yxctl/src/actions/rppd_schema.rs, the four tables `yxctl --batch`
# creates - here in the USERS database, which is the point of this test.
RPPD_DDL="
create table if not exists rppd_config (
    id serial primary key,
    host varchar(64) not null unique,
    host_name varchar(64) not null unique,
    active_since timestamptz default current_timestamp,
    max_db_connections int not null default 10,
    master bool unique);
create table if not exists rppd_function (
    id serial primary key,
    code text not null,
    checksum varchar(64) not null,
    schema_table varchar(64) not null,
    topic varchar(64) not null default '',
    priority int not null default 1,
    queue bool not null default true,
    cleanup_logs_min int not null default 0,
    fn_logging bool not null default false,
    verbose_debug bool not null default false,
    env json, sign json);
create table if not exists rppd_function_log (
    id bigserial primary key,
    node_id int not null,
    fn_id int not null,
    trig_value json,
    trig_type int not null default 0,
    started_at timestamptz not null default current_timestamp,
    took_ms bigint,
    output text,
    error_msg text);
create table if not exists rppd_cron (
    id serial primary key,
    fn_id int not null,
    cron varchar(64) not null,
    column_name varchar(64) not null,
    column_value text,
    cadence bool not null default false,
    timeout_sec int,
    finished_at timestamptz,
    started_at timestamptz,
    error_msg text);
"

# Same function as 92_rppd.sh: `DB` is the one binding every rppd example uses,
# so a red here is "did not run", not "guessed a variable name".
FN='cur = DB.cursor()
cur.execute("insert into cx_sink (data) values (%s)", ("ran",))
DB.commit()
print("cross-db test function ran")'

echo "Creating $APPDB: extension, tables, A rows, rppd tables + function..."
for n in "${NODES[@]}"; do
	for _ in 1 2 3 4 5; do
		[ "$(pq "$n" "select count(*) from pg_database where datname='$APPDB'")" = "1" ] && break
		pq "$n" "create database $APPDB" >/dev/null
		sleep 1
	done
	aq "$n" "create extension if not exists yaxaha" >/dev/null
	aq "$n" "$RPPD_DDL
	         create table if not exists cx_t (id bigint primary key, v text);
	         create table if not exists cx_r (id bigint primary key, v text);
	         create table if not exists cx_py (id bigint primary key, v text);
	         create table if not exists cx_sink (id serial primary key, data text);" >/dev/null
	app_register "$n" public.cx_t
	app_register "$n" public.cx_r            # unrouted first; az=east later (check 3)
	app_register "$n" public.cx_py "$PYCFG"
	# On every node: each node's rppd would read its own database, and a function
	# only on the leader would make "exactly once" depend on the election.
	aq "$n" "delete from rppd_function where schema_table='public.cx_py';
	         insert into rppd_function (code, checksum, schema_table, topic, fn_logging, verbose_debug)
	         values (\$fn\$$FN\$fn\$, 'na', 'public.cx_py', '', true, true)" >/dev/null

	a="$(aq "$n" "select count(*) from public.yt_config where module='A'")"
	t="$(aq "$n" "select count(*) from pg_trigger where tgname like 'zytsync_public_cx_%'")"
	f="$(aq "$n" "select count(*) from rppd_function where schema_table='public.cx_py'")"
	printf "  %-5s %s: A rows=%s sync triggers=%s rppd functions=%s\n" "$n" "$APPDB" "${a:-?}" "${t:-?}" "${f:-?}"
	if [ "${a:-0}" != "3" ] || [ "${t:-0}" != "3" ] || [ "${f:-0}" != "1" ]; then
		bad "$n: $APPDB setup is incomplete - everything after this would be vacuous"
		summary
	fi
done

# The instance config table's own sync registration, as 10_up.sh installs it -
# in postgres. Written before the restart, so the startup loader reads its A row.
register_table "$YX_CFG"
for n in "${NODES[@]}"; do cfg_write "$n" cfg_ready C 1; done

echo "Cold start (synchronized)..."
restart_all
pick_roles
app_wait_writable "$W" "$WIT" cx_t -1000 \
	|| bad "$APPDB.cx_t never became writable from $W toward $WIT after the cold start"

# ── 1 ───────────────────────────────────────────────────────────────────────
echo "-- 1: the cluster runs on the instance config in postgres"
for n in "${NODES[@]}"; do
	c="$(rh "docker logs $n 2>&1 | { grep -c 'db_url=postgresql://postgres@localhost/postgres?' || true; }" | tail -1 || true)"
	[ "${c:-0}" -gt 0 ] && ok "1: ytserv on $n was started on the postgres database" \
		|| bad "1: $n's entrypoint never logged a postgres db_url"
	check "1: ytserv on $n loaded the config table's own row from postgres" \
		"A.postgres.public.yt_config" "$(info "$n" "a:postgres.public.yt_config" table || true)"
done
check_up "1"

# ── 2 ───────────────────────────────────────────────────────────────────────
echo "-- 2: a table registered in $APPDB replicates in $APPDB, not in postgres"
for n in "${NODES[@]}"; do
	check "2: ytserv on $n holds cx_t's config under $APPDB" "A.$APPDB.public.cx_t" \
		"$(info "$n" "a:$APPDB.public.cx_t" table || true)"
done
check_replication "2" 1

# ── 3, before ───────────────────────────────────────────────────────────────
echo "-- 3: before the A-row change, cx_r is unrouted"
check_routing "3-before" 1 all

# ── between: the A-row change, then a restart ───────────────────────────────
#
# No rppd roster seed: ytserv keeps rppd_config itself (one row per member,
# host = ip:port, host_name = uuid, master = the leader), in the database rppd
# resolved to. A hand-written row would name the leader by container name -
# neither form ytserv writes - and rppd would dial it as a second peer.
for n in "${NODES[@]}"; do
	app_cfg_write "$n" public.cx_r A "$AZCFG"
done
echo "  $APPDB: cx_r -> az=east on every node"
restart_all
pick_roles
app_wait_writable "$W" "$WIT" cx_t -2000 \
	|| bad "$APPDB.cx_t never became writable from $W toward $WIT after the config restart"

# ── 3 ───────────────────────────────────────────────────────────────────────
echo "-- 3: $APPDB's A row now routes cx_r to east"
check_routing "3" 2 east

# ── 4 ───────────────────────────────────────────────────────────────────────
echo "-- 4: an rppd function registered in $APPDB fires on a commit in $APPDB"
check_rppd "4" 1

# ── 5 ───────────────────────────────────────────────────────────────────────
echo "-- 5: no config leaked between the databases"
check_leaks

# ── 6 ───────────────────────────────────────────────────────────────────────
echo "-- 6: restart ytserv everywhere; 1-4 must still hold"
restart_all
pick_roles
app_wait_writable "$W" "$WIT" cx_t -3000 \
	|| bad "$APPDB.cx_t never became writable from $W toward $WIT after the final restart"
check_up "6/1"
check_replication "6/2" 2
check_routing "6/3" 3 east
check_rppd "6/4" 2

# ── 7 ───────────────────────────────────────────────────────────────────────
# [dbreg] The registry (yt-pgxt combined-config.md, phase 1): which databases each
# node replicates for, found at runtime, and let go of.
echo "-- 7: the databases ytserv replicates for"
APP2="${XDB_APP2:-app2}"
PLAIN="${XDB_PLAIN:-plaindb}"
u_line() { info "$1" U "$2" || true; }   # <node> <db>: its yt_info('U') line
# <tag> <node> <db> <pattern> [seconds]: wait for its U line to match
u_wait() {
	local tag="$1" n="$2" db="$3" pat="$4" t="${5:-60}" i v=""
	for i in $(seq 1 "$t"); do
		v="$(u_line "$n" "$db")"
		[[ "$v" == $pat ]] && { ok "$tag: $n: $db is ${v:0:90}"; return 0; }
		sleep 1
	done
	bad "$tag: $n: $db is [${v:-not listed}], wanted [$pat]"
}
for n in "${NODES[@]}"; do
	[ "$(pq "$n" "select count(*) from pg_database where datname='$PLAIN'")" = "1" ] \
		|| pq "$n" "create database $PLAIN" >/dev/null
done
for n in "${NODES[@]}"; do
	u_wait "7a" "$n" postgres "participant *source=catalog*"
	u_wait "7a" "$n" "$APPDB" "participant *A=3 source=auto*"
	u_wait "7a" "$n" "$PLAIN" "skipped: no extension"
	check "7a: $n holds no connection to $PLAIN (B10: probed, not pooled)" "0" \
		"$(pq "$n" "select count(*) from pg_stat_activity where datname='$PLAIN'")"
done

# a database whose extension comes at runtime: one transaction, so the A row is
# there when the extension's announce makes ytserv look
for n in "${NODES[@]}"; do
	[ "$(pq "$n" "select count(*) from pg_database where datname='$APP2'")" = "1" ] \
		|| pq "$n" "create database $APP2" >/dev/null
	q "$n" "begin;
	        create extension if not exists yaxaha;
	        create table if not exists cx2_t (id bigint primary key, v text);
	        create trigger zytsync_public_cx2_t_trigger after insert or update or delete on cx2_t
	          for each row execute procedure yt_synchronize();
	        insert into public.yt_config (name, module, value) values ('public.cx2_t', 'A', '');
	        commit;" "$APP2" >/dev/null
done
for n in "${NODES[@]}"; do
	u_wait "7b" "$n" "$APP2" "participant *A=1 source=auto*" 45
	check "7b: $n holds cx2_t's config under $APP2, no restart" "A.$APP2.public.cx2_t" \
		"$(info "$n" "a:$APP2.public.cx2_t" table || true)"
done
q "$W" "begin; insert into cx2_t values (1, 'runtime'); select yt_complete(true); commit;" "$APP2" >/dev/null
sleep 3
for n in "${NODES[@]}"; do
	check "7b: $APP2.cx2_t's write from $W is on $n" "1" "$(q "$n" "select count(*) from cx2_t where id = 1" "$APP2")"
done

# skipped by the list, written locally on every node's unsynced catalog: let go
# of without a restart - and then it can be dropped (B9)
for n in "${NODES[@]}"; do cfg_write "$n" databases C "*, -$APP2"; done
for n in "${NODES[@]}"; do
	u_wait "7c" "$n" "$APP2" "skipped: -skip in databases" 45
	check "7c: $n forgot cx2_t's config" "" "$(info "$n" "a:$APP2.public.cx2_t" table || true)"
done
for n in "${NODES[@]}"; do
	pq "$n" "drop database $APP2" >/dev/null 2>&1
	check "7c: $APP2 dropped on $n (ytserv holds no connection to it)" "0" \
		"$(pq "$n" "select count(*) from pg_database where datname='$APP2'")"
done
for n in "${NODES[@]}"; do
	for _ in $(seq 1 45); do [ -z "$(u_line "$n" "$APP2")" ] && break; sleep 1; done
	check "7c: $n no longer lists $APP2" "" "$(u_line "$n" "$APP2")"
	cfg_delete "$n" databases C
	pq "$n" "drop database if exists $PLAIN" >/dev/null 2>&1
done

# ── 8 ───────────────────────────────────────────────────────────────────────
# [natural-key] The config table keyed by (module, name) (yt-pgxt combined-config.md
# D6): a row written locally on one node (trigger off) takes ids that a cluster
# insert from the leader then carries - which failed on the old id key - and a
# value UPDATE written on the leader takes effect on the leader too, not only on
# the nodes that took it by apply (the phase-2 trap, fixed the same day).
echo "-- 8: the config table's natural key"
c_wait() { # <tag> <node> <letters> <name> <want> [seconds]: wait for a yt_info value
	local tag="$1" n="$2" l="$3" name="$4" want="$5" t="${6:-60}" v=""
	for _ in $(seq 1 "$t"); do
		v="$(info "$n" "$l" "$name" || true)"
		[ "$v" = "$want" ] && { ok "$tag: $n: $l $name = $v"; return 0; }
		sleep 1
	done
	bad "$tag: $n: $l $name = [$v], wanted [$want]"
}
L="$(x_leader)"
F=""
for n in "${NODES[@]}"; do [ "$n" != "$L" ] && { F="$n"; break; }; done
if [ -z "$L" ] || [ -z "$F" ]; then
	bad "8: no leader to write on (leader [$L], follower [$F])"
else
	for i in 1 2 3; do cfg_write "$F" "xdb_probe_local_$i" C "$i"; done
	e="$(qe "$L" "insert into $YX_CFG (name, module, value) values ('xdb_probe_cluster', 'C', '1')" postgres)"
	[[ "$e" == *ERROR* ]] && bad "8a: the cluster insert on $L: $e"
	for n in "${NODES[@]}"; do
		v=""
		for _ in $(seq 1 30); do
			v="$(pq "$n" "select value from $YX_CFG where module = 'C' and name = 'xdb_probe_cluster'")"
			[ "$v" = "1" ] && break
			sleep 1
		done
		check "8a: the leader's insert is on $n beside its local rows" "1" "$v"
	done
	was="$(pq "$L" "select value from $YX_CFG where module = 'C' and name = 'tcp_timeout_ms'")"
	e="$(qe "$L" "update $YX_CFG set value = '2100' where module = 'C' and name = 'tcp_timeout_ms'" postgres)"
	[[ "$e" == *ERROR* ]] && bad "8b: the value UPDATE on $L: $e"
	for n in "${NODES[@]}"; do c_wait "8b" "$n" "c:tcp_timeout_ms" effective 2100 30; done
	qe "$L" "update $YX_CFG set value = '${was:-2000}' where module = 'C' and name = 'tcp_timeout_ms';
	         delete from $YX_CFG where module = 'C' and name = 'xdb_probe_cluster'" postgres >/dev/null
	for i in 1 2 3; do cfg_delete "$F" "xdb_probe_local_$i" C; done
fi

# ── 9 ───────────────────────────────────────────────────────────────────────
# [D4] A users database's own setting: def_sql_timeout_sec in appdb's table, read
# by the discovery pass (the table is not synced here: written on every node), is
# appdb's tables' fallback - and only theirs. A catalog setting written there
# (min_cluster_size) is counted ignored and changes nothing.
echo "-- 9: $APPDB's own settings"
cat_timeout="$(info "$TOP" "c:def_sql_timeout_sec" effective || true)"
for n in "${NODES[@]}"; do
	app_cfg_write "$n" def_sql_timeout_sec C 7
	app_cfg_write "$n" min_cluster_size C 9
done
for n in "${NODES[@]}"; do
	c_wait "9" "$n" "c:def_sql_timeout_sec@$APPDB" effective 7 60
	check "9: $n: its source is $APPDB" "$APPDB" "$(info "$n" "c:def_sql_timeout_sec@$APPDB" source || true)"
	check "9: $n: the catalog's own is unchanged" "$cat_timeout" "$(info "$n" "c:def_sql_timeout_sec" effective || true)"
	check "9: $n: cx_t's timeout falls back to $APPDB's" "7 ($APPDB def_sql_timeout_sec; stored 0)" \
		"$(info "$n" "a:$APPDB.public.cx_t" source.timeout_sec || true)"
	check "9: $n: min_cluster_size written in $APPDB changes nothing" "3" "$(info "$n" "c:min_cluster_size" effective || true)"
	u="$(u_line "$n" "$APPDB")"
	[[ "$u" == *"overrides=def_sql_timeout_sec ignored=1"* ]] && ok "9: $n: yt_info('U') shows $APPDB's own and ignored rows" \
		|| bad "9: $n: yt_info('U') for $APPDB is [$u]"
done

# ── 10 ──────────────────────────────────────────────────────────────────────
# [D12] the combined config as appdb sees it (the yt_config_effective view), and
# yxctl --config-lint on the misplaced row (exit 34), clean once it is gone
echo "-- 10: the combined view; --config-lint"
check "10: $TOP: yt_config_effective in $APPDB" "7|$APPDB|Database" \
	"$(aq "$TOP" "select value || '|' || source || '|' || scope from yt_config_effective where name = 'def_sql_timeout_sec'")"
out="$(rh "docker exec -u postgres $TOP yxctl --config-lint -d postgres 2>&1; echo rc=\$?" || true)"
[[ "$out" == *"rc=34"* && "$out" == *"min_cluster_size"* ]] && ok "10: --config-lint on $TOP finds $APPDB's min_cluster_size (exit 34)" \
	|| bad "10: --config-lint on $TOP: $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
for n in "${NODES[@]}"; do
	aq "$n" "alter table public.yt_config disable trigger user;
	         delete from public.yt_config where module = 'C';
	         alter table public.yt_config enable trigger user;" >/dev/null
done
for n in "${NODES[@]}"; do c_wait "10" "$n" "c:def_sql_timeout_sec@$APPDB" source default 60; done
# the fixture's own catalog rows (cfg_ready, the entrypoint's marker) name no
# setting and stay reported: what must be gone is appdb's
out="$(rh "docker exec -u postgres $TOP yxctl --config-lint -d postgres 2>&1; echo rc=\$?" || true)"
[[ "$out" == *"rc="* && "$out" != *"$APPDB.public.yt_config: C min_cluster_size"* ]] \
	&& ok "10: --config-lint on $TOP no longer reports $APPDB's row once it is gone" \
	|| bad "10: --config-lint on $TOP after the delete: $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"

# ── 11 ──────────────────────────────────────────────────────────────────────
# [D5] A node's own row, C <name>@<uuid>, written once on the leader (the catalog
# is synced): it replicates, applies on that node alone and wins over the plain
# value there; deleted, the node takes the plain value again.
echo "-- 11: a node's own row"
L="$(x_leader)"
T="$EAST1"
tu="$(node_uuid "$T")"
plain="$(info "$T" "c:recon_batch_max" effective || true)"
if [ -z "$L" ] || [ -z "$plain" ]; then
	bad "11: no leader [$L] or no recon_batch_max on $T [$plain]"
else
	e="$(qe "$L" "insert into $YX_CFG (name, module, value) values ('recon_batch_max@$tu', 'C', '777')" postgres)"
	[[ "$e" == *ERROR* ]] && bad "11: the per-node row on $L: $e"
	c_wait "11" "$T" "c:recon_batch_max" effective 777 30
	check "11: $T: the value comes from its own row" "catalog @${tu:0:8}" "$(info "$T" "c:recon_batch_max" source || true)"
	for n in "${NODES[@]}"; do
		[ "$n" = "$T" ] && continue
		check "11: $n: another node's row does not apply here" "$plain" "$(info "$n" "c:recon_batch_max" effective || true)"
	done
	qe "$L" "delete from $YX_CFG where module = 'C' and name = 'recon_batch_max@$tu'" postgres >/dev/null
	c_wait "11" "$T" "c:recon_batch_max" effective "$plain" 60
fi

# ── 12 ──────────────────────────────────────────────────────────────────────
# [phase 4/5] A users database whose config table is synced: a catalog setting
# written there is refused on the origin and stored nowhere; a database setting
# applies live on every node; then `yxctl --db-remove` on the leader detaches it
# cluster-wide (`!app3` in the synced catalog's C databases), and every node lets
# go of it, so it can be dropped.
echo "-- 12: a users database with a synced config table; yxctl --db-remove"
APP3="${XDB_APP3:-app3}"
for n in "${NODES[@]}"; do
	[ "$(pq "$n" "select count(*) from pg_database where datname='$APP3'")" = "1" ] \
		|| pq "$n" "create database $APP3" >/dev/null
	q "$n" "create extension if not exists yaxaha" "$APP3" >/dev/null
done
for n in "${NODES[@]}"; do u_wait "12" "$n" "$APP3" "participant *" 45; done
for n in "${NODES[@]}"; do
	q "$n" "select count(*) from yt_setup('public.yt_config', '', true, 'public.yt_config')" "$APP3" >/dev/null
done
L="$(x_leader)"
if [ -z "$L" ]; then
	bad "12: no leader"
else
	e="$(qe "$L" "insert into public.yt_config (name, module, value) values ('min_cluster_size', 'C', '9')" "$APP3")"
	echo "  12a: the write on $L answered: $(printf '%s' "$e" | head -2 | tr '\n' ' ')"
	check "12a: a catalog setting written in $APP3 is not stored" "0" \
		"$(q "$L" "select count(*) from public.yt_config where module = 'C' and name = 'min_cluster_size'" "$APP3")"
	for n in "${NODES[@]}"; do
		check "12a: $n: min_cluster_size unchanged" "3" "$(info "$n" "c:min_cluster_size" effective || true)"
	done
	e="$(qe "$L" "insert into public.yt_config (name, module, value) values ('def_cluster_commit', 'C', 'all')" "$APP3")"
	[[ "$e" == *ERROR* ]] && bad "12b: the database setting on $L: $e"
	for n in "${NODES[@]}"; do c_wait "12b" "$n" "c:def_cluster_commit@$APP3" source "$APP3" 30; done
	out="$(rh "docker exec -u postgres $L yxctl --db-remove $APP3 --drop-extension -d postgres 2>&1; echo rc=\$?" || true)"
	[[ "$out" == *"rc=0"* ]] && ok "12c: yxctl --db-remove $APP3 on $L" \
		|| bad "12c: yxctl --db-remove $APP3 on $L: $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
	for n in "${NODES[@]}"; do u_wait "12c" "$n" "$APP3" "detached" 90; done
	for n in "${NODES[@]}"; do
		pq "$n" "drop database $APP3" >/dev/null 2>&1
		check "12c: $APP3 dropped on $n" "0" "$(pq "$n" "select count(*) from pg_database where datname='$APP3'")"
	done
	qe "$(x_leader)" "delete from $YX_CFG where module = 'C' and name = 'databases'" postgres >/dev/null
fi

# ── 13 ──────────────────────────────────────────────────────────────────────
# [D11] One rppd per database: app4's functions run in an instance of their own.
echo "-- 13: one rppd per database (app4)"
APP4="${XDB_APP4:-app4}"
for n in "${NODES[@]}"; do
	[ "$(pq "$n" "select count(*) from pg_database where datname='$APP4'")" = "1" ] \
		|| pq "$n" "create database $APP4" >/dev/null
	q "$n" "create extension if not exists yaxaha" "$APP4" >/dev/null
done
for n in "${NODES[@]}"; do u_wait "13" "$n" "$APP4" "participant *" 45; done
for n in "${NODES[@]}"; do
	q "$n" "select count(*) from yt_setup('public.yt_config', '', true, 'public.yt_config')" "$APP4" >/dev/null
	q "$n" "create table if not exists cx_py4 (id bigint primary key, v text);
	        create table if not exists cx_sink (id serial primary key, data text);" "$APP4" >/dev/null
done
L="$(x_leader)"
if [ -z "$L" ]; then
	bad "13: no leader"
else
	# [rppd-tables] rppd's tables in app4: ytserv's, by SchemaGuard over rppd.yaml
	qe "$L" "delete from $YX_CFG where module = 'C' and name = 'rppd_dbs';
	         insert into $YX_CFG (name, module, value) values ('rppd_dbs', 'C', '$APP4')" postgres >/dev/null
	made=0
	for _ in $(seq 1 30); do
		made=0
		for n in "${NODES[@]}"; do
			[ "$(q "$n" "select to_regclass('public.rppd_function') is not null" "$APP4")" = "t" ] && made=$((made + 1))
		done
		[ "$made" = "${#NODES[@]}" ] && break
		sleep 2
	done
	check "13a: ytserv created rppd's tables in $APP4 on every node (C rppd_dbs)" "${#NODES[@]}" "$made"
	# the table's sync, its A row through app4's synced config table, the function
	for n in "${NODES[@]}"; do
		q "$n" "drop trigger if exists zytsync_public_cx_py4_trigger on cx_py4;
		        create trigger zytsync_public_cx_py4_trigger after insert or update or delete on cx_py4
		        for each row execute procedure yt_synchronize();
		        delete from rppd_function where schema_table='public.cx_py4';
		        insert into rppd_function (code, checksum, schema_table, topic, fn_logging, verbose_debug)
		        values (\$fn\$$FN\$fn\$, 'na', 'public.cx_py4', '', true, true)" "$APP4" >/dev/null
	done
	e="$(qe "$L" "delete from public.yt_config where module = 'A' and name = 'public.cx_py4';
	             insert into public.yt_config (name, module, value) values ('public.cx_py4', 'A', '$PYCFG')" "$APP4")"
	[[ "$e" == *ERROR* ]] && bad "13b: the A row of $APP4.cx_py4 on $L: $e"
	# its instance starts within a tick (30 s), with its database's queues
	st=""
	for _ in $(seq 1 45); do
		st="$(rh "docker logs $L 2>&1 | grep -a 'rppd started for database $APP4' | tail -1" 2>/dev/null || true)"
		[ -n "$st" ] && break
		sleep 2
	done
	[ -n "$st" ] && ok "13b: $L started the rppd of $APP4" || bad "13b: no rppd started for $APP4 on $L"
	sink_b="$(q "$L" "select count(*) from cx_sink" "$APP4")"
	app_b="$(sum_app "select count(*) from cx_sink")"
	out="$(qe "$W" "begin; insert into cx_py4 values (1, 'd11'); select yt_complete(true); commit;" "$APP4")"
	[[ "$out" == *ERROR* ]] && bad "13c: the write to $APP4.cx_py4: $out"
	ran=0
	for _ in $(seq 1 30); do
		ran=$(( $(q "$L" "select count(*) from cx_sink" "$APP4") - ${sink_b:-0} ))
		[ "$ran" -ge 1 ] && break
		sleep 2
	done
	check "13c: the function of $APP4 ran on the leader $L, once, in $APP4's own instance" "1" "$ran"
	logs="$(q "$L" "select count(*) from rppd_function_log" "$APP4")"
	[ "${logs:-0}" -ge 1 ] && ok "13c: $APP4.rppd_function_log records it" || bad "13c: nothing in $APP4.rppd_function_log"
	check "13c: $APPDB's instance ran nothing for it" "$app_b" "$(sum_app "select count(*) from cx_sink")"
	# done: app4 goes as app3 did
	qe "$L" "delete from $YX_CFG where module = 'C' and name = 'rppd_dbs'" postgres >/dev/null
	rh "docker exec -u postgres $L yxctl --db-remove $APP4 --drop-extension -d postgres >/dev/null 2>&1" || true
	for n in "${NODES[@]}"; do u_wait "13" "$n" "$APP4" "detached" 90; done
	for n in "${NODES[@]}"; do pq "$n" "drop database $APP4" >/dev/null 2>&1; done
	qe "$(x_leader)" "delete from $YX_CFG where module = 'C' and name = 'databases'" postgres >/dev/null
fi

summary
