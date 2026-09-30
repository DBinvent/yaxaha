#!/bin/bash
# Sourced by the wait scripts. Not meant to be run.
#
# Every wait in this suite is bounded, and that is not tidiness: an
# unbounded `while` turns a broken build into a hang, and a hang reports
# nothing. A stale extension name, a start-order deadlock, an unrunnable
# ytserv build and a missing argument were all true at the same time and all
# invisible, because each one ended in a loop with no way out. See REVIEW.md.
#
# A wait that gives up is a failure, never a shrug. Raise the budget on a
# slow machine rather than removing it:
#
#   IT_WAIT_TIMEOUT=300 cargo make --env PG_VER=14 --env CNT=3

IT_WAIT_TIMEOUT=${IT_WAIT_TIMEOUT:-90}
IT_ERROR_FILE=${IT_ERROR_FILE:-error.msg}

# Records the reason where close_wait.sh will find it, then exits non-zero.
#
# Both halves matter: several callers have no `set -e` and drop our exit
# code on the floor, so error.msg is what still makes the run fail. That is
# also why it is append-only — Makefile.toml's `preclean` truncates it once
# per run, and every node writes into the same file.
it_fail() {
  echo "[IT] $*" >&2
  echo "[IT] $*" >> "$IT_ERROR_FILE"
  exit 1
}

# Polls a command once a second until it succeeds or the budget runs out.
#
#   it_wait_for "<what, in words>" <command> [args...]
#
# Quiet while polling and loud exactly once: on the last attempt the command
# runs again with its output shown, so the failure message is followed by
# the reason rather than by nothing.
it_wait_for() {
  local what=$1
  shift
  local waited=0
  while ! "$@" >/dev/null 2>&1
  do
    if [ "$waited" -ge "$IT_WAIT_TIMEOUT" ]
    then
      echo "[IT] giving up on: $what — last attempt was:" >&2
      "$@" >&2 || true
      it_fail "gave up after ${IT_WAIT_TIMEOUT}s waiting for $what"
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
}
