# Apple `container` CLI Vendoring Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Building the macOS app requires no Docker — the two app-image vendor scripts use Apple's `container` CLI instead of docker/buildx.

**Architecture:** Swap the builder inside `scripts/vendor-container-image.sh` (buildx OCI export → `container build -o type=oci`) and `scripts/vendor-container-kernel.sh` (FROM-only buildx hack → `container image pull` + `container image save`). Staging, untar, `.gitkeep`-preserving wipes, and layout validation are unchanged. A shared preflight (`scripts/lib/container-cli.sh`) checks the CLI exists and starts its API server. Align `BundledImage.imageReference` with whatever name annotation Apple `container` writes.

**Tech Stack:** bash, Apple `container` CLI ≥ 1.1, Swift (one constant, maybe), SwiftPM.

**Spec:** `docs/superpowers/specs/2026-07-08-apple-container-cli-vendoring-design.md`

## Global Constraints

- Scope is the app-build path only: `scripts/build-container-image.sh` (Cloudflare/remote pipeline) stays on Docker/buildx. Do not touch it.
- No changes to `Containers/anglesite-dev/Dockerfile`.
- Logs are sacred: `container build` / `pull` output streams through unmodified — no `>/dev/null` on build steps.
- Preserve the `.gitkeep`-preserving wipe pattern in both scripts exactly as-is.
- Requires an Apple-Silicon Mac with Apple `container` CLI installed (v1.1.0 confirmed present on this machine).
- Work happens in the current worktree (`.claude/worktrees/feedback-551-f5ae64`); all commands run from the worktree root.

---

### Task 1: Preflight helper + migrate `vendor-container-image.sh`

**Files:**
- Create: `scripts/lib/container-cli.sh`
- Modify: `scripts/vendor-container-image.sh` (header comment lines 1–9; build section lines 69–99)

**Interfaces:**
- Produces: `ensure_container_cli()` — sourced bash function, no args, exits 1 with an install pointer if `container` is missing, otherwise runs `container system start` (idempotent). Task 3 sources the same file.

- [ ] **Step 1: Create the shared preflight**

```bash
#!/usr/bin/env bash
# Shared preflight for scripts that build/pull images with the Apple `container` CLI
# (https://github.com/apple/container). Source this file, then call ensure_container_cli.
#
# NOT used by scripts/build-container-image.sh — the Cloudflare/remote pipeline
# intentionally stays on Docker/buildx (amd64 + registry-push concerns).

ensure_container_cli() {
    if ! command -v container >/dev/null 2>&1; then
        echo "ERROR: Apple 'container' CLI not found on PATH." >&2
        echo "       Install it from https://github.com/apple/container/releases and re-run." >&2
        exit 1
    fi
    # Idempotent: no-ops when the API server is already up. `container build` and
    # `container image pull` fail without a running server, so always start it here.
    container system start
}
```

Save as `scripts/lib/container-cli.sh` (no chmod needed — it is sourced, not executed).

- [ ] **Step 2: Rewrite the header comment of `scripts/vendor-container-image.sh`**

Replace lines 1–9 (everything above `set -euo pipefail`) with:

```bash
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
```

- [ ] **Step 3: Source the preflight**

Immediately after the `ROOT=...` line, add:

```bash
source "$ROOT/scripts/lib/container-cli.sh"
```

and call `ensure_container_cli` right before the build (see Step 4).

- [ ] **Step 4: Replace the buildx build with `container build`**

Replace the block from `echo "Building anglesite-dev:latest (linux/arm64)…"` through the `docker buildx build … "$CTX"` invocation (currently lines 69–99: the builder-guard comment, the `docker buildx inspect/create` guard, and the build command) with:

