#!/usr/bin/env bash
#
# Exercises scripts/generate-swift-attributions.sh's nested-component path (NESTED_COMPONENTS,
# e.g. the libgit2 submodule SwiftGit2 compiles from source) against a throwaway repo root with a
# one-pin Package.resolved and a fake .build/checkouts tree:
#
#   * nested checkout present        -> a libgit2 entry with the version.h version, the COPYING
#                                       text, the table's SPDX id, sorted after SwiftGit2's entry
#   * nested checkout empty          -> exits 1, "checkout missing or empty"
#   * nested license file missing    -> exits 1, "no license file found"
#   * version.h format changed       -> exits 1, "version not found in include/git2/version.h"
#   * every failure skips the        -> none of them prints the pin loop's "Add an entry to
#     overrides advice                  …overrides…" advice, which can't fix a nested component
#
# Runs in CI's build-test lane (ci.yml), next to the app-binary attributions check; the script
# under test needs python3, which the swift:6.3.3-noble image lacks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/generate-swift-attributions.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

overall_status=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; overall_status=1; }

# Builds a repo root with one SwiftGit2 pin and a populated nested libgit2 checkout.
make_root() {
    local root="$1"
    local libgit2="$root/.build/checkouts/SwiftGit2/libgit2"
    mkdir -p "$libgit2/include/git2"
    cat > "$root/Package.resolved" <<'JSON'
{
  "pins" : [
    {
      "identity" : "swiftgit2",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/Anglesite/SwiftGit2.git",
      "state" : { "revision" : "cabf713c7db9b6c82d36ad45ff14b22f4d915be2" }
    }
  ],
  "version" : 3
}
JSON
    printf 'MIT License\n\nPermission is hereby granted, free of charge, to any person\n' \
        > "$root/.build/checkouts/SwiftGit2/LICENSE.md"
    printf 'fixture libgit2 COPYING text\n' > "$libgit2/COPYING"
    printf '#define LIBGIT2_VERSION           "9.8.7"\n' > "$libgit2/include/git2/version.h"
    echo '{}' > "$root/overrides.json"
}

run() {
    local root="$1"
    bash "$TARGET" "$root" "$root/out.json" "$root/overrides.json" > "$root/stdout" 2> "$root/stderr"
}

# --- nested checkout present: the entry is emitted -------------------------------------------
root="$tmp/ok"; make_root "$root"
if run "$root" && python3 - "$root/out.json" <<'PY'
import json, sys
entries = json.load(open(sys.argv[1]))
names = [e["name"] for e in entries]
assert names == ["libgit2", "SwiftGit2"], names
libgit2 = entries[0]
assert libgit2["version"] == "9.8.7", libgit2["version"]
assert libgit2["licenseText"] == "fixture libgit2 COPYING text\n", libgit2["licenseText"]
assert libgit2["licenseSPDXId"] == "GPL-2.0-only WITH GCC-exception-2.0", libgit2["licenseSPDXId"]
assert libgit2["homepage"] == "https://github.com/libgit2/libgit2", libgit2["homepage"]
assert entries[1]["version"] == "cabf713c7db9", entries[1]["version"]
PY
then pass "nested checkout present -> libgit2 entry emitted"
else fail "nested checkout present -> libgit2 entry emitted"; cat "$root/stderr"
fi

# Asserts a failing run: exit 1, the expected message, and no overrides advice.
expect_failure() {
    local label="$1" root="$2" message="$3"
    if run "$root"; then
        fail "$label -> exits 1 (it succeeded)"
        return
    fi
    if ! grep -qF "$message" "$root/stderr"; then
        fail "$label -> message '$message'"; cat "$root/stderr"
    elif grep -qF "Add an entry to" "$root/stderr"; then
        fail "$label -> no overrides advice"; cat "$root/stderr"
    else
        pass "$label -> exits 1 with '$message'"
    fi
}

root="$tmp/empty"; make_root "$root"
rm -rf "$root/.build/checkouts/SwiftGit2/libgit2"; mkdir "$root/.build/checkouts/SwiftGit2/libgit2"
expect_failure "nested checkout empty" "$root" "SwiftGit2/libgit2: checkout missing or empty"

root="$tmp/nolicense"; make_root "$root"
rm "$root/.build/checkouts/SwiftGit2/libgit2/COPYING"
expect_failure "nested license missing" "$root" "SwiftGit2/libgit2: no license file found"

root="$tmp/noversion"; make_root "$root"
printf '#define LIBGIT2_VER_MAJOR 9\n' > "$root/.build/checkouts/SwiftGit2/libgit2/include/git2/version.h"
expect_failure "version.h format changed" "$root" \
    "SwiftGit2/libgit2: version not found in include/git2/version.h"

exit "$overall_status"
