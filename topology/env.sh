#!/usr/bin/env bash
# [topology] Shared config for the Docker topology tests. Source, do not execute.
#
# Six nodes in three zones on two tiers - the smallest arrangement that can tell
# every topology rule apart:
#
#   tier 0   top    n1 n2        <- writes config down, never receives big tables
#   tier 1   east   n3 n4        <- a MINORITY zone: 2 of 6
#   tier 1   west   n5 n6
#
# east being a minority is the point. Before the threshold fix, a table routed
# there got party_size 3 from a 6-node cluster, select_party could offer 1, and
# every write aborted. See topology-todo.md 2.0.
set -euo pipefail

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Settings: yaxaha-tests/.env (not committed, see env.example). A variable already
# set in the environment wins over it.
if [ -f "$TESTS_ROOT/.env" ]; then
	_yx_keep="$(export -p)"; set -a; . "$TESTS_ROOT/.env"; set +a; eval "$_yx_keep"; unset _yx_keep
fi
# The yt-pgxt checkout the suite builds from and encodes table configs with:
# YT_PGXT, or a sibling of this repository.
REPO_ROOT="${YT_PGXT:-$(cd "$TESTS_ROOT/.." && pwd)/yt-pgxt}"

YX_HOST="${YX_HOST:-local}"          # where the containers run: an ssh target, or local
# [peering] The cluster's own uuid, written to every node as module-C `cluster`.
# Fixed rather than generated so a rebuilt fixture rejoins the same cluster, and
# shared because an empty value makes each node invent its own (Uuid::new_v4)
# and refuse every peer.
YX_CLUSTER_UUID="${YX_CLUSTER_UUID:-7a1c0000-0000-5000-8000-000000000001}"
YX_NET="${YX_NET:-yxtopo}"
YX_IMAGE="${YX_IMAGE:-yxtopo-node}"
YX_DB="${YX_DB:-yxtopo}"
YX_CFG="${YX_CFG:-public.yt_config}"
YX_PORT="${YX_PORT:-7421}"
# [skv] The app key every node's ytserv runs with (marg SECRET): what a join
# approval is an HMAC under (98_skv_join.sh, yxctl --skv-approve). A fixture
# value, not a secret; given to each container at creation (10_up.sh), so a
# change needs the containers made again.
YX_SECRET="${YX_SECRET:-yxtopo-fixture-app-key}"

# node -> az, and az -> tier. One place, because a test that disagreed with the
# cluster about where a node is would pass or fail for the wrong reason.
#
# [P3] Overridable from the environment so a SECOND fixture (the SKV cluster,
# its own network and database) reuses this harness instead of forking it.
# `YX_NODES` is a space-separated list; `YX_AZ` and `YX_TIER` are
# "name=value,name=value". Unset means the six-node topology above, unchanged.
if [ -n "${YX_NODES:-}" ]; then
	read -r -a NODES <<< "$YX_NODES"
else
	NODES=(n1 n2 n3 n4 n5 n6)
fi

declare -A NODE_AZ=()
declare -A AZ_TIER=()
if [ -n "${YX_AZ:-}" ]; then
	IFS=',' read -r -a _pairs <<< "$YX_AZ"
	for _p in "${_pairs[@]}"; do NODE_AZ["${_p%%=*}"]="${_p#*=}"; done
	IFS=',' read -r -a _pairs <<< "${YX_TIER:-}"
	for _p in "${_pairs[@]}"; do [ -n "$_p" ] && AZ_TIER["${_p%%=*}"]="${_p#*=}"; done
else
	NODE_AZ=( [n1]=top [n2]=top [n3]=east [n4]=east [n5]=west [n6]=west )
	AZ_TIER=( [top]=0 [east]=1 [west]=1 )
fi

# [P6c/db-local] Nodes whose PostgreSQL is reached over TCP, so they can never
# be Main (membership.md, Forever-Spare) while remaining full etcd and rppd
# members. Space-separated. They are in the roster but NOT in the quorum, which
# is why YX_MIN_CLUSTER exists below.
read -r -a SPARE_NODES <<< "${YX_SPARE_NODES:-}"

is_spare_node() {
	local n="$1" s
	for s in "${SPARE_NODES[@]:-}"; do [ "$s" = "$n" ] && return 0; done
	return 1
}

