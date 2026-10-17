#!/usr/bin/env bash
# [skv] The hierarchy on the secret store and TLS (yt-pgxt skv-secrets.md H2): a
# link is refused unless both clusters run them, so this is part of bringing the
# fixture up - right after 10_up.sh, before any script that needs a link. Set up the
# way an operator does it (H6): the store and genesis in each cluster, every node
# approved, TLS on, the links declared with yxctl from both ends and each lower CA
# approved on the upper leader with the line yxctl printed.
#
# Every node runs with an app key of its own (H7: "$YX_HIER_SECRET-<node>", env.sh).
#
# ## What is asserted
#
# S1 each cluster: the store on, genesis on its leader, every node approved
# S2 peer_tls on everywhere: every node holds a certificate of its own cluster's CA
# S3 yxctl --link-lower on the upper leader prints the upper's root and the line
#    each lower's operator runs; until its CA is approved the upper refuses a
#    lower's sign-in (H4: the CA admits it); yxctl --link-upper on each lower leader
#    pins the root (Z top.root) and prints the approval the upper's operator runs
# S4 the operator approves each lower's CA on the upper leader with the printed
#    line; an approval naming another key is refused
# S5 each lower cluster's CA is countersigned by the upper, the upper's root held;
#    east and west, neighbours under that upper, admit each other with no approval
#    (H3) - yxctl --link-neighbor prints what each side runs
# S6 every cluster requires TLS - links included
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../topology/skv_lib.sh"
echo "== hier store: every cluster on the secret store and TLS, the links set up with yxctl =="

[ -n "${YX_HIER_SECRET:-}" ] || { bad "YX_HIER_SECRET is empty: the nodes run with no app key, so there is no secret store"; summary; }
await_clusters

# ── S1 ───────────────────────────────────────────────────────────────────────
for c in "${CLUSTERS[@]}"; do
	in_cluster "$c"
	[ -n "$L" ] || { bad "S1 cluster $c has no leader"; continue; }
	# short, so 80_skv_link_tls.sh's rotations retire the old version within a test
	cfg_push skv_rotate_overlap_sec C 20
	if skv_setup; then ok "S1 $c: the store on, genesis on $L, every node approved: all hold v1"
	else bad "S1 $c: v1 not held on:$(not_holding 1)"; fi
done

# ── S2 ───────────────────────────────────────────────────────────────────────
T2="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for c in "${CLUSTERS[@]}"; do in_cluster "$c"; cfg_push peer_tls C true; done
for c in "${CLUSTERS[@]}"; do
	in_cluster "$c"
	skv_wait 120 "$c: certificates" all_tls "certificates v1" && ok "S2 $c: every node holds its certificate of v1" \
		|| bad "S2 $c: no certificate on:$(tls_not "certificates v1")"
done

# ── S3 the links, from both ends (yxctl, H6) ─────────────────────────────────
in_cluster upper
UL="$L"
o=""
for az in eastc westc; do
	o="$(yx "$UL" --link-lower $az)"
	case "$o" in *": CA v1 SHA256:"*"--link-upper top="*"--link-root SHA256:"*)
		ok "S3 --link-lower $az on the upper leader prints its root and the lower's line" ;;
		*) bad "S3 --link-lower $az: $(echo "$o" | tail -3 | tr '\n' ' ')" ;; esac
done
UROOT="$(printf '%s\n' "$o" | sed -n 's/.*: CA v1 \(SHA256:[A-Za-z0-9+\/]*\).*/\1/p' | head -1)"
check "S3 the root it printed is the upper's CA v1 (yt_info X @ca/1)" "$(info "$UL" X @ca/1)" "$UROOT"
pending() { q "$UL" "select count(*) from $YX_CFG where module='J' and value like 'pending:%'"; }
for _ in $(seq 1 60); do [ "$(pending)" -ge 2 ] 2>/dev/null && break; sleep 2; done
check "S3 the upper leader $UL holds the CA of both lower clusters for approval" "2" "$(pending)"
declare -A APPROVAL
for c in east west; do
	in_cluster "$c"
	r="$(ca_refusals "$L" "$T2")"
	[ "${r:-0}" -ge 1 ] 2>/dev/null && ok "S3 $c's sign-in is refused until its CA is approved (H4) - $r line(s) on $L" \
		|| bad "S3 $c's leader $L logged no sign-in refused for its CA"
	hosts="$(q "$L" "select value from $YX_CFG where module='Z' and name='top.host'")"
	o="$(yx "$L" --link-upper "top=$hosts" --link-root "$UROOT")"
	# `|| true`: under env.sh's `set -e` a line not printed ended the whole script here
	APPROVAL[$c]="$(printf '%s\n' "$o" | grep -o -- '--skv-approve [0-9a-f-]* --fingerprint SHA256:[A-Za-z0-9+/]*' | head -1 || true)"
	[ -n "${APPROVAL[$c]}" ] && ok "S3 --link-upper on $c's leader prints the approval: yxctl ${APPROVAL[$c]}" \
		|| bad "S3 --link-upper on $c: $(echo "$o" | tail -3 | tr '\n' ' ')"
	pinned=0
	for _ in $(seq 1 15); do
		pinned=0
		for n in "${NODES[@]}"; do
			[ "$(q "$n" "select value from $YX_CFG where module='Z' and name='top.root'")" = "$UROOT" ] && pinned=$((pinned + 1))
		done
		[ "$pinned" = "${#NODES[@]}" ] && break; sleep 2
	done
	check "S3 every $c node pins the upper's root (Z top.root)" "${#NODES[@]}" "$pinned"
