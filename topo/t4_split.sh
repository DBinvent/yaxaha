#!/usr/bin/env bash
# topo T4: split and combine of members (yt-pgxt topo-jobs.md, phase 4), on the
# west cluster of the rmc layout - itself below top, beside east - under rmc's
# load. Destructive: run it last, after a fresh ../rmc/up.sh.
#
#   ../rmc/up.sh && ./t4_split.sh
#
# Places two west members in a zone westx and splits it off as a cluster of its
# own, below west: refused first while a table both sides hold cannot cross; then
# approved from above (by top), the zone's table going with it and the shared one
# crossing the relay both ways, westx electing its own leader and its group jobs
# approved by west - its direct upper - never by top. Then westx combines back
# into west: its nodes members of west again, in zone westx, with the rows
# written while apart.
# J9 (split and combine keep every acknowledged row, the relay carries, the new
# cluster elects), J10. Writes results/t4-<time>.log; exits 0 when no check failed.
C=west
. "$(dirname "$0")/lib.sh"
topo_log t4
for c in "${CLUSTERS[@]}"; do [ -s "$RUN/members.$c" ] || die "no $RUN/members.$c - run ../rmc/up.sh first"; done
say "== topo T4 $(now) UTC, yaxaha $(docker exec "$(cname "$(members $C | cut -d' ' -f1)")" dpkg-query -W -f='${Version}' yaxaha 2>/dev/null), cluster $C: $(members $C)"

cfgval() { QT=20 q "$1" -c "select value from $CFG where module = '$2' and name = '$3'" 2>/dev/null; }
rows()   { QT=20 q "$1" -c "select count(*) from $2" 2>/dev/null; }
has_id() { [ "$(QT=20 q "$1" -c "select count(*) from $2 where id = $3" 2>/dev/null)" = 1 ]; }
all_have() { local t="$1" id="$2" n; shift 2; for n in "$@"; do has_id "$n" "$t" "$id" || return 1; done; }
sum()    { QT=20 q "$1" -c "select coalesce(md5(string_agg(id || ':' || v, ',' order by id)), 'empty') from $2" 2>/dev/null; }
leads()  { [ "$(node_state "$1")" = Leader ]; }
leader_among() { local n; for n in "$@"; do leads "$n" && { echo "$n"; return 0; }; done; return 1; }
named()  { [ "$(cfgval "$1" C cluster)" = "$2" ]; }
good()   { [ "$(node_state "$1")" = "$2" ]; }

mark
for c in "${CLUSTERS[@]}"; do jobs_on "$c"; done
L=$(leader_of $C)
read -r X1 X2 _ <<< "$(for n in $(members $C); do [ "$n" = "$L" ] || echo "$n"; done | tail -2 | tr '\n' ' ')"
KEEP=$(for n in $(members $C); do case " $X1 $X2 " in *" $n "*) ;; *) printf '%s ' "$n";; esac; done)
f=$(follower $C)
WUUID=$(cfgval "$L" C cluster)
say "   leader $L; $X1 and $X2 leave, $KEEP stay"

# ── a zone, a table that goes with it and one that will cross ───────────────
say "-- $(now) zone westx of $X1 and $X2; topo_s1 routed to westx, topo_s2 to both"
z=$(job_new "$f" az_create "" "name=westx;tier=1;nodes=$(node_uuid "$X1"),$(node_uuid "$X2")")
job_wait 60 "$f" "$z" done "zone westx made of $X1, $X2"
for n in $(members $C); do
    for t in topo_s1 topo_s2; do
        q "$n" -c "create table if not exists $t (id bigint primary key, v text)" \
            -c "drop trigger if exists zytsync_${t}_trigger on public.$t" \
            -c "create trigger zytsync_${t}_trigger after insert or update or delete on public.$t for each row execute procedure public.yt_synchronize()" \
            >/dev/null 2>&1
    done
done
cfg_tx $C "insert into $CFG (name, module, value) values ('public.topo_s1', 'A', '$(enc 'az=westx')')" || bad "the A row for topo_s1"
cfg_tx $C "insert into $CFG (name, module, value) values ('public.topo_s2', 'A', '$(enc 'az=westc,westx')')" || bad "the A row for topo_s2"
sleep 5
cwrite "$X1" "insert into topo_s1 select g, 's1-' || g from generate_series(1, 20) g" >/dev/null || bad "seed topo_s1 on $X1"
cwrite "$L" "insert into topo_s2 select g, 's2-' || g from generate_series(1, 20) g" >/dev/null || bad "seed topo_s2 on $L"
wait_for 30 all_have topo_s1 20 "$X1" "$X2" && ok "topo_s1 seeded in westx" || bad "topo_s1 seeded: $X2=$(rows "$X2" topo_s1)"
wait_for 30 all_have topo_s2 20 $(members $C) && ok "topo_s2 seeded everywhere" || bad "topo_s2 seeded"

# ── refused while a table both sides hold cannot cross ──────────────────────
say "-- $(now) split westx off: the ledger is held everywhere and carried nowhere"
r=$(job_new "$f" split "" "az=westx;level=LOWER")
job_wait 60 "$f" "$r" refused "a split is refused while a table both sides hold cannot cross"
case "$(job_get "$f" "$r" reason)" in *rmc_ledger*) ok "...naming the table";; *) bad "the refusal names rmc_ledger: [$(job_get "$f" "$r" reason)]";; esac
say "-- $(now) the ledger stays with westc; the writer and the checks follow its holders"
cfg_tx $C "update $CFG set value = '$(enc 'az=westc; no_up; no_down')' where module = 'A' and name in ('public.rmc_ledger', 'public.rmc_probe')" \
    || bad "route the ledger to westc"
