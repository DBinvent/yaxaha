#!/usr/bin/env bash
# yt-cluster config matrix with per-stage breakdown.
# Each run starts from a KNOWN-GOOD cluster: WAL wiped (so checkin cost isn't
# skewed by WAL file size), synchronized restart, leader elected, tables resynced
# and verified converged.
set -u
K="ssh -o BatchMode=yes -i $HOME/.ssh/lab_cluster_ed25519"
# The nodes' addresses, as the cluster's N rows give them: leader() reads the
# leader's address out of yt_info('E'). node1 is the write origin (PostgreSQL
# on 5434, the workload at /tmp/s2.sql); node2 and node3 are the peers.
N1=${NODE1:?set NODE1 NODE2 NODE3 to the node addresses}
N2=${NODE2:?set NODE2 to the address of node2}
N3=${NODE3:?set NODE3 to the address of node3}
ALL="$N1 $N2 $N3"
SP="$(dirname "$0")"

psql_on() { local h=$1; shift; local P=""; [ "$h" = "$N1" ] && P="-p 5434"
  $K "$h" "sudo -u postgres psql $P -d pgbench $*"; }

digest() { psql_on "$1" -tAc "\"select md5((select string_agg(bid||':'||bbalance,',' order by bid) from pgbench_branches))||md5((select string_agg(tid||':'||tbalance,',' order by tid) from pgbench_tellers))\""; }

