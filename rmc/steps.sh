#!/usr/bin/env bash
# The steps and checks test.sh is made of. Source after lib.sh.

# ── checks ───────────────────────────────────────────────────────────────────

# I1-I4 for one cluster: pause its writer, let the members converge, compare
# what every member holds with what the writer was told.
verify_cluster() { # verify_cluster <cluster>
    local c="$1" n l want got t=0 args=() out line
    load_pause "$c"
    l=$(leader_of "$c")
    # converge: every member holds as many rows as the leader (or the first member)
    while :; do
        want=$(q "${l:-$(members "$c" | cut -d' ' -f1)}" <<< "select count(*) from rmc_ledger" 2>/dev/null)
        got=0
        for n in $(members "$c"); do
            [ "$(q "$n" <<< "select count(*) from rmc_ledger" 2>/dev/null)" = "$want" ] && got=$((got + 1))
        done
        [ "$got" -eq "$(members "$c" | wc -w)" ] && break
        t=$((t + 3)); [ "$t" -ge 60 ] && break
        sleep 3
    done
    lq cat "/load/ledger-$c.log" > "$RUN/ledger.$c.log" 2>/dev/null
    for n in $(members "$c"); do
        q "$n" <<< "select id from rmc_ledger order by id" > "$RUN/ids.$c.$n" 2>/dev/null
        # a Spare or Paused member is not in the quorum: I3/I4 only (verify.py)
        case "$(node_state "$n")" in
            Good|Leader) args+=("$n=$RUN/ids.$c.$n");;
            *) args+=("~$n=$RUN/ids.$c.$n");;
        esac
    done
    out=$(python3 "$HERE/verify.py" "$c" "${ID_BASE[$c]}" "$ID_SPAN" "$RUN/ledger.$c.log" "${args[@]}")
    load_resume "$c"
    while IFS= read -r line; do
        case "$line" in
            *"  OK  "*) say "$line"; pass=$((pass + 1));;
            *"  FAIL  "*) say "$line"; fail=$((fail + 1));;
            *) say "$line";;
        esac
    done <<< "$out"
}

# I5: one leader per cluster, three different ones, no collision, every member
# participating (Good or Leader)
leaders_check() {
    local c n l st seen="" s
    for c in "${CLUSTERS[@]}"; do
        l=$(leader_of "$c")
        [ -n "$l" ] || { bad "I5 $c has a leader"; continue; }
        case " $seen " in *" $l "*) bad "I5 $c's leader $l also leads another cluster";; esac
        seen="$seen $l"
        st=""
        for n in $(members "$c"); do
            s=$(node_status "$n")
            case "$s" in *ollision*|*discrepancy*) bad "I5 $n reports [${s##*|}]";; esac
            st="$st $n=$(echo "$s" | cut -d'|' -f1)"
        done
        if echo "$st" | tr ' ' '\n' | grep -v '^$' | grep -qvE '=(Good|Leader)$'; then
            bad "I5 $c: every member participates:$st"
        else
            ok "I5 $c: leader $l, term $(node_term "$l"),$st"
        fi
    done
}

# I6: remember every cluster's leader and term, then check the clusters that were
# not touched did not move
declare -A SNAP_L SNAP_T
snap() { local c l; for c in "${CLUSTERS[@]}"; do l=$(leader_of "$c"); SNAP_L[$c]=$l; SNAP_T[$c]=$( [ -n "$l" ] && node_term "$l"); done; }
indep_check() { # indep_check <the cluster that was changed>
    local c l t
    for c in "${CLUSTERS[@]}"; do
        [ "$c" = "$1" ] && continue
        l=$(leader_of "$c"); t=$( [ -n "$l" ] && node_term "$l")
        if [ "$l" = "${SNAP_L[$c]}" ] && [ "$t" = "${SNAP_T[$c]}" ]; then
            ok "I6 $c did not notice: leader $l, term $t"
        else
            bad "I6 $c moved while $1 changed: leader ${SNAP_L[$c]} -> $l, term ${SNAP_T[$c]} -> $t"
        fi
    done
}

