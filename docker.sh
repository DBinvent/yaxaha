#!/bin/bash
set -Eeu

# APT_HOST: the yaxaha package repo host, apt.dbinvent.com by default (see Dockerfile ARG APT_HOST).
# APT_HOST_IP: optional. Maps APT_HOST to this address during the build via 'docker build --add-host',
#              since Docker doesn't inherit the host's /etc/hosts: for an apt server of your own that
#              answers to that name. Unset, the name resolves through DNS.
APT_HOST="${APT_HOST:-apt.dbinvent.com}"
APT_HOST_IP="${APT_HOST_IP:-}"

BUILD_ARGS=(--build-arg "APT_HOST=$APT_HOST")
if [[ -n "$APT_HOST_IP" ]]; then
  BUILD_ARGS+=(--add-host "$APT_HOST:$APT_HOST_IP")
fi

docker image build "${BUILD_ARGS[@]}" -t yaxaha .
echo
echo "Docker build completed, starting the docker_run.sh..."
echo

docker run -it -v $(pwd):/home/rust yaxaha