```bash
echo "Building anglesite-dev:latest (linux/arm64)…"
ensure_container_cli

echo "Exporting OCI layout → $OUT"
# Wipe any stale layout contents but preserve the committed .gitkeep placeholder so
# git does not report a deletion (the gitignore rules exclude everything else in the dir).
find "$OUT" -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true
mkdir -p "$OUT"

# Build for linux/arm64 and emit an OCI archive (tar) directly, then untar it into the
# layout directory. Apple `container build` outputs OCI natively (`-o type=oci,dest=…`
# is its default output type), so no separate builder is needed — this is the reason
# the old docker-container buildx builder (`anglesite-oci`) existed, and it is gone.
ARCHIVE="$OUT/image.tar"
container build \
    --os linux --arch arm64 \
    --tag anglesite-dev:latest \
    --output "type=oci,dest=${ARCHIVE}" \
    "$CTX"

tar -xf "$ARCHIVE" -C "$OUT"
rm -f "$ARCHIVE"
```

Keep the existing untar/validation lines that follow — but note the old script had its own `tar -xf` + `rm -f` after the build; make sure the result has exactly one untar (the block above) followed by the unchanged `for f in oci-layout index.json blobs/sha256` validation loop and the final `echo`/`ls`.

- [ ] **Step 5: Sanity-check the script parses**

Run: `bash -n scripts/vendor-container-image.sh && bash -n scripts/lib/container-cli.sh`
Expected: no output, exit 0. Also `grep -c docker scripts/vendor-container-image.sh` → expect `0` (case-insensitive check too: `grep -ci docker` should only hit if a comment still mentions it — remove any leftovers except none should remain).

- [ ] **Step 6: Run the script for real**

Run: `ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite scripts/vendor-container-image.sh`
Expected: staging messages, `container build` progress, then `Done. Resources/container-image/ now holds an OCI layout.` and an `ls -la` showing `oci-layout`, `index.json`, `blobs/`.
(First run may pull the base image; allow several minutes.)

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/container-cli.sh scripts/vendor-container-image.sh
git commit -m "feat(scripts): build the app image with Apple container CLI, not Docker"
```

---

### Task 2: Align `BundledImage.imageReference` with the emitted annotation

**Files:**
- Inspect: `Resources/container-image/index.json` (built in Task 1)
- Modify (only if needed): `Sources/AnglesiteContainer/BundledImage.swift:78-82`

**Interfaces:**
- Consumes: the OCI layout produced by Task 1.
- Produces: `BundledImage.imageReference` (public static let, String) matching the layout's name annotation exactly.

- [ ] **Step 1: Inspect the annotation**

Run: `python3 -c "import json;print(json.dumps(json.load(open('Resources/container-image/index.json'))['manifests'][0].get('annotations',{}),indent=2))"`
Expected: an annotations dict. Look for `io.containerd.image.name` and/or `org.opencontainers.image.ref.name` and note the exact value(s).

- [ ] **Step 2: Compare against the Swift constant**

Current value in `Sources/AnglesiteContainer/BundledImage.swift:82`:
`public static let imageReference = "docker.io/library/anglesite-dev:latest"`

Decision rule: `ContainerizationControl.loadOrGet` calls `ImageStore.get(reference: BundledImage.imageReference)` after `load(from:)`. The store keys images by the reference recorded in the layout. If the annotation from Step 1 equals the current constant → no change; skip to Step 5. If it differs (e.g. Apple `container` writes `anglesite-dev:latest` unqualified) → Steps 3–4.

- [ ] **Step 3 (conditional): Update the constant and its comment**

Replace lines 78–82 of `Sources/AnglesiteContainer/BundledImage.swift` with (substituting the actual observed value):

```swift
    /// The reference under which the imported app image is addressed in the on-disk `ImageStore`.
    /// Apple `container build` (scripts/vendor-container-image.sh) records this reference in the
    /// OCI layout's index annotations — this constant must match that recorded form exactly so
    /// `ImageStore.get(reference:)` finds the image after `load(from:)`.
    public static let imageReference = "<observed value>"
