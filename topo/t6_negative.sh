#!/usr/bin/env bash
# topo T6: negative and border cases of the job layer (yt-pgxt topo-jobs.md), on
# the west cluster of the rmc layout - below top, beside east - under rmc's load.
# Not destructive: every table, zone and job it makes is gone at the end, and the
# cluster is as it was. Safe after t0..t3, before t4.
#
#   ./t6_negative.sh        (after t0..t3, or on its own after ../rmc/up.sh)
#
# West's leader stays in westc; its three followers make two zones: westx (two
# nodes) and westy (one).
#
# J1  refused with a reason: an unknown kind; a move of a table that is neither
#     synced nor routed; a move with a malformed rule; a move to an az that does
#     not exist; an az_delete of an unknown az; an az_create placing an unknown
#     node; a split of an unknown az; a combine into a lower and into an unlinked
#     cluster; a group job naming a lower cluster.
# J2  a cancel in each state that can be held: requested (the leader's layer off
#     meanwhile - a job behind another's lock is refused, never queued, and
#     `approved` lasts one tick), a noop running, a move mid-fill, a move already
#     done. Each ends with a reason and releases its table; the move cancelled
#     mid-fill leaves the old rule in force and no half-written A row.
# J3  a forged state change, written on a follower as a cluster write.
#     What job.rs guarantees: the leader's own transitions are a compare-and-set
#     on the state it read (job_set_by: "where state = <from>"), so a forged state
#     is never overwritten blindly, and one set back to 'approved' is carried
#     forward again - those checks pass. Nothing refuses the write itself: yt_job
#     is an ordinary synced table, and the monitor reads active rows only, so a
#     forged 'done' is the job's outcome - those checks fail (below).
# A1  border moves: an empty table; to its current rule; to a one-node zone.
# A2  a cleanup purge while the only holder under the rule is stopped: the stale
#     copy is the last one, and is kept.
# S2  a split of a one-node zone; S3 a split while a move holds one of the zone's
#     tables (the ledger routed out of the zone meanwhile, the writer paused).
# J4  a move whose target stays down for good (restarted at the end, and by the
#     EXIT trap).
#
# Each of these failed until ytserv 0.20.61-0.20.63 (green, 100/0, 2026-10-10):
#   J4  a move with a target down for good never ended (../topology/PLAN.md F13):
#       now a round that can compare no target starts a deadline - 300 s, or the
#       job's `deadline=<s>` (0 waits forever) - and the move ends failed.
#   J1  a move of an unsynced table, or to an az that does not exist, was approved
#       and flipped at once; an az_create placing an unknown uuid was done. Now
#       refused on the leader (job.rs move_check, az_job_check), naming what.
#   J2  a cancelled noop said nothing, and a cancel of a done job turned it into
#       "cancelled": now a reason per kind, and a finished row is put back.
#   J3  a forged 'done' stood: the leader compares each row with the last state
#       its own history wrote, and puts back one it did not write.
#   A1  a move to the rule already in force, of a table only the leader holds,
#       never ended: refused as "under this rule already". The old holder's stray
#       row was the leader filling a party slot for a table it does not hold.
# Writes results/t6-<time>.log; exits 0 when no check failed.
C=west
. "$(dirname "$0")/lib.sh"
topo_log t6
for c in "${CLUSTERS[@]}"; do [ -s "$RUN/members.$c" ] || die "no $RUN/members.$c - run ../rmc/up.sh first"; done
say "== topo T6 $(now) UTC, yaxaha $(docker exec "$(cname "$(members $C | cut -d' ' -f1)")" dpkg-query -W -f='${Version}' yaxaha 2>/dev/null), cluster $C: $(members $C)"
table_cfg
[ -n "${CFG_LOCAL:-}" ] || die "no $RUN/tables.env - run ../rmc/up.sh first"