# I8: a cluster write commits on the leader and reaches another member
probe_id=0
writable() { # writable <cluster>
    local c="$1" l w t=0 err=""
    while [ "$t" -lt 60 ]; do
        l=$(leader_of "$c")
        w=$(for n in $(members "$c"); do [ "$n" != "$l" ] && echo "$n"; done | head -1)
        if [ -n "$l" ] && [ -n "$w" ]; then
            probe_id=$((probe_id + 1))
            local id=$(( ${ID_BASE[$c]} + $(date +%s) * 1000 + probe_id % 1000 ))
            err=$(cwrite "$l" "insert into rmc_probe values ($id, 'probe')")
            sleep 2
            if [ "$(q "$w" <<< "select count(*) from rmc_probe where id = $id")" = 1 ]; then
                ok "I8 $c writable: $l -> $w"
                return 0
            fi
        fi
        t=$((t + 6)); sleep 4
    done
    bad "I8 $c writable within 60s (leader ${l:-none}): ${err//$'\n'/ }"
}

# everything after a step: I5, I6 (when a cluster was named), I1-I4, I8, and what
# the writers saw during it
after_step() { # after_step <changed cluster|-> <writer-log marks...>
    local changed="$1" c
    leaders_check
    [ "$changed" != "-" ] && indep_check "$changed"
    for c in "${CLUSTERS[@]}"; do verify_cluster "$c"; done
    for c in "${CLUSTERS[@]}"; do writable "$c"; done
    for c in "${CLUSTERS[@]}"; do say "  ....  $c writer during the step: $(load_counts "$c" "${MARK[$c]:-1}")"; done
}
declare -A MARK
mark() { local c; for c in "${CLUSTERS[@]}"; do MARK[$c]=$(( $(load_lines "$c") + 1 )); done; snap; }

