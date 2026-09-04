# Worker Provisioning Deploy Spine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every `wrangler` call `SocialWorkerProvisionCommand` makes — not just the final deploy — through the same `DeployTarget`/`DeployExecutor` spine as an ordinary deploy, so `authorize`/`PreDeployCheck` run exactly once before any of it; give `generateWranglerToml` a typed return; delete the TOML-regex extractors.

**Architecture:** Three independently-shippable phases, per [`docs/superpowers/specs/2026-09-04-worker-provisioning-deploy-spine-design.md`](../specs/2026-09-04-worker-provisioning-deploy-spine-design.md): (1) a `WranglerInvocation` helper plus a new `DeployStep.wranglerSubcommand` case so arbitrary wrangler subcommands run through `DeployExecutor`; (2) a typed `WranglerConfiguration` return from `generateWranglerToml`, split into section builders, with the TOML-regex extractors deleted; (3) a new `SocialWorkerProvisionTarget` actor conforming to `DeployTarget`, whose `publish(context:)` does resource creation → secrets → migrations → delegates to `CloudflareDeployTarget.publish` for the final deploy, replacing `SocialWorkerProvisionCommand`'s own `runWrangler`/`deployer` plumbing.

**Tech Stack:** Swift 6.4, Swift Testing (`@Test`/`#expect`, not XCTest), `AnglesiteCore` SwiftPM target.

## Global Constraints

- Swift 6.4 / Xcode 27 toolchain; every test uses Swift Testing, never XCTest.
- No new third-party dependencies (Apple frameworks only) — nothing in this plan needs one.
- Run local full suites through `scripts/swift-test.sh` (not bare `swift test`) — it holds the machine-scoped lock. `--filter` runs for a single new/changed test file don't need it.
- Conventional commits, subject ≤72 chars, reference the issue number.
- This plan ships as **three separate PRs** (Phase 1, 2, 3 below), each independently mergeable and each leaving `main` green. Only the **last** PR's body says `Closes #1821`; Phase 1 and Phase 2 PRs must say "Part of #1821 — does not close it" per `CONTRIBUTING.md` ▸ "Multi-PR tracking issues," and their commits must NOT use `fix(#1821):`/`close(#1821):` as the commit type (GitHub's closing-keyword linker scans every commit on `main`, not just the PR body — a `fix(#1821):` commit auto-closes the issue on merge even from an interim PR). Use `feat(#1821):`/`refactor(#1821):`/`test(#1821):` for interim-PR commits instead.
- Every PR body is built from `.github/PULL_REQUEST_TEMPLATE.md`'s actual headings (Summary, Paired PR check, Test plan) — never a generic Summary/Test-plan shape.
- Behavior-preserving unless a task explicitly calls out an intended behavior change. The one intended behavior change in this whole plan: `checkDomainConfigDrift` now runs before Worker resource creation begins (Task 12), not only before the final deploy — call this out explicitly in the Phase 3 PR body.
- `WorkerCompositionTests.swift`'s existing 94 assertions on generated TOML content must keep passing byte-for-byte through Phase 2's section-builder split (only the *return type* changes, never the TOML text) unless a task says otherwise.

---

## Phase 1 (PR 1): `WranglerInvocation` + `DeployStep.wranglerSubcommand`

### Task 1: `WranglerInvocation` helper

**Files:**
- Create: `Sources/AnglesiteCore/WranglerInvocation.swift`
- Test: `Tests/AnglesiteCoreTests/WranglerInvocationTests.swift`

**Interfaces:**
- Produces: `WranglerInvocation.argv(subcommand: [String]) -> [String]`, `WranglerInvocation.EnvScope` (`.tokenOnly`, `.tokenAndAccount`), `WranglerInvocation.guestEnvironment(from: [String: String], scope: EnvScope) -> [String: String]`, `WranglerInvocation.exec(control: any LocalContainerControl, siteID: String, argv: [String], environment: [String: String], workingDirectory: String = "/workspace/site", logCenter: LogCenter, source: String) async throws -> ContainerExecResult`. Every later task in this phase consumes these four.

This is the one place that builds `["npx", "wrangler"] + subcommand`, resolves which secrets a wrangler call may see in-guest, and runs the `AsyncStream`-drain-to-`LogCenter` exec loop that today is duplicated in `ContainerCommandRunner.run`/`.runSecret` and `ContainerDeployExecutor.run`/`.runBuildWithClaimManifest`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/WranglerInvocationTests.swift
import Foundation
import Testing
@testable import AnglesiteCore
import AnglesiteTestSupport

@Suite("WranglerInvocation")
struct WranglerInvocationTests {
    @Test("argv prefixes npx wrangler")
    func argvPrefixesNpxWrangler() {
        #expect(WranglerInvocation.argv(subcommand: ["d1", "create", "site-social"])
            == ["npx", "wrangler", "d1", "create", "site-social"])
    }

    @Test("tokenOnly scope keeps only CLOUDFLARE_API_TOKEN")
    func tokenOnlyScope() {
        let env = WranglerInvocation.guestEnvironment(
            from: ["CLOUDFLARE_API_TOKEN": "tok", "CLOUDFLARE_ACCOUNT_ID": "acct", "PATH": "/bin"],
            scope: .tokenOnly)
        #expect(env == ["CLOUDFLARE_API_TOKEN": "tok"])
    }

    @Test("tokenAndAccount scope keeps both Cloudflare keys")
    func tokenAndAccountScope() {
        let env = WranglerInvocation.guestEnvironment(
            from: ["CLOUDFLARE_API_TOKEN": "tok", "CLOUDFLARE_ACCOUNT_ID": "acct", "PATH": "/bin"],
            scope: .tokenAndAccount)
        #expect(env == ["CLOUDFLARE_API_TOKEN": "tok", "CLOUDFLARE_ACCOUNT_ID": "acct"])
    }

    @Test("exec streams output to LogCenter and returns the result")
    func execStreamsAndReturns() async throws {
        let control = FakeLocalContainerControl()
        control.execResult = ContainerExecResult(exitCode: 0, stdout: "created\nid=abc123", stderr: "")
        control.execStdoutLines = ["created", "id=abc123"]
        let logCenter = LogCenter()
        let result = try await WranglerInvocation.exec(
            control: control, siteID: "site-1",
            argv: ["npx", "wrangler", "d1", "create", "x"],
            environment: ["CLOUDFLARE_API_TOKEN": "tok"],
            logCenter: logCenter, source: "worker-provision:site-1")
        #expect(result.exitCode == 0)
        #expect(result.stdout == "created\nid=abc123")
        let snapshot = await logCenter.snapshot()
        #expect(snapshot.filter { $0.source == "worker-provision:site-1" }.map(\.text) == ["created", "id=abc123"])
        #expect(control.execCalls.count == 1)
        #expect(control.execCalls[0].argv == ["npx", "wrangler", "d1", "create", "x"])
    }

    @Test("exec drains buffered output before rethrowing on failure")
    func execDrainsBeforeRethrowing() async throws {
        let control = FakeLocalContainerControl()
        control.execStdoutLines = ["partial output"]
        control.execError = LocalContainerError.bootFailed
        let logCenter = LogCenter()
        await #expect(throws: LocalContainerError.self) {
            _ = try await WranglerInvocation.exec(
                control: control, siteID: "site-1", argv: ["npx", "wrangler", "deploy"],
                environment: [:], logCenter: logCenter, source: "deploy:site-1")
        }
    }
}
```

Check `Tests/AnglesiteTestSupport/FakeLocalContainerControl.swift` first for the exact property names this fake exposes for scripting `execResult`/`execStdoutLines`/`execError`/`execCalls` (its `exec` implementation was confirmed to append to `execCalls` and replay `execStdoutLines` via `onOutput`, per the file read while planning this task) — adjust the test above to match its actual configuration surface (add a settable `execError` property to the fake in this same step if it doesn't already have one for throwing).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter WranglerInvocationTests`
Expected: FAIL — `WranglerInvocation` does not exist yet (compile error).

- [ ] **Step 3: Implement `WranglerInvocation`**

