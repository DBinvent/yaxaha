#!/bin/bash
set -Eeu

# APT_HOST: the yaxaha package repo host, defaults to the local dev apt server (see Dockerfile ARG APT_HOST).
# APT_HOST_IP: resolves APT_HOST during the build via 'docker build --add-host', since Docker doesn't
#              inherit the host's /etc/hosts. Defaults to the local dev apt server's LAN address when
#              APT_HOST is left at its default; set both to point at a different repo (e.g. a public one).
APT_HOST="${APT_HOST:-apt}"
APT_HOST_IP="${APT_HOST_IP:-}"
if [[ -z "$APT_HOST_IP" && "$APT_HOST" == "apt" ]]; then
  APT_HOST_IP=192.168.1.3
fi

BUILD_ARGS=(--build-arg "APT_HOST=$APT_HOST")
if [[ -n "$APT_HOST_IP" ]]; then
  BUILD_ARGS+=(--add-host "$APT_HOST:$APT_HOST_IP")
fi

docker image build "${BUILD_ARGS[@]}" -t yaxaha .
echo
echo "Docker build completed, starting the docker_run.sh..."
echo

docker run -it -v $(pwd):/home/rust yaxaha

