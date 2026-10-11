#!/usr/bin/env bash
# [blocking:node] A node that is really GONE, and comes back.
#
# `87_node_block.sh` covers the operator's `node_run` pause - a node that is
# running and has chosen not to participate. This is the other half, and the one
# an operator actually meets: the process is killed, transactions happen without
# it, and it is started again.
#
#   stop the container -> write while it is down -> start it -> it rejoins AND
#   the writes it missed are there.
#
# ## Why a `docker stop`, and not `node_down`
#
# `node_down` (env.sh) disconnects the container from the network: the process
# keeps running, keeps its WAL position in memory, and comes back with
# everything it had. A `docker stop` stops ytserv and PostgreSQL. On `start` the
# entrypoint runs again from scratch, ytserv re-reads its config from the table,
# and the node has to work out where it got to from `/var/yaxaha` alone. That is
# the failure operators have - a restart, a crash, a host reboot - and it is a
# strictly harder test of catch-up.
#
# Deliberately NOT `restart_all`: that helper wipes `/var/yaxaha/*` before
# restarting, which is right when a test wants a clean cluster and exactly wrong
# here. The whole question is whether a node resumes from the WAL it kept.
#
# ## Why this also sidesteps F9
#
# `node_run <uuid8>:pause` cannot be undone (PLAN.md F9): a paused node is not
# `up()`, so it is excluded from the party and the fan-out, and never receives
# the config row carrying `follow`. A container restart has no such problem -
# the node re-reads the config table on start - so recovery is testable even
# while F9 stands.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== recover: a stopped node returns and catches up the writes it missed =="

# recon=repair: catching up is the claim, and recon is what closes whatever the
# WAL replay does not.
CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'recon=repair; recon_rows=1' | tail -1)"

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists rv_t; create table rv_t (id bigint primary key, v text);" >/dev/null
done
register_table public.rv_t "$CFG"