T() { echo "$DB.public.$1"; }
cfgval() { QT=20 q "$1" -c "select value from $CFG where module = '$2' and name = '$3'" 2>/dev/null; }
arow()   { QT=20 q "$1" -c "select count(*) || '|' || coalesce(max(value), '') from $CFG where module = 'A' and name = 'public.$2'" 2>/dev/null; }
rows()   { QT=20 q "$1" -c "select count(*) from $2" 2>/dev/null; }
sum()    { QT=20 q "$1" -c "select coalesce(md5(string_agg(id || ':' || v, ',' order by id)), 'empty') from $2" 2>/dev/null; }
has_id() { [ "$(QT=20 q "$1" -c "select count(*) from $2 where id = $3" 2>/dev/null)" = 1 ]; }
all_have() { local t="$1" id="$2" n; shift 2; for n in "$@"; do has_id "$n" "$t" "$id" || return 1; done; }
local_sql() { q "$1" -c "begin" -c "set local yt.node = 'local'" -c "$2" -c "commit" >/dev/null 2>&1; }
good()   { local s; s=$(node_state "$1"); [ "$s" = Good ] || [ "$s" = Leader ]; }
# when_is <node> <id> <state> <secs>: the job reached the state (polled twice a second)
when_is() { local t=0; while [ "$t" -lt $(( $4 * 2 )) ]; do job_is "$1" "$2" "$3" && return 0; sleep 0.5; t=$((t + 1)); done; return 1; }
ended()  { case "$(job_get "$1" "$2" state)" in done|failed|refused|cancelled) return 0;; esac; return 1; }
sr()     { job_get "$1" "$2" "state || ' ' || reason"; }
# retry <node> <sql>: a cluster write, retried for half a minute (right after a
# flip a node may still be reading the new rule)
retry()  { local i; for i in $(seq 1 10); do cwrite "$1" "$2" >/dev/null && return 0; sleep 3; done; return 1; }
# table <name> [key type]: on every member, synced
table() {
    local n; for n in $(members $C); do
        q "$n" -c "create table if not exists $1 (id ${2:-bigint} primary key, v text)" \
            -c "drop trigger if exists zytsync_$1_trigger on public.$1" \
            -c "create trigger zytsync_$1_trigger after insert or update or delete on public.$1 for each row execute procedure public.yt_synchronize()" \
            >/dev/null 2>&1 || bad "table $1 on $n"
    done
}
route()   { cfg_tx $C "insert into $CFG (name, module, value) values ('public.$1', 'A', '$2')" || bad "the A row for $1"; }
unroute() { cfg_tx $C "delete from $CFG where module = 'A' and name = 'public.$1'" || bad "delete the A row of $1"; }
# the yt_job trigger on one node, as jobs_on puts it
trig_on() {
    q "$1" -c "drop trigger if exists zytsync_yt_job_trigger on $JT" \
        -c "create trigger zytsync_yt_job_trigger after insert or update or delete on $JT for each row execute procedure public.yt_synchronize()" \
        >/dev/null 2>&1
}
# is a reshape of the table open on the node (yt_info('E') reshape.N)
moving_on() {
    [ "$(QT=20 q "$1" -c "select count(*) from json_to_recordset(yt_info('E')) as x(name text, value text, module text) where name like 'reshape.%' and value like '%$2%'" 2>/dev/null)" != 0 ]
}
# seen_down <node> <peer>: <node> no longer reads <peer> as up
seen_down() {
    local l; l=$(info "$1" E "$(node_uuid "$2")")
    [ -n "$l" ] || return 1
    case "$l" in *", Good,"*|*", Leader,"*) return 1;; esac
    return 0
}
# seen_down_all <peer>: every other member reads it down - the node a job is
# asked on among them, whose write would otherwise still draw it into a party
seen_down_all() { local n; for n in $(members $C); do [ "$n" = "$1" ] || seen_down "$n" "$1" || return 1; done; }
# refused_with <secs> <node> <id> <fragment> <label>: the job ends refused, its
# reason naming <fragment>
refused_with() {
    local s r
    wait_for "$1" ended "$2" "$3"
    s=$(job_get "$2" "$3" state); r=$(job_get "$2" "$3" reason)
    if [ "$s" = refused ] && [[ "$r" == *"$4"* ]]; then ok "$5: $r"
    else bad "$5 - refused, naming [$4]: got [$s] [$r]"; fi
}
# cancelled_with <secs> <node> <id> <label>: the job ends cancelled, and says why
cancelled_with() {
    local s r
    wait_for "$1" ended "$2" "$3"
    s=$(job_get "$2" "$3" state); r=$(job_get "$2" "$3" reason)
    check "$4: cancelled" cancelled "$s"
    [ -n "$r" ] && ok "$4: ...and says why: $r" || bad "$4: ...and says why - its reason is empty"
}
# guard <node> <id> <label>: a split or combine this test expects refused must
# never reach its cut. One that takes its locks is cancelled at once - a cancel
# holds until the cut, which waits a settle first.
guard() {
    local t=0 s
    while [ "$t" -lt 180 ]; do
        s=$(job_get "$1" "$2" state)
        case "$s" in
            running|switching)
                job_cancel "$1" "$2" >/dev/null 2>&1
                bad "$3: it took its locks ($s) - cancelled at once, before its cut"
                wait_for 60 ended "$1" "$2"
                return 1;;
            done|failed|refused|cancelled) return 0;;
        esac
        sleep 0.5; t=$((t + 1))
    done
    return 0
}

