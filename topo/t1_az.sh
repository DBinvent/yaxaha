#!/usr/bin/env bash
# topo T1: az create and delete at runtime (yt-pgxt topo-jobs.md, phase 1), as
# jobs, on the west cluster of the rmc layout, under rmc's load.
#
#   ../rmc/up.sh && ./t1_az.sh          (after t0_jobs.sh, or on its own)
#
# Creates a zone and a linked cluster's catalogue entry, and checks every member
# holds them without a restart; refuses a second create, a delete of a zone a
# table is routed to, and a delete of a zone a live node is placed in; deletes
# them once nothing uses them, and checks they are gone from every member's map,
# again without a restart. J7, J3 for az jobs, J10's leader rule.
# Writes results/t1-<time>.log; exits 0 when no check failed.
C=west
. "$(dirname "$0")/lib.sh"
topo_log t1
for c in "${CLUSTERS[@]}"; do [ -s "$RUN/members.$c" ] || die "no $RUN/members.$c - run ../rmc/up.sh first"; done
say "== topo T1 $(now) UTC, yaxaha $(docker exec "$(cname "$(members $C | cut -d' ' -f1)")" dpkg-query -W -f='${Version}' yaxaha 2>/dev/null), cluster $C: $(members $C)"

# az_line <node> <name>: one of yt_info('E')'s az lines on a node
az_line() { info "$1" E "$2"; }
# on_all <check-description> <command...>: the command succeeds on every member
on_all() {
    local what="$1" n bad_on=""; shift
    for n in $(members $C); do "$@" "$n" >/dev/null 2>&1 || bad_on="$bad_on $n"; done
    [ -z "$bad_on" ] && ok "$what, on every member" || bad "$what: not on$bad_on"
}
has_tier()  { az_line "$2" az_tier | tr ' ' '\n' | grep -qx "$1"; }
no_tier()   { ! az_line "$2" az_tier | tr ' ' '\n' | grep -q "^$1="; }
has_link()  { az_line "$2" az_link | tr ' ' '\n' | grep -q "^$1"; }
no_link()   { ! az_line "$2" az_link | tr ' ' '\n' | grep -q "^$1="; }
zone_of()   { az_line "$2" az | grep -qE "(^| |\()$1=[0-9]"; }
started()   { docker inspect -f '{{.State.StartedAt}}' "$(cname "$1")"; }

mark
declare -A START; for n in $(members $C); do START[$n]=$(started "$n"); done
jobs_on $C
f=$(follower $C)

# ── create a zone ────────────────────────────────────────────────────────────
say "-- $(now) az_create westx (tier 1), asked on the follower $f"
a=$(job_new "$f" az_create "" "name=westx;tier=1")
job_wait 60 "$f" "$a" done "J7 az_create westx done"
check "J7 ...approved by the leader" "$(node_uuid "$(leader_of $C)")" "$(job_get "$f" "$a" approved_by)"
on_all "J7 westx=1 is in the tiers" has_tier "westx=1"
b=$(job_new "$f" az_create "" "name=westx;tier=2")
job_wait 30 "$f" "$b" refused "a second az_create westx is refused"

# ── create a linked cluster's catalogue entry ────────────────────────────────
say "-- $(now) az_create fakec (a NEIGHBOR cluster, by address)"
c=$(job_new "$f" az_create "" "name=fakec;level=NEIGHBOR;host=fakec1:7421")
job_wait 60 "$f" "$c" done "J7 az_create fakec done"
on_all "J7 fakec=NEIGHBOR is in the catalogue" has_link "fakec=NEIGHBOR@fakec1:7421"
d=$(job_new "$f" az_create "" "name=fakel;level=LOWER")
job_wait 30 "$f" "$d" refused "a LOWER cluster without its key is refused"

# ── a zone in use is not deleted ─────────────────────────────────────────────
say "-- $(now) route a table to westx, then try to delete westx"
for n in $(members $C); do
    q "$n" -c "create table if not exists topo_t (id bigint primary key, v text)" \
        -c "drop trigger if exists zytsync_topo_t_trigger on public.topo_t" \
        -c "create trigger zytsync_topo_t_trigger after insert or update or delete on public.topo_t for each row execute procedure public.yt_synchronize()" \
        >/dev/null 2>&1
done
cfg_tx $C "insert into $CFG (name, module, value) values ('public.topo_t', 'A', '$(enc 'az=westx')')" || bad "the A row for topo_t"
sleep 5
e=$(job_new "$f" az_delete "" "name=westx")
job_wait 30 "$f" "$e" refused "J7 az_delete westx is refused while a table is routed to it"
r=$(job_get "$f" "$e" reason)
case "$r" in *topo_t*) ok "J7 ...naming the table: $r";; *) bad "J7 the reason names topo_t: [$r]";; esac
e2=$(job_new "$f" az_delete "" "name=westx;force")
job_wait 30 "$f" "$e2" refused "J7 ...even with force: a table is never forced"

# ── a zone a live node is placed in is not deleted ───────────────────────────
nd=$(echo $(members $C) | awk '{print $NF}'); ndu=$(node_uuid "$nd")
say "-- $(now) az_create westy with $nd placed in it, then try to delete westy"
g=$(job_new "$f" az_create "" "name=westy;tier=1;nodes=$ndu")
job_wait 60 "$f" "$g" done "J7 az_create westy (tier 1, $nd) done"
on_all "J7 westy holds one node" zone_of "westy"
h=$(job_new "$f" az_delete "" "name=westy;force")
job_wait 30 "$f" "$h" refused "J7 az_delete westy is refused while a live node is placed in it, force or not"
r=$(job_get "$f" "$h" reason)
case "$r" in *"$(node_u8 "$nd")"*) ok "J7 ...naming the node: $r";; *) bad "J7 the reason names $nd: [$r]";; esac
say "-- $(now) place $nd back in westc"
cfg_tx $C "update $CFG set value = 'westc' where module = 'Z' and name = '$ndu'" || bad "re-place $nd"
sleep 5

# ── delete what nothing uses any more ────────────────────────────────────────
say "-- $(now) take the routing off topo_t, then delete westx, westy and fakec"
cfg_tx $C "delete from $CFG where module = 'A' and name = 'public.topo_t'" || bad "delete topo_t's A row"
sleep 5
x=$(job_new "$f" az_delete "" "name=westx")
job_wait 60 "$f" "$x" done "J7 az_delete westx done"
on_all "J7 westx is gone from the tiers, no restart" no_tier "westx"
y=$(job_new "$f" az_delete "" "name=westy")
job_wait 60 "$f" "$y" done "J7 az_delete westy done"
on_all "J7 westy is gone from the tiers" no_tier "westy"
z=$(job_new "$f" az_delete "" "name=fakec")
job_wait 60 "$f" "$z" done "J7 az_delete fakec done"
on_all "J7 fakec is gone from the catalogue" no_link "fakec"
w=$(job_new "$f" az_delete "" "name=westx")
job_wait 30 "$f" "$w" refused "deleting westx again is refused"

# ── nothing restarted, and the cluster is as it was ──────────────────────────
re=""; for n in $(members $C); do [ "$(started "$n")" = "${START[$n]}" ] || re="$re $n"; done
check "no member restarted during T1" "" "$re"
on_all "westc still holds its members" zone_of "westc"
after_step $C
say ""
say "== topo T1: $pass ok, $fail failed"
say "   log: results/$(basename "$LOG")"
[ "$fail" = 0 ]
