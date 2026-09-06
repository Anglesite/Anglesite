#!/usr/bin/env bash
#
# Regression test for #1903 (sleep-lint baseline drain, batch 2 of 2): asserts the 10
# AnglesiteCoreTests baseline entries this issue targets are gone from
# scripts/lib/sleep-lint-baseline.txt, and that every Task.sleep/Thread.sleep/usleep(...) call
# site remaining in those 9 files carries the `// sleep-is-subject` marker.
#
# scripts/check-test-sleep-marker.sh alone can't tell these apart from #1902's batch (still
# grandfathered) because it treats "in the baseline" and "marked" as equally passing — this
# test checks the stronger, batch-2-specific property: these particular sites are drained, not
# merely still tolerated by the baseline. Fails on a tree where the baseline still carries any
# of the 10 target lines.
#
# Pure git grep/awk against the real working tree (no fixture, no external dependency) — runs
# in CI's linux-build-test lane alongside the other self-contained .sh tests.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

baseline_file="scripts/lib/sleep-lint-baseline.txt"
overall_status=0

# path<TAB>trimmed-source-line, exactly as scripts/lib/sleep-lint-baseline.txt formats it.
target_files=(
  "Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeTests.swift"
  "Tests/AnglesiteCoreTests/MCPApplyEditRouterTests.swift"
  "Tests/AnglesiteCoreTests/MCPClientHTTPEndToEndTests.swift"
  "Tests/AnglesiteCoreTests/MCPClientTests.swift"
  "Tests/AnglesiteCoreTests/ProcessSupervisorShutdownTests.swift"
  "Tests/AnglesiteCoreTests/SecurityReportsModelTests.swift"
  "Tests/AnglesiteCoreTests/SiteFileWatcherTests.swift"
  "Tests/AnglesiteCoreTests/SyncSchedulerTests.swift"
  "Tests/AnglesiteCoreTests/VsockTCPProxyTests.swift"
)

# The exact 10 lines #1903 targets (batch 2 of #1810's ~60-site backlog) — see the issue body.
target_baseline_lines=(
$'Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeTests.swift\ttry await Task.sleep(for: .milliseconds(10))'
$'Tests/AnglesiteCoreTests/MCPApplyEditRouterTests.swift\ttry? await Task.sleep(nanoseconds: 50_000_000)'
$'Tests/AnglesiteCoreTests/MCPClientHTTPEndToEndTests.swift\ttry await Task.sleep(nanoseconds: 200_000_000)'
$'Tests/AnglesiteCoreTests/MCPClientTests.swift\ttry await Task.sleep(nanoseconds: 50_000_000)'
$'Tests/AnglesiteCoreTests/ProcessSupervisorShutdownTests.swift\ttry await Task.sleep(for: .milliseconds(100))   // let the waiter park on the exit continuation'
$'Tests/AnglesiteCoreTests/ProcessSupervisorShutdownTests.swift\ttry? await Task.sleep(nanoseconds: 100_000_000)'
$'Tests/AnglesiteCoreTests/SecurityReportsModelTests.swift\ttry await Task.sleep(nanoseconds: 200_000_000)'
$'Tests/AnglesiteCoreTests/SiteFileWatcherTests.swift\ttry? await Task.sleep(nanoseconds: 300_000_000)'
$'Tests/AnglesiteCoreTests/SyncSchedulerTests.swift\ttry await Task.sleep(for: .milliseconds(50))'
$'Tests/AnglesiteCoreTests/VsockTCPProxyTests.swift\ttry? await Task.sleep(for: .milliseconds(5))'
)

echo "-- checking $baseline_file no longer carries the 10 batch-2 entries --"
for entry in "${target_baseline_lines[@]}"; do
  if grep -qxF "$entry" "$baseline_file"; then
    echo "FAIL still in baseline: $entry"
    overall_status=1
  else
    echo "ok   drained from baseline: $entry"
  fi
done

echo "-- checking every remaining sleep call in the 9 target files carries the marker --"
for file in "${target_files[@]}"; do
  unmarked="$(
    git grep -n -E 'Task\.sleep|Thread\.sleep|usleep\(' -- "$file" 2>/dev/null \
      | grep -v 'sleep-is-subject' \
      | grep -vE ':\s*//' \
      || true
  )"
  if [[ -n "$unmarked" ]]; then
    echo "FAIL unmarked sleep(s) remain in $file:"
    printf '  %s\n' "$unmarked"
    overall_status=1
  else
    echo "ok   $file: every remaining sleep call is marked"
  fi
done

exit "$overall_status"
