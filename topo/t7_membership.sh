#!/usr/bin/env bash
# topo T7: membership border and failure cases, on the east cluster of the rmc
# layout (below top, beside west), under rmc's load. Destructive like T4 and T5:
# run it on a fresh layout - it counts on east's four first nodes.
#
#   ../rmc/up.sh && ./t7_membership.sh
#
# M5  a pause asked for the leader, then forced, is refused with the reason in
#     its log: it still leads, the term does not move, nobody pauses.
# M1  a follower paused out of the write path (node_run '<uuid8>:pause', as rmc's
#     retire and ../topology/87_node_block.sh do), then asked to follow again
#     ('<uuid8>:follow'): it follows, and holds every row written meanwhile.
# M4  a dead follower taken out of the roster without a pause: every member
#     retires it and the cluster keeps writing; then the leader is lost for a
#     minute, and the two members left must elect - which only a quorum counted
#     without the dead node allows (2 of 3; 2 of the old 4 is no majority).
# M7  two nodes added at once, each a physical copy (the documented path, as
#     rmc's add_node): both follow, both hold every row.
# M2  a node added with no data and no position (rmc's RMC_JOIN=empty): refused,
#     or it ends holding every row written before it joined. Then stopped and
#     taken out of the roster again.
#
# Expected to FAIL today - known gaps, never skipped, never accepted:
#   M1  F9 in ../topology/PLAN.md, "node_run ...:pause is a one-way door": a
#       paused node gets no apply, so the row that would resume it reaches its
#       table only by the history pull, which never re-configs. Only a restart
#       brings it back - the test then restarts it, so M4 starts from four nodes.
#   M2  ../rmc/plan.md, "Adding a node at runtime" (run 5 in ../rmc/results.md):
#       an empty node follows at once and takes every write from then on, but
#       none of the rows written before it joined.
# Writes results/t7-<time>.log; exits 0 when no check failed.
C=east
. "$(dirname "$0")/lib.sh"
topo_log t7
for c in "${CLUSTERS[@]}"; do [ -s "$RUN/members.$c" ] || die "no $RUN/members.$c - run ../rmc/up.sh first"; done
[ "$(members $C)" = "${START[$C]}" ] || die "$C is not as ../rmc/up.sh made it ($(members $C)) - run ../rmc/up.sh first"
say "== topo T7 $(now) UTC, yaxaha $(docker exec "$(cname "$(members $C | cut -d' ' -f1)")" dpkg-query -W -f='${Version}' yaxaha 2>/dev/null), cluster $C: $(members $C)"

good()    { local s; s=$(node_state "$1"); [ "$s" = Good ] || [ "$s" = Leader ]; }
paused()  { [ "$(node_state "$1")" = Paused ]; }
others()  { local n; for n in $(members $C); do [ "$n" = "$1" ] || echo "$n"; done; }
since()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
logs()    { docker logs --since "$1" "$(cname "$2")" 2>&1; }   # logs <since> <node>
# node_run, as a cluster write on the leader: '<uuid8>:<command>' reaches every
# member, and only the node it names acts on it
node_cmd() { cfg_tx $C "update $CFG set value = '$1' where module = 'C' and name = 'node_run'"; }
ext_ready() { [ "$(q "$1" <<< "select count(*) from pg_extension where extname = 'yaxaha'" 2>/dev/null)" = 1 ]; }
ids()     { QT=60 q "$1" -c "select id from rmc_ledger" 2>/dev/null | LC_ALL=C sort; }
# lacks <node> <ref>: how many ledger rows <ref> holds that <node> does not
lacks()   { LC_ALL=C comm -23 <(ids "$2") <(ids "$1") | grep -c .; }
holds_all() { [ "$(lacks "$1" "$2")" = 0 ]; }
# a member's peer line for a node reads it retired (job of reconcile_roster: Paused)
retired_on() { case "$(info "$1" E "$2")" in *", Paused,"*) return 0;; esac; return 1; }
# ...or no longer up (Down, Na, Paused): it has seen the node stop
down_on() {
    local l; l=$(info "$1" E "$2")
    [ -n "$l" ] || return 1
    case "$l" in *", Good,"*|*", Leader,"*) return 1;; esac
    return 0
}
down_everywhere() { local m; for m in $(members $C); do down_on "$m" "$1" || return 1; done; }
# cfg_retry <cluster> <sql>: a config write, tried three times - right after a node
# stops, a party drawn before its members read it down can be one short (the write
# fails "party short"/"no response from any nodes"; ytserv says retry)
cfg_retry() { local i; for i in 1 2 3; do cfg_tx "$1" "$2" && return 0; sleep 5; done; return 1; }
retired_everywhere() { local m; for m in $(members $C); do retired_on "$m" "$1" || return 1; done; }
ok_count() { load_counts $C "$1" | sed -n 's/^OK=\([0-9]*\).*/\1/p'; }
# learn <cluster> <node>: its placement, then its roster row, each a cluster write
# on that cluster's leader (Z first: rmc's add_node says why)
learn() {
    cfg_tx "$1" "insert into $CFG (name, module, value) values ('$(node_uuid "$2")', 'Z', '${AZ[$C]}')" || bad "$2's Z row on $1"
    cfg_tx "$1" "insert into $CFG (name, module, value) values ('$(node_uuid "$2")', 'N', '$(node_ip "$2"):$PORT')" || bad "$2's N row on $1"
}
# unlearn <cluster> <node>: the reverse, N before Z
unlearn() {
    cfg_retry "$1" "delete from $CFG where module = 'N' and name = '$(node_uuid "$2")'" || bad "delete $2's N row on $1"
    cfg_retry "$1" "delete from $CFG where module = 'Z' and name = '$(node_uuid "$2")'" || bad "delete $2's Z row on $1"
}
trap 'load_resume $C >/dev/null 2>&1; load_members $C $(members $C) >/dev/null 2>&1' EXIT

