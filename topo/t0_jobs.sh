#!/usr/bin/env bash
# topo T0: the job layer (yt-pgxt topo-jobs.md, phase 0), on the west cluster of
# the rmc layout, under rmc's load.
#
#   ../rmc/up.sh && ./t0_jobs.sh
#
# Turns the layer on (yt_job synced: its 'A' row and the sync trigger), then:
# a job asked for on a follower is decided by the leader; one active job per
# table; a kind that does not exist is refused, and a split without az= is
# refused naming it; a cancel; a job survives the loss of the leader; a move job runs the reshape to its flip; every member ends with
# the same job rows; the rmc invariants still hold.
# Writes results/t0-<time>.log; exits 0 when no check failed.
C=west
. "$(dirname "$0")/lib.sh"
topo_log t0
for c in "${CLUSTERS[@]}"; do [ -s "$RUN/members.$c" ] || die "no $RUN/members.$c - run ../rmc/up.sh first"; done
say "== topo T0 $(now) UTC, yaxaha $(docker exec "$(cname "$(members $C | cut -d' ' -f1)")" dpkg-query -W -f='${Version}' yaxaha 2>/dev/null), cluster $C: $(members $C)"
leader_u() { node_uuid "$(leader_of $C)"; }

mark
# ── turn the layer on ────────────────────────────────────────────────────────
say "-- $(now) sync $JT on $C: its A row on the leader, the trigger on every member"
jobs_on $C

# ── J4: asked on a follower, decided by the leader ───────────────────────────
f=$(follower $C); say "-- $(now) a noop job asked for on the follower $f"
id=$(job_new "$f" noop t0.a "hold=5")
[ -n "$id" ] && ok "job $id inserted on $f" || bad "insert a job on $f"
if wait_for 30 job_is "$f" "$id" done; then ok "job $id done"; else bad "job $id done within 30s: [$(job_get "$f" "$id" "state||' '||reason")]"; fi
check "J4 approved by the leader, not the follower" "$(leader_u)" "$(job_get "$f" "$id" approved_by)"
h=$(job_get "$f" "$id" history | grep -c .)
check "J4 its history has one line per transition (approved, running, done)" 3 "$h"

# ── J3: one active job per table ─────────────────────────────────────────────
say "-- $(now) two jobs on one table, one on another"
a=$(job_new "$f" noop t0.b "hold=40")
wait_for 30 job_is "$f" "$a" running && ok "job $a running" || bad "job $a running: [$(job_get "$f" "$a" state)]"
b=$(job_new "$(leader_of $C)" noop t0.b "")
wait_for 30 job_is "$f" "$b" refused && ok "J3 a second job on t0.b is refused" || bad "J3 job $b refused: [$(job_get "$f" "$b" state)]"
r=$(job_get "$f" "$b" reason)
case "$r" in *"busy: job $a"*) ok "J3 ...naming the job that holds it";; *) bad "J3 the reason names job $a: [$r]";; esac
c=$(job_new "$f" noop t0.c "hold=1")
wait_for 30 job_is "$f" "$c" done && ok "J3 a job on another table runs meanwhile" || bad "J3 job $c done: [$(job_get "$f" "$c" state)]"

# ── a kind that does not exist; missing or bad arguments ─────────────────────
# Every kind job.rs knows is built now (split and combine since 0.20.45), so the
# kind-level refusal left to test is the unknown one: decide() refuses it first,
# before any argument is read, as "unknown kind [<kind>]".
u=$(job_new "$f" t0_no_such_kind "" "")
if wait_for 30 job_is "$f" "$u" refused; then
    r=$(job_get "$f" "$u" reason)
    case "$r" in
        *"unknown kind [t0_no_such_kind]"*) ok "a job of a kind that does not exist is refused: $r";;
        *) bad "the refusal of kind t0_no_such_kind names it as unknown: [$r]";;
    esac
