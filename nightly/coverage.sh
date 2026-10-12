#!/usr/bin/env bash
# Code coverage of the nightly's tests: the lines of yt-pgxt's Rust workspace that
# the unit tests and the end-to-end suites ran. nightly/nightly.sh measures it in a
# run that finds nightly/coverage.yaml missing (or with --coverage), through these:
#
#   nightly/coverage.sh build <deb> <out.deb>   # instrumented ytserv + yxctl, and <deb> carrying them
#   nightly/coverage.sh unit                    # the workspace's cargo tests, instrumented
#   nightly/coverage.sh report <dir> <yaml>     # <dir>/e2e/<suite>/*.profraw + the unit profiles
#
# build: ytserv and yxctl, release profile, yt-pgxt's own crates compiled with
#   `-C instrument-coverage --cfg yt_coverage` (coverage-rustc.sh; the registry
#   crates plain), in yt-pgxt/target/coverage - never target/release, which the
#   release build reads. The package is <deb> with those two binaries swapped in and
#   /var/lib/yaxaha-cov (mode 1777) added: every suite installs it in place of
#   <deb>, and an instrumented process writes its counts there itself
#   (ytcluster-common/src/coverage.rs) - rewritten every 5 s, so a node killed by
#   its test keeps all but its last seconds. A suite mounts a docker volume of its
#   own over the directory (YX_COV_MOUNT), so the counts outlive the containers.
# unit: `cargo llvm-cov --workspace --no-fail-fast --no-report` - the unit suite of
#   a coverage run, the same tests and the same "test result:" lines.
# report: per suite, every end-to-end suite together, and the unit tests merged
#   with them, line by line. The unit tests are a debug build and the suites ran a
#   release one, so the two are merged as lines (lcov), not as LLVM profiles:
#   llvm-cov keeps one record per function, and a debug and a release build of
#   the same function do not share counters. Written: <yaml> (totals, per crate,
#   per suite - no paths or hosts, it is committed), <dir>/coverage.txt (every
#   file), <dir>/combined.lcov, <dir>/unit-html and <dir>/e2e-html; each suite's
#   profiles merged in <dir>/e2e/<suite>.profdata, the raw ones deleted.
#
# Counted: yt-pgxt's own sources - not the registry crates, not the sibling
# repositories ytserv builds from (rppd, rdbm, diff-doc-rs), not the generated
# protobuf code (protogen/). A unit test's own lines count, as cargo llvm-cov
# counts them.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TESTS="$(cd "$HERE/.." && pwd)"
if [ -f "$TESTS/.env" ]; then
	_keep="$(export -p)"; set -a; . "$TESTS/.env"; set +a; eval "$_keep"; unset _keep
fi
YT_PGXT="${YT_PGXT:-$(cd "$TESTS/.." && pwd)/yt-pgxt}"
COV_TARGET="$YT_PGXT/target/coverage"
LLVM_BIN="$(rustc --print sysroot)/lib/rustlib/$(rustc -vV | awk '/^host:/{print $2}')/bin"
IGNORE='/\.cargo/|/rustc/|/target/|/protogen/'

die() { echo "  FAIL  coverage: $*"; exit 1; }

build() {
	local deb="$1" out="$2" stage
	[ -f "$deb" ] || die "no package $deb"
	command -v cargo-llvm-cov >/dev/null && [ -x "$LLVM_BIN/llvm-profdata" ] \
		|| die "needs cargo-llvm-cov and the llvm-tools component (rustup component add llvm-tools-preview)"
	(cd "$YT_PGXT" && YT_COV_ROOT="$(realpath "$YT_PGXT")" RUSTC_WRAPPER="$HERE/coverage-rustc.sh" \
		CARGO_TARGET_DIR="$COV_TARGET" cargo build --release -p ytserv -p yxctl) \
		|| die "the instrumented build failed"
	stage="$(mktemp -d)"
	dpkg-deb -R "$deb" "$stage" || die "cannot unpack $deb"
	install -m 755 "$COV_TARGET/release/ytserv" "$stage/usr/local/bin/yaxaha/ytserv"
	install -m 755 "$COV_TARGET/release/yxctl" "$stage/usr/local/bin/yxctl"
	install -d -m 1777 "$stage/var/lib/yaxaha-cov"
	(cd "$stage" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | sort -z | xargs -0 md5sum > DEBIAN/md5sums)
	sed -i "s/^Installed-Size: .*/Installed-Size: $(du -sk --exclude=DEBIAN "$stage" | cut -f1)/" "$stage/DEBIAN/control"
	dpkg-deb --root-owner-group -Zgzip -b "$stage" "$out" >/dev/null || die "cannot pack $out"
	rm -rf "$stage"
	echo "  OK    coverage package: $(basename "$out")"
}

