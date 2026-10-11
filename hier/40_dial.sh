#!/usr/bin/env bash
# [tpl2 item 3] Enforcement on dial: rules 1 and 2, refused rather than documented.
#
#   1. Downward is leader-terminated. An upper node links to a lower cluster's
#      LEADER (or a designated deputy), never an arbitrary member.
#   2. Sideways is leader-to-leader only. A member never dials sideways.
#
# Why this matters in numbers rather than in principle: two clusters of 50 linked
# "somehow" is 2500 potential connections. Linked by these rules it is a handful,
# and that difference is the entire reason a hierarchy costs less than a flat mesh.
#
# ## What is observable
#
# A refusal is a *non-event* - no connection - so it cannot be asserted by looking
# for something that happened. Three things are checked instead:
#
# - `yt_info('E') -> az_external` marks a relation `(refused)` when `link_allowed`
#   says no, which is the decision itself rather than a proxy for it;
# - the refusal is LOGGED, at warn, with the rule number - because a boundary that
#   silently has no connectivity is this module's worst failure mode;
# - and the clusters keep working while it is in force, which is what "refused, not
#   broken" has to mean.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== dial: leader-terminated downward, leader-to-leader sideways =="

UP="$(leader_of upper)"; EA="$(leader_of east)"; WE="$(leader_of west)"
[ -n "$UP" ] && [ -n "$EA" ] && [ -n "$WE" ] \
	&& ok "three leaders (upper=$UP east=$EA west=$WE)" \
	|| { bad "need a leader per cluster: upper=[$UP] east=[$EA] west=[$WE]"; summary; }

# a non-leader member of each lower cluster, for the rule-1/rule-2 refusals
ea_member=""; for n in ${CLUSTER_NODES[east]}; do [ "$n" != "$EA" ] && ea_member="$n" && break; done
we_member=""; for n in ${CLUSTER_NODES[west]}; do [ "$n" != "$WE" ] && we_member="$n" && break; done
up_member=""; for n in ${CLUSTER_NODES[upper]}; do [ "$n" != "$UP" ] && up_member="$n" && break; done
echo "  non-leader members: east=$ea_member west=$we_member upper=$up_member"

# ── downward: a LOWER cluster is never dialled ─────────────────────────────
#
# It signs in to us. We hold a key for it, not an address - so there is nothing to
# dial, and the rule refuses explicitly rather than relying on the address being
# absent, so that a stray address in the catalogue cannot quietly become a downward
# mesh.
#
# The upper cluster therefore has NO permitted external link at all, and that is the
# assertion: its whole outbound surface across a boundary is empty.
for n in ${CLUSTER_NODES[upper]}; do
	ext="$(info "$n" E az_external)"
	allowed="$(printf '%s\n' "$ext" | tr ' ' '\n' | grep -cE '=(LOWER|UPPER|NEIGHBOR)$' || true)"
	echo "  $n: permitted external links=$allowed  [${ext:-<none>}]"
	[ "${allowed:-0}" = "0" ] \
		&& ok "$n holds no permitted downward link (a LOWER cluster is never dialled)" \
		|| bad "$n holds ${allowed:-0} permitted external link(s) - an upper cluster \
must not be able to reach into a subordinate: [$ext]"
done

# ── upward: only our leader, and never at THEIR leader ─────────────────────
#
# The upper leader is the busiest node in the cluster above, and a hierarchy exists
# to keep load off it - so a permitted upward link must point at a REGULAR node.
# Polled, because `link_allowed` is deliberately permissive until it has identified
# who leads over there: refusing the unknown case would refuse the very ping that
# resolves it.
up_leader_u8="$(node_uuid "$UP" | cut -c1-2)"
ea_ok=0; ea_hits_leader=0
for _ in $(seq 1 24); do
	ext_l="$(info "$EA" E az_external)"
	ea_ok="$(printf '%s\n' "$ext_l" | tr ' ' '\n' | grep -c '=UPPER$' || true)"
	# is the upper LEADER among the permitted targets?
	ea_hits_leader="$(printf '%s\n' "$ext_l" | tr ' ' '\n' \
		| grep -c "^${up_leader_u8}.*=UPPER$" || true)"
	# settled once some upward link is permitted and the leader is not one of them
	[ "${ea_ok:-0}" -ge 1 ] && [ "${ea_hits_leader:-0}" = "0" ] && break
	sleep 5
