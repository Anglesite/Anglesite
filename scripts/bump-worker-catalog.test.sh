#!/usr/bin/env bash
#
# Exercises scripts/bump-worker-catalog.sh (#1961) against throwaway lock/Swift fixtures with
# `curl` and `git` stubbed on PATH, so every branch runs without network or touching this
# repo's real pin:
#
#   * bump <sha>                 -> lock + WorkerCatalogPin.swift carry that commit and the
#                                   SHA-256 of the fetched fixture bytes; --check then passes
#   * bump (no arg)              -> resolves `main` through `git ls-remote`
#   * bump, fetch fails          -> exits non-zero, lock and Swift untouched
#   * bump, malformed sha        -> exits non-zero, no fetch attempted
#   * --check, hand-edited Swift -> fails naming --regenerate; --regenerate repairs it
#   * --check, malformed lock    -> fails
#   * --check on the real tree   -> the committed lock and Swift file agree (drift guard)
#
# Runs in CI's linux-build-test lane (ci.yml). The swift:6.3.3-noble image has no jq, python,
# or curl — the script under test needs none of them for --check/--regenerate, and the bump
# path only reaches `curl`/`git` through the stubs below. Run it locally after changing
# bump-worker-catalog.sh; `podman run --rm -v "$PWD:/work:ro" -w /work swift:6.3.3-noble
# bash scripts/bump-worker-catalog.test.sh` reproduces the CI userland.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/bump-worker-catalog.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

overall_status=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; overall_status=1; }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# ---- stubs -------------------------------------------------------------------------------------
# `curl -fsSL --retry N --retry-delay N <url> -o <out>`: serve $FIXTURES/<commit>/<path> for
# https://raw.example.invalid/davidwkeith/workers/<commit>/<path>; exit 22 (curl's -f code)
# when the fixture is missing, exactly like a 404 would.
FIXTURES="$tmp/fixtures"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --retry|--retry-delay) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
rel="${url#https://raw.example.invalid/davidwkeith/workers/}"
[[ "$rel" != "$url" ]] || { echo "stub curl: unexpected url $url" >&2; exit 3; }
[[ -f "$FIXTURES/$rel" ]] || exit 22
cp "$FIXTURES/$rel" "$out"
EOF
# `git ls-remote <remote> refs/heads/main` prints "<sha>\trefs/heads/main".
cat >"$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "ls-remote" ]] || { echo "stub git: unexpected args $*" >&2; exit 3; }
printf '%s\trefs/heads/main\n' "$STUB_MAIN_SHA"
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/git"
export FIXTURES
export PATH="$tmp/bin:$PATH"
export WORKER_CATALOG_RAW_BASE="https://raw.example.invalid"

SHA_A="$(printf 'a%.0s' $(seq 1 40))"
SHA_B="$(printf 'b%.0s' $(seq 1 40))"
for sha in "$SHA_A" "$SHA_B"; do
    mkdir -p "$FIXTURES/$sha/conformance"
    printf '{"workers":[{"id":"webmention-%s"}]}\n' "$sha" >"$FIXTURES/$sha/catalog.json"
    printf '{"packages":{"@dwk/webmention-%s":{}}}\n' "$sha" >"$FIXTURES/$sha/conformance/status.json"
done

# setup_case <name> — fresh lock/Swift paths under $tmp/<name>; exports the overrides the
# script reads.
setup_case() {
    local dir="$tmp/$1"
    mkdir -p "$dir"
    export WORKER_CATALOG_LOCK_FILE="$dir/worker-catalog.lock.json"
    export WORKER_CATALOG_PIN_SWIFT="$dir/WorkerCatalogPin.swift"
}

run_target() { bash "$TARGET" "$@"; }

lock_value() {
    sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$WORKER_CATALOG_LOCK_FILE" | head -n 1
}

# ---- bump with an explicit sha ---------------------------------------------------------------
setup_case explicit
if out=$(run_target "$SHA_A" 2>&1); then
    pass "bump <sha>: exits 0"
else
    fail "bump <sha>: exited non-zero: $out"