# I7: the gates
gate_id=0
gates() {
    local up ea we n ext allowed ok_up hits nb uleader t
    up=$(leader_of upper); ea=$(leader_of east); we=$(leader_of west)
    say "  ....  gates: leaders upper=$up east=$ea west=$we"

    # dial: the upper cluster holds no permitted link at all
    for n in $(members upper); do
        ext=$(info "$n" E az_external)
        allowed=$(printf '%s\n' "$ext" | tr ' ' '\n' | grep -cE '=(LOWER|UPPER|NEIGHBOR)$' || true)
        check "I7 dial: upper $n holds no permitted link (LOWER is never dialled)" 0 "$allowed"
    done
    # dial: each lower leader may dial up (never at the upper leader), and sideways
    # to the neighbour's leader - and its designated deputies, which the rule admits
    # so a leader change over there is a switch: at most three targets
    uleader=$(node_u8 "$up")
    local far fl fhit
    for n in "$ea" "$we"; do
        [ -n "$n" ] || continue
        far=$([ "$n" = "$ea" ] && echo "$we" || echo "$ea"); fl=$(node_u8 "$far")
        t=0
        while :; do
            ext=$(info "$n" E az_external)
            ok_up=$(printf '%s\n' "$ext" | tr ' ' '\n' | grep -c '=UPPER$' || true)
            hits=$(printf '%s\n' "$ext" | tr ' ' '\n' | grep -c "^${uleader}=UPPER$" || true)
            nb=$(printf '%s\n' "$ext" | tr ' ' '\n' | grep -c '=NEIGHBOR$' || true)
            fhit=$(printf '%s\n' "$ext" | tr ' ' '\n' | grep -c "^${fl}=NEIGHBOR$" || true)
            [ "$ok_up" -ge 1 ] && [ "$hits" = 0 ] && [ "$fhit" = 1 ] && [ "$nb" -le 3 ] && break
            t=$((t + 5)); [ "$t" -ge 90 ] && break
            sleep 5
        done
        [ "$ok_up" -ge 1 ] && ok "I7 dial: lower leader $n may dial up ($ok_up regular node(s))" \
            || bad "I7 dial: lower leader $n has no permitted upward link: [$ext]"
        check "I7 dial: ...never at the upper leader $up" 0 "$hits"
        check "I7 dial: lower leader $n may dial the neighbour's leader $far sideways" 1 "$fhit"
        [ "$nb" -le 3 ] && ok "I7 dial: ...and at most its two deputies besides ($nb sideways target(s))" \
            || bad "I7 dial: lower leader $n may dial $nb sideways targets, more than the far leader and its two deputies: [$ext]"
    done
    # dial: a lower member holds no permitted link
    for c in east west; do
        for n in $(members "$c"); do
            [ "$n" = "$(leader_of "$c")" ] && continue
            ext=$(info "$n" E az_external)
            allowed=$(printf '%s\n' "$ext" | tr ' ' '\n' | grep -cE '=(UPPER|NEIGHBOR)$' || true)
            check "I7 dial: $c member $n holds no permitted link" 0 "$allowed"
        done
    done

    # down: a top write reaches the lower clusters - by the relay - and a lower
    # write is refused
    gate_id=$((gate_id + 1))
    local id=$(( $(date +%s) * 100 + gate_id % 100 )) err landed=0 lower=0 t0
    err=$(cwrite "$up" "insert into rmc_down values ($id, 'top')") \
        && ok "I7 down: the upper leader writes rmc_down" || bad "I7 down: the upper leader writes rmc_down: ${err//$'\n'/ }"
    sleep 5
    for n in $(members upper); do [ "$(q "$n" <<< "select count(*) from rmc_down where id = $id")" = 1 ] && landed=$((landed + 1)); done
    check "I7 down: the row is on every upper member" "$(members upper | wc -w)" "$landed"
    holds_all() { local t="$1" i="$2" n; shift 2
        for n in "$@"; do [ "$(q "$n" <<< "select count(*) from $t where id = $i")" = 1 ] || return 1; done; }
    t0=$(date +%s)
    if wait_for 60 holds_all rmc_down "$id" $(members east) $(members west); then
        ok "I7 down: the top write reached every lower member after $(( $(date +%s) - t0 ))s (the relay)"
    else
        for n in $(members east) $(members west); do [ "$(q "$n" <<< "select count(*) from rmc_down where id = $id")" = 1 ] && lower=$((lower + 1)); done
        bad "I7 down: the top write reached $lower of $(( $(members east | wc -w) + $(members west | wc -w) )) lower members within 60s"
    fi
    err=$(cwrite "$ea" "insert into rmc_down values ($((id + 50)), 'east')")
    local here there
    here=$(q "$ea" <<< "select count(*) from rmc_down where id = $((id + 50))")
    there=$(q "$up" <<< "select count(*) from rmc_down where id = $((id + 50))")
    if [ "$here" = 0 ] && [ "$there" = 0 ]; then ok "I7 down: a lower write to rmc_down is refused everywhere"
    else bad "I7 down: a lower write to rmc_down was kept: $ea=$here $up=$there (${err//$'\n'/ })"; fi

    # up: an east write reaches every upper member - by the relay - and never west;
    # a write to it from top or west is refused
    err=$(cwrite "$ea" "insert into rmc_up values ($id, 'east')") \
        && ok "I7 up: the east leader writes rmc_up" || bad "I7 up: the east leader writes rmc_up: ${err//$'\n'/ }"
    t0=$(date +%s)
    if wait_for 60 holds_all rmc_up "$id" $(members east) $(members upper); then
        ok "I7 up: the east write reached every east and upper member after $(( $(date +%s) - t0 ))s (the relay)"
    else
        landed=0; for n in $(members upper); do [ "$(q "$n" <<< "select count(*) from rmc_up where id = $id")" = 1 ] && landed=$((landed + 1)); done
        bad "I7 up: the east write reached $landed of $(members upper | wc -w) upper members within 60s"
    fi
    lower=0
    for n in $(members west); do [ "$(q "$n" <<< "select count(*) from rmc_up where id = $id")" = 0 ] || lower=$((lower + 1)); done
    check "I7 up: ...and no west node" 0 "$lower"
    local wb; wb=$(leader_of west)
    err=$(cwrite "$up" "insert into rmc_up values ($((id + 60)), 'top')")
    here=$(q "$up" <<< "select count(*) from rmc_up where id = $((id + 60))")
    [ "$here" = 0 ] && ok "I7 up: a top write to rmc_up is refused" \
        || bad "I7 up: a top write to rmc_up was kept (${err//$'\n'/ })"
    err=$(cwrite "$wb" "insert into rmc_up values ($((id + 70)), 'west')")
    here=$(q "$wb" <<< "select count(*) from rmc_up where id = $((id + 70))")
    [ "$here" = 0 ] && ok "I7 up: a west write to rmc_up is refused" \
        || bad "I7 up: a west write to rmc_up was kept (${err//$'\n'/ })"

    # side: an unsharded table never crosses the neighbour link
    err=$(cwrite "$ea" "insert into rmc_side values ($id, 'east')") \
        && ok "I7 side: the east leader writes rmc_side" || bad "I7 side: the east leader writes rmc_side: ${err//$'\n'/ }"
    sleep 15
    landed=0
    for n in $(members east); do [ "$(q "$n" <<< "select count(*) from rmc_side where id = $id")" = 1 ] && landed=$((landed + 1)); done
    check "I7 side: the row is on every east member" "$(members east | wc -w)" "$landed"
    lower=0
    for n in $(members west) $(members upper); do [ "$(q "$n" <<< "select count(*) from rmc_side where id = $id")" = 0 ] || lower=$((lower + 1)); done
    check "I7 side: ...and on no west or upper node" 0 "$lower"
}

