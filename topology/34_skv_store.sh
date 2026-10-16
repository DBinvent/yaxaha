#!/usr/bin/env bash
# [skv] The secret store, phases P3-P5 (yt-pgxt ytserv/skv-secrets.md): the
# cluster master key made by the operator on the leader (Protocol A), values
# sealed under it - put, get, rm - through yxctl over ytserv's unix socket; every
# other node enrolling and approved (P4); rotation, retirement, recovery (P5).
#
# Every node of this fixture runs with the app key (10_up.sh gives each container
# SECRET=$YX_SECRET), which the store requires: the node keypair is encrypted with
# it, and every call that changes the store or returns a value carries a MAC under
# it. The config table is synced (10_up.sh), so the store's rows - module X -
# replicate.
#
# Only the leader gets a wrap at genesis: a follower is wrapped for once it
# enrolls (skv_enroll, every 10 s while it holds no key) and the operator approves
# its key. So K3-K10 put and read on the leader, and a follower is asserted to
# say, truthfully, that it does not hold the key yet; K11 approves them.
#
# ## What is asserted
#
# K1 the store off -> on: every node says "no master key in this cluster yet"
# K2 genesis on a follower is refused, naming the leader
# K3 genesis on the leader: @keyver 1, a canary, @genesis, the leader's wrap and
#    K row; the leader holds v1; every node has the same X rows; a follower says
#    v1 is not held and why
# K4 a second genesis changes nothing ("already at master key v1")
# K5 put / get round trip on the leader; get refused on a follower
# K6 the plaintext is in no config row, on any node; the X row is ciphertext
# K7 yt_info('X') lists the name and version, never the value; rm removes it
#    everywhere
# K8 a call without the app key's MAC is refused
# K9 ytserv mirrors every row but @genesis into its own etcd under /secret/, and
#    etcd refuses it - a get, a range over everything - to a remote caller. (A node
#    reaches its own etcd only over its own address here - ytserv binds the N
#    row's host, not loopback - so "local" is in-process, and the mirror is read
#    from ytserv's side, yt_info('X') row mirror.)
# K10 the leader restarted holds v1 again (the canary, at boot)
# K11 every other node enrolls - a pending J row marked (enroll), the node not
#     held out of the cluster meanwhile - and once approved holds v1 and reads
# K12 --skv-rotate: v2 published, a second rotate refused while it runs; readers
#     on every node never fail; every envelope re-sealed under v2; v1 retired only
#     after every node confirmed v2 and the overlap passed - its canary and wraps
#     gone, the recovery wrap kept
# K13 --skv-retire <node>: its K row, @pub and wraps deleted, its key in @crl, v3
#     wrapped for everyone else; it holds no v3 and reads nothing re-sealed; the
#     honest converse is printed; approved again, it holds v3
# K14 recovery: a genesis with a recovery key; every node loses its node.key; the
#     leader recovers with the recovery key; the others enroll, are approved, and
#     every value reads again
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/skv_lib.sh"
echo "== skv store: the cluster master key and the secrets sealed under it =="

VOTERS=()
for _n in "${NODES[@]}"; do is_spare_node "$_n" || VOTERS+=("$_n"); done

cleanup() { skv_cleanup; }

await_cluster
L="$(leader)"
[ -n "$L" ] && ok "the cluster has a leader ($L)" || { bad "no leader"; summary; }
F=""
for n in "${VOTERS[@]}"; do [ "$n" = "$L" ] || { F="$n"; break; }; done
cleanup

# ── K1 on ────────────────────────────────────────────────────────────────────
cfg_push skv C true
cfg_push skv_secrets C true
seen=""
for _ in $(seq 1 30); do
	seen=""
	for n in "${NODES[@]}"; do case "$(mk_of "$n")" in "none - no master key in this cluster yet"*) ;; *) seen="$seen $n";; esac; done
	[ -z "$seen" ] && break; sleep 2
