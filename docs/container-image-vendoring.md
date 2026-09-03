# Container Image Vendoring

This is the end-to-end runbook for the container boot artifacts Anglesite bundles
and consumes: the local Apple Containerization image, its kernel/initfs, and the
Cloudflare/Linux images built from the same `Containers/anglesite-dev/` source.
It replaces piecing the procedure together from script comments — see
[`docs/superpowers/plans/2026-07-08-apple-container-cli-vendoring.md`](superpowers/plans/2026-07-08-apple-container-cli-vendoring.md)
for the historical design rationale if you need it.

## Which builder for which runtime

Three scripts build images from two source contexts. Picking the wrong one is
the most common mistake — none of them error if you run it expecting a
different runtime to pick up the result.

| Script | Source context | Tool | Runtime it feeds |
|---|---|---|---|
| [`scripts/vendor-container-image.sh`](../scripts/vendor-container-image.sh) | `Containers/anglesite-dev/` | Apple `container` CLI | **Apple Containerization** (local macOS app, arm64-only) — exports an OCI layout into `Resources/container-image/`, bundled into the app |
| [`scripts/build-podman-image.sh`](../scripts/build-podman-image.sh) | `Containers/anglesite-dev/` | podman | **Linux** `SiteRuntime` substrate (`PodmanContainerControl`) — tags into the local podman store natively for the host's own arch, nothing exported |
| [`scripts/build-container-image.sh`](../scripts/build-container-image.sh) | `container/` (lowercase) | Docker buildx | **Cloudflare Sandbox** / remote runtime (#62) — pushed to a registry by digest; also usable for a local amd64/arm64 dev image outside the app |

`Containers/anglesite-dev/` and `container/` are two different build contexts
that happen to live near each other in the tree — see
[`container/README.md`](../container/README.md) for why the lowercase
directory still exists. If you're provisioning the macOS app for local
development, you want `vendor-container-image.sh` plus
`vendor-container-kernel.sh` below, not either of the other two.

## The Apple Containerization loop: build → vendor → verify

This is the path that matters for day-to-day macOS app development. Three
gitignored resource directories feed the app bundle via SwiftPM `.copy()`
rules on `AnglesiteContainer`:

- `Resources/container-image/` — the OCI-layout image, from `vendor-container-image.sh`
- `Resources/container-kernel/` — the Linux kernel (`vmlinux`), from `vendor-container-kernel.sh`
- `Resources/container-initfs/` — the vminit OCI layout, also from `vendor-container-kernel.sh`

An unprovisioned tree still **builds** — Debug just warns and Release fails
(see [`scripts/check-container-resources.sh`](../scripts/check-container-resources.sh)
below) — but every site preview fails at runtime with `imageLayoutNotProvisioned;
kernelNotProvisioned; initfsNotProvisioned` (`BundledImage.swift`) until these
are populated.

### Prerequisites

- An Apple-Silicon Mac.
- The Apple [`container`](https://github.com/apple/container) CLI, ≥ 1.1, on `PATH`.
- `ANGLESITE_SIDECAR_SRC` pointing at a checkout of the sibling
  [`Anglesite/anglesite-skills`](https://github.com/Anglesite/anglesite-skills) repo
  with a `server/index.mjs` and `package.json` — see [Worktrees and `ANGLESITE_SIDECAR_SRC`](#worktrees-and-anglesite_sidecar_src) below. `ANGLESITE_PLUGIN_SRC` is a legacy alias.
- `jq` (`brew install jq`), needed by the kernel/initfs script and the lock helpers.

### 1. Build + vendor the image

```sh
scripts/vendor-container-image.sh
```

This builds `anglesite-dev:latest` from `Containers/anglesite-dev/` with the
`container` CLI (arm64 only — `--build-arg BASE_IMAGE=...` pins the arm64 base
explicitly so the CLI doesn't try to resolve an unused amd64 `FROM` stage),
exports it as an OCI layout via `container image save` (a two-step
build-then-save, not `container build --output type=oci`, which is broken in
CLI 1.1.0), and writes the result into `Resources/container-image/`. It also
stamps `vendor-manifest.json` with the app's current MCP protocol version and
the staged sidecar's `package.json` version — `check-container-resources.sh`
compares that stamp on every subsequent build so a sidecar/app protocol drift
surfaces at build time instead of as an opaque MCP HTTP error at preview time
(#1407).

Before building, it stages the MCP sidecar (from `$ANGLESITE_SIDECAR_SRC`) and
the template's dependency manifests into `Containers/anglesite-dev/` via
[`scripts/lib/stage-dev-image-context.sh`](../scripts/lib/stage-dev-image-context.sh),
then cleans the staged copies up on exit — they're gitignored build-time
inputs, not tracked content.

### 2. Vendor the kernel + initfs

```sh
scripts/vendor-container-kernel.sh
```

Two independent artifacts, both required by Apple Containerization 0.34:

- **Kernel** — downloads the Kata Containers arm64 static release bundle,
  extracts the container-optimized `vmlinux.container` kernel (the same one
  `apple/containerization`'s `make fetch-default-kernel` uses), and copies it
  to `Resources/container-kernel/vmlinux`.
- **initfs** — resolves `ghcr.io/apple/containerization/vminit:<tag>` to a
  manifest digest via the registry API directly (so the digest is verified
  *before* pulling), pulls by that digest with the `container` CLI, and
  re-exports it as an OCI layout into `Resources/container-initfs/` via
  `container image save` (falling back to `skopeo copy` if the CLI's export
  comes out incomplete — install with `brew install skopeo` if you ever hit
  that path).

Both halves are checked against
[`scripts/container-artifact-versions.lock.json`](../scripts/container-artifact-versions.lock.json)
as they're fetched (see [Bumping the pinned versions](#bumping-the-pinned-versions-lock-bump) below) — a
mismatch against an already-pinned value is a hard failure, not a warning,
since it means what was just downloaded differs from what was previously
recorded as good.

### 3. Verify

```sh
scripts/check-container-resources.sh
```

This is also wired into the Xcode build (hence its Debug-warn/Release-error
split, and its `warning:`/`error:` line prefixes that Xcode's issue navigator
parses), but run it directly after vendoring to confirm before you launch the
app. It checks, for each of the three resource directories:

- **Presence** — the expected marker file exists (`container-image/index.json`,
  `container-kernel/vmlinux`, `container-initfs/index.json`).
- **Digest** (kernel + initfs only — the locally built image is excluded from
  digest-pinning since it's non-deterministic, #616) — the on-disk artifact's
  hash matches the lock file, when the lock has a pin recorded. An entry with
  no pin yet (`null`) never fails here.
- **MCP protocol stamp** (image only) — `vendor-container-image.sh`'s
  `vendor-manifest.json` stamp matches this build's current
  `MCPClient.protocolVersion`.

`ANGLESITE_CONTAINER_IMAGE` / `ANGLESITE_CONTAINER_KERNEL` /
`ANGLESITE_CONTAINER_INITFS` env vars override the default `Resources/`
paths (mirroring what `BundledImage.swift` honors at runtime) — an override
still gets the same existence/digest checks, not a free pass.

A **Release** build fails on any missing/mismatched artifact; set
`ANGLESITE_ALLOW_UNPROVISIONED_CONTAINER=1` to downgrade that to a warning
(never for a build you intend to distribute).

### Fast path: copying artifacts instead of rebuilding

Rebuilding needs Docker-free but still slow `container` CLI builds/downloads.
If you just need a working preview in a fresh worktree and the image itself
hasn't changed, copy the artifacts from the main checkout instead — see
[`docs/testing-macos-app.md`](testing-macos-app.md#container-boot-artifacts-fresh-worktrees)
for the `rsync` one-liner. Only re-vendor from scratch when
`Containers/anglesite-dev/` or the pinned kernel/initfs versions actually
changed.

## Bumping the pinned versions (lock bump)

`scripts/container-artifact-versions.lock.json` pins the Kata kernel release
and the vminit image tag/digest that `vendor-container-kernel.sh` fetches and
`check-container-resources.sh` verifies against. It's committed (not
gitignored) — it's metadata describing what *should* be vendored, not a
vendored binary itself.

To pick up a new upstream kernel or vminit release:

1. Edit the two version lines near the top of `vendor-container-kernel.sh`:

   ```sh
   KATA_VERSION="3.17.0"
   VMINIT_TAG="0.34.0"
   ```

2. Re-run with `--update-lock`:

   ```sh
   scripts/vendor-container-kernel.sh --update-lock
   ```

   This fetches the new versions, computes their digests, and writes them
   into the lock file (with `pinned_at` dates) instead of verifying against
   the *old* pinned values. Without `--update-lock`, changing the version
   lines and running normally would just hard-fail the mismatch check —
   that's intentional; a version bump has to be a deliberate, explicit step.

3. Re-verify:

   ```sh
   scripts/check-container-resources.sh
   ```

   Confirm it reports the freshly vendored artifacts as provisioned and that
   the digests it checks now come from the updated lock.

4. Commit the updated `scripts/container-artifact-versions.lock.json` alongside
   the version-line change in `vendor-container-kernel.sh`. The vendored
   `Resources/container-kernel/` and `Resources/container-initfs/` outputs
   stay gitignored as always — only the lock (the pin) is tracked.

5. Smoke-test a real container boot before opening the PR — a lock bump that
   points at a kernel/initfs pair Apple Containerization can't actually boot
   is exactly the failure class #616 exists to catch. See
   [`docs/testing-macos-app.md`](testing-macos-app.md) for how to launch the
   Debug app and confirm a preview boots.

## Worktrees and `ANGLESITE_SIDECAR_SRC`

All three build scripts (via `stage_dev_image_context` for the two
Apple-Containerization/podman scripts, and directly in
`build-container-image.sh`) resolve the MCP sidecar checkout from
`$ANGLESITE_SIDECAR_SRC`, falling back to `../anglesite` next to the repo root
if unset (`ANGLESITE_PLUGIN_SRC` is a legacy alias for the same variable).
That default resolves correctly from the main checkout, but **not** from a
worktree under `.claude/worktrees/<name>/` — `../anglesite` from there points
outside the parent repo entirely. Set it explicitly:

```sh
export ANGLESITE_SIDECAR_SRC=/path/to/github.com/Anglesite/anglesite-skills
```

Staging also enforces a minimum sidecar version (currently 1.9.0, matching the
CI sidecar pin in `.github/workflows/ci.yml`) — a too-old checkout still
builds and boots but silently breaks the MCP path (`tools/call` 400s), so
`stage_dev_image_context` fails loudly instead of baking that mismatch into
the image. Bump both pins together when the sidecar's minimum requirement
changes.

## See also

- [`container/README.md`](../container/README.md) — the Cloudflare/shared
  image's own directory-level README (what's in the image, its runtime
  contract, the digest-pinning distribution decision).
- [`docs/testing-macos-app.md`](testing-macos-app.md) — building, launching,
  and smoke-testing the app headless, including the fresh-worktree artifact
  fast path referenced above.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — general contribution workflow;
  see "Worktrees" in `CLAUDE.md`/`AGENTS.md` for the broader worktree-setup
  checklist `ANGLESITE_SIDECAR_SRC` is one part of.
- #616 (closed) — the distribution-grade provisioning design this lock file
  and verification script implement. #1643, #1644 — open follow-ups on the
  Cloudflare guest image side (baking guest scripts in, digest-pinning),
  outside this doc's local-macOS scope.
