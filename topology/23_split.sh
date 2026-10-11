#!/usr/bin/env bash
# [split] A real network split, and what each side does with it.
#
#   E1  4/3 - the majority keeps its leader and commits; the minority never shows
#       a leader of its own and refuses a cluster write; after the heal there is
#       one leader, the minority catches up, and every node holds the same table
#   E2  3/3 - neither side commits; never two leaders at once; after the heal,
#       exactly one leader and writes resume
#
# The claim under test is membership.md's "Why removing Off from `total` is not
# a split-brain hole": the election counts against the ROSTER (`ups > p_cnt/2`),
# so a minority can never elect. PLAN.md calls this the highest-value test in
# the plan, and until now split-brain had never been tested at all.
#
# ## How the split is made - and why not by moving nodes to a second network
#
# The first design moved the minority onto a second docker network
# (`${YX_NET}-split`) so its members would still reach each other. It cannot
# work against this ytserv, for two reasons that compound:
#
#   * ytserv resolves every roster host to an IP address ONCE and keeps the
#     address (`Host { host: IpAddr, .. }` in ytserv state/iputil.rs; the
#     listener binds the address its own name resolved to). A node moved to a
#     new network gets a new address that its peers never learn - so the
#     minority would NOT reach each other, the opposite of the point.
#   * `docker network connect` back gives the container a NEW address on
#     $YX_NET as well (an auto-assigned network refuses `--ip`). After the
#     "heal" the node listens on an address it no longer has and its peers dial
#     one it no longer owns: nothing heals until a restart, and every assertion
#     after the heal would fail for the harness rather than the product.
#
# (env.sh's partition/heal/node_down/node_up share the second problem; nothing
# uses them yet.)
#
# So the cut is made INSIDE the containers: every node on one side gets a
# blackhole route to every address on the other side (`docker exec --privileged
# ... ip route`, iproute2 is in the image for exactly this). Nothing changes
# address, both sides keep reaching their own members, `docker exec` still
# works so a cut-off node can be asked what it thinks, and the heal deletes the
# routes - exact. A blackholed destination fails a local send at once, so this
# is a hard split, not a lossy link. The cut is VERIFIED before anything is
# measured, and healed in an EXIT trap so a failed run never leaves it in place.
#
# ## min_cluster_size is lowered to a majority of the voters for this test
#
# At the fixture default (every voter: 6) a 4-voter majority can never commit -
# 89_recover measured that a cluster built the supported way tolerates no node
# failure. "The majority commits" is only a question once the quorum is a
# majority, so this test sets it the way 89_recover does (startup path:
# cfg_write + restart) and puts the row back on exit; the next script's restart
# makes it live.
#
# ## Where the forever-Spare goes
#
# n7 is never Main and is outside the COMMIT quorum, but it is in the roster the
# ELECTION counts, and while up it adds to `ups` (membership.md, "Forever-Spare").
#
#   E1: majority = the current leader + 3 voters (4 of 6), minority = 2 voters
#       + the spare. The spare goes with the MINORITY on purpose: it makes the
#       minority as strong as it can be without a voter majority - three nodes,
#       every voter seeing two live peers - so a spare wrongly counted toward an
#       election or a commit shows up here. With it on the majority side the
#       split is 5/2 and tests less. The leader is put in the majority so "keeps
#       a leader" means keeps; a leader stranded in a minority is another question.
#   E2: 3 voters + the spare against 3 voters, the spare on the incumbent
#       leader's side. That side then holds 4 of the 7 ROSTER nodes and a leader
#       already - the side most likely to commit wrongly, and exactly the one
#       that would if the spare were counted in the commit quorum.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== split: a 4/3 and a 3/3 network split =="

# ── helpers ──────────────────────────────────────────────────────────────────

VOTERS=(); SPARES=()
for _n in "${NODES[@]}"; do
	if is_spare_node "$_n"; then SPARES+=("$_n"); else VOTERS+=("$_n"); fi