done

# ── S4 the approvals, as printed ─────────────────────────────────────────────
T4="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
in_cluster upper
w="${APPROVAL[west]#*--fingerprint }"
o="$(yx "$UL" "${APPROVAL[east]% --fingerprint*}" --fingerprint "$w" --yes)"
case "$o" in *"not approved"*) ok "S4 an approval of east naming west's key is refused" ;;
	*) bad "S4 an approval naming another key: $(echo "$o" | tail -2 | tr '\n' ' ')" ;; esac
for c in east west; do
	o="$(yx "$UL" ${APPROVAL[$c]} --yes)"
	case "$o" in *Approved*) ok "S4 the operator approved $c's CA on the upper leader" ;;
		*) bad "S4 the approval of $c failed: $(echo "$o" | tail -2 | tr '\n' ' ')" ;; esac
done

# ── S5 ───────────────────────────────────────────────────────────────────────
for c in east west; do
	in_cluster "$c"
	skv_wait 120 "$c: countersigned" all_tls "CA countersigned by the upper cluster" \
		&& ok "S5 $c: its CA countersigned by the upper cluster, the upper's root held on every node" \
		|| bad "S5 $c: not countersigned on:$(tls_not "countersigned")"
done
check "S5 the upper recorded both approvals (K ca:<az>)" "2" \
	"$(q "$UL" "select count(*) from $YX_CFG where module='K' and name like 'ca:%'")"
# [H3] neighbours under the same upper: its countersignature approved both - the
# sign-in each logs once it changes, after the approvals (T4)
in_cluster east
hosts="$(q "$L" "select value from $YX_CFG where module='Z' and name='westc.host'")"
o="$(yx "$L" --link-neighbor "westc=$hosts")"
case "$o" in *"--link-neighbor eastc="*"--skv-approve "*) ok "S5 --link-neighbor on east's leader prints west's line and the approval" ;;
	*) bad "S5 --link-neighbor westc: $(echo "$o" | tail -3 | tr '\n' ' ')" ;; esac
jp() { q "$1" "select count(*) from $YX_CFG where module='J' and value like 'pending:%'"; }
for c in east west; do
	in_cluster "$c"
	other=westc; [ "$c" = west ] && other=eastc
	for _ in $(seq 1 45); do
		[ "$(jp "$L")" = 0 ] && [ -n "$(rh "docker logs --since $T4 $L 2>&1 | grep -a 'signed in to az $other as NEIGHBOR' | tail -1" 2>/dev/null || true)" ] && break
		sleep 2
	done
	check "S5 $c's leader holds no approval request for its neighbour $other (H3: the upper vouches)" "0" "$(jp "$L")"
	s5="$(rh "docker logs --since $T4 $L 2>&1 | grep -a 'signed in to az $other as NEIGHBOR' | tail -1" 2>/dev/null || true)"
	[ -n "$s5" ] && ok "S5 $c signed in to its neighbour $other" || bad "S5 $c logged no sign-in to $other since the approvals"
done

# ── S6 ───────────────────────────────────────────────────────────────────────
for c in "${CLUSTERS[@]}"; do
	in_cluster "$c"
	for _ in $(seq 1 60); do case "$(required_line "$L")" in "TLS between members required:"*) break;; esac; sleep 2; done
	case "$(required_line "$L")" in "TLS between members required:"*) ok "S6 $c requires TLS, its links included" ;;
		*) bad "S6 $c does not require TLS: $(required_line "$L")" ;; esac
done
summary
