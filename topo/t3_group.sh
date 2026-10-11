#!/usr/bin/env bash
# topo T3: jobs that span linked clusters (yt-pgxt topo-jobs.md, phase 3) -
# approval from above and participation locks - on the three linked clusters of
# the rmc layout (top above eastc and westc, which are neighbours), under rmc's
# load. `group_noop` is the job: it holds a table on its own cluster and on every
# one named in `with=`, for `hold` seconds.
#
#   ../rmc/up.sh && ./t3_group.sh       (after t0..t2, or on its own)
#
# J10 the top cluster's leader approves its own group job; a lower cluster's is
# approved by its upper's leader, which keeps a record of it, and refused while the
# upper takes part in a group job on the same table. J8 a cluster taking part in a
# group job on a table refuses its own jobs and other group jobs on it until
# released; a job takes every participant's lock or none; two jobs racing for the
# same two clusters - one wins, the other is refused naming the holder, and gets it
# on retry. No lock is left held at the end.
# Writes results/t3-<time>.log; exits 0 when no check failed.
C=west
. "$(dirname "$0")/lib.sh"
topo_log t3
for c in "${CLUSTERS[@]}"; do [ -s "$RUN/members.$c" ] || die "no $RUN/members.$c - run ../rmc/up.sh first"; done
say "== topo T3 $(now) UTC, yaxaha $(docker exec "$(cname "$(members $C | cut -d' ' -f1)")" dpkg-query -W -f='${Version}' yaxaha 2>/dev/null)"

g() { echo "$DB.public.topo_g$1"; }
# part <node> <table> <from-az> <job>: the state of that cluster's part in the job
part() { QT=20 q "$1" -c "select coalesce(max(state), 'none') from $JT where kind = 'participate' and tabl = '$2' and params like 'from=$3;job=$4;%'" 2>/dev/null; }
held() { QT=20 q "$1" -c "select count(*) from $JT where kind = 'participate' and state not in ('done', 'cancelled')" 2>/dev/null; }
settled() { case "$(job_get "$1" "$2" state)" in running|done|refused|failed|cancelled) return 0;; esac; return 1; }

mark
for c in "${CLUSTERS[@]}"; do jobs_on "$c"; done
U=$(follower upper); E=$(follower east); W=$(follower west)
UL=$(leader_of upper)

# ── J10: who approves ───────────────────────────────────────────────────────
say "-- $(now) J10: top has no upper - its own leader approves; west's job is approved by top"
a=$(job_new "$U" group_noop "$(g 1)" "")
job_wait 60 "$U" "$a" done "J10 a group job on top done"
check "J10 ...approved by top's own leader" "$(node_uuid "$UL")" "$(job_get "$U" "$a" approved_by)"
b=$(job_new "$W" group_noop "$(g 1)" "")
job_wait 60 "$W" "$b" done "J10 a group job on west done"
check "J10 ...approved from above, by top's leader" "top/$(node_uuid "$(leader_of upper)")" "$(job_get "$W" "$b" approved_by)"
check "J10 top keeps a record of the approval" 1 \
    "$(QT=20 q "$(leader_of upper)" -c "select count(*) from $JT where kind = 'approval' and params like 'for=westc;job=$b;%'")"

# ── J8: a participation holds the table there ───────────────────────────────
say "-- $(now) J8: west's group job holds $(g 2) on west and east"
c=$(job_new "$W" group_noop "$(g 2)" "with=eastc;hold=40")
job_wait 60 "$W" "$c" running "J8 west's job holds both clusters"
check "J8 east records its part in west's job" running "$(part "$E" "$(g 2)" westc "$c")"
check "J8 ...and west its own" running "$(part "$W" "$(g 2)" westc "$c")"
d=$(job_new "$E" noop "$(g 2)" "hold=1")
job_wait 30 "$E" "$d" refused "J8 east refuses a job of its own on the table meanwhile"
e=$(job_new "$E" group_noop "$(g 2)" "with=westc")
job_wait 30 "$E" "$e" refused "J8 ...and a group job of its own on it"
job_wait 90 "$W" "$c" done "J8 west's job done"
check "J8 east's part released" done "$(part "$E" "$(g 2)" westc "$c")"
e2=$(job_new "$E" group_noop "$(g 2)" "with=westc")
job_wait 60 "$E" "$e2" done "J8 east's group job on the table, asked again, done"

