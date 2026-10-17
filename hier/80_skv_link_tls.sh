#!/usr/bin/env bash
# [skv] TLS across links (yt-pgxt ytserv/skv/link.rs): the UPPER cluster's CA
# countersigns each LOWER cluster's CA, so the hierarchy chains to the upper root
# (decided 2026-10-13), and a lower rotation is countersigned again by continuity
# with no operator.
#
# The hierarchy runs on the store and TLS from the start (H2): 15_store.sh set it up
# - the store, genesis and approvals in each cluster, TLS required, the links
# declared with yxctl and each lower CA approved on the upper leader. This script
# checks what holds across the links, then rotates a lower and the upper. The store
# and TLS stay on afterwards: a hierarchy cannot run without them.
#
# ## What is asserted
#
# H7 a plaintext peer RPC from a lower node to an upper node is refused
# H8 a lower cluster rotates: its new CA countersigned by continuity, no operator;
#    once its old version is retired the upper revokes the old CA key
# H9 the upper rotates: its old version is retired only once both lower clusters
#    hold a CA countersigned by the new one - reached from the root they pinned, v1,
#    by the cross-certificate; every cluster still requires TLS
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../topology/skv_lib.sh"
echo "== skv link TLS: the upper cluster's CA countersigns each lower cluster's CA =="

await_clusters
# 15_store.sh first: every cluster on the store, TLS required
for c in "${CLUSTERS[@]}"; do
	in_cluster "$c"
	case "$(required_line "$L")" in "TLS between members required:"*) ;;
		*) bad "cluster $c does not require TLS - 15_store.sh sets the hierarchy up: $(required_line "$L")"; summary ;; esac
done
in_cluster upper
UL="$L"

# ── H7 ───────────────────────────────────────────────────────────────────────
in_cluster east
EL="$L"
UR=""; for n in "${CL_UPPER[@]}"; do [ "$n" = "$UL" ] || { UR="$n"; break; }; done
o="$(grpc_plain "$EL" "$UR" data)"
case "$o" in "PERMISSION_DENIED"*"peer_tls"*) ok "H7 a plaintext peer RPC from the lower leader $EL to $UR is refused" ;;
	*) bad "H7 plaintext from $EL to $UR: $o" ;; esac

# ── H8 a lower rotation ─────────────────────────────────────────────────────
in_cluster east
o="$(yx "$L" --skv-rotate)"
case "$o" in *"master key v2 published"*) ok "H8 east rotates: v2 and its CA published" ;; *) bad "H8 east rotate: $(echo "$o" | tail -1)" ;; esac
both() { all_tls "v2" && all_tls "CA countersigned"; }
skv_wait 150 "east v2 countersigned" both && ok "H8 east's new CA countersigned by continuity - no operator" \
	|| bad "H8 east v2 not countersigned:$(tls_not "countersigned")"
for _ in $(seq 1 90); do [ "$(x_like "$L" '@canary/1')" = 0 ] && break; sleep 2; done
check "H8 east retired its v1" "0" "$(x_like "$L" '@canary/1')"
for _ in $(seq 1 60); do [ "$(x_like "$UL" '@crl/ca:%')" -ge 1 ] 2>/dev/null && break; sleep 2; done
case "$(x_like "$UL" '@crl/ca:%')" in 0|"") bad "H8 the upper did not revoke east's old CA key" ;;
	*) ok "H8 ...and the upper revoked east's old CA key (the new one works)" ;; esac
in_cluster east
case "$(required_line "$L")" in "TLS between members required:"*) ok "H8 east still requires TLS" ;; *) bad "H8 east: $(required_line "$L")" ;; esac

# ── H9 an upper rotation ────────────────────────────────────────────────────
in_cluster upper
o="$(yx "$UL" --skv-rotate)"
case "$o" in *"master key v2 published"*) ok "H9 the upper rotates: v2 and its CA published" ;; *) bad "H9 upper rotate: $(echo "$o" | tail -1)" ;; esac
for _ in $(seq 1 120); do [ "$(x_like "$UL" '@ca/1/cert')" = 0 ] && break; sleep 2; done
check "H9 the upper retired its v1 - once both lower clusters were countersigned by v2" "0" "$(x_like "$UL" '@ca/1/cert')"
for c in east west; do
	in_cluster "$c"
	for _ in $(seq 1 45); do [ "$(x_like "$L" '@upca/%')" = 1 ] && break; sleep 2; done
	check "H9 $c holds the upper's one live root" "1" "$(x_like "$L" '@upca/%')"
	skv_wait 60 "$c countersigned" all_tls "CA countersigned" && ok "H9 $c: every node still countersigned" \
		|| bad "H9 $c:$(tls_not "countersigned")"
done
for c in "${CLUSTERS[@]}"; do
	in_cluster "$c"
	case "$(required_line "$L")" in "TLS between members required:"*) ok "H9 $c still requires TLS" ;;
		*) bad "H9 $c: $(required_line "$L")" ;; esac
done

summary