```swift
// Sources/AnglesiteCore/WranglerInvocation.swift
import Foundation

/// The one place that builds `npx wrangler` argv, resolves which secrets a wrangler call may see
/// in-guest, and runs the exec-and-drain-to-`LogCenter` loop shared by every `wrangler` call site
/// (`ContainerCommandRunner`, `ContainerDeployExecutor`) — see #1821.
public enum WranglerInvocation {
    /// Which Cloudflare secrets a wrangler call may see in-guest. `.tokenOnly` matches
    /// `SocialWorkerProvisionCommand`'s resource-creation/secret-push/migration calls (today's
    /// `ContainerCommandRunner.guestEnvAllowlist`); `.tokenAndAccount` matches the fixed
    /// `.wrangler`/`.bundleUpload` deploy steps (today's `ContainerDeployExecutor
    /// .guestEnvAllowlist`), which also need `CLOUDFLARE_ACCOUNT_ID` (#1853).
    public enum EnvScope: Sendable {
        case tokenOnly
        case tokenAndAccount
    }

    /// `["npx", "wrangler"] + subcommand` — the argv every plain (non-shell-wrapped) wrangler
    /// invocation shares.
    public static func argv(subcommand: [String]) -> [String] {
        ["npx", "wrangler"] + subcommand
    }

    /// Filters `environment` down to the keys `scope` allows across the host→guest boundary.
    public static func guestEnvironment(from environment: [String: String], scope: EnvScope) -> [String: String] {
        let allowlist: Set<String> = {
            switch scope {
            case .tokenOnly: return ["CLOUDFLARE_API_TOKEN"]
            case .tokenAndAccount: return ["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID"]
            }
        }()
        return environment.filter { allowlist.contains($0.key) }
    }

    /// Runs `argv` in `siteID`'s container via `control.exec`, streaming stdout/stderr into
    /// `logCenter` under `source` line-by-line as it arrives, draining fully on every exit path
    /// (success or thrown error) before returning/rethrowing — the same drain discipline
    /// `ContainerDeployExecutor.run` already documents (never leak a buffered line, never leave
    /// the drain task still running when this function returns).
    public static func exec(
        control: any LocalContainerControl,
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String = "/workspace/site",
        logCenter: LogCenter,
        source: String
    ) async throws -> ContainerExecResult {
        let (lines, continuation) = AsyncStream<(String, LogCenter.Stream)>.makeStream(bufferingPolicy: .unbounded)
        let drain = Task.detached(priority: .utility) {
            for await (line, stream) in lines {
                await logCenter.append(source: source, stream: stream, text: line)
            }
        }
        do {
            let result = try await control.exec(
                siteID: siteID,
                argv: argv,
                environment: environment,
                workingDirectory: workingDirectory,
                onOutput: { line, stream in continuation.yield((line, stream)) }
            )
            continuation.finish()
            _ = await drain.value
            return result
        } catch {
            continuation.finish()
            _ = await drain.value
            throw error
        }
    }
}
```

If `Tests/AnglesiteTestSupport/FakeLocalContainerControl.swift` doesn't yet have a way to make `exec` throw, add a settable `public var execError: (any Error)?` to it and have `exec` throw it first if set, before appending to `execCalls`/replaying output — needed by this task's "drains before rethrowing" test and reusable by later tasks/tests in this plan.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter WranglerInvocationTests`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WranglerInvocation.swift Tests/AnglesiteCoreTests/WranglerInvocationTests.swift Tests/AnglesiteTestSupport/FakeLocalContainerControl.swift
git commit -m "feat(#1821): add WranglerInvocation exec/argv/env helper"
```

---

### Task 2: Route `ContainerCommandRunner` through `WranglerInvocation`

**Files:**
- Modify: `Sources/AnglesiteCore/ContainerCommandRunner.swift`

**Interfaces:**
- Consumes: `WranglerInvocation.argv(subcommand:)`, `.guestEnvironment(from:scope:)`, `.exec(control:siteID:argv:environment:logCenter:source:)` from Task 1.
- Produces: `ContainerCommandRunner.runner`/`.secretRunner` unchanged in type and external behavior — this task is a pure internal refactor, no new public surface.

- [ ] **Step 1: Replace `run`'s body**

```swift
private func run(
    siteDirectory: URL,
    arguments: [String],
    environment: [String: String],
    source: String
) async throws -> ProcessSupervisor.RunResult {
    let argv = WranglerInvocation.argv(subcommand: arguments)
    let guestEnvironment = WranglerInvocation.guestEnvironment(from: environment, scope: .tokenOnly)
    let result = try await WranglerInvocation.exec(
        control: control, siteID: siteID, argv: argv, environment: guestEnvironment,
        logCenter: logCenter, source: source)
    return ProcessSupervisor.RunResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
}
```

Delete the now-unused `Self.guestEnvAllowlist` static property and the hand-rolled `AsyncStream`/`Task.detached` block this replaces.

- [ ] **Step 2: Replace `runSecret`'s exec block**

Keep `runSecret`'s own argv (the `sh -c "printf ... | npx wrangler secret put ..."` script) and its two extra env keys (`WRANGLER_SECRET_NAME`/`WRANGLER_SECRET_VALUE`) exactly as they are — only replace the drain-loop/`control.exec` block:

```swift
private func runSecret(
    siteDirectory: URL,
    name: String,
    value: String,
    environment: [String: String],
    source: String
) async throws -> ProcessSupervisor.RunResult {
    var guestEnvironment = WranglerInvocation.guestEnvironment(from: environment, scope: .tokenOnly)
    guestEnvironment["WRANGLER_SECRET_NAME"] = name
    guestEnvironment["WRANGLER_SECRET_VALUE"] = value
    let argv = [
        "sh", "-c",
        "printf '%s' \"$WRANGLER_SECRET_VALUE\" | npx wrangler secret put \"$WRANGLER_SECRET_NAME\"",
    ]
    let result = try await WranglerInvocation.exec(
        control: control, siteID: siteID, argv: argv, environment: guestEnvironment,
        logCenter: logCenter, source: source)
    return ProcessSupervisor.RunResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
}
```

- [ ] **Step 3: Run existing tests to confirm no regression**

There's no dedicated `ContainerCommandRunnerTests.swift` per the design doc's investigation (that file covers `ContainerDeployExecutor`, not `ContainerCommandRunner`) — confirm with `grep -rl "ContainerCommandRunner" Tests/`. If a test file exercising `ContainerCommandRunner.runner`/`.secretRunner` directly is found, run it now:

Run: `swift test --package-path . --filter ContainerCommandRunner`
Expected: PASS, unchanged from before this task (behavior-preserving refactor — same argv, same env filtering, same output shape).

If no such test file exists yet, this task adds a minimal one (see Task 2a below) rather than shipping the refactor unverified.

- [ ] **Step 3a: Add `ContainerCommandRunnerTests.swift` if it doesn't already exist**

```swift
// Tests/AnglesiteCoreTests/ContainerCommandRunnerTests.swift
import Foundation
import Testing
@testable import AnglesiteCore
import AnglesiteTestSupport

@Suite("ContainerCommandRunner")
struct ContainerCommandRunnerTests {
    @Test("runner prefixes npx wrangler and forwards only the token")
    func runnerBuildsWranglerArgv() async throws {
        let control = FakeLocalContainerControl()
        control.execResult = ContainerExecResult(exitCode: 0, stdout: "ok", stderr: "")
        let runner = ContainerCommandRunner(control: control, siteID: "site-1", logCenter: LogCenter())
        let result = try await runner.runner(
            URL(fileURLWithPath: "/tmp/site"), ["d1", "create", "x"],
            ["CLOUDFLARE_API_TOKEN": "tok", "CLOUDFLARE_ACCOUNT_ID": "acct"], "worker-provision:site-1")
        #expect(result.exitCode == 0)
        #expect(control.execCalls.last?.argv == ["npx", "wrangler", "d1", "create", "x"])
        #expect(control.execCalls.last?.env == ["CLOUDFLARE_API_TOKEN": "tok"])
    }

