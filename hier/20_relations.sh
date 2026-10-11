#!/usr/bin/env bash
# [tpl2 items 1-2] The relation layer: configured, loaded, derived, surfaced.
#
# Four things, and they fail differently:
#
# 1. the `<az>.link.<other_az>` rows are PARSED (a level that does not parse is a
#    rule that is not in force, and this module's failure mode is silent inertness);
# 2. they are loaded on BOTH arrival paths - the startup loader and a runtime config
#    change. `.tier` used to be parsed in two places and that is this tree's
#    recurring bug, so the two paths now share `AzMap::apply_z_row` and this test
#    exercises the runtime one by writing a row into a running cluster;
# 3. the MIRROR is derived: one row per edge, and the far side reads the opposite
#    relation without a second row that could disagree;
# 4. an operator can see all of it (`yt_info('E')` -> az_link / az_external).
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== relations: declared once per edge, derived on the other side =="

UP="$(leader_of upper)"; EA="$(leader_of east)"; WE="$(leader_of west)"
[ -n "$UP" ] && [ -n "$EA" ] && [ -n "$WE" ] \
	&& ok "all three clusters elected (upper=$UP east=$EA west=$WE)" \
	|| { bad "not every cluster has a leader: upper=[$UP] east=[$EA] west=[$WE]"; summary; }

# ── 1. the clusters really are distinct ────────────────────────────────────
#
# If they were not, everything below would pass for the wrong reason: every peer
# would be a member and "external" would describe nobody.
for c in "${CLUSTERS[@]}"; do
	n="$(echo "${CLUSTER_NODES[$c]}" | awk '{print $1}')"
	got="$(q "$n" "select value from $YX_CFG where module='C' and name='cluster'")"
	check "$c carries its own cluster uuid" "${CLUSTER_UUID[$c]}" "$got"
done

# ── 2. the catalogue is loaded, and it is ASYMMETRIC ───────────────────────
#
# Read from the live server (`yt_info`), not the config table: a row present and not
# loaded is exactly the failure this checks for, and the table cannot tell the
# difference.
#
# The asymmetry is the assertion that matters, because it is a security property
# rather than a saving: a cluster we DIAL is held as addresses, a cluster that DIALS
# US is held as a key and no address at all. An upper cluster therefore cannot reach
# down into a subordinate even if it wanted to.
up_link="$(info "$UP" E az_link)"
ea_link="$(info a1 E az_link)"
echo "  $UP az_link: ${up_link:-<none>}"
echo "  a1 az_link: ${ea_link:-<none>}"

for want in "eastc=LOWER" "westc=LOWER"; do
	case "$up_link" in
		*"$want"*) ok "the upper cluster knows $want" ;;
		*) bad "the upper cluster does not list $want: [${up_link:-<none>}]" ;;
	esac
done
# and it holds a KEY for each child, with no address
case "$up_link" in
	*"eastc=LOWER+key"*) ok "...and holds a sign-in key for eastc" ;;
	*) bad "no sign-in key held for eastc - a LOWER cluster is identified by its \
key, so without one it cannot be admitted at all: [$up_link]" ;;
esac
case "$up_link" in
	*"eastc=LOWER@"*) bad "the upper cluster holds an ADDRESS for eastc - a \
subordinate cluster must not be reachable from above: [$up_link]" ;;
	*) ok "...and no address for it, so it cannot be dialled downward" ;;
esac

# the lower cluster holds the mirror shape: addresses, no key
case "$ea_link" in
	*"top=UPPER@"*) ok "eastc holds ADDRESSES for the cluster above it" ;;
	*) bad "eastc has no address for top, so its leader cannot dial up: [$ea_link]" ;;
esac
case "$ea_link" in
	*"westc=NEIGHBOR@"*) ok "...and for its same-tier sibling" ;;
	*) bad "eastc has no address for westc: [$ea_link]" ;;
esac
case "$ea_link" in
	*"top=UPPER+key"*) bad "eastc holds a sign-in key for top - a key is for \
verifying a cluster that signs in to us, and top does not: [$ea_link]" ;;
	*) ok "...and no sign-in key for a cluster it dials" ;;
