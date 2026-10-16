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
#   9. the approval as SQL (ytserv skv.md "Approval"): on a follower `yxctl
#      --skv-approve` is refused, a value someone typed is refused by the trigger,
#      and `select yt_approve('<uuid>')` on the leader admits the subject - the J
#      row goes, `K <uuid>` carries the fingerprint the row showed, a follower
#      cannot rewrite it
#  11. a restart of a member whose key was approved comes back through the gate,
#      re-admitted by the proof of that key - no operator
#  12. a leader change keeps an approval: approved on one leader, admitted by the
#      next, which took the replicated J row over
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

# The subject: a voter that is NOT the leader, n6 first - a leaf in every az
# layout the suite uses, so pausing it cannot take quorum with it. Picked again
# after each restart: a leader cannot be paused (pause is a handover, the node
# stays Leader), and when the election after the skv-on restart picked n6 itself
# that read as "the subject was admitted WITHOUT proof" - the nightlies of
# 2026-10-09..11, reproduced 2026-10-11 with leader_uuid = n6 on every node.
SUBJECT=""; SUBJECT_UUID=""
pick_subject() {
	local c
	for c in n6 $(printf '%s\n' "${NODES[@]}" | tac); do
		is_spare_node "$c" && continue
		[ "$c" = "${L:-}" ] && continue
		SUBJECT="$c"; SUBJECT_UUID="$(node_uuid "$c")"; return 0
	done
}

leader_node() {
	local n
	for n in "${NODES[@]}"; do
		# `*Leader`, not `*Leader*`: only the leader's own line ENDS in "Leader" - a
		# follower's names it ("Leader: <uuid8>:<host>"), so the wider pattern picked
		# n1 whether or not it led, and the J row (leader-local) was read elsewhere.
		case "$(info "$n" O cluster)" in *Leader) printf '%s' "$n"; return;; esac
	done
}

