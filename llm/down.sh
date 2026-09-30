#!/usr/bin/env bash
# Remove the test cluster: containers, networks, volumes, and this run's secrets.
# The image stays (build.sh makes it again anyway).
. "$(dirname "$0")/lib.sh"
cluster_rm
rm -f "$RUN/state.env"
say "== removed the ytllm containers, volumes and networks"