esac

# ── 3. one cluster names several others ────────────────────────────────────
#
# eastc is UPPER to top AND NEIGHBOR to westc. Every row is implicitly "as seen from
# here", so two rows about two different clusters cannot collide - the case an
# earlier per-az `level` + `parent` form silently lost.
two=0
case "$ea_link" in *top=UPPER*) two=$((two+1));; esac
case "$ea_link" in *westc=NEIGHBOR*) two=$((two+1));; esac
[ "$two" = 2 ] \
	&& ok "eastc names BOTH of the clusters it is linked to" \
	|| bad "eastc lost one of its two links: [$ea_link]"

# ── 4. the relations resolve per peer ──────────────────────────────────────
up_ext="$(info "$UP" E az_external)"
ea_ext="$(info a1 E az_external)"
echo "  $UP az_external: ${up_ext:-<none>}"
echo "  a1 az_external: ${ea_ext:-<none>}"
case "$ea_ext" in
	*UPPER*) ok "an eastc node resolves UPPER for the nodes above it" ;;
	*) bad "no UPPER relation on a1: [${ea_ext:-<none>}]" ;;
esac
case "$ea_ext" in
	*NEIGHBOR*) ok "...and NEIGHBOR for its sibling's nodes" ;;
	*) bad "no NEIGHBOR relation on a1: [${ea_ext:-<none>}]" ;;
esac
# The upper cluster has no addresses and no roster for its children, so it has no
# external PEERS at all until one signs in - which is the shape, not a fault.
[ -z "$up_ext" ] \
	&& ok "the upper cluster holds no external peer until a child signs in" \
	|| echo "  (upper has external peers: $up_ext)"

# ── 5. a member of this cluster is NOT an external link ────────────────────
#
# The inverse assertion, and the one that would catch an over-eager relation: if
# `relation_to` returned anything but DEFAULT for a peer in the same az, every
# member would be excluded from its own quorum.
same_az_listed=0
for peer in a2 a3; do
	u8="$(node_uuid "$peer" | cut -c1-2)"
	case "$ea_ext" in *"$u8"*) same_az_listed=1;; esac
done
[ "$same_az_listed" = 0 ] \
	&& ok "a1's own cluster-mates are not listed as external links" \
	|| bad "a member of the same az is being treated as a cross-cluster link: [$ea_ext]"

# ── 6. the RUNTIME arrival path ────────────────────────────────────────────
#
# `.tier` was once parsed by the startup loader and again by `re_config`, and a
# rule wired into one arrival path of several works until somebody arrives the
# other way. Both now call `AzMap::apply_z_row`; this writes an edge into a RUNNING
# cluster and checks the live config picked it up without a restart.
# Through the CLUSTER path, not a plain INSERT. A bare insert into the config table
# is a local write: the sync trigger fires but nothing completes the cluster
# transaction, so the row sits on one node and `re_config` never runs for it - which
# looked exactly like the runtime arrival path being unwired, and is a harness
# mistake rather than a product one. A runtime config change has to travel the way
# any other synced write does.
echo "  adding an edge at runtime, through the cluster path (no restart)..."
q "$EA" "begin;
         insert into $YX_CFG (name,module,value) values ('zztest.level','Z','NEIGHBOR')
           on conflict do nothing;
         select yt_complete(true);
         commit;" >/dev/null 2>&1 || true
runtime_ok=0
for _ in $(seq 1 12); do
	case "$(info "$EA" E az_link)" in
		*"zztest=NEIGHBOR"*) runtime_ok=1; break ;;
	esac
	sleep 5
done
[ "$runtime_ok" = 1 ] \
	&& ok "an edge written at runtime reached the live config (re_config path)" \
	|| bad "the runtime path did not load the new edge - apply_z_row is wired into \
the startup loader only, which is the bug it was written to prevent"

# put it back, so later scripts see the declared topology
q "$EA" "begin;
         delete from $YX_CFG where module='Z' and name='zztest.level';
         select yt_complete(true);
         commit;" >/dev/null 2>&1 || true

summary