# One leader, the one the others follow: right after a restart with skv on, a
# second node still called itself Leader for a while, leader_node() returned it
# (the first in roster order), and every leader-local read - the J row, the
# subject's state, --skv-approve - went to the wrong node (2026-10-11, run 3:
# n3 challenged the subject, the test read elsewhere). Waits up to 60 s for a
# single self-declared leader that a majority of the voters follow; prints the claims
# while there are several.
settled_leader() {
	local i n line claim u8 named
	for i in $(seq 1 30); do
		claim=""; named=0
		for n in "${NODES[@]}"; do
			line="$(info "$n" O cluster)"
			case "$line" in *Leader) claim="$claim $n";; esac
		done
		claim="${claim# }"
		if [ -n "$claim" ] && [ "${claim// /}" = "$claim" ]; then
			u8="$(node_uuid "$claim" | sed -E 's/^(..).*(......)$/\1..\2/')"
			for n in "${NODES[@]}"; do
				[ "$n" = "$claim" ] && continue
				is_spare_node "$n" && continue
				case "$(info "$n" O cluster)" in *"Leader: $u8"*) named=$((named + 1));; esac
			done
			# a majority of the voters, not all: a joiner held Unconfirmed names nobody
			if [ $(( (named + 1) * 2 )) -gt $(( ${#NODES[@]} - ${#SPARE_NODES[@]} )) ]; then
				printf '%s' "$claim"; return 0
			fi
		fi
		[ "$i" = 1 ] || [ "$((i % 5))" = 0 ] && echo "  (leader not settled: claimed by [${claim:-nobody}], named by $named)" >&2
		sleep 2
	done
	leader_node
}

# The J row as the leader holds it. Read on the leader specifically: the
# challenge lives in the leader's memory, so its row is the authoritative one.
j_row() { q "$1" "select value from $YX_CFG where module='J' and name='$SUBJECT_UUID'"; }

# Approve on the leader every pending join but the subject's: a voter that missed
# the synchronised cold start after skv went on climbs back through register and
# is held Unconfirmed like any joiner - sent nothing, and not counted in a quorum.
approve_others() {
	local u
	for _ in $(seq 1 15); do
		local left=0
		for u in $(q "$L" "select name from $YX_CFG where module='J' and value like 'pending:%' and name <> '$SUBJECT_UUID'"); do
			q "$L" "select yt_approve('$u')" >/dev/null 2>&1
			left=1
		done
		[ "$left" = 0 ] && return 0
		sleep 4
	done
}
# A voter the leader counts as Good, neither the leader nor the subject
good_follower() {
	local n
	for n in "${NODES[@]}"; do
		[ "$n" = "$L" ] || [ "$n" = "$SUBJECT" ] || is_spare_node "$n" && continue
		case "$(info "$L" E "$(node_uuid "$n")")" in *Good*) echo "$n"; return 0 ;; esac
	done
	return 1
}

pause_subject() {
	cfg_write "$SUBJECT" node_run "S" "pause"
	sleep 12
}

# ── 0. reset ────────────────────────────────────────────────────────────────
for n in "${NODES[@]}"; do
	cfg_delete "$n" skv C
	cfg_delete "$n" skv_approve_ttl_sec C
	cfg_tx "$n" "J rows" "delete from $YX_CFG where module='J';"
done
restart_all
await_cluster
L="$(settled_leader)"
[ -n "$L" ] || { bad "no leader; nothing below can be attributed"; summary; }
pick_subject
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
L="$(settled_leader)"
[ -n "$L" ] || { bad "no leader after enabling skv"; summary; }
pick_subject
echo "  skv on: leader is $L, subject is $SUBJECT ($SUBJECT_UUID)"
approve_others

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
F="$(good_follower)" || F=n1
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
# On every node, triggers off: the J rows replicate now, and a row left on a
# follower would sit beside the leader's next one.
for n in "${NODES[@]}"; do cfg_tx "$n" "J rows" "delete from $YX_CFG where module='J';"; done
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

# ── 9. the approval as SQL: the operator approves on the leader ─────────────
#
# Everything above shows the gate holds. This is the door it opens: on the leader
# `select yt_approve('<uuid>')` has ytserv sign the approval of the entry it holds
# (`yt_info('J!:<uuid>')`, `ok:<kid>:<challenge>:<expires>:<mac>:<fingerprint>` -
# nothing secret, the key stays in ytserv's memory) and writes it into the J row;
# the yt_join_gate trigger hands it to the leader (`yt_info('J=:..')`), which
# arms the entry, and the subject's next ask is admitted. `yxctl --skv-approve`
# runs the same SQL. No SECRET: the app key is a node's own.
#
# The negatives first, while the entry is still pending: yxctl on a follower,
# and a value someone typed, arm nothing.
approve() { # approve <node> -> yxctl's output; its exit status
	local node="$1"
	local cmd="yxctl --skv-approve $SUBJECT_UUID --yes -U postgres -d $YX_DB -t $YX_CFG"
	if [ "$YX_HOST" = "local" ]; then
		docker exec -u postgres "$node" $cmd 2>&1
	else
		"${YX_SSH[@]}" "$YX_HOST" "docker exec -u postgres $node $cmd" 2>&1
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
case "$(j_row "$F")" in
	"$row") ok "the pending row reached a follower ($F): a next leader holds it" ;;
	*) bad "$F holds J [$(j_row "$F")], not the leader's pending row" ;;
esac

out="$(approve "$F")" && rc=0 || rc=$?
case "$rc:$out" in
	0:*) bad "an approval on a follower was ACCEPTED - [$out]" ;;
	*"not the leader"*) ok "yxctl --skv-approve on a follower is refused: not the leader" ;;
	*) bad "yxctl --skv-approve on a follower failed, but not as 'not the leader' (rc $rc) - [$out]" ;;
esac
# a value someone typed: the leader's own signature with one bit of it changed
signed="$(info "$L" "J!:$SUBJECT_UUID" "$SUBJECT_UUID")"
case "$signed" in
	ok:*) ok "yt_info('J!:<uuid>') on the leader signs the approval ($(printf '%s' "$signed" | cut -d: -f2))" ;;
	*) bad "yt_info('J!:<uuid>') on the leader did not sign - [$signed]" ;;
esac
mac="$(printf '%s' "$signed" | cut -d: -f5)"
case "${mac:0:1}" in A) m2="B${mac:1}" ;; *) m2="A${mac:1}" ;; esac
typed="$(printf '%s' "$signed" | awk -F: -v m="$m2" 'BEGIN{OFS=":"} {$5=m; print}')"
err="$(qe "$L" "update $YX_CFG set value='$typed' where module='J' and name='$SUBJECT_UUID';")"
case "$err" in
	*"does not verify"*) ok "a typed approval is refused by the trigger: it does not verify" ;;
	*) bad "a typed approval was not refused as unverified - [$err]" ;;