# ssh to the docker host, over ONE shared connection. A run makes thousands of
# calls, one per query, and several at once - sshd's MaxStartups (10:30:100 by
# default) then starts dropping new connections ("kex_exchange_identification:
# Connection reset by peer"), and the dropped call reads as an empty answer from
# the cluster. Multiplexed, each call is a channel on a session that already
# exists. YX_SSH_MUX=0 for a fresh connection per call.
YX_SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8)
if [ "${YX_SSH_MUX:-1}" = 1 ]; then
	YX_SSH+=(-o ControlMaster=auto -o "ControlPath=${XDG_RUNTIME_DIR:-/tmp}/yx-ssh-%C"
		-o ControlPersist=120 -o ServerAliveInterval=30)
fi

# Run a command on the docker host. Everything goes through this, so the whole
# suite works the same whether YX_HOST is remote or "local".
rh() {
	if [ "$YX_HOST" = "local" ]; then bash -c "$*"; else
		"${YX_SSH[@]}" "$YX_HOST" "$*"; fi
}

# psql on one node, -tA so the output is the value and nothing else.
#
# SQL goes in on STDIN, never as a -c argument: it has to survive ssh -> sh ->
# docker exec -> su -> psql, and every one of those layers wants its own quoting.
# A statement containing a quote came back empty rather than erroring, which
# looked exactly like a query that legitimately returned nothing.
#
# `lock_timeout` so a blocked statement FAILS instead of hanging. An orphaned 2PC
# prepared transaction holds its table locks indefinitely, and without this a
# `drop table if exists ...` in a test's first setup line waits forever, silently
# - a run that produces no output at all and looks like a slow cluster. Only lock
# waits are bounded; a cluster write legitimately doing a cross-node 2PC is
# waiting on the network, not on a lock, and is untouched.
q() { # q <node> <sql> [db]
	local node="$1" sql="$2" db="${3:-$YX_DB}"
	local opt="-c lock_timeout=30s"
	if [ "$YX_HOST" = "local" ]; then
		printf '%s\n' "$sql" | docker exec -i -u postgres -e PGOPTIONS="$opt" "$node" \
			psql -tAq -d "$db" 2>/dev/null
	else
		printf '%s\n' "$sql" | "${YX_SSH[@]}" "$YX_HOST" \
			"docker exec -i -u postgres -e PGOPTIONS='$opt' $node psql -tAq -d $db" 2>/dev/null
	fi
}

qe() { # qe <node> <sql> [db] - q, with psql's errors in the output
	local node="$1" sql="$2" db="${3:-$YX_DB}"
	local opt="-c lock_timeout=30s"
	if [ "$YX_HOST" = "local" ]; then
		printf '%s\n' "$sql" | docker exec -i -u postgres -e PGOPTIONS="$opt" "$node" \
			psql -tAq -d "$db" 2>&1
	else
		printf '%s\n' "$sql" | "${YX_SSH[@]}" "$YX_HOST" \
			"docker exec -i -u postgres -e PGOPTIONS='$opt' $node psql -tAq -d $db" 2>&1
	fi
}

# the deterministic node identity yxctl's --peers roster uses:
# uuid5(YAXAHA_NS, host). Every node computes the same one, so no UUID ever has
# to be written into a config file.
YAXAHA_NS="6a9f5c2e-1b3d-5e47-9a08-0bf99b3e0275"
node_uuid() { python3 -c "import uuid,sys; print(uuid.uuid5(uuid.UUID('$YAXAHA_NS'), sys.argv[1]))" "$1"; }

# yt_info returns JSON in this build ([{name,value,module},...]), not a record
# set - an older build needed `as x(name,value,module)` and that form now errors
# with "a column definition list is only allowed for functions returning record".
info() { # info <node> <letters> [name]
	local node="$1" letters="$2" want="${3:-}"
	local j; j="$(q "$node" "select yt_info('$letters')")"
	if [ -z "$want" ]; then printf '%s' "$j"; return; fi
	printf '%s' "$j" | python3 -c "
import json,sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in rows:
    if r.get('name') == '$want': print(r.get('value','')); break
"
}

