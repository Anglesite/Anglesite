#!/usr/bin/env bash
#
# Exercises scripts/swift-test.sh against a stubbed `swift` on PATH and a
# throwaway lock directory (ANGLESITE_TEST_LOCK_DIR), so no case touches the
# real /tmp/anglesite-swift-test.lock or compiles anything (#1594):
#
#   * args pass through to `swift test` unchanged
#   * a --filter run of non-model suites runs unlocked; one naming a live-model
#     suite (or ANGLESITE_TEST_LOCK=always) takes the lock
#   * a second full run waits for the first and only starts after it finishes
#   * a hand-rolled bare `mkdir` lock is waited on (never reclaimed), reported
#     with a well-formed mtime timestamp, and the waiter proceeds once it's rmdir'd
#   * a stale lock whose holder pid is dead is reclaimed
#   * the lock is released on normal exit, on `swift test` failure, and on
#     SIGINT / SIGTERM (forwarded to `swift test`)
#   * SIGINT / SIGTERM while still *waiting* for the lock exits 130 / 143 at
#     once (not after the poll interval), never runs `swift test`, and leaves
#     the other holder's lock alone
#   * ANGLESITE_TEST_LOCK_WAIT=fail exits 75 immediately while the lock is held
#
# Not wired into CI (nothing there contends for a model); run it locally after
# changing swift-test.sh:  bash scripts/swift-test.test.sh
# It is plain POSIX-ish bash + perl, so it also runs on Linux — useful for the
# GNU-coreutils side of the timestamp case.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/swift-test.sh"

tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

overall_status=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; overall_status=1; }
assert_exists() { [[ -e "$2" ]] && pass "$1" || fail "$1 (missing: $2)"; }
assert_gone()   { [[ ! -e "$2" ]] && pass "$1" || fail "$1 (still exists: $2)"; }
assert_output() { grep -qF -- "$2" "$3" && pass "$1" || { fail "$1 (no match: $2)"; sed 's/^/  | /' "$3"; }; }
assert_output_re() { grep -qE -- "$2" "$3" && pass "$1" || { fail "$1 (no regex match: $2)"; sed 's/^/  | /' "$3"; }; }
assert_no_output() { grep -qF -- "$2" "$3" && { fail "$1 (unexpected match: $2)"; sed 's/^/  | /' "$3"; } || pass "$1"; }
assert_status() { [[ "$2" -eq "$3" ]] && pass "$1" || fail "$1 (expected exit $2, got $3)"; }

# ---- Stub swift: logs its args and start/end times, sleeps, exits as told ----

stubs="$tmp/stubs"
mkdir -p "$stubs"
cat >"$stubs/swift" <<'STUB'
#!/usr/bin/env bash
echo "start $(date +%s) args: $*" >>"$FAKE_SWIFT_LOG"
sleeper=""
# Take the sleeper down with us so an interrupted case leaves no orphan `sleep`
# behind (this Mac is shared with other agents; never `pkill` by name here).
trap 'kill "${sleeper:-}" 2>/dev/null; echo "interrupted $(date +%s)" >>"$FAKE_SWIFT_LOG"; exit 130' INT TERM
sleep "${FAKE_SWIFT_SLEEP:-0}" & sleeper=$!
wait "$sleeper"
echo "end $(date +%s)" >>"$FAKE_SWIFT_LOG"
exit "${FAKE_SWIFT_EXIT:-0}"
STUB
chmod +x "$stubs/swift"

