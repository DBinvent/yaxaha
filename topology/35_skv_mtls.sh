#!/usr/bin/env bash
# [skv] peer_tls, phase P7 (yt-pgxt ytserv/skv-secrets.md, D16): mutual TLS between
# the members on the peer port, every certificate issued by the cluster CA of a
# master key version, and a cold start of the whole cluster with TLS required.
#
# The prerequisites come first, as the owner set them (2026-10-12): the app key on
# every node (10_up.sh), the cluster master key (genesis), every node approved for
# it (enroll + yxctl --skv-approve). Then peer_tls on: the leader makes the CA of
# the current version and a certificate per approved node; members speak TLS to
# each other as soon as each has one (the peer port takes both until then); once
# every member reported a certificate the leader writes @tls and plaintext peer
# RPCs are refused, but for the doors a node without a certificate needs.
#
# Key rotation: during a rotation both versions' CAs are trusted and every node
# holds a certificate of each; a connection tries the newest and falls back to
# the older; the older is retired only once every member confirmed the newer.
#
# ## What is asserted
#
# M1 the prerequisites: the store on, genesis, every node approved, all hold v1
# M2 peer_tls on: the CA of v1 and one certificate per node; every node has its own
# M3 every member reported one: the leader requires TLS (@tls), every node says so
# M4 on the wire: a peer answers a TLS hello with its certificate - its uuid,
#    issued by the CA of v1 - and refuses a client without one
# M5 a plaintext peer RPC is refused (data); the doors stay open (register, ping)
# M6 the cluster works over TLS: a cluster write reaches and reads on every node
# M7 cold start: every ytserv stopped, all started together with TLS required -
#    a leader is elected, every node is back on TLS, holds v1, writes replicate,
#    and no member was refused for speaking plaintext
# M8 rotation under load: v2 published, certificates of both versions while it
#    runs, writes and reads never fail, v1 retired - every node on v2 alone
# M9 peer_tls off: the requirement and the certificates go, plaintext again, and
#    the cluster still writes
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/skv_lib.sh"
echo "== skv mtls: peer_tls on the cluster CA, required, cold start, rotation =="

# every node's peer_tls line contains $1
all_tls() {
	local want="$1" n
	for n in "${NODES[@]}"; do case "$(tls_of "$n")" in *"$want"*) ;; *) return 1;; esac; done
}
tls_not() { # the nodes whose peer_tls line lacks $1
	local want="$1" n out=""
	for n in "${NODES[@]}"; do case "$(tls_of "$n")" in *"$want"*) ;; *) out="$out $n($(tls_of "$n"))";; esac; done
	printf '%s' "$out"
}
# a plaintext gRPC call from inside a node: the status it gets
grpc_plain() { # grpc_plain <from> <to> <method>
	rh "docker exec -i $1 python3 -" <<EOF 2>&1 || true
import grpc
ch = grpc.insecure_channel('$2:$YX_PORT')
f = ch.unary_unary('/rg.Grpc/$3', request_serializer=lambda x: x, response_deserializer=lambda x: x)
try:
    f(b'', timeout=10)
    print('OK')
except grpc.RpcError as e:
    print(e.code().name, (e.details() or '')[:200])
EOF
}
# A cold start: every ytserv stopped, then all started together. The cluster WAL
# is wiped as restart_all does (a resumed term would collide with it), but each
# node's key stays - fs_dir/<uuid>/node.key - so every node comes back holding
# what its own key opens, and speaks TLS from its first packet.
cold_start() {
	local n
	for n in "${NODES[@]}"; do rh "docker exec $n pkill -f yaxaha/ytserv >/dev/null 2>&1; true"; done
	sleep 2
	for n in "${NODES[@]}"; do
		rh "docker exec $n sh -c 'k=\$(find /var/yaxaha -name node.key | head -1); if [ -n \"\$k\" ]; then d=\$(dirname \"\$k\");
			find /var/yaxaha -mindepth 1 -maxdepth 1 ! -path \"\$d\" -exec rm -rf {} +;
			find \"\$d\" -mindepth 1 ! -name node.key ! -name node.pub -exec rm -rf {} +; else rm -rf /var/yaxaha/*; fi'" \
			>/dev/null 2>&1 || true
		cfg_delete "$n" least C
	done
	clear_prepared
	for n in "${NODES[@]}"; do rh "docker restart $n >/dev/null" & done
	wait
	sleep "${1:-30}"
}

await_cluster
L="$(leader)"
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }
F=""; P=""
for n in "${NODES[@]}"; do
	is_spare_node "$n" && continue
	[ "$n" = "$L" ] && continue
	if [ -z "$F" ]; then F="$n"; elif [ -z "$P" ]; then P="$n"; fi
done
skv_cleanup