done
NV=${#VOTERS[@]}
MAJ=$(( NV / 2 + 1 ))

qx() { # qx <node> <sql> [statement_timeout] -> psql's output WITH its errors
	local node="$1" sql="$2" to="${3:-60s}"
	printf '%s\n' "$sql" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=30s -c statement_timeout=$to' $node \
psql -X -tAq -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d $YX_DB 2>&1" 2>&1 || true
}
err_of() {
	printf '%s\n' "$1" | { grep -m1 -E 'ERROR:|FATAL:|PANIC:|psql: error|server closed the connection|connection to server|No such container|Error response from daemon|is not running' || true; }
}
cw() { # cw <node> <statements> [timeout] -> "" when the cluster write committed, else the error
	local o
	o="$(qx "$1" "begin; $2; select yt_complete(true); commit;" "${3:-60s}")"
	err_of "$o"
}
qt() { # env.sh's q plus a statement_timeout, so a stuck ytserv cannot hang a poll
	printf '%s\n' "$2" | rh "docker exec -i -u postgres \
-e PGOPTIONS='-c lock_timeout=20s -c statement_timeout=30s' $1 \
psql -X -tAq -d $YX_DB 2>/dev/null" 2>/dev/null || true
}
yinfo() { # yinfo <node> <letters> <name> -> one yt_info value
	local j
	j="$(qt "$1" "select yt_info('$2')")"
	printf '%s' "$j" | python3 -c "
import json,sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in rows:
    if r.get('name') == sys.argv[1]: print(r.get('value','')); break
" "$3" 2>/dev/null || true
}
in_list() { local x="$1" y; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }
lacking() { # lacking <table> <where> <want> [nodes...] -> nodes whose count differs, as node=count
	local rel="$1" where="$2" want="$3" n c out=""
	shift 3
	[ $# -gt 0 ] || set -- "${NODES[@]}"
	for n in "$@"; do
		c="$(qt "$n" "select count(*) from $rel where $where")"
		[ "$c" = "$want" ] || out+="$n=${c:-?} "
	done
	printf '%s' "${out% }"
}
wait_all() { # wait_all <secs> <table> <where> <want> [nodes...]
	local secs="$1"; shift
	local deadline=$((SECONDS + secs))
	while :; do
		[ -z "$(lacking "$@")" ] && return 0
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 3
	done
}
wait_converged() { # wait_converged <secs> <digest-sql>
	local deadline=$((SECONDS + $1)) n d first same
	while :; do
		first=""; same=1
		for n in "${NODES[@]}"; do
			d="$(qt "$n" "$2")"; d="${d:-<none>}"
			[ -n "$first" ] || first="$d"
			[ "$d" = "$first" ] || { same=0; break; }
		done
		[ "$same" = 1 ] && [ "$first" != "<none>" ] && return 0
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 3
	done
}

# Every node's address on $YX_NET, read from the node itself - the same lookup
# ytserv did at start. IP_NODE maps an address in a yt_info line back to a node.
declare -A NODE_IP=() IP_NODE=()

# lview <node> -> what that node says about the leader: self | none | <node> | ?...
lview() {
	local v ip
	v="$(yinfo "$1" O cluster)"
	case "$v" in
		"") printf '?'; return ;;
		*"Leader: None!"*) printf 'none'; return ;;
		*"Leader: Self"*|*", Leader"|*", Leader, discrepancy"*) printf 'self'; return ;;
	esac
	ip="$(printf '%s' "$v" | sed -n 's/.*Leader: [^:]*:\([0-9][0-9.]*\):[0-9][0-9]*.*/\1/p')"
	if [ -n "$ip" ] && [ -n "${IP_NODE[$ip]:-}" ]; then printf '%s' "${IP_NODE[$ip]}"
	else printf '?%s' "$v"; fi
}
# one_leader <secs> <nodes...> -> sets ONE_LEADER once exactly one of <nodes>
# leads and every other one names it; LAST_VIEWS keeps what each said
ONE_LEADER=""; LAST_VIEWS=""
one_leader() {
	local secs="$1"; shift
	local deadline=$((SECONDS + secs)) n v nself lead agree
	ONE_LEADER=""
	while :; do
		declare -A view=()
		LAST_VIEWS=""; nself=0; lead=""; agree=1
		for n in "$@"; do
			v="$(lview "$n")"; view[$n]="$v"; LAST_VIEWS+="$n:$v "
			if [ "$v" = self ]; then nself=$((nself + 1)); lead="$n"; fi
		done
		if [ "$nself" -eq 1 ]; then
			for n in "$@"; do
				[ "$n" = "$lead" ] || [ "${view[$n]}" = "$lead" ] || agree=0
			done
			if [ "$agree" = 1 ]; then ONE_LEADER="$lead"; return 0; fi
		fi
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 3
	done
}
# self_leaders -> every node that currently reports itself leader
self_leaders() {
	local n out=""
	for n in "${NODES[@]}"; do [ "$(lview "$n")" = self ] && out+="$n "; done
	printf '%s' "${out% }"
}