esac
gate="$(info "$L" "J:$SUBJECT_UUID" "$SUBJECT_UUID")"
case "$gate" in
	*'"ok":false'*) ok "nothing armed: yt_info('J:<uuid>') still refuses" ;;
	*) bad "after the refusals yt_info('J:<uuid>') says [$gate]" ;;
esac
check "the refusals leave the J row as it was" "$row" "$(j_row "$L")"
sleep 12
case "$(info "$L" E "$SUBJECT_UUID")" in
	*Good*|*Leader*) bad "the subject was admitted after refused approvals" ;;
	*) ok "the subject is still held after the refused approvals" ;;
esac

out="$(q "$L" "select yt_approve('$SUBJECT_UUID')" 2>&1)"
case "$out" in
	ok:*) ok "select yt_approve('<uuid>') on the leader recorded the approval" ;;
	*) bad "yt_approve on the leader failed - [$out]" ;;
esac
# approved, it may first be told to catch up as a Spare (the age check), then is
# granted at a later ask
admitted=""
for _ in $(seq 1 60); do
	case "$(info "$L" E "$SUBJECT_UUID")" in *Good*|*Leader*) admitted=1; break ;; esac
	sleep 2
done
[ -n "$admitted" ] && ok "the approved subject reached Follower within 120 s" \
	|| bad "the subject is not a Follower 120 s after the approval - [$(info "$L" E "$SUBJECT_UUID")]"
check "the J row is gone once the approval was consumed" "" "$(j_row "$L")"

# the record: written by the leader right after the consumption, as a cluster
# transaction - so it can trail the admission by a moment, more when its commit
# meets the admission's own party change and is retried (2 s apart, ytserv 0.20.78)
k_row() { q "$1" "select value from $YX_CFG where module='K' and name='$SUBJECT_UUID'"; }
kv=""
for _ in $(seq 1 20); do kv="$(k_row "$L")"; [ -n "$kv" ] && break; sleep 1; done
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

# ── 11. a restart comes back through the gate, by its proof ─────────────────
#
# The subject's key is approved now (its K row). With skv on, a member whose key
# was approved comes back into a live term through register: it stays Spare, asks
# to follow, and the leader re-admits it by the proof of that key - no operator
# (ytserv skv_join.rs skv_restart_gated / skv_rearm_by_proof). Before, a restart
# promoted itself and the gate never saw it.
rh "docker restart $SUBJECT >/dev/null"
# its own log first: the leader's view of it stays Good until its pings fail
asked=""
for _ in $(seq 1 45); do
	c="$(rh "docker logs --since 3m $SUBJECT 2>&1 | grep -c 'asking to follow - re-admitted' || true" | tail -1)"
	[ "${c:-0}" -gt 0 ] && { asked=1; break; }
	sleep 2
done
[ -n "$asked" ] && ok "11 the restarted subject came back by asking to follow, not by itself" \
	|| bad "11 the subject never logged asking to follow in 90 s - its restart bypassed the gate"
back=""
for _ in $(seq 1 45); do
	c="$(rh "docker logs --since 3m $L 2>&1 | grep -c 're-admitted by its proof' || true" | tail -1)"
	case "$c:$(info "$L" E "$SUBJECT_UUID")" in [1-9]*Good*|[1-9]*Leader*) back=1; break ;; esac
	sleep 2
done
[ -n "$back" ] && ok "11 ...re-admitted by the proof of its approved key, a Follower again - no operator" \
	|| bad "11 no re-admission by proof in 90 s - [$(info "$L" E "$SUBJECT_UUID")]"

# ── 12. a leader change keeps an approval ───────────────────────────────────
#
# Its K row gone, the subject is a joiner again: held, a pending row written and
# replicated. Off the network (its process and memory kept), approved on this
# leader with yt_approve, the leadership moved, back on the network: the next
# leader took the approval over from the replicated J row and admits it - no
# second approval.
for n in "${NODES[@]}"; do cfg_delete "$n" "$SUBJECT_UUID" K; done
pause_subject
cfg_write "$SUBJECT" node_run S "follow"
row=""
for _ in $(seq 1 30); do row="$(j_row "$L")"; case "$row" in pending:*) break ;; esac; sleep 2; done
case "$row" in
	pending:*) ok "12 the subject is a joiner again: a pending row" ;;
	*) bad "12 no pending row for the subject - [$row]" ;;
