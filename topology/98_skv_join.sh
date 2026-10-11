#!/usr/bin/env bash
# [skv §6] Join confirmation: the leader challenges a runtime joiner and admits
# it only on proof.
#
# ## The failure this exists to catch
#
# A confirmation gate that does not gate is indistinguishable from one that
# does, from every angle except an attacker's. Every node in this fixture is a
# cold-start peer from the roster and therefore NOT challenged (§6.1), so a
# suite that only watched the cluster come up would report a working gate having
# never exercised it once. That is why the first thing here is a NEGATIVE
# control: turn `skv` on and confirm a runtime `register()` is actually refused
# before believing anything that follows.
#
# ## What is and is not covered here
#
# Protocol B needs a provisioned master key, which is genesis (§2.1b) and lives
# in 97_skv.sh. This file covers what can be asserted without one:
#
#   1. skv off  -> joins are unchallenged, byte for byte today's behaviour
#   2. skv on   -> a runtime join is refused and says why
#   3.             a `J` row appears carrying a single-use challenge
#   4.             the challenge is STABLE across the node's retries
#   5. the yt_join_gate trigger refuses an `ok` nobody armed
#   6. module J is leader-restricted (CFGLC)
#   7. writing `ok` by hand admits nothing -- the arming is the decision
#   8. the pending row is swept past skv_approve_ttl_sec
#   8b. the approved key is recorded as a module-K row, leader-only (CFGLC)
#   9. Protocol C: `yxctl --skv-approve` on the leader, under the fixture's
#      SECRET, admits the subject - the J row goes, `K <uuid>` carries the
#      fingerprint the row showed, a follower cannot rewrite it - and the same
#      call under another SECRET arms nothing
#
# And 3b, which is §2.2 rather than §6: the pending row names the PUBLIC KEY the
# operator is being asked to approve. Genesis wraps the master key under
# whatever key it finds in the KV plane, so an approval over a bare uuid would
# authorise a substituted one -- the fingerprint being absent from this row is
# not cosmetic, it is the whole handoff exposure.
#
# Known limitation, stated rather than left to be found (§6.6): Protocols A and
# B prove knowledge, not channel ownership. Over a PLAINTEXT peer transport a
# relay attack is possible. `peer_tls` closes it, and is not exercised here --
# it is all-or-nothing across the cluster and needs each node's trust anchor
# placed in <fs_dir>/peers/, which this fixture does not do.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== skv join: a runtime joiner is admitted only on proof =="

# n6 is the subject. Chosen because it is a leaf in every az layout the suite
# uses, so pausing it cannot take quorum with it.
SUBJECT=n6
SUBJECT_UUID="$(node_uuid "$SUBJECT")"

leader_node() {
	local n
	for n in "${NODES[@]}"; do
		# `*Leader`, not `*Leader*`: only the leader's own line ENDS in "Leader" - a
		# follower's names it ("Leader: <uuid8>:<host>"), so the wider pattern picked
		# n1 whether or not it led, and the J row (leader-local) was read elsewhere.
		case "$(info "$n" O cluster)" in *Leader) printf '%s' "$n"; return;; esac
	done
}

# The J row as the leader holds it. Read on the leader specifically: the
# challenge lives in the leader's memory, so its row is the authoritative one.
j_row() { q "$1" "select value from $YX_CFG where module='J' and name='$SUBJECT_UUID'"; }

pause_subject() {
	cfg_write "$SUBJECT" node_run "S" "pause"
	sleep 12
}

# ── 0. reset ────────────────────────────────────────────────────────────────
for n in "${NODES[@]}"; do
	cfg_delete "$n" skv C
	cfg_delete "$n" skv_approve_ttl_sec C
	q "$n" "delete from $YX_CFG where module='J'" >/dev/null
done
restart_all
await_cluster
L="$(leader_node)"
[ -n "$L" ] || { bad "no leader; nothing below can be attributed"; summary; }
echo "  leader is $L, subject is $SUBJECT ($SUBJECT_UUID)"

# ── 1. skv off: unchallenged, exactly as today ──────────────────────────────
#
# The control. If a paused node cannot resume with the feature OFF then the
# fixture is broken and every refusal below would be meaningless.
pause_subject
check "skv off: the subject paused" "Paused" \
	"$(info "$SUBJECT" E "$SUBJECT_UUID" | grep -o 'Paused' | head -1)"
cfg_write "$SUBJECT" node_run S "follow"
sleep 15
state="$(info "$L" E "$SUBJECT_UUID")"
case "$state" in
	*Good*|*Leader*) ok "skv off: the subject resumed unchallenged" ;;
	*) bad "skv off: the subject did not resume — [$state]" ;;
