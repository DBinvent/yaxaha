#!/usr/bin/env bash
# Build the node image (ytllm-node) from a yaxaha package, and pull ClickHouse.
#
#   ./build.sh                 # YAXAHA_DEB from .env / the environment
#
# YAXAHA_DEB: a yaxaha_<version>_amd64.deb, 0.16.7 or newer (R1's ClickHouse fallback),
# e.g. built in yt-pgxt with `cargo deb -p yxctl --no-build`. Unset: the newest
# in ../../yt-pgxt/target/debian, when that checkout is next to this one.
. "$(dirname "$0")/lib.sh"

deb="${YAXAHA_DEB:-$(ls -t "$HERE"/../../yt-pgxt/target/debian/yaxaha_*_amd64.deb 2>/dev/null | head -1)}"
[ -n "$deb" ] && [ -f "$deb" ] || die "no yaxaha package: set YAXAHA_DEB to a yaxaha_<version>_amd64.deb"
say "== package $(basename "$deb") ($(md5sum < "$deb" | cut -c1-12)), docker ${DOCKER_HOST:-(default)}"

stage="$HERE/build"
rm -rf "$stage" && mkdir -p "$stage"
cp "$HERE"/node/Dockerfile "$HERE"/node/entrypoint.sh "$HERE"/node/requirements.txt "$stage"/
cp "$deb" "$stage/yaxaha.deb"
docker build -t "$IMAGE" "$stage" || die "docker build failed"
rm -f "$stage/yaxaha.deb"

docker pull -q "$CH_IMAGE" || die "docker pull $CH_IMAGE failed"
say "== $IMAGE: $(docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
    'dpkg-query -W -f="yaxaha \${Version}, " yaxaha; /opt/llm-df/bin/python -c "import datafusion, pyarrow; print(\"datafusion\", datafusion.__version__, \"pyarrow\", pyarrow.__version__)"')"
