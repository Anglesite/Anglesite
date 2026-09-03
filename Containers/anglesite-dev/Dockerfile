# Anglesite local dev-server image. Two build paths consume this file:
#   - scripts/vendor-container-image.sh (Apple `container` CLI, arm64 only — bundled into
#     AnglesiteContainer for Apple Containerization, which is Apple-Silicon-only)
#   - scripts/build-podman-image.sh (podman, native host arch — arm64 or amd64 — tagged
#     localhost/anglesite-dev:latest for PodmanContainerControl on Linux)
# Bakes Node + git + socat (the vsock<->TCP bridge, macOS path only) + the app's MCP sidecar
# (the MCP sidecar's server/, npm ci'd for the build's native arch so sharp's native binary is
# correct) so a fresh container needs no in-guest install.

# Per-arch digest pin (reproducible; re-bump periodically for base security updates). The build
# scripts pass the matching pinned reference as BASE_IMAGE. Do not declare both architectures as
# separate FROM stages: Apple container 1.1 resolves even the unused stage for the requested
# platform, so an arm64 build fails while trying to fetch the amd64-only digest. The default keeps
# direct/manual builds on arm64, matching the macOS runtime.
ARG BASE_IMAGE=node:24-bookworm-slim@sha256:e9b5516b06baeaea9a8e65a7aec6a85fbb960a30b52b66968f2c8092b3e2a3eb
FROM ${BASE_IMAGE} AS base

# socat is the guest-side vsock<->TCP bridge: the host reaches astro/mcp (guest-local TCP) by
# dialing AF_VSOCK ports that socat forwards to 127.0.0.1 (no vmnet on the sandboxed host, #60).
# Unused on the podman path (port-mapping replaces vsock there) but harmless to install.
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates socat \
    && rm -rf /var/lib/apt/lists/*
# MCP sidecar: staged by the build script from the plugin checkout's server/ dir. npm ci runs on the
# build's native arch → pulls the matching @img/sharp-linux-{arm64,x64} native prebuilt from the
# lockfile. --omit=dev drops devDependencies. We intentionally do NOT pass --omit=optional
# because the sharp prebuilts are marked optional in the lockfile (platform-specific); npm's
# platform-cpu/os filters already skip the other arch's prebuilt and macOS-only optionals like
# fsevents.
COPY mcp-sidecar/ /usr/local/lib/anglesite-mcp/
# Playwright is an unused optionalDependency of the plugin package. We keep `npm ci`
# (reproducible; lock-exact) and cannot pass --omit=optional because the sharp prebuilt is also
# optional. This prevents Playwright from downloading browsers while the image builds.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN cd /usr/local/lib/anglesite-mcp \
    && npm ci --omit=dev \
    && rm -rf node_modules/playwright node_modules/playwright-core node_modules/.cache/ms-playwright

# ---- Pre-baked site toolchain (skip cold npm install on boot; design §5b) ----
# Install the template's full dependency closure once, at image-build time. This keeps the
# resolved node_modules so a cloned site whose lockfile matches the template reuses it with
# zero install (anglesite-hydrate), AND leaves npm's cache (/root/.npm) in the layer so a
# drifted-lockfile site's `npm ci --prefer-offline` mostly avoids the network. Full closure
# (no --omit=dev): astro dev/check need devDependencies (tsx, @astrojs/check, typescript).
#
# Keep node_modules as one tar entry in the OCI layer instead of ~19,000 individual entries.
# Apple Containerization's Swift EXT4 formatter performs path-tree lookups for every OCI entry;
# the expanded tree made first boot take tens of minutes. Linux tar expands the same trusted,
# build-time archive into the writable site workspace much faster during hydration.
ENV ANGLESITE_HOME=/opt/anglesite
COPY template/package.json template/package-lock.json ${ANGLESITE_HOME}/baked/
RUN cd ${ANGLESITE_HOME}/baked \
    && ( npm ci \
         || { echo "WARN: template lockfile out of sync — falling back to npm install" >&2; \
              npm install; } ) \
    && tar -cf ${ANGLESITE_HOME}/baked-node-modules.tar node_modules \
    && rm -rf node_modules
COPY hydrate.sh /usr/local/bin/anglesite-hydrate
RUN chmod +x /usr/local/bin/anglesite-hydrate

WORKDIR /workspace