done
[ -z "$seen" ] && ok "K1 the store is on everywhere, and no node holds a master key yet" \
	|| bad "K1 not every node reports the store on and empty:$seen ($(mk_of "${seen# }"))"

# ── K2 genesis on a follower ─────────────────────────────────────────────────
o="$(yx "$F" --skv-genesis)"
case "$o" in *"not the leader"*) ok "K2 genesis on the follower $F is refused, naming the leader" ;;
	*) bad "K2 genesis on a follower was not refused as not-the-leader: $(echo "$o" | tail -2)" ;; esac
[ "$(x_rows "$F")" = 0 ] && ok "K2 ...and wrote nothing" || bad "K2 a refused genesis left X rows"

# ── K3 genesis on the leader ─────────────────────────────────────────────────
o="$(yx "$L" --skv-genesis)"
case "$o" in *"master key v1 made"*) ok "K3 genesis on the leader $L: $(echo "$o" | grep -m1 'master key v1')" ;;
	*) bad "K3 genesis on the leader failed: $(echo "$o" | tail -3)"; cleanup; summary ;; esac
check "K3 @keyver is 1" "1" "$(q "$L" "select value from $YX_CFG where module='X' and name='@keyver'")"
check "K3 a canary and a genesis record" "2" \
	"$(q "$L" "select count(*) from $YX_CFG where module='X' and name in ('@canary/1','@genesis')")"
LU="$(node_uuid "$L")"
check "K3 the leader's own wrap" "1" "$(q "$L" "select count(*) from $YX_CFG where module='X' and name='@wrap/1/$LU'")"
case "$(q "$L" "select value from $YX_CFG where module='K' and name='$LU'")" in
	SHA256:*) ok "K3 the leader's approval record (K row) names its key" ;;
	*) bad "K3 no K row for the leader" ;; esac
for _ in $(seq 1 15); do case "$(mk_of "$L")" in "v1 held"*) break;; esac; sleep 2; done
check "K3 the leader holds v1" "v1 held (v1)" "$(mk_of "$L")"
check "K3 the canary is ok" "ok" "$(info "$L" J canary)"
want="$(x_rows "$L")"
for _ in $(seq 1 15); do d=""; for n in "${NODES[@]}"; do [ "$(x_rows "$n")" = "$want" ] || d="$d $n"; done; [ -z "$d" ] && break; sleep 2; done
[ -z "$d" ] && ok "K3 every node has the same $want X rows" || bad "K3 the X rows did not reach:$d"
# the follower re-reads its store on its own tick once the rows arrived
for _ in $(seq 1 10); do case "$(mk_of "$F")" in *"v1 is not held"*) break;; esac; sleep 2; done
case "$(mk_of "$F")" in *"v1 is not held"*"@wrap/1/"*) ok "K3 the follower $F says v1 is not held, and why: $(mk_of "$F")" ;;
	*) bad "K3 the follower's answer is not 'v1 is not held': $(mk_of "$F")" ;; esac

# ── K4 a second genesis ──────────────────────────────────────────────────────
o="$(yx "$L" --skv-genesis)"
case "$o" in *"already at master key v1"*) ok "K4 a second genesis changes nothing" ;;
	*) bad "K4 a second genesis was not a no-op: $(echo "$o" | tail -2)" ;; esac
check "K4 still version 1" "1" "$(q "$L" "select value from $YX_CFG where module='X' and name='@keyver'")"

# ── K5 put / get ─────────────────────────────────────────────────────────────
V="s3cret-$RANDOM-$RANDOM"
o="$(printf '%s' "$V" | yx "$L" --skv put db_password)"
case "$o" in *"sealed under master key v1"*) ok "K5 put on the leader: db_password sealed under v1" ;;
	*) bad "K5 put failed: $(echo "$o" | tail -2)" ;; esac
check "K5 get on the leader returns the value" "$V" "$(yx "$L" --skv get db_password --print | tail -1)"
o="$(yx "$F" --skv get db_password --print)"
case "$o" in *"not held here"*) ok "K5 get on the follower is refused: v1 not held there" ;;
	*) bad "K5 get on a follower was not refused as not-held: $(echo "$o" | tail -1)" ;; esac

