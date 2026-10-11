#!/usr/bin/env bash
# topo T5: the jobs under faults (yt-pgxt topo-jobs.md, phase 5), on the rmc
# layout under rmc's load. Destructive like T4: run it last, after a fresh
# ../rmc/up.sh.
#
#   ../rmc/up.sh && ./t5_faults.sh
#
# A move mid-fill loses a target to a restart, and a move back loses its leader
# for a minute; a group job loses its own cluster's leader, then a participant's;
# a split loses a node of the zone during its cut, the cluster it made loses its
# leader during the combine back, and a second split loses the leader of the
# cluster it splits during its cut. Each job resumes and ends as it would have:
# J5. At the end every job row on every cluster is finished with a reason and no
# lock is left held: T8.
# Writes results/t5-<time>.log; exits 0 when no check failed.
C=west
. "$(dirname "$0")/lib.sh"
topo_log t5
for c in "${CLUSTERS[@]}"; do [ -s "$RUN/members.$c" ] || die "no $RUN/members.$c - run ../rmc/up.sh first"; done
say "== topo T5 $(now) UTC, yaxaha $(docker exec "$(cname "$(members $C | cut -d' ' -f1)")" dpkg-query -W -f='${Version}' yaxaha 2>/dev/null), cluster $C: $(members $C)"
RMC_WAIT=${RMC_WAIT:-120}

cfgval() { QT=20 q "$1" -c "select value from $CFG where module = '$2' and name = '$3'" 2>/dev/null; }
rows()   { QT=20 q "$1" -c "select count(*) from $2" 2>/dev/null; }
sum()    { QT=20 q "$1" -c "select coalesce(md5(string_agg(id || ':' || v, ',' order by id)), 'empty') from $2" 2>/dev/null; }
has_id() { [ "$(QT=20 q "$1" -c "select count(*) from $2 where id = $3" 2>/dev/null)" = 1 ]; }
all_have() { local t="$1" id="$2" n; shift 2; for n in "$@"; do has_id "$n" "$t" "$id" || return 1; done; }
leads()  { [ "$(node_state "$1")" = Leader ]; }
leader_among() { local n; for n in "$@"; do leads "$n" && { echo "$n"; return 0; }; done; return 1; }
named()  { [ "$(cfgval "$1" C cluster)" = "$2" ]; }
good()   { local s; s=$(node_state "$1"); [ "$s" = Good ] || [ "$s" = Leader ]; }
# when_is <node> <id> <state> <secs>: the job reached the state (polled twice a second)
when_is() { local t=0; while [ "$t" -lt $(( $4 * 2 )) ]; do job_is "$1" "$2" "$3" && return 0; sleep 0.5; t=$((t + 1)); done; return 1; }
table() { # table <name> on every member of west, synced
    local n; for n in $(members $C) $EXTRA; do
        q "$n" -c "create table if not exists $1 (id bigint primary key, v text)" \
            -c "drop trigger if exists zytsync_$1_trigger on public.$1" \
            -c "create trigger zytsync_$1_trigger after insert or update or delete on public.$1 for each row execute procedure public.yt_synchronize()" \
            >/dev/null 2>&1
    done
}

mark
for c in "${CLUSTERS[@]}"; do jobs_on "$c"; done
L=$(leader_of $C)
read -r X1 X2 _ <<< "$(for n in $(members $C); do [ "$n" = "$L" ] || echo "$n"; done | tail -2 | tr '\n' ' ')"
ALL=$(members $C)
KEEP=$(for n in $ALL; do case " $X1 $X2 " in *" $n "*) ;; *) printf '%s ' "$n";; esac; done)
EXTRA=""
f=$(follower $C)
# a config write, retried: right after a leadership move the new leader may still
# be catching up, and refuses it for a moment
cfg_try() { local i; for i in 1 2 3 4 5; do cfg_tx "$@" && return 0; sleep 3; done; return 1; }
say "   leader $L; zone westx: $X1 $X2; westc: $KEEP"
z=$(job_new "$f" az_create "" "name=westx;tier=1;nodes=$(node_uuid "$X1"),$(node_uuid "$X2")")
job_wait 60 "$f" "$z" done "zone westx made of $X1, $X2"

