#!/usr/bin/env bash
#
# Rewrite container/Dockerfile.cloudflare's `ARG CANONICAL_IMAGE` default to the
# digest-pinned reference recorded in container/CANONICAL_IMAGE_DIGEST (#1644).
#
# container/README.md's "Distribution decision (Q-D)" calls for pinning the
# canonical image by digest instead of a floating tag, for reproducibility.
# scripts/build-container-image.sh --push writes the resulting
# "$IMAGE_REPO@$DIGEST" reference to container/CANONICAL_IMAGE_DIGEST; this
# script consumes that file and updates the Dockerfile in place.
#
# Usage:
#   scripts/build-container-image.sh --push       # writes container/CANONICAL_IMAGE_DIGEST
#   scripts/pin-cloudflare-canonical-image.sh      # rewrites Dockerfile.cloudflare from it
#
# Review the resulting diff and commit both files together. This is a manual
# step by design (#1644's non-goals) — nothing runs it automatically in CI.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONTAINER_DIR="$REPO_ROOT/container"
DIGEST_FILE="$CONTAINER_DIR/CANONICAL_IMAGE_DIGEST"
DOCKERFILE="$CONTAINER_DIR/Dockerfile.cloudflare"

[[ -f "$DIGEST_FILE" ]] \
    || { echo "missing $DIGEST_FILE — run scripts/build-container-image.sh --push first" >&2; exit 1; }
[[ -f "$DOCKERFILE" ]] || { echo "missing $DOCKERFILE" >&2; exit 1; }

PINNED=$(tr -d '[:space:]' < "$DIGEST_FILE")
[[ -n "$PINNED" ]] || { echo "$DIGEST_FILE is empty" >&2; exit 1; }
# Expect "repo/path@sha256:<64 hex chars>", the same shape build-container-image.sh writes.
[[ "$PINNED" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] \
    || { echo "$DIGEST_FILE does not look like a 'repo@sha256:<digest>' reference: $PINNED" >&2; exit 1; }

grep -q '^ARG CANONICAL_IMAGE=' "$DOCKERFILE" \
    || { echo "no 'ARG CANONICAL_IMAGE=' line found in $DOCKERFILE" >&2; exit 1; }

CURRENT=$(awk -F'=' '/^ARG CANONICAL_IMAGE=/{print $2; exit}' "$DOCKERFILE")
if [[ "$CURRENT" == "$PINNED" ]]; then
    echo "container/Dockerfile.cloudflare already pins CANONICAL_IMAGE to $PINNED"
    exit 0
fi

# BSD sed (macOS) requires an argument to -i; GNU sed (Linux) treats a bare -i.bak
# the same way, so this form works on both. `|` as the delimiter avoids clashing
# with the `/` characters in an image reference.
sed -i.bak "s|^ARG CANONICAL_IMAGE=.*|ARG CANONICAL_IMAGE=${PINNED}|" "$DOCKERFILE"
rm -f "$DOCKERFILE.bak"

echo "Pinned CANONICAL_IMAGE: ${CURRENT:-<none>} -> ${PINNED}"