mark
# ── M5: a pause asked for the leader ─────────────────────────────────────────
L=$(leader_of $C)
[ -n "$L" ] || die "$C has no leader"
T0=$(node_term "$L")
for cmd in pause 'pause!'; do
    say "-- $(now) M5: node_run '$(node_u8 "$L"):$cmd' - asked of $C's leader $L"
    s0=$(since)
    node_cmd "$(node_u8 "$L"):$cmd" || bad "M5 node_run on $C"
    sleep 20
    check "M5 ($cmd) $L still leads $C" Leader "$(node_state "$L")"
    check "M5 ($cmd) ...the term did not move" "$T0" "$(node_term "$L")"
    p=""; for n in $(members $C); do paused "$n" && p="$p $n"; done
    check "M5 ($cmd) ...nobody paused" "" "$p"
    why=$(logs "$s0" "$L" | grep -a '\[grow\]' | grep -a 'LEADER' | tail -1)
    [ -n "$why" ] && ok "M5 ($cmd) ...refused, saying why: ${why#*\[grow\] }" \
        || bad "M5 ($cmd) the leader says why it refused the pause ([grow] ... LEADER) in its log"
done
node_cmd "" || bad "clear node_run on $C"

# ── M1: paused out of the write path, then asked to follow ──────────────────
L=$(leader_of $C); P=$(others "$L" | head -1)
say "-- $(now) M1: $P paused, the load going on without it, then asked to follow again"
load_members $C $(others "$P")
node_cmd "$(node_u8 "$P"):pause" || bad "M1 node_run on $C"
if wait_for 90 paused "$P"; then ok "M1 $P paused with the leader's approval"
else bad "M1 $P paused within 90s: [$(node_status "$P")]"; fi
m0=$(load_lines $C)
sleep 20
w=$(ok_count $((m0 + 1)))
[ "${w:-0}" -gt 0 ] && ok "M1 the cluster commits without it: $w writes in 20s" || bad "M1 the cluster commits with $P paused: [$(load_counts $C $((m0 + 1)))]"
node_cmd "$(node_u8 "$P"):follow" || bad "M1 node_run on $C"
t0=$(date +%s)
if wait_for 180 good "$P"; then
    ok "M1 $P follows again after $(( $(date +%s) - t0 ))s"
    load_pause $C
    wait_for "$RMC_WAIT" holds_all "$P" "$(leader_of $C)" \
        && ok "M1 $P holds every ledger row, those written while it was paused among them" \
        || bad "M1 $P holds every row written while it was paused: it lacks $(lacks "$P" "$(leader_of $C)")"
    load_resume $C