leader() { $K $N2 "sudo -u postgres psql -d pgbench -Atc \"select * from yt_info('E')\"" \
  | grep -oE 'Leader: [a-f0-9]{2}\.\.[a-f0-9]{6}:[0-9.]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 \
  || true; }
# node2 prints bare "Leader" when IT leads, so fall back to asking node1 about node2
leader_any() { local l; l=$(leader); if [ -z "$l" ]; then
    $K $N1 "sudo -u postgres psql -p 5434 -d pgbench -Atc \"select * from yt_info('E')\"" \
      | grep -qE '\"cluster\",\"value\":\"[^\"]*Leader\"' && echo "$N1" || echo "$N2"
  else echo "$l"; fi; }

resync() {
  $K $N1 "sudo -u postgres psql -p 5434 -d pgbench -tAc \"select 'update pgbench_branches set bbalance='||bbalance||' where bid='||bid||';' from pgbench_branches union all select 'update pgbench_tellers set tbalance='||tbalance||' where tid='||tid||';' from pgbench_tellers\"" > "$SP/rs.sql"
  for h in $N2 $N3; do
    scp -q -o BatchMode=yes -i "$HOME/.ssh/lab_cluster_ed25519" "$SP/rs.sql" "$h:/tmp/rs.sql"
    $K "$h" "sudo -u postgres psql -d pgbench -q -c 'ALTER TABLE pgbench_branches DISABLE TRIGGER z_b; ALTER TABLE pgbench_tellers DISABLE TRIGGER z_t;' -f /tmp/rs.sql -c 'ALTER TABLE pgbench_branches ENABLE TRIGGER z_b; ALTER TABLE pgbench_tellers ENABLE TRIGGER z_t;'"
  done
}

prepare() { # $1 = A-row base64
  for h in $ALL; do psql_on "$h" -qc "\"update public.yt_config set value='$1' where module='A' and name in ('public.pgbench_branches','public.pgbench_tellers')\""; done
  for h in $ALL; do $K "$h" 'sudo systemctl stop ytserver' & done; wait
  for h in $ALL; do $K "$h" 'sudo rm -rf /var/yaxaha/*' & done; wait      # equal WAL start
  for h in $ALL; do $K "$h" 'sudo systemctl start ytserver' & done; wait
  for i in $(seq 20); do sleep 5; [ -n "$(leader)" ] && break; done
  resync
  local a b c; a=$(digest $N1); b=$(digest $N2); c=$(digest $N3)
  [ "$a" = "$b" ] && [ "$b" = "$c" ] && echo "converged" || echo "NOT-CONVERGED"
}

marks() { for h in $ALL; do $K "$h" 'sudo cat /var/log/yaxaha/ytserver.log | wc -l'; done; }

run_case() { # $1 label  $2 base64  $3 txcount
  echo "############ $1"
  printf "  prepare: %s ; leader=" "$(prepare "$2")"; L=$(leader); echo "$L"
  psql_on $N1 -Atc "\"select * from yt_info('a:public.pgbench_branches')\"" | grep -oE '"(cluster_commit|wal)","value":"[a-z]+"' | sed 's/^/    /'
  read -r M1 M2 M3 < <(marks | tr '\n' ' ')
  printf "  RESULT: "
  $K $N1 "sudo -u postgres pgbench -p 5434 -h /var/run/postgresql -c 1 -j 1 -n -f /tmp/s2.sql -t $3 pgbench 2>&1 | grep -oE 'latency average = [0-9.]+ ms|tps = [0-9.]+|failed transactions: [0-9]+ ' | tr '\n' ' '"; echo
  sleep 5
  $K $N1 "sudo tail -n +$((M1+1)) /var/log/yaxaha/ytserver.log" > "$SP/c_$1_n1.log"
  $K $N2 "sudo tail -n +$((M2+1)) /var/log/yaxaha/ytserver.log" > "$SP/c_$1_n2.log"
  $K $N3 "sudo tail -n +$((M3+1)) /var/log/yaxaha/ytserver.log" > "$SP/c_$1_n3.log"
  echo "$L" > "$SP/c_$1_leader"
  local a b c; a=$(digest $N1); b=$(digest $N2); c=$(digest $N3)
  [ "$a" = "$b" ] && [ "$b" = "$c" ] && echo "  post: CONVERGED" || echo "  post: DIVERGED n1=${a:0:8} n2=${b:0:8} n3=${c:0:8}"
}


# [test3] force leadership to node1, then run
force_to_node1() {
  for i in $(seq 12); do
    L=$(leader_any)
    [ "$L" = "$N1" ] && { echo "leader=node1"; return 0; }
    psql_on $N1 -Atc "\"select * from yt_info('e:$N1')\"" >/dev/null 2>&1
    sleep 8
  done
  echo "leader=$(leader) (NOT node1)"
}
run_case3() { # label base64 tx
  echo "############ $1"
  printf "  prepare: %s ; " "$(prepare "$2")"
  printf "%s ; " "$(force_to_node1)"
  L=$(leader_any)
  psql_on $N1 -Atc "\"select * from yt_info('a:public.pgbench_branches')\"" \
    | grep -oE '"(cluster_commit|wal|sequential_consistency)","value":"[^"]*"' | tr '\n' ' '; echo
  read -r M1 M2 M3 < <(marks | tr '\n' ' ')
  printf "  RESULT: "
  $K $N1 "sudo -u postgres pgbench -p 5434 -h /var/run/postgresql -c 1 -j 1 -n -f /tmp/s2.sql -t $3 pgbench 2>&1 | grep -oE 'latency average = [0-9.]+ ms|tps = [0-9.]+|failed transactions: [0-9]+ ' | tr '\n' ' '"; echo
  sleep 6
  $K $N1 "sudo tail -n +$((M1+1)) /var/log/yaxaha/ytserver.log" > "$SP/t3_$1_n1.log"
  $K $N2 "sudo tail -n +$((M2+1)) /var/log/yaxaha/ytserver.log" > "$SP/t3_$1_n2.log"
  $K $N3 "sudo tail -n +$((M3+1)) /var/log/yaxaha/ytserver.log" > "$SP/t3_$1_n3.log"
  local a b c; a=$(digest $N1); b=$(digest $N2); c=$(digest $N3)
  [ "$a" = "$b" ] && [ "$b" = "$c" ] && echo "  post: CONVERGED" || echo "  post: DIVERGED ${a:0:8}/${b:0:8}/${c:0:8}"
}
run_case3 "$1" "$2" "${3:-300}"