# Whatever happens, nothing is left stopped, rerouted or switched off.
A2_DOWN=""; J4_DOWN=""; TRIG_OFF=""; S3_ROUTED=""
restore() {
    local n
    for n in $A2_DOWN $J4_DOWN; do docker start "$(cname "$n")" >/dev/null 2>&1; done
    [ -n "$TRIG_OFF" ] && trig_on "$TRIG_OFF"
    [ -n "$S3_ROUTED" ] && cfg_tx $C "update $CFG set value = '$CFG_LOCAL' where module = 'A' and name in ('public.rmc_ledger', 'public.rmc_probe')" >/dev/null 2>&1
    load_members $C $(members $C) >/dev/null 2>&1
    load_resume $C >/dev/null 2>&1
}
trap restore EXIT

mark
for c in "${CLUSTERS[@]}"; do jobs_on "$c"; done
L=$(leader_of $C)
[ -n "$L" ] || die "$C has no leader"
read -r X1 X2 Y _ <<< "$(for n in $(members $C); do [ "$n" = "$L" ] || echo "$n"; done | tr '\n' ' ')"
[ -n "${Y:-}" ] || die "$C needs four members, has: $(members $C)"
F=$X1   # where this test asks for its jobs: a follower, never stopped
U=$(follower upper)
RULE_C=$(enc 'az=westc'); RULE_X=$(enc 'az=westx'); RULE_Y=$(enc 'az=westy'); RULE_NO=$(enc 'az=nosuchz')
for r in "$RULE_C" "$RULE_X" "$RULE_Y" "$RULE_NO"; do [ -n "$r" ] || die "yxctl --encode-table-cfg gave nothing"; done
GHOST=$(node_uuid t6ghost)   # a valid node uuid no cluster holds
say "   leader $L; zones to come: westx $X1 $X2, westy $Y; jobs asked on $F"

# ── J1: refused, with a reason ───────────────────────────────────────────────
say "-- $(now) J1: requests the job layer must refuse"
for n in $(members $C); do
    q "$n" -c "create table if not exists topo_n0 (id bigint primary key, v text)" >/dev/null 2>&1 || bad "table topo_n0 on $n"
