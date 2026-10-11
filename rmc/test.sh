#!/usr/bin/env bash
# Run the phases of plan.md against the clusters up.sh made, under the load.
#
#   ./test.sh            # every phase, in order: P1 ... P7
#   ./test.sh P4 P5      # some phases (each one assumes the ones before it ran)
#
# Writes results/run-<time>.log and exits 0 only when no check failed and no GAP
# was reported. A GAP line is a limitation the design documents as not built yet:
# it is counted apart in the summary, and it fails the run like a FAIL - a known
# gap is still a gap, and a green run must not hide one.
. "$(dirname "$0")/lib.sh"
. "$HERE/steps.sh"

mkdir -p "$HERE/results"
LOG="$HERE/results/run-$(date -u +%Y%m%d-%H%M%S).log"
exec > >(tee "$LOG") 2>&1

for c in "${CLUSTERS[@]}"; do [ -s "$RUN/members.$c" ] || die "no $RUN/members.$c - run up.sh first"; done
say "== rmc $(now) UTC, yaxaha $(docker exec "$(cname "$(members upper | cut -d' ' -f1)")" dpkg-query -W -f='${Version}' yaxaha 2>/dev/null)"
say "   upper: $(members upper)   east: $(members east)   west: $(members west)   load: $RMC_ORIGIN, ${RMC_TX_MS}ms"

declare -A PHASE_RESULT
phase() { # phase <id> <title>
    PH="$1"; PH_PASS=$pass; PH_FAIL=$fail; PH_GAP=$known
    say ""
    say "==== $1 $2 ($(now))"
}
phase_end() {
    PHASE_RESULT[$PH]="$((pass - PH_PASS)) ok, $((fail - PH_FAIL)) failed, $((known - PH_GAP)) gap"
    say "==== $PH: ${PHASE_RESULT[$PH]}"
}

P1() {
    phase P1 "baseline: a minute of load"
    mark
    sleep 60
    after_step -
    gates
    phase_end
}

P2() {
    phase P2 "grow every level at runtime, one node at a time"
    add_node upper u4
    add_node east a5
    add_node west b5
    gates
    phase_end
}

P3() {
    phase P3 "move each cluster's leadership to its new node"
    shift_leader upper u4
    shift_leader east a5
    shift_leader west b5
    gates
    phase_end
}

P4() {
    phase P4 "refresh: restart a follower, restart the leader, lose the leader for a minute"
    local c f
    for c in "${CLUSTERS[@]}"; do
        f=$(members "$c" | tr ' ' '\n' | grep -vx "$(leader_of "$c")" | head -1)
        refresh_node "$c" "$f"
    done
    for c in "${CLUSTERS[@]}"; do refresh_leader "$c"; done
    for c in "${CLUSTERS[@]}"; do fail_leader "$c"; done
    gates
    phase_end
}

P5() {
    phase P5 "turnover: add new nodes and retire the original ones, under load"
    add_node east a6;  retire_node east a1 a6
    add_node east a7;  retire_node east a2 a7
    add_node east a8;  retire_node east a3 a8
    retire_node east a4 a5
    add_node upper u5; retire_node upper u1 u5
    add_node west b6;  retire_node west b1 b6
    gates
    phase_end
}

P6() {
    phase P6 "after turnover: elect again, restart a new follower"
    local to f
    to=$(members east | tr ' ' '\n' | grep -vx "$(leader_of east)" | tail -1)
    shift_leader east "$to"
    f=$(members east | tr ' ' '\n' | grep -vx "$(leader_of east)" | head -1)
    refresh_node east "$f"
    gates
    phase_end
}

P7() {
    phase P7 "writes that start on a follower (last: they can leave gaps behind)"
    local c
    for c in "${CLUSTERS[@]}"; do follower_writes "$c" 6; done
    mark
    sleep 20
    after_step -
    phase_end
}

phases=("$@"); [ ${#phases[@]} -gt 0 ] || phases=(P1 P2 P3 P4 P5 P6 P7)
for p in "${phases[@]}"; do
    case "$p" in P1|P2|P3|P4|P5|P6|P7) "$p";; *) die "unknown phase $p (P1..P7)";; esac
done

say ""
say "==== summary ($(now) UTC)"
for p in "${phases[@]}"; do say "  $p: ${PHASE_RESULT[$p]}"; done
for c in "${CLUSTERS[@]}"; do say "  $c: members $(members "$c"); writer $(load_counts "$c")"; done
say "  total: $pass ok, $fail failed, $known gap"
say "  log: results/$(basename "$LOG")"
[ "$fail" -eq 0 ] && [ "$known" -eq 0 ]
