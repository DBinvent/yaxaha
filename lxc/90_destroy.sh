#!/usr/bin/env bash
# Delete the test container.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# a coverage run: the instrumented binaries' counts, before they go with the container
if [ -n "$YX_COV_OUT" ] && lxc info "$YX_CONTAINER" >/dev/null 2>&1; then
	mkdir -p "$YX_COV_OUT"
	for d in /var/lib/yaxaha-cov /tmp/yaxaha-cov; do
		lxc exec "$YX_CONTAINER" -- tar -C "$d" -cf - . 2>/dev/null | tar -x -C "$YX_COV_OUT" 2>/dev/null || true
	done
	echo "Saved $(find "$YX_COV_OUT" -name '*.profraw' | wc -l) coverage profiles"
fi
lxc delete --force "$YX_CONTAINER" 2>/dev/null && echo "Deleted $YX_CONTAINER" || echo "$YX_CONTAINER not present"