# A table's module-'A' row is read by the STARTUP loader. yt_setup creates that
# row after ytserv is already running, and a direct UPDATE to it does not travel
# through re_config either - so ytserv keeps the value it loaded and logs
# "No cluster configuration found for table ...". Restarting is the documented
# path for new flags (Phase 2: "New flags need a synchronized systemctl restart
# ytserver on all nodes") and is what a test has to do after writing one.
# Every node's ytserv output, concatenated. `docker logs` because
# node-entrypoint.sh deliberately does not exec ytserv - the container stays up
# after it exits so its output is still readable.
#
# For assertions about something exactly one node did: a cluster-wide decision
# is logged by whichever node happened to be leader, and grepping the node you
# guessed is how a real log line gets read as absent.
logs_all() { # logs_all [node...]
	local ns=("$@")
	[ ${#ns[@]} -eq 0 ] && ns=("${NODES[@]}")
	for n in "${ns[@]}"; do rh "docker logs $n 2>&1" 2>/dev/null; done
}

# wait_writable <writer-node> <witness-node> <table> <probe-id>
#
# Block until a cluster write actually COMMITS AND REPLICATES, then remove the
# probe row. Returns non-zero if it never does.
#
# A fixed `sleep` after restart_all is a guess, and on a freshly created set of
# containers it is the wrong guess: the seed's writes PREPARE on the party and
# never commit, leaving orphaned prepared transactions and a table with zero
# rows. `await_cluster` is not enough either - every node can name the same
# leader while the write path is still not ready.
#
# The witness must not be the writer. A row present only on the node that wrote
# it proves nothing about replication, which is the thing being waited for.
# cfg_write <node> <name> <module> <value>
#
# Write one config row on ONE node, with the config table's own sync trigger
# switched off for the statement.
#
# `10_up.sh` registers `yt_config` for sync, so the config table carries a
# `yt_synchronize` trigger, and a write to it from a node that is not the leader
# is refused with:
#
#   ERROR:  yt_synchronize: Config: This configuration update require call from
#           cluster leader
#
# That is correct for a production cluster and wrong for a fixture: these tests
# deliberately write the same config row on every node and then restart, because
# a table's module-`A` row is read by the startup loader. Routing fixture config
# through consensus makes every test depend on which node won the last election.
#
# One transaction, and a failure is reported. Before, each statement ran on its
# own with psql's errors thrown away: an INSERT that failed left the row DELETED
# and said nothing, and the test then measured a setting that was never there.
cfg_write() {
	local n="$1" name="$2" mod="$3" val="$4"
	cfg_tx "$n" "cfg_write $mod $name" "delete from $YX_CFG where module='$mod' and name='$name';
	        insert into $YX_CFG (name,module,value) values ('$name','$mod','$val');"
}

# cfg_delete <node> <name> <module> — the removal half of cfg_write, and it needs
# the trigger off for exactly the same reason.
cfg_delete() {
	local n="$1" name="$2" mod="$3"
	cfg_tx "$n" "cfg_delete $mod $name" "delete from $YX_CFG where module='$mod' and name='$name';"
}

# cfg_tx <node> <what> <sql> - <sql> on the config table with its triggers off,
# all or nothing; an error goes to stderr as a WARN naming <what> and the node.
# Status 0 either way: callers run under `set -e`, and a refused write is for
# the test's own assertions to catch, not a reason to kill the script.
cfg_tx() {
	local n="$1" what="$2" sql="$3" out
	out="$(qe "$n" "begin;
	        alter table $YX_CFG disable trigger user;
	        $sql
	        alter table $YX_CFG enable trigger user;
	        commit;")"
	case "$out" in
		*ERROR*) echo "  WARN: $what on $n failed: $(printf '%s\n' "$out" | grep -m1 ERROR)" >&2 ;;
	esac
}

# register_table <schema.table> [module-A value]
#
# Put a table under cluster sync on every node. Replaces `yt_setup()` in the
# fixtures, and is not a stylistic preference - `yt_setup` cannot do this job on
# a cluster whose config table is itself synced.
#
# yt_setup creates the trigger and then INSERTs the module-`A` row **in one
# transaction**. On a non-leader that insert is refused (see cfg_write), and the
# rollback takes the CREATE TRIGGER with it. So `yt_setup` succeeds only where
# the config table happens to have no trigger, or on the leader.
#
# Measured on a fresh 6-node cluster: `10_up.sh`'s own `yt_setup(yt_config)`
# failed on n1 and succeeded on n2-n6, which left n1 as the only node whose
# config table had no trigger - so the NEXT `yt_setup` succeeded on n1 alone.
# One node out of six had the sync trigger, writes on the other five registered
# nothing, and every test's first cluster write died with `yt_complete: not
# connected`. Nothing in the logs named the table.
register_table() {
	local rel="$1" val="${2:-}" tname n
	tname="zytsync_${rel//./_}_trigger"
	for n in "${NODES[@]}"; do
		# and the statement-level TRUNCATE trigger yt_setup installs (31_commit C13)
		q "$n" "drop trigger if exists $tname on $rel;
		        create trigger $tname after insert or update or delete on $rel
		        for each row execute procedure yt_synchronize();
		        drop trigger if exists zytsynct_${rel//./_} on $rel;
		        create trigger zytsynct_${rel//./_} after truncate on $rel
		        for each statement execute procedure yt_synchronize();" >/dev/null
		cfg_write "$n" "$rel" A "$val"
	done
}

# The probe VALUE defaults to `{}`, which is a legal literal for `text`, `json`
# and `jsonb` alike. It used to be `'probe'`, and that is not valid jsonb:
# `96_jsonb_merge.sh` probes a `(id int, doc jsonb)` table, so its precondition
# failed with `invalid input syntax for type json` on every one of its 24
# attempts and the test could NEVER have passed. It was recorded as "written
# but never run"; this is why. Pass a fifth argument for a column type `{}`
# does not satisfy.
#
# A FRESH id per attempt, never the same one retried. A probe whose write
# committed locally but did not replicate leaves the row behind, and every later
# attempt at that id then dies on a local duplicate key - so the one failure mode
# this exists to wait out would make it wait forever. Probe ids are negative;
# tests count `where id > 0`, so leftovers cannot be mistaken for data.
wait_writable() {
	local w="$1" wit="$2" rel="$3" base="${4:--1000}" probe="${5:-{\}}"
	local i id
	for i in $(seq 1 24); do
		id=$((base - i))
		q "$w" "begin; insert into $rel values ($id,'$probe'); select yt_complete(true); commit;" >/dev/null
		if [ "$(q "$wit" "select count(*) from $rel where id=$id")" = "1" ]; then
			q "$w" "begin; delete from $rel where id < 0; select yt_complete(true); commit;" >/dev/null
			return 0
		fi
		sleep 5
	done
	echo "  WARN: $w -> $wit never became writable for $rel" >&2
	return 1
}

# Roll back every orphaned 2PC prepared transaction.
#
# This is the one piece of cluster state `rm -rf /var/yaxaha/*` does NOT reach,
# and it is the reason a killed run poisons the next one. A cluster write that
# dies between PREPARE and COMMIT leaves a `PREPARE TRANSACTION` behind; those
# survive a PostgreSQL restart by design and hold their table locks forever, so
# the next test's `drop table if exists ...` blocks and the whole run hangs with
# no output. That is exactly what happened here: n1/n2/n6 each held two, and
# `70_reshape.sh` sat in its very first setup loop for twenty minutes.
#
# Safe because the coordinator's WAL has just been wiped one line above: nothing
# is left that could ever resolve these, so rolling them back is the only
# outcome available. Never call this against a cluster you expect to keep
# running - only as part of the reset.
clear_prepared() {
	for n in "${NODES[@]}"; do
		local gids
		# `|| true`, and it is not defensive padding: this runs while env.sh is
		# being SOURCED, so `10_up.sh` reaches it before it has created any
		# container. A command substitution's status IS the assignment's
		# status, so under `set -e` a node that does not exist yet aborted the
		# sourcing — silently, with no output at all, because nothing had been
		# echoed yet. Latent since the fixture was written; a seventh node made
		# it fire every time.
		gids="$(q "$n" "select gid from pg_prepared_xacts" || true)"
		for g in $gids; do
			q "$n" "rollback prepared '$g'" >/dev/null
			echo "  reset: rolled back orphaned prepared xact $g on $n"
		done
	done
}

# ── [P4] network partition, for the split-brain and rejoin tests ────────────
#
# `docker network disconnect` rather than iptables inside the container: it cuts
# the node off from its PEERS while leaving `docker exec` working, so the test
# can still ask a partitioned node what it thinks. A node that vanished with its
# own evidence would make a split-brain test unfalsifiable - the one failure
# mode where "both sides elected" and "neither side did" look identical.
#
# partition <side-a nodes> -- <side-b nodes>
#
# Only side B is detached; A keeps the network. That is enough for a partition
# (the two sides cannot reach each other) and it means `heal` has one thing to
# undo rather than two.
partition() {
	local side_b=0 n
	for n in "$@"; do
		if [ "$n" = "--" ]; then side_b=1; continue; fi
		[ "$side_b" -eq 1 ] || continue
		rh "docker network disconnect $YX_NET $n >/dev/null 2>&1; true"
		echo "  partition: $n detached from $YX_NET"
	done
}

# Reattach everything. Idempotent: a node already connected is a no-op.
heal() {
	local n
	for n in "${NODES[@]}"; do
		rh "docker network connect $YX_NET $n >/dev/null 2>&1; true"
	done
	echo "  healed: every node reattached to $YX_NET"
}

# Take one node off the network without stopping it, and put it back.
#
# Distinct from `docker stop`: the process keeps running and keeps its in-memory
# state, which is what a network blip looks like and what the retired-key rejoin
# (etcd-skv.md 6.5) is about. A stop-and-start would clear exactly the state
# under test.
node_down() { rh "docker network disconnect $YX_NET $1 >/dev/null 2>&1; true"; echo "  $1 off the network"; }
node_up()   { rh "docker network connect    $YX_NET $1 >/dev/null 2>&1; true"; echo "  $1 back on the network"; }

restart_all() {
	# Clear the cluster WAL with the restart. A restarted node re-issues from
	# sub-term 1 while the old WAL still holds one, and every write then aborts
	# with "Sub-term 1 version 1 already exists" - the same collision a purge
	# leaves behind on a real node (rm -rf /var/yaxaha/*). Each test phase is
	# meant to start from a clean cluster anyway.
	#
	# CLEAN, not half: every ytserv stops BEFORE any WAL goes. Wiping it under
	# running nodes and then restarting them one by one let each restarted node
	# pull history from one still running on files already deleted under it -
	# commit records without rows that nobody could ever serve, so gaps nothing
	# could close, and the outdated-table gate refused every write: from
	# 70_reshape on, every test failed at its first write. And the position row
	# goes with the WAL it describes: a node with no WAL and a `least` row seeds
	# itself from it, as a physical copy resumes - from a stale mark, here,
	# claiming subterms of the resumed term it does not hold, so the leader's new
	# writes under those numbers read as "existing" there. `term` and
	# `leader_uuid` stay: the cluster resumes its term, as it always did here (a
	# cold start instead needs all six nodes up inside one window, and these
	# restarts come one at a time). Not `reshape_run` either: 70_reshape sets it
	# right before a restart, on purpose.
	for n in "${NODES[@]}"; do rh "docker exec $n pkill -f yaxaha/ytserv >/dev/null 2>&1; true"; done
	sleep 2
	for n in "${NODES[@]}"; do
		rh "docker exec $n sh -c 'rm -rf /var/yaxaha/*' >/dev/null 2>&1; true"
		cfg_delete "$n" least C
	done
	clear_prepared
	# All at once: with every ytserv stopped, nothing remembers a leader, and an
	# election after a full stop needs the nodes up together - one by one, each
	# node's cold-start window had closed before the last one answered, and the
	# cluster sat at "Leader: None" (the documented "synchronized restart").
	for n in "${NODES[@]}"; do rh "docker restart $n >/dev/null" & done
	wait
	# a 6-node cold start elects only once every node is back
	sleep "${1:-30}"
}

# node_ready <node> [timeout_sec] - the container running (started when it is
# not), its PostgreSQL answering, and its network interface up: an address on
# eth0 and every roster peer resolving. Status 1 with a WARN when not, so a
# caller under `set -e` decides (`|| true`, or `|| bad ...`).
node_ready() {
	local n="$1" t="${2:-300}" i
	if [ "$(rh "docker inspect -f '{{.State.Running}}' $n" 2>/dev/null)" != "true" ]; then
		echo "  NOTE: $n was not running - starting it" >&2
		rh "docker start $n >/dev/null" 2>/dev/null || true
	fi
	for ((i = 0; i < t; i += 2)); do
		[ "$(q "$n" 'select 1')" = "1" ] && break
		sleep 2
	done
	[ "$(q "$n" 'select 1')" = "1" ] || { echo "  WARN: $n: PostgreSQL did not answer within ${t}s" >&2; return 1; }
	for ((i = 0; i < 60; i += 2)); do
		rh "docker exec $n sh -c 'ip -4 -o addr show dev eth0 | grep -q inet && getent hosts ${NODES[*]} >/dev/null'" \
			>/dev/null 2>&1 && return 0
		sleep 2
	done
	echo "  WARN: $n: network interface not ready after 60s" >&2
	return 1
}

# The fixture's own config, as 10_up left it: what every test case starts from.
# The runtime rows ytserv writes itself are not part of it.
CFG_RUNTIME="'term','leader_uuid','least','single','reshape_run'"
cfg_baseline_save() {
	local n
	for n in "${NODES[@]}"; do
		q "$n" "drop table if exists yxt_cfg_baseline;
		        create table yxt_cfg_baseline as select name, module, value from $YX_CFG
		         where module='C' and name not in ($CFG_RUNTIME);" >/dev/null
	done
}
# Put it back: C rows a test added or changed go (module S, node-local commands,
# too), the fixture's come back; equal rows are left alone.
cfg_baseline_restore() {
	local n
	for n in "${NODES[@]}"; do
		if [ "$(q "$n" "select to_regclass('yxt_cfg_baseline') is not null")" != "t" ]; then
			echo "  NOTE: $n has no yxt_cfg_baseline (10_up did not run in this fixture) - config left as is" >&2
			continue
		fi
		cfg_tx "$n" "cfg_baseline_restore" "delete from $YX_CFG c
		         where (c.module='C' and c.name not in ($CFG_RUNTIME) and not exists (select 1 from yxt_cfg_baseline b
		                where b.module=c.module and b.name=c.name and b.value=c.value))
		            or c.module='S';
		        insert into $YX_CFG (name,module,value) select b.name, b.module, b.value from yxt_cfg_baseline b
		         where not exists (select 1 from $YX_CFG c where c.module=b.module and c.name=b.name and c.value=b.value);"
	done
}

# pre_case - run_a.sh, before every test case: clean and wiped.
#
# A case that failed halfway left its state for the next one: 89_recover exits
# on a failure before putting min_cluster_size back, and 24_db_local's quorum
# check then failed too; its stopped node was still down for 23, 92, 93 and 92c.
# So: every node running and ready, the fixture's config back, then the WAL wipe
# and synchronised restart (restart_all), and the cluster settled.
pre_case() {
	local n
	echo "  [pre-case] nodes ready, fixture config back, wipe + restart"
	for n in "${NODES[@]}"; do node_ready "$n" || true; done
	cfg_baseline_restore
	restart_all
	await_cluster || true
	for n in "${NODES[@]}"; do node_ready "$n" 60 || true; done
}

# wait until every node agrees on one leader, or give up and say so
await_cluster() {
	for _ in $(seq 1 20); do
		local seen=0
		for n in "${NODES[@]}"; do
			# "Leader: None!" names no leader - it is the opposite of settled
			case "$(info "$n" O cluster)" in *"Leader: None"*) ;; *Leader*) seen=$((seen+1));; esac
		done
		[ "$seen" -eq "${#NODES[@]}" ] && return 0
		sleep 5
	done
	echo "  WARN: cluster did not settle" >&2
}

# check_same <desc> <a-node> <b-node> <sql-digest> <min-rows> <table>
#
# Compares a digest across two nodes AND requires a minimum row count, because
# md5(NULL) = md5(NULL): two EMPTY tables compare equal, so a bare digest check
# reports "they agree exactly" when in fact nothing exists anywhere. The reshape
# test passed that assertion for a whole day while both sides were empty.
check_same() {
	local desc="$1" a="$2" b="$3" digest="$4" minrows="${5:-1}" rel="$6"
	local ca cb da db
	ca="$(q "$a" "select count(*) from $rel")"
	cb="$(q "$b" "select count(*) from $rel")"
	if [ "${ca:-0}" -lt "$minrows" ] || [ "${cb:-0}" -lt "$minrows" ]; then
		bad "$desc — refusing to compare: $a has ${ca:-0} row(s), $b has ${cb:-0}, need >= $minrows"
		return
	fi
	da="$(q "$a" "$digest")"
	db="$(q "$b" "$digest")"
	check "$desc" "$da" "$db"
}

pass=0; fail=0
ok()   { echo "  OK   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }
# check <description> <expected> <actual>
check() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi
}
summary() {
	echo "  ---- $pass passed, $fail failed ----"
	[ "$fail" -eq 0 ] || exit 1
}

# Sweep orphans before the test's own setup runs, not just at restart_all.
#
# Every test opens by dropping and recreating its table, and that drop is BEFORE
# the first restart_all - so an orphan left by a previous run blocks the very
# first statement, ahead of anything that would have cleared it. Six quick
# queries here are cheaper than diagnosing another silent twenty-minute hang.
#
# YX_NO_SWEEP is for a fixture that SOURCES this file for its helpers and then
# overrides NODES - the hierarchical fixture in ../hier does exactly that, and
# sweeping n1..n6 on a network where they do not exist is nine pointless ssh round
# trips before its own node list is even set.
[ -n "${YX_NO_SWEEP:-}" ] || clear_prepared