# ── steps ────────────────────────────────────────────────────────────────────

# The clusters that hold an address for a node of <cluster>: they need its N, Z
# and host rows too. A lower cluster's node is unknown to the upper cluster until
# it signs in as a leader.
linked_by() { case "$1" in upper) echo "east west";; east) echo west;; west) echo east;; esac; }

# cfg_hosts <cluster-holding-the-row> <cluster-the-row-is-about> <node list>
cfg_hosts() {
    local holder="$1" about="$2" list="" p
    shift 2
    for p in "$@"; do list="${list:+$list,}$p:$PORT"; done
    cfg_tx "$holder" "update $CFG set value = '$list' where module = 'Z' and name = '${AZ[$about]}.host'"
}

roster_has() { # roster_has <node> <uuid>: the node's running roster lists the uuid
    case "$(info "$1" E nodes)" in *"$2"*) return 0;; esac; return 1
}
follows() { # follows <node> <leader>
    local s; s=$(node_status "$1")
    [ "$(echo "$s" | cut -d'|' -f1)" = Good ] && [ "$(echo "$s" | cut -d'|' -f3)" = "$(node_uuid "$2")" ]
}
caught_up() { # caught_up <node> <leader>
    local a b
    a=$(q "$1" <<< "select count(*) from rmc_ledger" 2>/dev/null); b=$(q "$2" <<< "select count(*) from rmc_ledger" 2>/dev/null)
    [ -n "$a" ] && [ "$a" = "$b" ]
}

