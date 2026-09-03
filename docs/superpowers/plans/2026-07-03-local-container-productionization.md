# Local Container Productionization (#69) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `LocalContainerSiteRuntime` the sole preview runtime for launch: isolate/fix the vsock handshake mystery with a minimal repro, replace custom guest plumbing with off-the-shelf socat, bake the template's npm dependencies into the OCI image (no cold in-guest `npm install`), and remove the proof-of-concept host-runtime fallback.

**Architecture:** The guest image (built by `Containers/anglesite-dev/Dockerfile`, vendored by `scripts/vendor-container-image.sh`) gains socat (replacing the Go `vsock-bridge`) and a pre-baked `/opt/anglesite/baked/node_modules` hydrated into cloned sites via the existing `container/hydrate.sh` pattern. `ContainerizationControl` boot execs change accordingly. A new minimal vsock echo e2e test isolates the host↔guest vsock path from all app logic. `LiveSiteRuntimeFactory` stops silently falling back to `LocalSiteRuntime` and instead returns an `UnavailableSiteRuntime` that settles to the existing `.failed` UI state. `LocalSiteRuntime` itself is NOT deleted — `HeadlessRuntimePool` (Siri/Shortcuts, bundled-code-only) still uses it.

**Tech Stack:** Swift 6.4 / Xcode 27, SwiftPM + xcodegen, apple/containerization 0.35.0, Docker buildx (image vendoring only), socat, Swift Testing.

## Global Constraints

- Work in worktree `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/mystifying-noether-aad6be` — every subagent must `cd` there before any command.
- Branch stacks on PR #475: base is `origin/claude/strange-curie-172ac3` (Task 0 merges it). The eventual PR's base branch is `claude/strange-curie-172ac3`, NOT `main`.
- `export ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite` before any script that stages the plugin.
- Run `xcodegen generate` before any `xcodebuild` (project file is gitignored).
- Unit verification: `swift test --package-path .` — all suites must stay green. App-link verification (Task 6): `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`.
- Live e2e verification: `ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 swift test --filter <SuiteName>` on this (entitled, Apple Silicon) machine. CI never runs these (`ANGLESITE_SKIP_CONTAINER=1` there).
- No new third-party Swift dependencies. The Go toolchain dependency is REMOVED by this plan.
- containerization pin: exactly `.upToNextMinor(from: "0.35.0")`.
- **Merge caveat:** file/line references below were read at `origin/main`. PR #475 modified `ContainerizationControl.swift`, `VsockTCPProxy.swift`, and boot logging. After Task 0's merge, locate the quoted code by content, not line number, and preserve #475's logging/`onEvent` hooks when editing.

---

### Task 0: Branch setup on top of PR #475

**Files:**
- No source edits. Git + project generation only.

**Interfaces:**
- Produces: worktree branch `claude/mystifying-noether-aad6be` containing all of #475's commits; generated `Anglesite.xcodeproj`.

- [ ] **Step 1: Merge #475's branch**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/mystifying-noether-aad6be
git fetch origin claude/strange-curie-172ac3 main
git merge --no-edit origin/claude/strange-curie-172ac3
```
Expected: clean merge (worktree is at origin/main with no local commits). If conflicts appear, they are between #475 and post-#475 main commits — resolve preferring #475's versions of `VsockTCPProxy.swift`/`ContainerizationControl.swift` (they contain the restored crash fix), then continue.

- [ ] **Step 2: Generate project and sanity-build**

```bash
xcodegen generate
swift build --package-path .
```
Expected: build succeeds.

- [ ] **Step 3: Claim the issue**

```bash
gh issue comment 69 --body "Claimed: productionization plan in progress on branch claude/mystifying-noether-aad6be (stacked on #475) — socat bridge, baked template deps, vsock echo repro, fallback removal. Plan: docs/superpowers/plans/2026-07-03-local-container-productionization.md"
```

- [ ] **Step 4: Commit the plan file**

```bash
git add docs/superpowers/plans/2026-07-03-local-container-productionization.md
git commit -m "docs(#69): local-container productionization plan"
```

---

### Task 1: Bump apple/containerization to 0.35.0

**Files:**
- Modify: `Package.swift:163-165`
- Check: `project.yml` (bump any matching pin if present)

**Interfaces:**
- Produces: resolved containerization 0.35.0 (includes upstream vsock fixes #503/#572/#678/#712 and the EXT4 hardlink-unpack fix #777, which matters for Task 3's baked node_modules layer).

- [ ] **Step 1: Edit the pin**

In `Package.swift`, change:
```swift
.package(url: "https://github.com/apple/containerization.git", .upToNextMinor(from: "0.34.0"))
```
to:
```swift
.package(url: "https://github.com/apple/containerization.git", .upToNextMinor(from: "0.35.0"))
```
Then `grep -n containerization project.yml` — if a version appears there too, update it to match.

- [ ] **Step 2: Resolve and build**

```bash
swift package update containerization
swift build --package-path .
```
Expected: builds. Known 0.34→0.35 API delta is additive (EXT4Unpacker gained an optional journal parameter defaulting to nil; PodVolume additions) — if a compile error appears in `ContainerizationControl.swift`'s `EXT4Unpacker(blockSizeInBytes:)` call, keep our call unchanged (the new parameter has a default).

- [ ] **Step 3: Run the full unit suite**

```bash
swift test --package-path .
```
Expected: all suites green (~1154 tests).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved project.yml
git commit -m "chore(#69): bump apple/containerization 0.34 -> 0.35 (upstream vsock + EXT4 fixes)"
```

