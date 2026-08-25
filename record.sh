#!/usr/bin/env bash
# Records the tapes in tapes/ into GIFs and MP4s.
#
#   ./record.sh              both tapes
#   ./record.sh cluster      just tapes/cluster.tape
#   ./record.sh --keep       leave the container running afterwards
#
# The container is booted here rather than inside a tape on purpose: the
# entrypoint spends a minute or two on apt, ytsetup and a Postgres restart
# before anything worth watching happens. That belongs off-camera.
#
# Recording needs a real terminal — vhs drives ttyd and encodes with ffmpeg.
set -Eeuo pipefail
cd "$(dirname "$0")"

CONTAINER=yaxaha-demo
KEEP=0
TAPES=()

for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    *)      TAPES+=("tapes/$arg.tape") ;;
  esac
done
[ ${#TAPES[@]} -gt 0 ] || TAPES=(tapes/cluster.tape tapes/single-node.tape)

missing=()
for tool in vhs ttyd ffmpeg docker; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
  cat >&2 <<EOF
missing: ${missing[*]}

  vhs            go install github.com/charmbracelet/vhs@latest
  ttyd, ffmpeg   your package manager
  docker         https://docs.docker.com/engine/install/

vhs records a real terminal, so all four have to be present for the result
to be a recording rather than an illustration.
EOF
  exit 1
fi

# Same build arguments docker.sh uses — the yaxaha package comes from the
# local apt host unless told otherwise.
APT_HOST="${APT_HOST:-apt}"
APT_HOST_IP="${APT_HOST_IP:-}"
if [[ -z "$APT_HOST_IP" && "$APT_HOST" == "apt" ]]; then
  APT_HOST_IP=192.168.1.3
fi
BUILD_ARGS=(--build-arg "APT_HOST=$APT_HOST")
[[ -n "$APT_HOST_IP" ]] && BUILD_ARGS+=(--add-host "$APT_HOST:$APT_HOST_IP")

echo "building the image (cached unless the Dockerfile changed)"
docker image build "${BUILD_ARGS[@]}" -t yaxaha . >/dev/null

echo "booting $CONTAINER and waiting for its bootstrap"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
# -dt, not -d: the entrypoint ends in an interactive bash, which exits
# immediately on EOF without a tty and takes the container with it.
docker run -dt --name "$CONTAINER" -v "$(pwd):/home/rust" yaxaha >/dev/null

# Probed with a query rather than by grepping the logs for the bootstrap's
# closing message: docker_post_bootstrap.sh runs psql without `-P pager=off`,
# so with a tty attached it opens the pager and never prints that line. A
# working query is the thing we actually care about anyway.
ready=0
for _ in $(seq 90); do
  if docker exec "$CONTAINER" bash -lc 'psql -P pager=off -tAc "select 1"' 2>/dev/null | grep -qx 1; then
    ready=1
    break
  fi
  sleep 2
done
[ "$ready" = 1 ] || {
  docker logs "$CONTAINER" 2>&1 | tail -30
  echo "the container never finished bootstrapping — see above" >&2
  exit 1
}
echo "ready"

for tape in "${TAPES[@]}"; do
  echo
  echo "recording $tape"
  vhs "$tape"
done

if [ "$KEEP" = 1 ]; then
  echo
  echo "$CONTAINER left running — docker rm -f $CONTAINER when done"
else
  docker rm -f "$CONTAINER" >/dev/null
fi

echo
ls -lh ./*.gif ./*.mp4 2>/dev/null || true
cat <<'NEXT'

  A two-minute run makes a heavy GIF. Prefer the .mp4 on a web page and keep
  the GIF for places that cannot embed video (a README, a chat preview).

  Watch the result before publishing it: every Sleep in the tapes is a guess
  at how long the real run takes, not a measurement. Nobody has recorded
  these yet.
NEXT
