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
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Tests/AnglesiteTestSupport hosts the shared polling primitives (WaitUntil.swift,
# ManualDebounceGate.swift) and adjacent E2E test infrastructure (E2EServer.swift) — these
# implement the real sleep/timeout mechanics the rest of Tests/ is meant to delegate to, so a
# raw sleep here is the seam itself, not debt.
exempt_dir="Tests/AnglesiteTestSupport/"

baseline_file="scripts/lib/sleep-lint-baseline.txt"
marker="sleep-is-subject"

declare -A baseline
while IFS=$'\t' read -r base_file base_content; do
  [[ -z "$base_file" || "$base_file" == \#* ]] && continue
  baseline["$base_file"$'\x1c'"$base_content"]=1
done < "$baseline_file"

violations=()
while IFS=: read -r file lineno content; do
  [[ "$file" == "$exempt_dir"* ]] && continue

  trimmed="${content#"${content%%[![:space:]]*}"}"  # strip leading whitespace
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"  # strip trailing whitespace

  # A doc/prose comment line mentioning "Task.sleep" isn't a call site.
  case "$trimmed" in
    "//"*) continue ;;
  esac

  # Marked inline — accepted without further checks.
  case "$content" in
    *"$marker"*) continue ;;
  esac

  key="$file"$'\x1c'"$trimmed"
  [[ -n "${baseline[$key]:-}" ]] && continue

  violations+=("$file:$lineno: $trimmed")
done < <(git grep -n -E 'Task\.sleep|Thread\.sleep|usleep\(' -- Tests || true)

if [[ ${#violations[@]} -gt 0 ]]; then
  echo "error: ${#violations[@]} unjustified Task.sleep/Thread.sleep/usleep(...) call(s) found under Tests/:" >&2
  for v in "${violations[@]}"; do
    echo "  $v" >&2
  done
  echo >&2
  echo "Wait for the actual condition instead — AnglesiteTestSupport's waitUntil (or" >&2
  echo "ManualDebounceGate for a model's debounce seam) — see Tests/AnglesiteTestSupport/WaitUntil.swift" >&2
  echo "and CONTRIBUTING.md ▸ Testing. If the sleep genuinely is deliberate (the scenario under test," >&2
  echo "a negative assertion with no event to wait for, a real wall-clock-elapsed proof, a real" >&2
  echo "E2E/subprocess retry, ...), add a \`// $marker\` trailing comment on that line instead of" >&2
  echo "adding it to $baseline_file — that file is a one-time debt snapshot, not an escape hatch." >&2
  exit 1
fi

echo "✓ no unjustified Task.sleep/Thread.sleep/usleep(...) calls under Tests/ (${#baseline[@]} grandfathered, marker: // $marker)."
