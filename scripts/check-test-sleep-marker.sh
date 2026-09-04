#!/usr/bin/env bash
# Rejects a new Task.sleep/Thread.sleep/usleep(...) call under Tests/ that isn't marked as
# deliberate (#1810).
#
# #1344/#1721's flake class is a test that sleeps a guessed fixed interval and then asserts,
# instead of waiting for the actual condition — AnglesiteTestSupport's waitUntil (or
# ManualDebounceGate, for a model's own debounce seam) is the event-driven replacement (see
# Tests/AnglesiteTestSupport/WaitUntil.swift). Not every sleep is that pattern, though: a fake's
# deliberate simulated latency, a "settle briefly, confirm nothing happened" negative assertion
# (there's no event to wait for), a real wall-clock-elapsed proof, a cancellation sentinel that
# never resolves, or a real E2E/subprocess retry are all legitimate and reviewed case by case in
# #1810's migration commits. Mark one of those with a `// sleep-is-subject` trailing comment on
# the same line — this check accepts any line carrying that marker without asking why.
#
# scripts/lib/sleep-lint-baseline.txt grandfathers every site that already existed when this
# lint was added, matched by trimmed line content (not line number, so unrelated edits nearby
# don't trip it) — see that file's own header for why a one-time baseline instead of requiring
# every existing site to be marked before this check could land. A NEW site (not in the
# baseline) must either move to waitUntil or carry the marker; growing the baseline itself is
# not an escape hatch.
#
# The matching lives entirely in awk, not a bash associative array: this runs on build-test's
# macos-26 runner under the default `/bin/bash` step shell, which is Apple's ancient bash 3.2
# (GPLv3-avoidance freeze) — `declare -A` is a bash 4+ feature and doesn't exist there.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

baseline_file="scripts/lib/sleep-lint-baseline.txt"
marker="sleep-is-subject"
# Tests/AnglesiteTestSupport hosts the shared polling primitives (WaitUntil.swift,
# ManualDebounceGate.swift) and adjacent E2E test infrastructure (E2EServer.swift) — these
# implement the real sleep/timeout mechanics the rest of Tests/ is meant to delegate to, so a
# raw sleep here is the seam itself, not debt.
exempt_prefix="Tests/AnglesiteTestSupport/"

violations="$(
  git grep -n -E 'Task\.sleep|Thread\.sleep|usleep\(' -- Tests 2>/dev/null | awk \
    -F '\t' -v marker="$marker" -v exempt_prefix="$exempt_prefix" '
  # First input (the baseline file, tab-separated `path<TAB>content`): record grandfathered keys.
  NR == FNR {
    if ($0 ~ /^#/ || $0 == "") next
    baseline[$1 SUBSEP $2] = 1
    next
  }
  # Second input (git grep -n output, colon-separated `path:lineno:content`): find violations.
  {
    line = $0
    c1 = index(line, ":")
    file = substr(line, 1, c1 - 1)
    rest = substr(line, c1 + 1)
    c2 = index(rest, ":")
    lineno = substr(rest, 1, c2 - 1)
    content = substr(rest, c2 + 1)

    if (index(file, exempt_prefix) == 1) next

    trimmed = content
    sub(/^[ \t]+/, "", trimmed)
    sub(/[ \t]+$/, "", trimmed)

    # A doc/prose comment line mentioning "Task.sleep" is not a call site.
    if (trimmed ~ /^\/\//) next

    # Marked inline — accepted without further checks.
    if (index(content, marker) > 0) next

    if ((file SUBSEP trimmed) in baseline) next

    print file ":" lineno ": " trimmed
  }
' "$baseline_file" - || true
)"

if [[ -n "$violations" ]]; then
  count="$(printf '%s\n' "$violations" | wc -l | tr -d ' ')"
  echo "error: $count unjustified Task.sleep/Thread.sleep/usleep(...) call(s) found under Tests/:" >&2
  printf '  %s\n' "$violations" >&2
  echo >&2
  echo "Wait for the actual condition instead — AnglesiteTestSupport's waitUntil (or" >&2
  echo "ManualDebounceGate for a model's debounce seam) — see Tests/AnglesiteTestSupport/WaitUntil.swift" >&2
  echo "and CONTRIBUTING.md ▸ Testing. If the sleep genuinely is deliberate (the scenario under test," >&2
  echo "a negative assertion with no event to wait for, a real wall-clock-elapsed proof, a real" >&2
  echo "E2E/subprocess retry, ...), add a \`// $marker\` trailing comment on that line instead of" >&2
  echo "adding it to $baseline_file — that file is a one-time debt snapshot, not an escape hatch." >&2
  exit 1
fi

echo "✓ no unjustified Task.sleep/Thread.sleep/usleep(...) calls under Tests/ (marker: // $marker)."
