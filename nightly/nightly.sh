#!/usr/bin/env bash
# The nightly end-to-end run: test what changed, publish what passed.
#
#   nightly/nightly.sh                # what cron runs at 05:00 UTC
#   nightly/nightly.sh --dry-run      # say what a run would do, run nothing
#   nightly/nightly.sh --force        # run even with nothing untested
#   nightly/nightly.sh --no-publish   # build and test only
#   nightly/nightly.sh --suites "unit lxc"
#   nightly/nightly.sh --coverage     # measure coverage this run (--no-coverage: not)
#   nightly/locked.sh <command...>    # anything else on the test hosts, under the same lock
#
# Another run in progress (the lock, nightly/state/nightly.lock): exit 75 at once,
# nothing run, nothing appended, nothing sent.
#
# 1. Changes: a fingerprint of the .rs files of every watched repository - their
#    content, committed or not, tracked or not (ignored ones never) - against the
#    one the last run tested. A code change is a .rs change and nothing else: no
#    .rs change, no run - nothing built, nothing appended, no package. This
#    repository is never watched: a change to a test is not a change to test.
# 2. Version: when the deb version in yt-pgxt/yxctl/Cargo.toml is already
#    published, its patch is bumped (and ytserv's, when ytserv's sources changed
#    since its version was published) - in the working tree, uncommitted.
# 3. Build: the extension for every PostgreSQL major, the release binaries, the
#    PostgreSQL 18 deb the suites install, the etcd example 93_etcd needs.
# 4. Suites (NIGHTLY_SUITES), each with its own log, its OK/PASS and FAIL lines
#    counted; a suite that exits non-zero with no FAIL line counts one failure.
#    Exit 77 is a skip: a suite whose outside service is not there (llm: the
#    model service) tested nothing - recorded as skipped, neither passed nor
#    failed, and it does not hold back the publish.
# 5. Every suite passed (and NIGHTLY_PUBLISH=1): the release build - every glibc
#    target, EL9, musl, the extension - then the deb into the apt repository and
#    the EL9 rpm into REPO_DIR/yum/el9. Any failure anywhere publishes nothing.
# 6. The run is appended to nightly/results.yaml, oldest first: a page shows it
#    newest first by reading the list in reverse.
#
# Coverage: a run that finds nightly/coverage.yaml missing measures it - so
# renaming or deleting that file has the next night measure again, and with no
# .rs change it runs for that alone (trigger: coverage; nothing bumped or
# published, there is nothing new to publish). Such a run builds an instrumented
# ytserv and yxctl into a second package (nightly/coverage.sh) that every suite
# installs in place of the plain one, runs the unit tests under cargo llvm-cov,
# collects each suite's counts from its docker volume (lxc: from the container)
# and writes nightly/coverage.yaml plus a `coverage:` percent in its results.yaml
# entry; the per-file report stays in the run's logs. A measurement that produced
# no report is not retried for the same sources (state/coverage.tried.fp) unless
# asked with --coverage.
#
# Settings: ../.env (see ../env.example). State (fingerprints, what was
# published) in nightly/state/, logs in nightly/logs/<run>/ - neither committed.
set -uo pipefail
export PATH="$HOME/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG=C.UTF-8
# cron sets LOGNAME, not USER - and rppd's default connection is $USER@$USER: under
# cron it fell back to `postgres` and 19 ytserv unit tests failed on peer auth
export USER="${USER:-$(id -un)}"

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TESTS="$(cd "$HERE/.." && pwd)"
if [ -f "$TESTS/.env" ]; then
	_keep="$(export -p)"; set -a; . "$TESTS/.env"; set +a; eval "$_keep"; unset _keep
fi
GIT_ROOT="$(cd "$TESTS/.." && pwd)"
YT_PGXT="${YT_PGXT:-$GIT_ROOT/yt-pgxt}"
DIST="${DIST:-$GIT_ROOT/yaxaha_dist}"
INFRA_APT="${INFRA_APT:-$GIT_ROOT/infra_apt}"
REPO_DIR="${REPO_DIR:-}"   # the apt repository root, yum/el9 under it: .env
GPG_KEY="${GPG_KEY:-D9988976429AE53380B9E08C47C722E2BC8094E8}"
RMC_SSH="${RMC_SSH:-}"
RMC_DIR="${RMC_DIR:-rmc-run}"
ALL_SUITES="unit topology hier lxc llm topo topo-faults topo-membership rmc"
NIGHTLY_SUITES="${NIGHTLY_SUITES:-$ALL_SUITES}"
NIGHTLY_PUBLISH="${NIGHTLY_PUBLISH:-1}"
# Where the builds' containers run (the extension, the glibc/EL9/musl targets):
# a docker daemon by DOCKER_HOST syntax - ssh://<host> to keep them off this host.
# Empty: this host's own. Every build here uses build contexts and `docker cp`,
# never a bind mount, so a remote daemon builds the same thing.
NIGHTLY_DOCKER_HOST="${NIGHTLY_DOCKER_HOST:-}"
if [ -n "$NIGHTLY_DOCKER_HOST" ]; then export DOCKER_HOST="$NIGHTLY_DOCKER_HOST"; else unset DOCKER_HOST; fi
STATE="$HERE/state"
RESULTS="$HERE/results.yaml"
mkdir -p "$STATE" "$HERE/logs"

