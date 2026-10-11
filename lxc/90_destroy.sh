#!/usr/bin/env bash
# Delete the test container.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

lxc delete --force "$YX_CONTAINER" 2>/dev/null && echo "Deleted $YX_CONTAINER" || echo "$YX_CONTAINER not present"
