#!/usr/bin/env bash
#
# Exercises scripts/pin-cloudflare-canonical-image.sh against a throwaway
# container/ fixture (#1644), so the digest-file -> Dockerfile.cloudflare
# rewrite is checked without touching this repo's real files:
#
#   * missing CANONICAL_IMAGE_DIGEST       -> fails, Dockerfile unchanged
#   * empty CANONICAL_IMAGE_DIGEST         -> fails, Dockerfile unchanged
#   * malformed reference (no sha256)      -> fails, Dockerfile unchanged
#   * valid "repo@sha256:<digest>"         -> ARG CANONICAL_IMAGE rewritten,
#                                              rest of the Dockerfile untouched
#   * already pinned to the same value     -> no-op, exits 0
#
# Runs in CI's linux-build-test lane (ci.yml). No docker/network dependency —
# the script only reads a text file and rewrites another. Run it locally
# after changing pin-cloudflare-canonical-image.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/pin-cloudflare-canonical-image.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

overall_status=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; overall_status=1; }

DIGEST="sha256:$(printf 'a%.0s' $(seq 1 64))"
REPO_REF="ghcr.io/anglesite/anglesite-devserver@${DIGEST}"

dockerfile_fixture() {
    cat <<'EOF'
ARG CANONICAL_IMAGE=ghcr.io/anglesite/anglesite-devserver:dev
ARG SANDBOX_IMAGE=docker.io/cloudflare/sandbox:0.12.1

FROM ${SANDBOX_IMAGE} AS sandbox
FROM ${CANONICAL_IMAGE}
EOF
}

# Sets up a fresh container/ fixture under $1 and returns its path components
# via the DOCKERFILE / DIGEST_FILE globals the caller reads afterward.
setup_case() {
    local case_dir="$tmp/$1"
    mkdir -p "$case_dir/container"
    dockerfile_fixture > "$case_dir/container/Dockerfile.cloudflare"
    DOCKERFILE="$case_dir/container/Dockerfile.cloudflare"
    DIGEST_FILE="$case_dir/container/CANONICAL_IMAGE_DIGEST"
    REPO_ROOT="$case_dir"
}

run_target() {
    # The script derives REPO_ROOT/CONTAINER_DIR from its own location, so run
    # a copy staged inside each fixture's tree.
    mkdir -p "$REPO_ROOT/scripts"
    cp "$TARGET" "$REPO_ROOT/scripts/pin-cloudflare-canonical-image.sh"
    (cd "$REPO_ROOT" && bash scripts/pin-cloudflare-canonical-image.sh)
}

# ---- missing digest file -----------------------------------------------------
setup_case missing
if out=$(run_target 2>&1); then
    fail "missing digest file should exit non-zero"
else
    echo "$out" | grep -qF "missing" && pass "missing digest file: fails with a clear message" \
        || fail "missing digest file: error message unclear: $out"
fi
grep -q '^ARG CANONICAL_IMAGE=ghcr.io/anglesite/anglesite-devserver:dev$' "$DOCKERFILE" \
    && pass "missing digest file: Dockerfile untouched" || fail "missing digest file: Dockerfile was modified"

# ---- empty digest file --------------------------------------------------------
setup_case empty
: > "$DIGEST_FILE"
if out=$(run_target 2>&1); then
    fail "empty digest file should exit non-zero"
else
    pass "empty digest file: fails"
fi
grep -q '^ARG CANONICAL_IMAGE=ghcr.io/anglesite/anglesite-devserver:dev$' "$DOCKERFILE" \
    && pass "empty digest file: Dockerfile untouched" || fail "empty digest file: Dockerfile was modified"

# ---- malformed reference -------------------------------------------------------
setup_case malformed
echo "ghcr.io/anglesite/anglesite-devserver:dev" > "$DIGEST_FILE"
if out=$(run_target 2>&1); then
    fail "malformed reference should exit non-zero"
else
    echo "$out" | grep -qF "does not look like" && pass "malformed reference: fails with a clear message" \
        || fail "malformed reference: error message unclear: $out"
fi
grep -q '^ARG CANONICAL_IMAGE=ghcr.io/anglesite/anglesite-devserver:dev$' "$DOCKERFILE" \
    && pass "malformed reference: Dockerfile untouched" || fail "malformed reference: Dockerfile was modified"

# ---- valid digest --------------------------------------------------------------
setup_case valid
echo "$REPO_REF" > "$DIGEST_FILE"
if out=$(run_target 2>&1); then
    pass "valid digest: exits 0"
else
    fail "valid digest: exited non-zero: $out"
fi
grep -qF "ARG CANONICAL_IMAGE=${REPO_REF}" "$DOCKERFILE" \
    && pass "valid digest: ARG CANONICAL_IMAGE rewritten" || fail "valid digest: ARG CANONICAL_IMAGE not rewritten"
grep -q '^ARG SANDBOX_IMAGE=docker.io/cloudflare/sandbox:0.12.1$' "$DOCKERFILE" \
    && pass "valid digest: unrelated ARG line untouched" || fail "valid digest: unrelated ARG line was modified"
[[ ! -f "${DOCKERFILE}.bak" ]] && pass "valid digest: no leftover .bak file" || fail "valid digest: leftover ${DOCKERFILE}.bak"

# ---- already pinned to the same value ------------------------------------------
setup_case idempotent
echo "$REPO_REF" > "$DIGEST_FILE"
sed -i.tmp "s|^ARG CANONICAL_IMAGE=.*|ARG CANONICAL_IMAGE=${REPO_REF}|" "$DOCKERFILE" && rm -f "${DOCKERFILE}.tmp"
if out=$(run_target 2>&1); then
    echo "$out" | grep -qF "already pins" && pass "already pinned: no-op with a clear message" \
        || fail "already pinned: unexpected message: $out"
else
    fail "already pinned: exited non-zero: $out"
fi

exit $overall_status
