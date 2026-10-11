#!/usr/bin/env bash
# topo T2/T3: a table's move between zones, the stale copies it leaves, and their
# cleanup (yt-pgxt topo-jobs.md, phase 2), on the west cluster of the rmc layout,
# under rmc's load.
#
#   ../rmc/up.sh && ./t2_move.sh        (after t0/t1, or on its own)
#
# Splits west into two zones (westc: the first two members, westx: the other
# two), moves a seeded table from westc to westx without purge, then with purge
# back again, and cleans up in between. J1 a move without purge deletes nothing;
# J2 a purge deletes exactly the moved rows, only after the flip, only on old
# holders, never a row no other node holds; J6 a stale holder stops receiving
# the table's writes; J3 one job per table.
# Writes results/t2-<time>.log; exits 0 when no check failed.
C=west
. "$(dirname "$0")/lib.sh"
topo_log t2
for c in "${CLUSTERS[@]}"; do [ -s "$RUN/members.$c" ] || die "no $RUN/members.$c - run ../rmc/up.sh first"; done
say "== topo T2 $(now) UTC, yaxaha $(docker exec "$(cname "$(members $C | cut -d' ' -f1)")" dpkg-query -W -f='${Version}' yaxaha 2>/dev/null), cluster $C: $(members $C)"

T=topo_m
TK="$DB.public.$T"
read -r W1 W2 X1 X2 _ <<< "$(members $C)"
rows()  { QT=20 q "$1" -c "select count(*) from $T" 2>/dev/null; }
sum()   { QT=20 q "$1" -c "select coalesce(md5(string_agg(id||':'||v, ',' order by id)), 'empty') from $T" 2>/dev/null; }
local_sql() { q "$1" -c "begin" -c "set local yt.node = 'local'" -c "$2" -c "commit" >/dev/null 2>&1; }
has_rows() { [ "$(rows "$1")" = "$2" ]; }
all_rows() { local n w="$1"; shift; for n in "$@"; do has_rows "$n" "$w" || return 1; done; }

mark
jobs_on $C
f=$W1

# ── two zones, and a table in the first ──────────────────────────────────────
say "-- $(now) zone westx: $X1 $X2 (westc keeps $W1 $W2); table $T routed to westc"
z=$(job_new "$f" az_create "" "name=westx;tier=1;nodes=$(node_uuid "$X1"),$(node_uuid "$X2")")
job_wait 60 "$f" "$z" done "zone westx made of $X1, $X2"
for n in $(members $C); do
    q "$n" -c "create table if not exists $T (id bigint primary key, v text)" \
        -c "drop trigger if exists zytsync_${T}_trigger on public.$T" \
        -c "create trigger zytsync_${T}_trigger after insert or update or delete on public.$T for each row execute procedure public.yt_synchronize()" \
        >/dev/null 2>&1
done
RULE_C=$(enc 'az=westc'); RULE_X=$(enc 'az=westx')
cfg_tx $C "insert into $CFG (name, module, value) values ('public.$T', 'A', '$RULE_C')" || bad "the A row for $T"
sleep 5
cwrite "$W1" "insert into $T select g, 'r' || g from generate_series(1, 40) g" >/dev/null || bad "seed $T"
wait_for 30 all_rows 40 "$W1" "$W2" && ok "$W1 and $W2 hold the 40 seeded rows" || bad "the seed reached westc: $W1=$(rows "$W1") $W2=$(rows "$W2")"
check "$X1 holds none of it (not in westc)" 0 "$(rows "$X1")"
S40=$(sum "$W1")