else
    bad "M1 $P follows again within 180s of '$(node_u8 "$P"):follow' (F9: the command never reaches a paused node): [$(node_status "$P" | cut -d'|' -f1)]"
    bad "M1 $P holds every row written while it was paused: it lacks $(lacks "$P" "$(leader_of $C)")"
    # F9: only a restart brings it back
    say "   ....  $P restarted, so the steps after this one start from four nodes"
    docker restart -t 5 "$(cname "$P")" >/dev/null
    wait_for "$RMC_WAIT" follows "$P" "$(leader_of $C)" && ok "$P follows after a restart" \
        || bad "$P follows after a restart: [$(node_status "$P")]"
fi
load_members $C $(members $C)

# ── M4: a dead node out of the roster, without a pause ──────────────────────
L=$(leader_of $C); D=$(others "$L" | grep -vx "$P" | tail -1); DU=$(node_uuid "$D")
say "-- $(now) M4: $D stops for good, and leaves $C's roster without a pause"
mark
load_members $C $(others "$D")
docker stop -t 5 "$(cname "$D")" >/dev/null
del_member $C "$D"
# An operator takes a node out once the cluster has seen it dead. Before its
# members read it down, a write's party can still draw it, and the roster row's
# own delete is then one member short (nightly 20261009, 20261010: "no response
# from any nodes", the row kept, a4 never retired, east leaderless for 6 min).
wait_for 60 down_everywhere "$DU" || bad "M4 every member of $C reads $D down within 60s: $(for m in $(members $C); do printf '%s=[%s] ' "$m" "$(info "$m" E "$DU" | cut -d, -f2)"; done)"
unlearn $C "$D"
for holder in $(linked_by $C); do
    unlearn "$holder" "$D"
    cfg_hosts "$holder" "$C" $(members $C) || bad "M4 ${AZ[$C]}.host on $holder"
done
if wait_for 60 retired_everywhere "$DU"; then ok "M4 every member of $C retired $D"
else bad "M4 every member retires $D once its N row is gone: $(for m in $(members $C); do printf '%s=[%s] ' "$m" "$(info "$m" E "$DU" | cut -d, -f2)"; done)"; fi
writable $C
w=$(ok_count "${MARK[$C]}")
[ "${w:-0}" -gt 0 ] && ok "M4 the writer kept committing: $w writes since $D stopped" || bad "M4 the writer committed since $D stopped: [$(load_counts $C "${MARK[$C]}")]"
say "   ....  M4: $C now loses its leader; $(members $C | wc -w) members are left, so only a quorum recomputed without $D elects"
fail_leader $C

# ── M7: two nodes join at once ──────────────────────────────────────────────
N1=a5; N2=a6
say "-- $(now) M7: $N1 and $N2 join $C at once, each a physical copy"
mark
for n in $N1 $N2; do cfg_tx $C "insert into $CFG (name, module, value) values ('$(node_uuid "$n")', 'Z', '${AZ[$C]}')" || bad "M7 $n's Z row"; done
for n in $N1 $N2; do cfg_tx $C "insert into $CFG (name, module, value) values ('$(node_uuid "$n")', 'N', '$(node_ip "$n"):$PORT')" || bad "M7 $n's N row"; done
both_in() { roster_has "$1" "$(node_uuid "$N1")" && roster_has "$1" "$(node_uuid "$N2")"; }
r=0; for m in $(members $C); do wait_for 60 both_in "$m" && r=$((r + 1)); done
check "M7 both are in the running roster of every $C member" "$(members $C | wc -w)" "$r"
L=$(leader_of $C)
read -r S1 S2 _ <<< "$(for m in $(others "$L"); do [ "$(node_state "$m")" = Good ] && echo "$m"; done | tr '\n' ' ')"
S1=${S1:-$L}; S2=${S2:-$S1}
node_run "$N1" "$S1" & p1=$!
node_run "$N2" "$S2" & p2=$!
wait "$p1" "$p2" || bad "M7 docker run $N1, $N2"
for n in $N1 $N2; do wait_for 300 ext_ready "$n" && ok "M7 $n is up, a copy" || bad "M7 $n up: $(docker logs "$(cname "$n")" 2>&1 | grep -a '\[node\]' | tail -1)"; done
t0=$(date +%s)
# [H2] the clusters run on the secret store: a join waits for the operator's
# approval - given on the leader while the join is waited for (../rmc/store.sh)
follows_approved() { approve_pending $C >/dev/null 2>&1; follows "$@"; }
for n in $N1 $N2; do
    wait_for "$RMC_WAIT" follows_approved "$n" "$(leader_of $C)" && ok "M7 $n follows $(leader_of $C) after $(( $(date +%s) - t0 ))s" \
        || bad "M7 $n follows within ${RMC_WAIT}s: [$(node_status "$n" | cut -d'|' -f1,4)]"
