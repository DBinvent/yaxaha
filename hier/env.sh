#!/usr/bin/env bash
# [tpl2] Shared config for the HIERARCHICAL fixture: three clusters, one network.
# Source, do not execute.
#
# The single-cluster fixture in ../topology cannot express any of this, and the
# reason is not size - it is that a cross-cluster link needs two distinct CLUSTER
# UUIDS. Within one cluster uuid every peer is a member, so "an external link is
# excluded from quorum" is not a testable statement: there is nothing external.
#
#   cluster A  az top    tier 0    u1 u2 u3
#   cluster B  az eastc  tier 1    a1 a2 a3 a4
#   cluster C  az westc  tier 1    b1 b2 b3 b4
#
#   UPPER     leader(B|C) -> a REGULAR node of A   (never A's leader)
#   LOWER     A holds only a sign-in key for B and C, and never dials them
#   NEIGHBOR  leader(B) <-> leader(C)
#
# Three clusters rather than two because two cannot tell the interesting cases
# apart: a single lower cluster makes "fan out to the children" and "talk to the
# one child" the same test, and NEIGHBOR needs two same-tier clusters to exist at
# all.
#
# ## Why the roster contains foreign nodes
#
# A link is a peer entry - ytserv has no separate notion of a foreign node, which
# is exactly why `is_external_link` had to be written. So each cluster's `N` rows
# list its own three members AND the nodes it links to, and the module-`Z`
# relation rows are what stop those extra entries from being treated as members.
# `min_cluster_size` is therefore 3 (the members), not 6 - if the relation layer
# regresses, the symptom is a cluster that cannot elect, which is a loud failure
# rather than a silent merge.
set -euo pipefail

# Reuse the helpers (rh, q, info, cfg_write, register_table, restart_all,
# await_cluster, check/ok/bad/summary) rather than forking 280 lines of them, then
# override the topology. YX_NO_SWEEP skips its trailing clear_prepared, which
# would otherwise sweep n1..n6 on a network where they do not exist.
YX_NO_SWEEP=1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../topology" && pwd)/env.sh"
unset YX_NO_SWEEP

# NOT `${YX_NET:-yxhier}`: ../topology/env.sh has already run and set YX_NET,
# YX_DB and YX_IMAGE to its own defaults, so `:-` sees a non-empty value and keeps
# ITS value. Every override here silently did nothing, and the symptom was this
# fixture talking to the single-cluster database on the single-cluster network -
# which looks exactly like a cluster that will not start. Separate names for the
# overrides, so sourcing order cannot swallow them.
YX_NET="${YX_HIER_NET:-yxhier}"
YX_DB="${YX_HIER_DB:-yxhier}"
# Its OWN image, not ../topology's: the two fixtures are built from different
# branches in different worktrees, and rebuilding one image from the other's tree
# silently swaps the binary under a suite that is not being worked on.
YX_IMAGE="${YX_HIER_IMAGE:-yxhier-node}"
# [skv] node <n>'s app key: its own (skv-secrets.md H7). A hierarchy runs on the
# secret store (H2), and the store needs every node's app key: the fixture always
# has them - YX_HIER_SECRET picks the prefix. ../topology/skv_lib.sh asks it for
# every yxctl call it makes on a node.
YX_HIER_SECRET="${YX_HIER_SECRET:-yaxaha-hier-fixture}"
secret_of() { printf '%s' "${YX_HIER_SECRET:+$YX_HIER_SECRET-$1}"; }
# [skv] and from 15_store.sh on every cluster stays on the store and TLS: a restart
# (restart_all) wipes the cluster WAL but keeps each node's key - wiped, the node
# came back a stranger, with no certificate, and the upper never elected again
YX_KEEP_NODE_KEYS=1
# [skv] point ../topology/skv_lib.sh's helpers at one cluster: its nodes, its leader
in_cluster() {
	read -r -a NODES <<< "${CLUSTER_NODES[$1]}"
	L="$(leader_of "$1")"
}
x_like() { q "$1" "select count(*) from $YX_CFG where module='X' and name like '$2'"; }
required_line() { info "$1" X peer_tls; }
# the lines of a node's log since $2 that say its CA is what admits it (H4)
ca_refusals() { rh "docker logs --since $2 $1 2>&1 | grep -ac 'admitted by its CA'" 2>/dev/null || echo 0; }

# ── the three clusters ─────────────────────────────────────────────────────
# Four nodes in each LOWER cluster, three in the upper.
#
# Sized when the election threshold was `ups > p_cnt / 2` over the peers, leaving
# out self: a cluster of three could not elect after losing a node, and
# 70_failover (stop the lower leader, watch the link follow) had nothing to
# observe. Since ytserv 0.20.61 a strict majority of the roster with self counted
# elects (2 of 3); four stays, so a lower cluster survives a loss with room left.
# See tpl2.md and membership.md.
CL_UPPER=(u1 u2 u3)
CL_EAST=(a1 a2 a3 a4)
CL_WEST=(b1 b2 b3 b4)
NODES=("${CL_UPPER[@]}" "${CL_EAST[@]}" "${CL_WEST[@]}")
CLUSTERS=(upper east west)

declare -A CLUSTER_NODES=(
	[upper]="${CL_UPPER[*]}"
	[east]="${CL_EAST[*]}"
	[west]="${CL_WEST[*]}"
)