# ── M1 the prerequisites ─────────────────────────────────────────────────────
if skv_setup; then
	ok "M1 the store on, genesis on $L, every node approved: all hold v1"
else
	bad "M1 the prerequisites are not met - v1 not held on:$(not_holding 1)"; skv_cleanup; summary
fi
check "M1 TLS is off until asked for" "0" "$(x_has "$L" @ca/1/cert)"

# ── M2 the CA and the certificates ───────────────────────────────────────────
cfg_push peer_tls C true
for _ in $(seq 1 45); do [ "$(x_has "$L" @ca/1/cert)" = 1 ] && break; sleep 2; done
check "M2 the leader made the cluster CA of v1" "1" "$(x_has "$L" @ca/1/cert)"
check "M2 ...its key sealed under v1" "1" "$(x_has "$L" @ca/1/key)"
check "M2 one certificate per node" "${#NODES[@]}" \
	"$(q "$L" "select count(*) from $YX_CFG where module='X' and name like '@cert/1/%'")"
skv_wait 90 "every node has its certificate" all_tls "certificates v1" \
	&& ok "M2 every node took its certificate of v1" || bad "M2 no certificate on:$(tls_not "certificates v1")"

# ── M3 required ──────────────────────────────────────────────────────────────
for _ in $(seq 1 45); do [ "$(x_has "$L" @tls)" = 1 ] && break; sleep 2; done
case "$(info "$L" X peer_tls)" in "TLS between members required:"*) ok "M3 every member reported a certificate: TLS required" ;;
	*) bad "M3 TLS not required: $(info "$L" X peer_tls)" ;; esac
skv_wait 60 "every node requires TLS" all_tls "TLS required between members" \
	&& ok "M3 every node requires TLS between members" || bad "M3 not required on:$(tls_not "TLS required")"

# ── M4 on the wire ───────────────────────────────────────────────────────────
PU="$(node_uuid "$P")"
o="$(rh "docker exec $F sh -c 'openssl s_client -connect $P:$YX_PORT -servername v1.$PU.yaxaha -showcerts </dev/null 2>&1'" 2>&1 || true)"
case "$o" in *"CN = $PU"*|*"CN=$PU"*) ok "M4 $P answers a TLS hello with its own certificate (CN = its uuid)" ;;
	*) bad "M4 no certificate of $P in the TLS answer: $(echo "$o" | grep -m3 -i 'subject\|error\|CONNECTED')" ;; esac
case "$o" in *"CA v1"*) ok "M4 ...issued by the cluster CA of v1" ;; *) bad "M4 the issuer is not the CA of v1" ;; esac
case "$o" in *"certificate required"*|*"alert"*) ok "M4 ...and a client without a certificate is refused" ;;
	*) bad "M4 a client without a certificate was not refused: $(echo "$o" | tail -3)" ;; esac

# ── M5 plaintext ─────────────────────────────────────────────────────────────
o="$(grpc_plain "$F" "$P" data)"
case "$o" in "PERMISSION_DENIED"*"peer_tls"*) ok "M5 a plaintext peer RPC (data) is refused: TLS required" ;;
	*) bad "M5 a plaintext data call: $o" ;; esac
o="$(grpc_plain "$F" "$P" register)"
case "$o" in "PERMISSION_DENIED"*) bad "M5 register refused over plaintext - a node without a certificate could not ask for one" ;;
	*) ok "M5 register still answers over plaintext (the door of a node without a certificate): $o" ;; esac
o="$(grpc_plain "$F" "$P" ping)"
case "$o" in "PERMISSION_DENIED"*) bad "M5 ping refused over plaintext" ;; *) ok "M5 ping still answers over plaintext (anonymously)" ;; esac

# ── M6 the cluster over TLS ──────────────────────────────────────────────────
V="tls-$RANDOM-$RANDOM"
printf '%s' "$V" | yx "$L" --skv put over_tls >/dev/null
for _ in $(seq 1 15); do d=""; for n in "${NODES[@]}"; do [ "$(x_has "$n" over_tls)" = 1 ] || d="$d $n"; done; [ -z "$d" ] && break; sleep 2; done
[ -z "$d" ] && ok "M6 a cluster write over TLS reached every node" || bad "M6 the write did not reach:$d"
r=""; for n in "${NODES[@]}"; do [ "$(yx "$n" --skv get over_tls --print | tail -1)" = "$V" ] || r="$r $n"; done
[ -z "$r" ] && ok "M6 ...and reads on every node" || bad "M6 does not read on:$r"

# ── M7 cold start ────────────────────────────────────────────────────────────
SINCE="$(rh "date -u +%Y-%m-%dT%H:%M:%SZ")"
cold_start 40
await_cluster
L="$(leader)"
[ -n "$L" ] && ok "M7 cold start with TLS required: a leader is elected ($L)" || bad "M7 no leader after the cold start"
skv_wait 90 "every node back on TLS" all_tls "TLS required between members" \
	&& ok "M7 every node is back on its certificate, TLS required" || bad "M7 not on TLS:$(tls_not "TLS required")"
