#!/bin/sh
# cargo's RUSTC_WRAPPER for nightly/coverage.sh build: instrument yt-pgxt's own
# crates (YT_COV_ROOT), nothing else. RUSTFLAGS would instrument every crate in
# the graph - tokio, tonic, prost - and a ytserv built that way wrote 10.7 MB of
# counts on every flush and ran its hot paths through counters nobody reads.
# Build scripts stay plain: one instrumented would leave a profile behind in the
# source tree each time it ran.
case "$CARGO_MANIFEST_DIR" in
	"$YT_COV_ROOT"/*)
		case " $* " in
			*" --crate-name build_script_build "*) ;;
			*) exec "$@" -C instrument-coverage --cfg yt_coverage ;;
		esac ;;
esac
exec "$@"
