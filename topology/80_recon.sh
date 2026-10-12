#!/usr/bin/env bash
# [recon] Does self-healing actually heal? The repair path had NEVER executed
# against a live cluster until 2026-09-18 - `pk_columns` bound a String to
# `$1::regclass` and failed on every call, and `yt_info('E')` reporting
# "0 round(s), 0 row(s) checked" is indistinguishable from "nothing needed
# repair". This test exists so that cannot happen again.
#
# Divergence is created OUT OF BAND - the sync trigger is disabled on one node,
# the row changed there, the trigger put back - which is the only way to produce
# a genuinely divergent row without a cluster bug. That is also what a real
# divergence looks like: a write the cluster never saw.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== recon: a divergent row is detected and repaired =="

for n in "${NODES[@]}"; do
	q "$n" "drop table if exists rc_t; create table rc_t (id bigint primary key, v text);" >/dev/null
done

# rows=1 so a single write makes the table due on the next poll; repair mode so
# a losing node rewrites itself rather than only reporting
CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'recon=repair; recon_rows=1' | tail -1)"
echo "  recon config: $CFG"
# register_table, not yt_setup: yt_setup creates the trigger and writes the
# module-A row in ONE transaction, and on a node whose config table is synced
# that write is refused unless the node is the leader - rolling the CREATE
# TRIGGER back with it. The node then has neither, and every write there dies
# with `yt_complete: not connected`. See env.sh.
register_table public.rc_t "$CFG"
restart_all
await_cluster

# settle after restart_all: await_cluster proves a leader is agreed, not that
# every node is answering pings inside the deadline again
sleep 15

# Seeded as SEPARATE single-row transactions, not one multi-row statement.
#
# A multi-statement transaction on this cluster intermittently aborts with
# "Not enought working nodes ... requirements: N": the node is busy applying, a
# peer misses the ping deadline, flaps to "switched off", and select_party can
# no longer fill a party. It is flaky rather than size-dependent - across two
# runs a 20-row seed succeeded while a 10-row one failed, and then they swapped.
#
# That instability is real and pre-existing (see the PHASE 3/4 record), but it is
# NOT what this test is for. Seeding one row per transaction uses the write path
# that is reliable, so a failure here means recon failed, not the write path.
for i in $(seq 1 8); do
	q n1 "begin; insert into rc_t values ($i,'good-$i'); select yt_complete(true); commit;" >/dev/null
	sleep 1
done
for _ in $(seq 1 12); do
	[ "$(q n4 "select count(*) from rc_t")" = "8" ] && break
	sleep 5
done
check "the seed replicated to n4" "8" "$(q n4 "select count(*) from rc_t")"
check "n4 row 7 is the seeded value" "good-7" "$(q n4 "select v from rc_t where id=7")"

# ── create the divergence: n4 only, cluster never sees it ──────────────────
trg="$(q n4 "select tgname from pg_trigger where tgrelid='rc_t'::regclass and not tgisinternal and (tgtype & 1) = 1 limit 1")"
echo "  disabling $trg on n4, corrupting row 7, re-enabling"
# One transaction, its error printed, retried: three autocommit statements with
# the errors thrown away let a lock timeout on the ALTER (recon was rewriting
# rc_t under load then) skip the corruption, and the check below read the
# original value - "expected [CORRUPT] got [good-7]" on 2026-10-11.
divergent() { info n4 E recon | sed -n 's/.* \([0-9][0-9]*\) divergent.*/\1/p'; }
div0="$(divergent)"
for try in 1 2 3; do
	out="$(qe n4 "begin;
	      alter table rc_t disable trigger $trg;
	      update rc_t set v='CORRUPT' where id=7 returning v;
	      alter table rc_t enable trigger $trg;
	      commit;")" || true
	case "$out" in
		*ERROR*) echo "  corruption try $try failed: $(printf '%s\n' "$out" | grep -m1 ERROR)"; sleep 5 ;;
		*) break ;;
	esac
done
case "$out" in *ERROR*|"") ok_c="";; *CORRUPT*) ok_c=CORRUPT;; *) ok_c="";; esac
check "n4 row 7 corrupted, the cluster not told" "CORRUPT" "${ok_c:-[$out]}"
# Divergent now - or already repaired: recon, sweeping since the case's restart,
# can find and fix the row before this read (2026-10-11: counters "1 divergent, 1
# repaired", the read "good-7"). Its divergent counter going up says so.
v="$(q n4 "select v from rc_t where id=7")"; div1="$(divergent)"
if [ "$v" = CORRUPT ]; then ok "n4 is now divergent on row 7"
elif [ -n "$div1" ] && [ "${div1:-0}" -gt "${div0:-0}" ]; then ok "n4 was divergent on row 7 - recon already caught it (divergent ${div0:-0} -> $div1, row now [$v])"
else bad "n4 is now divergent on row 7 - expected [CORRUPT] got [$v], recon divergent ${div0:-?} -> ${div1:-?}"; fi
check "every other node still has the good value" "good-7" "$(q n2 "select v from rc_t where id=7")"

# ── make the table due so a round runs, then let recon work ────────────────
echo "  writing one more row to make the table due..."
q n1 "begin; insert into rc_t values (99,'trigger-a-round'); select yt_complete(true); commit;" >/dev/null
# the stabilize window must elapse before recon will compare anything - that is
# the skip rule doing its job, not a delay to tune away
sleep 20

for _ in $(seq 1 24); do
	[ "$(q n4 "select v from rc_t where id=7")" = "good-7" ] && break
	sleep 5
done

check "n4 row 7 was REPAIRED" "good-7" "$(q n4 "select v from rc_t where id=7")"
check "no other node was disturbed" "good-7" "$(q n2 "select v from rc_t where id=7")"

echo "  recon counters (n4):"
printf "     %s\n" "$(info n4 E recon)"
summary
