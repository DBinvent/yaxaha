#!/usr/bin/env bash
# [recovery] Tiers 2 and 3 (ytserv/recovery.md): a node compares a table with the
# majority of the cluster and repairs its own copy under a lock the cluster sees;
# a row no majority decides is blocked and recorded (T3) until its copies agree.
#
# The divergence is made OUT OF BAND, on one node, with the sync trigger off - a
# write the cluster never saw, which is what a lost or half-applied transaction
# leaves behind. On n4:
#
#   id 5        deleted        - a row n4 lacks       -> inserted from the majority
#   id 7        v changed      - another value         -> the majority's value...
#               note changed   - an ignored column     ...n4's own note kept
#   id 9        note changed   - an ignored column only -> no difference at all
#   id 19, 20   deleted        - the newest rows: above n4's own maximum, which a
#                                recon sweep (the overlap of every copy) never sees
#   id 13       inserted       - a row nobody else has (13 is never seeded) -> deleted.
#                                Inside the range: above every other copy's maximum it
#                                would be a write in flight, which no compare judges
#
# T2 is asked for (`yt_info('Y+:<db>.public.rv2_t')`); the automatic start - a gap
# the pull could not close for recovery_auto_sec - is the same run.
#
# Then T3: id 12 is made three-way, 3 / 2 / 2 across the seven copies, so no strict
# majority decides it. n4's run blocks it (a write to it is refused cluster-wide)
# and records it in a module-Y row; once the copies are made to agree again but
# n4's, n4's own look every minute repairs it, then releases it.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== recovery: T2 repairs a copy from the majority, T3 blocks what none decides =="

T=public.rv2_t
TK="$YX_DB.$T"
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists rv2_t; create table rv2_t (id bigint primary key, v text, note text);" >/dev/null
done
# no recon config: recon's own rounds stay off this table, the compare is T2's alone
CFG="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'ignore_col=note' | tail -1)"
register_table "$T" "$CFG"
restart_all
await_cluster
wait_writable n1 n2 rv2_t -1000 "{}" || { bad "cluster never became writable"; summary; }

L=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in *Leader) L="$n";; esac
done
[ -n "$L" ] || L=n1
echo "  leader: $L"
U4="$(node_uuid n4)"

# 1..20 but 13: the row only n4 will hold sits inside the range every copy holds
for i in $(seq 1 20); do
	[ "$i" = 13 ] && continue
	q n1 "begin; insert into rv2_t values ($i,'good-$i','note-$i'); select yt_complete(true); commit;" >/dev/null
done
for _ in $(seq 1 24); do
	[ "$(q n4 "select count(*) from rv2_t where id > 0")" = "19" ] && [ "$(q n6 "select count(*) from rv2_t where id > 0")" = "19" ] && break
	sleep 5
done
check "the seed reached n4" "19" "$(q n4 "select count(*) from rv2_t where id > 0")"

# out of band on one node: the trigger off for one transaction, its error shown
oob() { # oob <node> <sql>
	local trg out try
	trg="$(q "$1" "select tgname from pg_trigger where tgrelid='rv2_t'::regclass and not tgisinternal and (tgtype & 1) = 1 limit 1")"
	for try in 1 2 3; do
		out="$(qe "$1" "begin; alter table rv2_t disable trigger $trg; $2; alter table rv2_t enable trigger $trg; commit;")" || true
		case "$out" in *ERROR*) echo "  $1: out-of-band try $try failed: $(printf '%s\n' "$out" | grep -m1 ERROR)"; sleep 5 ;; *) return 0 ;; esac
	done
	return 1
}

# ── T2 ────────────────────────────────────────────────────────────────────────
oob n4 "delete from rv2_t where id in (5, 19, 20);
        update rv2_t set v='CORRUPT', note='n4-note-7' where id=7;
        update rv2_t set note='n4-own' where id=9;
        insert into rv2_t values (13, 'EXTRA', 'x')" || bad "n4 diverged out of band"
check "n4 diverged: 16 of the 19, and its extra row" "17" "$(q n4 "select count(*) from rv2_t where id > 0")"

check "T2 asked on n4" "started" "$(info n4 "Y+:$TK" recovery)"
# the lock is n4's Y row, visible on the leader while the table is repaired
seen=""
for _ in $(seq 1 180); do
	case "$(info "$L" Y "$U4.$TK")" in 2\;repairing*) seen=1; break ;; esac
	case "$(info n4 Y recovery)" in *"last: T2"*) break ;; esac
	sleep 1
