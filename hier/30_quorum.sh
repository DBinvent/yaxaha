#!/usr/bin/env bash
# [tpl2 item 3] An external link is not a member: it votes in nothing.
#
# This is the assertion the whole fixture exists for. ytserv has **no cluster-uuid
# check on the peer path** - a peer is a peer - so without the relation layer,
# linking two clusters does not link them, it MERGES them:
#
# - the far nodes would be broadcast elections and would vote in them;
# - they would count toward `min_cluster_size`, so a 3-node cluster rostering 6
#   foreign nodes would think it had 9 and refuse to commit with 3;
# - they would join the commit party, so a local write would wait on a quorum of
#   another cluster.
#
# Each LOWER cluster here rosters 7 foreign nodes (the upper cluster's 3 plus its
# sibling's 4) with `min_cluster_size = 2`. The upper cluster rosters none - it holds
# a sign-in key per child instead of an address - so it is the lower clusters that
# exercise the exclusion. If it regresses, the symptom is loud: no cluster elects, or
# writes abort with "not enough working nodes", which is the failure mode deliberately
# chosen over a silent merge.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== quorum: a linked cluster is pinged, counted in nothing =="

# Who each cluster holds addresses for - mirrors 10_up.sh's LINKED. The upper
# cluster is deliberately empty: it never dials down.
declare -A LINKED_EXPECT=(
	[upper]=""
	[east]="${CL_UPPER[*]} ${CL_WEST[*]}"
	[west]="${CL_UPPER[*]} ${CL_EAST[*]}"
)

UP="$(leader_of upper)"; EA="$(leader_of east)"; WE="$(leader_of west)"
[ -n "$UP" ] && [ -n "$EA" ] && [ -n "$WE" ] \
	&& ok "each cluster elected its own leader (upper=$UP east=$EA west=$WE)" \
	|| { bad "a cluster failed to elect, which is what a merged quorum looks like: \
upper=[$UP] east=[$EA] west=[$WE]"; summary; }

# ── 1. the roster really does contain foreign nodes ────────────────────────
#
# Without this the rest is vacuous: a cluster that rostered only its own members
# would pass every assertion below with the relation layer removed entirely.
# The expected roster size differs per cluster, and the difference IS the design:
# a cluster rosters its own members plus the nodes of any cluster it DIALS. An upper
# cluster dials none of its children - it holds a sign-in key for each instead - so
# it rosters only itself.
for c in "${CLUSTERS[@]}"; do
	n="$(echo "${CLUSTER_NODES[$c]}" | awk '{print $1}')"
	want=$(( $(echo ${CLUSTER_NODES[$c]} | wc -w) + $(echo ${LINKED_EXPECT[$c]:-} | wc -w) ))
	rn="$(q "$n" "select count(*) from $YX_CFG where module='N'")"
	check "$c rosters $want node(s): its members plus the clusters it dials" "$want" "$rn"
done

# ── 2. three leaders, not one ──────────────────────────────────────────────
#
# One leader across nine nodes is exactly what a merge looks like, and it is the
# single most important thing this file rules out.
leaders=""
for c in "${CLUSTERS[@]}"; do leaders="$leaders $(leader_of "$c")"; done
cnt="$(echo $leaders | wc -w)"
check "there are ${#CLUSTERS[@]} independent leaders, one per cluster" "${#CLUSTERS[@]}" "$cnt"

# ...and they are genuinely different nodes in different clusters
uniq_cnt="$(echo $leaders | tr ' ' '\n' | sort -u | wc -l)"
check "each leader is a distinct node" "${#CLUSTERS[@]}" "$uniq_cnt"

# ── 3. terms are independent ───────────────────────────────────────────────
#
# A shared term would mean the elections were shared. They are counted separately
# because a foreign term must not even be observed as a collision: `do_handle_ping`
# used to fold every answering peer's term into one set, and across a boundary that
# reads as "another leader on my term" on every ping.
coll=0
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in
		*ollision*|*discrepancy*) coll=$((coll+1)); echo "  $n: $(info "$n" O cluster)" ;;
	esac
done
[ "$coll" = 0 ] \
	&& ok "no node reports a term collision or leader discrepancy" \
	|| bad "$coll node(s) report a collision - a foreign cluster's term is being \
folded into this one's"

# ── 4. a local write commits on a LOCAL quorum ─────────────────────────────
#
# The measurable consequence. `min_cluster_size` is 2 and a lower cluster has 4
# members plus 7 foreign peers in its roster, so a write can only succeed if the
# foreign ones are excluded from the party.
echo "  writing to a cluster-local table in each cluster..."
for c in "${CLUSTERS[@]}"; do
	for n in ${CLUSTER_NODES[$c]}; do
		q "$n" "drop table if exists q_t; create table q_t (id bigint primary key, v text);" >/dev/null
	done
done
CFG_LOCAL="$("$REPO_ROOT"/target/release/yxctl --encode-table-cfg 'no_up; no_down' 2>/dev/null | tail -1)"
if [ -z "$CFG_LOCAL" ]; then
	# not fatal: the table is still synced with default routing, which is enough to
	# prove the party is local - it just also crosses, which section 5 covers
	echo "  (no --encode-table-cfg available; registering with default routing)"
	CFG_LOCAL=""
fi
register_table public.q_t "$CFG_LOCAL"
restart_all 30
await_clusters

for c in "${CLUSTERS[@]}"; do
	l="$(leader_of "$c")"
	[ -n "$l" ] || { bad "$c has no leader after the restart"; continue; }
	out="$(q "$l" "begin; insert into q_t values (1,'$c'); select yt_complete(true); commit;" 2>&1 || true)"
	got="$(q "$l" "select count(*) from q_t where id=1")"
	if [ "${got:-0}" = "1" ]; then
		ok "$c committed a write on its own members' quorum (leader $l)"
	else
		bad "$c could not commit on its own members - the foreign peers in its roster \
are being counted: ${out:0:160}"
	fi
done

# ── 5. and the write stayed inside its own cluster ─────────────────────────
#
# `no_up; no_down` makes q_t local to its az. Each cluster wrote a DIFFERENT value
# into id=1, so a row that crossed would be visible as the wrong value rather than
# as a missing row - a cross-check that cannot pass by both sides being empty.
for c in "${CLUSTERS[@]}"; do
	for n in ${CLUSTER_NODES[$c]}; do
		v="$(q "$n" "select v from q_t where id=1")"
		if [ -n "$v" ] && [ "$v" != "$c" ]; then
			bad "$n (cluster $c) holds [$v] - a row crossed a boundary it was pinned inside"
		fi
	done
done
ok "no cluster's local row appeared in another cluster with the wrong value"

summary
