#!/bin/bash
# Stops every node process, then reports the run's verdict.
#
# The exit code is the suite's result: non-zero if anything wrote to
# error.msg, which is where the test cases and the wait scripts record what
# went wrong.

errormsg=${IT_ERROR_FILE:-error.msg}
# Makefile.toml's `preclean` creates it, but this script is also run by hand.
# Without the file the verdict below is an empty string, and `exit ""` is a
# shell error rather than a result.
[ -f "$errormsg" ] || : > "$errormsg"

# Two budgets: ask politely, then insist. Was a single unbounded loop that
# sent SIGTERM once a second forever — so a process that ignored it, or one
# owned by somebody else, hung the run at the very end, after all the work
# was done and with the result already known.
term_budget=${IT_STOP_TIMEOUT:-30}
kill_budget=${IT_KILL_TIMEOUT:-10}

# Unchanged, and still the wrong way to find processes: it greps the whole
# process table for "node", with exclusions bolted on as it has misfired.
# Replacing it means a container per node — REVIEW.md, "What to use instead".
node_pids() {
  ps ugx | grep -v nodev | grep -v grep | grep -v "externals/node" | grep node | awk '{print $2}'
}

echo "[IT] Closing YT cluster ..."

stop_with() { # signal, budget
  local sig=$1 budget=$2 waited=0
  while [ -n "$(node_pids)" ]
  do
    for p in $(node_pids)
    do
      echo "Stopping pid $p with $sig ..."
      kill "-$sig" "$p" 2>/dev/null || true
    done
    if [ "$waited" -ge "$budget" ]
    then
      return 1
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  return 0
}

if ! stop_with TERM "$term_budget"
then
  echo "[IT] still running after ${term_budget}s, sending SIGKILL" >&2
  if ! stop_with KILL "$kill_budget"
  then
    echo "[IT] could not stop these, and the next run will collide with them:" >&2
    ps ugx | grep -v nodev | grep -v grep | grep -v "externals/node" | grep node >&2
    echo "[IT] gave up stopping node processes after $(( term_budget + kill_budget ))s" \
      >> "$errormsg"
  fi
fi

echo "[IT] YT cluster closed!"

exitcode=$(grep -cv "^[[:space:]]*$" "$errormsg")

if [[ $exitcode -ge 1 ]]
then
  echo
  echo "Error(s) detected at $errormsg:"
  echo
  cat "$errormsg"
  echo
fi

exit "$exitcode"