# ── K6 no plaintext ──────────────────────────────────────────────────────────
for _ in $(seq 1 10); do [ "$(q "$F" "select count(*) from $YX_CFG where module='X' and name='db_password'")" = 1 ] && break; sleep 2; done
leak=""
for n in "${NODES[@]}"; do
	[ "$(q "$n" "select count(*) from $YX_CFG where value like '%$V%' or name like '%$V%'")" = 0 ] || leak="$leak $n"
done
[ -z "$leak" ] && ok "K6 the plaintext is in no config row, on any node" || bad "K6 the plaintext is in the config table on:$leak"
check "K6 the X row reached the follower, as ciphertext" "1" \
	"$(q "$F" "select count(*) from $YX_CFG where module='X' and name='db_password' and value <> '$V'")"

# ── K7 ls, rm ────────────────────────────────────────────────────────────────
case "$(info "$L" X db_password)" in "v1 seq "*" B") ok "K7 yt_info('X') names it with its version, not its value" ;;
	*) bad "K7 yt_info('X') db_password: $(info "$L" X db_password)" ;; esac
case "$(yx "$L" --skv ls)" in *"db_password = v1 seq"*) ok "K7 yxctl --skv ls lists it" ;; *) bad "K7 --skv ls does not list it" ;; esac
o="$(yx "$L" --skv rm db_password)"
case "$o" in *"removed"*) ok "K7 rm on the leader" ;; *) bad "K7 rm failed: $(echo "$o" | tail -1)" ;; esac
for _ in $(seq 1 10); do d=""; for n in "${NODES[@]}"; do [ "$(q "$n" "select count(*) from $YX_CFG where module='X' and name='db_password'")" = 0 ] || d="$d $n"; done; [ -z "$d" ] && break; sleep 2; done
[ -z "$d" ] && ok "K7 ...and it is gone everywhere" || bad "K7 the removal did not reach:$d"

# ── K8 no app key, no call ───────────────────────────────────────────────────
o="$(printf 'x' | yx_nokey "$L" --skv put other)"
case "$o" in *"app key"*) ok "K8 a put without the app key is refused before anything is sent" ;;
	*) bad "K8 a put without the app key was not refused: $(echo "$o" | tail -1)" ;; esac

# ── K9 the etcd mirror ───────────────────────────────────────────────────────
printf '%s' "$V" | yx "$L" --skv put mirror_probe >/dev/null
etcd_py() { # etcd_py <run on node> <etcd host>: what the mirror shows that caller
	rh "docker exec -i $1 python3 -" <<EOF 2>&1 || true
import etcd3
c = etcd3.client(host='$2', port=$YX_PORT)
try:
    v, _ = c.get('/secret/encrypted/mirror_probe')
    print('get', 'found' if v else 'none')
except Exception as e:
    print('get', 'refused' if 'local connection' in str(e) else 'error ' + str(e)[:80])
try:
    keys = [m.key.decode() for _, m in c.get_all()]
    print('range', 'secret' if any(k.startswith('/secret/') for k in keys) else 'clean', len(keys))
except Exception as e:
    print('range', 'refused' if 'local connection' in str(e) else 'error ' + str(e)[:80])
EOF
}
want=$(( $(x_rows "$L") - 1 )) # every row but @genesis
for _ in $(seq 1 15); do [ "$(info "$L" X mirror)" = "$want key(s) under /secret/" ] && break; sleep 2; done
check "K9 the leader mirrors its X rows into its etcd" "$want key(s) under /secret/" "$(info "$L" X mirror)"
remote_view="$(etcd_py "$F" "$L")"
case "$remote_view" in *"get refused"*) ok "K9 a remote get of it is refused" ;; *) bad "K9 a remote get: $remote_view" ;; esac
case "$remote_view" in *"range clean"*|*"range refused"*) ok "K9 a remote range over everything returns no /secret/ key" ;;
	*) bad "K9 a remote range: $remote_view" ;; esac

# ── K10 restart ──────────────────────────────────────────────────────────────
rh "docker restart $L >/dev/null"
node_ready "$L" 120 || true
for _ in $(seq 1 30); do case "$(mk_of "$L")" in "v1 held"*) break;; esac; sleep 2; done
check "K10 the restarted $L holds v1 again, from its own rows and key" "v1 held (v1)" "$(mk_of "$L")"
check "K10 its canary is ok" "ok" "$(info "$L" J canary)"
check "K10 and reads the value" "$V" "$(yx "$L" --skv get mirror_probe --print | tail -1)"