lock="$tmp/test.lock"
# POLL_SECONDS: the wrapper's wait-loop poll interval for a case (default 1s; the
# interrupted-while-waiting cases raise it to prove the exit doesn't wait it out).
run() {
  ANGLESITE_TEST_LOCK_DIR="$lock" ANGLESITE_TEST_LOCK_POLL_SECONDS="${POLL_SECONDS:-1}" \
    PATH="$stubs:$PATH" bash "$TARGET" "$@"
}
# Background a wrapper the way a terminal or an agent's tool call launches it —
# with default signal dispositions. A bare `run … &` from this script would hand
# the wrapper SIGINT-ignored (bash's rule for `&` children without job control),
# which makes its INT trap a no-op and the SIGINT cases meaningless.
spawn() {
  ANGLESITE_TEST_LOCK_DIR="$lock" ANGLESITE_TEST_LOCK_POLL_SECONDS="${POLL_SECONDS:-1}" \
    PATH="$stubs:$PATH" exec perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV' bash "$TARGET" "$@"
}
wait_for_file() { # wait_for_file <seconds> <path>
  local i
  for ((i = 0; i < $1 * 10; i++)); do [[ -e "$2" ]] && return 0; sleep 0.1; done
  return 1
}
wait_for_output() { # wait_for_output <seconds> <string> <file>
  local i
  for ((i = 0; i < $1 * 10; i++)); do grep -qF -- "$2" "$3" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
wait_bounded() { # wait_bounded <seconds> <pid> — SIGKILLs and returns 1 if still alive
  local i
  for ((i = 0; i < $1 * 10; i++)); do kill -0 "$2" 2>/dev/null || return 0; sleep 0.1; done
  kill -9 "$2" 2>/dev/null || true
  return 1
}
# The "since" a bare-mkdir holder is reported with: the lock dir's mtime as
# YYYY-MM-DDTHH:MM:SS±HHMM, and nothing else in front of it (#1722 review: the
# GNU `stat` fallback used to prepend filesystem garbage on Linux).
since_re='a hand-rolled mkdir lock\) since [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}'

# ---- Case 1: passthrough + unlocked filtered run ---------------------------

echo "== filtered non-model run =="
log="$tmp/case1.swift.log"; out="$tmp/case1.out"
FAKE_SWIFT_LOG="$log" run --filter SiteStoreTests -c debug >"$out" 2>&1 || fail "case1 exited $?"
assert_output "args pass through to swift test" "args: test --filter SiteStoreTests -c debug" "$log"
assert_output "filtered run reports unlocked" "matches no live-model suite; running unlocked" "$out"
assert_no_output "filtered run never took the lock" "holding swift test lock" "$out"

echo "== filtered live-model run =="
log="$tmp/case1b.swift.log"; out="$tmp/case1b.out"
FAKE_SWIFT_LOG="$log" run --filter 'FoundationModelAssistant' >"$out" 2>&1 || fail "case1b exited $?"
assert_output "live-model filter takes the lock" "holding swift test lock $lock" "$out"
assert_gone "lock released after filtered live-model run" "$lock"
log="$tmp/case1c.swift.log"; out="$tmp/case1c.out"
FAKE_SWIFT_LOG="$log" run --filter=GenerableTypes >"$out" 2>&1 || fail "case1c exited $?"
assert_output "--filter=X spelling is recognised" "holding swift test lock $lock" "$out"
log="$tmp/case1d.swift.log"; out="$tmp/case1d.out"
FAKE_SWIFT_LOG="$log" ANGLESITE_TEST_LOCK=always run --filter SiteStoreTests >"$out" 2>&1 || fail "case1d exited $?"
assert_output "ANGLESITE_TEST_LOCK=always forces the lock" "holding swift test lock $lock" "$out"

# ---- Case 2: second full run queues behind the first -----------------------

echo "== two concurrent full runs =="
log1="$tmp/case2a.swift.log"; out1="$tmp/case2a.out"
log2="$tmp/case2b.swift.log"; out2="$tmp/case2b.out"
FAKE_SWIFT_LOG="$log1" FAKE_SWIFT_SLEEP=3 run >"$out1" 2>&1 &
p1=$!
wait_for_file 5 "$lock/holder" || fail "first run never wrote a holder file"
FAKE_SWIFT_LOG="$log2" run >"$out2" 2>&1 &
p2=$!
wait "$p1" || fail "first run exited $?"
wait "$p2" || fail "second run exited $?"
assert_output "second run waited on the first" "waiting for swift test lock $lock held by pid" "$out2"
assert_output "wait message names the holder's cwd" "in $(cd "$SCRIPT_DIR/.." && pwd) since" "$out2"
assert_output "second run reports acquisition" "acquired swift test lock" "$out2"
end1=$(sed -n 's/^end //p' "$log1"); start2=$(sed -n 's/^start \([0-9]*\).*/\1/p' "$log2")
if [[ -n "$end1" && -n "$start2" && "$start2" -ge "$end1" ]]; then
  pass "second swift test started only after the first finished ($start2 >= $end1)"
else
  fail "second swift test overlapped the first (end1=$end1 start2=$start2)"
fi
assert_gone "lock released after both runs" "$lock"

# ---- Case 3: hand-rolled mkdir lock is waited on, never reclaimed ----------

echo "== hand-rolled bare mkdir lock =="
mkdir "$lock"
log="$tmp/case3.swift.log"; out="$tmp/case3.out"
FAKE_SWIFT_LOG="$log" run >"$out" 2>&1 &
p=$!
sleep 2.5
assert_exists "bare mkdir lock is not reclaimed" "$lock"
[[ ! -s "$log" ]] && pass "swift test not started while bare lock held" || fail "swift test started under a bare lock"
rmdir "$lock"
wait "$p" || fail "case3 run exited $?"
assert_output "waiter identifies a bare lock" "held by an unknown process (no holder file" "$out"
assert_output_re "bare lock's since is a clean mtime timestamp" "${since_re}…" "$out"
assert_output "waiter proceeds after the bare lock is released" "acquired swift test lock" "$out"
assert_exists "swift test ran after release" "$log"

# ---- Case 4: stale lock from a dead pid is reclaimed -----------------------

echo "== stale lock =="
sleep 0.1 & dead=$!; wait "$dead"
mkdir "$lock"
printf 'pid=%s\ncwd=/nowhere\nsince=2026-01-01T00:00:00+0000\n' "$dead" >"$lock/holder"
log="$tmp/case4.swift.log"; out="$tmp/case4.out"
FAKE_SWIFT_LOG="$log" run >"$out" 2>&1 || fail "case4 exited $?"
assert_output "stale lock is reclaimed" "reclaiming stale lock $lock (pid $dead in /nowhere" "$out"
assert_no_output "stale lock did not make the run wait" "waiting for swift test lock" "$out"
assert_exists "swift test ran after reclaim" "$log"
assert_gone "lock released after reclaim run" "$lock"

# ---- Case 5: release on failure and on SIGINT ------------------------------

echo "== release on swift test failure =="
log="$tmp/case5a.swift.log"; out="$tmp/case5a.out"
st=0
FAKE_SWIFT_LOG="$log" FAKE_SWIFT_EXIT=7 run >"$out" 2>&1 || st=$?
assert_status "swift test exit status propagates" 7 "$st"
assert_gone "lock released after failing run" "$lock"

echo "== release on SIGINT / SIGTERM while swift test runs =="
for sig in INT TERM; do
  log="$tmp/case5-$sig.swift.log"; out="$tmp/case5-$sig.out"
  FAKE_SWIFT_LOG="$log" FAKE_SWIFT_SLEEP=30 spawn >"$out" 2>&1 &
  p=$!
  wait_for_file 5 "$lock/holder" || fail "SIG$sig run never took the lock"
  sleep 0.5
  kill -s "$sig" "$p"
  wait_bounded 10 "$p" || fail "SIG$sig run still alive 10s after the signal (killed)"
  st=0; wait "$p" || st=$?
  assert_gone "lock released after SIG$sig" "$lock"
  assert_output "SIG$sig was forwarded to swift test" "interrupted" "$log"
  [[ "$st" -ne 0 ]] && pass "SIG$sig run exits non-zero ($st)" || fail "SIG$sig run exited 0"
  assert_no_output "SIG$sig run did not run to completion" "end " "$log"
done

# ---- Case 5c: SIGINT / SIGTERM while still waiting for the lock ------------
#
# The #1722 review reproduced Ctrl-C during the wait loop hanging the wrapper
# (the INT trap forwarded to a not-yet-set child, i.e. did nothing, and the
# loop kept polling). The poll interval is raised well past the assertion
# window, so passing here means the exit did not merely wait the sleep out.

echo "== SIGINT / SIGTERM while waiting for the lock =="
for sig in INT TERM; do
  case "$sig" in INT) expected=130 ;; TERM) expected=143 ;; esac
  mkdir "$lock"
  log="$tmp/case5c-$sig.swift.log"; out="$tmp/case5c-$sig.out"
  FAKE_SWIFT_LOG="$log" POLL_SECONDS=45 spawn >"$out" 2>&1 &
  p=$!
  wait_for_output 5 "waiting for swift test lock" "$out" || fail "SIG$sig-while-waiting run never started waiting"
  sent=$(date +%s)
  kill -s "$sig" "$p"
  wait_bounded 10 "$p" || fail "SIG$sig-while-waiting run still alive 10s after the signal (killed)"
  st=0; wait "$p" || st=$?
  elapsed=$(( $(date +%s) - sent ))
  assert_status "SIG$sig while waiting exits $expected" "$expected" "$st"
  [[ "$elapsed" -le 5 ]] && pass "SIG$sig while waiting exits promptly (${elapsed}s, poll is 45s)" \
    || fail "SIG$sig while waiting took ${elapsed}s to exit"
  assert_output "SIG$sig while waiting says why it stopped" "interrupted (SIG$sig) before swift test started" "$out"
  assert_exists "SIG$sig while waiting leaves the foreign lock alone" "$lock"
  [[ ! -e "$log" ]] && pass "SIG$sig while waiting never ran swift test" || fail "SIG$sig while waiting ran swift test"
  rmdir "$lock"
done

# ---- Case 6: fail-fast mode ------------------------------------------------

echo "== ANGLESITE_TEST_LOCK_WAIT=fail =="
mkdir "$lock"
log="$tmp/case6.swift.log"; out="$tmp/case6.out"
st=0
FAKE_SWIFT_LOG="$log" ANGLESITE_TEST_LOCK_WAIT=fail run >"$out" 2>&1 || st=$?
assert_status "fail mode exits 75 while held" 75 "$st"
assert_output "fail mode says who holds it" "is held by an unknown process" "$out"
assert_output_re "fail mode reports a clean mtime timestamp" "${since_re};" "$out"
[[ ! -e "$log" ]] && pass "fail mode never ran swift test" || fail "fail mode ran swift test"
assert_exists "fail mode leaves the foreign lock alone" "$lock"
rmdir "$lock"

echo
if [[ "$overall_status" -eq 0 ]]; then echo "PASS: all swift-test.sh cases"; else echo "FAIL: see above"; fi
exit "$overall_status"
