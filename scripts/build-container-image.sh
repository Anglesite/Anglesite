#!/usr/bin/env bash
#
# Build the Cloudflare/shared Anglesite dev-server OCI image (issue #62).
#
# This script uses the lowercase container/ build context. It is not the active
# macOS app-bundled image path; use scripts/vendor-container-image.sh for the
# Apple Containerization image that becomes Resources/container-image/.
#
# This path remains for the Cloudflare Sandbox / remote-runtime image pipeline.
# Node is pinned to scripts/node-version.txt; git, the Astro/site toolchain, and
# the MCP sidecar runtime is baked in; the template's dependency closure
# is pre-installed so cold starts skip npm ci (design §5b).
#
# Usage:
#   scripts/build-container-image.sh            # build + load locally (arm64)
#   scripts/build-container-image.sh --push     # build + push to $IMAGE_REPO, print digest
#
# Env overrides:
#   IMAGE_REPO            registry repo (default: ghcr.io/anglesite/anglesite-devserver)
#   IMAGE_TAG            human tag    (default: dev)
#   PLATFORM             build arch   (default: linux/arm64). Set linux/amd64 for the
#                        Cloudflare substrate (CF Containers are amd64-only), or a
#                        comma list "linux/amd64,linux/arm64" for a multi-arch manifest.
#   ANGLESITE_SIDECAR_SRC sidecar checkout (default: ../anglesite sibling)
#   ANGLESITE_PLUGIN_SRC  legacy alias for ANGLESITE_SIDECAR_SRC
#
# Distribution (decision Q-D): the Cloudflare/shared image is pushed to a registry
# BY DIGEST. Cloudflare Containers run amd64 (remote); the substrate layers its
# sandbox init on top via container/Dockerfile.cloudflare (#61). The macOS Apple
# Containerization image is produced separately by scripts/vendor-container-image.sh
# from Containers/anglesite-dev/ and bundled into the app.
#
# NOTE: a multi-arch (comma) PLATFORM only works with --push — buildx cannot --load a
# multi-platform manifest into the local Docker image store. Asking for both errors out.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONTAINER_DIR="$REPO_ROOT/container"
VERSION_FILE="$SCRIPT_DIR/node-version.txt"

IMAGE_REPO="${IMAGE_REPO:-ghcr.io/anglesite/anglesite-devserver}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
PLATFORM="${PLATFORM:-linux/arm64}"

PUSH=0
[[ "${1:-}" == "--push" ]] && PUSH=1

# buildx can only --load a single-platform image into the local store. A multi-arch
# (comma-separated) PLATFORM must be pushed straight to the registry.
if [[ "$PLATFORM" == *,* && $PUSH -eq 0 ]]; then
    echo "PLATFORM='$PLATFORM' is multi-arch; buildx cannot --load it locally." >&2
    echo "Re-run with --push (multi-arch goes straight to ${IMAGE_REPO}), or set a single PLATFORM." >&2
    exit 1
fi

[[ -f "$VERSION_FILE" ]] || { echo "missing $VERSION_FILE" >&2; exit 1; }
NODE_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
[[ -n "$NODE_VERSION" ]] || { echo "$VERSION_FILE is empty" >&2; exit 1; }

# Resolve the sidecar source the same way scripts/lib/stage-dev-image-context.sh does.
DEFAULT_SRC=$(cd "$REPO_ROOT/.." && pwd)/anglesite
SIDECAR_SRC="${ANGLESITE_SIDECAR_SRC:-${ANGLESITE_PLUGIN_SRC:-$DEFAULT_SRC}}"
[[ -d "$SIDECAR_SRC" ]] || { echo "MCP sidecar source not found at $SIDECAR_SRC (set ANGLESITE_SIDECAR_SRC)" >&2; exit 1; }
[[ -f "$SIDECAR_SRC/server/index.mjs" && -f "$SIDECAR_SRC/package.json" ]] \
    || { echo "$SIDECAR_SRC is not an Anglesite MCP sidecar (need server/index.mjs and package.json)" >&2; exit 1; }