```

- [ ] **Step 4 (conditional): Build + unit tests**

Run: `swift build --target AnglesiteContainer && swift test --filter AnglesiteContainerTests`
Expected: build succeeds; any non-VM unit suite passes (VM-booting suites are env-gated off by default).

- [ ] **Step 5: Commit (only if a change was made)**

```bash
git add Sources/AnglesiteContainer/BundledImage.swift
git commit -m "fix(container): match imageReference to Apple container's OCI name annotation"
```

If no change was needed, record that in the task notes and move on — no commit.

---

### Task 3: Migrate the initfs half of `vendor-container-kernel.sh`

**Files:**
- Modify: `scripts/vendor-container-kernel.sh` (header lines 1–11; initfs export lines 87–109)

**Interfaces:**
- Consumes: `ensure_container_cli()` from `scripts/lib/container-cli.sh` (Task 1).

- [ ] **Step 1: Update the header comment**

Replace lines 7–11 (the initfs description + requirements lines) with:

```bash
# initfs: pulls ghcr.io/apple/containerization/vminit:0.34.0 (linux/arm64) with the Apple
#   `container` CLI and re-exports it as an OCI layout via `container image save`.
#
# Mirrors scripts/vendor-container-image.sh: produces gitignored, bundled app resources.
# Requires the Apple `container` CLI (≥ 1.1, https://github.com/apple/container) on an
# Apple-Silicon Mac. (The kernel half needs only curl/tar.)
```

- [ ] **Step 2: Source the preflight**

After the `ROOT=...` line add:

```bash
source "$ROOT/scripts/lib/container-cli.sh"
```

- [ ] **Step 3: Replace the FROM-only buildx export**

Replace the block from the builder-guard comment (line 87) through the heredoc build (line 105) — i.e. the `docker buildx inspect/create` guard, the wipe, and `docker buildx build … - <<<"FROM ${VMINIT_IMAGE}"` — with:

```bash
ensure_container_cli

# Wipe stale layout but preserve .gitkeep.
find "$INITFS_OUT" -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true
mkdir -p "$INITFS_OUT"

INITFS_ARCHIVE="$TMP/initfs.tar"
echo "Exporting OCI layout from ${VMINIT_IMAGE} (linux/arm64)…"
# Pull then save: `container image save` emits an OCI-compatible tar archive directly —
# no FROM-only Dockerfile build needed (that was a buildx workaround).
container image pull --platform linux/arm64 "$VMINIT_IMAGE"
container image save --platform linux/arm64 --output "$INITFS_ARCHIVE" "$VMINIT_IMAGE"
```

Keep the untar (`tar -xf "$INITFS_ARCHIVE" -C "$INITFS_OUT"`), the `rm -f`, the `REQUIRED_INITFS_ENTRIES` validation, and the skopeo fallback exactly as they are — but update the fallback's lead-in comment word "buildx" to "container image save" so it reads correctly:

In the comment above the fallback, change
`If buildx fails to emit a complete layout, fall back` → `If the container-CLI export fails to emit a complete layout, fall back`
and inside the fallback block change
`this recovery path is only hit if the buildx OCI export above fails` → `this recovery path is only hit if the container-CLI OCI export above fails`.

- [ ] **Step 4: Sanity-check + grep**

Run: `bash -n scripts/vendor-container-kernel.sh && grep -ci docker scripts/vendor-container-kernel.sh`
Expected: parse OK; grep returns `1` (exit 0) only for the skopeo `docker://` transport URL, which is a protocol name, not a Docker dependency — verify with `grep -i docker scripts/vendor-container-kernel.sh` that the only hit is the `docker://${VMINIT_IMAGE}` line.

- [ ] **Step 5: Run the script for real**

Run: `scripts/vendor-container-kernel.sh`
Expected: kernel download (~290 MB) + extraction messages, then `Exporting OCI layout from ghcr.io/apple/containerization/vminit:0.34.0 (linux/arm64)…`, pull progress, and the final verification listing showing `vmlinux` (~14 MiB) and an initfs layout with blobs.

- [ ] **Step 6: Commit**

```bash
git add scripts/vendor-container-kernel.sh
git commit -m "feat(scripts): vendor the vminit initfs with Apple container CLI, not Docker"
```

---

### Task 4: Documentation updates