---

### Task 2: Replace the Go vsock-bridge with socat

**Files:**
- Modify: `Containers/anglesite-dev/Dockerfile`
- Delete: `Containers/anglesite-dev/vsock-bridge/` (entire directory)
- Modify: `Sources/AnglesiteContainer/ContainerizationControl.swift` (the `runDetached(container, id: "bridge", ...)` call — find by content post-merge)

**Interfaces:**
- Consumes: guest image layout from the Dockerfile.
- Produces: guest ports 4321/4399 bridged by `/usr/bin/socat` processes exec'd with ids `"bridge-preview"` and `"bridge-mcp"`. Task 4's echo test also invokes `/usr/bin/socat` and relies on it being in the image.

- [ ] **Step 1: Rewrite the Dockerfile**

Replace the full contents of `Containers/anglesite-dev/Dockerfile` with:

```dockerfile
# Anglesite local dev-server image (arm64 / Apple Silicon). Built and exported as an OCI layout by
# scripts/vendor-container-image.sh, then bundled into AnglesiteContainer. Bakes Node + git + socat
# (the vsock<->TCP bridge) + the app's MCP sidecar (the plugin's server/, npm ci'd for linux-arm64 so
# sharp's native binary is correct) so a fresh container needs no in-guest install.

# Pinned to linux/arm64 digest for reproducible vendoring. Re-bump periodically for base security updates.
FROM node:22-bookworm-slim@sha256:6db9be2ebb4bafb687a078ef5ba1b1dd256e8004d246a31fd210b6b848ab6be2
# socat is the guest-side vsock<->TCP bridge: the host reaches astro/mcp (guest-local TCP) by
# dialing AF_VSOCK ports that socat forwards to 127.0.0.1 (no vmnet on the sandboxed host, #60).
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates socat \
    && rm -rf /var/lib/apt/lists/*
# MCP sidecar: staged by scripts/vendor-container-image.sh from the plugin's server/ dir.
# npm ci runs on linux/arm64 → pulls @img/sharp-linux-arm64 (the native prebuilt) from the
# lockfile. --omit=dev drops devDependencies. We intentionally do NOT pass --omit=optional
# because @img/sharp-linux-arm64 is marked optional in the lockfile (platform-specific prebuilt);
# npm's platform-cpu/os filters already skip macOS-only optionals like fsevents on linux/arm64.
COPY mcp-sidecar/ /usr/local/lib/anglesite-mcp/
# Playwright is an unused optionalDependency of the plugin. We keep `npm ci` (reproducible; lock-exact)
# and cannot pass --omit=optional because @img/sharp-linux-arm64 is also optional (platform prebuilt).
# ENV prevents playwright's postinstall from downloading ~300 MB of browsers; rm strips the pkg dirs.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN cd /usr/local/lib/anglesite-mcp \
    && npm ci --omit=dev \
    && rm -rf node_modules/playwright node_modules/playwright-core node_modules/.cache/ms-playwright
WORKDIR /workspace
```

- [ ] **Step 2: Delete the Go bridge**

```bash
git rm -r Containers/anglesite-dev/vsock-bridge
```

- [ ] **Step 3: Swap the boot exec in ContainerizationControl**