done
echo "  $EA (leader): UPPER permitted=$ea_ok, of which the upper leader=$ea_hits_leader"
[ "${ea_ok:-0}" -ge 1 ] \
	&& ok "the lower cluster's LEADER may dial upward ($ea_ok regular target(s))" \
	|| bad "the east leader has no permitted upward link, so nothing can carry a \
cross-scope apply up: [$ext_l]"
check "...and none of them is the upper cluster's leader" "0" "${ea_hits_leader:-0}"

# a MEMBER of the lower cluster must hold no upward link at all
if [ -n "$ea_member" ]; then
	ext_m="$(info "$ea_member" E az_external)"
	m_up="$(printf '%s\n' "$ext_m" | tr ' ' '\n' | grep -c '=UPPER$' || true)"
	check "a lower-cluster MEMBER holds no permitted upward link" "0" "${m_up:-0}"
fi

# ── sideways: leader to leader, plus the far leader's deputies ─────────────
#
# Rule 2 is leader-to-leader, and tpl2 item 4 (Open 2, closed as "both, eagerly")
# admits the far leader's Backup and Reserve beside it, so that a leader change
# over there is a switch. The east leader's permitted sideways set is therefore
# the west LEADER plus at most its two deputies - never another regular member.
# "Exactly one" predates item 4: a correct build reports 3 (leader + back +
# rsvr), which is the bound rmc/steps.sh I7 asserts too.
we_u8="$(node_uuid "$WE" | tr -d '-' | sed -E 's/^(..).*(......)$/\1..\2/')"
nb_list=""; nb_allowed=0; far_hit=0
for _ in $(seq 1 24); do
	ext_l="$(info "$EA" E az_external)"
	nb_list="$(printf '%s\n' "$ext_l" | tr ' ' '\n' | grep '=NEIGHBOR$' | sed 's/=NEIGHBOR$//' || true)"
	nb_allowed="$(printf '%s\n' "$nb_list" | grep -c . || true)"
	far_hit="$(printf '%s\n' "$nb_list" | grep -cxF "$we_u8" || true)"
	[ "${far_hit:-0}" = "1" ] && [ "${nb_allowed:-0}" -le 3 ] && break
	sleep 5
done
check "the east leader may dial the west leader ($WE) sideways" "1" "${far_hit:-0}"
# every other permitted sideways target must be a deputy the west leader named
deps="$(info "$EA" E deputies)"
stray=""
for t in $nb_list; do
	[ "$t" = "$we_u8" ] && continue
	case " $deps " in *" link=$t "*) ;; *) stray="$stray $t";; esac
done
[ "${nb_allowed:-0}" -le 3 ] && [ -z "$stray" ] \
	&& ok "...and besides it only the west leader's deputies ($nb_allowed sideways target(s))" \
	|| bad "the east leader may dial $nb_allowed sideways target(s); [${stray# }] are \
neither the west leader nor a deputy it named [$deps]: [$ext_l]"
if [ -n "$ea_member" ]; then
	m_nb="$(printf '%s\n' "$(info "$ea_member" E az_external)" | tr ' ' '\n' | grep -c '=NEIGHBOR$' || true)"
	check "a member holds no permitted sideways link" "0" "${m_nb:-0}"
fi

# ── the refusal is logged, with its rule ──────────────────────────────────
#
# At warn, because the fixture runs at log_level=warning and a diagnosis nobody can
# see is not one. Rate-limited to once per ping_err_cnt_off rounds, so this looks
# for any occurrence rather than a count.
found=0
for n in "${NODES[@]}"; do
	if [ -n "$(rh "docker logs $n 2>&1 | grep -a 'tpl2.*not dialling' | tail -1" 2>/dev/null || true)" ]; then
		found=$((found+1))
	fi
done
[ "$found" -gt 0 ] \
	&& ok "the refusal is logged with its rule on $found node(s)" \
	|| bad "no node logged a refused link - the rule is enforced silently, and a \
boundary with no connectivity then looks like a network fault"
rh "docker logs $EA 2>&1 | grep -a 'tpl2.*not dialling' | tail -2" 2>/dev/null || true

# ── and the clusters still work ────────────────────────────────────────────
#
# "Refused" has to mean the link is not opened, not that the cluster is broken.
still=0
for c in "${CLUSTERS[@]}"; do [ -n "$(leader_of "$c")" ] && still=$((still+1)); done
check "all ${#CLUSTERS[@]} clusters are still led while the refusals are in force" \
	"${#CLUSTERS[@]}" "$still"

summary
