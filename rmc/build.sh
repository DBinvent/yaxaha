#!/usr/bin/env bash
# Build the node image (rmc-node) from a yaxaha package.
#
#   ./build.sh                 # YAXAHA_DEB from .env / the environment
#
# YAXAHA_DEB: a yaxaha_<version>_amd64.deb for PostgreSQL 18, built in yt-pgxt
# with `cargo deb -p yxctl --variant pg18 --no-build`. Unset: the newest in
# ../../yt-pgxt/target/debian, when that checkout is next to this one.
. "$(dirname "$0")/lib.sh"

deb="${YAXAHA_DEB:-$(ls -t "$HERE"/../../yt-pgxt/target/debian/yaxaha_*_amd64.deb 2>/dev/null | head -1)}"
[ -n "$deb" ] && [ -f "$deb" ] || die "no yaxaha package: set YAXAHA_DEB to a yaxaha_<version>_amd64.deb"
say "== package $(basename "$deb") ($(md5sum < "$deb" | cut -c1-12))"

stage="$HERE/build"
rm -rf "$stage" && mkdir -p "$stage"
cp "$HERE"/node/Dockerfile "$HERE"/node/entrypoint.sh "$stage"/
cp "$deb" "$stage/yaxaha.deb"
docker build -q -t "$IMAGE" "$stage" >/dev/null || die "docker build failed"
rm -rf "$stage"
say "== $IMAGE: $(docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
    'dpkg-query -W -f="yaxaha \${Version}, " yaxaha; /usr/local/bin/yaxaha/ytserv --version 2>/dev/null | head -1; true')"