COVERAGE_FILE="$HERE/coverage.yaml"
COVERAGE=auto; COV_ASKED=0
DRY=0; FORCE=0; ARGS="$*"
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY=1; shift ;;
		--force) FORCE=1; shift ;;
		--no-publish) NIGHTLY_PUBLISH=0; shift ;;
		--suites) NIGHTLY_SUITES="$2"; shift 2 ;;
		--coverage) COVERAGE=1; COV_ASKED=1; shift ;;
		--no-coverage) COVERAGE=0; shift ;;
		-h|--help) sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

# One run at a time, on this host: the suites share one docker host, and two runs
# there tear down each other's clusters (2026-10-10: a manual run's rmc suite
# recreated the containers under another run's topo T6, and both reports were
# garbage). A run that finds the lock held does nothing at all - no build, no
# results.yaml entry, no Telegram message (cron skips the sender on exit 75) - and
# says who holds it. It has nothing to wait for either: whatever it would test,
# the running one is testing. nightly/locked.sh takes the same lock for a suite
# run by hand. A dry run changes nothing and takes no lock.
LOCK="$STATE/nightly.lock"
exec 9>> "$LOCK"
if [ "$DRY" != 1 ] && ! flock -n 9; then
	echo "$(date -u +%FT%TZ) not run: another run holds $LOCK - $(cat "$LOCK.who" 2>/dev/null || echo unknown)" >&2
	exit 75
fi
[ "$DRY" = 1 ] || echo "nightly.sh pid $$ since $(date -u +%FT%TZ) ${ARGS:-(cron)}" > "$LOCK.who"

now()  { date -u +%FT%TZ; }
secs() { date +%s; }
say()  { echo "$(date -u +%T) $*"; }

# ── 1. what changed ─────────────────────────────────────────────────────────────
watch_list() {
	if [ -n "${NIGHTLY_WATCH:-}" ]; then echo "$NIGHTLY_WATCH"; return; fi
	{
		echo yt-pgxt
		(cd "$YT_PGXT" && timeout 300 cargo metadata --format-version 1 --offline 2>/dev/null) | python3 -c '
import json, os, subprocess, sys
try: m = json.load(sys.stdin)
except Exception: sys.exit(0)
for p in m["packages"]:
    if p["source"] is None:
        d = os.path.dirname(p["manifest_path"])
        r = subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
        print(os.path.basename(r or d))'
		echo etcd yaxaha_dist infra_apt
	} | tr ' ' '\n' | grep -v '^$' | grep -vx "$(basename "$TESTS")" | sort -u | tr '\n' ' '
}

