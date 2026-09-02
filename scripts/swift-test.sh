#!/usr/bin/env bash
#
# `swift test` behind a machine-scoped lock, so two agents' full-suite runs on one
# Mac don't collide on the on-device FoundationModels inference queue (#1594).
#
# Why: on-device inference is serialized by a system-wide daemon across *all*
# processes — six concurrent standalone probes each completed one solo-length
# turn at exact 10s intervals (FIFO, zero parallelism; see #1594's Stage 1
# writeup). Two `swift test` processes each issuing live-model turns therefore
# multiply each other's per-turn wall clock, which is what pushed the
# FoundationModels suites past their own timeouts ("flake") or left one run
# apparently stalled behind the other's turns ("hang"). `@Suite(.serialized)`
# (#1378) only removes intra-process concurrency; the queue is global, so the
# guard has to be too. Compilation is unaffected — the lock is not a `.build`
# lock and does not cover `scripts/build-app.sh`.
#
# Lock semantics — deliberately the ad-hoc convention agents already use by hand,
# so scripted and hand-rolled runs queue behind each other correctly:
#
#   * the lock is the directory /tmp/anglesite-swift-test.lock, taken with an
#     atomic `mkdir` and released with `rmdir`/`rm -rf` (no `flock` on stock macOS);
#   * this script additionally writes `holder` inside it (pid / cwd / since / args)
#     so a waiter can say who holds it, and so a lock whose holder pid is dead is
#     recognised as stale and reclaimed. A bare `mkdir` holder with no `holder`
#     file is never reclaimed — it's waited on until it goes away;
#   * Ctrl-C (SIGINT) or SIGTERM while waiting for the lock exits at once with
#     128+signal (130 / 143) and leaves the other holder's lock untouched. Once
#     `swift test` is running, the signal is forwarded to it and the lock is
#     released when this script exits.
#
# When the lock is taken (ANGLESITE_TEST_LOCK=auto, the default):
#
#   * every run without `--filter` (a full run, `--skip` or not) takes the lock;
#   * a `--filter` run takes it only if the filter regex matches one of the
#     live-model suites in scripts/lib/live-model-tests.sh. Only live turns
#     contend, so a filtered run of unrelated suites (which still compiles the
#     whole package for minutes) shouldn't hold everyone else up. The match is
#     against `<target>.<suite>/` prefixes: a filter naming only a bare test
#     function inside a live-model suite (e.g. `--filter converse`) is not
#     recognised — pass ANGLESITE_TEST_LOCK=always for that.
#
# Usage:
#   scripts/swift-test.sh                       # full run, locked
#   scripts/swift-test.sh --filter FooTests     # args pass straight through
#
# Environment:
#   ANGLESITE_TEST_LOCK=auto|always|never       when to lock (default: auto)
#   ANGLESITE_TEST_LOCK_WAIT=wait|fail          fail: exit 75 at once if held
#                                                (default: wait)
#   ANGLESITE_TEST_LOCK_POLL_SECONDS=N          wait-loop poll interval (default: 30)
#   ANGLESITE_TEST_LOCK_DIR=path                lock path override — for the
#                                                script's own tests only; every
#                                                real run must share the default
#                                                (default: /tmp/anglesite-swift-test.lock)
#
# Exit status: `swift test`'s own; 75 (EX_TEMPFAIL) when ANGLESITE_TEST_LOCK_WAIT=fail
# finds the lock held; 130 / 143 when interrupted by SIGINT / SIGTERM before
# `swift test` started; 64 for a bad environment value.
#
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib/live-model-tests.sh

lock_dir="${ANGLESITE_TEST_LOCK_DIR:-/tmp/anglesite-swift-test.lock}"
lock_mode="${ANGLESITE_TEST_LOCK:-auto}"
lock_wait="${ANGLESITE_TEST_LOCK_WAIT:-wait}"
poll_seconds="${ANGLESITE_TEST_LOCK_POLL_SECONDS:-30}"

case "$lock_mode" in auto|always|never) ;; *)
  echo "swift-test.sh: ANGLESITE_TEST_LOCK must be auto, always, or never (got '$lock_mode')" >&2; exit 64 ;;
esac
case "$lock_wait" in wait|fail) ;; *)
  echo "swift-test.sh: ANGLESITE_TEST_LOCK_WAIT must be wait or fail (got '$lock_wait')" >&2; exit 64 ;;
esac

# ---- Does this invocation need the lock? -----------------------------------

# Collect every --filter value (both `--filter X` and `--filter=X` spellings).
filters=()
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--filter" ]]; then filters+=("$arg"); fi
  if [[ "$arg" == --filter=* ]]; then filters+=("${arg#--filter=}"); fi
  prev="$arg"
done

