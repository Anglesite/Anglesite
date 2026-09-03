#!/usr/bin/env bash
# Build the active macOS Apple Containerization image and export it as an OCI layout into
# Resources/container-image/.
#
# Apple's `container` CLI is the image builder. At runtime Anglesite imports this OCI layout
# and boots it with Apple's Containerization framework — builder and runtime share the same
# OCI implementation. Docker is not used anywhere on this path.
#
# Produces a gitignored, bundled app resource. Requires the Apple `container` CLI (≥ 1.1,
# https://github.com/apple/container) on an Apple-Silicon Mac.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/container-cli.sh"
source "$ROOT/scripts/lib/stage-dev-image-context.sh"
source "$ROOT/scripts/lib/mcp-protocol-version.sh"
# Fail fast, before staging work: no point copying the sidecar/template if the CLI is missing.
ensure_container_cli
CTX="$ROOT/Containers/anglesite-dev"
OUT="$ROOT/Resources/container-image"

stage_dev_image_context "$CTX"

# Captured now, before stage_dev_image_context's EXIT trap removes the staged sidecar copy — used
# below to stamp vendor-manifest.json once the image itself is built.
SIDECAR_VERSION="$(grep -m1 '"version"' "$CTX/mcp-sidecar/package.json" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"

echo "Building anglesite-dev:latest (linux/arm64)…"

echo "Exporting OCI layout → $OUT"
# Wipe any stale layout contents but preserve the committed .gitkeep placeholder so
# git does not report a deletion (the gitignore rules exclude everything else in the dir).
find "$OUT" -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true
mkdir -p "$OUT"

# Build into the CLI's local image store, then export with `container image save`, which emits
# a spec-compliant OCI image layout (index.json + oci-layout + blobs/sha256/) as a tar archive.
# Two steps instead of `container build --output type=oci,dest=…` because that flag is broken in
# container CLI 1.1.0 (the build completes, then the CLI errors "image.tar doesn't exist" —
# the tarball never lands at dest; reproduced with a trivial FROM-alpine build). Side benefit:
# the store keeps anglesite-dev:latest between runs, so rebuilds are incremental — the same role
# the old docker-container buildx builder's cache played.
ARCHIVE="$OUT/image.tar"
# Pass only the arm64 base digest. Apple container 1.1 tries to resolve every declared FROM stage,
# including an unused amd64 stage, against the requested platform.
ARM64_BASE="node:22-bookworm-slim@sha256:6db9be2ebb4bafb687a078ef5ba1b1dd256e8004d246a31fd210b6b848ab6be2"
# Stamped into vendor-manifest.json below so check-container-resources.sh can catch this pin
# drifting from scripts/node-version.txt (#1815) — this image's Node base is pinned
# independently of container/Dockerfile's NODE_VERSION build-arg (which reads that file
# directly), and nothing else would catch the two guest images landing on different majors.
NODE_MAJOR="$(sed -E 's#^node:([0-9]+)-.*#\1#' <<< "$ARM64_BASE")"
container build \
    --os linux --arch arm64 \
    --build-arg "BASE_IMAGE=$ARM64_BASE" \
    --tag anglesite-dev:latest \
    "$CTX"
container image save --platform linux/arm64 --output "$ARCHIVE" anglesite-dev:latest

tar -xf "$ARCHIVE" -C "$OUT"
rm -f "$ARCHIVE"

# Verify the layout is valid before reporting success.
for f in oci-layout index.json blobs/sha256; do
    [[ -e "$OUT/$f" ]] || { echo "ERROR: OCI layout missing $f" >&2; exit 1; }
done

# Stamp the vendored image with the MCP protocol version this app build expects, the sidecar
# version it was built from, and the Node base it was built on — scripts/check-container-resources.sh
# compares the protocol version against the app's current expectation and the Node major version
# against scripts/node-version.txt on every build, so a sidecar/app protocol drift (e.g. a later
# `git pull` that bumps MCPClient.protocolVersion) or a Node pin drift (#1815) is caught before it
# surfaces as an opaque MCP-connect HTTP error, or an inconsistent in-container dev-server
# failure, at preview time (#1407).
cat > "$OUT/vendor-manifest.json" <<EOF
{
  "mcpProtocolVersion": "$(mcp_protocol_version)",
  "sidecarVersion": "$SIDECAR_VERSION",
  "nodeBaseImage": "$ARM64_BASE",
  "nodeMajorVersion": "$NODE_MAJOR",
  "vendoredAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Done. Resources/container-image/ now holds an OCI layout."
echo "Contents:"
ls -la "$OUT"
