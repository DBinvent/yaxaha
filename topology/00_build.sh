#!/usr/bin/env bash
# [topology] Build the node image on the docker host, from the dev host's deb.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

DEB="${YAXAHA_DEB:-$(ls -t "$REPO_ROOT"/target/debian/yaxaha_*_amd64.deb 2>/dev/null | head -1)}"
[ -n "$DEB" ] || { echo "no deb in target/debian — run: cargo deb -p yxctl --variant pg18 --no-build" >&2; exit 1; }
echo "Using $(basename "$DEB")"

STAGE=/tmp/yxtopo-build
rh "rm -rf $STAGE && mkdir -p $STAGE"
if [ "$YX_HOST" = "local" ]; then
	cp "$DEB" $STAGE/yaxaha.deb; cp Dockerfile node-entrypoint.sh pg_setup.sql $STAGE/
else
	scp -q "$DEB" "$YX_HOST:$STAGE/yaxaha.deb"
	scp -q Dockerfile node-entrypoint.sh pg_setup.sql "$YX_HOST:$STAGE/"
fi

echo "Building image $YX_IMAGE (first run pulls ubuntu:24.04 + PGDG postgresql-18)..."
rh "cd $STAGE && docker build -q -t $YX_IMAGE ." | tail -1
rh "docker image inspect $YX_IMAGE --format '  image {{.Id}} {{.Size}} bytes'"