TEMPLATE_DIR="$REPO_ROOT/Resources/Template"
[[ -f "$TEMPLATE_DIR/package.json" ]] \
    || { echo "template manifests missing under $TEMPLATE_DIR" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || { echo "docker not found on PATH" >&2; exit 1; }

# Use a docker-container buildx builder explicitly so multi-platform builds don't depend on the
# developer's globally active builder. Do not call `docker buildx use`; that would leave global
# Docker state changed after this script exits.
if ! docker buildx inspect anglesite-oci >/dev/null 2>&1; then
    docker buildx create --name anglesite-oci --driver docker-container
fi

# ---- Stage a clean build context ----------------------------------------------
CTX=$(mktemp -d)
trap 'rm -rf "$CTX"' EXIT

echo "==> Staging build context"
cp "$CONTAINER_DIR/Dockerfile" "$CONTAINER_DIR/.dockerignore" "$CTX/"
cp "$CONTAINER_DIR/entrypoint.sh" "$CONTAINER_DIR/hydrate.sh" "$CONTAINER_DIR/start-dev-server.sh" "$CTX/"

# MCP sidecar runtime: server + manifests + lockfile. Production dependencies
# are installed inside the image.
mkdir -p "$CTX/mcp-sidecar"
rsync -a \
    --exclude='node_modules/' --exclude='.git/' \
    "$SIDECAR_SRC/server/" "$CTX/mcp-sidecar/server/"
cp "$SIDECAR_SRC/package.json" "$SIDECAR_SRC/package-lock.json" "$CTX/mcp-sidecar/"

# Template: manifests only. We bake the template's dependency closure, not its source.
mkdir -p "$CTX/template"
cp "$TEMPLATE_DIR/package.json" "$CTX/template/"
[[ -f "$TEMPLATE_DIR/package-lock.json" ]] && cp "$TEMPLATE_DIR/package-lock.json" "$CTX/template/"

# ---- Build --------------------------------------------------------------------
IMAGE_REF="${IMAGE_REPO}:${IMAGE_TAG}"
META="$CTX/metadata.json"
OUTPUT="--load"
[[ $PUSH -eq 1 ]] && OUTPUT="--push"

BUILD_ARGS=(
    --builder anglesite-oci
    --platform "$PLATFORM"
    --build-arg "NODE_VERSION=$NODE_VERSION"
    --tag "$IMAGE_REF"
    --metadata-file "$META"
    "$OUTPUT"
)
# Provenance attestations make a --push emit an OCI *index* manifest that both Apple
# `container` and Cloudflare image pull can reject as an unexpected multi-arch image.
# Strip them on push only; a local --load build keeps its (harmless) default metadata.
[[ $PUSH -eq 1 ]] && BUILD_ARGS+=(--provenance=false)

echo "==> Building $IMAGE_REF for $PLATFORM (Node v$NODE_VERSION)"
docker buildx build "${BUILD_ARGS[@]}" "$CTX"

# Informational only: the digest lets you pin both substrates to one image. The
# `|| true` keeps a missing/absent metadata file from aborting the run under
# `set -e` — callers that need to gate on the digest should check it themselves.
DIGEST=$(awk -F'"' '/containerimage\.digest/{print $4}' "$META" 2>/dev/null || true)

echo
echo "Built $IMAGE_REF ($PLATFORM, Node v$NODE_VERSION)"
if [[ -n "$DIGEST" ]]; then
    echo "Digest: $DIGEST"
    echo
    echo "Pin BOTH substrates to this digest for reproducibility:"
    echo "  ${IMAGE_REPO}@${DIGEST}"
fi

# container/README.md's "Distribution decision (Q-D)" calls for pinning the
# canonical image by digest. Only a --push produces a digest that actually
# resolves in the registry, so only --push records it. Run
# scripts/pin-cloudflare-canonical-image.sh afterward to consume this file.
if [[ $PUSH -eq 1 ]]; then
    if [[ -n "$DIGEST" ]]; then
        DIGEST_FILE="$CONTAINER_DIR/CANONICAL_IMAGE_DIGEST"
        echo "${IMAGE_REPO}@${DIGEST}" > "$DIGEST_FILE"
        echo
        echo "Wrote pinned reference to $DIGEST_FILE"
        echo "Run scripts/pin-cloudflare-canonical-image.sh to update Dockerfile.cloudflare."
    else
        echo >&2
        echo "warning: no digest resolved from buildx metadata; container/CANONICAL_IMAGE_DIGEST not written" >&2
    fi
fi
if [[ $PUSH -eq 0 ]]; then
    echo
    echo "Loaded into the local Docker image store. Re-run with --push to publish to $IMAGE_REPO."
fi