esac
check "skv off: no J row is written" "" "$(j_row "$L")"

# ── 2. skv on: a runtime join is refused ────────────────────────────────────
for n in "${NODES[@]}"; do
	cfg_write "$n" skv C "true"
	# Long enough to outlive this section's own timeline. The subject's first
	# challenge can start at the restart below, not at `follow`: a node that
	# misses the synchronised cold start climbs back through register and is
	# challenged then (seen 2026-10-10: challenged 38 s before the pause), and
	# its later asks reuse that entry, as they must. §4 reads it again some 70 s
	# after that, so a 60 s TTL rotated it in between - a correct expiry read as
	# an unstable challenge. Section 8 does not time the sweep.
	cfg_write "$n" skv_approve_ttl_sec C "180"
done
restart_all
await_cluster
L="$(leader_node)"
[ -n "$L" ] || { bad "no leader after enabling skv"; summary; }

pause_subject
cfg_write "$SUBJECT" node_run S "follow"
sleep 20

state="$(info "$L" E "$SUBJECT_UUID")"
case "$state" in
	*Good*|*Leader*)
		bad "skv on: the subject was admitted WITHOUT proof — the gate is not gating" ;;
	*) ok "skv on: the subject is not a Follower" ;;
esac
# §6.1: neither Follower NOR Spare. Spare still receives the replication
# stream, so admitting an unconfirmed node to Spare would hand it the data --
# which is the failure that would look like success.
case "$state" in
	*Spare*) bad "skv on: the subject reached Spare, which still receives replication" ;;
	*) ok "skv on: the subject reached neither Follower nor Spare" ;;
esac

# ── 3. the J row, with a challenge ──────────────────────────────────────────
row="$(j_row "$L")"
case "$row" in
	pending:*:*) ok "a pending join row was written with a challenge and an expiry" ;;
	"")  bad "no J row on the leader — an operator has nothing to approve" ;;
	*)   bad "J row is not 'pending:<challenge>:<expires>:<fingerprint>' — [$row]" ;;
esac
ch1="$(printf '%s' "$row" | cut -d: -f2)"
check "the challenge is 32 bytes base64" "44" "$(printf '%s' "$ch1" | wc -c | tr -d ' ')"

# ── 3b. the row names the KEY the operator is being asked to approve ────────
#
# §2.2: genesis wraps the master key under whatever public key it finds in the
# KV plane, and the join request crosses a plaintext transport. An approval
# over a bare uuid would authorise a substituted key, so the fingerprint is in
# the row AND inside the approval MAC. If this field is missing, every approval
# below is approving an identity nobody looked at.
fp="$(printf '%s' "$row" | cut -d: -f4-)"
case "$fp" in
	SHA256:?*) ok "the pending row names the offered key ($fp)" ;;
	-)   ok "the subject offered no public key (it cannot receive the master key)" ;;
	"")  bad "the pending row carries no fingerprint - an operator would be approving a uuid" ;;
	*)   bad "fingerprint field is [$fp]" ;;
esac

# ── 4. the challenge is STABLE across retries ───────────────────────────────
#
# The defect this catches is invisible any other way: the node re-asks every
# 10 s, and if each unanswered round consumed the nonce the challenge would
# rotate faster than an operator could type, so Protocol C could never complete
# and nothing in either log would say why.
sleep 25
row2="$(j_row "$L")"
ch2="$(printf '%s' "$row2" | cut -d: -f2)"
check "the challenge survives the node's retries" "$ch1" "$ch2"

# ── 5. the trigger refuses an 'ok' nobody armed ─────────────────────────────
#
# Run ON the leader and over its unix socket, so gates 1-3 all pass and the only
# thing left to refuse the write is gate 4/5 -- which is the point.
err="$(q "$L" "update $YX_CFG set value='ok' where module='J' and name='$SUBJECT_UUID';" 2>&1)"
after="$(j_row "$L")"
case "$after" in
	pending:*) ok "an unarmed 'ok' was refused and nothing was stored" ;;
	ok)        bad "an unarmed 'ok' was STORED — the yt_join_gate trigger is missing" ;;
	*)         bad "J row is now [$after]" ;;
esac

# ── 6. module J is leader-restricted ────────────────────────────────────────
#
# CFGLC, enforced by cluster.rs. Asserted on a follower, where the J row exists
# only if the config table is synced; if it is not, the row is absent and the
# update affects nothing, which is the same refusal by a different route.
F=n1; [ "$F" = "$L" ] && F=n2
out="$(q "$F" "update $YX_CFG set value='ok' where module='J' and name='$SUBJECT_UUID';" 2>&1)"
fr="$(j_row "$F")"
case "$fr" in
	ok) bad "a follower stored an approval — module J is not leader-restricted" ;;
	*)  ok "a follower cannot store an approval" ;;