# Add a node to a cluster while it runs (plan.md, "Adding a node at runtime").
#
# Order matters, and the first run showed why: a roster (N) row without its
# placement (Z) row makes the node a MEMBER of whichever cluster holds the row -
# a node of another cluster then counts in its quorum - so Z goes first. And the
# clusters that dial this one learn it only once its ytserv answers: a lower
# leader given a roster row for a node that was not running yet stopped answering.
add_node() { # add_node <cluster> <node>
    local c="$1" n="$2" u l m holder t0 ok_roster mem src
    u=$(node_uuid "$n")
    say "-- $(now) add $n to $c ($RMC_JOIN)"
    mark
    ext_ready() { [ "$(q "$1" <<< "select count(*) from pg_extension where extname = 'yaxaha'" 2>/dev/null)" = 1 ]; }
    learn() { # its own cluster learns it at runtime: Z, then N, each its own cluster transaction
        cfg_tx "$c" "insert into $CFG (name, module, value) values ('$u', 'Z', '${AZ[$c]}')" \
            && ok "add $n: Z row written on $c's leader" || bad "add $n: Z row on $c"
        # by address, not by name: ytserv resolves a roster host when the row is
        # written, and with RMC_JOIN=clone the node's container does not exist yet
        cfg_tx "$c" "insert into $CFG (name, module, value) values ('$u', 'N', '$(node_ip "$n"):$PORT')" \
            && ok "add $n: N row written on $c's leader" || bad "add $n: N row on $c"
        ok_roster=0
        for m in $(members "$c"); do wait_for 60 roster_has "$m" "$u" && ok_roster=$((ok_roster + 1)); done
        check "$n is in the running roster of every $c member (no restart)" "$(members "$c" | wc -w)" "$ok_roster"
    }
    l=$(leader_of "$c")
    [ -n "$l" ] || { bad "add $n: $c has no leader"; return 1; }

    if [ "$RMC_JOIN" = clone ]; then
        # the cluster first, so the copy carries the new node's own rows; the copy
        # from a participating follower, to keep the load off the leader
        learn
        src=$(for m in $(members "$c"); do [ "$m" != "$l" ] && [ "$(node_state "$m")" = Good ] && echo "$m"; done | head -1)
        src=${src:-$l}
        node_run "$n" "$src" || { bad "add $n: docker run"; return 1; }
        if wait_for 300 ext_ready "$n"; then
            ok "add $n: a physical copy of $src, $(q "$n" <<< "select count(*) from rmc_ledger") ledger rows, least $(q "$n" <<< "select value from $CFG where module = 'C' and name = 'least'")"
        else
            bad "add $n: a physical copy of $src: $(docker logs "$(cname "$n")" 2>&1 | grep -a '\[node\]' | tail -1)"; return 1
        fi
    else
        node_run "$n" || { bad "add $n: docker run"; return 1; }
        wait_for 180 ext_ready "$n" || { bad "add $n: PostgreSQL with the extension"; return 1; }
        schema_sql | q "$n" >/dev/null || { bad "add $n: schema"; return 1; }
        seq_sql "$n" | q "$n" >/dev/null
        learn
        # its config: the leader's, without the leader's runtime rows; cfg_ready starts ytserv
        l=$(leader_of "$c")
        [ -n "$l" ] || { bad "add $n: $c has no leader to copy the config from"; return 1; }
        q "$l" <<SQL | { echo "begin; set local session_replication_role = replica; delete from $CFG;"; cat; echo "commit;"; } | q "$n" >/dev/null \
            || { bad "add $n: copy the config from $l"; return 1; }
select format('insert into $CFG (id, name, module, value) values (%s, %L, %L, %L);', id, name, module, value)
from $CFG where not (module = 'C' and name in ('term', 'single', 'leader_uuid', 'least', 'reshape_run')) order by id
SQL
    fi
    say "  ....  $n holds $(q "$n" <<< "select count(*) from $CFG where module = 'N'") N rows, own row: $(q "$n" <<< "select count(*) from $CFG where module = 'N' and name = '$u'")"
    t0=$(date +%s)
    l=$(leader_of "$c")
    if wait_for "$RMC_WAIT" follows "$n" "$l"; then
        ok "$n follows $l after $(( $(date +%s) - t0 ))s"
    else
        bad "$n follows $l within ${RMC_WAIT}s: [$(node_status "$n" | cut -d'|' -f1,4)]"
    fi
    load_pause "$c"
    t0=$(date +%s)
    if wait_for "$RMC_WAIT" caught_up "$n" "$(leader_of "$c")"; then
        ok "$n caught up the ledger ($(q "$n" <<< "select count(*) from rmc_ledger") rows) after $(( $(date +%s) - t0 ))s"
    else
        bad "$n caught up the ledger within ${RMC_WAIT}s: $n has $(q "$n" <<< "select count(*) from rmc_ledger"), the leader $(q "$(leader_of "$c")" <<< "select count(*) from rmc_ledger")"
    fi
    load_resume "$c"

    # the clusters that dial this one learn it, now that it answers
    for holder in $(linked_by "$c"); do
        cfg_tx "$holder" "insert into $CFG (name, module, value) values ('$u', 'Z', '${AZ[$c]}')" || bad "add $n: Z row on $holder"
        cfg_tx "$holder" "insert into $CFG (name, module, value) values ('$u', 'N', '$(node_ip "$n"):$PORT')" || bad "add $n: N row on $holder"
        cfg_hosts "$holder" "$c" $(members "$c") "$n" || bad "add $n: ${AZ[$c]}.host on $holder"
        mem=0; for m in $(members "$holder"); do wait_for 60 roster_has "$m" "$u" && mem=$((mem + 1)); done
        check "$n is in the running roster of every $holder member" "$(members "$holder" | wc -w)" "$mem"
    done

    add_member "$c" "$n"
    load_members "$c" $(members "$c")
    sleep 10   # some load with the new node in the cluster before the checks
    after_step "$c"
}

