# In-Container Deploy Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a site runs in a `LocalContainerSiteRuntime` (#69), deploy it by running the build + the plugin pre-deploy scan + `wrangler deploy` **inside that same running container** (where Node already lives), instead of host-side embedded Node — so deploy works on the container runtime and the host embedded-Node deploy path can eventually retire (#70 Phase A1).

**Architecture:** Add a captured/streaming `exec` to the `LocalContainerControl` seam (real impl in `ContainerizationControl`, fake for CI). Introduce a `DeployExecutor` abstraction with two conformers — `HostDeployExecutor` (today's `ProcessSupervisor` + embedded Node, unchanged) and `ContainerDeployExecutor` (routes each step through `control.exec` in the guest at `/workspace/site`, with the Cloudflare token delivered via the guest exec environment). `DeployCommand` drives the executor instead of resolving host commands directly. `SiteWindow` selects the container executor when the open site's runtime is a container, else the host one. **This adds the container path; it does not remove the host path** — that removal is #70 Phase B, after the container becomes the sole macOS runtime.

**Tech Stack:** Swift 6 / Swift Testing, Apple Containerization (#69, `LinuxContainer.exec`), `ProcessSupervisor`/`LogCenter` (existing host path), `wrangler`/Astro/`tsx` in-guest.

## Global Constraints

- **Additive, not destructive:** the host deploy path (`resolveWranglerCommand`/`resolveBuildCommand`/`defaultPreflight` via embedded Node) stays intact and remains the default for host-runtime/MAS builds. Removing it is out of scope (gated #70 Phase B).
- **CI boundary:** the real `ContainerizationControl.exec` lives in `AnglesiteContainer` and is NEVER compiled by `swift test` (the `ANGLESITE_SKIP_CONTAINER` gate). Everything CI must compile — the protocol method, the `DeployExecutor` abstraction, `ContainerDeployExecutor`, the `DeployCommand` refactor, and the fakes — lives in `AnglesiteCore` / the app target and is tested with `FakeLocalContainerControl`.
- **Author-gated e2e:** a real in-guest deploy can only run on an entitled Apple-Silicon build with a booting container (#69 Task 10). CI/agents verify compile + unit behavior with fakes; the live build→scan→wrangler→URL round-trip is author-run.
- **Token never logged:** `CLOUDFLARE_API_TOKEN` is passed via the guest exec environment (the `exec` config's `environment`), never on the argv and never streamed to `LogCenter`.
- **Streaming preserved:** build + wrangler output must still reach `LogCenter` line-by-line (the deploy drawer) under sources `"deploy:<siteID>:build"` and `"deploy:<siteID>"`, exactly as the host path does today.
- **Commit trailer:** end every commit with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

**`AnglesiteCore` (CI-tested):**
- Modify `Sources/AnglesiteCore/LocalContainerControl.swift` — add `ContainerExecResult` + `exec(...)` to the protocol.
- Create `Sources/AnglesiteCore/DeployExecutor.swift` — the `DeployExecutor` protocol + `HostDeployExecutor` (extracts today's `ProcessSupervisor`/`CommandResolver` behavior) + `ContainerDeployExecutor`.
- Modify `Sources/AnglesiteCore/DeployCommand.swift` — drive steps through an injected `DeployExecutor`; keep the host executor as the default so behavior is unchanged when no container is supplied.
- Modify `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift` — implement `exec`.

**`AnglesiteContainer` (app-linked, NOT CI-compiled):**
- Modify `Sources/AnglesiteContainer/ContainerizationControl.swift` — implement the real `exec` (captured stdout/stderr + streaming + exit code + cwd `/workspace/site` + env).

**App target:**
- Modify `Sources/AnglesiteApp/DeployModel.swift` — accept an optional `(any LocalContainerControl)?` + siteID, and build a `ContainerDeployExecutor` when present.
- Modify `Sources/AnglesiteApp/SiteWindow.swift` — pass the open site's `LocalContainerControl` (from `preview.runtime`, when it's a container) into the deploy path.
- Modify `Sources/AnglesiteApp/PreviewModel.swift` and `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift` — expose the underlying `LocalContainerControl` (+ active siteID) so the deploy path can reach the same container.

**Tests:**
- Create `Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift`.
- Extend `Tests/AnglesiteCoreTests/DeployCommandTests.swift` for the executor seam.

---

## Tasks

### Task 1: `exec` on the `LocalContainerControl` seam + fake

**Files:** Modify `Sources/AnglesiteCore/LocalContainerControl.swift`; Modify `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift`.

**Interfaces:**
- Produces: `struct ContainerExecResult: Sendable, Equatable { let exitCode: Int32; let stdout: String; let stderr: String }`
- Produces (added to `LocalContainerControl`): `func exec(siteID: String, argv: [String], environment: [String: String], workingDirectory: String, onOutput: @Sendable (String) -> Void) async throws -> ContainerExecResult`

- [ ] **Step 1: Write the failing test** in `FakeLocalContainerControl.swift`'s test or a small new test — assert the fake records the exec call and returns its canned result, and that `onOutput` is invoked per stdout line.
- [ ] **Step 2: Add the type + protocol method.** `ContainerExecResult` and the `exec` signature on `LocalContainerControl`. (No `Containerization` types cross the seam — `argv`/`environment`/`String` only.)
- [ ] **Step 3: Implement in `FakeLocalContainerControl`:** store `private(set) var execCalls: [(siteID: String, argv: [String], env: [String: String])]`; an injectable `execResult: ContainerExecResult` and optional `execStdoutLines: [String]` that `onOutput` replays; return `execResult`.
- [ ] **Step 4: Run** the test — green. `swift test --filter FakeLocalContainerControl` (or the suite using it).
- [ ] **Step 5: Commit** (`feat(#70): exec seam on LocalContainerControl + fake`).

### Task 2: `DeployExecutor` abstraction + `HostDeployExecutor`

**Files:** Create `Sources/AnglesiteCore/DeployExecutor.swift`.

**Interfaces:**
- Produces: `protocol DeployExecutor: Sendable { func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult }` where `enum DeployStep { case build, preflight, wrangler }` and `struct DeployStepResult: Sendable, Equatable { let exitCode: Int32?; let output: String }` (output captured for URL/scan parsing; also streamed to `LogCenter` by the executor).
- Produces: `struct HostDeployExecutor: DeployExecutor` — wraps `ProcessSupervisor` + the existing `CommandResolver` logic (resolve bundled node/npm/wrangler, `supervisor.launch`, drain to `LogCenter` under `source`). This is a refactor-extract of today's `DeployCommand.runBuild`/wrangler-launch code; behavior must be identical.

- [ ] **Step 1: Write the failing test** — a `HostDeployExecutor` run of a `.build` step against a `/bin/sh -c` fixture returns the right exit code + captured output and streams to a `LogCenter` (mirror `DeployCommandTests`' `shFixture`).
- [ ] **Step 2: Define the protocol + types.**
- [ ] **Step 3: Implement `HostDeployExecutor`** by moving the host spawn/stream logic out of `DeployCommand` (node/npm/wrangler resolution + `supervisor.launch` + `LogCenter` drain + `waitForExit`).
- [ ] **Step 4: Run** the test — green.
- [ ] **Step 5: Commit** (`feat(#70): DeployExecutor seam + HostDeployExecutor (extracted)`).

### Task 3: `ContainerDeployExecutor` (routes steps through the guest)

**Files:** Create the type in `Sources/AnglesiteCore/DeployExecutor.swift`; Create `Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift`.

**Interfaces:**
- Consumes: `LocalContainerControl.exec` (Task 1), `LogCenter`.
- Produces: `struct ContainerDeployExecutor: DeployExecutor` with `init(control: any LocalContainerControl, siteID: String, logCenter: LogCenter)`. For each `DeployStep` it builds the in-guest argv (working dir `/workspace/site`):
  - `.build` → `["npm", "run", "build"]`
  - `.preflight` → `["npx", "tsx", "scripts/pre-deploy-check.ts", "--json"]`
  - `.wrangler` → `["npx", "wrangler", "deploy"]`
  It calls `control.exec(siteID:argv:environment:workingDirectory:"/workspace/site", onOutput:)`, streaming each line to `LogCenter` under `source`, and returns `DeployStepResult(exitCode:, output: result.stdout)`. The `environment` it forwards includes `CLOUDFLARE_API_TOKEN` for `.wrangler` (passed in, never logged).

- [ ] **Step 1: Write failing tests** with a `FakeLocalContainerControl`:
  - `.wrangler` execs `["npx","wrangler","deploy"]` at `/workspace/site` with `CLOUDFLARE_API_TOKEN` in the env (assert via `execCalls`), and the fake's stdout lines reach `LogCenter`.
  - a non-zero `execResult.exitCode` surfaces in `DeployStepResult.exitCode`.
  - `.preflight` execs the `tsx scripts/pre-deploy-check.ts --json` argv.
- [ ] **Step 2: Implement** `ContainerDeployExecutor`.
- [ ] **Step 3: Run** `swift test --filter ContainerDeployExecutorTests` — green.
- [ ] **Step 4: Commit** (`feat(#70): ContainerDeployExecutor — build/scan/wrangler in-guest`).

### Task 4: Drive `DeployCommand` through the executor

**Files:** Modify `Sources/AnglesiteCore/DeployCommand.swift`; extend `Tests/AnglesiteCoreTests/DeployCommandTests.swift`.

**Interfaces:**
- Consumes: `DeployExecutor` (Task 2/3), the existing `TokenSource`/`PreflightChecker` parsing of `DeployStepResult.output`.
- Produces: `DeployCommand.init(..., executor: any DeployExecutor = HostDeployExecutor())` — the `run`/`deploy` flow calls `executor.run(step: .build/.preflight/.wrangler, …)` for each step, parses `extractDeployedURL` from the wrangler step's `output`, parses the scan JSON from the preflight step's `output`. Token still gated first; result enum (`succeeded`/`blocked`/`failed`) unchanged.

- [ ] **Step 1: Write the failing test** — `DeployCommand` with a fake `DeployExecutor` that returns canned step outputs drives the full flow: build→preflight→wrangler→`succeeded(url:)`; a blocked preflight short-circuits; a non-zero wrangler → `.failed`. (Replaces the `CommandResolver`-fixture tests with executor-fixture tests; keep one host-executor integration test for parity.)
- [ ] **Step 2: Refactor `DeployCommand`** to use the injected executor; the default `HostDeployExecutor` keeps host behavior identical.
- [ ] **Step 3: Run** `swift test --filter DeployCommand` — green; confirm the host path still behaves as before.
- [ ] **Step 4: Commit** (`feat(#70): DeployCommand runs steps through DeployExecutor`).

### Task 5: Expose the container control + host-vs-container selection

**Files:** Modify `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift` (expose `control` + `activeSiteID`); `Sources/AnglesiteApp/PreviewModel.swift` (surface the container control when the runtime is a container); `Sources/AnglesiteApp/DeployModel.swift` (accept the control + select executor); `Sources/AnglesiteApp/SiteWindow.swift` (thread it in).

**Interfaces:**
- Produces: `LocalContainerSiteRuntime.containerControl: (any LocalContainerControl)?` + `activeSiteID` (nil unless started).
- Produces: `PreviewModel.activeContainerControl: (siteID: String, control: any LocalContainerControl)?` (nil for the host runtime).
- Produces: `DeployModel.deploy(siteID:siteDirectory:containerControl:)` — when `containerControl != nil`, construct the `DeployCommand` with a `ContainerDeployExecutor`; else the default `HostDeployExecutor`.

- [ ] **Step 1: Write the failing test** — a `DeployModel`-level (or `DeployCommand`-construction) test asserting that when a container control is supplied the deploy uses the container executor (e.g. via a spy), and when absent it uses the host executor. (App-target wiring like `SiteWindow` is verified by xcodebuild, not unit tests.)
- [ ] **Step 2: Expose `control`/`activeSiteID`** on `LocalContainerSiteRuntime`; surface via `PreviewModel`.
- [ ] **Step 3: Update `DeployModel`** to pick the executor; update `SiteWindow.loadAndStart()`/the deploy button (≈`SiteWindow.swift:336`) to pass `preview.activeContainerControl`.
- [ ] **Step 4: Verify** `swift test --filter Deploy`; `xcodegen generate && xcodebuild -scheme Anglesite -configuration Debug build CODE_SIGNING_ALLOWED=NO` and `-scheme AnglesiteMAS` — both BUILD SUCCEEDED.
- [ ] **Step 5: Commit** (`feat(#70): select in-container deploy when the site runs in a container`).

### Task 6: Real `ContainerizationControl.exec` (AnglesiteContainer — NOT CI)

**Files:** Modify `Sources/AnglesiteContainer/ContainerizationControl.swift`.

**Interfaces:** implements `LocalContainerControl.exec` against the live `LinuxContainer` held in `LiveContainers[siteID]`.

- [ ] **Step 1: Implement `exec`** — look up the `LinuxContainer` for `siteID` in `LiveContainers` (add a public accessor on the actor); `container.exec(id) { config in config.arguments = argv; config.environment = environment; config.workingDirectory = workingDirectory }`; `start()`; drain stdout/stderr `FileHandle`s line-by-line, calling `onOutput` and accumulating into `stdout`/`stderr` strings; `wait()` for the exit code; `delete()`. Mirror the `runToCompletion` lifecycle but capture+stream the output (confirm the real 0.34 `LinuxProcess` stdout/stderr handle API — adapt names as needed; `exec` already used at `:264`/`:283`).
- [ ] **Step 2: Verify it compiles** — `swift build --target AnglesiteContainer 2>&1 | tail -3` → Build complete. CI boundary intact: `ANGLESITE_SKIP_CONTAINER=1 swift build -c debug` excludes it.
- [ ] **Step 3: Commit** (`feat(#70): ContainerizationControl.exec — captured+streamed guest exec`).

### Task 7: Author e2e verification (entitled machine — gated)

**Files:** none (manual verification + a #69 comment).

- [ ] On an entitled Apple-Silicon build with a provisioned container: open a `.anglesite` site (container runtime selected), trigger Deploy, and confirm: the build, the pre-deploy scan, and `wrangler deploy` all run **in the guest** (no host Node spawn); output streams to the deploy drawer; the deployed URL is parsed; a blocked pre-deploy scan still short-circuits; an invalid token still fails before wrangler.
- [ ] Confirm the host path still deploys correctly on a non-container build (no regression).
- [ ] Record results in a #70 comment.

---

## Self-Review

**Coverage:** the exec seam (T1) + executor abstraction (T2/T3) + DeployCommand refactor (T4) + selection (T5) + real impl (T6) + author e2e (T7) cover the five "must be built" items from the design inventory (streamed exec, in-guest step argv, host-vs-container selection, token-via-exec-env, fake exec). ✅

**Additive guarantee:** `HostDeployExecutor` is the default and a refactor-extract (behavior-identical), so non-container/MAS deploy is unchanged — the host embedded-Node path is untouched. This plan is a prerequisite for #70 A1's *removal* step, not the removal itself. ✅

**CI boundary:** only `ContainerizationControl.exec` (T6) is non-CI; everything else compiles and is fake-tested on CI. ✅

**Token safety:** the token flows only through the guest exec `environment` (T3/T6), never argv/logs. ✅

**Placeholder scan:** in-guest argv, the seam signature, and the executor types are concrete; the only deferred specifics are the real 0.34 `LinuxProcess` stdout/stderr handle names (T6, flagged to confirm against the package — same posture as #69 Task 7). ✅

**Type consistency:** `ContainerExecResult` (T1) → consumed by `ContainerDeployExecutor` (T3) and produced by `ContainerizationControl.exec` (T6); `DeployStepResult`/`DeployStep` (T2) consistent across T2–T4; `LocalContainerSiteRuntime.containerControl` (T5) matches the protocol type. ✅

---

## Execution Handoff

Tasks 1–5 are CI-testable and can run now (subagent-driven-development recommended). Task 6 builds locally (Apple-Silicon + Xcode 27) but never on CI. Task 7 is author-only on an entitled machine. The whole feature is **inert until the container runtime is the selected path for a site** — so a full live deploy depends on #69 Task 10. When executing, run Tasks 1–6 to land the capability, then schedule Task 7 with the #69 boot verification.