needs_lock() {
  case "$lock_mode" in
    always) return 0 ;;
    never)  return 1 ;;
  esac
  (( ${#filters[@]} == 0 )) && return 0   # full run
  local f suite
  for f in "${filters[@]}"; do
    for suite in "${LIVE_MODEL_TEST_SUITES[@]}"; do
      # SwiftPM matches --filter as an unanchored regex against <target>.<suite>/<test>.
      if [[ "$suite/" =~ $f ]]; then return 0; fi
    done
  done
  return 1
}

# ---- Signals -----------------------------------------------------------------
#
# One handler for both phases of the run. While this shell is still waiting for
# the lock there is no child to forward to, so the handler only *records* the
# signal (and kills the current poll sleep); the wait loop checks for it after
# every step and exits 128+N without touching the other holder's lock. The poll
# sleep runs in the background under `wait`, which a trapped signal interrupts
# at once — a foreground `sleep` would defer the trap until the sleep ended, so
# Ctrl-C would sit out a whole poll interval. Recording rather than exiting from
# the handler also closes the window between a winning `mkdir` and `have_lock=1`:
# the exit happens at the next check, after the flag is set, so the EXIT trap
# releases a lock this run did take. Once `swift test` is running, the signal is
# forwarded to it and the run winds down through the normal wait/exit path.

child=""
sleeper=""
pending_signal=""
on_signal() {
  if [[ -n "$child" ]]; then
    kill -s "$1" "$child" 2>/dev/null || true
  else
    pending_signal="$1"
    [[ -n "$sleeper" ]] && kill "$sleeper" 2>/dev/null || true
  fi
}
bail_if_signalled() {
  [[ -n "$pending_signal" ]] || return 0
  echo "swift-test.sh: interrupted (SIG$pending_signal) before swift test started; giving up" >&2
  exit $((128 + $(kill -l "$pending_signal")))
}
poll_sleep() {
  sleep "$1" & sleeper=$!
  # A signal recorded before the sleeper existed could not have killed it, so
  # re-check now that it does; otherwise `wait` returns early on the next one.
  if [[ -z "$pending_signal" ]]; then wait "$sleeper" || true; fi
  kill "$sleeper" 2>/dev/null || true
  sleeper=""
}

# ---- Lock acquire / release ------------------------------------------------

holder_summary() {
  # Prints "pid N in <cwd> since <time>" from the holder file, or a fallback for
  # a bare-mkdir (hand-rolled) holder.
  local pid="" cwd="" since=""
  if [[ -r "$lock_dir/holder" ]]; then
    pid=$(sed -n 's/^pid=//p' "$lock_dir/holder")
    cwd=$(sed -n 's/^cwd=//p' "$lock_dir/holder")
    since=$(sed -n 's/^since=//p' "$lock_dir/holder")
    echo "pid ${pid:-?} in ${cwd:-?} since ${since:-?}"
  else
    # `date -r <file>` prints the file's mtime on both BSD/macOS date and GNU
    # coreutils date (`--reference`). Not `stat`: its `-f` is a format string on
    # BSD but "filesystem status" on GNU, so one form can't serve both.
    since=$(date -r "$lock_dir" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || echo '?')
    echo "an unknown process (no holder file — a hand-rolled mkdir lock) since ${since}"
  fi
}

reclaim_if_stale() {
  # Returns 0 if the lock was stale and has been removed.
  local pid
  [[ -r "$lock_dir/holder" ]] || return 1
  pid=$(sed -n 's/^pid=//p' "$lock_dir/holder")
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "swift-test.sh: reclaiming stale lock $lock_dir ($(holder_summary); pid $pid is gone)" >&2
    rm -rf "$lock_dir"
    return 0
  fi
  return 1
}

have_lock=0
release_lock() {
  if (( have_lock )); then
    rm -rf "$lock_dir"
    have_lock=0
  fi
}

acquire_lock() {
  local announced=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    bail_if_signalled
    if reclaim_if_stale; then continue; fi
    if [[ "$lock_wait" == "fail" ]]; then
      echo "swift-test.sh: swift test lock $lock_dir is held by $(holder_summary); ANGLESITE_TEST_LOCK_WAIT=fail, giving up" >&2
      exit 75  # EX_TEMPFAIL
    fi
    echo "swift-test.sh: waiting for swift test lock $lock_dir held by $(holder_summary)…" >&2
    announced=1
    poll_sleep "$poll_seconds"
  done
  have_lock=1
  bail_if_signalled   # signal landed around the winning mkdir: EXIT trap releases it
  {
    echo "pid=$$"
    echo "cwd=$PWD"
    echo "since=$(date +%Y-%m-%dT%H:%M:%S%z)"
    echo "args=$*"
  } >"$lock_dir/holder"
  (( announced )) && echo "swift-test.sh: acquired swift test lock $lock_dir" >&2
  return 0
}

# ---- Run ---------------------------------------------------------------------

trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'release_lock' EXIT

if needs_lock; then
  acquire_lock "$@"
  echo "swift-test.sh: holding swift test lock $lock_dir (pid $$) for: swift test $*" >&2
elif [[ "$lock_mode" == "never" ]]; then
  echo "swift-test.sh: ANGLESITE_TEST_LOCK=never; running unlocked" >&2
else
  echo "swift-test.sh: --filter ${filters[*]} matches no live-model suite; running unlocked" >&2
fi

# Not `exec`: the EXIT trap must outlive `swift test` to release the lock. The
# child is backgrounded so a signal reaches this shell's traps at once instead
# of after the run ends — but bash starts `&` children with SIGINT ignored, so
# the subshell resets it first or a forwarded/terminal Ctrl-C would never stop
# the run (confirmed empirically while writing this).
bail_if_signalled
( trap - INT; exec swift test "$@" ) &
child=$!
# A signal that landed before `child` was set was only recorded — deliver it now.
[[ -n "$pending_signal" ]] && kill -s "$pending_signal" "$child" 2>/dev/null || true
status=0
wait "$child" || status=$?
# A trapped signal interrupts `wait` with 128+N before the child has exited;
# wait again for the child's real status.
while (( status > 128 )) && kill -0 "$child" 2>/dev/null; do
  wait "$child" || status=$?
done
exit "$status"
