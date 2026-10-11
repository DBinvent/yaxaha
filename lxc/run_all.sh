#!/usr/bin/env bash
# Full integration cycle. RUN_CARGO=1 also runs the root-gated cargo tests (slow).
#
# Every script runs, whatever the one before it did: a red script is recorded and
# the cycle carries on, then exits 1 if anything failed. Ends with one line the
# nightly reads:
#   ---- lxc: <passed> passed, <failed> failed ----
# counted from the "  OK: " / "  FAIL: " lines the scripts print, plus one failure
# for a script that exited non-zero without printing a FAIL line (it died before a
# check could say why - an unguarded command under `set -e`).
set -uo pipefail
HERE="$(dirname "${BASH_SOURCE[0]}")"

scripts=(00_create.sh 10_push.sh 20_batch.sh 30_purge.sh)
if [ "${RUN_CARGO:-0}" = "1" ]; then
	scripts+=(40_cargo_ignored.sh)
fi
scripts+=(50_negative.sh 90_destroy.sh)

passed=0; failed=0
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
created=1
for s in "${scripts[@]}"; do
	# no container: every later script would only wait on it - go straight to cleanup
	if [ "$created" = 0 ] && [ "$s" != 90_destroy.sh ]; then
		echo "──── $s: SKIPPED (no container)"; continue
	fi
	echo "──── $s $(date -u +%T)"
	"$HERE/$s" 2>&1 | tee "$out"
	rc=${PIPESTATUS[0]}
	[ "$s" = 00_create.sh ] && [ "$rc" -ne 0 ] && created=0
	p=$(grep -c '^  OK: ' "$out")
	f=$(grep -c '^  FAIL: ' "$out")
	if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then
		echo "  FAIL: $s exited $rc without a FAIL line"
		f=1
	fi
	passed=$((passed + p)); failed=$((failed + f))
	if [ "$rc" -eq 0 ]; then
		echo "──── $s: PASS"
	else
		echo "──── $s: FAIL (exit $rc; continuing)"
	fi
done

echo
[ "$failed" -eq 0 ] && echo "ALL INTEGRATION TESTS PASSED"
echo "---- lxc: $passed passed, $failed failed ----"
[ "$failed" -eq 0 ]