**Files:**
- Modify: `Containers/README.md:5-12`
- Modify: `docs/build-plan.md:126`
- Modify: `CLAUDE.md:116` (the Containerization-epic paragraph) and `CLAUDE.md` "Stack" bullet if it mentions Docker (it does not — verify)

**Interfaces:** none (prose only).

- [ ] **Step 1: `Containers/README.md`**

Replace lines 5–12 with:

```markdown
`scripts/vendor-container-image.sh` builds `Containers/anglesite-dev/Dockerfile`
with Apple's `container` CLI, exports the result as an OCI layout into
`Resources/container-image/`, and the `AnglesiteContainer` Swift target bundles
that inert Linux root filesystem as app data.

Building the app needs no Docker: the Apple `container` CLI (≥ 1.1) is the image
builder, and at runtime Anglesite boots the vendored OCI image with Apple's
Containerization framework via `ContainerizationControl`. Docker remains only in
the separate Cloudflare/remote pipeline (`scripts/build-container-image.sh`).
```

- [ ] **Step 2: `docs/build-plan.md` line 126**

In the `macOS OCI image` bullet, change
`scripts/vendor-container-image.sh` builds it with Docker/buildx, exports an OCI layout` → `scripts/vendor-container-image.sh` builds it with Apple's `container` CLI, exports an OCI layout`
and change `Docker is only the image builder, not the app runtime.` → `Building the app needs no Docker; the Cloudflare/remote pipeline below is the only remaining Docker consumer.`

- [ ] **Step 3: `CLAUDE.md` Containerization paragraph**

In the paragraph at line 116, change
`Docker/buildx is only an image-build tool for producing that OCI root filesystem; the app does not run Docker.` → `The image is built with Apple's `container` CLI (`scripts/vendor-container-image.sh`); building the app needs no Docker. Docker/buildx remains only in the Cloudflare/remote image pipeline (`scripts/build-container-image.sh`).`
Also update the later sentence `Docker/buildx is only an image-build tool` if present elsewhere — run `grep -ni docker CLAUDE.md` and fix every hit to reflect the new reality.

- [ ] **Step 4: Verify no stale claims**

Run: `grep -rni 'requires docker\|docker/buildx' scripts/vendor-container-image.sh scripts/vendor-container-kernel.sh Containers/README.md CLAUDE.md docs/build-plan.md`
Expected: no hits describing the app-build path; hits inside `scripts/build-container-image.sh` context lines are fine (out of scope).

- [ ] **Step 5: Commit**

```bash
git add Containers/README.md docs/build-plan.md CLAUDE.md
git commit -m "docs: app image vendoring uses Apple container CLI, not Docker"
```

---

### Task 5: End-to-end boot verification

**Files:** none modified — verification only.

**Interfaces:**
- Consumes: vendored `Resources/container-image/`, `Resources/container-kernel/vmlinux`, `Resources/container-initfs/` from Tasks 1 and 3.

- [ ] **Step 1: Unit suites**

Run: `swift test --package-path .`
Expected: all default (non-VM) suites pass. If it hangs with no output, check `pgrep -fl swift-test` for a stale lock-holder first (known failure mode).

- [ ] **Step 2: Entitled boot probe**

Run: `scripts/run-container-probe.sh boot`
Expected: the probe builds, self-signs with the virtualization entitlement, imports the freshly vendored layouts, boots the container, and the preview HTTP poll succeeds. This exercises the Apple-container-built image end-to-end, including the `imageReference` lookup from Task 2.

- [ ] **Step 3: Record results**

If the probe passes: done. If it fails at image import, re-check the Task 2 annotation decision before debugging anything else — a reference mismatch is the most likely regression this migration can introduce (mitigated by the single-image `loadOrGet` fallback, so a hard failure here points at layout structure instead).

---

## Self-review notes

- Spec coverage: §1→Task 1, §2→Task 3, §3 preflight→Task 1 Step 1 (+Task 3 Step 2), §4→Task 2, §5 error handling→Task 1/3 (preflight + unmodified streaming), §6 docs→Task 4, verification→Tasks 1/3 real runs + Task 5.
- The Cloudflare pipeline and Dockerfile are untouched per Global Constraints.