# fp <repo dir> [dir...]: the content of every .rs file under the repository (or
# under the dirs given) - committed or not, tracked or not, ignored ones never.
# Only code counts: a doc, a script, a Cargo.toml version bump changes nothing.
fp() {
	local d="$1"; shift
	[ -e "$d/.git" ] || { echo "absent"; return; }
	local specs=() p
	if [ $# -eq 0 ]; then specs=(':(glob)**/*.rs'); else for p in "$@"; do specs+=(":(glob)$p/**/*.rs"); done; fi
	(cd "$d" && git ls-files -co --exclude-standard -z -- "${specs[@]}" 2>/dev/null \
		| sort -zu | xargs -0 -r sha256sum 2>/dev/null) | sha256sum | cut -c1-16
}
short_rev() { # <repo dir>: the commit, +dirty when the working tree differs from it
	local d="$1" r
	r=$(git -C "$d" rev-parse --short HEAD 2>/dev/null) || { echo "absent"; return; }
	if [ -n "$(git -C "$d" status --porcelain 2>/dev/null | head -1)" ]; then echo "$r+dirty"; else echo "$r"; fi
}
YTSERV_PATHS=(ytserv ytcluster-types ytcluster-common)
ytserv_fp() { # yt-pgxt's ytserv sources and every local repository it builds from
	local f; f="$(fp "$YT_PGXT" "${YTSERV_PATHS[@]}")"
	for r in rppd rdbm diff-doc-rs; do f="$f $(fp "$GIT_ROOT/$r")"; done
	echo "$f" | sha256sum | cut -c1-16
}
fingerprints() { local r; for r in $WATCH; do echo "$r $(fp "$GIT_ROOT/$r")"; done; }

WATCH="$(watch_list)"
CUR="$(fingerprints)"
LAST="$(cat "$STATE/tested.fp" 2>/dev/null)"
CHANGED="$(join -a1 <(sort <<< "$CUR") <(sort <<< "$LAST") 2>/dev/null | awk 'NF < 3 || $2 != $3 {print $1}' | tr '\n' ' ')"
TRIGGER=changes
# coverage: measured when its file is missing; a failed measurement of these same
# sources is not tried again on its own
COV_TRIED="$(cat "$STATE/coverage.tried.fp" 2>/dev/null)"
if [ "$COVERAGE" = auto ]; then
	# measured on its own only by a run of every suite: a partial one would write
	# the file, and the whole measurement would never come
	if [ -f "$COVERAGE_FILE" ] || [ "$NIGHTLY_SUITES" != "$ALL_SUITES" ]; then COVERAGE=0; else COVERAGE=1; fi
fi
if [ -z "$CHANGED" ]; then
	if [ "$FORCE" = 1 ]; then TRIGGER=forced
	elif [ "$COVERAGE" = 1 ] && { [ "$COV_ASKED" = 1 ] || [ "$CUR" != "$COV_TRIED" ]; }; then
		TRIGGER=coverage; NIGHTLY_PUBLISH=0
	else
		say "no .rs change since the last tested run in: $WATCH"; exit 0; fi
fi

# ── 2. the version ──────────────────────────────────────────────────────────────
cargo_version() { grep -m1 -oP '(?<=^version = ")[^"]+' "$1"; }
bump_patch() { # <Cargo.toml>
	local v n; v="$(cargo_version "$1")"; n="${v%.*}.$(( ${v##*.} + 1 ))"
	sed -i "0,/^version = \"$v\"/s//version = \"$n\"/" "$1"; echo "$n"
}
published_deb() { reprepro -b "$REPO_DIR" list yaxaha 2>/dev/null | awk '/yaxaha /{print $NF; exit}'; }
DEB_V="$(cargo_version "$YT_PGXT/yxctl/Cargo.toml")"
YTS_V="$(cargo_version "$YT_PGXT/ytserv/Cargo.toml")"
PUB_V="$(published_deb)"
BUMPED=false
NEED_BUMP=0
if [ "$TRIGGER" != coverage ] && [ -n "$PUB_V" ] && dpkg --compare-versions "$DEB_V" le "$PUB_V"; then NEED_BUMP=1; fi

say "== nightly $(now): $TRIGGER - changed: ${CHANGED:-none} (watching: $WATCH)"
say "   deb $DEB_V (published: ${PUB_V:-none}), ytserv $YTS_V; suites: $NIGHTLY_SUITES; publish: $NIGHTLY_PUBLISH; coverage: $( [ "$COVERAGE" = 1 ] && echo "measured$( [ -f "$COVERAGE_FILE" ] || echo " ($(basename "$COVERAGE_FILE") missing)")" || echo no)"
if [ "$DRY" = 1 ]; then
	[ "$NEED_BUMP" = 1 ] && say "   would bump the deb patch past $PUB_V$( [ "$(ytserv_fp)" != "$(cat "$STATE/published.ytserv.fp" 2>/dev/null)" ] && [ "$YTS_V" = "$(cat "$STATE/published.ytserv.version" 2>/dev/null)" ] && echo ", and ytserv's")"
	say "   dry run: nothing built, run or published"; exit 0
fi

if [ "$NEED_BUMP" = 1 ]; then
	while dpkg --compare-versions "$DEB_V" le "$PUB_V"; do DEB_V="$(bump_patch "$YT_PGXT/yxctl/Cargo.toml")"; done
	if [ "$(ytserv_fp)" != "$(cat "$STATE/published.ytserv.fp" 2>/dev/null)" ] \
	   && [ "$YTS_V" = "$(cat "$STATE/published.ytserv.version" 2>/dev/null)" ]; then
		YTS_V="$(bump_patch "$YT_PGXT/ytserv/Cargo.toml")"
	fi
	BUMPED=true
	say "   bumped: deb $DEB_V, ytserv $YTS_V"
fi
# what this run tests, taken after the bump so the bump is not itself a change
TESTED_FP="$(fingerprints)"
YTSERV_FP="$(ytserv_fp)"
declare -A REV
for r in $WATCH; do REV[$r]="$(short_rev "$GIT_ROOT/$r")"; done

RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
LOGS="$HERE/logs/$RUN_ID"
mkdir -p "$LOGS"
START="$(now)"; T0="$(secs)"
ROWS="$LOGS/suites.tsv"   # name passed failed seconds result log
: > "$ROWS"

# count <log> <exit code>: "<passed> <failed>"
count() {
	local log="$1" rc="$2" p f
	p=$(grep -cE '^[[:space:]]*(OK|PASS)([[:space:]:]|$)' "$log")
	f=$(grep -cE '^[[:space:]]*(FAIL|GAP)([[:space:]:]|$)' "$log")
	if grep -qE '^test result: ' "$log"; then # cargo test
		p=$(grep -oE '^test result: [a-zA-Z]+\. [0-9]+ passed; [0-9]+ failed' "$log" | awk '{s+=$4} END {print s+0}')
		f=$(grep -oE '^test result: [a-zA-Z]+\. [0-9]+ passed; [0-9]+ failed' "$log" | awk '{s+=$6} END {print s+0}')
	fi
	[ "$rc" -ne 0 ] && [ "$f" -eq 0 ] && f=1
	echo "$p $f"
}
# suite <name> <command...>: run it, log it, record it
SKIPPED=""
suite() {
	local name="$1"; shift
	local log="$LOGS/$name.log" t rc p f
	say "-- $name"
	t="$(secs)"
	( "$@" ) 9>&- > "$log" 2>&1; rc=$?   # 9>&-: a daemon a suite leaves behind (its ssh master) must not hold the lock
	if [ "$rc" -eq 77 ]; then
		printf '%s\t0\t0\t%s\tskipped\t%s\n' "$name" "$(( $(secs) - t ))" "$name.log" >> "$ROWS"
		SKIPPED="${SKIPPED:+$SKIPPED }$name"
		say "   $name: skipped - $(grep '^SKIP ' "$log" | tail -1 | sed 's/^SKIP [^:]*: //')"
		return 0
	fi
	read -r p f <<< "$(count "$log" "$rc")"
	local res=pass; [ "$f" -gt 0 ] && res=fail
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$p" "$f" "$(( $(secs) - t ))" "$res" "$name.log" >> "$ROWS"
	say "   $name: $p passed, $f failed, $(( ($(secs) - t) / 60 )) min ($res)"
	[ "$res" = pass ]
}

# ── 3. the build the suites install ─────────────────────────────────────────────
DEB="$LOGS/yaxaha_${DEB_V}_amd64-pg18.deb"
SUITE_DEB="$DEB"   # a coverage run: the instrumented one
COV="$LOGS/coverage"
build() {
	set -e
	cd "$YT_PGXT"
	FORCE=1 bash ytpgc/build-all-ytpgc.sh
	cargo build --release -p ytserv -p yxctl
	(cd yxctl && cargo deb --variant pg18 --no-build)
	cp "target/debian/yaxaha_${DEB_V}_amd64.deb" "$DEB"
	if [ -d "$GIT_ROOT/etcd" ]; then (cd "$GIT_ROOT/etcd" && cargo build --release --example yxetcd); fi
	echo "  OK    built $(basename "$DEB")"
}

# ── 4. the suites ───────────────────────────────────────────────────────────────
s_unit() { cd "$YT_PGXT" && cargo test --workspace --no-fail-fast; }
# a command on topology's and hier's docker host (YX_HOST: an ssh target, or local)
on_docker_host() {
	if [ "${YX_HOST:-local}" = local ]; then bash -c "$1"; else
		ssh -o BatchMode=yes -o ConnectTimeout=8 "$YX_HOST" "$1"; fi
}
s_topology() {
	cd "$TESTS/topology"
	export YAXAHA_DEB="$SUITE_DEB" YX_NODES="n1 n2 n3 n4 n5 n6 n7"
	local rc=0
	./run_all.sh || rc=1
	./90_down.sh || true
	on_docker_host "docker rm -f gitsrv chsrv >/dev/null 2>&1; true" || true
	return $rc
}
s_hier() {
	cd "$TESTS/hier"
	export YAXAHA_DEB="$SUITE_DEB"
	local rc=0
	./00_build.sh && ./run_all.sh || rc=1
	[ -x ./90_down.sh ] && ./90_down.sh || true
	return $rc
}
s_lxc() { cd "$TESTS/lxc" && ./run_all.sh; }
# the llm stack runs where LLM_SSH says (default: the rmc host), over ssh like rmc:
# the suite synced next to the package, its own .env there kept (the model host's
# address and the mTLS client certs of that host); empty: here.
# The model service is asked first (llm/probe.sh): not answering, the suite is
# skipped (77) before anything is built. Asked again after a failed run: if it
# stopped answering meanwhile, the failures say nothing about yaxaha - skipped too.
LLM_SSH="${LLM_SSH-$RMC_SSH}"
s_llm() {
	local rc=0
	if [ -z "$LLM_SSH" ]; then
		cd "$TESTS/llm"
		export YAXAHA_DEB="$SUITE_DEB"
		./probe.sh || return $?
		./build.sh && ./up.sh && ./test.sh || rc=1
		./down.sh || true
		[ "$rc" -eq 0 ] || PROBE_WAIT=60 ./probe.sh || return $?
		return $rc
	fi
	local at="cd $RMC_DIR/llm && unset DOCKER_HOST"
	ssh -o BatchMode=yes "$LLM_SSH" "mkdir -p $RMC_DIR/llm" \
	&& rsync -a --exclude .env --exclude run --exclude results --exclude build "$TESTS/llm/" "$LLM_SSH:$RMC_DIR/llm/" \
	|| return 1
	ssh -o BatchMode=yes "$LLM_SSH" "$at && ./probe.sh" || return $?
	rsync -a "$SUITE_DEB" "$LLM_SSH:$RMC_DIR/" \
	&& ssh -o BatchMode=yes -o ServerAliveInterval=30 "$LLM_SSH" "$at \
		&& export YAXAHA_DEB=\$HOME/$RMC_DIR/$(basename "$SUITE_DEB") YX_COV_MOUNT='${YX_COV_MOUNT:-}' && rc=0; ./build.sh && ./up.sh && ./test.sh || rc=1; ./down.sh >/dev/null 2>&1; exit \$rc" \
	|| rc=1
	[ "$rc" -eq 0 ] || ssh -o BatchMode=yes "$LLM_SSH" "$at && PROBE_WAIT=60 ./probe.sh" || return $?
	return $rc
}
# the rmc host: a copy of rmc/ and topo/ next to the package, its own rmc/.env kept
rmc_sync() {
	[ -n "$RMC_SSH" ] || return 0
	ssh -o BatchMode=yes "$RMC_SSH" "mkdir -p $RMC_DIR" \
	&& rsync -a --exclude results --exclude run --exclude .env "$TESTS/rmc/" "$RMC_SSH:$RMC_DIR/rmc/" \
	&& rsync -a --exclude results "$TESTS/topo/" "$RMC_SSH:$RMC_DIR/topo/" \
	&& rsync -a "$SUITE_DEB" "$RMC_SSH:$RMC_DIR/"
}
rmc_deb() { if [ -n "$RMC_SSH" ]; then echo "\$HOME/$RMC_DIR/$(basename "$SUITE_DEB")"; else echo "$SUITE_DEB"; fi; }
on_rmc() { # <command line, run in the rmc/ folder>
	local env="unset DOCKER_HOST; export YAXAHA_DEB=$(rmc_deb) YX_COV_MOUNT='${YX_COV_MOUNT:-}' RMC_ORIGIN=\${RMC_ORIGIN:-all} RMC_JOIN=\${RMC_JOIN:-clone} RMC_LOG_LEVEL=\${RMC_LOG_LEVEL:-info}"
	if [ -n "$RMC_SSH" ]; then
		ssh -o BatchMode=yes -o ServerAliveInterval=30 "$RMC_SSH" "cd $RMC_DIR/rmc && $env && $1"
	else
		(cd "$TESTS/rmc" && eval "$env" && eval "$1")
	fi
}
RMC_BUILT=0
rmc_prepare() { [ "$RMC_BUILT" = 1 ] && return 0; rmc_sync && on_rmc "./build.sh" && RMC_BUILT=1; }
# a fresh layout, or the suite fails with up.sh's last lines in its log
RMC_UP="( ./up.sh > /tmp/nightly-rmc-up.log 2>&1 || { tail -30 /tmp/nightly-rmc-up.log; echo '  FAIL  rmc up.sh'; exit 1; } )"
s_topo()            { rmc_prepare && on_rmc "$RMC_UP && cd ../topo && rc=0 && for t in t0_jobs t1_az t2_move t3_group t6_negative t4_split; do [ -x ./\$t.sh ] || continue; echo \"== \$t\"; ./\$t.sh || rc=1; done; exit \$rc"; }
s_topo_faults()     { rmc_prepare && on_rmc "$RMC_UP && cd ../topo && ./t5_faults.sh"; }
s_topo_membership() { rmc_prepare && on_rmc "$RMC_UP && cd ../topo && ./t7_membership.sh"; }
s_rmc()             { rmc_prepare && on_rmc "$RMC_UP && ./test.sh"; }
rmc_down() { on_rmc "./down.sh >/dev/null 2>&1; true" || true; }

# ── coverage (a run that measures it) ───────────────────────────────────────────
# A suite's instrumented processes write their counts into a docker volume of its
# own, yaxaha-cov-<suite>, on the host its containers run on - the suites add
# YX_COV_MOUNT to their `docker run`. lxc pulls the directory out of its container
# before deleting it (YX_COV_OUT) and pushes the instrumented binaries (YX_BIN_DIR).
cov_vol() { echo "yaxaha-cov-$1"; }
cov_on() { # <suite> <command line>: run it where that suite's containers run
	local to
	case "$1" in
		topology|hier) on_docker_host "$2"; return ;;
		llm) to="$LLM_SSH" ;;
		topo|topo-faults|topo-membership|rmc) to="$RMC_SSH" ;;
		*) return 0 ;;
	esac
	if [ -n "$to" ]; then ssh -o BatchMode=yes -o ConnectTimeout=8 "$to" "unset DOCKER_HOST; $2"
	else (unset DOCKER_HOST; bash -c "$2"); fi
}
cov_image() { # an image with tar, there: the suite's own node image
	case "$1" in
		topology) echo "${YX_IMAGE:-yxtopo-node}" ;;
		hier) echo "${YX_HIER_IMAGE:-yxhier-node}" ;;
		llm) echo ytllm-node ;;
		*) echo rmc-node ;;
	esac
}
cov_suite() { # <suite>: where it writes its counts - a fresh volume, or lxc's folder
	unset YX_COV_MOUNT YX_COV_OUT YX_BIN_DIR
	[ "$COVERAGE" = 1 ] || return 0
	case "$1" in
		unit|none) ;;
		lxc) mkdir -p "$COV/e2e/lxc"
			export YX_COV_OUT="$COV/e2e/lxc" YX_BIN_DIR="$YT_PGXT/target/coverage/release" ;;
		*) export YX_COV_MOUNT="-v $(cov_vol "$1"):/var/lib/yaxaha-cov"
			cov_on "$1" "docker volume rm -f $(cov_vol "$1") >/dev/null 2>&1; true" ;;
	esac
}
cov_build() { bash "$HERE/coverage.sh" build "$DEB" "$LOGS/yaxaha_${DEB_V}_amd64-pg18-coverage.deb"; }
s_unit_cov() { bash "$HERE/coverage.sh" unit; }
cov_report() {
	local s
	for s in $NIGHTLY_SUITES; do
		case "$s" in unit|lxc) continue ;; esac
		mkdir -p "$COV/e2e/$s"
		cov_on "$s" "docker run --rm -u 0 -v $(cov_vol "$s"):/c --entrypoint tar $(cov_image "$s") -C /c -cf - . 2>/dev/null; docker volume rm -f $(cov_vol "$s") >/dev/null 2>&1; true" \
			| tar -x -C "$COV/e2e/$s" 2>/dev/null
		echo "  $s: $(find "$COV/e2e/$s" -name '*.profraw' | wc -l) profile files"
	done
	RUN_ID="$RUN_ID" MEASURED="$(now)" DEB_V="$DEB_V" YTS_V="$YTS_V" SOURCE="${REV[yt-pgxt]:-}" RESULT="$RESULT" SUITES="$NIGHTLY_SUITES" \
		bash "$HERE/coverage.sh" report "$COV" "$COV/coverage.yaml" && [ -s "$COV/coverage.yaml" ]
}

