#!/usr/bin/env bash
# Rejects a hand-rolled `UserDefaults(suiteName: "...")` literal under Tests/ (#1745).
#
# #1727 gave every test suite that needs defaults an isolated, self-cleaning helper —
# AnglesiteTestSupport's TemporaryUserDefaults / withTemporaryUserDefaults (see
# Tests/AnglesiteTestSupport/TemporaryUserDefaults.swift). A test that instead writes
# `UserDefaults(suiteName: "some-literal-name")` directly bypasses that scratch-directory
# cleanup and can reintroduce the original leak: cfprefsd materializes a plain suite name as
# `~/Library/Preferences/<suite>.plist`, and nothing short of deleting the helper's backing
# directory reclaims it (see that file's doc comment for why). scripts/check-test-userdefaults-leak.sh
# catches the leak itself, after the fact, from a separate process; this is the earlier,
# static half — it catches the bypass at review time, before any test even runs.
#
# Scoped to literal string arguments only (`UserDefaults(suiteName: "..."`): a variable, e.g.
# `UserDefaults(suiteName: scratch.suiteName)` re-opening an existing TemporaryUserDefaults
# suite by name, is exactly how the helper's own tests verify persistence and must stay legal.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# The helper's own implementation is the one legitimate place a literal-shaped suite name
# appears under Tests/ — both in real code (constructing UserDefaults(suiteName: suiteName)
# is fine, but its doc comment illustrates the literal form in prose) and it's exempt outright
# rather than parsed line-by-line.
exempt_file="Tests/AnglesiteTestSupport/TemporaryUserDefaults.swift"

violations=()
while IFS=: read -r file line _; do
  [[ "$file" == "$exempt_file" ]] && continue
  violations+=("$file:$line")
done < <(git grep -n -E 'UserDefaults\(suiteName: *"' -- Tests || true)

if [[ ${#violations[@]} -gt 0 ]]; then
  echo "error: ${#violations[@]} direct UserDefaults(suiteName: \"...\") literal(s) found under Tests/:" >&2
  for v in "${violations[@]}"; do
    echo "  $v" >&2
  done
  echo >&2
  echo "Use AnglesiteTestSupport's TemporaryUserDefaults / withTemporaryUserDefaults instead of a" >&2
  echo "hand-rolled suite name — see Tests/AnglesiteTestSupport/TemporaryUserDefaults.swift and" >&2
  echo "CONTRIBUTING.md ▸ Testing for why (#1727)." >&2
  exit 1
fi

echo "✓ no direct UserDefaults(suiteName: \"...\") literals under Tests/."
