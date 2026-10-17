#!/usr/bin/env bash
# [skv] Helpers shared by the secret-store tests (34_skv_store.sh, 35_skv_mtls.sh).
# Source after env.sh, not executed.
#
# Every node of the fixture runs with the app key (10_up.sh gives each container
# SECRET=$YX_SECRET), which the store requires, and the config table is synced, so
# the store's rows - module X - replicate.

# yxctl inside a node, as postgres, with the fixture's app key; its output and errors.
# The database by name, `-d`: yxctl's `--db` is a connection URL, and a bare name
# there ran yxctl's own SQL (the --link-* checks) in `postgres` (hier 15_store S3,
# the nightly of 2026-10-17: relation public.yt_config does not exist)
# node $1's app key: the fixture's own rule when it has one (hier: one per node,
# secret_of), else the YX_SECRET every node of this fixture shares
app_secret() { if declare -F secret_of >/dev/null; then secret_of "$1"; else printf '%s' "$YX_SECRET"; fi; }
yx() {
	local n="$1"; shift
	rh "docker exec -i -u postgres -e SECRET=$(app_secret "$n") $n yxctl -d $YX_DB --target $YX_CFG $* 2>&1" 2>&1 || true
}
# without the app key: the container itself carries SECRET (10_up.sh gives it
# to `docker run`), so every exec inherits it unless it is taken away
yx_nokey() {
	local n="$1"; shift
	rh "docker exec -i -u postgres $n env -u SECRET yxctl -d $YX_DB --target $YX_CFG $* 2>&1" 2>&1 || true
}
leader() {
	local n
	for n in "${NODES[@]}"; do case "$(info "$n" O cluster)" in *Leader) echo "$n"; return;; esac; done
}
# through the sync path, on the leader ($L)
cfg_push() {
	q "$L" "begin; delete from $YX_CFG where module='$2' and name='$1';
	        insert into $YX_CFG (name,module,value) values ('$1','$2','$3'); select yt_complete(true); commit;" >/dev/null 2>&1
}
mk_of() { info "$1" J mk; }
tls_of() { info "$1" J peer_tls; }
x_rows() { q "$1" "select count(*) from $YX_CFG where module='X'"; }
x_has() { q "$1" "select count(*) from $YX_CFG where module='X' and name='$2'"; }

# skv_wait <seconds> <description> <command...>: until the command succeeds
skv_wait() {
	local t="$1" what="$2"; shift 2
	local i
	for ((i = 0; i < t; i += 2)); do "$@" && return 0; sleep 2; done
	echo "  (waited ${t}s for: $what)"
	return 1
}

# every node in "$@" (default: all) holds master key version $1 as its current one
all_hold() {
	local v="$1" n; shift
	for n in "${@:-${NODES[@]}}"; do case "$(mk_of "$n")" in "v$v held"*) ;; *) return 1;; esac; done
}
not_holding() { # the nodes that do not hold v$1
	local v="$1" n out=""
	for n in "${NODES[@]}"; do case "$(mk_of "$n")" in "v$v held"*) ;; *) out="$out $n";; esac; done
	printf '%s' "$out"
}

# The pending J rows on the leader: "<uuid> <value>" per line.
pending_j() {
	q "$L" "select name || ' ' || value from $YX_CFG where module='J' and value like 'pending:%'"
}

# yxctl --skv-approve <uuid> on the leader's host - the operator's approval
approve() {
	rh "docker exec -u postgres -e SECRET=$(app_secret "$L") $L yxctl --skv-approve $1 --yes -U postgres -d $YX_DB -t $YX_CFG 2>&1" 2>&1 || true
}

# Approve every node that enrolls, until all of "$@" (default: every node) hold
# master key version $1. A challenge with under 30 s left is waited out: it
# rotates at its expiry, on the node's next ask.
approve_until_held() {
	local v="$1" t="${APPROVE_WAIT:-240}" i u val exp now
	shift
	for ((i = 0; i < t; i += 4)); do
		all_hold "$v" "$@" && return 0
		now="$(q "$L" "select extract(epoch from now())::bigint")"
		while read -r u val; do
			[ -n "$u" ] || continue
			exp="$(printf '%s' "$val" | cut -d: -f3)"
			[ -n "$exp" ] && [ -n "$now" ] && [ $((exp - now)) -ge 30 ] || continue
			case "$(approve "$u")" in *Approved*) echo "  approved $u" ;; esac
		done <<< "$(pending_j)"
		sleep 4
	done
	all_hold "$v" "$@"
}

# The store's rows, approvals and pending entries gone, peer_tls off first: what
# a test leaves behind must be what the baseline restore knows.
skv_cleanup() {
	local n
	if [ "$(q "$L" "select count(*) from $YX_CFG where module='C' and name='peer_tls' and value='true'")" != 0 ]; then
		cfg_push peer_tls C false
		# the leader drops the requirement, then every node its certificates
		for _ in $(seq 1 45); do
			[ "$(x_has "$L" @tls)" = 0 ] && break; sleep 2
		done
	fi
	for n in "${NODES[@]}"; do
		cfg_tx "$n" "skv cleanup" "delete from $YX_CFG where module in ('X','J');
		        delete from $YX_CFG where module='K' and (name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-' or name like 'ca:%');
		        delete from $YX_CFG where module='C' and name in ('peer_tls','skv_rotate_overlap_sec');"
	done
}

# The store on and genesis on the leader, every other node enrolled and approved:
# every node holds v1. Status 1 when not.
skv_setup() {
	cfg_push skv C true
	cfg_push skv_secrets C true
	for _ in $(seq 1 30); do
		local seen="" n
		for n in "${NODES[@]}"; do case "$(mk_of "$n")" in "none - "*|"v"*) ;; *) seen="$seen $n";; esac; done
		[ -z "$seen" ] && break; sleep 2
	done
	# the leader's store comes on with the pushed rows: genesis until it answers
	local g="" i
	for i in $(seq 1 20); do
		g="$(yx "$L" --skv-genesis)"
		case "$g" in *"master key v1 made"*|*"already at master key v1"*) break ;; esac
		sleep 3
	done
	case "$g" in *"master key v1 made"*|*"already at master key v1"*) ;; *) echo "  genesis: $(echo "$g" | tail -1)"; return 1 ;; esac
	approve_until_held 1
}

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