done
table topo_n1
route topo_n1 "$RULE_C"
sleep 5
cwrite "$L" "insert into topo_n1 select g, 'r' || g from generate_series(1, 5) g" >/dev/null || bad "seed topo_n1"
j1=$(job_new "$F" launch "" "")
j2=$(job_new "$F" move "$(T topo_n0)" "cfg=$RULE_C")
j3=$(job_new "$F" move "$(T topo_n1)" "cfg=not-a-rule")
j4=$(job_new "$F" move "$(T topo_n1)" "cfg=$RULE_NO")
j5=$(job_new "$F" az_delete "" "name=nosuchz")
j6=$(job_new "$F" az_create "" "name=westg;nodes=$GHOST")
j7=$(job_new "$F" split "" "az=nosuchz;level=LOWER")
j8=$(job_new "$F" combine "" "into=nosuchc")
j9=$(job_new "$U" combine "" "into=eastc")
j10=$(job_new "$U" group_noop "$(T topo_ng)" "with=eastc")
# the split and the combines first: one wrongly approved is cancelled before its cut
guard "$F" "$j7" "J1 the split of nosuchz"
guard "$F" "$j8" "J1 the combine into nosuchc"
guard "$U" "$j9" "J1 top's combine into eastc"
refused_with 60 "$F" "$j1" "unknown kind [launch]" "J1 an unknown kind is refused"
refused_with 60 "$F" "$j2" "topo_n0" "J1 a move of topo_n0 - not synced, no rule - is refused, naming the table"
check "J1 ...and no A row was written for it" "0|" "$(arow "$L" topo_n0)"
refused_with 60 "$F" "$j3" "cfg is not a table rule" "J1 a move with a malformed rule is refused"
refused_with 60 "$F" "$j4" "nosuchz" "J1 a move of topo_n1 to the az nosuchz, which does not exist, is refused, naming it"
check "J1 ...and topo_n1 keeps its rule" "1|$RULE_C" "$(arow "$L" topo_n1)"
refused_with 60 "$F" "$j5" "az nosuchz is not in the placement map" "J1 an az_delete of an unknown az is refused"
wait_for 60 ended "$F" "$j6"
s=$(job_get "$F" "$j6" state); r=$(job_get "$F" "$j6" reason)
if [ "$s" = refused ] && { [[ "$r" == *"$GHOST"* ]] || [[ "$r" == *"${GHOST:0:2}..${GHOST:30}"* ]]; }; then
    ok "J1 an az_create placing an unknown node is refused, naming it: $r"
else bad "J1 an az_create placing the unknown node $GHOST is refused, naming it: got [$s] [$r]"; fi
if [ "$s" = done ]; then
    dz=$(job_new "$F" az_delete "" "name=westg;force")
    job_wait 60 "$F" "$dz" done "   cleanup: the zone westg it made, deleted (force: its node is in no roster)"
fi
refused_with 60 "$F" "$j7" "no node of this cluster is placed in nosuchz" "J1 a split of an unknown az is refused"
refused_with 60 "$F" "$j8" "nosuchc is no cluster this one links to" "J1 a combine into an unlinked cluster is refused"
refused_with 60 "$U" "$j9" "eastc is a lower cluster" "J1 a combine into a LOWER cluster (top into eastc) is refused"
refused_with 60 "$U" "$j10" "eastc is a lower cluster" "J1 a group job of top naming eastc, a LOWER cluster, is refused"
check "J1 top took no part in anything" 0 \
    "$(QT=20 q "$(leader_of upper)" -c "select count(*) from $JT where kind = 'participate' and state not in ('done', 'cancelled')" 2>/dev/null)"
# whatever the refused moves wrote, gone
[ "$(arow "$L" topo_n0)" = "0|" ] || unroute topo_n0
unroute topo_n1

# ── J3: a forged state change on a follower ──────────────────────────────────
say "-- $(now) J3: a running job's state forged on the follower $F"
a=$(job_new "$F" noop "$(T topo_nf1)" "hold=45")
job_wait 30 "$F" "$a" running "J3 a noop holding topo_nf1 for 45s runs"
err=$(cwrite "$F" "update $JT set state = 'done' where id = $a")
sleep 3
lv=$(job_get "$(leader_of $C)" "$a" state)
if [ -n "$err" ]; then ok "J3 a forged 'done' on $F is refused: ${err//$'\n'/ }"
elif [ "$lv" = running ]; then ok "J3 a forged 'done' on $F leaves the leader's view alone: running"
else bad "J3 a forged 'done' on $F is refused, or the leader still reads job $a running: accepted, the leader reads [$lv]"; fi
sleep 50
check "J3 ...and job $a ends as the leader ends it" "done held 45s" "$(sr "$F" "$a")"
b=$(job_new "$F" noop "$(T topo_nf2)" "hold=30")
job_wait 30 "$F" "$b" running "J3 a noop holding topo_nf2 for 30s runs"
cwrite "$F" "update $JT set state = 'approved' where id = $b" >/dev/null 2>&1
wait_for 120 ended "$F" "$b"
check "J3 a forged step back to 'approved': job $b still ends as the leader ends it" "done held 30s" "$(sr "$F" "$b")"
check "J3 ...approved by the leader, as before" "$(node_uuid "$(leader_of $C)")" "$(job_get "$F" "$b" approved_by)"