fi
[[ "$(lock_value commit)" == "$SHA_A" ]] && pass "bump <sha>: lock commit" || fail "bump <sha>: lock commit is $(lock_value commit)"
expected_catalog="$(sha256_of "$FIXTURES/$SHA_A/catalog.json")"
expected_status="$(sha256_of "$FIXTURES/$SHA_A/conformance/status.json")"
[[ "$(lock_value catalog_sha256)" == "$expected_catalog" ]] && pass "bump <sha>: lock catalog_sha256" \
    || fail "bump <sha>: lock catalog_sha256 is $(lock_value catalog_sha256), expected $expected_catalog"
[[ "$(lock_value conformance_status_sha256)" == "$expected_status" ]] && pass "bump <sha>: lock conformance_status_sha256" \
    || fail "bump <sha>: lock conformance_status_sha256 is $(lock_value conformance_status_sha256)"
[[ "$(lock_value repository)" == "davidwkeith/workers" ]] && pass "bump <sha>: lock repository" || fail "bump <sha>: lock repository"
[[ "$(lock_value pinned_at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && pass "bump <sha>: lock pinned_at is a date" || fail "bump <sha>: pinned_at is $(lock_value pinned_at)"
grep -qF "public static let commit = \"$SHA_A\"" "$WORKER_CATALOG_PIN_SWIFT" && pass "bump <sha>: Swift commit" || fail "bump <sha>: Swift commit"
grep -qF "public static let catalogSHA256 = \"$expected_catalog\"" "$WORKER_CATALOG_PIN_SWIFT" && pass "bump <sha>: Swift catalogSHA256" || fail "bump <sha>: Swift catalogSHA256"
grep -qF "public static let conformanceStatusSHA256 = \"$expected_status\"" "$WORKER_CATALOG_PIN_SWIFT" && pass "bump <sha>: Swift conformanceStatusSHA256" || fail "bump <sha>: Swift conformanceStatusSHA256"
grep -q '^// GENERATED by scripts/bump-worker-catalog.sh' "$WORKER_CATALOG_PIN_SWIFT" && pass "bump <sha>: Swift carries the generated-file header" || fail "bump <sha>: no generated-file header"
# DocC double-backtick links must survive the heredoc (an unescaped `` pair would be a command substitution).
grep -qF 'bytes at ``commit``' "$WORKER_CATALOG_PIN_SWIFT" && pass "bump <sha>: Swift keeps DocC symbol links intact" || fail "bump <sha>: DocC symbol links mangled"
if out=$(run_target --check 2>&1); then
    pass "bump <sha>: --check passes afterwards"
else
    fail "bump <sha>: --check failed afterwards: $out"
fi

# ---- re-bump to a different sha shows a diff of the manifests -----------------------------------
if out=$(run_target "$SHA_B" 2>&1); then
    pass "re-bump: exits 0"
else
    fail "re-bump: exited non-zero: $out"
fi
echo "$out" | grep -qF -- "-{\"workers\":[{\"id\":\"webmention-$SHA_A\"}]}" \
    && pass "re-bump: prints the catalog diff against the previous pin" || fail "re-bump: no catalog diff in output: $out"
[[ "$(lock_value commit)" == "$SHA_B" ]] && pass "re-bump: lock commit updated" || fail "re-bump: lock commit is $(lock_value commit)"
[[ "$(lock_value catalog_sha256)" == "$(sha256_of "$FIXTURES/$SHA_B/catalog.json")" ]] \
    && pass "re-bump: lock catalog_sha256 updated" || fail "re-bump: lock catalog_sha256 stale"

# ---- bump with no arg resolves main through git ls-remote ---------------------------------------
setup_case resolve
export STUB_MAIN_SHA="$SHA_A"
if out=$(run_target 2>&1); then
    pass "bump (no arg): exits 0"
else
    fail "bump (no arg): exited non-zero: $out"
fi
[[ "$(lock_value commit)" == "$SHA_A" ]] && pass "bump (no arg): pins the resolved main sha" || fail "bump (no arg): lock commit is $(lock_value commit)"
echo "$out" | grep -qF "resolved davidwkeith/workers main -> $SHA_A" && pass "bump (no arg): reports the resolution" || fail "bump (no arg): resolution not reported: $out"

# ---- fetch failure leaves the lock and Swift untouched ---------------------------------------------
setup_case fetchfail
run_target "$SHA_A" >/dev/null 2>&1
before_lock="$(cat "$WORKER_CATALOG_LOCK_FILE")"
before_swift="$(cat "$WORKER_CATALOG_PIN_SWIFT")"
MISSING_SHA="$(printf 'c%.0s' $(seq 1 40))"
if out=$(run_target "$MISSING_SHA" 2>&1); then
    fail "fetch failure: should exit non-zero"
else
    echo "$out" | grep -qF "could not fetch catalog.json" && pass "fetch failure: fails with a clear message" \
        || fail "fetch failure: error message unclear: $out"
fi
[[ "$(cat "$WORKER_CATALOG_LOCK_FILE")" == "$before_lock" ]] && pass "fetch failure: lock untouched" || fail "fetch failure: lock was modified"
[[ "$(cat "$WORKER_CATALOG_PIN_SWIFT")" == "$before_swift" ]] && pass "fetch failure: Swift untouched" || fail "fetch failure: Swift was modified"

# ---- malformed sha argument ----------------------------------------------------------------------
setup_case malformed
if out=$(run_target "not-a-sha" 2>&1); then
    fail "malformed sha: should exit non-zero"
else
    echo "$out" | grep -qF "40-character" && pass "malformed sha: fails with a clear message" \
        || fail "malformed sha: error message unclear: $out"
fi
[[ ! -f "$WORKER_CATALOG_LOCK_FILE" ]] && pass "malformed sha: no lock written" || fail "malformed sha: lock was written"

# ---- --check detects a hand-edited Swift file; --regenerate repairs it -----------------------------
setup_case drift
run_target "$SHA_A" >/dev/null 2>&1
sed -i.tmp "s/$SHA_A/$SHA_B/" "$WORKER_CATALOG_PIN_SWIFT" && rm -f "$WORKER_CATALOG_PIN_SWIFT.tmp"
if out=$(run_target --check 2>&1); then
    fail "drift: --check should exit non-zero"
else
    echo "$out" | grep -qF -- "--regenerate" && pass "drift: --check fails naming --regenerate" \
        || fail "drift: --check message unclear: $out"
fi
if out=$(run_target --regenerate 2>&1); then
    pass "drift: --regenerate exits 0"
else
    fail "drift: --regenerate exited non-zero: $out"
fi
grep -qF "public static let commit = \"$SHA_A\"" "$WORKER_CATALOG_PIN_SWIFT" && pass "drift: --regenerate restores the lock's commit" || fail "drift: Swift still drifted"
if out=$(run_target --check 2>&1); then
    pass "drift: --check passes after --regenerate"
else
    fail "drift: --check still failing: $out"
fi

# ---- --check rejects a malformed lock ---------------------------------------------------------------
setup_case badlock
run_target "$SHA_A" >/dev/null 2>&1
sed -i.tmp 's/"catalog_sha256": "[0-9a-f]*"/"catalog_sha256": "deadbeef"/' "$WORKER_CATALOG_LOCK_FILE" && rm -f "$WORKER_CATALOG_LOCK_FILE.tmp"
if out=$(run_target --check 2>&1); then
    fail "bad lock: --check should exit non-zero"
else
    echo "$out" | grep -qF "catalog_sha256 must be 64" && pass "bad lock: --check rejects a malformed digest" \
        || fail "bad lock: message unclear: $out"
fi

# ---- missing lock ---------------------------------------------------------------------------------
setup_case nolock
if out=$(run_target --check 2>&1); then
    fail "missing lock: --check should exit non-zero"
else
    echo "$out" | grep -qF "missing lock file" && pass "missing lock: --check fails with a clear message" \
        || fail "missing lock: message unclear: $out"
fi

# ---- the real tree: committed lock and generated Swift agree ------------------------------------------
unset WORKER_CATALOG_LOCK_FILE WORKER_CATALOG_PIN_SWIFT
if out=$(run_target --check 2>&1); then
    pass "real tree: scripts/worker-catalog.lock.json and WorkerCatalogPin.swift agree"
else
    fail "real tree: lock/Swift drift — run scripts/bump-worker-catalog.sh --regenerate: $out"
fi
real_commit="$(sed -n 's/^[[:space:]]*"commit":[[:space:]]*"\([^"]*\)".*/\1/p' "$SCRIPT_DIR/worker-catalog.lock.json")"
[[ "$real_commit" =~ ^[0-9a-f]{40}$ ]] && pass "real tree: lock pins a full commit sha, not a branch" || fail "real tree: lock commit is '$real_commit'"

exit $overall_status