RESULT=pass; BUILD=pass; PUBLISHED_DEB=""; PUBLISHED_RPM=""; NOTE=""; COVERAGE_PCT=""; COV_NOTE=""
if suite build build; then
	if [ "$COVERAGE" = 1 ]; then
		if suite coverage-build cov_build; then SUITE_DEB="$LOGS/yaxaha_${DEB_V}_amd64-pg18-coverage.deb"
		else COVERAGE=0; COV_NOTE="coverage not measured: its build failed"; echo "$TESTED_FP" > "$STATE/coverage.tried.fp"; fi
	fi
	for s in $NIGHTLY_SUITES; do
		cov_suite "$s"
		case "$s" in
			unit) if [ "$COVERAGE" = 1 ]; then suite unit s_unit_cov; else suite unit s_unit; fi ;;
			topology) suite topology s_topology ;;
			hier) suite hier s_hier ;;
			lxc) suite lxc s_lxc ;;
			llm) suite llm s_llm ;;
			topo) suite topo s_topo ;;
			topo-faults) suite topo-faults s_topo_faults ;;
			topo-membership) suite topo-membership s_topo_membership ;;
			rmc) suite rmc s_rmc ;;
			*) printf '%s\t0\t1\t0\tfail\t-\n' "$s" >> "$ROWS"; say "   unknown suite $s" ;;
		esac || RESULT=fail
	done
	cov_suite none
	case " $NIGHTLY_SUITES " in *" topo"*|*" rmc "*) rmc_down ;; esac
	if [ "$COVERAGE" = 1 ]; then
		if suite coverage cov_report; then
			COVERAGE_PCT="$(grep -oP '^coverage=\K.*' "$LOGS/coverage.log" | tail -1)"
			cp "$COV/coverage.yaml" "$COVERAGE_FILE"; rm -f "$STATE/coverage.tried.fp"
			COV_NOTE="coverage ${COVERAGE_PCT}% of yt-pgxt's lines (nightly/$(basename "$COVERAGE_FILE"))"
		else
			COV_NOTE="coverage not measured: no report"; echo "$TESTED_FP" > "$STATE/coverage.tried.fp"
		fi
	fi