esac

# ── 7. a hand-written 'ok' admits nothing ───────────────────────────────────
#
# THE property that makes this design tolerate a replicated yt_config: the
# arming is the decision and the row is the record. Bypass every database gate
# -- disable the trigger, write `ok` directly -- and the node must still not be
# admitted, because nothing reads that row to grant anything.
q "$L" "alter table $YX_CFG disable trigger user;
        update $YX_CFG set value='ok' where module='J' and name='$SUBJECT_UUID';
        alter table $YX_CFG enable trigger user;" >/dev/null
cfg_write "$SUBJECT" node_run S "follow"
sleep 20
state="$(info "$L" E "$SUBJECT_UUID")"
case "$state" in
	*Good*|*Leader*)
		bad "a forged 'ok' row admitted the node — admission is reading the row" ;;
	*) ok "a forged 'ok' row admits nothing: the arming is the decision" ;;
esac

# ── 8. an unapproved pending row is swept ───────────────────────────────────
#
# skv_approve_ttl_sec is 180 above (not timed here), and the sweep rides the 5 s
# monitor tick.
# Clear the forged value first so what is being timed is a real pending row.
q "$L" "alter table $YX_CFG disable trigger user;
        delete from $YX_CFG where module='J';
        alter table $YX_CFG enable trigger user;" >/dev/null
cfg_write "$SUBJECT" node_run S "follow"
sleep 15
[ -n "$(j_row "$L")" ] && ok "a fresh pending row was written" \
	|| bad "no pending row to time the sweep against"

# ── 8b. the approved key is recorded, and only the leader may record it ─────
#
# The module-K row is what `skv_share_master` checks before wrapping the master
# key under a node's public key. Its absence is not cosmetic: it is the
# difference between "wrap for the key we approved" and "wrap for whatever is
# in the KV plane".
kfp="$(q "$L" "select value from $YX_CFG where module='K' and name='$SUBJECT_UUID'")"
case "$kfp" in
	SHA256:?*) ok "the approved key is recorded as a module-K row" ;;
	"")  echo "  note: no K row yet - the subject was never granted in this run" ;;
	*)   bad "K row is [$kfp], not a fingerprint" ;;
esac
# CFGLC: a follower must not be able to authorise a key of its own choosing
q "$F" "update $YX_CFG set value='SHA256:forged' where module='K' and name='$SUBJECT_UUID';" \
	>/dev/null 2>&1
after_k="$(q "$F" "select value from $YX_CFG where module='K' and name='$SUBJECT_UUID'")"
case "$after_k" in
	SHA256:forged) bad "a follower rewrote a module-K row - K is not leader-restricted" ;;
	*) ok "a follower cannot rewrite an approved key" ;;
esac

# ── 9. Protocol C: the operator approves on the leader ──────────────────────
#
# Everything above shows the gate holds. This is the door it opens:
# `yxctl --skv-approve <uuid>` on the LEADER's host reads the J row, MACs
# challenge || uuid || fingerprint under the app key, and sends it over ytserv's
# unix socket; the leader verifies it with ITS app key over ITS entry and arms
# it, yxctl writes `ok` (the yt_join_gate trigger lets it through now), and the
# subject's next ask is admitted. The app key is the fixture's SECRET, given to
# every container by 10_up.sh - a container made before that has none, and the
# leader says so ("no app key").
#
# The negative first, while the entry is still pending: the same call under
# another SECRET must arm nothing.
approve() { # approve <node> <secret> -> yxctl's output; its exit status
	local node="$1" secret="$2"
	local cmd="yxctl --skv-approve $SUBJECT_UUID --yes -U postgres -d $YX_DB -t $YX_CFG"
	if [ "$YX_HOST" = "local" ]; then
		docker exec -u postgres -e SECRET="$secret" "$node" $cmd 2>&1
	else
		"${YX_SSH[@]}" "$YX_HOST" "docker exec -u postgres -e SECRET='$secret' $node $cmd" 2>&1
	fi
}
# The J row once it has time left to be approved in: the leader's own clock, and
# a challenge that would expire under the call is waited out (it rotates at its
# expiry, on the subject's next ask).
fresh_row() {
	local row exp now
	for _ in $(seq 1 45); do
		row="$(j_row "$L")"
		exp="$(printf '%s' "$row" | cut -d: -f3)"
		now="$(q "$L" "select extract(epoch from now())::bigint")"
		case "$row" in
			pending:*) [ -n "$exp" ] && [ -n "$now" ] && [ $((exp - now)) -ge 30 ] \
				&& { printf '%s' "$row"; return 0; } ;;
		esac
		sleep 5
	done
	return 1
}

