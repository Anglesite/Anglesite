#!/usr/bin/env bash
#
# Self-contained tests for scripts/check-localization-catalog.sh — in particular its
# owner-vocabulary lint (#1963, decision D1): a catalog key that uses git/npm/wrangler/MCP/
# file-layout vocabulary fails the check unless it is allowlisted in
# scripts/lib/owner-vocabulary-allowlist.txt or its only call sites are the Debug pane.
#
# Every case runs the real script against a throwaway git repo built from fixtures (a tiny
# Localizable.xcstrings, a view file, an optional DebugPaneView.swift, an optional allowlist),
# so nothing here touches the repo's own catalog. Needs only bash, git, and python3 — the same
# dependencies as the script under test — and runs in CI's `localization-catalog` lane right
# after the script itself (that lane is where python3 is guaranteed; the swift:6.3.3-noble
# image behind linux-build-test doesn't ship it).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_under_test="$script_dir/check-localization-catalog.sh"

overall_status=0
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-localization-catalog-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

# make_repo <name> — creates $tmp_root/<name> as a git repo with the expected layout and
# echoes its path. Callers then write fixtures into it.
make_repo() {
  local repo="$tmp_root/$1"
  mkdir -p "$repo/Sources/AnglesiteApp" "$repo/scripts/lib"
  git -C "$repo" init -q
  echo "$repo"
}

# run_check <repo> — runs the script from inside <repo>, capturing combined output and status.
run_check() {
  local repo="$1"
  set +e
  output="$(cd "$repo" && bash "$script_under_test" 2>&1)"
  status=$?
  set -e
}

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; echo "$output" | sed 's/^/     | /'; overall_status=1; }

# A catalog from a list of keys (each key's entry is `{}` — the shape Xcode writes for a plain
# source-language string).
write_catalog() {
  local repo="$1"; shift
  python3 - "$repo/Sources/AnglesiteApp/Localizable.xcstrings" "$@" <<'PY'
import json, sys
path, keys = sys.argv[1], sys.argv[2:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"sourceLanguage": "en", "strings": {k: {} for k in keys}, "version": "1.0"}, f, indent=2)
    f.write("\n")
PY
}

echo "-- clean catalog passes --"
repo="$(make_repo clean)"
write_catalog "$repo" "Hello" "Publish a JSON feed from your source code"
cat > "$repo/Sources/AnglesiteApp/HomeView.swift" <<'EOF'
import SwiftUI
struct HomeView: View {
    var body: some View {
        Text("Hello")
        Text("Publish a JSON feed from your source code")
    }
}
EOF
run_check "$repo"
if [[ $status -eq 0 ]] && grep -q "no key uses owner-surface vocabulary" <<<"$output"; then
  pass "clean catalog (and 'JSON feed' / 'source code' aren't false positives)"
else
  fail "clean catalog should pass (status=$status)"
fi

echo "-- a literal with no catalog key still fails (regression) --"
repo="$(make_repo missing)"
write_catalog "$repo" "Hello"
cat > "$repo/Sources/AnglesiteApp/HomeView.swift" <<'EOF'
import SwiftUI
struct HomeView: View { var body: some View { Text("Goodbye") } }
EOF
run_check "$repo"
if [[ $status -ne 0 ]] && grep -q 'no matching key' <<<"$output" && grep -q '"Goodbye"' <<<"$output"; then
  pass "missing literal fails and names it"
else
  fail "missing literal should fail (status=$status)"
fi

echo "-- a bare error-property assignment still fails (regression) --"
repo="$(make_repo bare)"
write_catalog "$repo"
cat > "$repo/Sources/AnglesiteApp/Model.swift" <<'EOF'
final class Model { var errorMessage: String?; func load() { errorMessage = "Boom" } }
EOF
run_check "$repo"
if [[ $status -ne 0 ]] && grep -q 'bare string literal' <<<"$output"; then
  pass "bare errorMessage assignment fails"
else
  fail "bare errorMessage assignment should fail (status=$status)"
fi

echo "-- owner-surface vocabulary in a catalog key fails --"
repo="$(make_repo vocab)"
write_catalog "$repo" "Commit and push working-tree changes to your current branch" \
  "Couldn't find this site's wrangler.toml" "Dev server stopped" "Copy SHA" \
  "Check git status in this site's Source folder" "Undo unavailable: MCP not running." \
  "npm run build failed (exit 1)" "Restricted content in Config/" "Astro Website…"
cat > "$repo/Sources/AnglesiteApp/HomeView.swift" <<'EOF'
import SwiftUI
struct HomeView: View {
    var body: some View {
        Text("Commit and push working-tree changes to your current branch")
        Text("Couldn't find this site's wrangler.toml")
        Text("Dev server stopped")
        Button("Copy SHA") {}
        Text("Check git status in this site's Source folder")
        Text("Undo unavailable: MCP not running.")
        Text("npm run build failed (exit 1)")
        Text("Restricted content in Config/")
        Button("Astro Website…") {}
    }
}
EOF
run_check "$repo"
if [[ $status -ne 0 ]] && grep -q "9 Sources/AnglesiteApp/Localizable.xcstrings key(s) use git/npm/wrangler/MCP/file-layout" <<<"$output" \
   && grep -q "'Commit' in" <<<"$output" && grep -q "'wrangler' in" <<<"$output" \
   && grep -q "'Dev server' in" <<<"$output" && grep -q "'SHA' in" <<<"$output" \
   && grep -q "'git' in" <<<"$output" && grep -q "'MCP' in" <<<"$output" \
   && grep -q "'npm' in" <<<"$output" && grep -q "'Config/' in" <<<"$output" \
   && grep -q "'Astro' in" <<<"$output" \
   && grep -q "owner-vocabulary-allowlist.txt" <<<"$output"; then
  pass "all nine vocabulary hits are reported with the matched word"