# Retire a node (plan.md, "Retiring a node").
retire_node() { # retire_node <cluster> <node> [shift-to]
    local c="$1" n="$2" to="${3:-}" u holder others=() m
    u=$(node_uuid "$n")
    say "-- $(now) retire $n from $c"
    mark
    for m in $(members "$c"); do [ "$m" = "$n" ] || others+=("$m"); done
    load_members "$c" "${others[@]}"
    if [ "$(leader_of "$c")" = "$n" ]; then
        shift_leader "$c" "${to:-${others[-1]}}" quiet
        mark
    fi
    # An operator stops a node only once it has paused: a leader that kept its
    # leadership, or a pause the leader refused, ends the retirement here, and the
    # node keeps serving - stopping it anyway would test the operator's mistake,
    # and every later step would measure that instead.
    if [ "$(leader_of "$c")" = "$n" ]; then
        bad "retire $n: it still leads $c - not retired"
        load_members "$c" $(members "$c")
        after_step "$c"
        return
    fi
    cfg_tx "$c" "update $CFG set value = '$(node_u8 "$n"):pause' where module = 'C' and name = 'node_run'" \
        || bad "retire $n: node_run on $c"
    paused() { [ "$(node_state "$1")" = Paused ]; }
    if wait_for 90 paused "$n"; then
        ok "$n paused with the leader's approval"
    else
        bad "$n paused within 90s: [$(node_status "$n")]; $(docker logs "$(cname "$n")" 2>&1 | grep -a '\[grow\]' | tail -1)"
        load_members "$c" $(members "$c")
        after_step "$c"
        return
    fi
    docker stop -t 5 "$(cname "$n")" >/dev/null
    del_member "$c" "$n"
    # the reverse of add_node: N before Z, so no roster row is ever left without its placement
    cfg_tx "$c" "delete from $CFG where module = 'N' and name = '$u'" || bad "retire $n: N row on $c"
    cfg_tx "$c" "delete from $CFG where module = 'Z' and name = '$u'" || bad "retire $n: Z row on $c"
    for holder in $(linked_by "$c"); do
        cfg_tx "$holder" "delete from $CFG where module = 'N' and name = '$u'" || bad "retire $n: N row on $holder"
        cfg_tx "$holder" "delete from $CFG where module = 'Z' and name = '$u'" || bad "retire $n: Z row on $holder"
        cfg_hosts "$holder" "$c" $(members "$c") || bad "retire $n: ${AZ[$c]}.host on $holder"
    done
    after_step "$c"
}

# Move a cluster's leadership to a node: yt_info('e:<node>') on any member.
shift_leader() { # shift_leader <cluster> <target> [quiet]
    local c="$1" to="$2" quiet="${3:-}" from t0 tb ta r
    from=$(leader_of "$c"); tb=$(node_term "$from")
    say "-- $(now) move $c's leadership: $from -> $to"
    [ -n "$quiet" ] || mark
    r=$(q "$to" <<< "select value from json_to_recordset(yt_info('e:$(node_u8 "$to")')) as x(name text, value text, module text)" 2>&1 | head -1)
    say "  ....  yt_info('e:$(node_u8 "$to")'): $r"
    t0=$(date +%s)
    is_leader() { [ "$(leader_of "$1")" = "$2" ]; }
    if wait_for 120 is_leader "$c" "$to"; then
        ta=$(node_term "$to")
        ok "$to leads $c after $(( $(date +%s) - t0 ))s, term $tb -> $ta"
        [ "${ta:-0}" -gt "${tb:-0}" ] && ok "$c's term went up" || bad "$c's term went up: $tb -> $ta"
    else
        bad "$to leads $c within 120s: the leader is [$(leader_of "$c")]"
    fi
    [ -n "$quiet" ] || after_step "$c"
}

# Restart a follower with its state (PostgreSQL and ytserv): it rejoins and catches up.
refresh_node() { # refresh_node <cluster> <node>
    local c="$1" n="$2" l t0
    say "-- $(now) restart follower $n of $c"
    mark
    l=$(leader_of "$c")
    load_members "$c" $(for m in $(members "$c"); do [ "$m" = "$n" ] || echo "$m"; done)
    docker restart -t 5 "$(cname "$n")" >/dev/null
    t0=$(date +%s)
    if wait_for "$RMC_WAIT" follows "$n" "$(leader_of "$c")"; then ok "$n is back as a follower after $(( $(date +%s) - t0 ))s"
    else bad "$n is back as a follower within ${RMC_WAIT}s: [$(node_status "$n")]"; fi
    load_members "$c" $(members "$c")
    after_step "$c"
}

