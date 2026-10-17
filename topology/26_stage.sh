#!/usr/bin/env bash
# [staged-sync] A table with data on one node only is put under sync by a `stage`
# job (yt-pgxt topology-todo.md §2.8): every member catches up from the source by
# key, the rule walks nodes>=1 -> half -> all, and the job ends done. A member that
# holds rows of its own the source does not stays different - nothing is deleted -
# and the job fails once nothing changed for its stall_sec.
#
# Written 2026-10-16 without a run (full test runs were off for a dev session) and
# put in run_a.sh as it was, as 29c/29d were: its first run is the next nightly.
#
#   S1  st_t: 200 rows on the source only, the table empty everywhere else
#   S2  a stage job (source = that node) ends done; the rule is `all` on every node
#   S3  every node holds the source's 200 rows, the same rows
#   S4  a write after the job reaches every node
#   S5  st_s: one node holds a row of its own beside the source's 50 - the job
#       (stall_sec=60) fails, naming that node, and the table keeps its stage
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== staged sync: a table with data on one node put under sync =="

JT=public.yt_job
qt() {
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}
leader_now() {
	local n v
	for n in "${NODES[@]}"; do
		v="$(info "$n" O cluster)"
		case "$v" in *", Leader"|*", Leader, discrepancy"*) printf '%s' "$n"; return 0 ;; esac
	done
}
u8() { local u; u="$(node_uuid "$1")"; printf '%s' "${u:0:2}..${u:30}"; }
# a job asked for on <node>: its id, or what the insert said
job_new() { # job_new <node> <table> <params>
	local out i
	for i in 1 2 3; do
		out="$(qt "$1" "begin; insert into $JT (kind, tabl, params) values ('stage', '$2', '$3') returning id; \
			select yt_complete(true); commit;" | head -1)"
		[[ "$out" =~ ^[0-9]+$ ]] && { printf '%s' "$out"; return 0; }
		sleep 5
	done
	printf '%s' "$out"
}
# wait up to <secs> for job <id> to read <state> on <node>; prints state and reason
job_wait() { # job_wait <secs> <node> <id> <state>
	local i v=""
	for i in $(seq 1 $(( $1 / 5 ))); do
		v="$(qt "$2" "select state || ' ' || coalesce(reason, '') from $JT where id = $3")"
		case "$v" in "$4"*) break ;; failed*|refused*|cancelled*) break ;; esac
		sleep 5
	done
	printf '%s' "$v"
}
sum_of() { qt "$1" "select count(*) || ':' || coalesce(md5(string_agg(id || '=' || v, ',' order by id)), '') from $2"; }

cleanup() {
	set +e
	local n
	for n in "${NODES[@]}"; do
		q "$n" "drop table if exists st_t, st_s;" >/dev/null 2>&1
		cfg_delete "$n" public.st_t A >/dev/null 2>&1 || true
		cfg_delete "$n" public.st_s A >/dev/null 2>&1 || true
		# the job layer back off, as the fixture had it
		q "$n" "drop trigger if exists zytsync_public_yt_job_trigger on $JT;
		        drop trigger if exists zytsynct_public_yt_job on $JT;
		        delete from $JT where kind = 'stage';" >/dev/null 2>&1
		cfg_delete "$n" "$JT" A >/dev/null 2>&1 || true
	done
}

# ── setup ────────────────────────────────────────────────────────────────────
SRC=n2
OWN=n3
trap cleanup EXIT
cleanup
for n in "${NODES[@]}"; do
	q "$n" "create table st_t (id bigint primary key, v text);
	        create table st_s (id bigint primary key, v text);" >/dev/null
done
# rows written before the tables are synced stay where they were written
q "$SRC" "insert into st_t select g, 'r' || g from generate_series(1, 200) g;
          insert into st_s select g, 's' || g from generate_series(1, 50) g;" >/dev/null
q "$OWN" "insert into st_s values (1000, 'own');" >/dev/null
register_table public.st_t ""
register_table public.st_s ""
# the job layer: yt_job synced, as topo's jobs_on does
register_table "$JT" ""
restart_all
await_cluster
L="$(leader_now)"
[ -n "$L" ] || { bad "no leader"; summary; }
echo "  leader $L, source $SRC ($(u8 $SRC)), a node of its own rows $OWN ($(u8 $OWN))"

check "S1 st_t: 200 rows on the source, none elsewhere" "200 0" \
	"$(qt "$SRC" "select count(*) from st_t") $(qt n4 "select count(*) from st_t")"

# ── S2: the stage job ────────────────────────────────────────────────────────
ID="$(job_new "$L" "$YX_DB.public.st_t" "source=$(node_uuid $SRC)")"
[[ "$ID" =~ ^[0-9]+$ ]] || { bad "S2 the stage job was not inserted: $ID"; summary; }
r="$(job_wait 420 "$L" "$ID" done)"
case "$r" in
	done*) ok "S2 the stage job is done - ${r#done }" ;;
	*) bad "S2 the stage job did not end done within 420s: [$r]" ;;
esac
all=0
for n in "${NODES[@]}"; do
	case "$(info "$n" a:public.st_t cluster_commit)" in all) all=$((all + 1)) ;; esac
done
check "S2 the rule is cluster_commit=all on every node" "${#NODES[@]}" "$all"

# ── S3: every node holds the source's rows ──────────────────────────────────
want="$(sum_of "$SRC" st_t)"
same=0
for n in "${NODES[@]}"; do [ "$(sum_of "$n" st_t)" = "$want" ] && same=$((same + 1)); done
check "S3 every node holds the source's 200 rows ($want)" "${#NODES[@]}" "$same"

# ── S4: a write after the job ───────────────────────────────────────────────
q n4 "begin; insert into st_t values (201, 'after'); select yt_complete(true); commit;" >/dev/null
got=0
for i in $(seq 1 12); do
	got=0
	for n in "${NODES[@]}"; do [ "$(qt "$n" "select count(*) from st_t where id = 201")" = 1 ] && got=$((got + 1)); done
	[ "$got" = "${#NODES[@]}" ] && break
	sleep 5
done
check "S4 a write after the job reaches every node" "${#NODES[@]}" "$got"

# ── S5: rows of a member's own - the job stalls ─────────────────────────────
ID2="$(job_new "$L" "$YX_DB.public.st_s" "source=$(node_uuid $SRC);stall_sec=60")"
[[ "$ID2" =~ ^[0-9]+$ ]] || { bad "S5 the stage job was not inserted: $ID2"; summary; }
r="$(job_wait 600 "$L" "$ID2" failed)"
case "$r" in
	failed*"no progress"*"$(u8 $OWN)"*) ok "S5 the job failed on the stall, naming $OWN - ${r#failed }" ;;
	failed*) bad "S5 the job failed, but not on the stall naming $OWN: [$r]" ;;
	*) bad "S5 the job did not fail within 600s: [$r]" ;;
esac
check "S5 the source's rows reached $OWN, its own row stayed" "51 1" \
	"$(qt "$OWN" "select count(*) from st_s") $(qt "$OWN" "select count(*) from st_s where id = 1000")"

summary
