#!/usr/bin/env bash
# Push yxctl artifacts into the container: the .deb when YX_DEB is set,
# otherwise raw binaries + extension files from the build tree.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

if [ -n "$YX_DEB" ]; then
	echo "Pushing $YX_DEB ..."
	lxc file push "$YX_DEB" "$YX_CONTAINER/tmp/yaxaha.deb"
	xc env DEBIAN_FRONTEND=noninteractive apt-get install -qy /tmp/yaxaha.deb
else
	echo "No YX_DEB set — pushing binaries from $YX_BIN_DIR ..."
	for b in yxctl ytserv; do
		if [ ! -x "$YX_BIN_DIR/$b" ]; then
			echo "missing $YX_BIN_DIR/$b — run: cargo build --release" >&2
			exit 1
		fi
	done
	xc mkdir -p /usr/local/bin/yaxaha /usr/local/include/yaxaha
	lxc file push "$YX_BIN_DIR/yxctl" "$YX_CONTAINER/usr/local/bin/yxctl"
	lxc file push "$YX_BIN_DIR/ytserv" "$YX_CONTAINER/usr/local/bin/yaxaha/ytserv"
	# per-libc variants (deb layout) when built — exercises find_bin's best-match
	# selection among ytserv, ytserv-glibc2_35, ytserv-musl
	for v in "$REPO_ROOT"/target/glibc*/ytserv-glibc* "$REPO_ROOT"/target/musl/ytserv-musl; do
		if [ -f "$v" ]; then
			lxc file push "$v" "$YX_CONTAINER/usr/local/bin/yaxaha/$(basename "$v")"
			xc chmod 755 "/usr/local/bin/yaxaha/$(basename "$v")"
		fi
	done
	# extension binaries + control/sql (installed by yxctl into the PG dirs)
	if ls "$REPO_ROOT"/ytpgc/dist/*.so >/dev/null 2>&1; then
		for f in "$REPO_ROOT"/ytpgc/dist/*; do
			[ -f "$f" ] && lxc file push "$f" "$YX_CONTAINER/usr/local/include/yaxaha/"
		done
	fi
	for f in "$REPO_ROOT"/ytpgc/yaxaha.control "$REPO_ROOT"/ytpgc/yaxaha--*.sql; do
		[ -f "$f" ] && lxc file push "$f" "$YX_CONTAINER/usr/local/include/yaxaha/"
	done
	xc chmod 755 /usr/local/bin/yxctl /usr/local/bin/yaxaha/ytserv
fi

# older container (e.g. ubuntu:22.04, glibc 2.35) cannot run the host-built yxctl —
# fall back to the glibc variant, same as a real user on that release would
if ! xc yxctl --help >/dev/null 2>&1; then
	for alt in "$REPO_ROOT"/target/glibc*/yxctl-glibc*; do
		if [ -f "$alt" ]; then
			echo "native yxctl does not run here — pushing $(basename "$alt") as yxctl"
			lxc file push "$alt" "$YX_CONTAINER/usr/local/bin/yxctl"
			xc chmod 755 /usr/local/bin/yxctl
			break
		fi
	done
fi

assert "yxctl --help runs" xc yxctl --help
echo "Artifacts pushed."
