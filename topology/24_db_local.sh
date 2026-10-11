#!/usr/bin/env bash
# [db-local] A node whose PostgreSQL is reached over TCP: a FOREVER-SPARE.
#
# `membership.md` §Forever-Spare. Such a node cannot originate a cluster write —
# it is not where the WAL is, not where `yt_complete` runs, and not what the
# extension is loaded into — so it must never be promoted. But it IS a full
# member for replication, the embedded etcd, rppd and the queue.
#
# ## The defect this exists to prevent, which it did not catch in time
#
# Run 1 (2026-09-24) found that such a node **did not start at all**:
# `is_single_master()` returned `Ok(false)` for two unrelated reasons — "Postgres
# is over TCP" and "another ytserv owns this socket" — and `main.rs` exited on
# both. Every gate, refusal and status row written for the Forever-Spare role
# was therefore unreachable. The rule was implemented, reviewed, documented, and
# dead.
#
# The FIXTURE found it, because the plan called for a seventh node of this kind;
# this script did not exist yet. It exists now so the fix cannot silently
# regress — and note that a regression would look exactly like it did: the node
# exits, the other six never complete a cold start, and every unrelated test
# fails on "cluster did not settle".
#
# ## What is NOT asserted here
#
# That a TCP url proves PostgreSQL is on another machine. It does not — `n7`'s
# database is in its own container. `can_be_main` is a test of the URL SHAPE
# (`rmc.rs::db_is_unix_socket`), deliberately weaker than `start_mode`'s, and
# that is the behaviour under test. See membership.md, "the two predicates".
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== db-local: a TCP-attached node is a forever-Spare, not a dead one =="

# No spare node is a FAIL, not a skip: this script exists because the forever-
# Spare role went untested once already (above), and a fixture without the node
# is that same silence. `:-` because env.sh runs under `set -u`, where a bare
# ${YX_SPARE_NODES%% *} on an unset variable aborts before any line is printed.
SUBJECT="${YX_SPARE_NODES:-}"
SUBJECT="${SUBJECT%% *}"
[ -n "$SUBJECT" ] || { bad "the fixture lacks a spare node: YX_SPARE_NODES is unset or empty, \
so there is no TCP-attached forever-Spare to test (run_a.sh's 7-node fixture sets \
YX_NODES with n7 and YX_SPARE_NODES=n7)"; summary; }
echo "  subject: $SUBJECT"

# The leader's OWN yt_info('O') ends in "Leader" with NO colon; a follower says
# "Leader: <uuid>". So `*Leader:*` matches every FOLLOWER and never the leader —
# which is how `24_db_local.sh`'s "the subject is not the leader" passed while
# comparing against a follower. `15_setup.sh:48` had it right all along.
leader_node() {
	local n
	for n in "${NODES[@]}"; do
		case "$(info "$n" O cluster)" in *Leader) printf '%s' "$n"; return;; esac
	done
}

# ── 1. it RUNS ──────────────────────────────────────────────────────────────
#
# First, and on its own, because every other assertion here is vacuous if the
# process is not alive. This is the one that was false.
alive="$(q "$SUBJECT" "select 1")"
check "$SUBJECT answers SQL" "1" "$alive"

info_o="$(info "$SUBJECT" O cluster)"
case "$info_o" in
	*Term*) ok "$SUBJECT's ytserv is up and answering yt_info" ;;
	*) bad "$SUBJECT's ytserv is not answering — [${info_o:-<empty>}]. If it exited, \
check for StartMode::SocketBusy being returned for a TCP url again" ;;
esac

# ── 2. it says WHY, in its own log ──────────────────────────────────────────
#
# An operator who wonders for weeks why a node is never promoted should find the
# answer in its first ten lines, not infer it from a node that never asks.
# `grep -c` exits 1 on a count of zero, and `|| echo 0` AFTER the pipeline then
# yields "0\n0" rather than "0" - so the one case this line exists to catch
# (the log line missing) made `[` fail on a malformed integer instead of
# reporting it. Swallow it inside the remote command.
logged="$(rh "docker logs $SUBJECT 2>&1 | { grep -c 'cannot be the write master' || true; }" | tail -1)"
[ "${logged:-0}" -gt 0 ] \
	&& ok "$SUBJECT logs why it can never be the write master" \
	|| bad "$SUBJECT does not say why it is ineligible"

# ── 3. yt_info reports the role ─────────────────────────────────────────────
fs="$(info "$SUBJECT" E forever_spare)"
case "$fs" in
	*TCP*|*write\ master*) ok "yt_info('E') reports forever_spare with a reason" ;;
	"") bad "yt_info('E') has no forever_spare row — an operator has no way to ask" ;;
	*)  ok "yt_info('E') reports forever_spare: $fs" ;;
esac

# ...and ONLY on that node. A row that appeared everywhere would be reporting
# nothing.
other=""
for n in "${NODES[@]}"; do
	is_spare_node "$n" && continue
	[ -n "$(info "$n" E forever_spare)" ] && other="$n"
done
check "no ordinary node reports forever_spare" "" "$other"

# ── 4. it is never Leader, and the cluster elects without it ───────────────
L="$(leader_node)"
[ -n "$L" ] && ok "the cluster has a leader ($L)" || bad "no leader"
[ "$L" = "$SUBJECT" ] && bad "$SUBJECT was elected LEADER — it cannot act as write master" \
	|| ok "$SUBJECT is not the leader"

# min_cluster_size excludes the spares, so a 7-node roster forming a 6-node
# cluster is itself the assertion.
check "quorum excludes the spare" "$(( ${#NODES[@]} - ${#SPARE_NODES[@]} ))" \
	"$(q "$L" "select value from $YX_CFG where module='C' and name='min_cluster_size'")"

# ── 5. it still RECEIVES replication ───────────────────────────────────────
#
# The half of the requirement that makes this a role rather than a failure.
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists dbl_t; create table dbl_t (id bigint primary key, v text);" >/dev/null
done
register_table public.dbl_t
restart_all
await_cluster
L="$(leader_node)"
wait_writable "$L" "$SUBJECT" dbl_t || bad "cluster never became writable toward $SUBJECT"

q "$L" "begin; insert into dbl_t values (1,'to-the-spare'); select yt_complete(true); commit;" >/dev/null
sleep 3
check "a write reaches the forever-Spare" "to-the-spare" \
	"$(q "$SUBJECT" "select v from dbl_t where id=1")"

# ── 6. it serves the embedded etcd ─────────────────────────────────────────
#
# "can be a forever spare for a etcd and rppd node" — the etcd half, which is
# what 35_queue_spare.sh then builds on.
etcd_on="$(q "$SUBJECT" "select value from $YX_CFG where module='C' and name='serve_etcd'")"
check "serve_etcd is on for $SUBJECT" "true" "$etcd_on"

summary