row="$(fresh_row)" || row=""
[ -n "$row" ] && ok "a pending J row with time left to approve" \
	|| bad "no pending J row with 30 s left on the leader - [$(j_row "$L")]"
fp_row="$(printf '%s' "$row" | cut -d: -f4-)"
case "$fp_row" in
	SHA256:?*) ok "the subject offered its node key: the row names $fp_row, not '-'" ;;
	*) bad "the pending row's fingerprint is [$fp_row] - the subject offered no node key" ;;
esac

out="$(approve "$L" "not-the-fixture-secret")" && rc=0 || rc=$?
case "$rc:$out" in
	0:*) bad "an approval under another SECRET was ACCEPTED - [$out]" ;;
	*"wrong MAC"*) ok "an approval under another SECRET is refused: wrong MAC" ;;
	*) bad "an approval under another SECRET failed, but not on its MAC (rc $rc) - [$out]" ;;
esac
gate="$(info "$L" "J:$SUBJECT_UUID" "$SUBJECT_UUID")"
case "$gate" in
	*'"ok":false'*) ok "a wrong MAC arms nothing: yt_info('J:<uuid>') still refuses" ;;
	*) bad "after a wrong MAC yt_info('J:<uuid>') says [$gate]" ;;
esac
check "a wrong MAC leaves the J row as it was" "$row" "$(j_row "$L")"
sleep 12
case "$(info "$L" E "$SUBJECT_UUID")" in
	*Good*|*Leader*) bad "the subject was admitted after an approval with a wrong MAC" ;;
	*) ok "the subject is still held after an approval with a wrong MAC" ;;
esac

out="$(approve "$L" "$YX_SECRET")" && rc=0 || rc=$?
case "$rc:$out" in
	0:*"Approved"*) ok "yxctl --skv-approve on the leader armed the join" ;;
	*) bad "yxctl --skv-approve on the leader failed (rc $rc) - [$out]" ;;
esac
admitted=""
for _ in $(seq 1 15); do
	case "$(info "$L" E "$SUBJECT_UUID")" in *Good*|*Leader*) admitted=1; break ;; esac
	sleep 2
done
[ -n "$admitted" ] && ok "the approved subject reached Follower within 30 s" \
	|| bad "the subject is not a Follower 30 s after the approval - [$(info "$L" E "$SUBJECT_UUID")]"
check "the J row is gone once the approval was consumed" "" "$(j_row "$L")"

# the record: written by the leader right after the consumption, as a cluster
# transaction - so it can trail the admission by a moment
k_row() { q "$1" "select value from $YX_CFG where module='K' and name='$SUBJECT_UUID'"; }
kv=""
for _ in $(seq 1 10); do kv="$(k_row "$L")"; [ -n "$kv" ] && break; sleep 1; done
check "the leader recorded K <uuid> = the fingerprint the J row showed" "$fp_row" "$kv"
fk="$(k_row "$F")"
case "$fk" in
	"$fp_row") ok "the K row reached a follower ($F)" ;;
	"") echo "  note: the K row has not reached $F - it replicates only through the synced config table" ;;
	*) bad "$F holds K = [$fk], not [$fp_row]" ;;
esac
# leader-only: a follower's rewrite is refused by check_re_config (the UPDATE
# carries no module column, so ytserv reads whose row it is by its id)
q "$F" "update $YX_CFG set value='SHA256:forged' where module='K' and name='$SUBJECT_UUID';" >/dev/null 2>&1
check "a follower cannot rewrite the approved key (on $F)" "$fk" "$(k_row "$F")"
check "a follower's rewrite does not reach the leader either" "$fp_row" "$(k_row "$L")"

# ── 10. restore ─────────────────────────────────────────────────────────────
#
# skv OFF again, so a later test in the run does not inherit a cluster that
# refuses every join. The suite's tests are ordered but not isolated.
for n in "${NODES[@]}"; do
	cfg_delete "$n" skv C
	cfg_delete "$n" skv_approve_ttl_sec C
	cfg_delete "$n" node_run S
	q "$n" "delete from $YX_CFG where module='J'" >/dev/null
	# the subject's approved key: a K row named by a uuid is leader-only, so it
	# goes with the sync trigger off, on every node - like cfg_delete
	cfg_delete "$n" "$SUBJECT_UUID" K
done
restart_all
await_cluster
L="$(leader_node)"
[ -n "$L" ] && ok "cluster restored with skv off" || bad "cluster did not settle after restore"

summary