# ── a move without purge deletes nothing ─────────────────────────────────────
say "-- $(now) move $T to westx, no purge"
m=$(job_new "$f" move "$TK" "cfg=$RULE_X")
b=$(job_new "$(leader_of $C)" cleanup "$TK" "")
job_wait 30 "$f" "$b" refused "J3 a cleanup of $T during its move is refused"
job_wait 180 "$f" "$m" done "the move to westx done"
check "J1 $X1 holds every row" "$S40" "$(sum "$X1")"
check "J1 $X2 holds every row" "$S40" "$(sum "$X2")"
check "J1 $W1 kept its rows (no purge)" "$S40" "$(sum "$W1")"
check "J1 $W2 kept its rows" "$S40" "$(sum "$W2")"
cwrite "$X1" "insert into $T select g, 'r' || g from generate_series(41, 50) g" >/dev/null || bad "write to $T after the move"
wait_for 30 all_rows 50 "$X1" "$X2" && ok "a write after the move reaches the new holders" || bad "new holders: $X1=$(rows "$X1") $X2=$(rows "$X2")"
sleep 5
check "J6 the old holder $W1 is detached: no new rows" 40 "$(rows "$W1")"
check "J6 ...and $W2" 40 "$(rows "$W2")"
S50=$(sum "$X1")

# ── cleanup: report, then purge, keeping what no other node holds ───────────
c1=$(job_new "$f" cleanup "$TK" "")
job_wait 60 "$f" "$c1" done "a cleanup without purge reports"
case "$(job_get "$f" "$c1" reason)" in *"stale rows: 80"*) ok "...80 stale rows (40 on each old holder)";;
    *) bad "the report counts 80 stale rows: [$(job_get "$f" "$c1" reason)]";; esac
local_sql "$W1" "insert into $T values (1000, 'only-here')"
check "a row that exists only on $W1" 1 "$(QT=20 q "$W1" -c "select count(*) from $T where id = 1000")"
c2=$(job_new "$f" cleanup "$TK" "purge")
job_wait 120 "$f" "$c2" done "cleanup with purge"
case "$(job_get "$f" "$c2" reason)" in *"1 stale row(s) kept"*) ok "J2 ...it kept the row no other node holds";;
    *) bad "J2 the purge kept one row: [$(job_get "$f" "$c2" reason)]";; esac
check "J2 $W1 holds only that row" 1 "$(rows "$W1")"
check "J2 $W2 holds nothing" 0 "$(rows "$W2")"
check "J2 the new holders are untouched ($X1)" "$S50" "$(sum "$X1")"
check "J2 ...($X2)" "$S50" "$(sum "$X2")"
local_sql "$W1" "delete from $T where id = 1000"

# ── a move back with purge, under writes to the table ───────────────────────
say "-- $(now) move $T back to westc, with purge, writing to it meanwhile"
m2=$(job_new "$f" move "$TK" "cfg=$RULE_C;purge")
# through a holder: until the flip $X1 and $X2 commit the table, $W1 and $W2 fill
for i in $(seq 1 10); do cwrite "$X1" "update $T set v = 'upd' where id = $i" >/dev/null || bad "update $i on $X1"; sleep 0.5; done
job_wait 240 "$f" "$m2" done "the move back with purge done"
check "J2 $W1 holds every row" 50 "$(rows "$W1")"
check "J2 $W2 holds the same as $W1" "$(sum "$W1")" "$(sum "$W2")"
check "the updates made during the move are there" 10 "$(QT=20 q "$W1" -c "select count(*) from $T where v = 'upd'")"
check "J2 the old holder $X1 was purged" 0 "$(rows "$X1")"
check "J2 ...and $X2" 0 "$(rows "$X2")"

# ── back as it was ───────────────────────────────────────────────────────────
say "-- $(now) $X1 and $X2 back in westc; zone westx and $T's rule gone"
cfg_tx $C "update $CFG set value = 'westc' where module = 'Z' and name in ('$(node_uuid "$X1")', '$(node_uuid "$X2")')" || bad "re-place $X1, $X2"
cfg_tx $C "delete from $CFG where module = 'A' and name = 'public.$T'" || bad "delete $T's A row"
sleep 5
d=$(job_new "$f" az_delete "" "name=westx")
job_wait 60 "$f" "$d" done "zone westx deleted"
after_step $C
say ""
say "== topo T2: $pass ok, $fail failed"
say "   log: results/$(basename "$LOG")"
[ "$fail" = 0 ]
