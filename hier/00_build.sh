#!/usr/bin/env bash
# [tpl2] Build the hierarchical fixture's node image from THIS tree's deb.
#
# A copy of ../topology/00_build.sh with one deliberate difference: it tags
# `$YX_IMAGE`, which defaults to `yxhier-node` rather than `yxtopo-node`. The two
# fixtures are built from different branches in different worktrees, and tagging
# one image from the other's tree swaps the binary under a suite nobody is looking
# at - which is a very quiet way to invalidate a passing run.
#
# The Dockerfile and entrypoint are shared, because nothing about the node itself
# differs; only the cluster wiring does, and that is config.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

TOPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../topology" && pwd)"

DEB="${YAXAHA_DEB:-$(ls -t "$REPO_ROOT"/target/debian/yaxaha_*_amd64.deb 2>/dev/null | head -1)}"
[ -n "$DEB" ] || { echo "no deb in target/debian — run: cargo deb -p yxctl --variant pg18 --no-build" >&2; exit 1; }
echo "Using $(basename "$DEB")"

STAGE=/tmp/yxhier-build
rh "rm -rf $STAGE && mkdir -p $STAGE"
if [ "$YX_HOST" = "local" ]; then
	cp "$DEB" $STAGE/yaxaha.deb
	cp "$TOPO"/Dockerfile "$TOPO"/node-entrypoint.sh "$TOPO"/pg_setup.sql $STAGE/
else
	scp -q "$DEB" "$YX_HOST:$STAGE/yaxaha.deb"
	scp -q "$TOPO"/Dockerfile "$TOPO"/node-entrypoint.sh "$TOPO"/pg_setup.sql "$YX_HOST:$STAGE/"
fi

echo "Building image $YX_IMAGE..."
rh "cd $STAGE && docker build -q -t $YX_IMAGE ." | tail -1
rh "docker image inspect $YX_IMAGE --format '  image {{.Id}} {{.Size}} bytes'"
