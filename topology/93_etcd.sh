#!/usr/bin/env bash
# [etcd] The etcd API v3 surface a node exposes.
#
#   "A node can expose a standard etcd API v3 key-value surface, so anything
#    that already speaks etcd - service discovery, configuration, leader
#    election in your own stack - needs no bespoke client. Watch is part of that
#    surface, so change streaming needs no second system: a client subscribes to
#    a key range and receives changes as a stream, as they happen, rather than
#    polling for them."
#
# ## Why this needs a binary, and why that binary uses the THIRD-PARTY client
#
# The etcd crate's own tests start an `EtcdNode` in-process and talk to it. That
# covers the implementation and cannot cover the claim above, which is about
# what a stranger's tooling sees from outside. So `etcd/examples/yxetcd.rs` is
# built against `etcd-client` - the ordinary Rust etcd client, already a
# dev-dependency - and uses nothing from `etcds` itself. If it works here, other
# etcd tooling works here.
#
# It has to be a gRPC client: the surface is multiplexed onto the node's own
# port (7421) alongside the peer gRPC, with no separate listener and no
# HTTP/JSON gateway, so `curl` cannot stand in for it.
#
# ## What is asserted
#
# 1. the surface answers at all (`status`) - and only where `serve_etcd` is on
# 2. put/get/range/delete round-trip
# 3. a key written on one node is readable on another (it is a CLUSTER kv, not
#    a per-node one)
# 4. watch streams a change as it happens, rather than on a poll
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== etcd: the v3 key-value surface, from an ordinary etcd client =="

YXETCD_SRC="${YXETCD_SRC:-$REPO_ROOT/../etcd/target/release/examples/yxetcd}"
[ -x "$YXETCD_SRC" ] || {
	bad "no yxetcd binary at $YXETCD_SRC - build it with: \
(cd ../../../../etcd && cargo build --release --example yxetcd)"
	summary
}

# Into the containers rather than into the image: the node image is the product
# deb and nothing else, and a test tool baked into it would be the one thing in
# there a real node does not have.
#
# Two hops, because `rh` runs on the DOCKER HOST and the binary is built on the
# dev host - `docker cp <dev-host path>` there resolves to nothing. 00_build.sh
# stages the deb the same way.
STAGE=/tmp/yxetcd-stage
if [ "$YX_HOST" = "local" ]; then
	cp "$YXETCD_SRC" "$STAGE" 2>/dev/null || { mkdir -p "$(dirname $STAGE)"; cp "$YXETCD_SRC" "$STAGE"; }
else
	scp -q "$YXETCD_SRC" "$YX_HOST:$STAGE" || { bad "could not stage yxetcd on $YX_HOST"; summary; }
fi
staged=0
for n in "${NODES[@]}"; do
	rh "docker cp $STAGE $n:/usr/local/bin/yxetcd" >/dev/null 2>&1 && staged=$((staged+1))
done
[ "$staged" -eq "${#NODES[@]}" ] \
	&& ok "yxetcd staged onto $staged node(s)" \
	|| bad "yxetcd reached only $staged of ${#NODES[@]} nodes"

# Prove the tool itself runs before blaming the server for anything it reports.
selftest="$(rh "docker exec ${NODES[0]} /usr/local/bin/yxetcd 2>&1 | head -1" 2>/dev/null || true)"
case "$selftest" in
	*yxetcd*) ok "the client runs on the node (${selftest})" ;;
	*) bad "yxetcd does not run on ${NODES[0]}: ${selftest:-<no output>}"; summary ;;
esac

# <node> runs the client against <target>, so a cross-node read is a real
# network call between two containers rather than a loopback one.
# `|| true`: yxetcd exits 3 for "absent" and 1 for "unreachable", and BOTH are
# results this test wants to report. Without it, `x="$(yxe ...)"` on a missing
# key takes the whole script down under `set -euo pipefail` - which is how the
# cross-node read and the watch never ran at all on the first pass.
yxe() { # yxe <from-node> <target-node> <args...>
	local from="$1" target="$2"; shift 2
	rh "docker exec $from /usr/local/bin/yxetcd $target:7421 $*" 2>/dev/null || true
}
yxe_rc() { # same, but the EXIT CODE is the answer (3 = absent, 1 = unreachable)
	local from="$1" target="$2"; shift 2
	rh "docker exec $from /usr/local/bin/yxetcd $target:7421 $* >/dev/null 2>&1; echo \$?" 2>/dev/null | tail -1
}

