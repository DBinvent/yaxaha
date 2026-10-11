#!/bin/bash
# The load: one cluster's writer, run in the load container for the whole test.
#
#   writer.sh <cluster> <id-base> <pause-ms> [all|leader]
#
# Each transaction inserts one row into rmc_ledger and logs its outcome to
# /load/ledger-<cluster>.log. `all` (lib.sh's default) sends to the next member
# of /load/members-<cluster> in turn; `leader` sends every transaction to the
# cluster's current leader, found by asking the members and asked again after
# any failure. Log lines:
#
#   <epoch-seconds> <id> <node> <outcome> <message>
#
#   OK   the commit returned success: the cluster acknowledged the row
#   ERR  a clean SQL error: nothing may be committed
#   NOC  no connection: nothing was sent
#   UNK  unknown: the connection broke or a timeout hit mid-transaction; the row
#        may or may not exist, but every member must agree
#   NOL  no member reported itself leader: nothing was sent (id 0)
#
# Control files in /load: pause-<cluster> (the writer then touches paused-<cluster>
# between transactions), stop-<cluster>. The sequence survives a restart of the
# writer in seq-<cluster>, so an id is never reused.
c="$1"; base="$2"; ms="${3:-200}"; origin="${4:-leader}"
dir=/load
log="$dir/ledger-$c.log"
seqf="$dir/seq-$c"
seq=$(cat "$seqf" 2>/dev/null || echo 0)
pause=$(awk "BEGIN { print $ms / 1000 }")
leader=""

# the member that reports itself Leader, or empty
find_leader() {
    local x s
    leader=""
    for x in "${nodes[@]}"; do
        s=$(PGCONNECT_TIMEOUT=3 timeout 10 psql -h "$x" -U postgres -d rmc -X -q -At -c "with e as (select * from json_to_recordset(yt_info('E')) as x(name text, value text, module text)) select split_part(v.value, ', ', 2) from e v, e s where s.name = 'self' and v.name = s.value" 2>/dev/null)
        [ "$s" = Leader ] && { leader="$x"; return 0; }
    done
    return 1
}

while [ ! -e "$dir/stop-$c" ]; do
    if [ -e "$dir/pause-$c" ]; then
        touch "$dir/paused-$c"
        sleep 0.2
        continue
    fi
    rm -f "$dir/paused-$c"
    mapfile -t nodes < <(grep -v '^[[:space:]]*$' "$dir/members-$c" 2>/dev/null)
    if [ "${#nodes[@]}" -eq 0 ]; then sleep 1; continue; fi

    if [ "$origin" = leader ]; then
        # re-ask now and then: leadership can move without a failure here
        case " ${nodes[*]} " in *" $leader "*) ;; *) leader="";; esac
        [ $(( seq % 50 )) -eq 0 ] && leader=""
        if [ -z "$leader" ] && ! find_leader; then
            printf '%s 0 - NOL no member reports itself leader\n' "$(date +%s)" >> "$log"
            sleep 1
            continue
        fi
        n="$leader"
    fi
    seq=$((seq + 1))
    echo "$seq" > "$seqf"
    id=$((base + seq))
    [ "$origin" = leader ] || n="${nodes[$((seq % ${#nodes[@]}))]}"
    out=$(PGCONNECT_TIMEOUT=5 timeout 45 psql -h "$n" -U postgres -d rmc -X -q -At -v ON_ERROR_STOP=1 \
        -c "set statement_timeout = '30s'" \
        -c "begin" \
        -c "insert into rmc_ledger (id, node, v) values ($id, '$n', 'load')" \
        -c "select yt_complete(true)" \
        -c "commit" 2>&1)
    rc=$?
    msg=$(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-240)
    if [ "$rc" -eq 0 ]; then
        r=OK
    elif [ "$rc" -eq 124 ]; then
        r=UNK
    else
        # unknown first: taking a broken connection for "nothing sent" or a clean
        # error would report a row that did commit as a phantom (a node restarted
        # between yt_complete and the commit's answer: "SSL error: unexpected eof
        # while reading ... connection to server was lost")
        case "$out" in
            *"server closed the connection"*|*"terminating connection"*|*"could not receive data"*|\
            *"no connection to the server"*|*"statement timeout"*|*"canceling statement"*|*"SSL SYSCALL"*|\
            *"connection to server was lost"*|*"SSL error"*) r=UNK;;
            *"connection to server"*"failed"*|*"could not translate host name"*) r=NOC;;
            *) r=ERR;;
        esac
    fi
    printf '%s %s %s %s %s\n' "$(date +%s)" "$id" "$n" "$r" "$msg" >> "$log"
    [ "$r" = OK ] || leader=""
    sleep "$pause"
done
rm -f "$dir/paused-$c"