# ── J2: a cancel while requested, and while running ─────────────────────────
LJ=$(leader_of $C)
say "-- $(now) J2: $LJ's job layer off (its $JT trigger dropped), a noop asked on $F and cancelled there"
trig_off() { q "$1" -c "drop trigger if exists zytsync_yt_job_trigger on $JT" >/dev/null 2>&1; }
trig_off "$LJ" && TRIG_OFF=$LJ || bad "drop the $JT trigger on $LJ"
sleep 35   # the leader trusts "the layer is on" for 30s (job.rs ENABLED_TTL)
r1=$(job_new "$F" noop "$(T topo_nr)" "hold=600")
sleep 10
check "J2 the request waits: the leader decides nothing while its layer is off" requested "$(job_get "$LJ" "$r1" state)"
job_cancel "$F" "$r1" >/dev/null 2>&1 || bad "cancel job $r1 on $F"
trig_on "$LJ" && TRIG_OFF="" || bad "the $JT trigger back on $LJ"
cancelled_with 120 "$F" "$r1" "J2 a requested noop, cancelled before the leader read it"
r2=$(job_new "$F" noop "$(T topo_nr)" "hold=600")
job_wait 90 "$F" "$r2" running "J2 a noop holding topo_nr for 600s runs (the layer is on again)"
job_cancel "$F" "$r2" >/dev/null 2>&1 || bad "cancel job $r2 on $F"
cancelled_with 60 "$F" "$r2" "J2 a running noop, cancelled"
r3=$(job_new "$F" noop "$(T topo_nr)" "hold=1")
job_wait 30 "$F" "$r3" done "J2 ...its table released: the next job on topo_nr runs"

# ── the zones, and the tables of the moves ──────────────────────────────────
say "-- $(now) zone westx: $X1 $X2; zone westy: $Y; westc keeps $L"
z1=$(job_new "$F" az_create "" "name=westx;tier=1;nodes=$(node_uuid "$X1"),$(node_uuid "$X2")")
job_wait 60 "$F" "$z1" done "zone westx made of $X1, $X2"
z2=$(job_new "$F" az_create "" "name=westy;tier=1;nodes=$(node_uuid "$Y")")
job_wait 60 "$F" "$z2" done "zone westy made of $Y alone"
for t in topo_n2 topo_n3 topo_n4 topo_n5; do table "$t"; route "$t" "$RULE_C"; done
sleep 5
# topo_n2 big enough that its fill outlasts a cancel: seeded on its one holder
# alone, locally - the targets copy it from there
local_sql "$L" "insert into topo_n2 select g, 'r' || g from generate_series(1, 30000) g" || bad "seed topo_n2 on $L"
check "topo_n2 seeded on $L, its one holder" 30000 "$(rows "$L" topo_n2)"
cwrite "$L" "insert into topo_n4 select g, 'r' || g from generate_series(1, 10) g" >/dev/null || bad "seed topo_n4"
cwrite "$L" "insert into topo_n5 select g, 'r' || g from generate_series(1, 30) g" >/dev/null || bad "seed topo_n5"
check "topo_n5 seeded on $L" 30 "$(rows "$L" topo_n5)"
check "...and on no node outside westc ($Y)" 0 "$(rows "$Y" topo_n5)"
S5=$(sum "$L" topo_n5)

# ── J2: a cancel mid-fill ───────────────────────────────────────────────────
say "-- $(now) J2: topo_n2 (30000 rows) moves to westx; cancelled as soon as it runs"
m2=$(job_new "$F" move "$(T topo_n2)" "cfg=$RULE_X")
when_is "$F" "$m2" running 60 && ok "the move of topo_n2 runs" || bad "the move of topo_n2 runs: [$(sr "$F" "$m2")]"
job_cancel "$F" "$m2" >/dev/null 2>&1 || bad "cancel job $m2 on $F"
cancelled_with 60 "$F" "$m2" "J2 a move cancelled mid-fill"
[[ "$(job_get "$F" "$m2" reason)" == *"before the flip"* ]] && ok "J2 ...stopped before the flip" \
    || bad "J2 the cancelled move says it stopped before the flip: [$(job_get "$F" "$m2" reason)]"