# Restart a cluster's leader quickly: the cluster keeps one leader and keeps committing.
refresh_leader() { # refresh_leader <cluster>
    local c="$1" l t0
    l=$(leader_of "$c")
    say "-- $(now) restart $c's leader $l"
    mark
    docker restart -t 5 "$(cname "$l")" >/dev/null
    t0=$(date +%s)
    has_leader() { [ -n "$(leader_of "$1")" ]; }
    sleep 5
    if wait_for "$RMC_WAIT" has_leader "$c"; then ok "$c has a leader after $(( $(date +%s) - t0 ))s: $(leader_of "$c")"
    else bad "$c has a leader within ${RMC_WAIT}s"; fi
    back() { local s; s=$(node_state "$1"); [ "$s" = Good ] || [ "$s" = Leader ]; }
    wait_for "$RMC_WAIT" back "$l" && ok "$l participates again ($(node_state "$l"))" || bad "$l participates again: [$(node_status "$l")]"
    after_step "$c"
}

# Stop a cluster's leader for a minute: another member must take over; the old
# leader then comes back as a follower.
fail_leader() { # fail_leader <cluster>
    local c="$1" l nl t0
    l=$(leader_of "$c")
    say "-- $(now) stop $c's leader $l for 60s"
    mark
    load_members "$c" $(for m in $(members "$c"); do [ "$m" = "$l" ] || echo "$m"; done)
    docker stop -t 5 "$(cname "$l")" >/dev/null
    t0=$(date +%s)
    other_leader() { local x; x=$(leader_of "$1"); [ -n "$x" ] && [ "$x" != "$2" ]; }
    if wait_for "$RMC_WAIT" other_leader "$c" "$l"; then
        nl=$(leader_of "$c"); ok "$c elected $nl after $(( $(date +%s) - t0 ))s without $l"
    else
        local s=""; for m in $(members "$c"); do [ "$m" = "$l" ] || s="$s $m=[$(node_status "$m" | cut -d'|' -f1,4)]"; done
        bad "$c elects a new leader within ${RMC_WAIT}s of losing $l:$s"
    fi
    sleep $(( 60 - ( $(date +%s) - t0 ) > 0 ? 60 - ( $(date +%s) - t0 ) : 0 ))
    docker start "$(cname "$l")" >/dev/null
    back() { local s; s=$(node_state "$1"); [ "$s" = Good ] || [ "$s" = Leader ]; }
    t0=$(date +%s)
    if wait_for "$RMC_WAIT" back "$l"; then ok "$l is back after $(( $(date +%s) - t0 ))s as $(node_state "$l")"
    else bad "$l is back within ${RMC_WAIT}s: [$(node_status "$l")]"; fi
    load_members "$c" $(members "$c")
    after_step "$c"
}

# I9: writes that start on a follower. Kept out of the load and run last (P7):
# the first runs found that they leave a gap behind on the other members, and a
# gap makes every later write there wait (plan.md, "The load").
follower_writes() { # follower_writes <cluster> <count>
    local c="$1" k="$2" l f i id err fl=() done=() fails="" rep=0 n all
    l=$(leader_of "$c")
    for n in $(members "$c"); do [ "$n" = "$l" ] || fl+=("$n"); done
    for i in $(seq 1 "$k"); do
        f="${fl[$((i % ${#fl[@]}))]}"
        id=$(( ${ID_BASE[$c]} + 800000000000 + $(date +%s) * 10 + i ))
        if err=$(cwrite "$f" "insert into rmc_probe values ($id, 'from $f')"); then
            done+=("$id")
        else
            fails="$fails $f:[$(echo "$err" | tr '\n' ' ' | cut -c1-90)]"
        fi
        sleep 2
    done
    sleep 15
    for id in "${done[@]}"; do
        all=1
        for n in $(members "$c"); do [ "$(q "$n" <<< "select count(*) from rmc_probe where id = $id")" = 1 ] || all=0; done
        rep=$((rep + all))
    done
    check "I9 $c: follower-originated writes commit (of $k)" "$k" "${#done[@]}"
    [ -z "$fails" ] || say "  ....  $c refused:$fails"
    check "I9 $c: ...and reach every member" "${#done[@]}" "$rep"
}