esac
approve_others
node_down "$SUBJECT"
exp_old="$(j_row "$L" | cut -d: -f3)"
out="$(q "$L" "select yt_approve('$SUBJECT_UUID')" 2>&1)"
case "$out" in ok:*) ok "12 approved on the leader $L" ;; *) bad "12 yt_approve on $L failed - [$out]" ;; esac
OLD_L="$L"
# the next leader: any other voter that takes it (a promote is refused to a node
# that judges itself behind - election.rs promote_refusal)
for NL in $(printf '%s\n' "${NODES[@]}"); do
	[ "$NL" = "$OLD_L" ] || [ "$NL" = "$SUBJECT" ] || is_spare_node "$NL" && continue
	case "$(info "$OLD_L" E "$(node_uuid "$NL")")" in *Good*) ;; *) continue ;; esac
	case "$(j_row "$NL")" in
		ok:*) ok "12 the approval reached $NL" ;;
		*) bad "12 $NL holds J [$(j_row "$NL")], not the approval" ;;
	esac
	NIP="$(rh "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $NL")"
	echo "  force-election to $NL ($NIP): $(qe "$OLD_L" "select yt_info('e:$NIP:$YX_PORT')" | cut -c1-200)"
	for _ in $(seq 1 20); do [ "$(settled_leader)" = "$NL" ] && break; sleep 2; done
	[ "$(settled_leader)" = "$NL" ] && break
done
L="$(settled_leader)"
[ -n "$L" ] && [ "$L" != "$OLD_L" ] && ok "12 the leadership moved from $OLD_L to $L" \
	|| bad "12 the leadership did not move from $OLD_L - [$L]"
c="$(rh "docker logs --since 5m $L 2>&1 | grep -c 'took over the J rows' || true" | tail -1)"
[ "${c:-0}" -gt 0 ] && ok "12 the new leader $L took the J rows over" || bad "12 $L never logged taking the J rows over"
# This fixture runs without the secret store: the approval was signed with
# $OLD_L's own process key (`ok:local:..`), which no other node holds. The next
# leader keeps the entry - the same challenge and expiry, so the joiner is not
# challenged again - and the approval is given again under it. With a master key
# (`ok:mk<v>:..`) the approval itself carries over (skv.md "Approval").
kid="$(j_row "$L" | cut -d: -f2)"
pending_new="$(info "$L" J "$SUBJECT_UUID")"
case "$kid:$pending_new" in
	local:*"expires $exp_old "*) ok "12 $L holds the subject's entry with its challenge, not armed: a local approval is given again" ;;
	*) bad "12 after the move: kid [$kid], $L's entry [$pending_new], expires before [$exp_old]" ;;
esac
node_up "$SUBJECT"
out="$(q "$L" "select yt_approve('$SUBJECT_UUID')" 2>&1)"
case "$out" in ok:local:*) ok "12 approved again under $L" ;; *) bad "12 yt_approve on $L failed - [$out]" ;; esac
admitted=""
for _ in $(seq 1 30); do
	case "$(info "$L" E "$SUBJECT_UUID")" in *Good*|*Leader*) admitted=1; break ;; esac
	sleep 2
done
[ -n "$admitted" ] && ok "12 the new leader $L admitted the subject, its challenge unchanged" \
	|| bad "12 the subject is not a Follower under $L 60 s after its return - [$(info "$L" E "$SUBJECT_UUID")]"

# ── 10. restore ─────────────────────────────────────────────────────────────
#
# skv OFF again, so a later test in the run does not inherit a cluster that
# refuses every join. The suite's tests are ordered but not isolated.
for n in "${NODES[@]}"; do
	cfg_delete "$n" skv C
	cfg_delete "$n" skv_approve_ttl_sec C
	cfg_delete "$n" node_run S
	cfg_tx "$n" "J rows" "delete from $YX_CFG where module='J';"
	# the subject's approved key: a K row named by a uuid is leader-only, so it
	# goes with the sync trigger off, on every node - like cfg_delete
	cfg_delete "$n" "$SUBJECT_UUID" K
done
restart_all
await_cluster
L="$(settled_leader)"
[ -n "$L" ] && ok "cluster restored with skv off" || bad "cluster did not settle after restore"

summary