for n in $(members $C); do check "J2 the old rule is in force on $n: one A row, westc's" "1|$RULE_C" "$(arow "$n" topo_n2)"; done
check "J2 the old holder $L keeps every row" 30000 "$(rows "$L" topo_n2)"
sleep 6   # every member reads the job cancelled on its next tick (2s)
still=""; for n in $(members $C); do moving_on "$n" topo_n2 && still="$still $n"; done
check "J2 no member still moves topo_n2" "" "$still"
r4=$(job_new "$F" noop "$(T topo_n2)" "hold=1")
job_wait 30 "$F" "$r4" done "J2 ...its table released: the next job on topo_n2 runs"

# ── A1: border moves ────────────────────────────────────────────────────────
say "-- $(now) A1: topo_n3, empty, moves to westx"
m3=$(job_new "$F" move "$(T topo_n3)" "cfg=$RULE_X")
job_wait 180 "$F" "$m3" done "A1 the move of an empty table done"
check "A1 $X1 holds it, empty" 0 "$(rows "$X1" topo_n3)"
retry "$X1" "insert into topo_n3 values (1, 'after')" || bad "write topo_n3 on $X1 after the move"
wait_for 30 all_have topo_n3 1 "$X1" "$X2" && ok "A1 ...its new rule is in force: a write reaches $X1 and $X2" \
    || bad "A1 a write after the move reaches westx: $X1=$(rows "$X1" topo_n3) $X2=$(rows "$X2" topo_n3)"
check "A1 ...and not $L, its old holder" 0 "$(rows "$L" topo_n3)"

say "-- $(now) A1: topo_n4, held by the leader $L alone, moves to the rule it has"
m4=$(job_new "$F" move "$(T topo_n4)" "cfg=$RULE_C")
if wait_for 120 ended "$F" "$m4"; then
    s=$(job_get "$F" "$m4" state); r=$(job_get "$F" "$m4" reason)
    case "$s" in
        done|refused) [ -n "$r" ] && ok "A1 a move to the table's current rule ends $s: $r" \
            || bad "A1 a move to the current rule ends $s, without a reason";;
        *) bad "A1 a move to the current rule ends done, or refused as a no-op: [$s] [$r]";;
    esac
else
    bad "A1 a move to the current rule of topo_n4 - held by the leader alone - ends done or refused within 120s: still [$(sr "$F" "$m4")]"
    job_cancel "$F" "$m4" >/dev/null 2>&1; wait_for 60 ended "$F" "$m4"
fi
check "A1 ...topo_n4's rule is unchanged" "1|$RULE_C" "$(arow "$L" topo_n4)"
check "A1 ...and so are its rows" 10 "$(rows "$L" topo_n4)"

say "-- $(now) A1: topo_n5 moves to westy, a zone of one node"
m5=$(job_new "$F" move "$(T topo_n5)" "cfg=$RULE_Y")
job_wait 180 "$F" "$m5" done "A1 the move to a one-node zone done"
check "A1 $Y, the zone's one node, holds every row" "$S5" "$(sum "$Y" topo_n5)"
retry "$Y" "insert into topo_n5 values (31, 'on y')" || bad "write topo_n5 on $Y after the move"
wait_for 30 has_id "$Y" topo_n5 31 && ok "A1 ...a write after the move lands on $Y" || bad "A1 a write after the move lands on $Y"
check "A1 ...and $L, its old holder, keeps its rows, stale" 30 "$(rows "$L" topo_n5)"

# ── J2: a cancel of a job already done ──────────────────────────────────────
say "-- $(now) J2: the done move $m5 asked to cancel"
job_cancel "$F" "$m5" >/dev/null 2>&1 || bad "cancel job $m5 on $F"
not_cancel() { [ "$(job_get "$1" "$2" state)" != cancel ]; }
wait_for 60 not_cancel "$F" "$m5"
check "J2 a cancel of a done move leaves it done" done "$(job_get "$F" "$m5" state)"
for n in $(members $C); do check "J2 ...the rule its flip wrote is in force on $n" "1|$RULE_Y" "$(arow "$n" topo_n5)"; done