# ## Quorum has to tolerate the outage, or there is nothing to catch up
#
# `min_cluster_size` is 6 here on a 7-node roster (the spare is excluded), and
# that is what the SUPPORTED setup produces: `yxctl --peers` seeds
# `min_cluster_size = 1 + peers`, i.e. the entire roster. A cluster built the
# documented way therefore tolerates ZERO node failures - measured on the first
# run of this script, where 4 of 5 transactions were refused with one node
# stopped. Recorded as a finding; not this test's subject.
#
# Set with `cfg_write` + the restart below - the STARTUP path - and not at
# runtime. A runtime change is what PLAN.md F8 is about: pushed through the sync
# path it did not reach the witness's live config within 10s (`expected [4] got
# [6]`), and the churn from the attempt broke the baseline write outright. The
# startup loader is the reliable way to set a knob, so the test uses it.
MCS_TEST=$(( (${#NODES[@]} - ${#SPARE_NODES[@]}) / 2 + 1 ))   # majority of the voters
# Put back on ANY exit, and the stopped node started: a failure below used to
# `summary` out before the restore at the end, and 24_db_local's quorum check
# then failed on this test's value (2026-10-11).
on_exit() {
	[ -n "${SUBJ:-}" ] && { node_ready "$SUBJ" 60 >/dev/null 2>&1 || true; }
	for n in "${NODES[@]}"; do
		cfg_write "$n" min_cluster_size C "$(( ${#NODES[@]} - ${#SPARE_NODES[@]} ))"
	done
}
trap on_exit EXIT
for n in "${NODES[@]}"; do cfg_write "$n" min_cluster_size C "$MCS_TEST"; done
echo "  min_cluster_size -> $MCS_TEST for this test (majority of $(( ${#NODES[@]} - ${#SPARE_NODES[@]} )) voters)"

restart_all
await_cluster
wait_writable n1 n2 rv_t || { bad "cluster never became writable"; summary; }

L=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in *Leader) L="$n";; esac
done
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }

SUBJ=""; WITNESS=""
for n in "${NODES[@]}"; do
	is_spare_node "$n" && continue
	[ "$n" = "$L" ] && continue
	if [ -z "$SUBJ" ]; then SUBJ="$n"; elif [ -z "$WITNESS" ]; then WITNESS="$n"; fi
done
[ -n "$SUBJ" ] && [ -n "$WITNESS" ] || { bad "need two non-spare followers"; summary; }
echo "  leader=$L  stopping=$SUBJ  witness=$WITNESS"

# The apply path has to be caught up BEFORE the subject goes away, or "missing
# afterwards" cannot be attributed to the outage.
gap_of() {
	local m g
	m="$(info "$1" E health.metrics)"
	if [ -z "$m" ]; then printf '%s' "-1"; return; fi
	g="$(printf '%s' "$m" | sed -n 's/.*wal_gap \([0-9][0-9]*\).*/\1/p')"
	if [ -z "$g" ]; then printf '%s' "-1"; else printf '%s' "$g"; fi
}
gaps_closed() {
	local i n g w
	for i in $(seq 1 "${1:-24}"); do
		w=0
		for n in "${NODES[@]}"; do
			# Voters only. A forever-Spare is outside the write path - a write
			# never waits on ITS gaps (the outdated gate is the leader's) - and
			# while it serves no local socket its yt_info is empty, so gap_of
			# said -1 for it on every pass and this loop could never return 0
			# on the seven-node fixture, whatever the voters held.
			is_spare_node "$n" && continue
			g="$(gap_of "$n")"
			if [ "$g" = "-1" ]; then w=-1; break; fi
			if [ "$g" -gt 0 ]; then w="$g"; fi
		done
		if [ "$w" = "0" ]; then return 0; fi
		sleep 5
	done
	return 1
}
gaps_closed 24 \
	&& ok "every node is caught up before the outage" \
	|| bad "the cluster has subterm gap(s) before the test even starts"

check "the quorum took effect in $WITNESS's live config" "$MCS_TEST" \
	"$(info "$WITNESS" E cfg.min_cluster_size)"

# A verified seed: a baseline that did not actually replicate would make every
# later count meaningless.
wrote=0
for i in 1 2 3; do
	q "$L" "begin; insert into rv_t values (1,'before') on conflict do nothing;
	        select yt_complete(true); commit;" >/dev/null 2>&1
	sleep 3
	[ "$(q "$SUBJ" "select count(*) from rv_t where id=1")" = "1" ] && { wrote=1; break; }
done
[ "$wrote" = "1" ] \
	&& ok "the baseline row reached $SUBJ before it was stopped" \
	|| { bad "could not get a baseline row to $SUBJ"; summary; }

# ── the outage ──────────────────────────────────────────────────────────────
echo "  stopping $SUBJ for 10s..."
# -t 20: the entrypoint stops ytserv and PostgreSQL cleanly on SIGTERM; at -t 2
# docker SIGKILLed it first, and every start began with a crash recovery.
rh "docker stop -t 20 $SUBJ >/dev/null" 2>/dev/null || true
sleep 10

# It has to be really gone, or the writes below are not "made while it was
# down" and the catch-up assertion proves nothing.
down="$(q "$SUBJ" "select 1" 2>/dev/null || true)"
[ -z "$down" ] \
	&& ok "$SUBJ is down (its PostgreSQL does not answer)" \
	|| bad "$SUBJ still answers SQL after docker stop - it never went down"

still_led=""
for n in "${NODES[@]}"; do
	[ "$n" = "$SUBJ" ] && continue
	case "$(info "$n" O cluster)" in *Leader*) still_led="$n"; break;; esac
done
[ -n "$still_led" ] \
	&& ok "the cluster still has a leader with $SUBJ down" \
	|| bad "losing one node left the cluster with no leader"

# ── transactions it must miss ───────────────────────────────────────────────
#
# Each one verified on a node that IS up: a write that never committed is not a
# write the stopped node "missed", and counting it later would report a
# catch-up failure for a transaction that never happened.
# Each write is CONFIRMED on a node that is up, with a settle, before it counts
# as one the stopped node missed. Checked with no settle, the witness had not
# received it yet, every write looked refused, `posted` came out 0 - and the
# catch-up assertion below then passed vacuously as "0 of 0" while the stopped
# node was in fact missing a committed transaction. Only the digest comparison
# caught it. A test whose subject is "did it catch up" must not be able to
# conclude that from an empty set.
echo "  writing 5 transactions while $SUBJ is down..."
posted=0
committed=""
for i in 2 3 4 5 6; do
	q "$L" "begin; insert into rv_t values ($i,'during-$i') on conflict do nothing;
	        select yt_complete(true); commit;" >/dev/null 2>&1
	for _ in 1 2 3 4; do
		if [ "$(q "$WITNESS" "select count(*) from rv_t where id=$i")" = "1" ]; then
			posted=$((posted+1)); committed="$committed $i"; break
		fi
		sleep 3
	done
done
echo "     confirmed on $WITNESS:$committed"
echo "     committed while down: $posted of 5"
# REPORTED, not graded - and this took two wrong bars to see. `= 5` failed
# because the first write after a node vanishes routinely does: the party was
# picked before the peer went quiet. `>= 4` failed too, because the rate is not
# stable - 4 of 5 on one run, 2 of 5 on the next, at the same majority quorum.
#
# How many transactions a cluster completes while a node is missing is a
# property of the cluster under loss, and belongs in the output where somebody
# can watch it move. It is not what this script tests, and grading it made the
# script red for reasons unrelated to recovery twice running. What IS asserted
# is the floor: at least one, or the catch-up assertion below would be measuring
# an empty set.
echo "     (at the SUPPORTED default, min_cluster_size = the whole roster, this"
echo "      is 0 of 5 - a cluster built that way tolerates no node failure)"
[ "$posted" -ge 1 ] \
	&& ok "the cluster kept committing with a node down ($posted of 5, quorum $MCS_TEST)" \
	|| bad "nothing committed with one node down at min_cluster_size=$MCS_TEST of \
$(( ${#NODES[@]} - ${#SPARE_NODES[@]} )) voters - a majority quorum should absorb one loss"
[ "$posted" -ge 1 ] || { bad "nothing committed, so there is nothing to catch \
up and the rest of this test would pass vacuously"; summary; }
echo "     the stopped node must end up with all $posted of them"

check "$SUBJ is still stopped and has none of them" "0" \
	"$(q "$SUBJ" "select count(*) from rv_t where id>1" 2>/dev/null || echo 0)"

# ── back on ─────────────────────────────────────────────────────────────────
echo "  starting $SUBJ again..."
rh "docker start $SUBJ >/dev/null" 2>/dev/null || true

# The container first: PostgreSQL answering and its network interface up
# (env.sh node_ready). A crash recovery after the stop took three minutes once,
# and the 180 s below - which is about ytserv rejoining - ran out on it.
node_ready "$SUBJ" 600 \
	&& ok "$SUBJ is running again: PostgreSQL answers, network up" \
	|| { bad "$SUBJ's container did not come back (PostgreSQL / network) within 600s of docker start"; summary; }

# Answering SQL is PostgreSQL; answering yt_info is ytserv. Both have to come
# back, and the entrypoint starts them in that order.
back=0
for _ in $(seq 1 36); do
	if [ -n "$(info "$SUBJ" O cluster)" ]; then back=1; break; fi
	sleep 5
done
[ "$back" = "1" ] \
	&& ok "$SUBJ answers yt_info again (state: $(info "$SUBJ" E state))" \
	|| { bad "$SUBJ never came back within 180s of docker start"; summary; }

# It must rejoin as a participant, not sit in Spare forever - "appeared" is not
# the same as "is in the cluster".
rejoined=""
for _ in $(seq 1 36); do
	rejoined="$(info "$SUBJ" E state)"
	case "$rejoined" in
		Good|Leader|*Main*) break ;;
		*) sleep 5 ;;
	esac
