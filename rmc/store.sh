#!/usr/bin/env bash
# [skv] The three clusters on the secret store and TLS (yt-pgxt skv-secrets.md H2):
# a link is refused unless both clusters run them. Sourced by up.sh, after the
# clusters elect and before the writers start, and by steps.sh for a node added
# at runtime - with the store on, a runtime join waits for the operator's approval.
# Set up as an operator does it (H6): the store and genesis in each cluster, every
# node approved, TLS on, the links declared with yxctl from both ends and each lower
# CA approved on the upper leader with the line yxctl printed; the cluster's CA
# pinned (C skv_ca_root) for every node that joins later (H12).
#
# Source after lib.sh, not executed.

# yxctl inside a node, as postgres, with its own app key: output and errors. The
# database by name, `-d`: yxctl's `--db` is a connection URL, and a bare name there
# ran its own SQL (the --link-* checks) in `postgres` (hier 15_store, 2026-10-17)
yxn() { # yxn <node> <args...>
    local n="$1"; shift
    docker exec -i -u postgres -e SECRET="$(secret_of "$n")" "$(cname "$n")" \
        yxctl -d "$DB" --target "$CFG" "$@" 2>&1 || true
}
# a C row through the cluster, on its leader
cfg_c() { # cfg_c <cluster> <name> <value>
    cfg_tx "$1" "delete from $CFG where module = 'C' and name = '$2'; insert into $CFG (name, module, value) values ('$2', 'C', '$3')"
}
mk_line() { info "$1" J mk; }
tls_line() { info "$1" J peer_tls; }
# every member of the cluster holds master key version $2 / its peer_tls line says $2
holds_v() { local m; for m in $(members "$1"); do case "$(mk_line "$m")" in "v$2 held"*) ;; *) return 1;; esac; done; }
tls_all() { local m; for m in $(members "$1"); do case "$(tls_line "$m")" in *"$2"*) ;; *) return 1;; esac; done; }
not_v() { local m out=""; for m in $(members "$1"); do case "$(mk_line "$m")" in "v$2 held"*) ;; *) out="$out $m($(mk_line "$m"))";; esac; done; printf '%s' "$out"; }
not_tls() { local m out=""; for m in $(members "$1"); do case "$(tls_line "$m")" in *"$2"*) ;; *) out="$out $m";; esac; done; printf '%s' "$out"; }

# Approve on the cluster's leader every join waiting for it, `<uuid> pending:<challenge>:<expires>:...`;
# one whose challenge expires within 30 s is left: it rotates on the node's next ask
approve_pending() { # approve_pending <cluster>
    local c="$1" l u val exp now
    l=$(leader_of "$c"); [ -n "$l" ] || return 1
    now=$(q "$l" <<< "select extract(epoch from now())::bigint")
    while read -r u val; do
        [ -n "$u" ] || continue
        exp=$(printf '%s' "$val" | cut -d: -f3)
        [ -n "$exp" ] && [ -n "$now" ] && [ $((exp - now)) -ge 30 ] || continue
        case "$(yxn "$l" --skv-approve "$u" --yes)" in *Approved*) say "  ....  approved $u on $l" ;; esac
    done <<< "$(q "$l" <<< "select name || ' ' || value from $CFG where module = 'J' and value like 'pending:%'")"
}
# approve, until every member holds master key version $2
approve_until() { # approve_until <cluster> <version> [seconds]
    local c="$1" v="$2" t="${3:-240}" i
    for ((i = 0; i < t; i += 4)); do
        holds_v "$c" "$v" && return 0
        approve_pending "$c"
        sleep 4
    done
    holds_v "$c" "$v"
}

# every member's store on - its master key line answers, held or not
store_on() { local m; for m in $(members "$1"); do case "$(mk_line "$m")" in "none - "*|"v"*) ;; *) return 1;; esac; done; }
# S1 the store on in one cluster: genesis on its leader, every member approved
store_cluster() { # store_cluster <cluster>
    local c="$1" l g i
    cfg_c "$c" skv true && cfg_c "$c" skv_secrets true || return 1
    # genesis only once every member's store is on, as topology's skv_setup waits:
    # made before, v1 is wrapped for no member whose store came on after it, and
    # none of them ever held it ("X row @wrap/1/<uuid> is missing here", the
    # nightly of 2026-10-17, upper's u1 and u3)
    wait_for 60 store_on "$c" || say "  store: $c - not on everywhere yet, genesis anyway"
    l=$(leader_of "$c")
    for i in $(seq 1 20); do
        g=$(yxn "$l" --skv-genesis)
        case "$g" in *"master key v1 made"*|*"already at master key v1"*) break ;; esac
        sleep 3; l=$(leader_of "$c")
    done
    case "$g" in *"master key v1 made"*|*"already at master key v1"*) ;; *) say "  genesis on $c: $(echo "$g" | tail -1)"; return 1 ;; esac
    approve_until "$c" 1
}