# ── K11 enroll, approve ──────────────────────────────────────────────────────
# K10's restart may have moved leadership - to a node genesis never wrapped for.
# That leader enrolls with itself, and once approved a member holding v1 wraps it
# for it (skv_wrap): so K11 works against whichever node leads now.
await_cluster
OLD_L="$L"
L="$(leader)"
echo "  leader after K10: $L (genesis ran on $OLD_L)"
# Make it so either way: leadership moved to a node that holds no key (operator
# force-election, yt_info('e:<node>')) - the case where only a holder can wrap.
case "$(mk_of "$L")" in "v1 held"*)
	for n in "${VOTERS[@]}"; do case "$(mk_of "$n")" in "v1 held"*) ;; *) NL="$n"; break;; esac; done
	# the target by its address: force_leader_to matches a peer's host:port, or
	# the short uuid label - not a full uuid, not a container name
	NIP="$(rh "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $NL")"
	echo "  force-election to $NL ($NIP): $(q "$L" "select yt_info('e:$NIP:$YX_PORT')" 2>&1 | cut -c1-200)"
	for _ in $(seq 1 45); do [ "$(leader)" = "$NL" ] && break; sleep 2; done
	await_cluster
	L="$(leader)"
	echo "  leadership moved to $L, which holds no key"
	;;
esac
check "K11 the leader holds no key now (the one genesis wrapped for does not lead)" "" \
	"$(case "$(mk_of "$L")" in "v1 held"*) echo held;; esac)"
F=""
for n in "${VOTERS[@]}"; do
	[ "$n" = "$L" ] && continue
	case "$(mk_of "$n")" in "v1 held"*) ;; *) F="$n"; break;; esac
done
OTHERS=()
for n in "${NODES[@]}"; do [ "$n" = "$L" ] || OTHERS+=("$n"); done
LU="$(node_uuid "$L")"
for _ in $(seq 1 30); do case "$(info "$L" J "$LU")" in *"(enroll)"*) break;; esac; sleep 2; done
case "$(info "$L" J "$LU")" in *"(enroll)"*) ok "K11 the leader $L, without v1, enrolled with itself" ;;
	*) bad "K11 the leader $L did not enroll with itself: $(info "$L" J "$LU")" ;; esac
FU="$(node_uuid "$F")"
for _ in $(seq 1 30); do case "$(info "$L" J "$FU")" in *"(enroll)"*) break;; esac; sleep 2; done
case "$(info "$L" J "$FU")" in *"(enroll)"*) ok "K11 the follower $F enrolled: the leader holds an enroll entry for it" ;;
	*) bad "K11 no enroll entry for $F on the leader: $(info "$L" J "$FU")" ;; esac
# not held out: a pending enroll is no pending join
case "$(q "$L" "select count(*) from $YX_CFG where module='J' and name='$FU' and value like 'pending:%'")" in
	1) ok "K11 ...recorded as a J row the operator reads" ;; *) bad "K11 no pending J row for $F" ;; esac
# a pending enroll holds nobody out of quorum: a cluster write (a config row)
# commits and reaches the follower meanwhile
cfg_push skv_reseal_batch C 49
for _ in $(seq 1 15); do [ "$(q "$F" "select value from $YX_CFG where module='C' and name='skv_reseal_batch'")" = 49 ] && break; sleep 2; done
check "K11 a cluster write commits while every follower's enroll is pending" "49" \
	"$(q "$F" "select value from $YX_CFG where module='C' and name='skv_reseal_batch'")"
# and a leader without the key says so rather than seal under nothing
o="$(printf 'x' | yx "$L" --skv put keyless)"
case "$o" in *"does not hold the current master key"*) ok "K11 a put on the leader without the key is refused, saying why" ;;
	*) bad "K11 a put on a keyless leader: $(echo "$o" | tail -1)" ;; esac
if approve_until_held 1; then
	ok "K11 approved: every node holds v1 (a leader without it wrapped for by a holder)"
else
	bad "K11 not every node holds v1 after approval:$(not_holding 1)"