# reach <from> <to> -> 0 when <from> can open a TCP connection to <to>'s ytserv port
reach() {
	rh "docker exec $1 timeout 3 bash -c '</dev/tcp/${NODE_IP[$2]}/$YX_PORT'" >/dev/null 2>&1
}
blackholes() { # blackholes <node> -> how many blackhole routes it carries
	local c
	c="$(rh "docker exec $1 ip -4 route show type blackhole" 2>/dev/null | wc -l | tr -d ' ' || true)"
	printf '%s' "${c:-?}"
}
# cut_sides "<A nodes>" "<B nodes>": each side loses the other's addresses
cut_sides() {
	local a b cmd_a="" cmd_b=""
	for b in $2; do cmd_a+="ip route replace blackhole ${NODE_IP[$b]}/32; "; done
	for a in $1; do cmd_b+="ip route replace blackhole ${NODE_IP[$a]}/32; "; done
	for a in $1; do rh "docker exec --privileged $a sh -c '$cmd_a'" 2>&1 | sed 's/^/     cut: /' || true; done
	for b in $2; do rh "docker exec --privileged $b sh -c '$cmd_b'" 2>&1 | sed 's/^/     cut: /' || true; done
	echo "     cut: [$1] | [$2]"
}
# heal_routes: every blackhole to any fixture address, removed from every node
heal_routes() {
	local n cmd=""
	for n in "${NODES[@]}"; do
		[ -n "${NODE_IP[$n]:-}" ] && cmd+="ip route del blackhole ${NODE_IP[$n]}/32 2>/dev/null; "
	done
	for n in "${NODES[@]}"; do
		rh "docker exec --privileged $n sh -c '$cmd true'" >/dev/null 2>&1 || true
	done
	echo "     healed: blackhole routes removed from every node"
}
# verify_split <label> "<A>" "<B>" -> one check line; 0 when the cut is exactly as asked
verify_split() {
	local label="$1" a b why="" n want
	read -r -a a <<< "$2"; read -r -a b <<< "$3"
	reach "${b[0]}" "${a[0]}" && why+=" ${b[0]}->${a[0]} still connects;"
	reach "${a[0]}" "${b[0]}" && why+=" ${a[0]}->${b[0]} still connects;"
	if [ "${#b[@]}" -ge 2 ]; then reach "${b[0]}" "${b[1]}" || why+=" ${b[0]}->${b[1]} is cut (same side);"; fi
	if [ "${#a[@]}" -ge 2 ]; then reach "${a[0]}" "${a[1]}" || why+=" ${a[0]}->${a[1]} is cut (same side);"; fi
	for n in "${a[@]}"; do want=${#b[@]}; [ "$(blackholes "$n")" = "$want" ] || why+=" $n has $(blackholes "$n") routes, not $want;"; done
	for n in "${b[@]}"; do want=${#a[@]}; [ "$(blackholes "$n")" = "$want" ] || why+=" $n has $(blackholes "$n") routes, not $want;"; done
	if [ -z "$why" ]; then
		ok "$label the split is real: each side reaches itself and not the other"
		return 0
	fi
	bad "$label the split is NOT what was asked -$why"
	return 1
}
verify_healed() { # verify_healed <label> <a> <b>
	local n left=""
	for n in "${NODES[@]}"; do [ "$(blackholes "$n")" = "0" ] || left+=" $n"; done
	if [ -z "$left" ] && reach "$3" "$2" && reach "$2" "$3"; then
		ok "$1 the heal is complete: no route left, $3 and $2 reach each other"
	else
		bad "$1 the heal is NOT complete - routes left on:${left:- none}, or $3/$2 still cut"
	fi
}

MCS_ORIG=""
CLEANED=0
on_exit() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set +e
	heal_routes
	for n in "${NODES[@]}"; do
		if [ -n "$MCS_ORIG" ]; then cfg_write "$n" min_cluster_size C "$MCS_ORIG"
		else cfg_delete "$n" min_cluster_size C; fi
		q "$n" "drop table if exists sp_t;" >/dev/null 2>&1
		cfg_delete "$n" public.sp_t A >/dev/null 2>&1
	done
	echo "  cleanup: sp_t dropped; min_cluster_size row back to [${MCS_ORIG:-none}] (live at the next restart)"
}

# ── setup ────────────────────────────────────────────────────────────────────

if [ "$NV" -lt 4 ] || [ $(( NV % 2 )) -ne 0 ]; then
	bad "needs an even number (>= 4) of voters, so that one split has a majority and one ties - has $NV"
	summary
fi
MCS_ORIG="$(qt "${NODES[0]}" "select value from $YX_CFG where module='C' and name='min_cluster_size' limit 1")"
for n in "${NODES[@]}"; do
	q "$n" "drop table if exists sp_t; create table sp_t (id bigint primary key, v text);" >/dev/null
done
register_table public.sp_t
for n in "${NODES[@]}"; do cfg_write "$n" min_cluster_size C "$MAJ"; done
echo "  min_cluster_size -> $MAJ for this test (majority of $NV voters; was ${MCS_ORIG:-unset})"
trap on_exit EXIT
restart_all
await_cluster
wait_writable "${VOTERS[0]}" "${VOTERS[1]}" sp_t || { bad "cluster never became writable"; summary; }

# listed in yt_info('E') only when it differs from the compiled default (3)
mcs="$(yinfo "${VOTERS[0]}" E cfg.min_cluster_size)"
check "precondition: min_cluster_size is $MAJ in the live config" "$MAJ" "${mcs:-3}"

for n in "${NODES[@]}"; do
	ip="$(rh "docker exec $n getent ahostsv4 $n" 2>/dev/null | awk 'NR==1{print $1}' || true)"
	NODE_IP[$n]="$ip"
	[ -n "$ip" ] && IP_NODE[$ip]="$n"
done
unresolved=""
for n in "${NODES[@]}"; do [ -n "${NODE_IP[$n]}" ] || unresolved+=" $n"; done
[ -z "$unresolved" ] || { bad "could not read the address of:$unresolved"; summary; }
reach "${VOTERS[1]}" "${VOTERS[0]}" \
	&& ok "precondition: the reachability probe connects before any cut" \
	|| { bad "the reachability probe fails with no cut at all - nothing below could be verified"; summary; }

DIG="select md5(string_agg(id::text||':'||v, ',' order by id)) from sp_t where id > 0"

# ═════ E1 — 4/3 ══════════════════════════════════════════════════════════════
echo "  -- E1: 4/3"
one_leader 60 "${NODES[@]}" || { bad "E1 no agreed leader before the split: $LAST_VIEWS"; summary; }
L="$ONE_LEADER"
others=()
for n in "${VOTERS[@]}"; do [ "$n" = "$L" ] || others+=("$n"); done
A=( "$L" "${others[@]:0:$((MAJ - 1))}" )
BV=( "${others[@]:$((MAJ - 1))}" )
B=( "${BV[@]}" "${SPARES[@]}" )
echo "     leader $L; majority [${A[*]}]  minority [${B[*]}]"

e="$(cw "${A[1]}" "insert into sp_t values (1,'before-split')" 30s)"
wait_all 60 sp_t "id=1" 1 || true
check "E1 baseline: the pre-split row is on every node" "" "$(lacking sp_t "id=1" 1)"

cut_sides "${A[*]}" "${B[*]}"
verify_split "E1" "${A[*]}" "${B[*]}" || summary

# A minority write at once, while its nodes may still name the old leader, and
# one after the window, when they should name none. Both refused, and neither
# may survive on the node that took it.
M_IDS=(9001 9002); M_ERR=()
M_ERR+=("$(cw "${BV[0]}" "insert into sp_t values (9001,'minority-early')" 30s)")

# THE observation: sampled every 3 s for 45 s. A minority node naming the
# majority's leader for the first few seconds is detection lag, not a leader of
# its own; claiming itself, or naming a node on ITS side, is never acceptable.
claims=""
for _ in $(seq 1 15); do
	for n in "${B[@]}"; do
		v="$(lview "$n")"
		case "$v" in
			self) claims+=" $n:self" ;;
			none|"?"*) ;;
			*) in_list "$v" "${B[@]}" && claims+=" $n->$v" ;;
		esac
	done
	sleep 3
