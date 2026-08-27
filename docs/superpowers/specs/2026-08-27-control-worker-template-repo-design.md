# Control Worker template repo — design

**Date:** 2026-08-27
**Issue:** #894 (placeholder, filed 2026-07-22). Part of #59. Builds on the runtime design in
[`2026-06-23-remote-sandbox-runtime-ios-design.md`](2026-06-23-remote-sandbox-runtime-ios-design.md)
and the onboarding design in
[`2026-07-21-ios-cloudflare-onboarding-design.md`](2026-07-21-ios-cloudflare-onboarding-design.md).
**Status:** Approved design; scoped into follow-up issues; #894 closes as superseded by this doc.

## Scope correction (read first)

#894's own text, written 2026-07-22, says *"no such repo exists yet anywhere under the Anglesite
org"* for the Control Worker + Sandbox DO + Dockerfile. That's stale. Between #894 being filed and
today, three PRs landed the substance of it **inside this monorepo**, not as a separate repo:

- [#423](https://github.com/Anglesite/Anglesite/pull/423) (`feat(#67)`) and
  [#448](https://github.com/Anglesite/Anglesite/pull/448) (`feat(#66)`) added
  [`Workers/ControlWorker/`](../../../Workers/ControlWorker) — a real `@cloudflare/sandbox`-hosting
  Worker + Durable Object implementing exactly the `/start`, `/status`, `/stop` contract
  `HTTPSandboxControlClient` (AnglesiteCore) already calls: git-clones `Source/` into the sandbox,
  hydrates deps, starts the in-guest processes, opens the two tunnels, and returns
  `{previewURL, mcpURL}`. It also has the in-guest auth-proxy (`in-guest/auth-proxy.ts`, cookie-
  based, HTTP + WS upgrade) and an MCP bearer-auth middleware (`in-guest/mcp-auth.ts`).
- #62 (closed) added [`container/`](../../../container) — the shared OCI image
  (`Dockerfile`, Node pinned to `scripts/node-version.txt`, git, the baked MCP sidecar and
  pre-installed template deps per design §5b) plus
  [`Dockerfile.cloudflare`](../../../container/Dockerfile.cloudflare), a thin wrapper that layers
  the Cloudflare Sandbox SDK's init binary on top of the canonical image by digest.

So the Worker/DO/auth-proxy/Dockerfile pieces #894 asked for **already exist**. What's still
missing is narrower than #894's original framing, and this doc scopes exactly that remainder.

## What's actually missing

Tracing the wiring between the pieces above surfaces four concrete gaps — not "build a Control
Worker," but "finish assembling the one that exists into something a Deploy-to-Cloudflare button
can actually provision":

1. **The guest image doesn't contain the scripts the Worker starts.** `worker.ts`'s `/start` route
   does `sandbox.startProcess("node /opt/anglesite/auth-proxy.js", …)` and
   `sandbox.startProcess("node /opt/anglesite/mcp-server.js", …)`. Neither file is ever placed at
   that path: `build-guest.js` esbuilds `in-guest/auth-proxy.ts` and `in-guest/mcp-auth.ts` to
   `Workers/ControlWorker/dist/guest/*.js`, but neither `container/Dockerfile` nor
   `Dockerfile.cloudflare` `COPY`s that output into the image. There is also no `mcp-server.js` at
   all — `in-guest/mcp-auth.ts` only exports the auth middleware/upgrade-guard; nothing wraps the
   baked MCP sidecar entry (`ANGLESITE_MCP_ENTRY=/opt/anglesite/mcp-sidecar/server/index.mjs`) with
   it to produce an HTTP server that route can start. **A real `/start` call today would boot the
   sandbox, clone the site, and then fail two of its three `startProcess` calls.** This has never
   been exercised live — #61's spike predates this code, and #894's own doc lists a live
   integration test as a still-open item.
2. **No image-digest pinning.** `Dockerfile.cloudflare`'s `ARG CANONICAL_IMAGE=ghcr.io/anglesite/anglesite-devserver:dev`
   is a floating tag. `container/README.md`'s "Distribution decision (Q-D)" explicitly calls for
   pinning the **canonical image by digest** for reproducibility, and #894's own scope line named
   this ("image-digest tracking against the canonical container image (#62)"). Nothing produces or
   consumes a pinned digest today — `scripts/build-container-image.sh --push` prints one, but
   nothing writes it back into `Dockerfile.cloudflare`.
3. **No standalone, Deploy-to-Cloudflare-able repo.** Cloudflare's button
   (`deploy.workers.cloudflare.com/?url=<repo>`) clones a single public repo, expects
   `wrangler.jsonc` at its root, and builds/pushes whatever `Dockerfile` that config's `containers[].image`
   points at. `Workers/ControlWorker/` and `container/` are two directories inside the
   `Anglesite/Anglesite` app monorepo — not a self-contained thing the button can target as-is.
4. **App-side wiring + the Worker's auth model are both still placeholders.** Per the onboarding
   design, the "Deploy to Cloudflare" button in `RemoteConnectForm` today points at Cloudflare's
   generic Containers docs (relabeled "Cloudflare Container Setup Guide") — an intentional, honest
   interim target, not a real deploy. And the Worker's `authorized()` check
   (`Workers/ControlWorker/src/auth.ts`) validates a bespoke `CONTROL_API_SECRET` bearer, matching
   what `SandboxControlOnboarding`/`HTTPSandboxControlClient` capture today — the onboarding design's
   "Epic touchpoints" section flagged validating the real Cloudflare OAuth token instead as an
   open question for "the Control Worker template (future issue)," i.e. here.

## Locked decisions

| Gap | Decision | Rationale |
|---|---|---|
| Guest image wiring | Add a `guest/` layer to `Dockerfile.cloudflare` that `COPY`s `Workers/ControlWorker/dist/guest/auth-proxy.js` to `/opt/anglesite/auth-proxy.js`, and add a new `in-guest/mcp-server.ts` (thin: import the baked sidecar's HTTP entry, wrap with `mcpAuthMiddleware`/`mcpAuthUpgradeGuard`, listen on `$MCP_PORT`) built alongside it to `/opt/anglesite/mcp-server.js` | Keeps the wrapper thin and colocated with the Worker that starts these processes; the base `container/Dockerfile` stays substrate-neutral (macOS Containerization doesn't need either script) |
| Image digest pinning | `scripts/build-container-image.sh --push` writes the resulting digest to a checked-in `container/CANONICAL_IMAGE_DIGEST` file; a new `scripts/pin-cloudflare-canonical-image.sh` reads it and rewrites `Dockerfile.cloudflare`'s `ARG CANONICAL_IMAGE` default in place | Keeps the pin a plain, diffable, git-reviewable text file rather than a build-time side channel; matches how `Package.resolved` pins are reviewed today |
| Template repo location | **New sibling repo**, `Anglesite/anglesite-control-worker-template`, populated by a CI job that mirrors `Workers/ControlWorker/` + `container/` (flattened to repo root) on tag/release — not a live git subtree/submodule | Mirrors the existing `Anglesite/anglesite-skills` pattern (this app already treats a sibling repo as the deploy unit for MCP); a submodule would make Cloudflare's build clone this whole private-feeling monorepo layout, and a subtree merge fights the fact that `container/`'s Dockerfile build context is staged by a script, not built standalone (see `container/README.md`) |
| Worker auth model | **Keep `CONTROL_API_SECRET` bearer for the template's v1**; validating the Cloudflare OAuth token directly is deferred to its own future issue once the template repo exists and can be iterated on independently of the app | The bespoke-secret path is implemented, tested, and already what the app captures; swapping to native OAuth-token validation changes the Worker's request shape and is exactly the kind of change that's safer to make once there's a real deployed template to test against, not blocking template repo #1 |
| Deploy-to-Cloudflare button | Wire the real button once the template repo (above) exists and has had at least one manual deploy verified against a live account | Matches the onboarding design's own caveat: the interim docs-link button must not claim to deploy until something really does |

## Scope (filed as follow-up issues, in dependency order)

This doc replaces #894 with four concretely scoped issues that can be picked up independently
(the first two are prerequisites for the third; the fourth depends on the third):

1. [#1643](https://github.com/Anglesite/Anglesite/issues/1643) — Bake the guest scripts
   (`auth-proxy.js`, new `mcp-server.js`) into the Cloudflare guest image so `/start`'s three
   `startProcess` calls actually succeed.
2. [#1644](https://github.com/Anglesite/Anglesite/issues/1644) — Pin `Dockerfile.cloudflare`'s
   canonical image by digest instead of a floating tag, with a script to update the pin after a
   `build-container-image.sh --push`.
3. [#1645](https://github.com/Anglesite/Anglesite/issues/1645) — Stand up
   `Anglesite/anglesite-control-worker-template` as a real, independently deployable repo (mirrored
   from `Workers/ControlWorker/` + `container/`) that Cloudflare's Deploy-to-Cloudflare button can
   target — including one manually-verified live deploy. Depends on #1643 and #1644.
4. [#1646](https://github.com/Anglesite/Anglesite/issues/1646) — Wire the real Deploy-to-Cloudflare
   button into `RemoteConnectForm`, replacing the interim docs link, once #1645 has a verified live
   deploy.

## Non-goals (explicitly still out of scope)

- The live end-to-end integration test the 2026-06-23 design already called for (boots a real
  sandbox, asserts HMR over the tunnel, authenticated MCP round-trip) — depends on #3 existing
  first, and is folded into #3's acceptance criteria rather than filed separately.
- Cloudflare OAuth-token-as-Worker-auth (see table above) — explicitly deferred past the template
  repo's v1.
- Any change to `RemoteSandboxSiteRuntime`, `SandboxControlClient`, or the wire contract — all of
  that is locked and already tested; this doc is entirely about what serves that contract on the
  Cloudflare side.

## Epic touchpoints

- **#894** — closes as superseded by this doc + the four filed issues.
- **#66 / #67** — this is the remaining assembly work on top of what #423/#448 already shipped.
- **#62** — the canonical image this reuses; the digest-pinning gap is the direct follow-up to its
  "Distribution decision (Q-D)."
- **2026-07-21 onboarding design** — its interim "Cloudflare Container Setup Guide" button is what
  issue #4 above replaces with a real one.