fi
r=""
for n in "${NODES[@]}"; do [ "$(yx "$n" --skv get mirror_probe --print | tail -1)" = "$V" ] || r="$r $n"; done
[ -z "$r" ] && ok "K11 every node reads the value" || bad "K11 the value does not read on:$r"

# ── K12 rotate ───────────────────────────────────────────────────────────────
cfg_push skv_rotate_overlap_sec C 20
sleep 4
READS="$(mktemp)"
( for i in $(seq 1 45); do
	for n in "${NODES[@]}"; do
		got="$(yx "$n" --skv get mirror_probe --print | tail -1)"
		[ "$got" = "$V" ] && echo "ok" || echo "FAIL $n: $got"
	done
	sleep 1
  done ) > "$READS" 2>&1 &
READER=$!
o="$(yx "$L" --skv-rotate)"
case "$o" in *"master key v2 published"*) ok "K12 --skv-rotate: v2 published" ;; *) bad "K12 rotate: $(echo "$o" | tail -2)" ;; esac
o="$(yx "$L" --skv-rotate)"
case "$o" in *"rotation is in progress"*) ok "K12 a second rotate while it runs is refused" ;;
	*) bad "K12 a second rotate was not refused: $(echo "$o" | tail -1)" ;; esac
skv_wait 90 "every node holds v2" all_hold 2 && ok "K12 every node holds v2" || bad "K12 v2 not held on:$(not_holding 2)"
for _ in $(seq 1 30); do case "$(info "$L" X mirror_probe)" in "v2 seq "*) break;; esac; sleep 2; done
case "$(info "$L" X mirror_probe)" in "v2 seq "*) ok "K12 the envelope is re-sealed under v2" ;;
	*) bad "K12 not re-sealed: $(info "$L" X mirror_probe)" ;; esac
for _ in $(seq 1 60); do [ "$(x_has "$L" @canary/1)" = 0 ] && break; sleep 2; done
check "K12 v1 retired: its canary gone" "0" "$(x_has "$L" @canary/1)"
check "K12 ...and its wraps, but the recovery one" "0" \
	"$(q "$L" "select count(*) from $YX_CFG where module='X' and name like '@wrap/1/%' and name <> '@wrap/1/recovery'")"
for _ in $(seq 1 15); do d=""; for n in "${NODES[@]}"; do [ "$(mk_of "$n")" = "v2 held (v2)" ] || d="$d $n"; done; [ -z "$d" ] && break; sleep 2; done
[ -z "$d" ] && ok "K12 every node dropped v1 on apply" || bad "K12 still holding v1:$d"
wait "$READER" 2>/dev/null || true
fails="$(grep -c FAIL "$READS" || true)"; total="$(wc -l < "$READS")"
[ "$fails" = 0 ] && [ "$total" -gt 0 ] && ok "K12 $total reads on every node during the rotation, none failed" \
	|| bad "K12 $fails of $total reads failed during the rotation: $(grep -m2 FAIL "$READS")"
rm -f "$READS"

# ── K13 retire ───────────────────────────────────────────────────────────────
R="${OTHERS[${#OTHERS[@]}-1]}"
RU="$(node_uuid "$R")"
o="$(yx "$L" --skv-retire "$RU" --yes)"
case "$o" in *"retired"*"master key v3 published"*) ok "K13 --skv-retire $R: retired, v3 published" ;;
	*) bad "K13 retire: $(echo "$o" | tail -3)" ;; esac
case "$o" in *"can still open every envelope it already has"*) ok "K13 ...and the honest converse is printed" ;;
	*) bad "K13 no honest converse in: $(echo "$o" | tail -1)" ;; esac
check "K13 its K row is gone" "0" "$(q "$L" "select count(*) from $YX_CFG where module='K' and name='$RU'")"
check "K13 its @pub and every wrap are gone" "0" \
	"$(q "$L" "select count(*) from $YX_CFG where module='X' and (name='@pub/$RU' or name like '@wrap/%/$RU')")"