# One az per cluster here. That is a simplification the rules permit (a relation is
# between azs, and one az per cluster is the smallest thing that has a boundary),
# and it keeps every assertion about a boundary unambiguous.
declare -A NODE_AZ=(
	[u1]=top   [u2]=top   [u3]=top
	[a1]=eastc [a2]=eastc [a3]=eastc [a4]=eastc
	[b1]=westc [b2]=westc [b3]=westc [b4]=westc
)
declare -A NODE_CLUSTER=(
	[u1]=upper [u2]=upper [u3]=upper
	[a1]=east  [a2]=east  [a3]=east  [a4]=east
	[b1]=west  [b2]=west  [b3]=west  [b4]=west
)
declare -A AZ_TIER=( [top]=0 [eastc]=1 [westc]=1 )

# Distinct cluster uuids - the whole point of the fixture. Fixed rather than
# generated so a failure is reproducible and a log line is greppable.
declare -A CLUSTER_UUID=(
	[upper]=aaaaaaaa-aaaa-5aaa-8aaa-aaaaaaaaaaaa
	[east]=bbbbbbbb-bbbb-5bbb-8bbb-bbbbbbbbbbbb
	[west]=cccccccc-cccc-5ccc-8ccc-cccccccccccc
)

# ── the other-cluster catalogue, per cluster ───────────────────────────────
#
# Each cluster's own `yt_config` lists the OTHER clusters from its point of view,
# and what it holds about each depends on which way the connection goes:
#
#   a cluster we DIAL      (UPPER, NEIGHBOR)  ->  addresses
#   a cluster that DIALS us (LOWER)            ->  a public key, and NO address
#
# The asymmetry is a security property, not a saving. The upper cluster cannot
# reach down into a subordinate even if it wanted to, and adding a child costs the
# parent one key instead of a roster that goes stale whenever the child's
# membership changes.
#
#   upper:  eastc.level=LOWER    + eastc.pub      (no addresses for its children)
#           westc.level=LOWER    + westc.pub
#   east:   top.level=UPPER      + top.host       (dials up, avoiding top's leader)
#           westc.level=NEIGHBOR + westc.host     (leader to leader)
#   west:   top.level=UPPER      + top.host
#           eastc.level=NEIGHBOR + eastc.host
#
# Note `westc` naming two others with no special handling: every row is implicitly
# "as seen from here", so two rows about two different clusters cannot collide.
#
# The keys are placeholders. There is no signing machinery in the tree yet (see
# tpl2.md), so what is testable today is that the key is HELD and that a LOWER
# cluster carries no address - not that a signature is verified.
declare -A OTHERS=(
	[upper]="eastc:LOWER:: westc:LOWER::"
	[east]="top:UPPER:${CL_UPPER[*]}: westc:NEIGHBOR:${CL_WEST[*]}:"
	[west]="top:UPPER:${CL_UPPER[*]}: eastc:NEIGHBOR:${CL_EAST[*]}:"
)
# placeholder sign-in keys, one per cluster that is somebody's child
declare -A AZ_PUBKEY=(
	[eastc]="eastc-signin-key-placeholder"
	[westc]="westc-signin-key-placeholder"
)

# nodes of one cluster, as an array
members_of() { # members_of <cluster>
	echo "${CLUSTER_NODES[$1]}"
}

# which node currently leads a cluster, by asking its own members. Empty if none.
#
# Asks every member and takes the one that reports itself Leader, rather than
# reading somebody's "Leader: <uuid>" pointer - a pointer can name a node that has
# already stepped down, and the failover test turns on telling those apart.
leader_of() { # leader_of <cluster>
	local c="$1" n
	for n in ${CLUSTER_NODES[$c]}; do
		case "$(info "$n" O cluster 2>/dev/null)" in
			*Leader) echo "$n"; return 0;;
		esac
	done
	return 0
}

# wait until each of the three clusters has elected, not until "some node
# somewhere reports a leader" - with three clusters that would pass while two of
# them were still cold.
await_clusters() { # await_clusters [tries]
	local tries="${1:-24}" i c l settled
	for i in $(seq 1 "$tries"); do
		settled=0
		for c in "${CLUSTERS[@]}"; do
			l="$(leader_of "$c")"
			[ -n "$l" ] && settled=$((settled + 1))
		done
		[ "$settled" -eq "${#CLUSTERS[@]}" ] && return 0
		sleep 5
	done
	echo "  WARN: only $settled of ${#CLUSTERS[@]} clusters elected" >&2
	return 0
}

# the az-level view, for assertions that talk about relations
az_of_node() { echo "${NODE_AZ[$1]}"; }
cluster_of_node() { echo "${NODE_CLUSTER[$1]}"; }

# Sweep orphans now that NODES is the hierarchical list (see YX_NO_SWEEP above),
# with one difference from ../topology's version: it tolerates a container that
# does not exist yet.
#
# The inherited one does not. `gids="$(q ...)"` under `set -e` takes the exit status
# of the command substitution, and `docker exec` on a missing container is non-zero
# - so sourcing this file before 10_up.sh has created anything killed the script
# instantly and printed NOTHING, which is a remarkably unhelpful way for a build
# script to fail.
clear_prepared() {
	local n gids g
	for n in "${NODES[@]}"; do
		gids="$(q "$n" "select gid from pg_prepared_xacts" 2>/dev/null || true)"
		for g in $gids; do
			q "$n" "rollback prepared '$g'" >/dev/null 2>&1 || true
			echo "  reset: rolled back orphaned prepared xact $g on $n"
		done
	done
}
clear_prepared