else
	BUILD=fail; RESULT=fail; NOTE="the build failed - no suite ran"
fi
# tested, whatever the outcome: the same sources are not run again tomorrow
echo "$TESTED_FP" > "$STATE/tested.fp"

# ── 5. publish ──────────────────────────────────────────────────────────────────
release() {
	set -e
	cd "$YT_PGXT"
	BASE_IMAGE=almalinux:9 GLIBC_TAG=2_34 ./build_glibc.sh
	local out; out="$(mktemp)"
	EL9=1 FORCE=1 BUILD_HOST="${DOCKER_HOST:-}" GITHUB_OUTPUT="$out" "$DIST/build.sh" "$GIT_ROOT"
	SKIP_EXT=1 SKIP_GLIBC=1 GITHUB_OUTPUT="$out" "$DIST/build_rpm.sh" "$GIT_ROOT"
	REL_DEB="$(grep -oP '(?<=^deb=).*' "$out" | tail -1)"
	REL_RPM="$(grep -oP '(?<=^rpm=).*' "$out" | tail -1)"
	rm -f "$out"
	[ -f "$REL_DEB" ] && [ -f "$REL_RPM" ]
	echo "deb=$REL_DEB" > "$LOGS/release.out"; echo "rpm=$REL_RPM" >> "$LOGS/release.out"
	echo "  OK    release build: $(basename "$REL_DEB"), $(basename "$REL_RPM")"
}
publish() {
	set -e
	local deb rpm
	deb="$(grep -oP '(?<=^deb=).*' "$LOGS/release.out")"; rpm="$(grep -oP '(?<=^rpm=).*' "$LOGS/release.out")"
	DEB="$deb" REPO_DIR="$REPO_DIR" CONF_DIR="$DIST/repo-conf" PACKAGE=yaxaha GPG_KEY="$GPG_KEY" \
		INSTALL_HTML="$DIST/install.html" "$INFRA_APT/scripts/publish-apt.sh"
	echo "  OK    deb published: $(basename "$deb")"
	# its createrepo fallback bind-mounts the local repository: this host's daemon
	DOCKER_HOST=unix:///var/run/docker.sock RPM="$rpm" REPO_DIR="$REPO_DIR" GPG_KEY="$GPG_KEY" "$DIST/publish_rpm.sh"
	echo "  OK    rpm published: $(basename "$rpm")"
}
if [ "$RESULT" = pass ] && [ "$NIGHTLY_PUBLISH" = 1 ]; then
	if suite release release && suite publish publish; then
		PUBLISHED_DEB="$DEB_V"; PUBLISHED_RPM="$DEB_V"
		echo "$DEB_V" > "$STATE/published.version"
		echo "$YTS_V" > "$STATE/published.ytserv.version"
		echo "$YTSERV_FP" > "$STATE/published.ytserv.fp"
	else
		RESULT=fail; NOTE="tested green, but the release build or the publish failed"
	fi
