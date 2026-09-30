#!/bin/bash
# Prints a ytserv binary that can actually run on this machine.
#
# The package ships several builds of the same server — `ytserv`,
# `ytserv-glibc2_35`, `ytserv-musl` — and they are not interchangeable:
# on Ubuntu 22.04 the unsuffixed one wants libpython3.12, which the image
# does not have, and dies with
#
#   error while loading shared libraries: libpython3.12.so.1.0
#
# This used to be `ls -l .../ytserv* | head -1 | awk '{print $9}'`, i.e.
# whichever name sorted first — which is that one. `yxctl` picks
# `ytserv-glibc2_35` for the packaged install, so the tests were running a
# different binary from the deployment even when they ran at all.
set -Eeu

dir=${YTSERV_DIR:-/usr/local/bin/yaxaha}

# A static build reports "not a dynamic executable" and no "not found",
# so it passes this too.
runnable() {
  ! ldd "$1" 2>/dev/null | grep -q "not found"
}

# Reverse name order puts a suffixed glibc build ahead of the bare name, and
# a newer -glibc2_NN ahead of an older one; the static musl build goes last,
# as the fallback that cannot fail on a missing library.
for candidate in $(ls -1 "$dir"/ytserv* 2>/dev/null | grep -v -- '-musl$' | sort -r) \
                 $(ls -1 "$dir"/ytserv*-musl 2>/dev/null)
do
  [ -x "$candidate" ] || continue
  if runnable "$candidate"
  then
    echo "$candidate"
    exit 0
  fi
done

echo "no runnable ytserv found in $dir" >&2
echo "set YTSERV_BIN=path/to/ytserv, or YTSERV_DIR to look elsewhere" >&2
exit 1
