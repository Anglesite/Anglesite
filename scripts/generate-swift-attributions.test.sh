#!/usr/bin/env bash
#
# Exercises scripts/generate-swift-attributions.sh's nested-component path (NESTED_COMPONENTS,
# e.g. the libgit2 submodule SwiftGit2 compiles from source) against a throwaway repo root with a
# one-pin Package.resolved and a fake .build/checkouts tree:
#
#   * nested checkout present        -> a libgit2 entry with the version.h version, the COPYING
#                                       text and the table's SPDX id; a LibXDiff entry assembled
#                                       from its licenseParts (header notices + LGPL file), both
#                                       sorted ahead of SwiftGit2's entry
#   * a licenseParts file missing    -> exits 1, "license part not found (header xhistogram.c)"
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
    mkdir -p "$libgit2/deps/xdiff" "$libgit2/deps/winhttp"
    printf '/*\n *  LibXDiff fixture notice\n *\n *  LGPL line\n */\n\n#define XDIFF_H\n' \
        > "$libgit2/deps/xdiff/xdiff.h"
    printf '/*\n * Histogram fixture notice\n */\n#include "xinclude.h"\n' \
        > "$libgit2/deps/xdiff/xhistogram.c"
    printf 'fixture LGPL text\n' > "$libgit2/deps/winhttp/COPYING.LGPL"
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
assert names == ["libgit2", "LibXDiff (bundled in libgit2)", "SwiftGit2"], names
libgit2 = entries[0]
assert libgit2["version"] == "9.8.7", libgit2["version"]
assert libgit2["licenseText"] == "fixture libgit2 COPYING text\n", libgit2["licenseText"]
assert libgit2["licenseSPDXId"] == "GPL-2.0-only WITH GCC-exception-2.0", libgit2["licenseSPDXId"]
assert libgit2["homepage"] == "https://github.com/libgit2/libgit2", libgit2["homepage"]
xdiff = entries[1]
assert xdiff["version"] == "9.8.7", xdiff["version"]
assert xdiff["licenseSPDXId"] == "LGPL-2.1-or-later AND BSD-3-Clause", xdiff["licenseSPDXId"]
separator = "\n" + "-" * 70 + "\n\n"
expected = separator.join([
    "LibXDiff fixture notice\n\nLGPL line\n",
    "Histogram fixture notice\n",
    "fixture LGPL text\n",
])
assert xdiff["licenseText"] == expected, repr(xdiff["licenseText"])
assert entries[2]["version"] == "cabf713c7db9", entries[2]["version"]
PY
then pass "nested checkout present -> libgit2 and LibXDiff entries emitted"
else fail "nested checkout present -> libgit2 and LibXDiff entries emitted"; cat "$root/stderr"
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

root="$tmp/nopart"; make_root "$root"
rm "$root/.build/checkouts/SwiftGit2/libgit2/deps/xdiff/xhistogram.c"
expect_failure "a licenseParts file missing" "$root" \
    "SwiftGit2/libgit2/deps/xdiff: license part not found (header xhistogram.c)"

exit "$overall_status"
