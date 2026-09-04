# syntax=docker/dockerfile:1
#
# Cloudflare/shared Anglesite dev-server image — issue #62 (design doc Q-D).
#
# This lowercase container/ image is NOT the app-bundled macOS image source.
# The active Apple Containerization image lives in Containers/anglesite-dev/ and
# is exported into Resources/container-image/ by scripts/vendor-container-image.sh.
#
# This Dockerfile remains for the Cloudflare Sandbox / remote-runtime pipeline:
# the Astro dev server and the MCP sidecar run inside this Linux
# container so the remote runtime can match the local runtime's behavior.
#
#   • Apple Containerization (macOS) — Containers/anglesite-dev/ bundled as OCI.
#   • Cloudflare Sandbox (remote/iOS) — see container/Dockerfile.cloudflare.
#
# Defaults to linux/arm64 in scripts/build-container-image.sh, but Cloudflare
# Sandbox currently needs linux/amd64. Node is pinned to scripts/node-version.txt
# and passed in as NODE_VERSION by scripts/build-container-image.sh. No default
# here (#1815): this Dockerfile is not buildable standalone anyway (see
# container/README.md), and a bare `docker build` silently drifting onto a
# stale default is worse than failing loudly.
ARG NODE_VERSION
FROM node:${NODE_VERSION}-bookworm-slim

# git: Git is the source of truth — the container clones the site on start
#      (design §3.1 option A). No host-share, no embedded Node.
# tini: PID 1 that reaps the long-lived dev server's children and forwards signals.
# ca-certificates: HTTPS git clone + npm registry.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

ENV ANGLESITE_HOME=/opt/anglesite \
    NPM_CONFIG_CACHE=/opt/anglesite/npm-cache \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    SITE_DIR=/workspace \
    PORT=4321

# ---- MCP sidecar runtime ------------------------------------------------------
# The sidecar is the source of truth for the MCP server. Bake its
# runtime — server/*.mjs plus the production dependency closure
# (@modelcontextprotocol/sdk, sharp, and the SDK's hoisted zod) — so the runtime
# substrates can start it with no network install. Deps are installed against the
# committed lockfile before the source is copied so this layer caches well.
COPY mcp-sidecar/package.json mcp-sidecar/package-lock.json ${ANGLESITE_HOME}/mcp-sidecar/
RUN cd ${ANGLESITE_HOME}/mcp-sidecar \
 && ( npm ci --omit=dev \
      || { echo "WARN: sidecar lockfile out of sync — falling back to npm install" >&2; \
           npm install --omit=dev; } )
COPY mcp-sidecar/ ${ANGLESITE_HOME}/mcp-sidecar/
ENV ANGLESITE_MCP_ENTRY=${ANGLESITE_HOME}/mcp-sidecar/server/index.mjs

# ---- Pre-baked site toolchain (skip npm ci on cold start; design §5b) ---------
# Install the template's full dependency closure once, at build time. This warms
# the npm cache for any cloned site AND keeps the resolved node_modules so a site
# whose lockfile matches the template reuses it with zero install (hydrate.sh).
# Store that tree as one tar entry in the OCI layer: besides shrinking the layer's
# entry count, this avoids pathological first-boot EXT4 import time in the local
# Apple Containerization runtime. Hydration expands it in the Linux guest.
# `npm ci` is preferred (reproducible, and it's what hydrate.sh's zero-install
# fast path compares against). If the template's committed lockfile has drifted
# out of sync with its package.json, fall back to `npm install` with a loud
# warning rather than failing the image — sites then take hydrate.sh's
# warm-cache `npm ci` path instead of the zero-install hardlink.
COPY template/package.json template/package-lock.json ${ANGLESITE_HOME}/baked/
RUN cd ${ANGLESITE_HOME}/baked \
 && ( npm ci \
      || { echo "WARN: template lockfile out of sync — falling back to npm install" >&2; \
           npm install; } ) \
 && tar -cf ${ANGLESITE_HOME}/baked-node-modules.tar node_modules \
 && rm -rf node_modules

# ---- Hydration + start helpers ------------------------------------------------
COPY entrypoint.sh hydrate.sh start-dev-server.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/hydrate.sh \
             /usr/local/bin/start-dev-server.sh

WORKDIR /workspace
EXPOSE 4321

# tini as PID 1; entrypoint hydrates the repo + deps, then execs the CMD.
# Substrates may override CMD or drive their own start sequence — this is a
# sensible, override-friendly default.
ENTRYPOINT ["/usr/bin/tini", "--", "entrypoint.sh"]
CMD ["start-dev-server.sh"]
