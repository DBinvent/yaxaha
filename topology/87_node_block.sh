#!/usr/bin/env bash
# [blocking:node] The NODE scope of "Blocking: Row, Table, Node".
#
#   "A node that has drifted too far from the cluster is demoted out of the
#    write path rather than left to accumulate divergence."
#
# Two ways a node leaves the write path, and they are not the same mechanism:
#
# | | driven by | config | default |
# |---|---|---|---|
# | operator | `node_run` config row | `<uuid8>:pause` / `follow` | — |
# | automatic | the leader's ping tick | `auto_demote` | **off** |
#
# ## Why the operator path is asserted and the automatic one is observed
#
# `auto_demote` is off by default, and its own comment says why: an early
# version read IDLENESS as lag. On a cluster that simply has not written for a
# while every peer reports a position whose subterm closed minutes ago,
# `age_of` exceeds the budget, and they are all demoted to Spare - which is not
# `up()`, so `select_party` can no longer fill a party and EVERY write is
# refused, on a cluster whose pings, term and leadership look perfectly healthy.
# 6613 demotions on one leader before that was found (`grow.rs`).
#
# So this asserts the deterministic path end to end, and drives the automatic
# one far enough to show it is wired without making the suite depend on a race
# against a lag budget.
#
# ## What "out of the write path" means
#
# `PeerState::Pause` makes `up()` false (`peer.rs`), so the node stops being
# selectable for a party. The cluster must keep writing without it - that is the
# point of removing it - and it must come back on `follow`.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== blocking/node: a node is taken out of the write path, and comes back =="

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists nb_t; create table nb_t (id bigint primary key, v text);" >/dev/null
done
# recon=repair, because §3 asserts that a node which missed writes while paused
# gets them back. `register::budget` admits a returning node that is CLOSE
# ENOUGH - admission at half the budget, demotion past the whole - so rejoining
# a little behind is by design, and recon is what closes the remainder. Without
# a recon config nothing ever does, and the row is simply gone on that node.
NB_CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'recon=repair; recon_rows=1' | tail -1)"
register_table public.nb_t "$NB_CFG"
restart_all
await_cluster
wait_writable n1 n2 nb_t || { bad "cluster never became writable"; summary; }

L=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in *Leader) L="$n";; esac
done
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }

# A follower, and not the spare: the spare is already out of the write path, so
# pausing it would assert nothing.
SUBJ=""; WITNESS=""
for n in "${NODES[@]}"; do
	is_spare_node "$n" && continue
	[ "$n" = "$L" ] && continue
	if [ -z "$SUBJ" ]; then SUBJ="$n"; elif [ -z "$WITNESS" ]; then WITNESS="$n"; fi
done
[ -n "$SUBJ" ] && [ -n "$WITNESS" ] || { bad "need two non-spare followers"; summary; }
echo "  leader=$L  subject=$SUBJ  witness=$WITNESS"

# ## The uuid8 form, which is not the uuid
#
# `node_run` reaches EVERY node - it is a replicated config row - so a bare
# `pause` would pause the whole cluster. The prefix form addresses one, and the
# prefix is matched against `PeerUuid::as_uuid8()`, which is NOT the first eight
# characters of the uuid: it is `<first 2>..<last 6>`. Building it from
# `yt.node` keeps the test honest about the format the server actually compares.
uuid8_of() {
	q "$1" "select substr(u,1,2) || '..' || substr(u,31,6) from (select current_setting('yt.node') u) x"
}
U8="$(uuid8_of "$SUBJ")"
case "$U8" in
	??..??????) ok "$SUBJ uuid8 is $U8" ;;
	*) bad "could not build a uuid8 for $SUBJ - got [${U8:-<empty>}]"; summary ;;
esac

# Verified and retried, because the seed is SETUP. 85_alert.sh learned this the
# expensive way: a seed that quietly did not replicate makes the test report
# "the write never arrived" about the feature under test rather than about
# itself. Here it produced "the cluster writes before the pause - expected [1]
# got [0]" two seconds after a cold start.
seed() { # seed <id> <witness-node> — one committed write, confirmed to land
	local id="$1" who="$2" i
	for i in 1 2 3; do
		q "$L" "begin; insert into nb_t values ($id,'v$id') on conflict do nothing;
		        select yt_complete(true); commit;" >/dev/null 2>&1
		sleep 3
		[ "$(q "$who" "select count(*) from nb_t where id=$id")" = "1" ] && return 0
	done
	return 1
}