elif [ "$TRIGGER" = coverage ] && [ "$RESULT" = pass ]; then
	NOTE="tested green; a coverage run of published sources publishes nothing"
elif [ "$RESULT" = pass ]; then
	NOTE="tested green; publishing is off (NIGHTLY_PUBLISH=0)"
elif [ -z "$NOTE" ]; then
	NOTE="not published: a suite failed"
fi
[ -n "$COV_NOTE" ] && NOTE="${NOTE:+$NOTE; }$COV_NOTE"
# no host names here: results.yaml is committed (the reason is in the suite's log)
[ -n "$SKIPPED" ] && NOTE="${NOTE:+$NOTE; }skipped: $SKIPPED (its outside service did not answer)"

# ── 6. the record ───────────────────────────────────────────────────────────────
END="$(now)"
export START END TRIGGER CHANGED DEB_V YTS_V BUMPED RESULT BUILD NOTE PUBLISHED_DEB PUBLISHED_RPM RUN_ID ROWS RESULTS COVERAGE_PCT
export DURATION=$(( $(secs) - T0 ))
export REVS="$(for r in $WATCH; do echo "$r=${REV[$r]}"; done)"
python3 - <<'EOF'
import json, os
q = json.dumps  # a JSON string is a YAML double-quoted scalar
e = os.environ
rows = []
for line in open(e["ROWS"]):
    n, p, f, s, r, log = line.rstrip("\n").split("\t")
    rows.append((n, int(p), int(f), int(s), r))
