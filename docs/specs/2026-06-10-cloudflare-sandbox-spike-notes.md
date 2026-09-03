# Cloudflare Sandbox spike (#61) — findings

> **Status:** in progress. Scaffold + local image validation done; live Cloudflare
> measurements pending (need the account's Containers/Sandbox + a browser for HMR).
> Spike code: `Spikes/CloudflareSandboxSpike/` (deleted once its findings landed here — see #1802).
> Part of #59 · feeds **Q-D** (image distribution) and **#5b** (cold-start strategy).

Throwaway spike to prove the **remote substrate** end-to-end: run the shared OCI image
(#62) in a Cloudflare Sandbox, clone a real Anglesite site, `astro dev`, reach it from a
desktop browser, and measure. No app changes.

## Setup as built

- **Worker + `@cloudflare/sandbox` 0.12.1** drives one sandbox (formerly `Spikes/CloudflareSandboxSpike/`, since deleted).
- **Image** = canonical Anglesite image (#62) + the Cloudflare `/sandbox` init binary
  (`docker.io/cloudflare/sandbox:0.12.1`) + `cloudflared`. Pinned the sandbox version in
  `container/Dockerfile.cloudflare` (was the `:latest` TODO #61 owned).
- **Exposure:** two paths wired — `exposePort()` preview URL (needs a custom domain with
  wildcard DNS) and a `cloudflared` quick tunnel (`*.trycloudflare.com`, no DNS). #61/design
  §3.3 call for the tunnel.

## Confirm (the load-bearing measurements)

| # | Question | Result | Notes |
|---|---|---|---|
| 1 | **Cold-start time** — clone + hydrate + `astro dev` ready | ⬜ TBD | `/start` returns `clone_ms` / `hydrate_ms` / `dev_ready_ms` / `total_ms`. Run warm vs cold. |
| 1a | hydrate fast-path (baked `node_modules` hardlink, #5b) actually hit? | ⬜ TBD | Check hydrate log: "reusing baked node_modules (zero install)" vs "npm ci". Depends on the site's lockfile matching the template. |
| 2 | **HMR works over the tunnel WebSocket** (edit in-container → browser updates) | ⬜ TBD | The acceptance test. Confirm WS upgrade survives the tunnel/proxy. |
| 3 | `pre-deploy-check` + `wrangler deploy` run cleanly **in-container** | ⬜ TBD | `/deploy`. Confirm the security hook runs where the files live. |
| 4 | **Snapshot** availability — does re-entry skip `npm ci`? | ⬜ TBD | Is container snapshotting GA on the account yet? If not, every cold start re-hydrates. |

## Findings confirmed during scaffolding (local Docker, no CF account)

- **✅ Init binary path corrected.** The Cloudflare Sandbox init is at **`/container-server/sandbox`**,
  **not** `/sandbox` — `container/Dockerfile.cloudflare` (and the spike Dockerfile) had the wrong path
  (it was the explicit TODO #61 owned). Inspecting `cloudflare/sandbox:0.12.1` also shows it bundles
  `node`, `bun`, `npm`, and **`cloudflared`** in `/usr/local/bin` — so we copy cloudflared from there
  instead of downloading it. Both Dockerfiles now `COPY --from=sandbox /container-server /container-server`
  with `ENTRYPOINT ["/container-server/sandbox"]`. Fix verified: the assembled image carries the
  init binary (99 MB), cloudflared, `git`, the baked deps (`/opt/anglesite/baked`), and the scripts.
- **⚠️ ARCH MISMATCH (the headline finding for Q-D).** `cloudflare/sandbox:0.12.1` is **linux/amd64-only**
  (`docker build` warns `InvalidBaseImagePlatform` on arm64). Cloudflare Containers run **amd64**;
  `scripts/build-container-image.sh` was **hardcoded `linux/arm64`** (for Apple Silicon / Apple
  Containerization). So "one image, two substrates" can't be literally one arch — the canonical image
  must be built **multi-arch** (`linux/amd64,linux/arm64`) or per-substrate, and the build script needs
  a `PLATFORM`/multi-arch option. Cost (build time, registry size) → **Q-D**.
  - **RESOLVED in the build script (#298, 2026-06-22):** `PLATFORM` is now an env override
    (default `linux/arm64`; set `linux/amd64` for CF, or a comma list for multi-arch). A multi-arch
    `PLATFORM` is rejected with `--load` (buildx can't load a multi-platform manifest) and a `--push`
    build passes `--provenance=false` so the push is a plain image manifest, not an attestation index that
    Apple `container` / CF image pull can reject. The **one-vs-two-image** distribution decision (Q-D)
    is still open — pending the live run confirming the amd64 image boots in a Sandbox.
- **Image strategy is a real fork for #66.** Two ways to combine the toolchains, to decide:
  - **A (current design):** canonical Anglesite image (multi-arch) as base + `COPY /container-server`
    from the sandbox image. Keeps toolchain layers byte-identical to what Apple Containerization runs,
    but pins the CF image to amd64 (sandbox binary's arch) and couples to the sandbox image's internal
    layout (`/container-server`).
  - **B (CF-documented):** `FROM cloudflare/sandbox:0.12.1` + add the Anglesite toolchain on top. The
    supported pattern; gets node/bun/cloudflared for free; amd64-only; layers diverge from the local
    substrate. Recommendation pending the live run.
- **Preview-URL strategy.** `exposePort()` requires a custom domain w/ wildcard DNS; `.workers.dev`
  can't do the `*-sandbox-<id>` subdomains. The tunnel sidesteps it but adds `cloudflared` to the
  image + a per-session process. Which does #66 ship? ⬜ decide.
- **MCP-over-HTTP now unblocked.** #63 (plugin HTTP transport) + #64 (`MCPClient` HTTP transport)
  **landed** since this image was designed — `start-dev-server.sh`'s "until then... stdio" comment is
  now stale. The container can start the plugin's MCP server in HTTP mode
  (`ANGLESITE_MCP_TRANSPORT=http`) alongside `astro dev`, and the app reaches it via
  `MCPClient.connect(httpEndpoint:)`. #66 should expose a *second* port for it. ⬜ validate the
  edit pipeline over the tunnel too.
- **`instance_type`** — started at `"standard"`. Does `astro dev` + `npm` fit? Record RAM/CPU need.
- **`sleepAfter` / cost** — containers sleep after ~10m idle and lose disk; re-entry re-clones +
  re-hydrates unless snapshots are available (#5b). Measure the re-entry penalty.

## Local validation (done — no CF account)

- **Canonical image build** (`IMAGE_TAG=spike scripts/build-container-image.sh`): ✅ builds clean,
  `linux/arm64`, Node 24.15.0. Digest `sha256:057ae307…`. So #62's image assembles.
- **Spike image build** (canonical + `/container-server/sandbox` + cloudflared): ✅ assembles after the
  path fix (arm64 base + amd64 sandbox → cosmetic `InvalidBaseImagePlatform` warning; layers export
  cleanly). Verified contents: init binary, cloudflared, git, baked deps, `start-dev-server.sh`/`hydrate.sh`.
- **Runnable `docker run` smoke** (clone + hydrate + `astro dev` on :4321): ⬜ pending an **amd64**
  canonical build — the arm64 spike image can't execute the amd64 init binary. Do this with the
  amd64/multi-arch canonical image alongside the live CF run.

## Output / recommendation

_(to fill once measured)_ — real cold-start numbers, the arch decision for Q-D, the
preview-URL strategy for #66, and whether snapshots change the #5b plan.
