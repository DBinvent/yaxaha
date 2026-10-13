#!/usr/bin/env bash
# [skv] TLS across links (yt-pgxt ytserv/skv/link.rs): the UPPER cluster's CA
# countersigns each LOWER cluster's CA, so the hierarchy chains to the upper root
# (decided 2026-10-13), and a lower rotation is countersigned again by continuity
# with no operator.
#
# Needs the nodes to run with an app key the three clusters share: run 10_up.sh
# with YX_HIER_SECRET set (it is unset in the nightly, which this test is not in).
#
# ## What is asserted
#
# H1 each cluster: the store on, genesis on its leader, every node approved
# H2 peer_tls on everywhere: every node holds a certificate of its own cluster's CA
# H3 the upper leader holds the CA of each lower cluster for approval (a J row
#    named by its az's uuid); the operator approves both there
# H4 each lower cluster's CA is countersigned by the upper, the upper's root held
# H5 every cluster requires TLS - links included
# H6 a plaintext peer RPC from a lower node to an upper node is refused
# H7 a lower cluster rotates: its new CA countersigned by continuity, no operator;
#    once its old version is retired the upper revokes the old CA key
# H8 the upper rotates: its old version is retired only once both lower clusters
#    hold a CA countersigned by the new one; every cluster still requires TLS
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../topology/skv_lib.sh"
echo "== skv link TLS: the upper cluster's CA countersigns each lower cluster's CA =="

in_cluster() { # point the skv helpers at one cluster: its nodes, its leader
	read -r -a NODES <<< "${CLUSTER_NODES[$1]}"
	L="$(leader_of "$1")"
}
x_like() { q "$1" "select count(*) from $YX_CFG where module='X' and name like '$2'"; }
required_line() { info "$1" X peer_tls; }

[ -n "${YX_HIER_SECRET:-}" ] || { bad "YX_HIER_SECRET is not set: the nodes run with no app key, so there is no secret store"; summary; }
await_clusters

# ── H1 ───────────────────────────────────────────────────────────────────────
for c in "${CLUSTERS[@]}"; do
	in_cluster "$c"
	[ -n "$L" ] || { bad "H1 cluster $c has no leader"; continue; }
	skv_cleanup
	cfg_push skv_rotate_overlap_sec C 20
	if skv_setup; then ok "H1 $c: the store on, genesis on $L, every node approved: all hold v1"
	else bad "H1 $c: v1 not held on:$(not_holding 1)"; fi
done

# ── H2 ───────────────────────────────────────────────────────────────────────
for c in "${CLUSTERS[@]}"; do in_cluster "$c"; cfg_push peer_tls C true; done
for c in "${CLUSTERS[@]}"; do
	in_cluster "$c"
	skv_wait 120 "$c: certificates" all_tls "certificates v1" && ok "H2 $c: every node holds its certificate of v1" \
		|| bad "H2 $c: no certificate on:$(tls_not "certificates v1")"
done

# ── H3 ───────────────────────────────────────────────────────────────────────
in_cluster upper
UL="$L"
pending() { q "$UL" "select count(*) from $YX_CFG where module='J' and value like 'pending:%'"; }
for _ in $(seq 1 60); do [ "$(pending)" -ge 2 ] 2>/dev/null && break; sleep 2; done
check "H3 the upper leader $UL holds the CA of both lower clusters for approval" "2" "$(pending)"
for u in $(q "$UL" "select name from $YX_CFG where module='J' and value like 'pending:%'"); do
	case "$(approve "$u")" in *Approved*) ok "H3 the operator approved the CA of az $u on the upper leader" ;;
		*) bad "H3 the approval of az $u failed: $(approve "$u" | tail -1)" ;; esac
done

# ── H4 ───────────────────────────────────────────────────────────────────────
for c in east west; do
	in_cluster "$c"
	skv_wait 120 "$c: countersigned" all_tls "CA countersigned by the upper cluster" \
		&& ok "H4 $c: its CA countersigned by the upper cluster, the upper's root held on every node" \
		|| bad "H4 $c: not countersigned on:$(tls_not "countersigned")"