done
check "E1 no minority node ever claims or names a leader on its own side (45 s, every 3 s)" "" "${claims# }"
stale=""
for n in "${B[@]}"; do v="$(lview "$n")"; [ "$v" = none ] || stale+=" $n:$v"; done
check "E1 the minority shows no leader once the split is noticed" "" "${stale# }"

M_ERR+=("$(cw "${BV[0]}" "insert into sp_t values (9002,'minority-late')" 30s)")
for k in 0 1; do
	[ -n "${M_ERR[$k]}" ] \
		&& ok "E1 a minority write (id ${M_IDS[$k]}, from ${BV[0]}) is refused: ${M_ERR[$k]:0:120}" \
		|| bad "E1 a minority write (id ${M_IDS[$k]}, from ${BV[0]}) was ACCEPTED during the split"
done
check "E1 ...and neither refused row is on the minority node that took it" "0" \
	"$(qt "${BV[0]}" "select count(*) from sp_t where id in (9001,9002)")"

# The majority: still one leader, and it commits. The first write after a cut
# can still pick a party member that is gone, so it is retried with fresh ids.
if one_leader 30 "${A[@]}"; then
	LA="$ONE_LEADER"
	ok "E1 the majority keeps one leader ($LA), named by all of ${A[*]}"
else
	LA="$L"
	bad "E1 the majority has no agreed leader: $LAST_VIEWS"