done
[ -n "$seen" ] && ok "the leader saw n4's lock on $TK while it repaired" \
	|| bad "the leader never saw n4's lock on $TK ($(info "$L" Y | head -c 300))"
for _ in $(seq 1 60); do
	case "$(info n4 Y recovery)" in *"last: T2"*) break ;; esac
	sleep 5
done
last="$(info n4 Y recovery)"
echo "  n4: $last"
case "$last" in *"last: T2 done"*) ok "T2 finished clean";; *) bad "T2 finished clean - got [$last]";; esac

check "id 5, which n4 lacked, is back" "good-5" "$(q n4 "select v from rv2_t where id=5")"
check "id 7 holds the majority's value" "good-7" "$(q n4 "select v from rv2_t where id=7")"
check "id 7 kept n4's own ignored column" "n4-note-7" "$(q n4 "select note from rv2_t where id=7")"
check "id 9, different only where ignored, untouched" "n4-own" "$(q n4 "select note from rv2_t where id=9")"
check "ids 19 and 20, the newest, are back" "2" "$(q n4 "select count(*) from rv2_t where id in (19, 20)")"
check "id 13, which only n4 held, is gone" "0" "$(q n4 "select count(*) from rv2_t where id=13")"
check "n4 holds the 19 again" "19" "$(q n4 "select count(*) from rv2_t where id > 0")"
check "n2 was not touched" "good-7|note-7" "$(q n2 "select v || '|' || note from rv2_t where id=7")"
check "the lock is gone" "" "$(info "$L" Y "$U4.$TK")"
check "so is n4's node row" "" "$(info "$L" Y "$U4")"

# ── T3 ────────────────────────────────────────────────────────────────────────
for n in n3 n4; do oob "$n" "update rv2_t set v='X' where id=12" || bad "$n diverged out of band"; done
for n in n5 n6; do oob "$n" "update rv2_t set v='Y' where id=12" || bad "$n diverged out of band"; done
check "T2 asked on n4 again" "started" "$(info n4 "Y+:$TK" recovery)"
row=""
for _ in $(seq 1 60); do
	row="$(info "$L" Y "$U4.$TK|12")"
	[ -n "$row" ] && break
	sleep 5
done
case "$row" in *"no majority"*) ok "T3: n4 recorded id 12 - no majority decides it [$row]";;
	*) bad "T3: n4 recorded id 12 - got [$row]";; esac
out="$(qe n1 "begin; update rv2_t set v='w' where id=12; select yt_complete(true); commit;")" || true
case "$out" in *blocked*) ok "a write to id 12 is refused cluster-wide";;
	*) bad "a write to id 12 is refused cluster-wide - got [$(printf '%s' "$out" | head -c 200)]";; esac
case "$(info n4 Y recovery)" in *"unproven"*) ok "the run says the table is not proven";;
	*) bad "the run says the table is not proven - got [$(info n4 Y recovery)]";; esac

# every other copy agrees again - upserted, so a copy that never had the row (a
# spare behind) agrees too: T3 releases when the copies agree, all of them. n4
# alone holds X: its own look every minute repairs it, then releases it
for n in "${NODES[@]}"; do
	[ "$n" = n4 ] && continue
	oob "$n" "insert into rv2_t values (12, 'good-12', 'note-12')
	          on conflict (id) do update set v = excluded.v, note = excluded.note" || bad "$n put back"
done
for _ in $(seq 1 60); do
	[ -z "$(info "$L" Y "$U4.$TK|12")" ] && break
	sleep 5
done
check "T3 released itself once the copies agreed" "" "$(info "$L" Y "$U4.$TK|12")"
check "n4 holds the majority's id 12" "good-12" "$(q n4 "select v from rv2_t where id=12")"
q n1 "begin; update rv2_t set v='after-12' where id=12; select yt_complete(true); commit;" >/dev/null
for _ in $(seq 1 12); do
	[ "$(q n4 "select v from rv2_t where id=12")" = "after-12" ] && break
	sleep 5
done
check "id 12 takes writes again, and n4 gets them" "after-12" "$(q n4 "select v from rv2_t where id=12")"

summary