# ## The config table is a SYNCED table, so a subterm gap blocks it too
#
# `node_run` travels as a row in `yt_config`, which has the sync trigger like
# any other registered table - so while a node has a subterm gap, "writes to
# synced tables will wait and retry until they close" applies to the config
# write as much as to the data. Run after other scripts have restarted the
# cluster a few times, the push simply never lands and `cfg.node_run` stays
# empty: the same run that passed when this script went first failed when it
# went last. Wait for the gaps, then push.
gap_of() { # gap_of <node> -> subterms still missing, or -1 if unknown
	local m g
	m="$(info "$1" E health.metrics)"
	if [ -z "$m" ]; then printf '%s' "-1"; return; fi
	g="$(printf '%s' "$m" | sed -n 's/.*wal_gap \([0-9][0-9]*\).*/\1/p')"
	if [ -z "$g" ]; then printf '%s' "-1"; else printf '%s' "$g"; fi
}
wait_gaps_closed() {
	local i n w
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
if wait_gaps_closed 24; then
	ok "every node's apply path is caught up before the config push"
else
	bad "the cluster still has subterm gap(s) after 120s - a config write to \
yt_config waits on those exactly like a data write, so node_run would not land"
fi

# ## Why not `cfg_write`
#
# `cfg_write` writes a config row with the sync trigger DISABLED, on one node.
# That is right for pre-start configuration - the row is read by the startup
# loader - and wrong for this: `node_run` is acted on by `node_cmd_check`
# reading `recent_cfg`, which only changes when a config write travels the sync
# path and every node's `re_config` fires. Written with cfg_write on the leader,
# the row never left it, the subject never saw the command, and the test's first
# run reported "n1 is not paused" with no `[grow]` line on n1 at all - because
# nothing had asked it to pause.
cfg_push() { # cfg_push <name> <module> <value> — through the sync path
	q "$L" "begin;
	        delete from $YX_CFG where module='$2' and name='$1';
	        insert into $YX_CFG (name,module,value) values ('$1','$2','$3');
	        select yt_complete(true); commit;" >/dev/null 2>&1
}
seed 1 "$SUBJ" \
	&& ok "the cluster writes, and the write reaches $SUBJ, before the pause" \
	|| { bad "the cluster could not get a write to $SUBJ in 3 attempts - the \
precondition failed, so nothing below would mean anything"; summary; }

# ── 1a. a pause that would break quorum is REFUSED ─────────────────────────
#
# `do_pause` asks the leader first, and the leader may say no - removing this
# node would drop the cluster below `min_cluster_size`. That refusal is a safety
# property worth asserting on its own: an operator draining a node one at a time
# must be stopped before the last one, not after.
echo "  asking $SUBJ to pause via node_run (unforced)..."
cfg_push node_run C "$U8:pause"
sleep 15

# ## Read the STATE, not the log
#
# Every `[grow]` pause line is `info!`, and the fixture runs at
# `log_level=warning` - the level 10_up.sh sets and the guide recommends, since
# debug costs ~11%. So a log-based assertion here can only ever fail: n1 emitted
# zero INFO lines all run.
#
# `yt_info('O')` is no better - it reports the term and who the leader is, and
# Paused, Spare, Off and Main all print the same line. The node's own state was
# reachable only inside `yt_info('E')`'s row keyed by the full uuid, which an
# operator would have to know in advance. `E -> state` was added for this.
asked="$(rh "docker logs --since 3m $SUBJ 2>&1 | { grep -E '\[grow\]' || true; } | tail -3" 2>/dev/null || true)"
[ -n "$asked" ] && printf '     %s\n' "$asked"

state="$(info "$SUBJ" E state)"
echo "     $SUBJ state: ${state:-<no answer>}"
refused=0
case "$asked" in *refused*) refused=1 ;; esac

if [ "$refused" = "1" ]; then
	ok "the leader refused the unforced pause - it would break quorum"
	# ...and then force it, which is the documented escape hatch.
	echo "  forcing with pause!..."
	cfg_push node_run C "$U8:pause!"
	sleep 15
	state="$(info "$SUBJ" E state)"
	echo "     $SUBJ state: ${state:-<no answer>}"
fi

case "$state" in
	*Pause*) ok "$SUBJ reports itself Paused (yt_info('E') -> state)" ;;
	"")      bad "$SUBJ reports no state at all - yt_info('E') has no 'state' row, \
so an operator has no way to see whether node_run took effect" ;;
	*)       bad "$SUBJ is not paused, its state is [$state]" ;;
