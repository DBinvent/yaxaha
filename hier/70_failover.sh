#!/usr/bin/env bash
# [tpl2 item 4] A leader change on the far side is a switch, not a rediscovery.
#
# The link is leader-terminated (rule 1), so the obvious failure mode is that
# electing a new leader below severs every link from above. topology.md's answer is
# to hold the link to the node that will take over *before* it does:
#
#   "The optional Backup / Reserve target is what stops a leader election from
#    severing the link: the peer already holds a connection to the node that will
#    take over, so failover is a switch rather than a rediscovery."
#
# Three things had to exist for that, and none of them did:
#
# - a leader had to DESIGNATE deputies. `CompleteEventRequest.back` / `.rsvr` were
#   on the wire and the receive side set `sm.back` / `sm.rsrv` from them, but the
#   send side passed `None` with a `// wish set backup & reserve` comment - so
#   `sm.back` was NoHost on every node of every cluster and the whole mechanism was
#   inert;
# - a CROSS-CLUSTER peer had to learn them. Config replicates inside a cluster, not
#   across a boundary, so they are now reported on every ping response;
# - `link_allowed` had to admit a deputy as a dial target alongside the leader,
#   otherwise holding the link would violate rule 1.
#
# This kills the lower leader and asserts the link survives.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== failover: the link follows a leader change on the far side =="

UP="$(leader_of upper)"; EA="$(leader_of east)"
[ -n "$UP" ] && [ -n "$EA" ] \
	&& ok "upper and east are led (upper=$UP east=$EA)" \
	|| { bad "need both: upper=[$UP] east=[$EA]"; summary; }

# ── 1. deputies are designated at all ──────────────────────────────────────
#
# Asserted first and separately, because if nothing designates them every later
# assertion in this file would fail for that one reason and the log would blame the
# failover.
# Read the STATE (`yt_info('E') -> deputies`), not a log line. The designation is
# reported at `info!`, and every fixture here runs at log_level=warning where an
# `info!` is invisible - so grepping for it asserts on nothing and fails on a build
# where the feature works. PLAN.md records this trap; this file walked into it.
dep_seen=0
for n in "${NODES[@]}"; do
	d="$(info "$n" E deputies)"
	case "$d" in *back=*) dep_seen=$((dep_seen+1));; esac
done
[ "$dep_seen" -gt 0 ] \
	&& ok "$dep_seen node(s) hold a designated backup" \
	|| bad "no node reports a backup - CompleteEventRequest.back is still unset, so \
there is nothing for a link to fail over TO"
echo "  $EA deputies: $(info "$EA" E deputies)"

# ── 2. the upper cluster learned the lower cluster's deputies ──────────────
#
# Via the lower LEADER's ping request. Not the response: a LOWER cluster is never
# dialled (it signs in and pings up), so an upper node never receives a ping
# response from below - only the requests of the lower leader, at the one regular
# upper node that admitted its sign-in.
learned=0
for n in ${CLUSTER_NODES[upper]}; do
	case "$(info "$n" E deputies)" in *link=*) learned=$((learned+1));; esac
done
[ "$learned" -gt 0 ] \
	&& ok "$learned upper node(s) learned a linked cluster's deputy by ping" \
	|| bad "no upper node learned a deputy of a cluster it links to - the link can \
only be rediscovered after an election, which is what item 4 exists to avoid"

# ── 3. a cross-boundary write works BEFORE the failover ────────────────────
#
# The baseline. Without it, "it still works afterwards" could mean it never worked.
enc() { "$REPO_ROOT"/target/release/yxctl --encode-table-cfg "$1" 2>/dev/null | tail -1; }
CFG="$(enc 'az=top,eastc; write=top')"
for n in ${CLUSTER_NODES[upper]} ${CLUSTER_NODES[east]}; do
	q "$n" "drop table if exists f_t; create table f_t (id bigint primary key, v text);" >/dev/null
done
register_table public.f_t "$CFG"
restart_all 30
await_clusters
UP="$(leader_of upper)"; EA="$(leader_of east)"
[ -n "$UP" ] && [ -n "$EA" ] || { bad "clusters did not settle after the restart"; summary; }

q "$UP" "begin; insert into f_t values (1,'before'); select yt_complete(true); commit;" >/dev/null 2>&1 || true
before=0
for _ in $(seq 1 12); do
	[ "$(q "$EA" "select v from f_t where id=1")" = "before" ] && before=1 && break
	sleep 5
done
[ "$before" = 1 ] \
	&& ok "a cross-boundary write reaches the lower cluster before the failover" \
	|| { bad "the baseline write did not cross, so nothing below can be attributed \
to the failover"; summary; }