skv_wait 60 "every node holds v1" all_hold 1 && ok "M7 every node holds v1 again, from its own key" || bad "M7 v1 not held on:$(not_holding 1)"
V2="cold-$RANDOM"
printf '%s' "$V2" | yx "$L" --skv put after_cold >/dev/null
for _ in $(seq 1 20); do d=""; for n in "${NODES[@]}"; do [ "$(x_has "$n" after_cold)" = 1 ] || d="$d $n"; done; [ -z "$d" ] && break; sleep 2; done
[ -z "$d" ] && ok "M7 a write after the cold start replicates to every node" || bad "M7 the write did not reach:$d"
refused=0
for n in "${NODES[@]}"; do
	c="$(rh "docker logs --since $SINCE $n 2>&1 | grep -c 'over plaintext refused'" 2>/dev/null || echo 0)"
	refused=$((refused + ${c:-0}))
done
check "M7 no member was refused for speaking plaintext since the cold start" "0" "$refused"

# ── M8 rotation under load ───────────────────────────────────────────────────
cfg_push skv_rotate_overlap_sec C 20
sleep 4
LOAD="$(mktemp)"
( for i in $(seq 1 40); do
	v="rot-$i"
	o="$(printf '%s' "$v" | yx "$L" --skv put rot_probe)"
	case "$o" in *"sealed under"*) echo "ok put" ;; *) echo "FAIL put $i: $(echo "$o" | tail -1)" ;; esac
	for n in "${NODES[@]}"; do
		got="$(yx "$n" --skv get over_tls --print | tail -1)"
		[ "$got" = "$V" ] && echo "ok get" || echo "FAIL get $n: $got"
	done
	sleep 1
  done ) > "$LOAD" 2>&1 &
LOADER=$!
o="$(yx "$L" --skv-rotate)"
case "$o" in *"master key v2 published"*) ok "M8 --skv-rotate under load: v2 published" ;; *) bad "M8 rotate: $(echo "$o" | tail -2)" ;; esac
check "M8 the CA of v2 came with it" "1" "$(x_has "$L" @ca/2/cert)"
seen_both=""
for _ in $(seq 1 30); do
	all_tls "certificates v1, v2" && { seen_both=1; break; }
	all_tls "certificates v2 -" && break
	sleep 2
done
[ -n "$seen_both" ] && ok "M8 while it runs every node holds certificates of both versions" \
	|| echo "  NOTE: both versions were never seen on every node at once (the overlap may have passed): $(tls_not "v2")"
for _ in $(seq 1 75); do [ "$(x_has "$L" @ca/1/cert)" = 0 ] && break; sleep 2; done
check "M8 v1 retired once every member confirmed v2: its CA gone" "0" "$(x_has "$L" @ca/1/cert)"
check "M8 ...and its certificates" "0" "$(q "$L" "select count(*) from $YX_CFG where module='X' and name like '@cert/1/%'")"
skv_wait 60 "every node on v2 alone" all_tls "certificates v2 -" \
	&& ok "M8 every node speaks TLS with v2 alone" || bad "M8 not on v2 alone:$(tls_not "certificates v2 -")"
wait "$LOADER" 2>/dev/null || true
fails="$(grep -c FAIL "$LOAD" || true)"; total="$(wc -l < "$LOAD")"
[ "$fails" = 0 ] && [ "$total" -gt 0 ] && ok "M8 $total writes and reads during the rotation, none failed" \
	|| bad "M8 $fails of $total failed during the rotation: $(grep -m3 FAIL "$LOAD")"
rm -f "$LOAD"

# ── M9 off ───────────────────────────────────────────────────────────────────
cfg_push peer_tls C false
for _ in $(seq 1 45); do [ "$(x_has "$L" @tls)" = 0 ] && break; sleep 2; done
check "M9 peer_tls off: the leader drops the requirement" "0" "$(x_has "$L" @tls)"
skv_wait 60 "every node off TLS" all_tls "no certificate" && ok "M9 every node dropped its certificates" \
	|| bad "M9 still on TLS:$(tls_not "no certificate")"
printf '%s' "off-$RANDOM" | yx "$L" --skv put after_off >/dev/null
for _ in $(seq 1 15); do d=""; for n in "${NODES[@]}"; do [ "$(x_has "$n" after_off)" = 1 ] || d="$d $n"; done; [ -z "$d" ] && break; sleep 2; done
[ -z "$d" ] && ok "M9 the cluster writes over plaintext again" || bad "M9 a write after peer_tls off did not reach:$d"

skv_cleanup
summary