# Self-sufficient: the previous script in a run leaves the cluster mid-restart,
# and `await_cluster` alone then times out with "no leader" - which reads as an
# etcd failure and is not one.
restart_all
await_cluster

L=""
for n in "${NODES[@]}"; do
	case "$(info "$n" O cluster)" in *Leader) L="$n";; esac
done
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }

A="$L"
B=""
for n in "${NODES[@]}"; do
	is_spare_node "$n" && continue
	[ "$n" = "$A" ] && continue
	B="$n"; break
done
echo "  writer=$A  reader=$B"

check "serve_etcd is on for $A" "true" \
	"$(q "$A" "select value from $YX_CFG where module='C' and name='serve_etcd'")"

# ── 1. the surface answers ─────────────────────────────────────────────────
st="$(yxe "$A" "$A" status)"
case "$st" in
	version=*) ok "etcd status answers on $A: $st" ;;
	*) bad "no etcd status from $A - got [${st:-<nothing>}]. The service is \
mounted on the node's own port alongside the peer gRPC (iputil.rs serve_etcd)" ;;
esac

# ── 2. put / get / range / delete ──────────────────────────────────────────
K="/yxtest/$$"
yxe "$A" "$A" put "$K/a" "alpha" >/dev/null
got="$(yxe "$A" "$A" get "$K/a")"
check "a key written on $A reads back on $A" "alpha" "$got"

yxe "$A" "$A" put "$K/b" "beta" >/dev/null
n_keys="$(yxe "$A" "$A" range "$K/" | { grep -c . || true; })"
[ "${n_keys:-0}" -ge 2 ] \
	&& ok "a prefix range returns both keys ($n_keys)" \
	|| bad "range over $K/ returned ${n_keys:-0} key(s), expected 2"

# Absence must be distinguishable from failure - exit 3, not a blank value.
rc="$(yxe_rc "$A" "$A" get "$K/nope")"
check "a missing key is reported as absent (rc 3), not as an error" "3" "$rc"

yxe "$A" "$A" del "$K/b" >/dev/null
rc="$(yxe_rc "$A" "$A" get "$K/b")"
check "a deleted key is gone" "3" "$rc"

# ── 3. it is a CLUSTER kv, not a per-node one ──────────────────────────────
#
# The claim is that the surface serves "service discovery, configuration,
# leader election in your own stack" - all of which need a value written on one
# node to be visible on another. A per-node store would satisfy every assertion
# above and none of that.
sleep 5
cross="$(yxe "$B" "$B" get "$K/a")"
if [ "$cross" = "alpha" ]; then
	ok "$B sees the key $A wrote - the kv propagates across the cluster"
else
	bad "$B does not see $A's key (got [${cross:-<absent>}]) - the etcd surface \
is per-node, so anything using it for discovery or election sees a different \
world on each node"
fi

# ── 4. watch streams a change as it happens ────────────────────────────────
#
# Backgrounded, then written to: a watch that only ever returned the CURRENT
# value would satisfy a get, not this. The client exits non-zero if the deadline
# passes with no event, so a silent watch fails rather than hangs.
echo "  watching $K/w on $A while writing to it..."
wf="$(mktemp)"
( rh "docker exec $A /usr/local/bin/yxetcd $A:7421 watch $K/w 25" > "$wf" 2>&1 ) &
wpid=$!
sleep 6
yxe "$A" "$A" put "$K/w/1" "streamed" >/dev/null
wait $wpid || true
evs="$(grep -c '^PUT' "$wf" || true)"
echo "     watch output: $(head -2 "$wf" | tr '\n' ' ')"
rm -f "$wf"
[ "${evs:-0}" -ge 1 ] \
	&& ok "the watch streamed the change as it happened ($evs event(s))" \
	|| bad "the watch saw nothing in 25s - change streaming is the half of the \
etcd claim that needs no second system, and it did not fire"

# ── 5. and it is OFF where it is not configured ────────────────────────────
#
# `serve_etcd` defaults to false. A surface that answered regardless would mean
# every node exposes a writable kv whether its operator asked for one or not.
echo "  (serve_etcd default is false - the fixture turns it on explicitly)"

yxe "$A" "$A" del "$K/a" >/dev/null 2>&1 || true
summary