STEPS = ("build", "coverage-build", "coverage", "release", "publish")
suites = [r for r in rows if r[0] not in STEPS]
steps = [r for r in rows if r[0] in STEPS]
out = []
if not os.path.exists(e["RESULTS"]) or os.path.getsize(e["RESULTS"]) == 0:
    out.append("# yaxaha nightly end-to-end runs, oldest first - one entry per run, appended by\n"
               "# nightly/nightly.sh. A page lists them newest first by reading in reverse.\n")
out.append(f"- run: {q(e['RUN_ID'])}")
out.append(f"  started: {q(e['START'])}")
out.append(f"  finished: {q(e['END'])}")
out.append(f"  minutes: {round(int(e['DURATION']) / 60)}")
out.append(f"  trigger: {e['TRIGGER']}")
out.append(f"  changed: [{', '.join(q(c) for c in e['CHANGED'].split())}]")
out.append(f"  sources: {{{', '.join(q(k) + ': ' + q(v) for k, v in (x.split('=', 1) for x in e['REVS'].split()))}}}")
out.append(f"  version: {{deb: {q(e['DEB_V'])}, ytserv: {q(e['YTS_V'])}, bumped: {e['BUMPED']}}}")
out.append("  steps:")
for n, p, f, s, r in steps:
    out.append(f"    - {{name: {n}, result: {r}, minutes: {round(s / 60)}}}")