Find the detached `"bridge"` exec (at origin/main it reads `["/usr/local/bin/vsock-bridge", "4321:4321", "4399:4399"]`; #475 may have reordered it before astro/mcp and added logging — keep that ordering and logging). Replace the single call with two:

```swift
// Guest vsock<->TCP bridges (socat, baked into the image): map guest vsock ports onto the
// local TCP listeners so host-side dialVsock reaches them. One process per port; `fork`
// accepts unlimited sequential/parallel connections.
try await runDetached(container, id: "bridge-preview",
    ["/usr/bin/socat", "VSOCK-LISTEN:4321,reuseaddr,fork", "TCP:127.0.0.1:4321"])
try await runDetached(container, id: "bridge-mcp",
    ["/usr/bin/socat", "VSOCK-LISTEN:4399,reuseaddr,fork", "TCP:127.0.0.1:4399"])
```

- [ ] **Step 4: Sweep remaining references**

```bash
grep -rn "vsock-bridge" Sources/ Tests/ scripts/ docs/ Containers/ CLAUDE.md
```
Update any hits (comments in `ContainerizationControl.swift`, the `docs/qa/local-container-runtime-smoke-test.md` runbook if it names the binary). Expected end state: zero hits outside this plan file and historical PR/issue text.

- [ ] **Step 5: Build + unit tests**

```bash
swift build --package-path . && swift test --package-path .
```
Expected: green (no unit suite execs the bridge; `VsockTCPProxyTests` mock the dialer).

- [ ] **Step 6: Commit**

```bash
git add -A Containers/anglesite-dev Sources/AnglesiteContainer docs
git commit -m "feat(#69): replace Go vsock-bridge with socat in the guest image"
```

---

### Task 3: Bake template npm dependencies into the guest image

**Files:**
- Modify: `scripts/vendor-container-image.sh` (stage `template/` + `hydrate.sh` into the build context, next to the existing mcp-sidecar staging block)
- Modify: `Containers/anglesite-dev/Dockerfile` (baked-deps layer + hydrate script)
- Modify: `Sources/AnglesiteContainer/ContainerizationControl.swift` (the `"astro"` runDetached exec)

**Interfaces:**
- Consumes: `Resources/Template/package.json` + `Resources/Template/package-lock.json` (both exist; lockfile is ~246KB), `container/hydrate.sh` (single source of truth — do NOT fork a copy into `Containers/`).
- Produces: guest paths `/opt/anglesite/baked/{package.json,package-lock.json,node_modules}` and `/usr/local/bin/anglesite-hydrate`; boot no longer runs a cold registry `npm install` for template-derived sites.

- [ ] **Step 1: Stage template + hydrate in the vendor script**

In `scripts/vendor-container-image.sh`, immediately after the mcp-sidecar staging block (which ends with `cp "$PLUGIN_SRC/package-lock.json" "$SIDECAR_STAGE/"`), add — mirroring the sidecar's staging/cleanup conventions in that script:

```bash
# ---------------------------------------------------------------------------
# Stage the website template's dependency manifests + the hydrate script into
# the build context, so the image can bake the template's full node_modules
# (design §5b, same pattern as container/Dockerfile). hydrate.sh is shared
# with the Cloudflare image — container/hydrate.sh is the single source.
# ---------------------------------------------------------------------------
TEMPLATE_STAGE="$CTX/template"
echo "Staging template manifests from $ROOT/Resources/Template → $TEMPLATE_STAGE"
rm -rf "$TEMPLATE_STAGE"
mkdir -p "$TEMPLATE_STAGE"
cp "$ROOT/Resources/Template/package.json" "$TEMPLATE_STAGE/"
cp "$ROOT/Resources/Template/package-lock.json" "$TEMPLATE_STAGE/"
cp "$ROOT/container/hydrate.sh" "$CTX/hydrate.sh"
```

If the script has a cleanup section removing `$SIDECAR_STAGE` after the build, extend it to also remove `$TEMPLATE_STAGE` and `$CTX/hydrate.sh`.

- [ ] **Step 2: Add the baked layer to the Dockerfile**

Append to `Containers/anglesite-dev/Dockerfile` (before the final `WORKDIR /workspace` line):

```dockerfile
# ---- Pre-baked site toolchain (skip cold npm install on boot; design §5b) ----
# Install the template's full dependency closure once, at image-build time. This keeps the
# resolved node_modules so a cloned site whose lockfile matches the template reuses it with
# zero install (anglesite-hydrate), AND leaves npm's cache (/root/.npm) in the layer so a
# drifted-lockfile site's `npm ci --prefer-offline` mostly avoids the network. Full closure
# (no --omit=dev): astro dev/check need devDependencies (tsx, @astrojs/check, typescript).
ENV ANGLESITE_HOME=/opt/anglesite
COPY template/package.json template/package-lock.json ${ANGLESITE_HOME}/baked/
RUN cd ${ANGLESITE_HOME}/baked \
    && ( npm ci \
         || { echo "WARN: template lockfile out of sync — falling back to npm install" >&2; \
              npm install; } )
COPY hydrate.sh /usr/local/bin/anglesite-hydrate
RUN chmod +x /usr/local/bin/anglesite-hydrate
```

- [ ] **Step 3: Use hydrate in the boot exec**

In `ContainerizationControl.swift`, change the `"astro"` detached exec from:

```swift
try await runDetached(container, id: "astro", ["sh", "-lc",
    "cd /workspace/site && npm install --no-audit --no-fund && npx astro dev --port 4321 --host 127.0.0.1"])
```
to:
```swift
// Hydrate deps from the image's baked toolchain (zero-install hardlink when the site's
// lockfile matches the template; offline-first npm ci otherwise), then start astro.
try await runDetached(container, id: "astro", ["sh", "-lc",
    "/usr/local/bin/anglesite-hydrate /workspace/site && cd /workspace/site && npx astro dev --port 4321 --host 127.0.0.1"])
```

- [ ] **Step 4: Build + unit tests**

```bash
swift build --package-path . && swift test --package-path .
```
Expected: green (template guard suites like `IntegrationTemplateAssetsTests` are unaffected — the template itself is unchanged).

- [ ] **Step 5: Commit**

```bash
git add scripts/vendor-container-image.sh Containers/anglesite-dev/Dockerfile Sources/AnglesiteContainer/ContainerizationControl.swift
git commit -m "feat(#69): bake template npm deps into the guest image; hydrate on boot"
```

---

### Task 4: Re-vendor artifacts + minimal vsock echo e2e test (the diagnostic gate)

**Files:**
- Modify: `Sources/AnglesiteContainer/ContainerizationControl.swift` (extract an internal bare-boot helper)
- Create: `Tests/AnglesiteContainerLocalTests/VsockEchoEndToEndTests.swift`

**Interfaces:**
- Consumes: socat in the image (Task 2), vendored image/kernel/initfs, `BundledImage` env overrides (`ANGLESITE_CONTAINER_IMAGE`/`_KERNEL`/`_INITFS`) for out-of-bundle test runs.
- Produces: `ContainerizationControl.makeBareContainer(siteID:) async throws -> LinuxContainer` (internal; phases 0–2 of `start()` — artifact resolution, EXT4 unpack, VM create+start, NO repo mount/clone/astro) and `ContainerizationControl.stopBareContainer(_:siteID:) async` for teardown. Reused by the echo test via `@testable import`.

- [ ] **Step 1: Ensure Docker is available, then re-vendor the image**

```bash
docker info >/dev/null || { echo "Docker required for image vendoring"; exit 1; }
export ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite
scripts/vendor-container-image.sh
ls Resources/container-image/index.json
```
Expected: OCI layout regenerated with socat + baked deps. If `Resources/container-kernel/vmlinux` or `Resources/container-initfs/index.json` are missing in this worktree (they're gitignored), also run `scripts/vendor-container-kernel.sh`.

- [ ] **Step 2: Extract the bare-boot helper**

In `ContainerizationControl.swift`, refactor `start(siteID:sourceRepo:ref:)` so phases 0–2 (artifact resolution → EXT4 unpack → `LinuxContainer` create/start) live in an internal helper that `start()` calls. The repo virtio-fs mount only applies when a repo is provided:

```swift
/// Phases 0–2 of `start()`: resolve bundled artifacts, unpack rootfs/initfs, boot the VM.
/// `sourceRepo: nil` boots a bare container (no virtio-fs share) — used by the vsock e2e test.
internal func makeBareContainer(siteID: String, sourceRepo: URL? = nil) async throws -> LinuxContainer
```

`start()` becomes `let container = try await makeBareContainer(siteID: siteID, sourceRepo: sourceRepo)` followed by the existing phases 3–6 unchanged. Add the matching internal teardown that mirrors the cleanup `stop()`/failure paths already perform for the ext4 artifacts:

```swift
internal func stopBareContainer(_ container: LinuxContainer, siteID: String) async
```

Also expose the existing private `runDetached` to tests by marking it `internal` (it is currently `private`).

- [ ] **Step 3: Write the echo test**

Create `Tests/AnglesiteContainerLocalTests/VsockEchoEndToEndTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteContainer

/// Minimal synthetic repro for the #69 vsock handshake mystery: no git, no npm, no astro —
/// one guest socat echo listener on an AF_VSOCK port, one host dialVsock, assert bytes
/// round-trip. If THIS fails, the bug is in the framework/kernel vsock path and this file
/// is the upstream repro; if it passes, the failure lives in Anglesite's full boot flow.
@Suite struct VsockEchoEndToEndTests {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_E2E"] == "1"
    }

    @Test("host dialVsock reaches a guest vsock listener and bytes round-trip")
    func vsockEchoRoundTrip() async throws {
        try #require(enabled, "set ANGLESITE_CONTAINER_E2E=1 on an entitled Apple-Silicon Mac")

        let control = ContainerizationControl()
        let container = try await control.makeBareContainer(siteID: "vsock-echo-e2e")
        do {
            try await control.runDetached(container, id: "echo",
                ["/usr/bin/socat", "VSOCK-LISTEN:9999,reuseaddr,fork", "EXEC:cat"])

            // Retry the dial until the listener is up (socat needs a beat to bind).
            var handle: FileHandle?
            var lastError: Error?
            for _ in 0..<40 {
                do {
                    handle = try await container.dialVsock(port: 9999)
                    break
                } catch {
                    lastError = error
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            let fh = try #require(
                handle,
                "never dialed guest vsock :9999 within 10s; last error: \(String(describing: lastError))")

            let payload = Data("ping-vsock-echo\n".utf8)
            try fh.write(contentsOf: payload)

            // Read until the payload echoes back (or 10s deadline).
            var received = Data()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while received.count < payload.count, ContinuousClock.now < deadline {
                let chunk = fh.availableData
                if chunk.isEmpty {
                    try await Task.sleep(for: .milliseconds(100))
                } else {
                    received.append(chunk)
                }
            }
            #expect(received == payload,
                "echo mismatch: got \(received.count) bytes — the dial-ok/instant-EOF signature means the vsock data path is broken at the framework layer")
            try? fh.close()
        } catch {
            await control.stopBareContainer(container, siteID: "vsock-echo-e2e")
            throw error
        }
        await control.stopBareContainer(container, siteID: "vsock-echo-e2e")
    }
}
```

(Adapt `runDetached`'s call shape to its real post-#475 signature; if `FileHandle.availableData` proves exception-prone here — the #470 lesson — read via `read(fh.fileDescriptor, ...)` on a captured fd instead, mirroring `VsockTCPProxy`'s POSIX pump.)

- [ ] **Step 4: Compile-check the gated target**

```bash
ANGLESITE_CONTAINER_TESTS=1 swift build --package-path . --build-tests
```
Expected: builds.

- [ ] **Step 5: Run the echo test live (THE decision gate)**

```bash
ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 swift test --package-path . --filter VsockEchoEndToEndTests
```
- **PASS** → raw vsock works post-0.35/socat. The mystery is in the full boot flow's interaction; proceed to Task 5 (which now has a working baseline to diff against).
- **FAIL with the dial-ok/instant-EOF signature** → framework-level repro achieved in ~80 lines with zero app logic. STOP, report: file an upstream apple/containerization issue attaching this test, note it on #69, and surface to the user before continuing (Tasks 5–6 still proceed; the boot timeout root cause is now upstream's).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteContainer/ContainerizationControl.swift Tests/AnglesiteContainerLocalTests/VsockEchoEndToEndTests.swift
git commit -m "test(#69): minimal vsock echo e2e — isolates the host<->guest vsock path"
```

---

### Task 5: Full-boot live verification

**Files:**
- No planned source edits (diagnostic task; small fixes allowed if the run surfaces one — commit separately with its own message).

**Interfaces:**
- Consumes: everything above.
- Produces: a #69 comment with the boot outcome + timing; go/no-go signal for Task 6.

- [ ] **Step 1: Run the existing full-boot e2e**

```bash
ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 swift test --package-path . --filter ContainerizationControlTests 2>&1 | tail -40
```
Expected: `bootsAndServes` passes, and total boot time is well under the 90s `waitUntilServing` window (hydrate should make the astro start seconds-fast). Record wall-clock time.

- [ ] **Step 2: Interpret**

- Pass → the timeout is resolved; note which change(s) plausibly fixed it (0.35 bump vs socat vs no-cold-install) based on Task 4's gate result.
- Fail, echo test passing → diff the two flows (bare boot + socat echo vs full boot): remaining variables are the virtio-fs repo mount, git clone, concurrent execs, and the two proxies. Bisect by adding those elements to a copy of the echo test one at a time. Report findings on #69 before attempting fixes beyond one obvious culprit.

- [ ] **Step 3: Post results to #69**

```bash
gh issue comment 69 --body "<results: pass/fail, boot wall-clock, which hypothesis the echo-test gate confirmed/eliminated, next steps if any>"
```

---

### Task 6: Remove the host-runtime preview fallback

**Files:**
- Create: `Sources/AnglesiteCore/UnavailableSiteRuntime.swift`
- Create: `Tests/AnglesiteCoreTests/UnavailableSiteRuntimeTests.swift`
- Modify: `Sources/AnglesiteApp/SiteRuntimeFactory.swift` (lines 44-58 at origin/main)
- Check: `Sources/AnglesiteApp/PreviewModel.swift:159` comment ("capability gate chose the host runtime") — update wording to match the new behavior.

**Interfaces:**
- Consumes: `SiteRuntime` protocol (`Sources/AnglesiteCore/SiteRuntime.swift:28-33`): `start(siteID:siteDirectory:) async`, `stop() async`, `observe() -> AsyncStream<SiteRuntimeState>`, `var mcpClient: MCPClient { get }`. `MCPClient(supervisor: .shared)` is a valid initializer (see `SiteRuntimeFactory.swift:39`).
- Produces: `public actor UnavailableSiteRuntime: SiteRuntime`, `init(reasons: [String])`. NOT touched: `LocalSiteRuntime` (still used by `HeadlessRuntimePool.swift:43` for Siri/Shortcuts headless edits — bundled code only, no npm install, no MAS problem) and its three test suites.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/UnavailableSiteRuntimeTests.swift`:

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct UnavailableSiteRuntimeTests {
    @Test("start settles to .failed with every reason in the message")
    func startFails() async throws {
        let runtime = UnavailableSiteRuntime(reasons: [
            "signed build is missing com.apple.security.virtualization",
            "Linux kernel: vmlinux not found"
        ])
        let stream = await runtime.observe()
        await runtime.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/tmp/s1"))

        var failedMessage: String?
        for await state in stream {
            if case .failed(let id, let message) = state {
                #expect(id == "s1")
                failedMessage = message
                break
            }
        }
        let message = try #require(failedMessage)
        #expect(message.contains("com.apple.security.virtualization"))
        #expect(message.contains("vmlinux not found"))
    }

    @Test("stop returns to idle without error")
    func stopIsIdempotent() async {
        let runtime = UnavailableSiteRuntime(reasons: ["x"])
        await runtime.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/tmp/s1"))
        await runtime.stop()
        await runtime.stop()
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --package-path . --filter UnavailableSiteRuntimeTests
```
Expected: FAIL — `UnavailableSiteRuntime` not defined.

- [ ] **Step 3: Implement**

Create `Sources/AnglesiteCore/UnavailableSiteRuntime.swift`. Mirror `LocalSiteRuntime`'s `observe()`/state-broadcast machinery exactly (continuation registry keyed by UUID, yield current state on subscribe, `onTermination` cleanup — copy the pattern from `LocalSiteRuntime.swift`, do not invent a new one):

```swift
import Foundation

/// Terminal `SiteRuntime` returned when the local container runtime is required but this
/// build/machine can't run it (missing virtualization entitlement, unprovisioned image/kernel/
/// initfs, unsupported hardware). It settles straight to `.failed` with the human-readable
/// reasons; there is deliberately NO host-subprocess preview fallback (#69) — running a site's
/// npm dependency tree as host processes is exactly what the container exists to avoid on MAS.
/// (Headless Siri/Shortcuts edits still use `LocalSiteRuntime`: bundled MCP server + bundled
/// Node only, no downloaded code.)
public actor UnavailableSiteRuntime: SiteRuntime {
    public let mcpClient: MCPClient
    private let reasons: [String]
    // state + continuation registry: copy LocalSiteRuntime's implementation verbatim.

    public init(reasons: [String]) {
        self.reasons = reasons
        self.mcpClient = MCPClient(supervisor: .shared)
    }

    public func start(siteID: String, siteDirectory: URL) async {
        setState(.failed(
            siteID: siteID,
            message: "This build can't run the site preview: " + reasons.joined(separator: "; ")))
    }

    public func stop() async { setState(.idle) }

    public func observe() -> AsyncStream<SiteRuntimeState> {
        // copy LocalSiteRuntime's observe() implementation
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --package-path . --filter UnavailableSiteRuntimeTests
```
Expected: PASS.

- [ ] **Step 5: Remove the fallback selection**

In `Sources/AnglesiteApp/SiteRuntimeFactory.swift`, replace the fallback return and reason helper (origin/main lines 44-58):

```swift
        logRuntimeSelection(Self.unavailableReason(support: support, provisioning: provisioning))
        return UnavailableSiteRuntime(
            reasons: Self.reasons(support: support, provisioning: provisioning))
    }

    private static func reasons(
        support: LocalContainerSupport.Availability,
        provisioning: BundledImageProvisioningReport
    ) -> [String] {
        var reasons: [String] = []
        if case .unavailable(let supportReasons) = support {
            reasons.append(contentsOf: supportReasons.map(\.description))
        }
        reasons.append(contentsOf: provisioning.missingDescriptions)
        return reasons
    }

    private static func unavailableReason(
        support: LocalContainerSupport.Availability,
        provisioning: BundledImageProvisioningReport
    ) -> String {
        "container runtime unavailable — preview disabled (no host fallback, #69): "
            + reasons(support: support, provisioning: provisioning).joined(separator: "; ")
    }
```

Also update the factory's doc comment (lines 19-24) — it still says "otherwise the existing host-subprocess runtime". And fix the stale comment at `PreviewModel.swift:159`.

- [ ] **Step 6: Full unit suite + app link check**

```bash
swift test --package-path .
xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
```
Expected: tests green; `BUILD SUCCEEDED` (per project memory, `swift test` alone doesn't prove the app target links).

- [ ] **Step 7: File the follow-up + commit**

```bash
gh issue create --title "Migrate HeadlessRuntimePool off LocalSiteRuntime; then delete the host preview runtime" \
  --body "Post-#69 cleanup. The preview fallback is removed (UnavailableSiteRuntime); LocalSiteRuntime remains only as HeadlessRuntimePool's default (Sources/AnglesiteCore/HeadlessRuntimePool.swift:43 — bundled MCP server + bundled Node, no npm install, so no MAS exposure). Once the container runtime can serve headless intents, point the pool at it and delete LocalSiteRuntime + its three test suites (LocalSiteRuntimeTests, LocalSiteRuntimeGraphTests, LocalSiteRuntimeReindexTests)."
git add Sources/AnglesiteCore/UnavailableSiteRuntime.swift Tests/AnglesiteCoreTests/UnavailableSiteRuntimeTests.swift Sources/AnglesiteApp/SiteRuntimeFactory.swift Sources/AnglesiteApp/PreviewModel.swift
git commit -m "feat(#69)!: remove host-runtime preview fallback; surface container unavailability as .failed"
```

---

### Task 7: Finish the branch

- [ ] **Step 1: Verification-before-completion**

Use superpowers:verification-before-completion. Re-run and capture: `swift test --package-path .` (full), the xcodebuild link check, and (if not already green in Tasks 4-5) the two live e2e suites.

- [ ] **Step 2: Push and open the stacked PR**

```bash
git push -u origin claude/mystifying-noether-aad6be
gh pr create --base claude/strange-curie-172ac3 \
  --title "feat(#69): productionize local container — socat bridge, baked template deps, vsock echo e2e, no host fallback" \
  --body "<summary per repo conventions: what changed, test plan with actual outputs, link #69 + this plan doc. End with the Claude Code attribution footer.>"
```
(Stacked on #475 per repo preference; retarget to `main` after #475 merges.)

- [ ] **Step 3: Report on #69 and to the user**

Comment on #69 with the final state (echo-gate verdict, boot timing before/after, fallback removal), then summarize for the user: outcomes, PR link, and anything that stopped early (e.g. an upstream framework bug filed from Task 4).