# ── a move loses a target mid-fill, a move back loses its leader ────────────
say "-- $(now) J5: topo_f1 (500 rows - some thirty a frame) moves to westx with purge; $X1 restarts mid-fill"
table topo_f1
cfg_tx $C "insert into $CFG (name, module, value) values ('public.topo_f1', 'A', '$(enc 'az=westc')')" || bad "the A row for topo_f1"
sleep 5
# west's writer paused meanwhile: a bulk load on top of it is a throughput test, and
# its timeouts leave sub-terms rolled back as abandoned only ten seconds later -
# writes wait on each. The faults below run under the load again.
lq touch "/load/pause-$C"
# in transactions of 10 rows: a cluster transaction checks in once a row, and one
# of hundreds of rows outlasts its call's timeout. Retried for half a minute: under
# the load a writer's transaction can time out after its check-in, and the sub-term
# it leaves is rolled back as abandoned only after ten seconds - writes wait on it
for b in $(seq 0 49); do
    for try in $(seq 1 10); do
        out=$(cwrite "$L" "insert into topo_f1 select g, 'f' || g from generate_series($((b * 10 + 1)), $((b * 10 + 10))) g") && break
        [ "$try" = 10 ] && bad "seed topo_f1 rows $((b * 10 + 1))-$((b * 10 + 10)): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        sleep 3
    done
done
wait_for 60 all_have topo_f1 500 $KEEP && ok "topo_f1 seeded in westc, 500 rows" || bad "topo_f1 seeded"
lq rm -f "/load/pause-$C"
F=$(sum "$L" topo_f1)
m=$(job_new "$(follower $C)" move "$DB.public.topo_f1" "cfg=$(enc 'az=westx');purge")
when_is "$(follower $C)" "$m" running 60 && ok "the move runs" || bad "the move runs: [$(job_get "$(follower $C)" "$m" state)]"
refresh_node $C "$X1"
job_wait 300 "$(follower $C)" "$m" done "J5 the move with a target restarted mid-fill done"
for n in $X1 $X2; do check "J5 $n holds every row" "$F" "$(sum "$n" topo_f1)"; done
for n in $KEEP; do check "J5 the old holder $n was purged" 0 "$(rows "$n" topo_f1)"; done

say "-- $(now) J5: topo_f1 moves back with purge; west's leader stops mid-move"
m2=$(job_new "$(follower $C)" move "$DB.public.topo_f1" "cfg=$(enc 'az=westc');purge")
when_is "$(follower $C)" "$m2" running 60 && ok "the move back runs" || bad "the move back runs"
fail_leader $C
job_wait 300 "$(follower $C)" "$m2" done "J5 the move back that lost its leader done"
for n in $KEEP; do check "J5 $n holds every row" "$F" "$(sum "$n" topo_f1)"; done
for n in $X1 $X2; do check "J5 the old holder $n was purged" 0 "$(rows "$n" topo_f1)"; done

# ── a group job loses its leader, then a participant's ──────────────────────
say "-- $(now) J5: a group job of west with east loses west's leader"
g=$(job_new "$(follower $C)" group_noop "$DB.public.topo_f2" "with=eastc;hold=50")
when_is "$(follower $C)" "$g" running 60 && ok "the group job holds west and east" || bad "the group job runs"
fail_leader $C
job_wait 120 "$(follower $C)" "$g" done "J5 the group job that lost its leader done"
E=$(follower east)
check "J8 east's part released" 0 "$(QT=20 q "$E" -c "select count(*) from $JT where kind = 'participate' and params like 'from=westc;job=$g;%' and state not in ('done', 'cancelled')")"
say "-- $(now) J5: a group job of west with east loses east's leader"
g2=$(job_new "$(follower $C)" group_noop "$DB.public.topo_f3" "with=eastc;hold=50")
when_is "$(follower $C)" "$g2" running 60 && ok "the group job holds west and east" || bad "the group job runs"
fail_leader east
job_wait 180 "$(follower $C)" "$g2" done "J5 the group job whose participant lost its leader done"
E=$(follower east)
check "J8 east's part released by its new leader" 0 "$(QT=20 q "$E" -c "select count(*) from $JT where kind = 'participate' and params like 'from=westc;job=$g2;%' and state not in ('done', 'cancelled')")"