unit() {
	cd "$YT_PGXT" && cargo llvm-cov --workspace --no-fail-fast --no-report
}

# lcov <out.lcov> <profraw...>: what those profiles ran in the instrumented binaries
e2e_lcov() {
	local out="$1"; shift
	"$LLVM_BIN/llvm-profdata" merge -sparse --failure-mode=all "$@" -o "${out%.lcov}.profdata" 2>"${out%.lcov}.merge.log" \
		|| { echo "  WARN  no usable profile for $(basename "$out")"; return 1; }
	"$LLVM_BIN/llvm-cov" export -format=lcov -instr-profile "${out%.lcov}.profdata" \
		-ignore-filename-regex="$IGNORE" "$COV_TARGET/release/ytserv" -object "$COV_TARGET/release/yxctl" > "$out"
}

report() {
	local dir="$1" yaml="$2" s files
	mkdir -p "$dir"
	if (cd "$YT_PGXT" && cargo llvm-cov report --lcov --output-path "$dir/unit.lcov" --ignore-filename-regex "$IGNORE") >/dev/null 2>"$dir/unit.log"; then
		(cd "$YT_PGXT" && cargo llvm-cov report --html --output-dir "$dir/unit-html" --ignore-filename-regex "$IGNORE") >/dev/null 2>&1
	else
		echo "  WARN  no unit profiles: $(tail -1 "$dir/unit.log")"; rm -f "$dir/unit.lcov"
	fi
	for s in "$dir"/e2e/*/; do
		[ -d "$s" ] || continue
		mapfile -t files < <(find "$s" -name '*.profraw' -size +0)
		[ "${#files[@]}" -gt 0 ] || { echo "  WARN  $(basename "$s"): no profiles"; continue; }
		e2e_lcov "$dir/e2e/$(basename "$s").lcov" "${files[@]}" && echo "  OK    $(basename "$s"): ${#files[@]} profiles"
	done
	mapfile -t files < <(find "$dir/e2e" -name '*.profraw' -size +0 2>/dev/null)
	if [ "${#files[@]}" -gt 0 ] && e2e_lcov "$dir/e2e.lcov" "${files[@]}"; then
		"$LLVM_BIN/llvm-cov" show -format=html -output-dir "$dir/e2e-html" -instr-profile "$dir/e2e.profdata" \
			-ignore-filename-regex="$IGNORE" "$COV_TARGET/release/ytserv" -object "$COV_TARGET/release/yxctl" >/dev/null 2>&1
	fi
	ROOT="$YT_PGXT" DIR="$dir" YAML="$yaml" python3 - <<'EOF'
import glob, json, os, sys
e = os.environ
root = os.path.realpath(e["ROOT"]) + "/"
d = e["DIR"]
q = json.dumps  # a JSON string is a YAML double-quoted scalar

def read(path):
    """lcov -> {repo-relative file: {line: hits}}, yt-pgxt's own sources only"""
    out, cur = {}, None
    for line in open(path, errors="replace"):
        if line.startswith("SF:"):
            f = os.path.realpath(line[3:].strip())
            cur = out.setdefault(f[len(root):], {}) if f.startswith(root) and "/protogen/" not in f else None
        elif line.startswith("DA:") and cur is not None:
            n, h = line[3:].split(",")[:2]
            cur[int(n)] = cur.get(int(n), 0) + int(h)
    return out

sources = {}
if os.path.exists(f"{d}/unit.lcov"):
    sources["unit"] = read(f"{d}/unit.lcov")
for p in sorted(glob.glob(f"{d}/e2e/*.lcov")):
    sources[os.path.basename(p)[:-5]] = read(p)
e2e = read(f"{d}/e2e.lcov") if os.path.exists(f"{d}/e2e.lcov") else {}
if not sources:
    sys.exit("coverage: nothing measured - no unit profile, no suite profile")

# every line any build instrumented is a line to cover
lines = {}
for src in list(sources.values()) + [e2e]:
    for f, ls in src.items():
        lines.setdefault(f, set()).update(ls)
def hit(src, f):
    return {n for n, h in src.get(f, {}).items() if h > 0}
total = {f: set().union(*(hit(s, f) for s in sources.values())) for f in lines}

def pct(c, n): return round(100.0 * c / n, 1) if n else 0.0
def share(files, covered):
    n = sum(len(lines[f]) for f in files)
    return n, sum(len(covered(f)) for f in files), pct(sum(len(covered(f)) for f in files), n)

allf = sorted(lines)
n, c, p = share(allf, lambda f: total[f])
crates = sorted({f.split("/")[0] for f in allf})
with open(f"{d}/coverage.txt", "w") as fh:
    fh.write(f"{'file':70} {'lines':>6} {'total':>6} {'unit':>6} {'e2e':>6}\n")
    for f in allf:
        fh.write(f"{f:70} {len(lines[f]):6} {pct(len(total[f]), len(lines[f])):6} "
                 f"{pct(len(hit(sources.get('unit', {}), f)), len(lines[f])):6} {pct(len(hit(e2e, f)), len(lines[f])):6}\n")
with open(f"{d}/combined.lcov", "w") as fh:
    for f in allf:
        fh.write(f"SF:{root}{f}\n")
        for ln in sorted(lines[f]):
            fh.write(f"DA:{ln},{1 if ln in total[f] else 0}\n")
        fh.write(f"LF:{len(lines[f])}\nLH:{len(total[f])}\nend_of_record\n")

out = ["# yaxaha code coverage: the lines of yt-pgxt's Rust workspace the nightly's tests ran -",
       "# the unit tests and every end-to-end suite, against an instrumented ytserv and yxctl",
       "# (nightly/coverage.sh says what counts). Written by a nightly run that measured it,",
       "# and a run measures it when this file is MISSING, or lists fewer suites than a whole",
       "# run: rename or delete it and the next nightly measures again, even with no code",
       "# change (nightly/nightly.sh --coverage: now). ytserv's percent is the badge's.",
       f"run: {q(e.get('RUN_ID', ''))}",
       f"measured: {q(e.get('MEASURED', ''))}",
       f"version: {{deb: {q(e.get('DEB_V', ''))}, ytserv: {q(e.get('YTS_V', ''))}}}",
       f"source: {q(e.get('SOURCE', ''))}",
       f"result: {e.get('RESULT', 'unknown')}",
       f"suites: [{', '.join(q(x) for x in e.get('SUITES', '').split())}]",
       f"lines: {{total: {n}, covered: {c}, percent: {p}}}",
       "# percent of those lines each part ran: the unit tests, the suites together, each suite",
       "by:"]
by = [("unit", sources["unit"])] if "unit" in sources else []
by += [("e2e", e2e)] if e2e else []
by += [(k, v) for k, v in sources.items() if k != "unit"]
for name, src in by:
    out.append(f"  {q(name)}: {share(allf, lambda f: hit(src, f))[2]}")
out.append("crates:")
for cr in crates:
    fs = [f for f in allf if f.split("/")[0] == cr]
    cn, cc, cp = share(fs, lambda f: total[f])
    out.append(f"  - {{name: {q(cr)}, lines: {cn}, percent: {cp}, unit: {share(fs, lambda f: hit(sources.get('unit', {}), f))[2]}, "
               f"e2e: {share(fs, lambda f: hit(e2e, f))[2]}}}")
with open(e["YAML"], "w") as fh:
    fh.write("\n".join(out) + "\n")
print(f"  OK    coverage {p}% of {n} lines ({c} run)")
print(f"coverage={p}")
EOF
	local rc=$?
	# the raw profiles - 0.6 MB a process, 340 MB a run - are in the .profdata now
	[ "$rc" -eq 0 ] && find "$dir/e2e" -name '*.profraw' -delete
	return $rc
}

case "${1:-}" in
	build) shift; build "$@" ;;
	unit) unit ;;
	report) shift; report "$@" ;;
	*) sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "$0"; exit 2 ;;
esac