check "K13 its key is listed in @crl" "1" "$(x_has "$L" "@crl/$RU")"
REST=(); for n in "${NODES[@]}"; do [ "$n" = "$R" ] || REST+=("$n"); done
skv_wait 90 "the others hold v3" all_hold 3 "${REST[@]}" && ok "K13 every other node holds v3" \
	|| bad "K13 v3 not held on:$(not_holding 3)"
case "$(mk_of "$R")" in "v3 held"*) bad "K13 the retired $R holds v3" ;; *) ok "K13 the retired $R holds no v3: $(mk_of "$R")" ;; esac
printf '%s' "$V-after" | yx "$L" --skv put after_retire >/dev/null
for _ in $(seq 1 15); do [ "$(x_has "$R" after_retire)" = 1 ] && break; sleep 2; done
o="$(yx "$R" --skv get after_retire --print)"
case "$o" in *"not held here"*) ok "K13 a value put after the retirement does not read on $R" ;;
	*) bad "K13 $R read a value put after its retirement: $(echo "$o" | tail -1)" ;; esac
if approve_until_held 3; then ok "K13 approved again, $R holds v3 (a fresh K row)"; else bad "K13 $R not re-admitted:$(not_holding 3)"; fi
check "K13 ...and its @crl row went with the new approval" "0" "$(x_has "$L" "@crl/$RU")"

# ── K14 recovery ─────────────────────────────────────────────────────────────
rh "docker exec $L sh -c 'openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out /tmp/rk.pem \
	&& openssl pkey -in /tmp/rk.pem -pubout -out /tmp/rk.pub && chmod 644 /tmp/rk.pem /tmp/rk.pub'" >/dev/null 2>&1
RK="$(rh "docker exec $L cat /tmp/rk.pem")"
o="$(yx "$L" --skv-genesis --discard --recovery-pub /tmp/rk.pub --yes)"
case "$o" in *"master key v1 made"*"recovery wrap is kept"*) ok "K14 genesis --discard with a recovery key: v1 again" ;;
	*) bad "K14 genesis with a recovery key: $(echo "$o" | tail -2)" ;; esac
skv_wait 90 "every node holds the new v1" all_hold 1 || true
printf '%s' "$V-rec" | yx "$L" --skv put recovered >/dev/null
# every node loses its node.key (fs_dir is /var/yaxaha here; restart_all wipes
# the cluster WAL there too), restarted together
for n in "${NODES[@]}"; do rh "docker exec $n sh -c 'find /var/yaxaha -name node.key -delete'" >/dev/null 2>&1 || true; done
restart_all 40
await_cluster
L="$(leader)"
echo "  leader after the restart: $L"
# each node made a new keypair at boot and opened nothing with it
for _ in $(seq 1 30); do d=""; for n in "${NODES[@]}"; do [ -n "$(mk_of "$n")" ] || d="$d $n"; done; [ -z "$d" ] && break; sleep 2; done
held_any=""; for n in "${NODES[@]}"; do case "$(mk_of "$n")" in "v1 held"*) held_any="$held_any $n";; esac; done
[ -z "$held_any" ] && ok "K14 with every node.key gone, no node holds the master key" || bad "K14 still held on:$held_any"
printf '%s\n' "$RK" | rh "docker exec -i $L sh -c 'cat > /tmp/rk.pem && chmod 644 /tmp/rk.pem'"
o="$(yx "$L" --skv-recover --recovery-key /tmp/rk.pem)"
case "$o" in *"recovered v1 with the recovery key"*) ok "K14 --skv-recover on the leader $L: v1 recovered" ;;
	*) bad "K14 recover: $(echo "$o" | tail -2)" ;; esac
skv_wait 30 "the leader holds v1" all_hold 1 "$L" && ok "K14 the leader holds v1 again" || bad "K14 the leader: $(mk_of "$L")"
if approve_until_held 1; then ok "K14 the others enrolled with their new keys, approved: every node holds v1"; else bad "K14 not held on:$(not_holding 1)"; fi
r=""
for n in "${NODES[@]}"; do [ "$(yx "$n" --skv get recovered --print | tail -1)" = "$V-rec" ] || r="$r $n"; done
[ -z "$r" ] && ok "K14 every node reads the value sealed before the loss" || bad "K14 the value does not read on:$r"

cleanup
summary