    @Test("secretRunner pipes the value through stdin, never through argv")
    func secretRunnerPipesValue() async throws {
        let control = FakeLocalContainerControl()
        control.execResult = ContainerExecResult(exitCode: 0, stdout: "Success!", stderr: "")
        let runner = ContainerCommandRunner(control: control, siteID: "site-1", logCenter: LogCenter())
        let result = try await runner.secretRunner(
            URL(fileURLWithPath: "/tmp/site"), "AP_PRIVATE_KEY", "super-secret-pem",
            ["CLOUDFLARE_API_TOKEN": "tok"], "worker-provision:site-1")
        #expect(result.exitCode == 0)
        let call = try #require(control.execCalls.last)
        #expect(!call.argv.joined().contains("super-secret-pem"))
        #expect(call.env["WRANGLER_SECRET_VALUE"] == "super-secret-pem")
        #expect(call.env["WRANGLER_SECRET_NAME"] == "AP_PRIVATE_KEY")
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/ContainerCommandRunner.swift Tests/AnglesiteCoreTests/ContainerCommandRunnerTests.swift
git commit -m "refactor(#1821): route ContainerCommandRunner through WranglerInvocation"
```

---

### Task 3: Add `DeployStep.wranglerSubcommand(args:)`

**Files:**
- Modify: `Sources/AnglesiteCore/DeployExecutor.swift`
- Modify (exhaustive-switch fakes that must add the new case): `Tests/AnglesiteCoreTests/DeployCommandTests.swift` (`FakeExecutor.key(_:)`), `Tests/AnglesiteAppTests/DeployModelTests.swift` (`GatedDeployExecutor`), `Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift` (`BlockingPreflightExecutor`)

**Interfaces:**
- Produces: `DeployStep.wranglerSubcommand(args: [String])` — a new case. Consumed by `SocialWorkerProvisionTarget` in Phase 3 (Task 13).

- [ ] **Step 1: Add the case and update every exhaustive switch over `DeployStep`**

In `DeployExecutor.swift`, add to the enum:

```swift
public enum DeployStep: Sendable {
    case build
    case preflight
    case wrangler
    case bundleUpload
    case githubPagesPublish
    /// An arbitrary `wrangler <args>` subcommand outside the fixed pipeline — `d1 create`,
    /// `kv namespace create`, `queues create`, `d1 migrations apply`, etc. Used by
    /// `SocialWorkerProvisionTarget`'s resource-creation sequence (#1821) so those calls run
    /// through the same executor abstraction as `.wrangler`/`.bundleUpload`, instead of a
    /// separately-injected `CommandRunner` seam.
    case wranglerSubcommand(args: [String])
}
```

Update `ContainerDeployExecutor.guestArgv(for:siteDirectory:)`'s switch:

```swift
case .wranglerSubcommand(let args):
    return WranglerInvocation.argv(subcommand: args)
```

Update `ContainerDeployExecutor.guestEnvAllowlist(for:)`'s switch — `.wranglerSubcommand` gets `.tokenOnly`'s allowlist (matching today's `ContainerCommandRunner.guestEnvAllowlist`, which is token-only, unlike `.wrangler`'s token+account):

```swift
private static func guestEnvAllowlist(for step: DeployStep) -> Set<String> {
    switch step {
    case .build, .preflight:
        return []
    case .wrangler, .bundleUpload:
        return ["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID"]
    case .githubPagesPublish:
        return ["GITHUB_PAGES_TOKEN"]
    case .wranglerSubcommand:
        return ["CLOUDFLARE_API_TOKEN"]
    }
}
```

Update `HostDeployExecutor.defaultResolver`'s switch:

```swift
case .wranglerSubcommand:
    return { _ in .unavailable(reason: HostNodeRetirement.reason("social worker provisioning")) }
```

In `Tests/AnglesiteCoreTests/DeployCommandTests.swift`, add a case to `FakeExecutor.key(_:)`:

```swift
case .wranglerSubcommand(let args): return "wranglerSubcommand:\(args.joined(separator: " "))"
```

(Keyed by the joined args, not a fixed string, so a test can script different responses for different subcommands via repeated `.set(.wranglerSubcommand(args: ["d1", "create", "x"]), exitCode:output:)` calls.)

In `Tests/AnglesiteAppTests/DeployModelTests.swift`'s `GatedDeployExecutor` and `Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift`'s `BlockingPreflightExecutor`, add a `case .wranglerSubcommand:` arm that falls through to whatever that fake's default/no-op behavior is for steps it doesn't specifically gate (read each fake's existing `case .bundleUpload:`/`case .githubPagesPublish:` arm first and mirror its shape — both are already "not the step this fake cares about" arms).

- [ ] **Step 2: Verify it compiles and existing tests still pass**

Run: `scripts/swift-test.sh --filter DeployCommandTests`
Run: `scripts/swift-test.sh --filter DeployModelTests`
Run: `scripts/swift-test.sh --filter DeployCommandProgressTests`
Expected: PASS — this task adds a case but nothing yet constructs it in production code, so no behavior changes.

- [ ] **Step 3: Add a `wranglerSubcommand` argv/env-allowlist test to `ContainerDeployExecutorTests.swift`**

```swift
@Test("wranglerSubcommand argv and env allowlist")
func wranglerSubcommandArgvAndEnv() {
    let argv = ContainerDeployExecutorTestHook.guestArgv(
        for: .wranglerSubcommand(args: ["d1", "create", "site-social"]),
        siteDirectory: URL(fileURLWithPath: "/tmp/site"))
    #expect(argv == ["npx", "wrangler", "d1", "create", "site-social"])
}
```

Run: `swift test --package-path . --filter ContainerDeployExecutorTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/DeployExecutor.swift Tests/AnglesiteCoreTests/DeployCommandTests.swift Tests/AnglesiteAppTests/DeployModelTests.swift Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift
git commit -m "feat(#1821): add DeployStep.wranglerSubcommand case"
```

---

### Task 4: Route `ContainerDeployExecutor`'s guest exec through `WranglerInvocation.exec`

**Files:**
- Modify: `Sources/AnglesiteCore/DeployExecutor.swift`

**Interfaces:**
- Consumes: `WranglerInvocation.exec(...)` from Task 1.
- No public interface change — internal dedup only.

This collapses `ContainerDeployExecutor.run`'s and `.runBuildWithClaimManifest`'s own `AsyncStream`/`Task.detached` drain blocks into calls to `WranglerInvocation.exec`, and gives `.wranglerSubcommand` the stdout-or-stderr fallback the old `SocialWorkerProvisionCommand.runWrangler` relied on (every other step keeps stdout-only capture, unchanged).

- [ ] **Step 1: Replace `run`'s exec block**

Keep the pre-existing `step == .wrangler` resync block (lines ~164-184) untouched — it runs before the block being replaced. Replace the drain-loop-and-`control.exec` block (`let (lines, continuation) = ...` through `return DeployStepResult(exitCode: result.exitCode, output: result.stdout)`) with:

```swift
let argv = Self.guestArgv(for: step, siteDirectory: siteDirectory)
let result: ContainerExecResult
do {
    result = try await WranglerInvocation.exec(
        control: control, siteID: siteID, argv: argv,
        environment: Self.guestEnvironment(from: environment, step: step),
        logCenter: logCenter, source: source)
} catch is CancellationError {
    return DeployStepResult(exitCode: nil, output: "")
} catch let error as LocalContainerError {
    if case .bootFailed = error {
        return DeployStepResult(
            exitCode: nil,
            output: "Container isn't running — open/start the site's preview first.")
    }
    return DeployStepResult(exitCode: nil, output: "couldn't exec in the container: \(error)")
} catch let error {
    return DeployStepResult(exitCode: nil, output: "couldn't exec in the container: \(error)")
}
// `.wranglerSubcommand` needs the same stdout-or-stderr fallback
// `SocialWorkerProvisionCommand.runWrangler` relied on before this refactor (a failed wrangler
// subcommand can write its error to stderr with empty stdout, e.g. a name-conflict on `d1
// create`) — every other step keeps stdout-only capture, its existing behavior.
if case .wranglerSubcommand = step {
    return DeployStepResult(exitCode: result.exitCode, output: result.stdout.isEmpty ? result.stderr : result.stdout)
}
return DeployStepResult(exitCode: result.exitCode, output: result.stdout)
```

Note `WranglerInvocation.exec` already drains fully on both the success and throw paths, so the explicit `continuation.finish()`/`await drain.value` calls that used to appear in each `catch` arm here are gone — they're now inside `WranglerInvocation.exec` itself.

- [ ] **Step 2: Replace `runBuildWithClaimManifest`'s exec block**

Same shape — replace its `AsyncStream`/`Task.detached`/`control.exec` block with a `WranglerInvocation.exec(...)` call, preserving its own `catch is CancellationError { return .cancelled }` / generic-catch-returns-`.completed(...)` structure exactly as today (only the exec-and-drain mechanics move into `WranglerInvocation`).

- [ ] **Step 3: Run the full `ContainerDeployExecutorTests.swift` suite**

Run: `swift test --package-path . --filter ContainerDeployExecutorTests`
Expected: PASS, unchanged — this is a pure internal refactor of the exec/drain mechanics, argv/env/resync/error-mapping behavior is identical to before.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/DeployExecutor.swift
git commit -m "refactor(#1821): route ContainerDeployExecutor guest exec through WranglerInvocation"
```

---

### Task 5: Phase 1 wrap-up — full verification and PR

- [ ] **Step 1: Full local suite**

Run: `scripts/swift-test.sh`
Expected: PASS, zero regressions.

- [ ] **Step 2: App build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: succeeds (this phase touches only `AnglesiteCore`, but the app target links it).

- [ ] **Step 3: Open the PR**

Title: `feat(#1821): unify wrangler exec through WranglerInvocation`. Body from `.github/PULL_REQUEST_TEMPLATE.md`'s headings, noting under Summary that this is Phase 1 of 3 for #1821 and does **not** close it. Reference the design doc.

---

## Phase 2 (PR 2): Typed TOML result, section builders, delete the TOML extractors

### Task 6: `WranglerConfiguration` typed return

**Files:**
- Modify: `Sources/AnglesiteCore/WorkerComposition.swift`
- Modify: `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift` (call-site updates only — `.toml` accessor)

**Interfaces:**
- Produces: `WorkerComposition.WranglerConfiguration { let toml: String; let resources: ProvisionedResources; let effectiveRoutes: [String] }`, and `generateWranglerToml(...) throws -> WranglerConfiguration` (was `-> String`). Consumed by Task 7 (section builders operate inside this same function) and by Task 8 (`persistConfig`'s call site).

- [ ] **Step 1: Write the failing test**

```swift
@Test("generateWranglerToml returns the computed run_worker_first route set")
func returnsEffectiveRoutes() throws {
    let config = try WorkerComposition.generateWranglerToml(
        siteName: "site", workers: [WorkerDescriptor.indieauth],
        routeClaims: [WorkerRouteClaim(path: "/token", match: .exact, methods: ["POST"], handler: "indieauth")])
    #expect(config.effectiveRoutes.contains("/token"))
    #expect(config.toml.contains("run_worker_first = [\"/token\"]"))
}

@Test("generateWranglerToml echoes the resources it was given")
func echoesResources() throws {
    let resources = WorkerComposition.ProvisionedResources(d1DatabaseID: "abc-123")
    let config = try WorkerComposition.generateWranglerToml(
        siteName: "site", workers: [WorkerDescriptor.indieauth], resources: resources)
    #expect(config.resources == resources)
}
```

(Adjust `WorkerDescriptor.indieauth`/fixture construction to match whatever fixture helpers `WorkerCompositionTests.swift` already uses — read the top of that file for the existing pattern before writing this.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter WorkerCompositionTests/returnsEffectiveRoutes`
Expected: FAIL — compile error, `generateWranglerToml` still returns `String`.

- [ ] **Step 3: Add `WranglerConfiguration` and change the return type**

```swift
/// The result of composing one site's `wrangler.toml`: the TOML text itself, the resources
/// (echoed back — already typed on the way in via `resources:`), and the route-pattern set the
/// generator computed for `[assets].run_worker_first` — previously discarded into the TOML
/// string with no way for a caller to read it back without re-parsing (#1821).
public struct WranglerConfiguration: Sendable, Equatable {
    public let toml: String
    public let resources: ProvisionedResources
    public let effectiveRoutes: [String]

    public init(toml: String, resources: ProvisionedResources, effectiveRoutes: [String]) {
        self.toml = toml
        self.resources = resources
        self.effectiveRoutes = effectiveRoutes
    }
}
```

Change `generateWranglerToml`'s return type from `String` to `WranglerConfiguration`. At the end of the function, where it currently does:

```swift
lines.append("")
return lines.joined(separator: "\n")
```

change to:

```swift
lines.append("")
return WranglerConfiguration(
    toml: lines.joined(separator: "\n"),
    resources: resources,
    effectiveRoutes: patterns.sorted())
```

`patterns` is the `Set<String>` already computed at the `[assets]` block (`var patterns = Set(WorkerRouteClaims.runWorkerFirstPatterns(effectiveClaims)); patterns.formUnion(experimentRoutes.map(\.path))`) — it's currently scoped inside the `if composesWorker { ... }` block, so hoist its declaration (as `var patterns: Set<String> = []`) to the top of the function, before that `if`, so it's still in scope at the return statement, and keep populating it exactly as today only inside the `if composesWorker` branch.

- [ ] **Step 4: Update every existing `WorkerCompositionTests.swift` call site**

Every existing test that does `let toml = try WorkerComposition.generateWranglerToml(...)` and then asserts `toml.contains(...)` needs `let toml = try WorkerComposition.generateWranglerToml(...).toml` instead (one-word suffix added at each call site — read through the file and apply this mechanically to all ~94 call sites; there is no other change needed since the TOML content itself is unchanged).

- [ ] **Step 5: Run the full `WorkerCompositionTests.swift` suite**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: PASS (all ~96 tests: 94 existing + 2 new from Step 1).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/WorkerComposition.swift Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
git commit -m "feat(#1821): generateWranglerToml returns typed WranglerConfiguration"
```

---

### Task 7: Split `generateWranglerToml` into section builders

**Files:**
- Modify: `Sources/AnglesiteCore/WorkerComposition.swift`

**Interfaces:**
- Internal only (`private static` helpers) — no change to `generateWranglerToml`'s own signature or `Task.6`'s `WranglerConfiguration`. `WorkerCompositionTests.swift` must keep passing unchanged (same `.toml` text).

This is a pure mechanical extraction — every line emitted must stay byte-for-byte identical. Extract these private static helpers (each returning `[String]`, appended to `lines` at the same point the inline code used to sit):

```swift
private static func d1Block(binding: String, siteName: String, migrationsDir: String? = nil, id: String?, projectRoot: String?) -> [String] {
    var block = ["", "[[d1_databases]]", "binding = \"\(binding)\"", "database_name = \"\(siteName)-social\""]
    if let migrationsDir {
        block.append("migrations_dir = \"\(rooted(migrationsDir, projectRoot: projectRoot))\"")
    }
    if let id, !id.isEmpty {
        block.append("database_id = \"\(id)\"")
    } else {
        block.append("database_id = \"\"  # filled by provisioning")
    }
    return block
}

private static func queueBlock(name: String, producerBinding: String) -> [String] {
    [
        "", "[[queues.producers]]", "queue = \"\(name)\"", "binding = \"\(producerBinding)\"",
        "", "[[queues.consumers]]", "queue = \"\(name)\"",
        "max_batch_size = 10", "max_batch_timeout = 30", "max_retries = 3",
    ]
}
```

Replace each of the six near-identical `[[d1_databases]]` blocks (generic `DB` at what's currently ~427-437, `EXPERIMENTS_DB` ~444-455, `AUTH_DB` ~459-470, `WEBMENTION_INBOX` ~475-485, `MICROPUB_DB` ~490-500, `WEBSUB_DB` ~522-532, `MICROSUB_DB` ~555-565 — seven total, not six; re-count against the current file before starting, since Task 6 may have shifted these lines slightly) with `lines.append(contentsOf: d1Block(binding: "DB", siteName: siteName, id: resources.d1DatabaseID, projectRoot: projectRoot))` (only `EXPERIMENTS_DB`/`AUTH_DB` pass `migrationsDir:`, the rest omit it — matching today's exact per-block shape). Replace the three producer/consumer queue pairs (webmention/websub/microsub) with `lines.append(contentsOf: queueBlock(name: queueName, producerBinding: "WEBMENTION_QUEUE"))` etc.

Leave every other block (KV namespaces, R2 buckets, Durable Objects, `[vars]`, secret-name comments, `[observability]`, the `[assets]`/route-pattern header) inline exactly as-is — the design doc calls these out as candidates too, but the D1/queue blocks are the only ones with enough repeated near-identical structure to justify extraction without adding indirection that makes the function harder to follow. Don't over-extract: a `varsBlock`/`observabilityBlock` split with no repeated structure to collapse just adds a function call for one call site, which is not worth it here.

- [ ] **Step 1: Extract the helpers and replace the seven D1 blocks + three queue-pairs**

(As described above — this is the implementation step; there's no separate "write a failing test" step because this task changes no observable behavior, only internal structure. The existing `WorkerCompositionTests.swift` suite from Task 6 is the regression test.)

- [ ] **Step 2: Run the full suite to confirm byte-for-byte output is unchanged**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: PASS, zero changes to any existing assertion.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteCore/WorkerComposition.swift
git commit -m "refactor(#1821): split generateWranglerToml into D1/queue section builders"
```

---

### Task 8: Update `persistConfig`'s call site for the typed return

**Files:**
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`

**Interfaces:**
- Consumes: `WranglerConfiguration.toml` from Task 6.

- [ ] **Step 1: Update `persistConfig`**

In `persistConfig` (currently ~664-742), change:

```swift
let toml = try WorkerComposition.generateWranglerToml(...)
try toml.write(to: ..., atomically: true, encoding: .utf8)
```

to:

```swift
let configuration = try WorkerComposition.generateWranglerToml(...)
try configuration.toml.write(to: ..., atomically: true, encoding: .utf8)
```

(Same argument list as today — only the local variable's type and the `.write` receiver change.)

- [ ] **Step 2: Run the provisioning test suite**

Run: `scripts/swift-test.sh --filter SocialWorkerProvisionCommandTests`
Expected: PASS, unchanged — `persistConfig`'s written TOML content is identical.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift
git commit -m "refactor(#1821): update persistConfig for typed WranglerConfiguration"
```

---

### Task 9: Delete the TOML-regex extractors and `readPersistedResources`

**Files:**
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`
- Modify: `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`

**Interfaces:**
- Removes: `SocialWorkerProvisionCommand.readPersistedResources(from:)`, `.extractTomlString(named:from:)`, `.extractKVNamespaceID(binding:from:)`, `.extractAllTomlStrings(named:from:)`. `extractResourceID(from:)` (the `wrangler --json`-output parser) is untouched — it parses a create command's own stdout, not `wrangler.toml`.

- [ ] **Step 1: Change `provision()`'s resource-seeding to use only `knownResources`**

In `provision(...)` (~line 263), change:

```swift
var resources = knownResources == .init() ? Self.readPersistedResources(from: siteDirectory) : knownResources
```

to:

```swift
var resources = knownResources
```

`SiteSettings.provisionedWorkerResources` (persisted by `DeployCoordinator.persistProvisionedResources` on every successful provisioning run since #1015) is now the sole source of truth for already-created resource ids — see Open Question 1 in the design doc for why the TOML-reparse fallback is safe to drop pre-1.0.

- [ ] **Step 2: Delete the four now-unused private statics**

Delete `readPersistedResources(from:)` (~744-782), `extractTomlString(named:from:)` (~800-802), `extractKVNamespaceID(binding:from:)` (~809-819), `extractAllTomlStrings(named:from:)` (~821-830). Leave `extractResourceID(from:)` and `findID(in:)` untouched.

- [ ] **Step 3: Delete the extractor-specific tests, update the rest**

In `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`, delete the tests the design doc's investigation named: `"extracts resource ids from common wrangler JSON shapes"` — **keep this one**, it tests `extractResourceID`, which is untouched; only delete `"reads persisted resource ids from active wrangler.toml bindings only"`, `"knownResources is reused instead of re-scraping wrangler.toml…"`, and the four `readPersistedResources` classification tests (queue-suffix, bucket-suffix, KV-binding disambiguation) — search the file for `readPersistedResources` to find all of them precisely, since exact names may have drifted since the design doc's investigation.

For any remaining test that constructs a `wrangler.toml` on disk and relies on `provision()` re-reading it via the now-deleted fallback (i.e. calls `provision()` with `knownResources: .init()` and a pre-written `wrangler.toml`, expecting resources to be picked up from that file), change it to pass the expected `WorkerComposition.ProvisionedResources` directly as `knownResources:` instead — that's the new, sole way to seed already-known resources into a `provision()` call.

- [ ] **Step 4: Run the full provisioning test suite**

Run: `scripts/swift-test.sh --filter SocialWorkerProvisionCommandTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift
git commit -m "refactor(#1821): delete TOML-regex extractors, use knownResources only"
```

---

### Task 10: Phase 2 wrap-up — full verification and PR

- [ ] **Step 1: Full local suite**

Run: `scripts/swift-test.sh`
Expected: PASS.

- [ ] **Step 2: App build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: succeeds.

- [ ] **Step 3: Open the PR**

Title: `feat(#1821): typed WranglerConfiguration, delete TOML extractors`. Body notes Phase 2 of 3, does **not** close #1821.

---

## Phase 3 (PR 3): `SocialWorkerProvisionTarget` — provisioning as a `DeployTarget`

### Task 11: `DeployCommand.Result.webmentionPaidPlanConfirmationNeeded`

**Files:**
- Modify: `Sources/AnglesiteCore/DeployCommand.swift`
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` (`asDeployCommandResult` mapping)
- Modify: `Sources/AnglesiteApp/DeployModel.swift` (the `DeployCommand.Result`-consuming switch that must add the new case)
- Modify: `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift` (`asDeployCommandResult` tests)

**Interfaces:**
- Produces: `DeployCommand.Result.webmentionPaidPlanConfirmationNeeded` (no associated value). Consumed by `SocialWorkerProvisionTarget.publish(context:)` in Task 13, and by `SocialWorkerProvisionCommand.provision`'s result-mapping in Task 14.

- [ ] **Step 1: Add the case**

```swift
public enum Result: Sendable, Equatable {
    case succeeded(url: URL, duration: TimeInterval)
    case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning])
    case workerNameConflict(name: String)
    case domainConfigDrift(findings: [DomainConfigAudit.Finding])
    /// A Queue-backed Worker (inbound Webmention, WebSub, or Microsub) needs to be provisioned
    /// but the site hasn't acknowledged that Cloudflare Queues require the Workers Paid plan —
    /// only ever produced by `SocialWorkerProvisionTarget.publish` (#1821); every other
    /// `DeployTarget` conformer never returns it.
    case webmentionPaidPlanConfirmationNeeded
    case failed(reason: String, exitCode: Int32?)
}
```

- [ ] **Step 2: Fix every exhaustive switch this breaks**

Compile (`swift build --package-path .`) and fix each resulting exhaustiveness error. Expect at minimum:

`SocialWorkerProvisionCommand.swift`'s `asDeployCommandResult` — change from collapsing into `.failed(...)` to a direct passthrough (this is the actual fix the design doc's Open Question 2 resolves):

```swift
case .webmentionPaidPlanConfirmationNeeded:
    return .webmentionPaidPlanConfirmationNeeded
```

`DeployModel.swift`'s `DeployCommand.Result`-consuming switch (the one at ~391-400 mapping to `DeployModel`'s own phase/result type) — this path is only ever reached by an ordinary `CloudflareDeployTarget`/`GitHubPagesDeployTarget` deploy, which never produces this case, so add a defensive arm:

```swift
case .webmentionPaidPlanConfirmationNeeded:
    return .failed(reason: "unexpected: paid-plan confirmation needed outside worker provisioning")
```

Any `FakeExecutor`/test double that switches over `DeployCommand.Result` (not `DeployStep` — a different type) exhaustively needs the same treatment; the compiler will name each one.

- [ ] **Step 3: Update `asDeployCommandResult`'s existing test**

Find the test asserting the old collapse-to-`.failed` behavior (design doc's investigation named it among the "1039-1067" tests) and change its expectation to `.webmentionPaidPlanConfirmationNeeded` instead of a `.failed(reason:)` containing the confirmation message.

- [ ] **Step 4: Run the affected suites**

Run: `scripts/swift-test.sh --filter SocialWorkerProvisionCommandTests`
Run: `scripts/swift-test.sh --filter DeployCommandTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployCommand.swift Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift Sources/AnglesiteApp/DeployModel.swift Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift
git commit -m "feat(#1821): add DeployCommand.Result.webmentionPaidPlanConfirmationNeeded"
```

---

### Task 12: `SocialWorkerProvisionTarget` — `authorize`

**Files:**
- Create: `Sources/AnglesiteCore/SocialWorkerProvisionTarget.swift`
- Test: `Tests/AnglesiteCoreTests/SocialWorkerProvisionTargetTests.swift`

**Interfaces:**
- Produces: `actor SocialWorkerProvisionTarget: DeployTarget` with `static let id = "cloudflare-worker-provisioning"`, an `init(...)` capturing every provisioning-specific input as a stored property (full list in Task 13's Interfaces block — this task only needs `cloudflareTarget: CloudflareDeployTarget` and exposes `authorize(siteDirectory:)`), and a `public var resources: WorkerComposition.ProvisionedResources { get async }`-style actor-isolated accessor (Task 13 populates it; this task only initializes it from `knownResources`).
- Consumes: `CloudflareDeployTarget.authorize(siteDirectory:)`, `.persistWorkerProvisioned(siteDirectory:)` (currently `static func`, package-internal per the design doc's investigation — confirm its access level; if `private`/`internal` and this new type is a different file in the same module, it's already visible, no change needed since both live in `AnglesiteCore`).

Why an `actor`, not a `struct`: `publish(context:)` (Task 13) accumulates `resources` incrementally across many resource-creation steps, and `SocialWorkerProvisionCommand.provision` (Task 14) needs to read the final value back after `DeployCommand.deploy` returns — regardless of which case it returned, including a `.blocked`/`.failed` case where partial resources must still be recoverable for a retry (this is `SocialWorkerProvisionCommand.Result`'s longstanding "every case carries `resources`" contract, unchanged by this refactor). An `actor` gives safe, natural async-isolated mutable state across the `authorize`→`publish` sequence without a boxed reference type; `DeployTarget: Sendable` is satisfied automatically since actors are `Sendable`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/SocialWorkerProvisionTargetTests.swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SocialWorkerProvisionTarget.authorize")
struct SocialWorkerProvisionTargetAuthorizeTests {
    @Test("delegates to CloudflareDeployTarget's full authorize, including domain-drift")
    func delegatesFullAuthorize() async throws {
        let tmpDir = try makeTemporarySiteDirectory()
        let inner = CloudflareDeployTarget(
            tokenSource: { "tok" },
            domainConfigDriftSource: { _, _, _ in [DomainConfigAudit.Finding(field: "dns", declared: "a", live: "b")] })
        try DomainConfigStore(sourceDirectory: tmpDir).save(DomainConfig(domain: .init(hostname: "example.com")))
        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: inner, siteName: "site", workers: [], knownResources: .init())
        let result = await target.authorize(siteDirectory: tmpDir)
        guard case .blocked(.domainConfigDrift) = result else {
            Issue.record("expected .blocked(.domainConfigDrift), got \(result)")
            return
        }
    }

    @Test("persists CF_WORKER_PROVISIONED on a successful authorize")
    func persistsWorkerProvisionedOnSuccess() async throws {
        let tmpDir = try makeTemporarySiteDirectory()
        let inner = CloudflareDeployTarget(tokenSource: { "tok" })
        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: inner, siteName: "site", workers: [], knownResources: .init())
        let result = await target.authorize(siteDirectory: tmpDir)
        guard case .ready = result else { Issue.record("expected .ready, got \(result)"); return }
        let config = try String(contentsOf: tmpDir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "CF_WORKER_PROVISIONED", in: config) == "true")
    }
}
```

(Use whatever existing helper this test module already has for building a scratch site directory — grep `Tests/AnglesiteCoreTests/` for `makeTemporarySiteDirectory`/similar and reuse it rather than inventing a new one; if none exists, use the same `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)` + cleanup pattern `SocialWorkerProvisionCommandTests.swift` already uses.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path . --filter SocialWorkerProvisionTargetTests`
Expected: FAIL — `SocialWorkerProvisionTarget` doesn't exist.

- [ ] **Step 3: Implement `authorize`**

```swift
// Sources/AnglesiteCore/SocialWorkerProvisionTarget.swift
import Foundation

/// `DeployTarget` conformer for Cloudflare Worker provisioning (#1821): resource creation
/// (D1/KV/R2/Queues), secret pushes, and D1 migrations all run inside `publish(context:)`,
/// reached only after `authorize` (the full `CloudflareDeployTarget` gate — worker-name-conflict
/// AND domain-config-drift, not just the former) and the shared build+`PreDeployCheck` spine have
/// passed. `publish` finishes by delegating to `cloudflareTarget.publish(context:)` for the
/// actual `wrangler deploy`, so the final step reuses `CloudflareDeployTarget`'s URL extraction,
/// custom-domain attach, Markdown for Agents, and `.site-config` persistence rather than
/// duplicating any of it.
///
/// An `actor`, not a `struct`: `resources` accumulates incrementally across `publish`'s many
/// resource-creation steps, and `SocialWorkerProvisionCommand.provision` needs to read the final
/// value back after `DeployCommand.deploy` returns — on every outcome, not just success, since a
/// partial failure must not lose ids already created (this target's `resources` is the same
/// resumability state `SocialWorkerProvisionCommand.Result` has always carried).
public actor SocialWorkerProvisionTarget: DeployTarget {
    public static let id = "cloudflare-worker-provisioning"

    private let cloudflareTarget: CloudflareDeployTarget
    private let siteName: String
    private let workers: [WorkerDescriptor]
    public private(set) var resources: WorkerComposition.ProvisionedResources

    public init(
        cloudflareTarget: CloudflareDeployTarget,
        siteName: String,
        workers: [WorkerDescriptor],
        knownResources: WorkerComposition.ProvisionedResources
    ) {
        self.cloudflareTarget = cloudflareTarget
        self.siteName = siteName
        self.workers = workers
        self.resources = knownResources
    }

    public func authorize(siteDirectory: URL) async -> DeployTargetAuthorization {
        let authorization = await cloudflareTarget.authorize(siteDirectory: siteDirectory)
        if case .ready = authorization {
            CloudflareDeployTarget.persistWorkerProvisioned(siteDirectory: siteDirectory)
        }
        return authorization
    }
}
```

If `CloudflareDeployTarget.persistWorkerProvisioned` turns out to be `private` rather than package-internal (re-check its access modifier in `CloudflareDeployTarget.swift` — it read as bare `static func` with no modifier, i.e. `internal`, during planning, which is visible from another file in the same `AnglesiteCore` target), no change needed; if it's genuinely `private`, widen it to `internal` (drop the `private` keyword) as part of this step — it's already called from `SocialWorkerProvisionCommand.swift`, a different file, today, so it can't actually be `private`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path . --filter SocialWorkerProvisionTargetTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionTarget.swift Tests/AnglesiteCoreTests/SocialWorkerProvisionTargetTests.swift
git commit -m "feat(#1821): add SocialWorkerProvisionTarget.authorize"
```

---

### Task 13: `SocialWorkerProvisionTarget.publish` — move the provisioning body in

**Files:**
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionTarget.swift`
- Modify: `Tests/AnglesiteCoreTests/SocialWorkerProvisionTargetTests.swift`

**Interfaces:**
- Produces: `SocialWorkerProvisionTarget.publish(context: DeployTargetContext) async -> DeployCommand.Result`. Expands `init` to carry every input `provision()`'s body needs (full parameter list below).
- Consumes: `DeployStep.wranglerSubcommand` (Task 3), `WranglerConfiguration` (Task 6), `context.executor.run(step:siteDirectory:environment:source:)`.

This is the largest single task in the plan: it moves `SocialWorkerProvisionCommand.provision`'s entire resource-creation/secret-push/paid-plan-gate/migration body (today's lines ~283-620, unchanged in Task 9's version) into `publish(context:)`, reading from `self`'s stored properties instead of `provision`'s function parameters, mutating `self.resources` instead of a local `var`, and replacing every `runWrangler(...)` call with a call through `context.executor.run(step: .wranglerSubcommand(args:), ...)`.

- [ ] **Step 1: Expand `init` to carry every provisioning input**

```swift
public actor SocialWorkerProvisionTarget: DeployTarget {
    public static let id = "cloudflare-worker-provisioning"

    private let cloudflareTarget: CloudflareDeployTarget
    private let siteName: String
    private let workers: [WorkerDescriptor]
    private let routeClaims: [WorkerRouteClaim]
    private let siteURL: String?
    private let displayName: String?
    private let apUsername: String?
    private let apIcon: String?
    private let acknowledgesPaidPlan: Bool
    private let inboxCaptureEnabled: Bool
    private let inboxForwardEmail: String?
    private let activityPubActorType: String?
    private let moderators: [String]?
    private let experiments: [DomainConfig.Experiments.Experiment]
    private let mcpEnabled: Bool
    private let keyPairSource: SocialWorkerProvisionCommand.KeyPairSource
    private let solidOidcSigningKeySource: SocialWorkerProvisionCommand.SolidOidcSigningKeySource
    private let webdavPepperSource: SocialWorkerProvisionCommand.WebdavPepperSource
    private let secretRunner: SocialWorkerProvisionCommand.SecretRunner
    private let accountIDSource: SocialWorkerProvisionCommand.AccountIDSource
    public private(set) var resources: WorkerComposition.ProvisionedResources

    public init(
        cloudflareTarget: CloudflareDeployTarget,
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim] = [],
        knownResources: WorkerComposition.ProvisionedResources = .init(),
        siteURL: String? = nil,
        displayName: String? = nil,
        apUsername: String? = nil,
        apIcon: String? = nil,
        acknowledgesPaidPlan: Bool = false,
        inboxCaptureEnabled: Bool = false,
        inboxForwardEmail: String? = nil,
        activityPubActorType: String? = nil,
        moderators: [String]? = nil,
        experiments: [DomainConfig.Experiments.Experiment] = [],
        mcpEnabled: Bool = false,
        keyPairSource: @escaping SocialWorkerProvisionCommand.KeyPairSource,
        solidOidcSigningKeySource: @escaping SocialWorkerProvisionCommand.SolidOidcSigningKeySource,
        webdavPepperSource: @escaping SocialWorkerProvisionCommand.WebdavPepperSource,
        secretRunner: @escaping SocialWorkerProvisionCommand.SecretRunner,
        accountIDSource: @escaping SocialWorkerProvisionCommand.AccountIDSource
    ) {
        self.cloudflareTarget = cloudflareTarget
        self.siteName = siteName
        self.workers = workers
        self.routeClaims = routeClaims
        self.resources = knownResources
        self.siteURL = siteURL
        self.displayName = displayName
        self.apUsername = apUsername
        self.apIcon = apIcon
        self.acknowledgesPaidPlan = acknowledgesPaidPlan
        self.inboxCaptureEnabled = inboxCaptureEnabled
        self.inboxForwardEmail = inboxForwardEmail
        self.activityPubActorType = activityPubActorType
        self.moderators = moderators
        self.experiments = experiments
        self.mcpEnabled = mcpEnabled
        self.keyPairSource = keyPairSource
        self.solidOidcSigningKeySource = solidOidcSigningKeySource
        self.webdavPepperSource = webdavPepperSource
        self.secretRunner = secretRunner
        self.accountIDSource = accountIDSource
    }

    public func authorize(siteDirectory: URL) async -> DeployTargetAuthorization {
        let authorization = await cloudflareTarget.authorize(siteDirectory: siteDirectory)
        if case .ready = authorization {
            CloudflareDeployTarget.persistWorkerProvisioned(siteDirectory: siteDirectory)
        }
        return authorization
    }
}
```

- [ ] **Step 2: Write `publish(context:)`, adapting `provision`'s body 1:1**

Copy `provision`'s body from the `hasRunningExperiment` computation (today ~261) through the last D1-migration block (~620) into `publish(context:)`, with these mechanical substitutions applied throughout:

- `siteDirectory`/`siteID` → `context.siteDirectory`/`context.siteID`
- `environment` (the local `var environment = DeployCommand.hostDeployEnvironment(); environment["CLOUDFLARE_API_TOKEN"] = token`) → `context.baseEnvironment` with `CLOUDFLARE_API_TOKEN` already added — build it once at the top of `publish`: `var environment = context.baseEnvironment; environment["CLOUDFLARE_API_TOKEN"] = context.credential`
- every `resources` mutation (`resources.d1DatabaseID = id`, etc.) → `self.resources.d1DatabaseID = id` (actor-isolated, no `await` needed for `self` access within the actor's own method)
- every `await runWrangler(siteDirectory: siteDirectory, arguments: [...], environment: environment, source: source, resources: resources)` → a new private actor method:

```swift
private func runWranglerSubcommand(
    context: DeployTargetContext, arguments: [String], environment: [String: String], source: String
) async -> StepResult {
    let result = await context.executor.run(
        step: .wranglerSubcommand(args: arguments),
        siteDirectory: context.siteDirectory, environment: environment, source: source)
    guard let exitCode = result.exitCode, exitCode == 0 else {
        return .failure(.failed(reason: result.output.isEmpty ? "wrangler exited with code \(String(describing: result.exitCode))" : result.output, exitCode: result.exitCode))
    }
    return .success(result.output)
}

private enum StepResult {
    case success(String)
    case failure(DeployCommand.Result)
}
```

  called as `await runWranglerSubcommand(context: context, arguments: ["d1", "create", name], environment: environment, source: source)`. Note the `StepResult.failure` payload is now `DeployCommand.Result` (not `SocialWorkerProvisionCommand.Result` — `publish` returns the former), and every early-return in the copied body that used to do `return failure` (a `SocialWorkerProvisionCommand.Result`) now does `return failure` where `failure` is already a `DeployCommand.Result` from this new `runWranglerSubcommand`, OR, for the checks that build a `.failed(...)` directly (e.g. `guard let id = ... else { return .failed(reason: ..., exitCode: 0, resources: resources) }`), drop the `resources:` argument entirely (`DeployCommand.Result.failed` has no such parameter — `resources` is read back separately via `self.resources` after `publish` returns, per Task 14).

- `persistConfig(...)` calls stay exactly as they are (same function, same file, still callable from within the actor) — copy `persistConfig` itself into this file too (or leave it on `SocialWorkerProvisionCommand` as `static`/`internal` and call `SocialWorkerProvisionCommand.persistConfig(...)`, whichever keeps the diff smaller; since `persistConfig` doesn't reference `self` in its current form beyond parameters, moving it as a `private static` helper on `SocialWorkerProvisionTarget` — with `resources: self.resources` passed explicitly at each call site — is the cleaner home given it's now provisioning-specific logic, so move it).
- the `hasActivityPub`/`hasSolidOidc`/`hasWebdav` secret-push blocks: `keyPairSource(siteID)` → `keyPairSource(context.siteID)`, `secretRunner(siteDirectory, name, value, environment, source)` → `try await secretRunner(context.siteDirectory, name, value, environment, source)` (unchanged shape, just reading `context.siteDirectory`).
- the paid-plan gate: `guard acknowledgesPaidPlan else { return .webmentionPaidPlanConfirmationNeeded(resources: resources) }` → `guard acknowledgesPaidPlan else { return .webmentionPaidPlanConfirmationNeeded }` (Task 11's new case, no associated resources — `self.resources` is already correct at this point for the caller to read back).
- the final block: replace

```swift
switch await deployer(token, siteID, siteDirectory, wellKnownDynamicClaims) {
case .succeeded(let url, _):
    return .succeeded(url: url, resources: resources, duration: Date().timeIntervalSince(started))
...
```

with a direct delegation to the inner Cloudflare target — `publish` doesn't call `DeployCommand.deploy` again (that would re-run `authorize`/build/`PreDeployCheck` a second time); it calls `cloudflareTarget.publish(context:)` directly, since `context` here already reflects the one shared spine run this `publish` call is itself part of:

```swift
return await cloudflareTarget.publish(context: context)
```

(`started`/duration tracking moves into `CloudflareDeployTarget.publish` already — it computes its own `duration` from its own `started` timestamp scoped to the wrangler-deploy step, which is the correct semantic per `DeployCommand.Result.succeeded`'s doc: "`duration` covers the target's publish step only." The old `Date().timeIntervalSince(started)` in `SocialWorkerProvisionCommand.provision` covered the *entire* provisioning+deploy span, which was arguably the wrong thing to call "publish duration" anyway — this is a small, intentional narrowing, not a bug.)

- [ ] **Step 3: Write a `publish` integration test**

```swift
@Test("publish creates D1 before delegating to CloudflareDeployTarget for the final deploy")
func publishCreatesD1ThenDeploys() async throws {
    let tmpDir = try makeTemporarySiteDirectory()
    let executor = FakeExecutor()
        .set(.wranglerSubcommand(args: ["d1", "create", "site-social"]), exitCode: 0, output: #"{"database_id":"db-abc"}"#)
        .set(.build, exitCode: 0, output: "")
        .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
        .set(.wrangler, exitCode: 0, output: "Published site (0.1 sec)\n  https://site.workers.dev")
    let inner = CloudflareDeployTarget(tokenSource: { "tok" })
    let target = SocialWorkerProvisionTarget(
        cloudflareTarget: inner, siteName: "site", workers: [.indieauth],
        keyPairSource: { _ in .init(privateKeyPem: "", publicKeyPem: "", publishToken: "") },
        solidOidcSigningKeySource: { _ in "" }, webdavPepperSource: { _ in "" },
        secretRunner: { _, _, _, _, _ in .init(stdout: "", stderr: "", exitCode: 0) },
        accountIDSource: { _ in nil })
    let cmd = DeployCommand(target: target, executor: executor)
    let result = await cmd.deploy(siteID: "s", siteDirectory: tmpDir)
    guard case .succeeded(let url, _) = result else { Issue.record("expected .succeeded, got \(result)"); return }
    #expect(url.absoluteString == "https://site.workers.dev")
    let resources = await target.resources
    #expect(resources.d1DatabaseID == "db-abc")
}
```

Use `WorkerDescriptor.indieauth` or whatever fixture `SocialWorkerProvisionCommandTests.swift` already uses for a D1-needing worker (`.indieauth` needs D1 via `needsD1` per `WorkerComposition`). `FakeExecutor` here needs the `.set(_ step: DeployStep, ...)` API from `DeployCommandTests.swift`'s fake (Task 3 already taught it to key `.wranglerSubcommand` by its joined args) — if it's `private` to that file, either widen its access or copy a minimal version into this test file; prefer reusing it by widening access (`private` → default/internal) in `DeployCommandTests.swift` if nothing else in that file depends on it staying file-private.

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path . --filter SocialWorkerProvisionTargetTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionTarget.swift Sources/AnglesiteCore/DeployCommandTests.swift Tests/AnglesiteCoreTests/SocialWorkerProvisionTargetTests.swift Tests/AnglesiteCoreTests/DeployCommandTests.swift
git commit -m "feat(#1821): move provisioning body into SocialWorkerProvisionTarget.publish"
```

---

### Task 14: `SocialWorkerProvisionCommand.provision` becomes a thin adapter

**Files:**
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`

**Interfaces:**
- Changes `SocialWorkerProvisionCommand.init`: **removes** `runner: CommandRunner`, `deployer: Deployer` parameters and the `CommandRunner`/`Deployer` typealiases; **adds** `executor: any DeployExecutor = HostDeployExecutor()`.
- Changes `provision(...)`'s signature: **adds** `configDirectory: URL? = nil`, `currentRoutes: [String] = []`, `onPreflight: DeployCommand.PreflightObserver? = nil`, `onDomainAttach: DeployCommand.DomainAttachObserver? = nil`, `onMarkdownForAgents: DeployCommand.MarkdownForAgentsObserver? = nil`, `onProgress: ProgressHandler? = nil` — these replace what the deleted `deployer` closure used to capture from its caller (`DeployModel`'s `configDirectory`/`currentRoutes`/four callbacks, per the investigation).
- Keeps unchanged: every other `provision(...)` parameter, the full `Result` enum (still 6 cases, unchanged shape), `tokenSource`/`keyPairSource`/`solidOidcSigningKeySource`/`webdavPepperSource`/`secretRunner`/`workerScriptNamesSource`/`accountIDSource` init parameters.

- [ ] **Step 1: Update `init`**

Remove `runner`/`deployer` parameters and their typealiases (`CommandRunner`, `Deployer`) and defaults (`defaultRunner`, `defaultDeployer`). Add:

```swift
private let executor: any DeployExecutor

public init(
    tokenSource: @escaping TokenSource = CloudflareDeployTarget.keychainTokenSource,
    executor: any DeployExecutor = HostDeployExecutor(),
    keyPairSource: @escaping KeyPairSource = SocialWorkerProvisionCommand.defaultKeyPairSource,
    solidOidcSigningKeySource: @escaping SolidOidcSigningKeySource = SocialWorkerProvisionCommand.defaultSolidOidcSigningKeySource,
    webdavPepperSource: @escaping WebdavPepperSource = SocialWorkerProvisionCommand.defaultWebdavPepperSource,
    secretRunner: @escaping SecretRunner = SocialWorkerProvisionCommand.defaultSecretRunner,
    workerScriptNamesSource: @escaping CloudflareDeployTarget.WorkerScriptNamesSource = CloudflareDeployTarget.defaultWorkerScriptNames,
    accountIDSource: @escaping AccountIDSource = SocialWorkerProvisionCommand.defaultAccountIDSource
) {
    self.tokenSource = tokenSource
    self.executor = executor
    self.keyPairSource = keyPairSource
    self.solidOidcSigningKeySource = solidOidcSigningKeySource
    self.webdavPepperSource = webdavPepperSource
    self.secretRunner = secretRunner
    self.workerScriptNamesSource = workerScriptNamesSource
    self.accountIDSource = accountIDSource
}
```

(`HostDeployExecutor()`'s production default fails explicitly per its own doc, exactly matching the retired `defaultRunner`'s "log-and-127" stance — no behavior change for a caller that never overrides it.)

- [ ] **Step 2: Rewrite `provision(...)`'s body**

Keep every parameter through `mcpEnabled` unchanged; add the six new ones listed in this task's Interfaces block. Replace the entire body (today ~239-634, already updated by Tasks 9/11) with:

```swift
) async -> Result {
    let token: String?
    do {
        token = try await tokenSource()
    } catch {
        return .failed(reason: "couldn't read Cloudflare API token: \(error)", exitCode: nil, resources: knownResources)
    }
    guard let token, !token.isEmpty else {
        return .failed(
            reason: "no CLOUDFLARE_API_TOKEN — add it in Settings → Advanced → Credentials, or set the env var",
            exitCode: nil, resources: knownResources)
    }
    guard WorkerComposition.isValidSiteName(siteName) else {
        return .failed(reason: "invalid Worker name: \(siteName)", exitCode: nil, resources: knownResources)
    }

    let target = SocialWorkerProvisionTarget(
        cloudflareTarget: CloudflareDeployTarget(
            tokenSource: { token }, workerScriptNamesSource: workerScriptNamesSource,
            accountIDSource: { apiToken in await accountIDSource(apiToken) }),
        siteName: siteName, workers: workers, routeClaims: routeClaims, knownResources: knownResources,
        siteURL: siteURL, displayName: displayName, apUsername: apUsername, apIcon: apIcon,
        acknowledgesPaidPlan: acknowledgesPaidPlan, inboxCaptureEnabled: inboxCaptureEnabled,
        inboxForwardEmail: inboxForwardEmail, activityPubActorType: activityPubActorType,
        moderators: moderators, experiments: experiments, mcpEnabled: mcpEnabled,
        keyPairSource: keyPairSource, solidOidcSigningKeySource: solidOidcSigningKeySource,
        webdavPepperSource: webdavPepperSource, secretRunner: secretRunner, accountIDSource: accountIDSource)

    let started = Date()
    let deployResult = await DeployCommand(target: target, executor: executor).deploy(
        siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory,
        currentRoutes: currentRoutes, wellKnownDynamicClaims: wellKnownDynamicClaims,
        onPreflight: onPreflight, onDomainAttach: onDomainAttach,
        onMarkdownForAgents: onMarkdownForAgents, onProgress: onProgress)
    let finalResources = await target.resources

    switch deployResult {
    case .succeeded(let url, let duration):
        return .succeeded(url: url, resources: finalResources, duration: duration)
    case .blocked(let failures, let warnings):
        return .blocked(failures: failures, warnings: warnings, resources: finalResources)
    case .workerNameConflict(let name):
        return .workerNameConflict(name: name, resources: finalResources)
    case .domainConfigDrift(let findings):
        return .domainConfigDrift(findings: findings, resources: finalResources)
    case .webmentionPaidPlanConfirmationNeeded:
        return .webmentionPaidPlanConfirmationNeeded(resources: finalResources)
    case .failed(let reason, let exitCode):
        return .failed(reason: reason, exitCode: exitCode, resources: finalResources)
    }
}
```

`started`/`Date()` above is now unused for `.succeeded`'s duration (Task 13's note: `CloudflareDeployTarget.publish` supplies its own, narrower, more accurate duration) — delete the now-dead `let started = Date()` line rather than leaving it unused (the compiler will flag it).

Delete `runWrangler`, `StepResult`, `persistConfig`, `readPersistedResources`'s already-deleted remnants, and `extractResourceID`/`findID` **stay** — wait, `extractResourceID`/`findID` moved logically into `SocialWorkerProvisionTarget` in Task 13 (it's called from the resource-creation steps that live there now) — if Task 13 left them on `SocialWorkerProvisionCommand` and called them as `SocialWorkerProvisionCommand.extractResourceID(from:)` from the actor, that's fine and simpler than moving them; don't move them in this task unless Task 13 already did. Reconcile whichever choice Task 13 actually made and remove only what's now genuinely dead code here (`runWrangler`, `StepResult`, `persistConfig` if Task 13 moved it, the `defaultRunner`/`defaultDeployer` static seams and their doc comments).

- [ ] **Step 3: Compile and fix fallout**

Run: `swift build --package-path .`
Fix every resulting error in this file (mostly: confirm nothing else in `SocialWorkerProvisionCommand.swift` still references `runner`/`deployer`/`self.runner`/`self.deployer`).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift
git commit -m "refactor(#1821): SocialWorkerProvisionCommand.provision delegates to DeployCommand"
```

(This task's own tests come in Task 17, once the call sites — Tasks 15/16 — compile too; `swift build` succeeding is this task's own bar, not `swift test`, since the 50 broken test-file call sites are Task 17's job.)

---

### Task 15: Update `DeployModel.swift`'s call site

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift`

**Interfaces:**
- Consumes: the new `SocialWorkerProvisionCommand.init`/`provision(...)` signatures from Task 14.

- [ ] **Step 1: Replace the `SocialWorkerProvisionCommand(...)` construction**

Replace the construction at ~1006-1058 (quoted in full during planning — `tokenSource`/`runner`/`secretRunner`/`deployer`/`workerScriptNamesSource`) with:

```swift
let cloudflareTarget = resolvedTarget as? CloudflareDeployTarget
let socialCommand = SocialWorkerProvisionCommand(
    tokenSource: {
        guard let cloudflareTarget else { return nil }
        return try await cloudflareTarget.tokenSource()
    },
    executor: containerExecutor ?? HostDeployExecutor(),
    secretRunner: containerSecretRunner ?? SocialWorkerProvisionCommand.defaultSecretRunner,
    workerScriptNamesSource: { token in
        guard let cloudflareTarget else { return [] }
        return try await cloudflareTarget.workerScriptNamesSource(token)
    }
)
```

`containerExecutor` here is whatever `DeployExecutor` `activeCommand` (the existing `DeployCommand` pinned to `resolvedTarget`, built at ~868-887) was itself constructed with — read that construction site and reuse the *same* executor instance (it's already either a `ContainerDeployExecutor` when a container is running or a fallback), rather than building a second, separately-configured one; if that executor isn't already exposed as a local `let` your new code can reference, extract it into one at that existing construction site so both `activeCommand` and this new `socialCommand` share it. `containerRunner`/`ContainerCommandRunner(...)` construction for `.runner` is no longer needed and can be deleted if nothing else in this file uses `containerCommandRunner.runner` — keep `containerCommandRunner.secretRunner` (now assigned to `containerSecretRunner`), since `SecretRunner` is unchanged by this plan.

- [ ] **Step 2: Replace the `.provision(...)` call**

At ~1090-1108, add the six new arguments this call was previously forwarding through a custom `deployer` closure:

```swift
let provisionResult = await socialCommand.provision(
    siteID: siteID,
    siteDirectory: siteDirectory,
    siteName: workerSiteName,
    workers: workers,
    routeClaims: effectiveRouteClaims.map(\.claim),
    knownResources: settings.provisionedWorkerResources ?? .init(),
    siteURL: siteURL,
    displayName: settings.displayName,
    apUsername: apUsername,
    apIcon: apIcon,
    acknowledgesPaidPlan: acknowledgesPaidPlan,
    inboxCaptureEnabled: settings.inboxCaptureEnabled ?? false,
    inboxForwardEmail: inboxForwardEmail,
    activityPubActorType: isHostedCommunity ? "Group" : nil,
    moderators: isHostedCommunity ? settings.moderators : nil,
    experiments: runningExperiments,
    mcpEnabled: mcpEnabled,
    configDirectory: configDirectory,
    currentRoutes: currentRoutes,
    wellKnownDynamicClaims: WorkerRouteClaims.wellKnownClaims(effectiveRouteClaims),
    onPreflight: { [weak self] outcome in
        Task { @MainActor in self?.onScanComplete?(outcome) }
    },
    onDomainAttach: { [weak self] outcome in
        Task { @MainActor in self?.domainAttachStatus = outcome }
    },
    onMarkdownForAgents: { [weak self] outcome in
        Task { @MainActor in self?.markdownForAgentsStatus = outcome }
    },
    onProgress: { [weak self] progress in
        Task { @MainActor in
            self?.currentMilestone = progress.label
            self?.currentMilestonePhase = progress.phase
            self?.onMilestone?(siteID, progress)
        }
    }
)
```

(`wellKnownDynamicClaims` was already a `provision(...)` parameter pre-refactor — confirm it's still passed at the same position; the four `on*` closures are copied verbatim from the deleted `deployer` closure body.)

- [ ] **Step 3: Compile**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: succeeds (run `xcodegen generate` first if this worktree hasn't yet, per `AGENTS.md` ▸ "Worktrees").

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift
git commit -m "refactor(#1821): update DeployModel for the new provision() signature"
```

---

### Task 16: Update `SiteOperations.swift`'s two call sites

**Files:**
- Modify: `Sources/AnglesiteCore/SiteOperations.swift`

**Interfaces:**
- Consumes: Task 14's new signatures. No behavior change needed here — neither call site builds a custom `runner`/`deployer`, both use `factory.socialWorkerProvision()` (zero-arg, all defaults) and pass no `configDirectory`/observer closures today, so they need **no changes at all** to the `.provision(...)` call argument lists (the six new parameters all default) — only verify they still compile.

- [ ] **Step 1: Compile and confirm no changes needed**

Run: `swift build --package-path .`

If `deployWithWorkerComposition` (~165-181) or `provisionSocialWorker` (~255-261) fail to compile, the failure will point at exactly what changed; the design intent is that both keep compiling unchanged since `CommandFactory.swift:29`'s `SocialWorkerProvisionCommand()` zero-arg construction and every new `provision(...)` parameter default make this a source-compatible change for callers that never injected `runner`/`deployer`.

- [ ] **Step 2: If it doesn't compile unchanged, fix minimally**

Only if Step 1 surfaces an actual error — apply the minimal fix (most likely: `CommandFactory.swift`'s zero-arg default now needs an explicit `executor:` if `HostDeployExecutor()` isn't accessible from that context for some reason; unlikely but verify).

- [ ] **Step 3: Commit** (only if Step 2 made changes; otherwise this task is a no-op verification, fold into Task 17's commit)

---

### Task 17: Migrate `SocialWorkerProvisionCommandTests.swift` (50 sites) + the two `SiteOperations` test files

**Files:**
- Modify: `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`
- Modify: `Tests/AnglesiteCoreTests/SiteOperationsTests.swift`
- Modify: `Tests/AnglesiteCoreTests/SiteOperationsProgressSeamTests.swift`

**Interfaces:**
- Consumes: Task 14's new `init`/`provision(...)` signatures.

This is a mechanical bulk migration, not a design task — the pattern is fixed by Task 14; this task applies it uniformly.

**The conversion pattern**, applied to every `SocialWorkerProvisionCommand(...)` construction in the file:

*Before* (today's typical shape, varying per test in which closures it injects):
```swift
let recorder = CallRecorder()
let command = SocialWorkerProvisionCommand(
    tokenSource: { "tok" },
    runner: { siteDirectory, arguments, environment, source in
        await recorder.record(arguments)
        return .init(stdout: "created", stderr: "", exitCode: 0)
    },
    secretRunner: { _, _, _, _, _ in .init(stdout: "Success!", stderr: "", exitCode: 0) },
    deployer: { token, siteID, siteDirectory, claims in
        .succeeded(url: URL(string: "https://x.workers.dev")!, duration: 1)
    }
)
let result = await command.provision(siteID: "s", siteDirectory: tmpDir, siteName: "site", workers: [.indieauth])
```

*After* — `runner`/`deployer` become one `executor:` fake scripted per `DeployStep`, using the same `FakeExecutor` pattern Task 3/13 already established in `DeployCommandTests.swift` (widen its access there if needed, or give this test file its own copy — whichever the file already leans toward; check whether `SocialWorkerProvisionCommandTests.swift` already imports/reuses types from `DeployCommandTests.swift` today, and match that precedent):

```swift
let executor = FakeExecutor()
    .set(.wranglerSubcommand(args: ["d1", "create", "site-social"]), exitCode: 0, output: "created")
    .set(.build, exitCode: 0, output: "")
    .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
    .set(.wrangler, exitCode: 0, output: "Published site (0.1 sec)\n  https://x.workers.dev")
let command = SocialWorkerProvisionCommand(
    tokenSource: { "tok" },
    executor: executor,
    secretRunner: { _, _, _, _, _ in .init(stdout: "Success!", stderr: "", exitCode: 0) }
)
let result = await command.provision(siteID: "s", siteDirectory: tmpDir, siteName: "site", workers: [.indieauth])
```

Each test's specific `runner` behavior (what it records, what output/exit-code it returns for which arguments) maps to a `.set(.wranglerSubcommand(args: [...]), exitCode:output:)` call scripted for the *specific* subcommand argv that test cares about; a test whose `runner` closure just returns a fixed success for any arguments (the common case) needs a `.set` call per distinct wrangler subcommand the test's active `workers` set actually triggers — read `provision`'s (now `SocialWorkerProvisionTarget.publish`'s) gating logic to know which subcommands a given `workers`/`experiments`/`inboxCaptureEnabled` combination reaches, and script exactly those; every test also needs `.build`/`.preflight`/`.wrangler` scripted with success output (matching the old `deployer` closure's canned `.succeeded(...)` return) unless the test is specifically asserting on a provisioning-stage failure that should never reach the deploy stage at all (in which case leave `.wrangler` unscripted and assert the deploy step never ran, via `executor.ran(.wrangler) == false`).

A test whose `deployer` closure returned something other than `.succeeded` (e.g. `.failed(...)`, to test `provision`'s pass-through mapping) instead scripts `.set(.wrangler, exitCode: 1, output: "...")` or `.set(.preflight, exitCode: 1, output: scanJSON(ok: false, ...))` to produce the equivalent `DeployCommand.Result` through the real spine rather than a canned closure return.

- [ ] **Step 1: Apply the conversion pattern to every construction in `SocialWorkerProvisionCommandTests.swift`**

Work through the file's ~50 `SocialWorkerProvisionCommand(...)` constructions one at a time, applying the pattern above. Re-run the single test being converted after each one or small batch (`swift test --package-path . --filter SocialWorkerProvisionCommandTests/<testName>`) rather than converting all 50 blind and debugging the whole file at once.

- [ ] **Step 2: Apply the same pattern to `SiteOperationsTests.swift`'s two constructions and `SiteOperationsProgressSeamTests.swift`'s one**

`SiteOperationsTests.swift:16` (tokenSource-only) needs no change beyond compiling (no `runner`/`deployer` to migrate). `SiteOperationsTests.swift:580-592` (quoted in full during planning) is the one real migration in that file — apply the same pattern. `SiteOperationsProgressSeamTests.swift:34` (tokenSource-only) needs no change beyond compiling.

- [ ] **Step 3: Run the full migrated suites**

Run: `scripts/swift-test.sh --filter SocialWorkerProvisionCommandTests`
Run: `scripts/swift-test.sh --filter SiteOperationsTests`
Run: `scripts/swift-test.sh --filter SiteOperationsProgressSeamTests`
Expected: PASS, all tests — same assertions as before, exercised through the real `DeployCommand` spine instead of a canned `deployer` closure (a strictly stronger test: it now also exercises `authorize`/build/`PreDeployCheck` sequencing for every provisioning test, not just the ones that explicitly tested that before).

- [ ] **Step 4: Commit**

```bash
git add Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift Tests/AnglesiteCoreTests/SiteOperationsTests.swift Tests/AnglesiteCoreTests/SiteOperationsProgressSeamTests.swift
git commit -m "test(#1821): migrate SocialWorkerProvisionCommand tests to the executor seam"
```

---

### Task 18: `SocialWorkerProvisionTarget` behavior coverage — the domain-drift-before-provisioning change

**Files:**
- Modify: `Tests/AnglesiteCoreTests/SocialWorkerProvisionTargetTests.swift`

**Interfaces:**
- No production interface change — this task adds the one test this whole plan's single intentional behavior change deserves: proof that a domain-drift finding blocks provisioning *before* any resource-creation wrangler call runs.

- [ ] **Step 1: Write the test**

```swift
@Test("domain-config-drift blocks before any resource is created")
func domainDriftBlocksBeforeResourceCreation() async throws {
    let tmpDir = try makeTemporarySiteDirectory()
    try DomainConfigStore(sourceDirectory: tmpDir).save(DomainConfig(domain: .init(hostname: "example.com")))
    let inner = CloudflareDeployTarget(
        tokenSource: { "tok" },
        domainConfigDriftSource: { _, _, _ in [DomainConfigAudit.Finding(field: "dns", declared: "a", live: "b")] })
    let executor = FakeExecutor()  // no steps scripted — any call fails the test via a nil/zero default
    let target = SocialWorkerProvisionTarget(
        cloudflareTarget: inner, siteName: "site", workers: [.indieauth],
        keyPairSource: { _ in .init(privateKeyPem: "", publicKeyPem: "", publishToken: "") },
        solidOidcSigningKeySource: { _ in "" }, webdavPepperSource: { _ in "" },
        secretRunner: { _, _, _, _, _ in .init(stdout: "", stderr: "", exitCode: 0) },
        accountIDSource: { _ in nil })
    let cmd = DeployCommand(target: target, executor: executor)
    let result = await cmd.deploy(siteID: "s", siteDirectory: tmpDir)
    guard case .domainConfigDrift = result else { Issue.record("expected .domainConfigDrift, got \(result)"); return }
    #expect(!executor.ran(.wranglerSubcommand(args: ["d1", "create", "site-social"])))
}
```

`FakeExecutor.ran(_:)` keys by `key(_:)` (Task 3's `"wranglerSubcommand:\(args...)"` string) — confirm the exact args string `d1 create` would use for `.indieauth` (`"\(siteName)-social"`, i.e. `"site-social"` for `siteName: "site"`) matches what `SocialWorkerProvisionTarget.publish` actually builds, per Task 13's copied body.

- [ ] **Step 2: Run**

Run: `swift test --package-path . --filter SocialWorkerProvisionTargetTests`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/SocialWorkerProvisionTargetTests.swift
git commit -m "test(#1821): cover domain-drift blocking before resource creation"
```

---

### Task 19: Phase 3 wrap-up — full verification and PR (closes #1821)

- [ ] **Step 1: Full local suite**

Run: `scripts/swift-test.sh`
Expected: PASS, zero regressions across the whole package.

- [ ] **Step 2: App build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: succeeds.

- [ ] **Step 3: Smoke-test a real provisioning run if the container boot artifacts are available in this worktree**

Per `docs/testing-macos-app.md` — if `Resources/container-{image,kernel,initfs}` are present (they may not be, per this session's toolchain preflight warning), launch the Debug app and provision a test site's Worker to confirm the end-to-end path (D1/KV create → secrets → deploy) still works against a real container, not just fakes. If the artifacts aren't available in this worktree, note that explicitly in the PR body's Test plan rather than silently skipping it.

- [ ] **Step 4: Open the PR**

Title: `feat(#1821): route Worker provisioning through the DeployCommand spine`. Body from the PR template, `Closes #1821`, calling out the one intentional behavior change (domain-config-drift now checked before any resource creation, not only before the final deploy) under a "Design notes" section appended after the template's own sections. Link the design doc.