done
load_pause $C
for n in $N1 $N2; do
    wait_for "$RMC_WAIT" holds_all "$n" "$(leader_of $C)" && ok "M7 $n holds every ledger row" \
        || bad "M7 $n holds every ledger row: it lacks $(lacks "$n" "$(leader_of $C)")"
done
load_resume $C
for holder in $(linked_by $C); do
    for n in $N1 $N2; do learn "$holder" "$n"; done
    cfg_hosts "$holder" "$C" $(members $C) $N1 $N2 || bad "M7 ${AZ[$C]}.host on $holder"
done
add_member $C $N1; add_member $C $N2
load_members $C $(members $C)
sleep 10
after_step $C

# ── M2: a node with no data and no position ─────────────────────────────────
NE=a7; UE=$(node_uuid "$NE")
say "-- $(now) M2: $NE joins $C with no data and no position"
mark
load_pause $C
ids "$(leader_of $C)" > "$RUN/t7.before"
B=$(grep -c . "$RUN/t7.before")
load_resume $C
say "   ....  $B ledger rows before it joins"
node_run "$NE" || bad "M2 docker run $NE"
if wait_for 180 ext_ready "$NE"; then
    schema_sql | q "$NE" >/dev/null || bad "M2 schema on $NE"
    seq_sql "$NE" | q "$NE" >/dev/null
    learn $C "$NE"
    # its config: the leader's, without the leader's runtime rows (rmc's add_node,
    # RMC_JOIN=empty); cfg_ready among them starts its ytserv
    l=$(leader_of $C)
    q "$l" <<SQL | { echo "begin; set local session_replication_role = replica; delete from $CFG;"; cat; echo "commit;"; } | q "$NE" >/dev/null \
        || bad "M2 copy the config from $l to $NE"
select format('insert into $CFG (id, name, module, value) values (%s, %L, %L, %L);', id, name, module, value)
from $CFG where not (module = 'C' and name in ('term', 'single', 'leader_uuid', 'least', 'reshape_run')) order by id
SQL
    s0=$(since)
    if wait_for "$RMC_WAIT" follows_approved "$NE" "$(leader_of $C)"; then
        ok "M2 $NE, empty, admitted: it follows $(leader_of $C)"
        load_pause $C
        miss() { LC_ALL=C comm -23 "$RUN/t7.before" <(ids "$NE") | grep -c .; }
        none_missing() { [ "$(miss)" = 0 ]; }
        wait_for "$RMC_WAIT" none_missing \
            && ok "M2 ...and it holds every one of the $B rows written before it joined" \
            || bad "M2 a node admitted empty holds every row written before it joined: it lacks $(miss) of $B (../rmc/plan.md, RMC_JOIN=empty)"
        load_resume $C
    else
        why=$(logs "$s0" "$(leader_of $C)" | grep -a '\[register\] refused' | grep -a "$(node_u8 "$NE")" | tail -1)
        [ -n "$why" ] && ok "M2 $NE, empty, is refused: ${why#*\[register\] }" \
            || bad "M2 $NE neither follows within ${RMC_WAIT}s nor is refused with a reason: [$(node_status "$NE" | cut -d'|' -f1,4)]"
    fi
else
    bad "M2 $NE: PostgreSQL with the extension within 180s"
fi
say "   ....  M2: $NE stopped and taken out of $C's roster"
docker stop -t 5 "$(cname "$NE")" >/dev/null
unlearn $C "$NE"
wait_for 60 retired_everywhere "$UE" && ok "M2 every member of $C retired $NE" || bad "M2 every member retires $NE"

# ── the end ─────────────────────────────────────────────────────────────────
node_cmd "" || bad "clear node_run on $C"
p=""; for n in $(members $C); do paused "$n" && p="$p $n"; done
check "no member of $C is left paused" "" "$p"
after_step $C
say ""
say "== topo T7: $pass ok, $fail failed"
say "   log: results/$(basename "$LOG")"
[ "$fail" = 0 ] && [ "$known" = 0 ]