done
case "$rejoined" in
	Good|Leader|*Main*) ok "$SUBJ rejoined as a participant (state: $rejoined)" ;;
	*) bad "$SUBJ came back but is stuck in [$rejoined] after 180s - it is \
present without participating" ;;
esac

# ── THE assertion: it caught up ─────────────────────────────────────────────
caught=0
for _ in $(seq 1 36); do
	caught="$(q "$SUBJ" "select count(*) from rv_t where id>1" 2>/dev/null || echo 0)"
	[ "${caught:-0}" -ge "$posted" ] && break
	# keep the table due so recon has a trigger, if WAL replay alone is not it
	q "$L" "begin; update rv_t set v=v where id=1; select yt_complete(true); commit;" >/dev/null 2>&1
	sleep 5
done
[ "${caught:-0}" -ge "$posted" ] \
	&& ok "$SUBJ caught up every transaction made while it was down ($caught of $posted)" \
	|| bad "$SUBJ has $caught of $posted transactions made while it was down, \
180s after rejoining - it is back in the write path with a hole"

# ...and the whole table agrees with a node that never went away.
check_same "$SUBJ and $WITNESS hold the identical table" "$SUBJ" "$WITNESS" \
	"select md5(string_agg(id::text||':'||v, ',' order by id)) from rv_t" 1 rv_t

# What each node actually holds, so a mismatch above is readable without a
# second run.
for n in "$SUBJ" "$WITNESS" "$L"; do
	printf "     %-4s %s\n" "$n" "$(q "$n" "select string_agg(id||':'||v, ' ' order by id) from rv_t")"
done

# The row goes back in on_exit (the EXIT trap above), whatever path got here.
summary