# What the upper cluster holds about east's deputies, read BEFORE the kill: after
# it, the new leader's own pings may already have updated the list, and "it was a
# deputy" has to mean it was one before it was needed. All upper members, because
# east dials a REGULAR upper node, never necessarily the upper leader.
links_before=""
for n in ${CLUSTER_NODES[upper]}; do
	links_before="$links_before $(info "$n" E deputies)"
done
echo "  upper's link deputies before the failover:${links_before}"
# ...and east's own designation, to tell "the upper side never held it" apart from
# "the election picked a node that was no deputy" in step 4
ea_deps="$(info "$EA" E deputies)"
echo "  $EA's own deputies before the failover: ${ea_deps:-<none>}"

# ── 4. kill the lower leader ───────────────────────────────────────────────
echo "  stopping the east leader ($EA)..."
rh "docker stop $EA >/dev/null" 2>/dev/null || true

NEW=""
for _ in $(seq 1 24); do
	for n in ${CLUSTER_NODES[east]}; do
		[ "$n" = "$EA" ] && continue
		case "$(info "$n" O cluster 2>/dev/null)" in *Leader) NEW="$n"; break;; esac
	done
	[ -n "$NEW" ] && break
	sleep 5
done
[ -n "$NEW" ] \
	&& ok "east elected a new leader without its old one ($EA -> $NEW)" \
	|| { bad "east did not re-elect after losing $EA. The cluster is sized so a \
majority survives (see env.sh), so this is a QUORUM/ELECTION problem and not a link \
problem - a cluster that loses its leader is not re-electing on the members that \
remain. Everything below measures the link and cannot run without it."; summary; }

# The new leader should be the node that was already designated Backup, which is
# what makes this a switch: the upper cluster's link to it already existed.
# yt_info prints a uuid as `as_uuid8`: its first 2 and last 6 hex digits, joined by
# `..` - matched whole, not by the first 2 digits alone (1 in 256 matches anything).
new8="$(node_uuid "$NEW" | sed -E 's/^(..).*(......)$/\1..\2/')"
case " $ea_deps " in
	*" back=$new8 "*|*" rsvr=$new8 "*) nd=1 ;;
	*) nd=0 ;;
esac
case "$links_before" in
	*"link=$new8"*) ok "the new leader $NEW ($new8) is one the upper cluster already \
held a link to: the failover was a switch" ;;
	*) if [ "$nd" = 1 ]; then
		bad "the new leader $NEW ($new8) was east's designated deputy [$ea_deps], but the \
upper cluster did not hold it before the failover [${links_before# }] - the lower \
leader's deputies never reached the cluster above"
	else
		bad "the new leader $NEW ($new8) was not one of east's designated deputies \
[$ea_deps]: the election does not prefer the Backup, so the upper cluster could not have \
held it [${links_before# }] - item 4's switch needs the Backup to take over"
	fi ;;
esac

# ── 5. the link survived: a cross-boundary write still lands ───────────────
echo "  writing across the boundary again..."
q "$UP" "begin; insert into f_t values (2,'after'); select yt_complete(true); commit;" >/dev/null 2>&1 || true
after=0
for _ in $(seq 1 24); do
	[ "$(q "$NEW" "select v from f_t where id=2")" = "after" ] && after=1 && break
	sleep 5
done
[ "$after" = 1 ] \
	&& ok "cross-scope applies resume to the NEW lower leader" \
	|| bad "the write did not reach $NEW after the failover - the link was severed by \
the election, which is the failure item 4 was written to prevent"

# ...and the upper cluster's own leadership was untouched by all of this. A lower
# cluster's election must not disturb the cluster above it; if it does, the
# boundary is not a boundary.
check "the upper cluster kept its own leader throughout" "$UP" "$(leader_of upper)"

# ── 6. and the old leader rejoins as a member, not as a second leader ──────
echo "  restarting $EA..."
rh "docker start $EA >/dev/null" 2>/dev/null || true
sleep 30
back="$(info "$EA" O cluster 2>/dev/null)"
echo "  $EA: ${back:-<no answer>}"
case "$back" in
	*Leader) bad "$EA came back as a leader while $NEW leads - two leaders in one \
cluster: [$back]" ;;
	"") bad "$EA did not answer after restart: [${back:-<none>}]" ;;
	*) ok "$EA rejoined east as a follower of $NEW" ;;
esac
leaders_now=0
for n in ${CLUSTER_NODES[east]}; do
	case "$(info "$n" O cluster 2>/dev/null)" in *Leader) leaders_now=$((leaders_now+1));; esac
done
check "east has exactly one leader after the old one returned" "1" "$leaders_now"

summary