else bad "a job of kind t0_no_such_kind refused within 30s: [$(job_get "$f" "$u" "state||' '||reason")]"; fi
# a split is built: without az= it is refused by its argument check
# (split.rs params_refusal), and the reason names the missing parameter
s=$(job_new "$f" split "" "level=LOWER")
if wait_for 30 job_is "$f" "$s" refused; then
    r=$(job_get "$f" "$s" reason)
    case "$r" in
        *"split needs az="*) ok "a split without az= is refused naming it: $r";;
        *) bad "the refusal of a split without az= names az=: [$r]";;
    esac
else bad "a split without az= refused within 30s: [$(job_get "$f" "$s" "state||' '||reason")]"; fi
m=$(job_new "$f" move public.rmc_ledger "")
wait_for 30 job_is "$f" "$m" refused && ok "a move without <db>.<schema>.<table> is refused" || bad "bad move refused: [$(job_get "$f" "$m" state)]"

# ── cancel ───────────────────────────────────────────────────────────────────
x=$(job_new "$f" noop t0.d "hold=600")
wait_for 30 job_is "$f" "$x" running && ok "job $x running" || bad "job $x running"
job_cancel "$f" "$x" >/dev/null 2>&1
wait_for 30 job_is "$f" "$x" cancelled && ok "a cancel asked on a follower ends the job: cancelled" || bad "job $x cancelled: [$(job_get "$f" "$x" state)]"

# ── J5: the leader is lost mid-job ───────────────────────────────────────────
wait_for 60 job_is "$f" "$a" done && ok "job $a (t0.b) done" || bad "job $a done: [$(job_get "$f" "$a" state)]"
l=$(leader_of $C); y=$(job_new "$f" noop t0.e "hold=30")
wait_for 30 job_is "$f" "$y" running && ok "job $y running under $l" || bad "job $y running"
say "-- $(now) stop $C's leader $l for 60s"
docker stop -t 5 "$(cname "$l")" >/dev/null
nl=""; newl() { nl=$(leader_of $C); [ -n "$nl" ] && [ "$nl" != "$l" ]; }
wait_for 120 newl && ok "$C elected $nl" || bad "$C elected a new leader within 120s"
wait_for 90 job_is "$f" "$y" done && ok "J5 job $y finished by the new leader" || bad "J5 job $y done: [$(job_get "$f" "$y" "state||' '||reason")]"
sleep 30; docker start "$(cname "$l")" >/dev/null
back() { local s; s=$(node_state "$1"); [ "$s" = Good ] || [ "$s" = Leader ]; }
wait_for 120 back "$l" && ok "$l back" || bad "$l back within 120s"

# ── a move job runs the reshape to its flip ──────────────────────────────────
say "-- $(now) a move job on rmc_side (already where its rule puts it: the frames match, it flips)"
v=$(job_new "$f" move "$DB.public.rmc_side" "")
wait_for 120 job_is "$f" "$v" done && ok "the move job $v done: $(job_get "$f" "$v" reason)" || bad "move job $v done within 120s: [$(job_get "$f" "$v" "state||' '||reason")]"
moving() { info "$1" E reshape.0 | grep -q .; }
# every member reads the job done on its next tick (2s), and stops moving
none_moving() { local n; for n in $(members $C); do moving "$n" && return 1; done; return 0; }
wait_for 10 none_moving
still=""; for n in $(members $C); do moving "$n" && still="$still $n"; done
check "no member still moving rmc_side a tick after the job" "" "$still"

# ── every member holds the same job rows ─────────────────────────────────────
rows() { QT=20 q "$1" -c "select md5(string_agg(id||state||reason||approved_by||history, ',' order by id)) from $JT" 2>/dev/null; }
ref=$(rows "$(leader_of $C)"); diff=""
for n in $(members $C); do [ "$(rows "$n")" = "$ref" ] || diff="$diff $n"; done
check "every member holds the same $JT rows" "" "$diff"

after_step $C
say ""
say "== topo T0: $pass ok, $fail failed"
say "   log: results/$(basename "$LOG")"
[ "$fail" = 0 ] && [ "$known" = 0 ]