# ── a split loses a node of its zone during the cut ─────────────────────────
say "-- $(now) J5: westx splits off; $X2 restarts during the cut"
L=$(leader_of $C)
case " $X1 $X2 " in *" $L "*) shift_leader $C "$(echo $KEEP | cut -d' ' -f1)" quiet; L=$(leader_of $C); sleep 5;; esac
table topo_s1; table topo_s2
cfg_try $C "insert into $CFG (name, module, value) values ('public.topo_s1', 'A', '$(enc 'az=westx')')" || bad "the A row for topo_s1"
cfg_try $C "insert into $CFG (name, module, value) values ('public.topo_s2', 'A', '$(enc 'az=westc,westx')')" || bad "the A row for topo_s2"
cfg_try $C "update $CFG set value = '$(enc 'az=westc; no_up; no_down')' where module = 'A' and name in ('public.rmc_ledger', 'public.rmc_probe')" \
    || bad "route the ledger to westc"
load_members $C $KEEP; echo "$KEEP" > "$RUN/members.$C"
sleep 5
# retried like the seed above: right after a leadership move, or under the load
retry() { local i; for i in $(seq 1 10); do cwrite "$1" "$2" >/dev/null && return 0; sleep 3; done; return 1; }
retry "$X1" "insert into topo_s1 select g, 's1-' || g from generate_series(1, 20) g" || bad "seed topo_s1"
retry "$L" "insert into topo_s2 select g, 's2-' || g from generate_series(1, 20) g" || bad "seed topo_s2"
wait_for 30 all_have topo_s1 20 "$X1" "$X2" || bad "topo_s1 seeded"
wait_for 30 all_have topo_s2 20 $ALL || bad "topo_s2 seeded"
f=$(follower $C)
s=$(job_new "$f" split "" "az=westx;level=LOWER")
when_is "$f" "$s" running 60 && ok "the split cuts" || bad "the split cuts: [$(job_get "$f" "$s" "state||' '||reason")]"
docker restart -t 5 "$(cname "$X2")" >/dev/null
job_wait 300 "$f" "$s" done "J5 the split that lost a node of its zone during the cut done"
XU=$(job_get "$f" "$s" reason | sed -n 's/.*is cluster \([0-9a-f-]*\) now.*/\1/p')
for n in $X1 $X2; do check "J5 $n names westx's cluster" "$XU" "$(cfgval "$n" C cluster)"; done
wait_for 120 leader_among "$X1" "$X2" && XL=$(leader_among "$X1" "$X2") || XL=""
[ -n "$XL" ] && ok "J5 westx elects $XL" || bad "J5 westx elects a leader"
cwrite "$L" "insert into topo_s2 values (21, 'down')" >/dev/null || bad "write topo_s2 in west"
wait_for 90 all_have topo_s2 21 "$X1" "$X2" && ok "J5 the relay carries down" || bad "the relay carries down"