# ── J10: an upper taking part refuses its approval ──────────────────────────
say "-- $(now) J10: top takes part in east's group job on $(g 3); west's job on it is refused from above"
f=$(job_new "$E" group_noop "$(g 3)" "with=top;hold=40")
job_wait 60 "$E" "$f" running "east's job holds $(g 3) on east and top"
h=$(job_new "$W" group_noop "$(g 3)" "")
job_wait 60 "$W" "$h" refused "J10 west's job on the table is refused"
case "$(job_get "$W" "$h" reason)" in
    *"refused from above"*"top:"*"takes part"*) ok "J10 ...from above, by top, which takes part itself";;
    *) bad "J10 refused from above: [$(job_get "$W" "$h" reason)]";; esac
job_wait 90 "$E" "$f" done "east's job done"
h2=$(job_new "$W" group_noop "$(g 3)" "")
job_wait 60 "$W" "$h2" done "J10 ...and approved once top is free"

# ── J8: every lock or none ──────────────────────────────────────────────────
say "-- $(now) J8: top holds $(g 4) by a job of its own; west's job with east and top takes neither"
i=$(job_new "$U" noop "$(g 4)" "hold=40")
job_wait 30 "$U" "$i" running "top's own job holds $(g 4)"
k=$(job_new "$W" group_noop "$(g 4)" "with=eastc,top")
job_wait 60 "$W" "$k" refused "J8 west's job on the table is refused"
case "$(job_get "$W" "$k" reason)" in
    *"top:"*"job $i (noop running)"*) ok "J8 ...by top, naming its job";;
    *) bad "J8 refused by top naming job $i: [$(job_get "$W" "$k" reason)]";; esac
check "J8 east - asked first, in az order - took its part and released it" done "$(part "$E" "$(g 4)" westc "$k")"
check "J8 ...west never took its own" none "$(part "$W" "$(g 4)" westc "$k")"
job_wait 60 "$U" "$i" done "top's own job done"

# ── J8: two jobs racing for the same two clusters ───────────────────────────
say "-- $(now) J8: west and east ask for a group job on $(g 5) with each other, at once"
( job_new "$W" group_noop "$(g 5)" "with=eastc;hold=15" > "$RUN/t3.r1" ) &
( job_new "$E" group_noop "$(g 5)" "with=westc;hold=15" > "$RUN/t3.r2" ) &
wait
r1=$(cat "$RUN/t3.r1"); r2=$(cat "$RUN/t3.r2")
wait_for 90 settled "$W" "$r1" && wait_for 90 settled "$E" "$r2" || bad "both racing jobs decided"
s1=$(job_get "$W" "$r1" state); s2=$(job_get "$E" "$r2" state)
say "   west's job $r1: $s1 - $(job_get "$W" "$r1" reason)"
say "   east's job $r2: $s2 - $(job_get "$E" "$r2" reason)"
case "$s1/$s2" in
    running/refused|done/refused) win=W; lose=E; lid=$r2; wid=$r1; lwith=westc;;
    refused/running|refused/done) win=E; lose=W; lid=$r1; wid=$r2; lwith=eastc;;
    *) win=""; bad "J8 exactly one of the racing jobs won: west $s1, east $s2";;
esac
if [ -n "$win" ]; then
    ok "J8 exactly one of the racing jobs won"
    case "$(job_get "${!lose}" "$lid" reason)" in
        *busy*) ok "J8 ...the other was refused, naming the holder";;
        *) bad "J8 the loser names the holder: [$(job_get "${!lose}" "$lid" reason)]";; esac
    job_wait 60 "${!win}" "$wid" done "J8 the winner done"
    again=$(job_new "${!lose}" group_noop "$(g 5)" "with=$lwith")
    job_wait 60 "${!lose}" "$again" done "J8 the loser's job, asked again, done"
fi

# ── nothing left held ───────────────────────────────────────────────────────
for c in "${CLUSTERS[@]}"; do check "no participation left held on $c" 0 "$(held "$(leader_of "$c")")"; done
after_step $C
say ""
say "== topo T3: $pass ok, $fail failed"
say "   log: results/$(basename "$LOG")"
[ "$fail" = 0 ]
