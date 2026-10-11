#!/usr/bin/env bash
# Remove the clusters: every rmc-* container and the network. results/ stays.
. "$(dirname "$0")/lib.sh"
cluster_rm
say "== removed the rmc containers and network"