# ── S2: a split of a one-node zone ──────────────────────────────────────────
say "-- $(now) S2: westy, one node, asked to split off"
[ "$(leader_of $C)" = "$Y" ] && shift_leader $C "$L" quiet
s2=$(job_new "$F" split "" "az=westy;level=LOWER")
guard "$F" "$s2" "S2 the split of westy"
refused_with 60 "$F" "$s2" "min_cluster_size" "S2 a split of westy, a zone of one node, is refused"

# ── A2: a purge whose only witness is stopped ───────────────────────────────
say "-- $(now) A2: $Y, the one holder of topo_n5, stopped; a cleanup with purge"
load_members $C $(for n in $(members $C); do [ "$n" = "$Y" ] || echo "$n"; done)
docker stop -t 5 "$(cname "$Y")" >/dev/null && A2_DOWN=$Y
wait_for 60 seen_down_all "$Y" || bad "every member sees $Y down within 60s: [$(info "$(leader_of $C)" E "$(node_uuid "$Y")")]"
c5=$(job_new "$F" cleanup "$(T topo_n5)" "purge")
job_wait 120 "$F" "$c5" done "A2 the cleanup with purge done"
[[ "$(job_get "$F" "$c5" reason)" == *"30 stale row(s) kept"* ]] && ok "A2 ...it kept every stale row: no live node holds them" \
    || bad "A2 the purge kept the 30 stale rows: [$(job_get "$F" "$c5" reason)]"
check "A2 $L still holds them" "$S5" "$(sum "$L" topo_n5)"
docker start "$(cname "$Y")" >/dev/null
wait_for 180 good "$Y" && ok "$Y back as $(node_state "$Y")" || bad "$Y back within 180s: [$(node_status "$Y")]"
A2_DOWN=""
load_members $C $(members $C)

# ── S3: a split while a move holds a table of the zone ──────────────────────
say "-- $(now) S3: topo_n6 in westx, held by a move that cannot fill; westx asked to split off"
case " $X1 $X2 " in *" $(leader_of $C) "*) shift_leader $C "$L" quiet;; esac
# The ledger and the probe table are held everywhere and never cross, so a split
# is refused for them first (t4): routed out of westx while this lasts, the writer
# paused, so no row is written that westx would then lack.
load_pause $C
S3_ROUTED=1
cfg_tx $C "update $CFG set value = '$(enc 'az=westc,westy; no_up; no_down')' where module = 'A' and name in ('public.rmc_ledger', 'public.rmc_probe')" \
    || bad "route the ledger out of westx"
# a text key: such a table cannot be filled or frame-compared (reshape.rs), so
# its move holds it until cancelled
table topo_n6 text
route topo_n6 "$RULE_X"
sleep 5
for n in "$X1" "$X2"; do local_sql "$n" "insert into topo_n6 select 'k' || g, 'v' from generate_series(1, 50) g" || bad "seed topo_n6 on $n"; done
mv6=$(job_new "$F" move "$(T topo_n6)" "cfg=$RULE_C")
when_is "$F" "$mv6" running 60 && sleep 10
if job_is "$F" "$mv6" running; then
    ok "S3 the move $mv6 holds topo_n6 ($(job_get "$F" "$mv6" "coalesce(nullif(reason, ''), 'running')"))"
    s3=$(job_new "$F" split "" "az=westx;level=LOWER")
    guard "$F" "$s3" "S3 the split of westx"
    refused_with 60 "$F" "$s3" "is busy here: job $mv6 (move" "S3 a split of westx while move $mv6 holds topo_n6 is refused, naming the move"
else
    bad "S3 a move that holds topo_n6 while the split is asked for: [$(sr "$F" "$mv6")] - no split asked"
fi
job_is "$F" "$mv6" running && { job_cancel "$F" "$mv6" >/dev/null 2>&1; wait_for 60 ended "$F" "$mv6"; }
cfg_tx $C "update $CFG set value = '$CFG_LOCAL' where module = 'A' and name in ('public.rmc_ledger', 'public.rmc_probe')" \
    && S3_ROUTED="" || bad "route the ledger back everywhere"
load_resume $C
unroute topo_n6

