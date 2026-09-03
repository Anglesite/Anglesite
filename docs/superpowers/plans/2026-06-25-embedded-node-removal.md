# Embedded Node Removal (#70) — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **⛔ DO NOT START PHASE B (teardown) until the Gating Checklist below is fully satisfied.** Every item in #70's scope is currently load-bearing — the host `LocalSiteRuntime` is the *active* preview runtime on every build today (the container path is gated behind `BundledImage.isProvisioned` + the virtualization entitlement and is selected on zero builds), and embedded Node is also used by deploy, audit, scaffold, and Cloudflare-token-verify, none of which have moved into a container. Removing it before the preconditions are met leaves builds with **no runtime**.

**Goal:** Retire the vendored Node.js binary, its build-time vendor/re-sign apparatus, the JIT entitlements, and the host-subprocess dev-server runtime — once the container runtimes (#69 local, #66 remote) and all host-side Node consumers have replaced it, so no platform is left without a runtime.

**Architecture:** Two stages. **Phase A (prerequisites)** migrates the *non-dev-server* host-side Node consumers (deploy / audit / scaffold / token-verify) off embedded Node — each is its own design-bearing effort, tracked separately, listed here as gating items. **Phase B (teardown)** is the mechanical removal this plan details task-by-task: delete the host dev-server runtime, `NodeRuntime`, the scripts, the resources, the entitlements, and the build phases, then update docs and close #4/#70. The general `Process()`-based spawn substrate (`InProcessBackend` / `ProcessSupervisor` / `SupervisorBackend`) **stays** — it spawns git, `gh`, the container tooling, etc.; only its Node coupling is removed.

**Tech Stack:** Swift 6 / SwiftUI, SPM, XcodeGen (`project.yml`), Apple Containerization (#69), Cloudflare Sandbox (#66), Swift Testing + XCTest.

## Global Constraints

- **Gating is absolute:** no Phase B task may be executed until every Gating Checklist item is ✅. The reviewer of the first Phase B task must confirm the checklist in the PR description.
- **No platform left without a runtime:** after teardown, every target must still have a working preview path — macOS via `LocalContainerSiteRuntime` (#69), iOS/fallback via `RemoteSandboxSiteRuntime` (#66). If MAS cannot run a container (Wall‑2 entitlement not granted) it must route to the remote runtime, or this plan does not proceed for MAS.
- **`InProcessBackend` / `ProcessSupervisor` / `SupervisorBackend` are NOT removed** — they are the general subprocess substrate (git, `gh`, container CLIs). Only the Node-specific coupling (`ProcessSupervisor.defaultEnvironment` putting `node-runtime/bin` on `PATH`, and callers passing `NodeRuntime.bundledExecutableURL`) is removed.
- **Both schemes must build after every task:** `Anglesite` (DevID) and `AnglesiteMAS`. Verify with `xcodebuild ... -scheme <X> build CODE_SIGNING_ALLOWED=NO` (real-signed runs need the cert; not required for these structural changes).
- **Commit trailer:** end every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## Gating Checklist — ALL must be ✅ before any Phase B task

- [ ] **#69 container boot proven** — Task 10 done: an entitled Apple-Silicon build boots a `LocalContainerSiteRuntime`, serves the preview, and round-trips `apply_edit` through the in-container MCP endpoint.
- [ ] **Container is the default macOS runtime** — `PreviewModel.makeRuntime` selects `LocalContainerSiteRuntime` for normal entitled builds (kernel/initfs/sidecar provisioned for distribution, not just env-overrides), so `LocalSiteRuntime` is no longer the active path.
- [ ] **#66 remote runtime shipped** — `RemoteSandboxSiteRuntime` + the Cloudflare Worker control plane work, so iOS and any non-container fallback has a runtime.
- [ ] **MAS runtime resolved** — either Wall‑2 (`com.apple.security.virtualization`) is granted for MAS, or MAS is wired to the remote runtime. MAS must not be left runtime-less.
- [ ] **Phase A complete** — all four host-side Node consumers migrated off `NodeRuntime.bundledExecutableURL` (see Phase A). Confirm with `git grep NodeRuntime` returning only the dev-server-runtime call sites that Phase B removes.

---

## Phase A — Prerequisite migrations (NOT detailed here; each needs its own plan)

These host-side operations use embedded Node independently of the preview runtime. Each must be migrated **before** Phase B, and each is a design-bearing effort that warrants its own spec/plan. They are listed as gating items with the strategy direction from the roadmap ("all JS in-guest"); do not treat them as bite-sized tasks of this plan.

| # | Consumer | Node use today | Migration direction |
|---|---|---|---|
| A1 | `DeployCommand` (`resolveBuildCommand` `:330`, `resolveWranglerCommand` `:314`, `defaultPreflight` `:297`) | `npm run build`, `wrangler deploy`, `npx tsx pre-deploy-check.ts` | Run build + `pre-deploy-check` + deploy **in-container** (per `docs/specs/2026-05-30-cloudflare-sandbox-dev-server-design.md` §deploy), or via a native deploy path. |
| A2 | `AuditCommand` (`resolveBuildCommand` `:182`) + `A11yAuditRunner` | `npm run build`, `npx tsx a11y-audit.ts` | Run the audit build + runners in-container, or port the audit to native Swift. **Design not yet written.** |
| A3 | `SiteScaffolder` (`:124`) | `npm install` in the new site dir | Scaffold installs in-container, or defer install to first container boot. **Design not yet written.** |
| A4 | `CloudflareTokenVerifier` (`defaultRunner` `:139`) | `wrangler whoami` | Replace with a native Cloudflare API call (`GET /user/tokens/verify`) — no Node needed — or run in-container. |

**Exit criterion for Phase A:** none of `DeployCommand`, `AuditCommand`, `SiteScaffolder`, `CloudflareTokenVerifier`, or `A11yAuditRunner` reference `NodeRuntime.bundledExecutableURL`, and none rely on `ProcessSupervisor.defaultEnvironment` putting the vendored Node on `PATH`.

---

## File Structure (Phase B teardown surface)

**Delete outright:**
- `Sources/AnglesiteCore/NodeRuntime.swift` + `Tests/AnglesiteCoreTests/NodeRuntimeTests.swift`
- `Sources/AnglesiteCore/LocalSiteRuntime.swift` + its tests; `Sources/AnglesiteCore/AstroDevServer.swift` (if not used elsewhere — verify)
- `scripts/vendor-node.sh`, `scripts/resign-node.sh`, `scripts/vendor-npm-cache.sh`
- `Resources/node-runtime-devid.entitlements`, `Resources/node-runtime.entitlements`
- `Resources/node-runtime/` (gitignored build artifact — nothing to delete in git; stops being produced)

**Modify:**
- `Sources/AnglesiteCore/ProcessSupervisor.swift:68,73` — drop the Node-on-PATH default environment
- `Sources/AnglesiteApp/PreviewModel.swift` — remove the `LocalSiteRuntime` fallback branch
- `Sources/AnglesiteCore/MCPClient*.swift` — remove the stdio transport if only the dev-server used it (keep HTTP/Streamable for the container)
- `project.yml` — remove `Resources/node-runtime` sources + the vendor-node / vendor-npm-cache prebuild phases + the resign-node postbuild phases on both `Anglesite` and `AnglesiteMAS`
- `Resources/Anglesite.entitlements` — audit + drop the JIT keys (`cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.allow-executable-page-protection`, `cs.disable-library-validation`, `cs.allow-dyld-environment-variables`) once no remaining spawn needs them
- `scripts/build-overlay.sh`, `scripts/create-smoke-fixture.sh`, `scripts/release-mas.sh` — drop `node-runtime` references
- `Tests/AnglesiteTestSupport/E2EPrerequisites.swift` + the e2e tests that `#require(locateNode())` — repoint to the container
- `docs/build-plan.md` — mark #70 ✅, note Phase 10.1 Node tasks obsolete

**Keep (do NOT remove):** `InProcessBackend.swift`, `SupervisorBackend.swift`, `ProcessSupervisor.swift` (minus the Node coupling), `scripts/copy-plugin.sh` (still stages the plugin for the container image, per #323).

---

## Phase B — Teardown tasks

> Each task: make the removal, prove the build/tests still pass and no dangling references remain, commit. "RED" for a removal is a grep that still finds the symbol; "GREEN" is the grep coming back empty + the build passing.

### Task B1: Remove the host dev-server runtime (`LocalSiteRuntime` + the `PreviewModel` fallback)

**Files:**
- Modify: `Sources/AnglesiteApp/PreviewModel.swift` (the `makeRuntime` factory — remove the `LocalSiteRuntime` branch)
- Delete: `Sources/AnglesiteCore/LocalSiteRuntime.swift`, `Sources/AnglesiteCore/AstroDevServer.swift` (verify no other references first)
- Delete: the corresponding tests (`Tests/AnglesiteCoreTests/LocalSiteRuntimeTests.swift`, `AstroDevServerTests.swift` if present)

**Interfaces:**
- Consumes: `LocalContainerSiteRuntime` (#69), `RemoteSandboxSiteRuntime` (#66) — the surviving runtimes.
- Produces: `PreviewModel.makeRuntime` returns only `LocalContainerSiteRuntime` (macOS) or `RemoteSandboxSiteRuntime` (iOS/fallback).

- [ ] **Step 1: Confirm nothing outside the dev-server path references the doomed types.** Run `git grep -n 'LocalSiteRuntime\|AstroDevServer'` — every hit must be in `PreviewModel`, the files being deleted, or their tests. If a *non-dev-server* consumer appears, STOP — Phase A is incomplete.
- [ ] **Step 2: Rewrite `PreviewModel.makeRuntime`** to drop the `LocalSiteRuntime(contentGraph:)` fallback. On macOS (`#if !ANGLESITE_MAS` / arch as appropriate) return `LocalContainerSiteRuntime`; otherwise return `RemoteSandboxSiteRuntime`. There is no host-subprocess fallback.
- [ ] **Step 3: Delete `LocalSiteRuntime.swift` + `AstroDevServer.swift` + their tests.**
- [ ] **Step 4: Verify.** `swift build`; `swift test 2>&1 | tail`; `xcodegen generate && xcodebuild -scheme Anglesite -configuration Debug build CODE_SIGNING_ALLOWED=NO` and the same for `-scheme AnglesiteMAS`. All green. `git grep -n LocalSiteRuntime` → empty.
- [ ] **Step 5: Commit** (`feat(#70): remove host dev-server runtime; container/remote are the only preview paths`).

### Task B2: Remove `NodeRuntime` + the `ProcessSupervisor` Node-on-PATH coupling

**Files:**
- Delete: `Sources/AnglesiteCore/NodeRuntime.swift`, `Tests/AnglesiteCoreTests/NodeRuntimeTests.swift`
- Modify: `Sources/AnglesiteCore/ProcessSupervisor.swift:68,73`

- [ ] **Step 1: Confirm no remaining callers.** `git grep -n 'NodeRuntime\|bundledExecutableURL\|environmentWithNodeOnPath'` — after Task B1 + Phase A, the only hits must be `NodeRuntime.swift`, its test, and `ProcessSupervisor.swift`. Any other hit ⇒ STOP.
- [ ] **Step 2: Change `ProcessSupervisor`'s default environment** from `{ NodeRuntime.environmentWithNodeOnPath }` to the plain process environment (`{ ProcessInfo.processInfo.environment }`), in both the `init()` default and the `init(backend:defaultEnvironment:)` default (lines 68, 73).
- [ ] **Step 3: Delete `NodeRuntime.swift` + `NodeRuntimeTests.swift`.** (The `environment(_:prependingPATH:)` PATH helper dies with it — it had no non-Node callers.)
- [ ] **Step 4: Verify.** `swift build`; `swift test`; `git grep -n NodeRuntime` → empty. `ProcessSupervisorTests` still pass (they spawn `/bin/echo` etc., unaffected).
- [ ] **Step 5: Commit** (`feat(#70): remove NodeRuntime and the Node-on-PATH supervisor default`).

### Task B3: Remove the vendor/re-sign scripts + `project.yml` build phases

**Files:**
- Delete: `scripts/vendor-node.sh`, `scripts/resign-node.sh`, `scripts/vendor-npm-cache.sh`
- Modify: `project.yml` (both targets), `scripts/build-overlay.sh`, `scripts/create-smoke-fixture.sh`, `scripts/release-mas.sh`

- [ ] **Step 1: Edit `project.yml`.** On BOTH `Anglesite` and `AnglesiteMAS`: remove the `Resources/node-runtime` entry from `sources`; remove the `Vendor Node runtime` and `Vendor primed npm cache` `preBuildScripts`; remove the `Re-sign bundled Node …` `postBuildScripts` (the DevID one passing `node-runtime-devid.entitlements`, and the MAS one). Leave `copy-plugin.sh`, `build-overlay.sh`, `build-help-index.sh` prebuild phases in place.
- [ ] **Step 2: Drop `node-runtime` references in the remaining scripts.** `build-overlay.sh` (use system `npm` only), `create-smoke-fixture.sh` (remove the hardcoded `node-runtime/bin/node` smoke check + npm path), `release-mas.sh` (remove the `node-runtime/bin/node` codesign-verify block).
- [ ] **Step 3: Delete the three vendor/resign scripts.**
- [ ] **Step 4: Verify.** `git grep -n 'node-runtime\|vendor-node\|resign-node\|vendor-npm-cache'` → only matches in deleted-file history / docs, none in `project.yml` or live scripts. `xcodegen generate` succeeds; both schemes build `CODE_SIGNING_ALLOWED=NO` (no missing-script-phase errors); the built `.app` has no `Contents/Resources/node-runtime/`.
- [ ] **Step 5: Commit** (`build(#70): drop Node vendor/re-sign scripts and project.yml phases`).

### Task B4: Remove the Node entitlements + audit the app JIT keys

**Files:**
- Delete: `Resources/node-runtime.entitlements`, `Resources/node-runtime-devid.entitlements`
- Modify: `Resources/Anglesite.entitlements` (after audit)

- [ ] **Step 1: Delete the two `node-runtime*.entitlements`** — nothing references them now that `resign-node.sh` is gone (`git grep -n node-runtime.*entitlements` → empty).
- [ ] **Step 2: Audit the JIT keys in `Resources/Anglesite.entitlements`.** The comment at `:19` says these exist for "Spawning Node, wrangler, gh, claude as child processes." Confirm which remaining spawned process (post-Phase-A: git, `gh`, container CLIs — Node/wrangler are gone) actually needs each of: `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.allow-executable-page-protection`, `cs.disable-library-validation`, `cs.allow-dyld-environment-variables`. JIT/unsigned-memory/executable-page-protection were V8-specific → removable. `disable-library-validation` and `allow-dyld-environment-variables` → confirm no surviving spawn needs them (likely removable) before dropping. Keep `com.apple.security.virtualization` (that's #69).
- [ ] **Step 3: Remove the keys the audit cleared** from `Anglesite.entitlements`. `AnglesiteMAS.entitlements` has no JIT keys (they lived only on the Node binary) — leave it.
- [ ] **Step 4: Verify.** `plutil -lint Resources/Anglesite.entitlements` passes; `xcodegen generate`; both schemes build `CODE_SIGNING_ALLOWED=NO`. (A real-signed + notarized smoke is the author's follow-up to confirm the slimmer entitlements still launch — flag in the PR.)
- [ ] **Step 5: Commit** (`build(#70): delete Node entitlements; drop V8 JIT keys from the app entitlements`).

### Task B5: Repoint the e2e test prerequisites off local Node

**Files:**
- Modify: `Tests/AnglesiteTestSupport/E2EPrerequisites.swift`; `Tests/AnglesiteBridgeTests/AppliesEditEndToEndTests.swift`; `Tests/AnglesiteCoreTests/MCPClientHTTPEndToEndTests.swift`; `Tests/AnglesiteIntentsTests/ContentPipelineE2ETests.swift`, `SmokeMatrixTests.swift`; `Tests/.../NewSiteWizardModelTests.swift`

- [ ] **Step 1: Decide the post-Node e2e story.** The apply-edit / MCP-HTTP e2e tests spun up a local Node + the plugin MCP server (`E2EPrerequisites.locateNode()`). With the server in-container, either (a) repoint these to the container-backed MCP endpoint (becomes the same surface as #69's `ContainerizationControlTests`, so they may be redundant — consolidate), or (b) gate them the way the container e2e is gated (`ANGLESITE_CONTAINER_E2E`). Pick (a) where a container e2e already covers it; otherwise (b).
- [ ] **Step 2: Update `E2EPrerequisites`** — remove `locateNode()` (no local Node anymore); replace the prerequisite probe with the container/remote availability check, or delete prerequisites that are now covered by container e2e.
- [ ] **Step 3: Update `NewSiteWizardModelTests`** — the `testBuildWithInstallWarningSurfacesWarning…` test asserted a "Bundled Node not found" warning from `SiteScaffolder`. After Phase A (A3) the scaffold install path changed; update the test to the migrated behavior.
- [ ] **Step 4: Verify.** `swift test` green; `git grep -n locateNode` → empty (or only the repurposed helper).
- [ ] **Step 5: Commit** (`test(#70): repoint e2e prerequisites off local Node to the container runtime`).

### Task B6: Docs + close issues

**Files:** `docs/build-plan.md`; GitHub issues #4, #70

- [ ] **Step 1: Update `docs/build-plan.md`** — flip `#70` to ✅ with a one-line summary; note the Phase 10.1 embedded-Node tasks (vendor/re-sign) are obsolete; note #4 (DevID re-sign) is closed as moot.
- [ ] **Step 2: Verify** the doc renders and the `#70`/`#4` references are consistent.
- [ ] **Step 3: Commit** (`docs(#70): mark embedded-Node removal complete; retire Phase 10.1 Node tasks`).
- [ ] **Step 4: Close #4** (re-sign moot — no nested foreign Mach-O) and **#70** with a comment linking the teardown PRs.

---

## Self-Review

**Spec coverage (vs. #70's scope checklist):**
- `vendor-node.sh` / `resign-node.sh` / `vendor-npm-cache.sh` → Task B3. ✅
- `Resources/node-runtime/` + `node-runtime*.entitlements` → B3 (resources) + B4 (entitlements). ✅
- `NodeRuntime`, `InProcessBackend`, `LocalSiteRuntime`, `Process()` paths → B1 (`LocalSiteRuntime`) + B2 (`NodeRuntime` + supervisor coupling). **Deviation from the issue's wording:** `InProcessBackend` and the general `Process()` substrate are deliberately KEPT (they spawn git/`gh`/container CLIs) — only the Node coupling is removed. Documented in Global Constraints; flag for the human (the issue's "InProcessBackend … no longer needed" is inaccurate). ✅-with-note
- Drop `cs.allow-jit` / `cs.allow-unsigned-executable-memory` / `cs.disable-library-validation` → B4 (after audit). ✅
- Update `build-plan.md` + close #4 → B6. ✅

**Prerequisite honesty:** the four host-side Node consumers (deploy/audit/scaffold/token-verify) are *not* dev-server-runtime and are gated as Phase A — this plan does not pretend to remove Node while they still need it. ✅

**Placeholder scan:** Phase A items are intentionally scoped as prerequisites needing their own plans (not bite-sized steps) — this is a stated boundary, not a hidden TODO. Phase B tasks have concrete files, commands, and verification. ✅

**Type/symbol consistency:** `NodeRuntime.bundledExecutableURL` / `environmentWithNodeOnPath` (B2), `ProcessSupervisor.defaultEnvironment` (B2), `PreviewModel.makeRuntime` (B1), `E2EPrerequisites.locateNode()` (B5) — names match the inventory. ✅

---

## Execution Handoff

**This plan is gated and not yet executable** — Phase B must not start until the Gating Checklist is satisfied (#69 Task 10 + container-default, #66 shipped, MAS runtime resolved, Phase A migrations done). When that day comes, execute Phase B with **superpowers:subagent-driven-development** (fresh subagent per task + review), confirming the Gating Checklist in the first PR's description.