# ── the cluster it made loses its leader during the combine back ────────────
say "-- $(now) J5: westx combines back; its leader $XL restarts during the cut"
WUUID=$(cfgval "$L" C cluster)
XF=$X1; [ "$XL" = "$X1" ] && XF=$X2
k=$(job_new "$XF" combine "" "into=westc")
when_is "$XF" "$k" running 60 && ok "the combine cuts" || bad "the combine cuts: [$(job_get "$XF" "$k" "state||' '||reason")]"
docker restart -t 5 "$(cname "$XL")" >/dev/null
wait_for 300 named "$X1" "$WUUID" && wait_for 60 named "$X2" "$WUUID" \
    && ok "J5 the combine that lost its leader moved both nodes to west" || bad "J5 both name west: $X1=$(cfgval "$X1" C cluster) $X2=$(cfgval "$X2" C cluster)"
wait_for 180 good "$X1" && wait_for 60 good "$X2" && ok "J5 both are members of west again" \
    || bad "J5 both members of west: $X1=$(node_state "$X1") $X2=$(node_state "$X2")"
S2=$(sum "$L" topo_s2)
for n in $X1 $X2; do check "J5 topo_s2 the same on $n" "$S2" "$(sum "$n" topo_s2)"; done

# ── a second split loses west's leader during its cut ───────────────────────
mark   # the writers' and leaders' baseline for this last step: east's leader moved above, on purpose
say "-- $(now) J5: westx splits off again; west's leader stops during the cut"
L=$(leader_of $C)
case " $X1 $X2 " in *" $L "*) shift_leader $C "$(echo $KEEP | cut -d' ' -f1)" quiet; L=$(leader_of $C);; esac
f=$(follower $C); case " $X1 $X2 " in *" $f "*) f=$(echo $KEEP | tr ' ' '\n' | grep -vx "$L" | head -1);; esac
s2=$(job_new "$f" split "" "az=westx;level=LOWER")
when_is "$f" "$s2" running 60 && ok "the second split cuts" || bad "the second split cuts: [$(job_get "$f" "$s2" "state||' '||reason")]"
# stopped for a minute and started here rather than by fail_leader: the leader
# elected meanwhile may be a node of the zone - which then switches itself last -
# and fail_leader looks for one among the nodes that stay. And with the zone gone,
# west is its leader and one node: no quorum until the leader is back, so the
# split ends once it is (the cut and the switch happen meanwhile)
say "-- $(now) stop west's leader $L for 60s"
docker stop -t 5 "$(cname "$L")" >/dev/null
sleep 60
docker start "$(cname "$L")" >/dev/null
wait_for 120 good "$L" && ok "$L back as $(node_state "$L")" || bad "$L back within 120s: [$(node_status "$L")]"
job_wait 300 "$f" "$s2" done "J5 the split that lost west's leader during its cut done"
XU2=$(job_get "$f" "$s2" reason | sed -n 's/.*is cluster \([0-9a-f-]*\) now.*/\1/p')
for n in $X1 $X2; do check "J5 $n names the new westx" "$XU2" "$(cfgval "$n" C cluster)"; done
wait_for 120 leader_among "$X1" "$X2" && ok "J5 the new westx elects $(leader_among "$X1" "$X2")" || bad "J5 the new westx elects a leader"

# ── T8: every job finished, no lock left ────────────────────────────────────
say "-- $(now) T8: every job row finished with a reason, no lock held"
for c in "${CLUSTERS[@]}" westx; do
    if [ "$c" = westx ]; then n=$(leader_among "$X1" "$X2"); else n=$(leader_of "$c"); fi
    [ -n "$n" ] || { bad "T8 $c has a leader to ask"; continue; }
    check "T8 $c: no job left unfinished" "" "$(QT=20 q "$n" -c "select string_agg(id || ' ' || kind || ' ' || state, ', ') from $JT where state not in ('done', 'failed', 'refused', 'cancelled')")"
    check "T8 $c: every job that did not end done says why" "" "$(QT=20 q "$n" -c "select string_agg(id || ' ' || kind, ', ') from $JT where state in ('failed', 'refused', 'cancelled') and reason = ''")"
done
after_step $C
say ""
say "== topo T5: $pass ok, $fail failed"
say "   log: results/$(basename "$LOG")"
[ "$fail" = 0 ]