# ── J4: a move whose target stays down ──────────────────────────────────────
say "-- $(now) J4: $X2 stopped for good; topo_n7 moves to westx"
table topo_n7
route topo_n7 "$RULE_C"
sleep 5
cwrite "$L" "insert into topo_n7 select g, 'r' || g from generate_series(1, 20) g" >/dev/null || bad "seed topo_n7"
load_members $C $(for n in $(members $C); do [ "$n" = "$X2" ] || echo "$n"; done)
docker stop -t 5 "$(cname "$X2")" >/dev/null && J4_DOWN=$X2
wait_for 60 seen_down_all "$X2" || bad "every member sees $X2 down within 60s"
m7=$(job_new "$F" move "$(T topo_n7)" "cfg=$RULE_X")
when_is "$F" "$m7" running 60 && ok "the move of topo_n7 runs, its target $X2 down" || bad "the move of topo_n7 runs: [$(sr "$F" "$m7")]"
say "   ....  up to 600s for job $m7 to end; $X2 stays down"
if wait_for 600 ended "$F" "$m7"; then
    s=$(job_get "$F" "$m7" state); r=$(job_get "$F" "$m7" reason)
    if [ "$s" = failed ] && [ -n "$r" ]; then ok "J4 a move whose target stays down ends failed: $r"
    else bad "J4 a move whose target stays down ends failed, with a reason: [$s] [$r]"; fi
else
    bad "J4 a move whose target stays down ends failed with a reason within 600s (no deadline - ../topology/PLAN.md F13): still [$(sr "$F" "$m7")]"
fi
check "J4 ...topo_n7 keeps its rule" "1|$RULE_C" "$(arow "$L" topo_n7)"

# ── back as it was ──────────────────────────────────────────────────────────
say "-- $(now) cleanup: every job of this test ended, $X2 back, the zones and tables gone"
for id in $(QT=20 q "$(leader_of $C)" -c "select id from $JT where state in ('requested', 'approved', 'running', 'purging', 'cancel') and tabl like '$DB.public.topo_n%'" 2>/dev/null); do
    job_cancel "$F" "$id" >/dev/null 2>&1
    wait_for 60 ended "$F" "$id" && say "   ....  job $id: $(sr "$F" "$id")" || bad "job $id ends once cancelled: [$(sr "$F" "$id")]"
done
docker start "$(cname "$X2")" >/dev/null
wait_for 180 good "$X2" && ok "$X2 back as $(node_state "$X2")" || bad "$X2 back within 180s: [$(node_status "$X2")]"
J4_DOWN=""
load_members $C $(members $C)
cfg_tx $C "update $CFG set value = 'westc' where module = 'Z' and name in ('$(node_uuid "$X1")', '$(node_uuid "$X2")', '$(node_uuid "$Y")')" \
    || bad "re-place $X1, $X2, $Y in westc"
for t in topo_n0 topo_n1 topo_n2 topo_n3 topo_n4 topo_n5 topo_n6 topo_n7; do
    [ "$(arow "$(leader_of $C)" "$t")" = "0|" ] || unroute "$t"
done
sleep 5
d1=$(job_new "$F" az_delete "" "name=westx")
job_wait 60 "$F" "$d1" done "zone westx deleted"
d2=$(job_new "$F" az_delete "" "name=westy")
job_wait 60 "$F" "$d2" done "zone westy deleted"
for n in $(members $C); do
    q "$n" -c "drop table if exists topo_n0, topo_n1, topo_n2, topo_n3, topo_n4, topo_n5, topo_n6, topo_n7" >/dev/null 2>&1 \
        || bad "drop the test tables on $n"
done

# ── no job left running, no lock left held ──────────────────────────────────
for c in "${CLUSTERS[@]}"; do
    n=$(leader_of "$c")
    [ -n "$n" ] || { bad "$c has a leader to ask"; continue; }
    check "$c: no job left unfinished" "" "$(QT=20 q "$n" -c "select string_agg(id || ' ' || kind || ' ' || state, ', ') from $JT where state not in ('done', 'failed', 'refused', 'cancelled')" 2>/dev/null)"
    check "$c: no participation left held" 0 "$(QT=20 q "$n" -c "select count(*) from $JT where kind = 'participate' and state not in ('done', 'cancelled')" 2>/dev/null)"
done
after_step $C
say ""
say "== topo T6: $pass ok, $fail failed"
say "   log: results/$(basename "$LOG")"
[ "$fail" = 0 ] && [ "$known" = 0 ]