else
  fail "vocabulary hits should fail and name each word (status=$status)"
fi

echo "-- an allowlisted key passes --"
repo="$(make_repo allowlisted)"
cat > "$repo/Sources/AnglesiteApp/SettingsView.swift" <<'EOF'
import SwiftUI
struct SettingsView: View { var body: some View { Section("Safari MCP Bridge") { Text("x") } } }
EOF
write_catalog "$repo" "Safari MCP Bridge" "x"
cat > "$repo/scripts/lib/owner-vocabulary-allowlist.txt" <<'EOF'
# Advanced developer section, gated by #1964.

Safari MCP Bridge
EOF
run_check "$repo"
if [[ $status -eq 0 ]] && ! grep -q "warning:" <<<"$output"; then
  pass "allowlisted key passes without a stale-entry warning"
else
  fail "allowlisted key should pass cleanly (status=$status)"
fi

echo "-- a key used only by the Debug pane is exempt --"
repo="$(make_repo debugpane)"
write_catalog "$repo" "git status" "%@ exited with exit code %lld" "Hello"
cat > "$repo/Sources/AnglesiteApp/DebugPaneView.swift" <<'EOF'
import SwiftUI
struct DebugPaneView: View {
    let name = "x"; let code = 1
    var body: some View {
        Text("git status")
        Text("\(name) exited with exit code \(code)")
    }
}
EOF
cat > "$repo/Sources/AnglesiteApp/HomeView.swift" <<'EOF'
import SwiftUI
struct HomeView: View { var body: some View { Text("Hello") } }
EOF
run_check "$repo"
if [[ $status -eq 0 ]]; then
  pass "Debug-pane-only keys (plain and interpolated) are exempt"
else
  fail "Debug-pane-only keys should be exempt (status=$status)"
fi

echo "-- a key the Debug pane shares with another surface (documented limit) --"
repo="$(make_repo debugpane-shared)"
write_catalog "$repo" "git status"
cat > "$repo/Sources/AnglesiteApp/DebugPaneView.swift" <<'EOF'
import SwiftUI
struct DebugPaneView: View { var body: some View { Text("git status") } }
EOF
cat > "$repo/Sources/AnglesiteApp/HomeView.swift" <<'EOF'
import SwiftUI
struct HomeView: View { var body: some View { Text("git status") } }
EOF
run_check "$repo"
# The lint keys off the catalog (it can't tell which view a key came from), so a key that the
# Debug pane happens to share is exempt there too — document that limit rather than pretend
# otherwise: the catalog key is exempt, and the check passes.
if [[ $status -eq 0 ]]; then
  pass "a Debug-pane literal exempts the catalog key wherever else it appears (documented limit)"
else
  fail "shared Debug-pane key is expected to pass under the documented limit (status=$status)"
fi

echo "-- a stale allowlist entry warns but doesn't fail --"
repo="$(make_repo stale)"
write_catalog "$repo" "Hello"
cat > "$repo/Sources/AnglesiteApp/HomeView.swift" <<'EOF'
import SwiftUI
struct HomeView: View { var body: some View { Text("Hello") } }
EOF
cat > "$repo/scripts/lib/owner-vocabulary-allowlist.txt" <<'EOF'
This key was rewritten and no longer exists
EOF
run_check "$repo"
if [[ $status -eq 0 ]] && grep -q "warning: 1 scripts/lib/owner-vocabulary-allowlist.txt entry no longer match" <<<"$output" \
   && grep -q '"This key was rewritten and no longer exists"' <<<"$output"; then
  pass "stale allowlist entry is reported as a warning"
else
  fail "stale allowlist entry should warn without failing (status=$status)"
fi

echo "-- word boundaries: 'pushover', 'branching out', 'gitignore' aren't hits; 'pushed' is --"
repo="$(make_repo boundaries)"
write_catalog "$repo" "Pushover notifications" "Branching out to new readers" "A .gitignore-style list" "Changes were pushed"
cat > "$repo/Sources/AnglesiteApp/HomeView.swift" <<'EOF'
import SwiftUI
struct HomeView: View {
    var body: some View {
        Text("Pushover notifications")
        Text("Branching out to new readers")
        Text("A .gitignore-style list")
        Text("Changes were pushed")
    }
}
EOF
run_check "$repo"
if [[ $status -ne 0 ]] && grep -q "1 Sources/AnglesiteApp/Localizable.xcstrings key(s) use" <<<"$output" \
   && grep -q "'pushed' in \"Changes were pushed\"" <<<"$output"; then
  pass "only the whole-word hit is reported"
else
  fail "expected exactly one whole-word hit (status=$status)"
fi

if [[ $overall_status -eq 0 ]]; then
  echo "all check-localization-catalog.sh tests passed"
else
  echo "some check-localization-catalog.sh tests FAILED"
fi
exit $overall_status