out.append("  suites:")
for n, p, f, s, r in suites:
    out.append(f"    - {{name: {q(n)}, passed: {p}, failed: {f}, minutes: {round(s / 60)}, result: {r}}}")
if not suites:
    out[-1] = "  suites: []"
out.append(f"  totals: {{passed: {sum(r[1] for r in suites)}, failed: {sum(r[2] for r in suites)}}}")
out.append(f"  result: {e['RESULT']}")
if e.get("COVERAGE_PCT"):
    out.append(f"  coverage: {e['COVERAGE_PCT']}")
pub = {k: v for k, v in (("deb", e["PUBLISHED_DEB"]), ("rpm", e["PUBLISHED_RPM"])) if v}
out.append("  published: " + ("{" + ", ".join(f"{k}: {q(v)}" for k, v in pub.items()) + "}" if pub else "null"))
if e["NOTE"]:
    out.append(f"  note: {q(e['NOTE'])}")
with open(e["RESULTS"], "a") as fh:
    fh.write("\n".join(out) + "\n")
EOF
say "== nightly $RESULT: $(awk -F'\t' '$1!="build"&&$1!="coverage-build"&&$1!="coverage"&&$1!="release"&&$1!="publish"{p+=$2;f+=$3} END{print p+0" passed, "f+0" failed"}' "$ROWS"), $(( ($(secs) - T0) / 60 )) min${PUBLISHED_DEB:+, published $PUBLISHED_DEB}${NOTE:+ - $NOTE}"
say "   logs: $LOGS"
[ "$RESULT" = pass ]
