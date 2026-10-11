#!/usr/bin/env bash
# [tpl2] Remove the hierarchical fixture's containers - every node in NODES
# (env.sh: u1-u3, a1-a4, b1-b4). As ../topology/90_down.sh does for its own: the
# image and the network are left - a rebuild is the expensive part and nothing in
# them carries test state.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
for n in "${NODES[@]}"; do rh "docker rm -f $n >/dev/null 2>&1; true"; done
echo "Removed ${#NODES[@]} containers. (docker network rm $YX_NET / docker rmi $YX_IMAGE to go further.)"
rh "free -m | awk '/Mem:/{print \"  host avail: \"\$7\" MB\"}'"