# S1-S6: every cluster on the store and TLS, the links set up and approved
store_up() {
    local c l o az hosts root ok_all=0 approval
    for c in "${CLUSTERS[@]}"; do
        store_cluster "$c" && ok "store: $c on the secret store, every node holds v1" \
            || { bad "store: $c - v1 not held on:$(not_v "$c" 1)"; ok_all=1; }
    done
    for c in "${CLUSTERS[@]}"; do cfg_c "$c" peer_tls true || ok_all=1; done
    for c in "${CLUSTERS[@]}"; do
        wait_for 120 tls_all "$c" "certificates v1" && ok "store: $c - every node holds its certificate of v1" \
            || { bad "store: $c - no certificate on:$(not_tls "$c" "certificates v1")"; ok_all=1; }
    done
    # the links, from both ends (H6): the upper names its lowers, each lower pins the upper's root
    l=$(leader_of upper)
    for az in eastc westc; do
        o=$(yxn "$l" --link-lower "$az")
        case "$o" in *": CA v1 SHA256:"*) ok "store: --link-lower $az on the upper leader $l" ;;
            *) bad "store: --link-lower $az: $(echo "$o" | tail -2 | tr '\n' ' ')"; ok_all=1 ;; esac
    done
    root=$(printf '%s\n' "$o" | sed -n 's/.*: CA v1 \(SHA256:[A-Za-z0-9+\/]*\).*/\1/p' | head -1)
    [ -n "$root" ] || { bad "store: the upper's root not printed"; return 1; }
    for c in east west; do
        l=$(leader_of "$c")
        hosts=$(q "$l" <<< "select value from $CFG where module = 'Z' and name = 'top.host'")
        o=$(yxn "$l" --link-upper "top=$hosts" --link-root "$root")
        approval=$(printf '%s\n' "$o" | grep -o -- '--skv-approve [0-9a-f-]* --fingerprint SHA256:[A-Za-z0-9+/]*' | head -1)
        [ -n "$approval" ] || { bad "store: --link-upper on $c: $(echo "$o" | tail -2 | tr '\n' ' ')"; ok_all=1; continue; }
        # the upper's operator approves the lower's CA with the line it printed (H4)
        for _ in $(seq 1 20); do
            case "$(yxn "$(leader_of upper)" $approval --yes)" in *Approved*) ok "store: $c's CA approved on the upper leader"; break ;; esac
            sleep 3
        done
    done
    for c in east west; do
        wait_for 180 tls_all "$c" "CA countersigned by the upper cluster" \
            && ok "store: $c's CA countersigned by the upper cluster" \
            || { bad "store: $c not countersigned on:$(not_tls "$c" "countersigned")"; ok_all=1; }
    done
    # neighbours under one upper: its countersignature approved both (H3)
    l=$(leader_of east)
    hosts=$(q "$l" <<< "select value from $CFG where module = 'Z' and name = 'westc.host'")
    o=$(yxn "$l" --link-neighbor "westc=$hosts")
    case "$o" in *"--link-neighbor eastc="*) ok "store: --link-neighbor westc on east's leader" ;;
        *) bad "store: --link-neighbor westc: $(echo "$o" | tail -2 | tr '\n' ' ')"; ok_all=1 ;; esac
    # a node that joins later takes the cluster's certificate bundle only through a pinned CA (H12)
    for c in "${CLUSTERS[@]}"; do
        l=$(leader_of "$c")
        root=$(info "$l" X @ca/1)
        [ -n "$root" ] && cfg_c "$c" skv_ca_root "$root" && ok "store: $c's CA pinned for its joiners ($root)" \
            || { bad "store: $c's CA not pinned"; ok_all=1; }
    done
    for c in "${CLUSTERS[@]}"; do
        wait_for 120 required_tls "$c" && ok "store: $c requires TLS, its links included" \
            || { bad "store: $c does not require TLS: $(info "$(leader_of "$c")" X peer_tls)"; ok_all=1; }
    done
    return $ok_all
}
required_tls() { case "$(info "$(leader_of "$1")" X peer_tls)" in "TLS between members required:"*) return 0;; esac; return 1; }

# A node added at runtime: its join approved on the leader, until it holds the
# cluster's current master key and its certificate
store_join() { # store_join <cluster> <node>
    local c="$1" n="$2" v i
    v=$(info "$(leader_of "$c")" J mk | sed -n 's/^v\([0-9]*\) held.*/\1/p')
    v=${v:-1}
    for ((i = 0; i < ${RMC_WAIT:-180}; i += 4)); do
        case "$(mk_line "$n")" in "v$v held"*) break ;; esac
        approve_pending "$c"
        sleep 4
    done
    case "$(mk_line "$n")" in "v$v held"*) ok "$n: its join approved, it holds master key v$v" ;;
        *) bad "$n: no master key v$v after its join: $(mk_line "$n")"; return 1 ;; esac
    wait_for 120 node_tls "$n" && ok "$n: holds its certificate" || bad "$n: no certificate: $(tls_line "$n")"
}
node_tls() { case "$(tls_line "$1")" in *"certificates v"*) return 0;; esac; return 1; }