load_members $C $KEEP
echo "$KEEP" > "$RUN/members.$C"
sleep 5

# ── the split ───────────────────────────────────────────────────────────────
say "-- $(now) split westx off, below west"
s=$(job_new "$f" split "" "az=westx;level=LOWER")
job_wait 240 "$f" "$s" done "J9 westx split off"
by=$(job_get "$f" "$s" approved_by)
case "$by" in top/*) ok "J10 ...approved from above, by top's leader";; *) bad "J10 approved by top: [$by]";; esac
XU=$(job_get "$f" "$s" reason | sed -n 's/.*is cluster \([0-9a-f-]*\) now.*/\1/p')
[ -n "$XU" ] && ok "westx is cluster $XU" || bad "the reason names the new cluster: [$(job_get "$f" "$s" reason)]"
check "J9 $X1 names it" "$XU" "$(cfgval "$X1" C cluster)"
check "J9 ...and $X2" "$XU" "$(cfgval "$X2" C cluster)"
check "J9 west records westx below it" LOWER "$(cfgval "$L" Z westx.level)"
check "J9 west's roster holds neither" 0 "$(QT=20 q "$L" -c "select count(*) from $CFG where module = 'N' and name in ('$(node_uuid "$X1")', '$(node_uuid "$X2")')")"
check "J9 westx records west above it" UPPER "$(cfgval "$X1" Z westc.level)"
wait_for 90 leader_among "$X1" "$X2" && XL=$(leader_among "$X1" "$X2") || XL=""
[ -n "$XL" ] && ok "J9 westx elects its own leader: $XL" || bad "J9 westx elects a leader within 90s: $X1=$(node_state "$X1") $X2=$(node_state "$X2")"
XF=$X1; [ "$XL" = "$X1" ] && XF=$X2

# ── its tables ──────────────────────────────────────────────────────────────
check "J9 the zone's table went with it ($X1)" 20 "$(rows "$X1" topo_s1)"
cwrite "$XF" "insert into topo_s1 values (21, 'in westx')" >/dev/null || bad "write topo_s1 in westx"
wait_for 30 all_have topo_s1 21 "$X1" "$X2" && ok "J9 a write to it in westx reaches both its nodes" || bad "topo_s1 21 in westx"
if cwrite "$L" "insert into topo_s1 values (99, 'from west')" >/dev/null 2>&1; then
    bad "west writes a table that went with westx"
else ok "west no longer writes the table that went"; fi
cwrite "$L" "insert into topo_s2 values (21, 'from west')" >/dev/null || bad "write topo_s2 in west"
wait_for 90 all_have topo_s2 21 "$X1" "$X2" && ok "J9 the shared table crosses down, west to westx" || bad "topo_s2 21 down: $X1=$(has_id "$X1" topo_s2 21 && echo y || echo n)"
cwrite "$XF" "insert into topo_s2 values (22, 'from westx')" >/dev/null || bad "write topo_s2 in westx"
wait_for 90 all_have topo_s2 22 $KEEP && ok "J9 ...and up, westx to west" || bad "topo_s2 22 up"

# ── approval from the direct upper only ─────────────────────────────────────
say "-- $(now) J10: westx is below west, below top - its group job is west's to approve"
g=$(job_new "$XF" group_noop "$DB.public.topo_s3" "")
job_wait 60 "$XF" "$g" done "J10 a group job in westx done"
case "$(job_get "$XF" "$g" approved_by)" in westc/*) ok "J10 ...approved by west, its direct upper, not top";;
    *) bad "J10 approved by westc: [$(job_get "$XF" "$g" approved_by)]";; esac

# ── combine back ────────────────────────────────────────────────────────────
say "-- $(now) westx combines back into west"
k=$(job_new "$XF" combine "" "into=westc")
wait_for 240 named "$X1" "$WUUID" && wait_for 30 named "$X2" "$WUUID" \
    && ok "J9 $X1 and $X2 name west's cluster again" || bad "J9 both name west: $X1=$(cfgval "$X1" C cluster) $X2=$(cfgval "$X2" C cluster)"
p=$(QT=20 q "$L" -c "select state || ' ' || reason from $JT where kind = 'participate' and params like 'from=westx;job=$k;%' order by id limit 1")
case "$p" in done*admitted*) ok "J9 west admitted them: ${p#done }";; *) bad "west's part reads admitted: [$p]";; esac
wait_for 180 good "$X1" Good && wait_for 60 good "$X2" Good && ok "J9 both follow west's leader" \
    || bad "J9 both Good members of west: $X1=$(node_state "$X1") $X2=$(node_state "$X2")"
check "J9 west's catalogue has no westx any more" "" "$(cfgval "$L" Z westx.level)"
check "J9 $X1 holds what was written in westx" 21 "$(rows "$X1" topo_s1)"
cwrite "$X1" "insert into topo_s1 values (23, 'in west again')" >/dev/null || bad "write topo_s1 on $X1 in west"
wait_for 30 all_have topo_s1 23 "$X1" "$X2" && ok "J9 its table is written in west's consensus now" || bad "topo_s1 23"
S2=$(sum "$L" topo_s2)
for n in $X1 $X2 $KEEP; do check "J9 topo_s2 the same on $n" "$S2" "$(sum "$n" topo_s2)"; done

after_step $C
say ""
say "== topo T4: $pass ok, $fail failed"
say "   log: results/$(basename "$LOG")"
[ "$fail" = 0 ]
