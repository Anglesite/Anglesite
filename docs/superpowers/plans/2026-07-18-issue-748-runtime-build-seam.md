# Issue #748 — Runtime Build Seam Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the two capabilities [#748](https://github.com/Anglesite/Anglesite-app/issues/748) requires so [#744](https://github.com/Anglesite/Anglesite-app/issues/744) can later enforce dynamic/provider `.well-known` collisions: (1) a portable, non-secret `RuntimeOwnedPathClaim` type plus a `DeployExecutor` capability that reports zero of them by default, and (2) a substrate-neutral ephemeral build-command input/output seam that hands a `WellKnownClaimManifest` into the `.build` step and returns the observed artifact inventory/findings.

**Architecture:** Extend the existing `DeployExecutor` protocol (`Sources/AnglesiteCore/DeployExecutor.swift`) — the app's only "selected deployment runtime/provider" abstraction today — with two new requirements, each defaulting via a protocol extension to the safe "nothing implemented yet" answer (`[]` / `.unsupported`). `ContainerDeployExecutor` gets a real implementation of the build seam: it base64-encodes the manifest, passes it into the guest as a shell positional parameter (mirroring the existing `bundleUpload` injection-safe pattern), writes it to guest `/tmp` (never `/workspace/site`, which mirrors `Source/`), runs `npm run build` with two env vars pointing at the manifest/result paths, and parses a marker-delimited JSON result blob back out of stdout. `HostDeployExecutor` (production-retired) gets no override, so it correctly reports `.unsupported`. No existing deploy behavior changes — this is purely additive; nothing calls the new methods yet (that wiring is #744's job).

**Tech Stack:** Swift 6.4, Swift Testing (`@Suite`/`@Test`/`#expect`), `Codable`/`Sendable` value types, existing `LocalContainerControl`/`FakeLocalContainerControl` test doubles.

## Global Constraints