done
check "H4 the upper recorded both approvals (K ca:<az>)" "2" \
	"$(q "$UL" "select count(*) from $YX_CFG where module='K' and name like 'ca:%'")"

# ── H5 ───────────────────────────────────────────────────────────────────────
for c in "${CLUSTERS[@]}"; do
	in_cluster "$c"
	for _ in $(seq 1 60); do case "$(required_line "$L")" in "TLS between members required:"*) break;; esac; sleep 2; done
	case "$(required_line "$L")" in "TLS between members required:"*) ok "H5 $c requires TLS, its links included" ;;
		*) bad "H5 $c does not require TLS: $(required_line "$L")" ;; esac
done

# ── H6 ───────────────────────────────────────────────────────────────────────
in_cluster east
EL="$L"
UR=""; for n in "${CL_UPPER[@]}"; do [ "$n" = "$UL" ] || { UR="$n"; break; }; done
o="$(grpc_plain "$EL" "$UR" data)"
case "$o" in "PERMISSION_DENIED"*"peer_tls"*) ok "H6 a plaintext peer RPC from the lower leader $EL to $UR is refused" ;;
	*) bad "H6 plaintext from $EL to $UR: $o" ;; esac

# ── H7 a lower rotation ─────────────────────────────────────────────────────
in_cluster east
o="$(yx "$L" --skv-rotate)"
case "$o" in *"master key v2 published"*) ok "H7 east rotates: v2 and its CA published" ;; *) bad "H7 east rotate: $(echo "$o" | tail -1)" ;; esac
both() { all_tls "v2" && all_tls "CA countersigned"; }
skv_wait 150 "east v2 countersigned" both && ok "H7 east's new CA countersigned by continuity - no operator" \
	|| bad "H7 east v2 not countersigned:$(tls_not "countersigned")"
for _ in $(seq 1 90); do [ "$(x_like "$L" '@canary/1')" = 0 ] && break; sleep 2; done
check "H7 east retired its v1" "0" "$(x_like "$L" '@canary/1')"
for _ in $(seq 1 60); do [ "$(x_like "$UL" '@crl/ca:%')" -ge 1 ] 2>/dev/null && break; sleep 2; done
case "$(x_like "$UL" '@crl/ca:%')" in 0|"") bad "H7 the upper did not revoke east's old CA key" ;;
	*) ok "H7 ...and the upper revoked east's old CA key (the new one works)" ;; esac
in_cluster east
case "$(required_line "$L")" in "TLS between members required:"*) ok "H7 east still requires TLS" ;; *) bad "H7 east: $(required_line "$L")" ;; esac

# ── H8 an upper rotation ────────────────────────────────────────────────────
in_cluster upper
o="$(yx "$UL" --skv-rotate)"
case "$o" in *"master key v2 published"*) ok "H8 the upper rotates: v2 and its CA published" ;; *) bad "H8 upper rotate: $(echo "$o" | tail -1)" ;; esac
for _ in $(seq 1 120); do [ "$(x_like "$UL" '@ca/1/cert')" = 0 ] && break; sleep 2; done
check "H8 the upper retired its v1 - once both lower clusters were countersigned by v2" "0" "$(x_like "$UL" '@ca/1/cert')"
for c in east west; do
	in_cluster "$c"
	for _ in $(seq 1 45); do [ "$(x_like "$L" '@upca/%')" = 1 ] && break; sleep 2; done
	check "H8 $c holds the upper's one live root" "1" "$(x_like "$L" '@upca/%')"
	skv_wait 60 "$c countersigned" all_tls "CA countersigned" && ok "H8 $c: every node still countersigned" \
		|| bad "H8 $c:$(tls_not "countersigned")"
done
for c in "${CLUSTERS[@]}"; do
	in_cluster "$c"
	case "$(required_line "$L")" in "TLS between members required:"*) ok "H8 $c still requires TLS" ;;
		*) bad "H8 $c: $(required_line "$L")" ;; esac
done

# ── cleanup: TLS off, then the store, in every cluster ───────────────────────
for c in "${CLUSTERS[@]}"; do in_cluster "$c"; cfg_push peer_tls C false; done
for c in "${CLUSTERS[@]}"; do in_cluster "$c"; skv_cleanup; done
summary
