#!/usr/bin/env bash
# [P5] Build and start the git server, and put its deploy key on every node.
#
# Run after 10_up.sh: the nodes must exist before the key can be installed into
# them. Idempotent — re-running reuses the key pair if it is already there, so a
# node added later gets the same one.
#
# The PRIVATE key is generated on the docker host and copied into the nodes with
# `docker cp`; it never enters an image layer. An image is cached and often
# pushed, and a key baked into one has been handed to everybody who can pull it.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
echo "== git server =="

KEYDIR="${YX_KEYDIR:-/tmp/yxtopo-git}"
IMG="${YX_GIT_IMAGE:-yxtopo-gitsrv}"

rh "mkdir -p $KEYDIR"
# ssh-keygen refuses to overwrite, so ask only when it is not there.
rh "test -f $KEYDIR/id_ed25519 || ssh-keygen -t ed25519 -N '' -C yxtopo -f $KEYDIR/id_ed25519 >/dev/null"
PUB="$(rh "cat $KEYDIR/id_ed25519.pub")"
[ -n "$PUB" ] || { bad "no deploy key"; summary; }

echo "  building $IMG..."
rh "cd - >/dev/null 2>&1; true"
# The build context is this directory, shipped to the docker host the same way
# 00_build.sh ships the node context.
tar -C "$(dirname "${BASH_SOURCE[0]}")" -cf - Dockerfile.gitsrv gitsrv-entrypoint.sh \
	| rh "mkdir -p /tmp/yxgitsrv && tar -C /tmp/yxgitsrv -xf - && \
	      docker build -q -f /tmp/yxgitsrv/Dockerfile.gitsrv -t $IMG /tmp/yxgitsrv" \
	| tail -1

rh "docker network inspect $YX_NET >/dev/null 2>&1 || docker network create $YX_NET >/dev/null"
rh "docker rm -f gitsrv >/dev/null 2>&1; true"
rh "docker run -d --name gitsrv --hostname gitsrv --network $YX_NET \
	-e DEPLOY_PUBKEY='$PUB' $IMG >/dev/null"

echo "  waiting for sshd..."
# The entrypoint seeds fn.git, then sql.git, then prints this line and starts sshd.
# Waiting for fn.git alone read the listing while sql.git was still being seeded
# (nightly 20261015: "got [fn.git]").
for _ in $(seq 1 30); do
	out="$(rh "docker logs gitsrv 2>&1" || true)"
	case "$out" in *"[gitsrv] repositories:"*) break;; esac
	sleep 1
done
check "the fixture repositories exist" "fn.git sql.git" \
	"$(rh "docker exec gitsrv sh -c 'ls /srv/git'" | tr '\n' ' ' | sed 's/ $//')"

# ── the deploy key, and a known_hosts entry, on every node ──────────────────
#
# `rppd_git_ssh_key` and rdbm's `source_git_ssh_key` name a PATH, node-local by
# design (a key path replicated cluster-wide names a different file on every
# node), so each node needs its own copy.
for n in "${NODES[@]}"; do
	rh "docker exec $n mkdir -p /var/yaxaha/ssh"
	rh "docker cp $KEYDIR/id_ed25519 $n:/var/yaxaha/ssh/git_key"
	rh "docker exec $n chown postgres:postgres /var/yaxaha/ssh/git_key"
	rh "docker exec $n chmod 600 /var/yaxaha/ssh/git_key"
done
echo "  deploy key installed on ${#NODES[@]} node(s) at /var/yaxaha/ssh/git_key"

# One node proves the whole path end to end. `StrictHostKeyChecking=accept-new`
# is what both ssh_command implementations use, so this exercises the real
# first-contact behaviour rather than a pre-seeded known_hosts.
probe="${NODES[0]}"
out="$(rh "docker exec -u postgres $probe env \
	GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/var/yaxaha/ssh/known_hosts -o IdentitiesOnly=yes -i /var/yaxaha/ssh/git_key' \
	git ls-remote ssh://git@gitsrv/srv/git/fn.git" 2>&1 | head -3)"
case "$out" in
	*refs/heads/*) ok "$probe can clone over ssh from gitsrv" ;;
	*) bad "$probe cannot reach gitsrv over ssh — [$out]" ;;
esac

echo
echo "  remotes for the tests:"
echo "    ssh://git@gitsrv/srv/git/fn.git    (rppd_function.source_git)"
echo "    ssh://git@gitsrv/srv/git/sql.git   (sg_history.source_git)"
echo "    rppd_git_ssh_key = /var/yaxaha/ssh/git_key"
summary