- Swift/SwiftUI with Apple frameworks only — no new third-party dependencies (none needed here).
- Process spawning stays centralized — this plan doesn't add new spawn call sites, it only changes the `argv`/environment handed to the existing `LocalContainerControl.exec` seam.
- Logs are sacred — the build seam must keep streaming guest stdout/stderr to `LogCenter` exactly as `run(step:...)` already does; the new method reuses the same drain pattern.
- Never copy raw `Config/`, credentials, tokens, or runtime bindings through the new seam — the manifest type has no field capable of holding any of those.
- Temporary data must never land inside `/workspace/site` (the guest's clone of `Source/`) — both the manifest and result files live under guest `/tmp`.
- Run `swift test --package-path .` before considering any task done, per `CONTRIBUTING.md`.

---

## File Structure

- **Create** `Sources/AnglesiteCore/WellKnownClaimManifest.swift` — the portable contract types (`RuntimeOwnedPathClaim`, `WellKnownClaimManifest`, `WellKnownBuildSeamResult`, `WellKnownBuildSeamOutcome`). One file, no logic beyond `Codable`/parsing — mirrors the style of `WorkerCatalog.swift`.
- **Modify** `Sources/AnglesiteCore/DeployExecutor.swift` — add the two new `DeployExecutor` protocol requirements + default extension, and `ContainerDeployExecutor`'s real seam implementation.
- **Create** `Tests/AnglesiteCoreTests/WellKnownClaimManifestTests.swift` — Codable round-trip tests for the new types.
- **Modify** `Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift` — add the seam's contract tests (argv/manifest transport, output round trip, malformed/missing result, unsupported, cancellation, cleanup trap).

---

### Task 1: Portable claim/manifest/result types

**Files:**
- Create: `Sources/AnglesiteCore/WellKnownClaimManifest.swift`
- Test: `Tests/AnglesiteCoreTests/WellKnownClaimManifestTests.swift`

**Interfaces:**
- Produces: `WellKnownPathMatch` (`.exact`/`.prefix`), `RuntimeOwnedPathClaim` (fields: `id: String`, `owner: String`, `path: String`, `match: WellKnownPathMatch`, `schemes: Set<Scheme>`, `port: Int?`, `capability: String`, `specificationURL: URL?`), `WellKnownClaimManifest` (field: `entries: [WellKnownClaimManifest.Entry]`, static `environmentVariableName`/`resultPathEnvironmentVariable`), `WellKnownBuildSeamResult` (fields: `observedArtifacts: [String]`, `findings: [Finding]`, static `parsing(_:) -> WellKnownBuildSeamResult`), `WellKnownBuildSeamOutcome` (`.unsupported` / `.cancelled` / `.completed(DeployStepResult, WellKnownBuildSeamResult)`). Task 2 and Task 3 consume all of these by exact name.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/WellKnownClaimManifestTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WellKnownClaimManifest contract types")
struct WellKnownClaimManifestTests {

    @Test("RuntimeOwnedPathClaim round-trips through JSON")
    func claimRoundTrips() throws {
        let claim = RuntimeOwnedPathClaim(
            id: "acme-managed-tls",
            owner: "cloudflare-managed-tls",
            path: "acme-challenge/",
            match: .prefix,
            schemes: [.http],
            port: 80,
            capability: "RFC 8555 managed-TLS ownership",
            specificationURL: URL(string: "https://www.rfc-editor.org/rfc/rfc8555.html"))
        let data = try JSONEncoder().encode(claim)
        let decoded = try JSONDecoder().decode(RuntimeOwnedPathClaim.self, from: data)
        #expect(decoded == claim)
    }

    @Test("empty WellKnownClaimManifest round-trips")
    func emptyManifestRoundTrips() throws {
        let manifest = WellKnownClaimManifest()
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(WellKnownClaimManifest.self, from: data)
        #expect(decoded == manifest)
        #expect(decoded.entries.isEmpty)
    }

    @Test("WellKnownClaimManifest with entries round-trips")
    func populatedManifestRoundTrips() throws {
        let manifest = WellKnownClaimManifest(entries: [
            .init(id: "security-txt", path: "security.txt", match: .exact, owner: "generator:security-txt"),
            .init(id: "acme", path: "acme-challenge/", match: .prefix, owner: "cloudflare-managed-tls")
        ])
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(WellKnownClaimManifest.self, from: data)
        #expect(decoded == manifest)
    }

    @Test("WellKnownBuildSeamResult parses a valid JSON blob")
    func seamResultParsesValidJSON() {
        let json = #"{"observedArtifacts":["security.txt"],"findings":[{"path":"security.txt","message":"ok"}]}"#
        let result = WellKnownBuildSeamResult.parsing(json)
        #expect(result.observedArtifacts == ["security.txt"])
        #expect(result.findings == [.init(path: "security.txt", message: "ok")])
    }

    @Test("WellKnownBuildSeamResult degrades to empty on malformed JSON")
    func seamResultDegradesOnMalformedJSON() {
        let result = WellKnownBuildSeamResult.parsing("not valid json")
        #expect(result == WellKnownBuildSeamResult())
    }

    @Test("WellKnownBuildSeamResult degrades to empty on an empty blob")
    func seamResultDegradesOnEmptyBlob() {
        let result = WellKnownBuildSeamResult.parsing("")
        #expect(result == WellKnownBuildSeamResult())
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter WellKnownClaimManifestTests`
Expected: FAIL to compile — `RuntimeOwnedPathClaim`, `WellKnownClaimManifest`, `WellKnownBuildSeamResult` don't exist yet.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/WellKnownClaimManifest.swift`:

```swift
import Foundation

// See docs/superpowers/specs/2026-07-14-well-known-support-design.md — #748 owns this ephemeral,
// non-secret contract so a runtime/provider can report affirmatively-owned `.well-known` paths
// (e.g. ACME managed-TLS) and so a build step can receive a derived claim manifest and report
// back what it observed on disk. #744 assembles the full inventory and consumes this contract;
// it must not duplicate it.

/// Whether a claim matches one exact path or every path under a prefix.
public enum WellKnownPathMatch: String, Sendable, Codable, Equatable {
    case exact
    case prefix
}

/// A portable, non-secret claim that a deploy provider or runtime affirmatively owns a
/// `.well-known` path — e.g. a hosting provider's managed-TLS ACME challenge handler. Never
/// carries credentials, tokens, or runtime bindings.
public struct RuntimeOwnedPathClaim: Sendable, Codable, Equatable, Identifiable {
    public enum Scheme: String, Sendable, Codable, Equatable {
        case http
        case https
    }

    /// Stable identifier for this claim, unique within one provider's report.
    public var id: String
    /// Stable identifier of the owning provider or runtime, e.g. `"cloudflare-managed-tls"`.
    public var owner: String
    /// The `.well-known` path segment (or prefix) this claim covers, no leading slash.
    public var path: String
    public var match: WellKnownPathMatch
    /// Schemes this claim applies under.
    public var schemes: Set<Scheme>
    /// Port this claim applies to, or `nil` for the scheme's default port.
    public var port: Int?
    /// Human-readable capability/provenance description, e.g. "RFC 8555 managed-TLS ownership".
    public var capability: String
    public var specificationURL: URL?

    public init(
        id: String,
        owner: String,
        path: String,
        match: WellKnownPathMatch,
        schemes: Set<Scheme> = [.https],
        port: Int? = nil,
        capability: String,
        specificationURL: URL? = nil
    ) {
        self.id = id
        self.owner = owner
        self.path = path
        self.match = match
        self.schemes = schemes
        self.port = port
        self.capability = capability
        self.specificationURL = specificationURL
    }
}

/// The ephemeral, non-secret manifest the app/deploy orchestrator derives (from #744's full
/// inventory) and hands to a runtime's build step. Only the fields a runtime needs to detect a
/// fresh on-disk collision cross this seam — never raw site settings or credentials.
public struct WellKnownClaimManifest: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable, Identifiable {
        public var id: String
        public var path: String
        public var match: WellKnownPathMatch
        public var owner: String

        public init(id: String, path: String, match: WellKnownPathMatch, owner: String) {
            self.id = id
            self.path = path
            self.match = match
            self.owner = owner
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Guest-visible env var whose value is the guest filesystem path where this manifest's
    /// JSON was written. Substrate-neutral by name — any future runtime conformer should expose
    /// the manifest to its build step under this same variable, whatever its transport mechanism.
    public static let environmentVariableName = "ANGLESITE_WELLKNOWN_CLAIM_MANIFEST"

    /// Guest-visible env var whose value is the guest filesystem path a build step should write
    /// its `WellKnownBuildSeamResult` JSON to before exiting.
    public static let resultPathEnvironmentVariable = "ANGLESITE_WELLKNOWN_RESULT_PATH"
}

/// What a build step observed on disk after receiving a `WellKnownClaimManifest`.
public struct WellKnownBuildSeamResult: Sendable, Codable, Equatable {
    public struct Finding: Sendable, Codable, Equatable {
        public var path: String?
        public var message: String

        public init(path: String? = nil, message: String) {
            self.path = path
            self.message = message
        }
    }

    /// Relative `dist/.well-known/...` paths the build actually produced.
    public var observedArtifacts: [String]
    public var findings: [Finding]

    public init(observedArtifacts: [String] = [], findings: [Finding] = []) {
        self.observedArtifacts = observedArtifacts
        self.findings = findings
    }

    /// Parses the JSON blob a build step returns after the result marker. Never throws — an
    /// absent or malformed blob degrades to an empty result rather than failing the build step,
    /// per #748's "malformed results" contract requirement.
    public static func parsing(_ json: String) -> WellKnownBuildSeamResult {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let result = try? JSONDecoder().decode(WellKnownBuildSeamResult.self, from: data)
        else {
            return WellKnownBuildSeamResult()
        }
        return result
    }
}

/// The outcome of asking a `DeployExecutor` to run the build step with a claim manifest.
public enum WellKnownBuildSeamOutcome: Sendable, Equatable {
    /// This executor does not implement the seam — callers must not claim cross-owner collision
    /// protection when they receive this case.
    case unsupported
    /// The build was cancelled before it produced a result.
    case cancelled
    case completed(DeployStepResult, WellKnownBuildSeamResult)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter WellKnownClaimManifestTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WellKnownClaimManifest.swift Tests/AnglesiteCoreTests/WellKnownClaimManifestTests.swift
git commit -m "feat(core): add WellKnownClaimManifest contract types (#748)"
```

---

### Task 2: `DeployExecutor` capability requirements + safe defaults

**Files:**
- Modify: `Sources/AnglesiteCore/DeployExecutor.swift:47-54` (the `DeployExecutor` protocol declaration)
- Test: `Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift` (new test group appended)

**Interfaces:**
- Consumes: `RuntimeOwnedPathClaim`, `WellKnownClaimManifest`, `WellKnownBuildSeamOutcome` from Task 1.
- Produces: `DeployExecutor.reportOwnedPathClaims() async -> [RuntimeOwnedPathClaim]` (default `[]`) and `DeployExecutor.runBuildWithClaimManifest(siteDirectory:environment:source:claimManifest:) async -> WellKnownBuildSeamOutcome` (default `.unsupported`) — both callable on `HostDeployExecutor`, `ContainerDeployExecutor`, and any future conformer without their own override. Task 3 overrides the second one on `ContainerDeployExecutor`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift`, inside `struct ContainerDeployExecutorTests`, right after the `siteIDForwarded` test (before the closing `}` of the struct):

```swift

    // MARK: - #748 capability defaults

    @Test("HostDeployExecutor reports no owned path claims by default")
    func hostExecutorReportsNoOwnedClaims() async {
        let executor = HostDeployExecutor()
        let claims = await executor.reportOwnedPathClaims()
        #expect(claims.isEmpty)
    }

    @Test("HostDeployExecutor's build seam is unsupported by default")
    func hostExecutorSeamIsUnsupported() async {
        let executor = HostDeployExecutor()
        let outcome = await executor.runBuildWithClaimManifest(
            siteDirectory: URL(fileURLWithPath: "/host/irrelevant"),
            environment: [:],
            source: "src",
            claimManifest: WellKnownClaimManifest()
        )
        #expect(outcome == .unsupported)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter ContainerDeployExecutorTests`
Expected: FAIL to compile — `reportOwnedPathClaims()` and `runBuildWithClaimManifest(...)` are not members of `DeployExecutor`/`HostDeployExecutor` yet.

- [ ] **Step 3: Extend the protocol**

Edit `Sources/AnglesiteCore/DeployExecutor.swift`, replacing the existing protocol block (lines 47-54):

```swift
public protocol DeployExecutor: Sendable {
    func run(
        step: DeployStep,
        siteDirectory: URL,
        environment: [String: String],
        source: String
    ) async -> DeployStepResult

    /// Paths this deploy provider affirmatively owns (e.g. ACME managed-TLS challenge paths) —
    /// see docs/superpowers/specs/2026-07-14-well-known-support-design.md. Defaults to no claims;
    /// override only when this executor can prove ownership, never speculatively.
    func reportOwnedPathClaims() async -> [RuntimeOwnedPathClaim]

    /// Runs the `.build` step with `claimManifest` made available to the build, returning the
    /// observed `.well-known` artifact inventory and findings alongside the normal step result.
    /// Defaults to `.unsupported` — #744 must not claim cross-owner collision protection when
    /// this returns `.unsupported`.
    func runBuildWithClaimManifest(
        siteDirectory: URL,
        environment: [String: String],
        source: String,
        claimManifest: WellKnownClaimManifest
    ) async -> WellKnownBuildSeamOutcome
}

public extension DeployExecutor {
    func reportOwnedPathClaims() async -> [RuntimeOwnedPathClaim] { [] }

    func runBuildWithClaimManifest(
        siteDirectory: URL,
        environment: [String: String],
        source: String,
        claimManifest: WellKnownClaimManifest
    ) async -> WellKnownBuildSeamOutcome {
        .unsupported
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ContainerDeployExecutorTests`
Expected: PASS — the two new tests pass (`HostDeployExecutor` gets both defaults through the protocol extension), all prior `ContainerDeployExecutorTests` cases still pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployExecutor.swift Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift
git commit -m "feat(core): add DeployExecutor ownership-claim and build-seam capabilities (#748)"
```

---

### Task 3: `ContainerDeployExecutor`'s real build seam

**Files:**
- Modify: `Sources/AnglesiteCore/DeployExecutor.swift` (inside `public struct ContainerDeployExecutor`, immediately after the closing brace of `run(step:...)`, currently ending at line 147, and before the `guestEnvAllowlist` doc comment currently at line 149)
- Test: `Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift` (new test group appended)

**Interfaces:**
- Consumes: `WellKnownClaimManifest`, `WellKnownBuildSeamOutcome`, `WellKnownBuildSeamResult` (Task 1); `ContainerDeployExecutor`'s existing private `control`/`siteID`/`logCenter` fields and `Self.guestEnvironment(from:)` helper (already defined in this struct).
- Produces: `ContainerDeployExecutor.runBuildWithClaimManifest(...)` (overrides the Task 2 default), `ContainerDeployExecutor.wellKnownSeamArgv(manifestBase64:) -> [String]` (`static func`, package-internal — exposed to tests the same way `guestArgv` already is via `ContainerDeployExecutorTestHook`), and three `static let` constants: `wellKnownResultMarker`, `wellKnownManifestGuestPath`, `wellKnownResultGuestPath`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift`, inside `struct ContainerDeployExecutorTests`, after the Task 2 tests:

```swift

    // MARK: - #748 build seam: manifest transport in

    @Test("build seam writes the manifest to guest /tmp, never /workspace/site, via a positional-parameter shell script")
    func seamArgvUsesInjectionSafePositionalParameter() async {
        let fake = fakePassing()
        let executor = makeExecutor(fake: fake)
        let manifest = WellKnownClaimManifest(entries: [
            .init(id: "acme", path: "acme-challenge/", match: .prefix, owner: "cloudflare-managed-tls")
        ])
        _ = await executor.runBuildWithClaimManifest(
            siteDirectory: URL(fileURLWithPath: "/host/irrelevant"),
            environment: [:],
            source: "src",
            claimManifest: manifest
        )
        let calls = await fake.execCalls
        #expect(calls.count == 1)
        let argv = calls[0].argv
        #expect(argv.count == 5)
        #expect(argv[0] == "sh")
        #expect(argv[1] == "-c")
        #expect(argv[3] == "sh")
        // The script must reference the guest manifest/result paths and the env vars a future
        // build script reads, and must never touch /workspace/site for the manifest itself.
        let script = argv[2]
        #expect(script.contains("/tmp/anglesite-wellknown-manifest.json"))
        #expect(!script.contains("/workspace/site/anglesite-wellknown"))
        #expect(script.contains(WellKnownClaimManifest.environmentVariableName))
        #expect(script.contains(WellKnownClaimManifest.resultPathEnvironmentVariable))
        #expect(script.contains("npm run build"))
        // Cleanup trap covers cancellation/failure per #748's cleanup requirement.
        #expect(script.contains("trap"))
        #expect(script.contains("EXIT INT TERM"))
        // The manifest payload itself travels as $1, a positional parameter — never spliced into
        // the script string — mirroring the existing bundleUpload injection-safety pattern.
        let manifestBase64 = argv[4]
        let decodedData = try? Data(base64Encoded: manifestBase64, options: .ignoreUnknownCharacters).map { $0 }
        #expect(decodedData != nil)
        let decodedManifest = decodedData.flatMap { try? JSONDecoder().decode(WellKnownClaimManifest.self, from: $0) }
        #expect(decodedManifest == manifest)
    }

    @Test("build seam round-trips an empty manifest")
    func seamRoundTripsEmptyManifest() async {
        let fake = fakePassing()
        let executor = makeExecutor(fake: fake)
        _ = await executor.runBuildWithClaimManifest(
            siteDirectory: URL(fileURLWithPath: "/host"),
            environment: [:],
            source: "src",
            claimManifest: WellKnownClaimManifest()
        )
        let argv = await fake.execCalls[0].argv
        let decoded = Data(base64Encoded: argv[4], options: .ignoreUnknownCharacters)
            .flatMap { try? JSONDecoder().decode(WellKnownClaimManifest.self, from: $0) }
        #expect(decoded == WellKnownClaimManifest())
    }

    // MARK: - #748 build seam: output round trip

    @Test("build seam parses the marker-delimited result blob out of stdout")
    func seamParsesResultBlob() async {
        let fake = FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(
                exitCode: 0,
                stdout: """
                building...
                done
                ---ANGLESITE-WELLKNOWN-RESULT---
                {"observedArtifacts":["security.txt"],"findings":[]}
                """,
                stderr: ""
            )
        )
        let executor = makeExecutor(fake: fake)
        let outcome = await executor.runBuildWithClaimManifest(
            siteDirectory: URL(fileURLWithPath: "/host"),
            environment: [:],
            source: "src",
            claimManifest: WellKnownClaimManifest()
        )
        guard case .completed(let stepResult, let seamResult) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(stepResult.exitCode == 0)
        #expect(stepResult.output == "building...\ndone")
        #expect(seamResult.observedArtifacts == ["security.txt"])
        #expect(seamResult.findings.isEmpty)
    }

    @Test("build seam degrades to an empty result when the marker is missing entirely")
    func seamDegradesWhenMarkerMissing() async {
        let fake = FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(exitCode: 0, stdout: "plain build output, no seam marker", stderr: "")
        )
        let executor = makeExecutor(fake: fake)
        let outcome = await executor.runBuildWithClaimManifest(
            siteDirectory: URL(fileURLWithPath: "/host"),
            environment: [:],
            source: "src",
            claimManifest: WellKnownClaimManifest()
        )
        guard case .completed(let stepResult, let seamResult) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(stepResult.output == "plain build output, no seam marker")
        #expect(seamResult == WellKnownBuildSeamResult())
    }

    @Test("build seam degrades to an empty result when the blob after the marker is malformed")
    func seamDegradesOnMalformedBlob() async {
        let fake = FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(
                exitCode: 1,
                stdout: "build failed\n---ANGLESITE-WELLKNOWN-RESULT---\nnot json at all",
                stderr: ""
            )
        )
        let executor = makeExecutor(fake: fake)
        let outcome = await executor.runBuildWithClaimManifest(
            siteDirectory: URL(fileURLWithPath: "/host"),
            environment: [:],
            source: "src",
            claimManifest: WellKnownClaimManifest()
        )
        guard case .completed(let stepResult, let seamResult) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(stepResult.exitCode == 1)
        #expect(stepResult.output == "build failed")
        #expect(seamResult == WellKnownBuildSeamResult())
    }

    // MARK: - #748 build seam: cancellation

    @Test("a cancelled build seam resolves as .cancelled, not a hang")
    func seamCancellationResolves() async {
        let fake = CancelParkingFakeContainerControl()
        let executor = ContainerDeployExecutor(control: fake, siteID: "s", logCenter: LogCenter())

        let task = Task {
            await executor.runBuildWithClaimManifest(
                siteDirectory: URL(fileURLWithPath: "/host"),
                environment: [:],
                source: "src",
                claimManifest: WellKnownClaimManifest()
            )
        }
        await fake.waitUntilParked()
        task.cancel()

        let outcome = await task.value
        #expect(outcome == .cancelled)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter ContainerDeployExecutorTests`
Expected: FAIL to compile — `ContainerDeployExecutor` has no `runBuildWithClaimManifest` override yet (it's currently only inherited from Task 2's default, which returns `.unsupported` unconditionally, so even once it compiles these new tests would fail their `.completed`/argv assertions until Step 3 lands).

- [ ] **Step 3: Implement the real seam**

Edit `Sources/AnglesiteCore/DeployExecutor.swift`. Insert the following immediately after the closing brace of `run(step:...)` (currently line 147) and before the `/// DeployCommand hands every step...` doc comment for `guestEnvAllowlist` (currently line 149), inside `public struct ContainerDeployExecutor`:

```swift

    // MARK: Well-known claim manifest seam (#748)

    /// Marks the boundary in `.build` stdout between ordinary build output and the seam's JSON
    /// result blob. Any future template-side consumer (#744) must echo this exact line.
    static let wellKnownResultMarker = "---ANGLESITE-WELLKNOWN-RESULT---"
    /// Guest-side scratch path for the incoming manifest — deliberately under `/tmp`, never
    /// `/workspace/site` (the guest's clone of `Source/`).
    static let wellKnownManifestGuestPath = "/tmp/anglesite-wellknown-manifest.json"
    /// Guest-side scratch path a future build script writes its result JSON to — also `/tmp`,
    /// for the same "never inside Source/" reason.
    static let wellKnownResultGuestPath = "/tmp/anglesite-wellknown-result.json"

    public func runBuildWithClaimManifest(
        siteDirectory: URL,
        environment: [String: String],
        source: String,
        claimManifest: WellKnownClaimManifest
    ) async -> WellKnownBuildSeamOutcome {
        guard let manifestData = try? JSONEncoder().encode(claimManifest) else {
            return .completed(
                DeployStepResult(exitCode: nil, output: "couldn't encode well-known claim manifest"),
                WellKnownBuildSeamResult())
        }
        let argv = Self.wellKnownSeamArgv(manifestBase64: manifestData.base64EncodedString())

        let (lines, continuation) = AsyncStream<(String, LogCenter.Stream)>.makeStream(bufferingPolicy: .unbounded)
        let logCenter = self.logCenter
        let drain = Task.detached(priority: .utility) {
            for await (line, stream) in lines {
                await logCenter.append(source: source, stream: stream, text: line)
            }
        }
        let result: ContainerExecResult
        do {
            result = try await control.exec(
                siteID: siteID,
                argv: argv,
                environment: Self.guestEnvironment(from: environment),
                workingDirectory: "/workspace/site",
                onOutput: { line, stream in continuation.yield((line, stream)) }
            )
        } catch is CancellationError {
            continuation.finish()
            _ = await drain.value
            return .cancelled
        } catch {
            continuation.finish()
            _ = await drain.value
            return .completed(
                DeployStepResult(exitCode: nil, output: "couldn't exec in the container: \(error)"),
                WellKnownBuildSeamResult())
        }
        continuation.finish()
        _ = await drain.value

        let outputLines = result.stdout.components(separatedBy: "\n")
        let seamResult: WellKnownBuildSeamResult
        let buildOutput: String
        if let markerIndex = outputLines.firstIndex(of: Self.wellKnownResultMarker) {
            buildOutput = outputLines[..<markerIndex].joined(separator: "\n")
            seamResult = .parsing(outputLines[(markerIndex + 1)...].joined(separator: "\n"))
        } else {
            buildOutput = result.stdout
            seamResult = WellKnownBuildSeamResult()
        }
        return .completed(DeployStepResult(exitCode: result.exitCode, output: buildOutput), seamResult)
    }

    /// Builds the guest shell command that: (1) writes the base64-decoded manifest to
    /// `/tmp` — passed as `$1`, a positional parameter, never spliced into the script string,
    /// mirroring `guestArgv`'s `.bundleUpload` injection-safety pattern; (2) runs `npm run build`
    /// with both #748 env vars pointed at their `/tmp` paths; (3) echoes the result marker plus
    /// whatever the build wrote to the result path; and (4) traps EXIT/INT/TERM to remove both
    /// `/tmp` scratch files on every path this shell can gracefully reach (a hard-killed guest
    /// process's `/tmp` is still disposed of when its ephemeral VM is next torn down or rebooted).
    static func wellKnownSeamArgv(manifestBase64: String) -> [String] {
        let script = """
        trap 'rm -f \(wellKnownManifestGuestPath) \(wellKnownResultGuestPath)' EXIT INT TERM
        printf '%s' "$1" | base64 -d > \(wellKnownManifestGuestPath)
        \(WellKnownClaimManifest.environmentVariableName)=\(wellKnownManifestGuestPath) \
        \(WellKnownClaimManifest.resultPathEnvironmentVariable)=\(wellKnownResultGuestPath) npm run build
        code=$?
        echo "\(wellKnownResultMarker)"
        cat \(wellKnownResultGuestPath) 2>/dev/null || true
        exit $code
        """
        return ["sh", "-c", script, "sh", manifestBase64]
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ContainerDeployExecutorTests`
Expected: PASS — all seam tests plus every pre-existing `ContainerDeployExecutorTests` case.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployExecutor.swift Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift
git commit -m "feat(core): implement ContainerDeployExecutor's well-known claim manifest seam (#748)"
```

---

### Task 4: Full verification pass

**Files:** none (verification only).

- [ ] **Step 1: Run the full Swift package test suite**

Run: `swift test --package-path .`
Expected: PASS, no regressions in any other suite (in particular `DeployExecutorSelectionTests`, `LocalContainerSiteRuntimeTests`, which exercise the same file's neighboring types).

- [ ] **Step 2: Build the app target**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`

If `Anglesite.xcodeproj` doesn't exist yet in this worktree, run `xcodegen generate` first (per `CLAUDE.md`'s worktree guidance), then retry the build.

Expected: BUILD SUCCEEDED — this task adds no `AnglesiteApp`-layer code, so this is a regression check only (`AnglesiteCore` still links cleanly into the app target).

- [ ] **Step 3: Re-check CONTRIBUTING.md's PR checklist**

Confirm: conventional commit messages reference `#748`; no `Resources/Template/` files touched (so no extra `swift test` coupling risk beyond what Task 4 Step 1 already covers); no new dependency added; nothing in this change touches the MCP message schema or plugin skills, so **no paired PR** in `Anglesite/anglesite` is needed.

---

## Self-Review

**1. Spec coverage** — every #748 scope bullet maps to a task:
- "portable, non-secret runtime/provider ownership claim" → Task 1 (`RuntimeOwnedPathClaim`).
- "explicit deploy-provider capability... default is no claims" → Task 2 (`reportOwnedPathClaims`).
- "ACME... only when the selected provider/runtime affirmatively reports managed-TLS ownership" → satisfied by construction: no conformer overrides the default, so no claim exists until a future issue adds a real Cloudflare-specific check (explicitly out of scope for #748 per the design doc's "future work" framing).
- "substrate-neutral ephemeral build-command input/output seam... local container, remote sandbox, LAN/other applicable runtime paths, and unavailable" → the seam lives on `DeployExecutor` itself with a `.unsupported` default (Task 2), so it's automatically neutral across every current and future conformer; `ContainerDeployExecutor` gets the one real implementation that exists today (Task 3), matching the memory note that remote-sandbox/LAN have no `DeployExecutor` conformer yet.
- "Transport the manifest into temporary runtime storage outside Source/" → Task 3's guest paths are both under `/tmp`, never `/workspace/site`.
- "Return the observed artifact inventory and structured findings" → `WellKnownBuildSeamResult` (Task 1) + the marker-parsing in Task 3.
- "Never copy raw Config/, credentials, tokens, or runtime bindings" → the manifest type has no such field; `environment` handling is unchanged from the existing `run()` allowlist.
- "Clean temporary inputs on success, cancellation, restart, and failure" → the `trap ... EXIT INT TERM` in Task 3; documented SIGKILL caveat.
- "Expose unsupported/failure state explicitly" → `.unsupported`/`.cancelled` cases (Task 1/2/3).
- Testing bullets (empty claims, ACME-like prefix claims, round trips, unsupported runtimes, malformed results, cancellation, cleanup) → covered one-for-one across Task 1's and Task 3's test lists.

**2. Placeholder scan** — no TBD/TODO markers; every step has complete, runnable code; no "similar to Task N" references.

**3. Type consistency** — `RuntimeOwnedPathClaim`, `WellKnownClaimManifest`, `WellKnownClaimManifest.Entry`, `WellKnownBuildSeamResult`, `WellKnownBuildSeamResult.Finding`, and `WellKnownBuildSeamOutcome` are defined once in Task 1 and referenced identically (same names, same field names) in Task 2's and Task 3's signatures and tests.