esac

# The row reaches every node; only the addressed one may act on it. Without
# this, `node_run` with a prefix that matched everybody would pass above.
others=""
for n in "${NODES[@]}"; do
	[ "$n" = "$SUBJ" ] && continue
	case "$(info "$n" E state)" in *Pause*) others="$others $n";; esac
done
[ -z "$others" ] \
	&& ok "no other node acted on the row - the prefix addressed exactly one" \
	|| bad "these nodes also paused:$others - the prefix match is too loose"

# ── 2. the cluster keeps writing without it ────────────────────────────────
#
# The whole point of taking a node out. A pause that also stopped the cluster
# would be an outage with extra steps.
# Witnessed on a node that is NOT the paused one - the point is that the cluster
# carries on without it.
seed 2 "$WITNESS" \
	&& ok "the cluster still commits with $SUBJ paused, and $WITNESS has it" \
	|| bad "the cluster stopped committing once $SUBJ was paused - a pause is \
supposed to remove a node, not the cluster"
check "the leader has it too" "1" \
	"$(q "$L" "select count(*) from nb_t where id=2")"

# ── 3. follow brings it back, and it catches up ────────────────────────────
# ## Poll, do not sleep-and-peek
#
# Resuming is not one step: `do_follow` moves Paused -> Spare, and the node then
# has to be ADMITTED by the leader, which it re-asks for every grow tick until
# its position is close enough. A fixed 20s window caught it mid-way and
# reported "still paused" about a node that reached Good shortly after.
echo "  resuming $SUBJ..."
cfg_push node_run C "$U8:follow"
state=""
for _ in $(seq 1 30); do
	state="$(info "$SUBJ" E state)"
	case "$state" in
		""|*Pause*) sleep 5 ;;
		*) break ;;
	esac
done
case "$state" in
	*Pause*) bad "$SUBJ is still paused 150s after follow: $state" ;;
	"")      bad "$SUBJ does not answer after follow" ;;
	*)       ok "$SUBJ is back in the cluster (state: $state)" ;;
esac
# The live config is what the command had to reach; without this the assertion
# above cannot tell "the command arrived and worked" from "something else
# un-paused it".
check "$SUBJ's LIVE config carries the follow command" "$U8:follow" \
	"$(info "$SUBJ" E cfg.node_run)"

seed 3 "$SUBJ" \
	&& ok "a write after resume reaches $SUBJ" \
	|| bad "$SUBJ is back in the cluster but writes do not reach it"

# ## The row it missed while paused
#
# A returning node is admitted while still slightly behind - that is the
# documented hysteresis, not a bug - so this is recon's job, not admission's.
# Give it rounds rather than a single look; `recon_rows=1` makes the table due
# on the next write.
caught=0
for _ in $(seq 1 24); do
	if [ "$(q "$SUBJ" "select count(*) from nb_t where id=2")" = "1" ]; then caught=1; break; fi
	# a write keeps the table due, so recon has something to trigger on
	q "$L" "begin; update nb_t set v=v where id=1; select yt_complete(true); commit;" >/dev/null 2>&1
	sleep 5
done
[ "$caught" = "1" ] \
	&& ok "the write it missed while paused was repaired by recon" \
	|| bad "120s after resuming, $SUBJ is still missing the write made while it \
was paused - it is back in the write path with a hole, and recon did not close it"

# ── 4. auto_demote is wired, and OFF by default ────────────────────────────
#
# Observed rather than asserted: see the header. What is asserted is the
# default, because the default is the safety property - a cluster that has not
# opted in must never demote a follower for being idle.
ad="$(q "$L" "select coalesce((select value from $YX_CFG where module='C' and name='auto_demote'),'<unset>')")"
case "$ad" in
	'<unset>'|false) ok "auto_demote is off by default ($ad) - idleness cannot demote anyone" ;;
	*) bad "auto_demote is [$ad] in a fixture that never set it" ;;
esac

# `grep -c` exits 1 on a count of zero - the expected case here - so the
# swallow goes INSIDE the remote command, not after it.
demotions="$(rh "docker logs --since 10m $L 2>&1 | { grep -c 'demoted .* to Spare' || true; }" | tail -1)"
[ "${demotions:-0}" -eq 0 ] \
	&& ok "the leader demoted nobody while auto_demote was off" \
	|| bad "$demotions demotion(s) logged with auto_demote off"

cfg_delete "$L" node_run C
summary