fi
WA=""
for n in "${A[@]}"; do [ "$n" = "$LA" ] || { WA="$n"; break; }; done
SPLIT_ACK=(); tries=0; last_e=""; id=100
deadline=$((SECONDS + 90))
while [ "$SECONDS" -lt "$deadline" ]; do
	id=$((id + 1)); tries=$((tries + 1))
	last_e="$(cw "$WA" "insert into sp_t values ($id,'majority-first')" 30s)"
	if [ -z "$last_e" ]; then SPLIT_ACK+=("$id"); break; fi
	sleep 3
done
[ "${#SPLIT_ACK[@]}" -gt 0 ] \
	&& ok "E1 the majority commits a cluster write (from $WA, attempt $tries)" \
	|| bad "E1 the majority never committed in 90 s ($tries attempts): ${last_e:0:160}"
for k in 1 2 3 4 5; do
	o="${A[$(( k % ${#A[@]} ))]}"
	e="$(cw "$o" "insert into sp_t values ($((200 + k)),'majority-$o')" 30s)"
	[ -z "$e" ] && SPLIT_ACK+=("$((200 + k))")
done
echo "     committed during the split: ${#SPLIT_ACK[@]} row(s): ${SPLIT_ACK[*]:-none}"
ACK_LIST="$(IFS=,; echo "${SPLIT_ACK[*]:-0}")"
wait_all 30 sp_t "id in ($ACK_LIST)" "${#SPLIT_ACK[@]}" "${A[@]}" || true
check "E1 every majority node holds the rows committed during the split" "" \
	"$(lacking sp_t "id in ($ACK_LIST)" "${#SPLIT_ACK[@]}" "${A[@]}")"

# ── heal ────────────────────────────────────────────────────────────────────
heal_routes
verify_healed "E1" "${A[0]}" "${B[0]}"
if one_leader 120 "${NODES[@]}"; then
	LH="$ONE_LEADER"
	ok "E1 after the heal there is exactly one leader ($LH), named by every node"
else
	LH="$LA"
	bad "E1 after the heal there is no single agreed leader in 120 s: $LAST_VIEWS"
fi
if [ "${#SPLIT_ACK[@]}" -eq 0 ]; then
	# "caught up 0 of 0" would pass on an empty set - say what it is instead
	bad "E1 catch-up cannot be measured: the majority committed nothing during the split"
else
	wait_all 180 sp_t "id in ($ACK_LIST)" "${#SPLIT_ACK[@]}" "${B[@]}" || true
	for n in "${B[@]}"; do
		check "E1 $n caught up the ${#SPLIT_ACK[@]} row(s) committed while it was cut off" "" \
			"$(lacking sp_t "id in ($ACK_LIST)" "${#SPLIT_ACK[@]}" "$n")"
	done
fi
check "E1 no node holds a row the minority tried to write" "" "$(lacking sp_t "id in (9001,9002)" 0)"
wait_converged 120 "$DIG" || true
for n in "${NODES[@]}"; do
	[ "$n" = "$LH" ] && continue
	check_same "E1 $n holds the identical table to $LH" "$LH" "$n" "$DIG" "$((1 + ${#SPLIT_ACK[@]}))" sp_t
done

# ═════ E2 — 3/3 ══════════════════════════════════════════════════════════════
echo "  -- E2: 3/3 voters"
one_leader 60 "${NODES[@]}" || { bad "E2 no agreed leader before the split: $LAST_VIEWS"; summary; }
L2="$ONE_LEADER"
HALF=$(( NV / 2 ))
others=()
for n in "${VOTERS[@]}"; do [ "$n" = "$L2" ] || others+=("$n"); done
A2V=( "$L2" "${others[@]:0:$((HALF - 1))}" )
A2=( "${A2V[@]}" "${SPARES[@]}" )
B2=( "${others[@]:$((HALF - 1))}" )
echo "     leader $L2; side A [${A2[*]}]  side B [${B2[*]}]"

cut_sides "${A2[*]}" "${B2[*]}"
verify_split "E2" "${A2[*]}" "${B2[*]}" || summary

# Writes only once the cut has been NOTICED (tcp_timeout_ms is 2000 here and a
# peer is switched off after a few failed pings): a write racing the detection is
# a different question from whether either side can commit WITH the split known.
sleep 20
E2_IDS=(); E2_WHO=(); E2_ERR=()
e2_write() { # e2_write <id> <node> <side>
	E2_IDS+=("$1"); E2_WHO+=("$2 ($3)")
	E2_ERR+=("$(cw "$2" "insert into sp_t values ($1,'split-$3-$2')" 30s)")
}
[ "${#A2V[@]}" -ge 2 ] && e2_write 9101 "${A2V[1]}" "A, beside the leader"
e2_write 9102 "${B2[0]}" "B"

# Never two leaders at once - from one side, "both elected" and "neither did"
# look the same, so the whole cluster is sampled together.
dual=""
for t in $(seq 1 10); do
	sl="$(self_leaders)"
	case "$sl" in *" "*) dual+=" [t+$((t * 3))s: $sl]" ;; esac
	sleep 3
done
check "E2 never two self-declared leaders at once (30 s, every 3 s)" "" "${dual# }"

e2_write 9103 "$L2" "A, the incumbent leader"
[ "${#B2[@]}" -ge 2 ] && e2_write 9104 "${B2[1]}" "B"
for k in "${!E2_IDS[@]}"; do
	[ -n "${E2_ERR[$k]}" ] \
		&& ok "E2 a write from ${E2_WHO[$k]} is refused: ${E2_ERR[$k]:0:120}" \
		|| bad "E2 a write from ${E2_WHO[$k]} COMMITTED during a 3/3 split (id ${E2_IDS[$k]})"
done

heal_routes
verify_healed "E2" "${A2[0]}" "${B2[0]}"
if one_leader 120 "${NODES[@]}"; then
	LH2="$ONE_LEADER"
	ok "E2 after the heal there is exactly one leader ($LH2), named by every node"
else
	LH2="$L2"
	bad "E2 after the heal there is no single agreed leader in 120 s: $LAST_VIEWS"
fi

# Writes resume: retried, fresh ids, from a voter that is not the leader.
WR=""
for n in "${VOTERS[@]}"; do [ "$n" = "$LH2" ] || { WR="$n"; break; }; done
resumed=""; tries=0; last_e=""; id=300
deadline=$((SECONDS + 90))
while [ "$SECONDS" -lt "$deadline" ]; do
	id=$((id + 1)); tries=$((tries + 1))
	last_e="$(cw "$WR" "insert into sp_t values ($id,'after-heal')" 30s)"
	if [ -z "$last_e" ]; then resumed="$id"; break; fi
	sleep 3
done
if [ -n "$resumed" ]; then
	ok "E2 writes resume after the heal (from $WR, attempt $tries)"
	wait_all 60 sp_t "id=$resumed" 1 || true
	check "E2 ...and the write reaches every node" "" "$(lacking sp_t "id=$resumed" 1)"
else
	bad "E2 writes did not resume within 90 s of the heal ($tries attempts): ${last_e:0:160}"
fi
check "E2 no node holds a row written during the 3/3 split" "" \
	"$(lacking sp_t "id between 9101 and 9199" 0)"
wait_converged 120 "$DIG" || true
for n in "${NODES[@]}"; do
	[ "$n" = "$LH2" ] && continue
	check_same "E2 $n holds the identical table to $LH2 after both splits" "$LH2" "$n" "$DIG" 1 sp_t
done

on_exit
summary
