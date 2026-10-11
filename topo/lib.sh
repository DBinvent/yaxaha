# topo: what every topo script shares. Sourced, after setting C (the cluster).
#
# On top of the rmc harness (../rmc/lib.sh and steps.sh: the layout, docker and
# psql helpers, the invariants, the writers), the job helpers and the switch that
# turns the job layer on.
. "$(dirname "${BASH_SOURCE[0]}")/../rmc/lib.sh"
. "$HERE/steps.sh"
TOPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JT=public.yt_job

# topo_log <name>: tee everything to results/<name>-<time>.log
topo_log() {
    mkdir -p "$TOPO/results"
    LOG="$TOPO/results/$1-$(date -u +%Y%m%d-%H%M%S).log"
    exec > >(tee "$LOG") 2>&1
}

# a job asked for on a node: prints its id. Tried three times: the request is a
# cluster write, and one right after a node stopped can fail while its members
# still read the node up (nightly 20261009 J4, 20261010 A2: the error was taken
# for the job's id, and every check of the job after it read nothing)
job_new() { # job_new <node> <kind> <table> <params>
    local out i
    for i in 1 2 3; do
        out=$(q "$1" -c "begin" -c "insert into $JT (kind, tabl, params) values ('$2', nullif('$3', ''), '$4') returning id" \
            -c "select yt_complete(true)" -c "commit" 2>&1 | head -1)
        [[ "$out" =~ ^[0-9]+$ ]] && { echo "$out"; return 0; }
        say "   ....  job_new $2 on $1, try $i: ${out:-no output}" >&2
        sleep 5
    done
    echo "$out"
}
job_get() { # job_get <node> <id> <column>
    QT=20 q "$1" -c "select $3 from $JT where id = $2" 2>/dev/null
}
job_is() { [ "$(job_get "$1" "$2" state)" = "$3" ]; }
job_cancel() { cwrite "$1" "update $JT set state = 'cancel' where id = $2"; }
# job_wait <secs> <node> <id> <state> <label>: ok or bad, with the job's reason as
# it reads once the wait is over
job_wait() {
    local r
    if wait_for "$1" job_is "$2" "$3" "$4"; then
        r=$(job_get "$2" "$3" reason)
        ok "$5${r:+ - $r}"
    else bad "$5 (within $1s): [$(job_get "$2" "$3" "state||' '||reason")]"; fi
}
follower() { local n l; l=$(leader_of "$1"); for n in $(members "$1"); do [ "$n" = "$l" ] || { echo "$n"; return; }; done; }

# jobs_on <cluster>: sync yt_job - its A row once, the trigger on every member -
# and wait until the leader says the layer is on
jobs_on() {
    local c="$1" n has
    has=$(QT=20 q "$(leader_of "$c")" -c "select count(*) from $CFG where module = 'A' and name = '$JT'" 2>/dev/null)
    if [ "${has:-0}" = 0 ]; then
        cfg_tx "$c" "insert into $CFG (name, module, value) values ('$JT', 'A', '')" || bad "the A row for $JT"
    fi
    for n in $(members "$c"); do
        q "$n" -c "drop trigger if exists zytsync_yt_job_trigger on $JT" \
            -c "create trigger zytsync_yt_job_trigger after insert or update or delete on $JT for each row execute procedure public.yt_synchronize()" \
            >/dev/null 2>&1 || bad "the $JT trigger on $n"
    done
    # on when a job goes round: asked, decided by the leader, done (the leader
    # reads the trigger at most 30s late)
    local id
    id=$(job_new "$(follower "$c")" noop "" "")
    job_wait 90 "$(follower "$c")" "$id" done "the job layer is on in $c (leader $(leader_of "$c"))"
}
