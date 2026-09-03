# Anywhere Runtime P1 — Mac Helper Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `Anglesite Remote.app` — a faceless (`LSUIElement`) helper, registered as a login item via `SMAppService.agent` and embedded in the main app's bundle, that boots a site's container on demand and bridges it over the P0 `AnglesiteP2P` transport core (file signaling, matching P0's own E2E harness — CloudKit signaling is P2) — proven by a second Mac process editing a site with the main `Anglesite.app` never launched.

**Architecture:** The helper reuses every P0 `AnglesiteP2P` type unchanged (`WebRTCPeer`, `FileSignalingChannel`, `FetchBridgeServer`, `MCPChannelResponder`, `ControlHeartbeat`) and adds only the host-side glue P0 explicitly deferred to P1: real `HTTPExecutor`/MCP-bridge conformers that replay against a booted container's loopback ports (P0 shipped `DirectoryHTTPExecutor`, a static-file stand-in, for its own tests only), a cross-process "who owns this site's container right now" registry, and the container boot + site-access plumbing. Epic: [#1208](https://github.com/Anglesite/Anglesite/issues/1208); spec: `docs/superpowers/specs/2026-08-03-anywhere-runtime-webrtc-design.md` §Architecture 2 and 5.

**Tech Stack:** Swift 6.4 / Xcode 27, SwiftPM + XcodeGen (`project.yml`), Swift Testing, `AnglesiteP2P` (P0, already vendored), `AnglesiteCore` (`LocalContainerControl`, `HTTPTransport`, `SiteStore`, `SecurityScopedBookmarking`), `AnglesiteContainer` (`ContainerizationControl`), `ServiceManagement` (`SMAppService`, Darwin-only, macOS 13+).

## Global Constraints

- `swift test` needs `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` on the owner's machine (CommandLineTools swift is too old).
- Every new target gets `swiftSettings: strictConcurrency` like its siblings in `Package.swift`.
- Conformers of `MCPTransport`/`P2PConnection`-adjacent actors follow the existing actor-per-conformer pattern already used throughout `AnglesiteP2P`.
- New public API needs `///` doc comments per `docs/comment-style-guide.md` (CI fails on broken DocC links).
- Commit subjects ≤72 chars, conventional-commit format, reference #1208.
- Tests are Swift Testing (`@Test`, `#expect`), not XCTest.
- **This plan amends the "`Anglesite` is the only app target" invariant** in `CLAUDE.md`/`AGENTS.md` ▸ "Build target" — Task 1 updates that doc alongside the code, per the spec's explicit requirement (design spec line 50).
- **App Groups is a real capability gap, not a code gap.** The spec's "app publishes its live proxy ports in app-group state" (design spec line 66) and any helper read of the main app's iCloud-stored site catalog both need a `com.apple.security.application-groups` entitlement on *both* bundle IDs (`io.dwk.anglesite` and the new helper ID), which requires enabling the App Groups capability for both App IDs in the Apple Developer portal (Team `M34HBJZNYA`, which holds the paid Developer Program membership App Groups requires) and regenerating provisioning profiles — an owner action this plan cannot perform, mirroring #66's Workers-Paid-plan blocker. Every task below is designed so its Swift code and tests work against an **injected directory URL seam**, never a hardcoded app-group container path, so nothing in this plan blocks on that portal step — only the *production* wiring (Task 6, Step 5) needs it, and is called out there.
- **P1 does not solve cross-sandbox site discovery.** The phone/CloudKit-driven "which site does the owner want" flow is P2+ (real pairing) territory. P1's session entry point takes the target site's `Source/` directory as an explicit argument (CLI arg for the exit-criterion harness; a `control`-channel `hello` payload field in the real flow) — matching how P0's own `anglesite-p2p-demo` took `<site-root>` as an argument rather than solving discovery.
- Code lands on a new branch `feat/1208-p1-mac-helper` cut from `main` in a fresh worktree (`.claude/worktrees/1208-p1-helper/`). Run `xcodegen generate` there once initially, and again after every `project.yml` edit (Task 1) — repo convention.
- Run `scripts/check-xcodeproj-sync.sh` after any `project.yml` change — CI's `xcodeproj-sync` job fails the same way locally.

## File Structure

```
Sources/AnglesiteRemote/                  # new SwiftPM target — the helper's implementation, kept
  RemoteSessionRegistry.swift             # separate from Sources/anglesite-remote-helper/main.swift
  RemoteContainerSession.swift            # so it's unit-testable without a built app bundle.
  LoopbackHTTPExecutor.swift
  LoopbackMCPBridge.swift
  RemoteSiteResolver.swift
  LoginItemRegistering.swift
Sources/anglesite-remote-helper/
  main.swift                              # thin executable: wires the above + AnglesiteP2P together
Tests/AnglesiteRemoteTests/
  RemoteSessionRegistryTests.swift
  LoopbackHTTPExecutorTests.swift
  LoopbackMCPBridgeTests.swift
  RemoteSiteResolverTests.swift
  RemoteContainerSessionTests.swift
  HelperContainerE2ETests.swift           # gated ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1
                                           #   ANGLESITE_P2P_E2E=1 — the P1 exit criterion
Resources/AnglesiteRemote.entitlements    # new
Resources/AnglesiteRemote-Info.plist      # new (LSUIElement)
project.yml                               # + AnglesiteRemote target, embedded in Anglesite's
                                           #   Contents/Library/LoginItems/
scripts/check-xcodeproj-sync.sh           # + AnglesiteRemote in SOURCES_ROOTS
CLAUDE.md / AGENTS.md                     # ▸ "Build target" — amend the "only app target" line
```

Out of P1 scope (explicitly deferred): CloudKit signaling + QR pairing + key pinning (P2), TURN (P3), the iOS client (P4), publish-from-phone (P5). The helper's `control`-channel deploy-request handling is a P5 concern; P1's `ControlHeartbeat` runs but nothing consumes `.deployRequest`.

---

### Task 1: `AnglesiteRemote` target scaffolding + doc amendment

**Files:**
- Modify: `project.yml` (new `AnglesiteRemote` target + embed into `Anglesite`'s dependencies)
- Modify: `scripts/check-xcodeproj-sync.sh` (`SOURCES_ROOTS` dict)
- Modify: `CLAUDE.md`, `AGENTS.md` ▸ "Build target"
- Create: `Resources/AnglesiteRemote.entitlements`, `Resources/AnglesiteRemote-Info.plist`
- Create: `Sources/AnglesiteRemote/LoginItemRegistering.swift`
- Create: `Sources/anglesite-remote-helper/main.swift` (placeholder body for this task; Task 7 fills it in)
- Test: `Tests/AnglesiteRemoteTests/LoginItemRegisteringTests.swift`

**Interfaces:**
- Produces: `LoginItemRegistering` protocol + `SMAppServiceLoginItem` conformer + `FakeLoginItemRegistering` test double — every later task's `main.swift` calls this, nothing else in this task depends on other tasks.

- [ ] **Step 1: Write `Resources/AnglesiteRemote-Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Anglesite Remote</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <!-- Faceless: no Dock icon, no menu bar, no windows unless explicitly opened. -->
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <!-- iCloud Drive "Anglesite" folder — must match Anglesite.app's entry exactly (see
         AppSettings.ubiquityContainerIdentifier, Sources/AnglesiteCore/AppSettings.swift). -->
    <key>NSUbiquitousContainers</key>
    <dict>
        <key>iCloud.io.dwk.anglesite</key>
        <dict>
            <key>NSUbiquitousContainerIsDocumentScopePublic</key>
            <true/>
            <key>NSUbiquitousContainerSupportedFolderLevels</key>
            <string>Any</string>
        </dict>
    </dict>
</dict>
</plist>
```

- [ ] **Step 2: Write `Resources/AnglesiteRemote.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <!-- Bridges P2P channels to the container's loopback proxies, and (eventually) accepts
         inbound WebRTC ICE hole-punch traffic — see design spec §2 "no standing listening ports"
         (ICE binds ephemeral ports; that's not a stable inbound service). -->
    <key>com.apple.security.network.server</key>
    <true/>
    <!-- Own bookmark store for non-iCloud sites (design spec §2 "File access") — the main app's
         bookmarks are app-scoped and don't transfer to this bundle ID. -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>
    <!-- Apple Containerization framework (#69): boot local OCI containers, same as Anglesite.app. -->
    <key>com.apple.security.virtualization</key>
    <true/>
    <!-- NO com.apple.developer.icloud-container-identifiers and NO
         com.apple.security.application-groups here yet — both require a provisioning profile
         even under ad-hoc/Manual signing (see Resources/Anglesite-Debug.entitlements' identical
         note re: #1038). Task 6 Step 5 documents the manual Apple Developer portal step that
         unblocks adding them; until then this file matches the CI-safe, no-Team-required shape
         every other Debug entitlements file in this repo keeps. -->
</dict>
</plist>
```

- [ ] **Step 3: Add the `AnglesiteRemote` target to `project.yml`**

Add near the end of `targets:`, after `AnglesiteMobile`:

```yaml
  # Anywhere runtime (#1208 P1): faceless helper, login item via SMAppService.agent, embedded
  # inside Anglesite.app so one install covers both. No Dock icon, no windows (LSUIElement).
  AnglesiteRemote:
    type: application
    platform: macOS
    sources:
      - path: Sources/AnglesiteRemote
      - path: Sources/anglesite-remote-helper
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.dwk.anglesite.remote
        PRODUCT_NAME: "Anglesite Remote"
        INFOPLIST_FILE: Resources/AnglesiteRemote-Info.plist
        GENERATE_INFOPLIST_FILE: NO
        CODE_SIGN_ENTITLEMENTS: Resources/AnglesiteRemote.entitlements
        ENABLE_HARDENED_RUNTIME: YES
        MACOSX_DEPLOYMENT_TARGET: "27.0"
        SWIFT_VERSION: "5.10"
        CURRENT_PROJECT_VERSION: 1
        MARKETING_VERSION: "0.1.0"
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) ANGLESITE_MAS"
        SKIP_INSTALL: YES
        # Embedded helper apps live under the parent's Contents/Library/LoginItems/ —
        # SMAppService.agent's documented discovery location.
      configs:
        Release:
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Apple Distribution"
    dependencies:
      - package: Anglesite
        product: AnglesiteCore
      - package: Anglesite
        product: AnglesiteContainer
      - package: Anglesite
        product: AnglesiteP2P
```

Then, inside the existing `Anglesite:` target's `dependencies:` list (`project.yml`, alongside the `AnglesiteQuickLookPreview`/`AnglesiteQuickLookThumbnail` `embed: true` entries), add:

```yaml
      - target: AnglesiteRemote
        embed: true
        codeSign: true
        buildPhase:
          copyFiles:
            destination: wrapper
            subpath: Contents/Library/LoginItems
```

XcodeGen's `copyFiles.destination: wrapper` + `subpath:` is the documented mechanism for placing a dependency at an arbitrary path inside the host bundle (the QuickLook extensions use the shorthand `embed: true` alone because `PlugIns/` is their product type's *default* destination; an application embedded as a login item has no such default, hence the explicit `buildPhase`).

- [ ] **Step 4: Add `AnglesiteRemote` to `scripts/check-xcodeproj-sync.sh`'s `SOURCES_ROOTS`**

Find the `SOURCES_ROOTS` dict (mirrors `"Anglesite": "Sources/AnglesiteApp"`) and add:

```python
    "AnglesiteRemote": "Sources/AnglesiteRemote",
```

- [ ] **Step 5: `LoginItemRegistering` seam**

`Sources/AnglesiteRemote/LoginItemRegistering.swift`:

```swift
import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// Registers (or unregisters) this helper as a login item. Abstracted so tests exercise the
/// decision logic without touching the real login-item database (`SMAppService` has no
/// in-memory test mode and mutates real system state).
public protocol LoginItemRegistering: Sendable {
    /// Current registration status.
    func status() -> LoginItemStatus
    /// Registers the login item. Idempotent: calling this when already `.enabled` is a no-op.
    func register() throws
    /// Unregisters the login item.
    func unregister() throws
}

/// Mirrors `SMAppService.Status`'s cases relevant to this helper's startup decision, without
/// exposing the real enum (keeps this file compilable on non-Darwin per `Package.swift`'s
/// existing platform-gating pattern for Darwin-only targets).
public enum LoginItemStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

#if canImport(ServiceManagement)
/// Production conformer over `SMAppService.agent`.
public struct SMAppServiceLoginItem: LoginItemRegistering {
    private let service: SMAppService

    /// - Parameter plistName: The launchd agent plist name registered under this bundle's
    ///   `Contents/Library/LaunchAgents/` (SMAppService.agent's documented convention).
    public init(plistName: String = "io.dwk.anglesite.remote.plist") {
        self.service = SMAppService.agent(plistName: plistName)
    }

    public func status() -> LoginItemStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public func register() throws {
        guard status() != .enabled else { return }
        try service.register()
    }

    public func unregister() throws {
        try service.unregister()
    }
}
#endif

/// Test double: in-memory status, no system calls.
public final class FakeLoginItemRegistering: LoginItemRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: LoginItemStatus
    public private(set) var registerCallCount = 0
    public private(set) var unregisterCallCount = 0

    public init(initialStatus: LoginItemStatus = .notRegistered) {
        self._status = initialStatus
    }

    public func status() -> LoginItemStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    public func register() throws {
        lock.lock(); defer { lock.unlock() }
        registerCallCount += 1
        _status = .enabled
    }

    public func unregister() throws {
        lock.lock(); defer { lock.unlock() }
        unregisterCallCount += 1
        _status = .notRegistered
    }
}
```

Note: `SMAppService.agent(plistName:)` also requires a matching `Contents/Library/LaunchAgents/io.dwk.anglesite.remote.plist` launchd property list bundled into `AnglesiteRemote.app`, declaring `Label` + `BundleProgram` (pointing at the embedded helper's own executable path relative to its bundle). Add `Resources/AnglesiteRemote-LaunchAgent.plist` and a `- path: Resources/AnglesiteRemote-LaunchAgent.plist` `sources:` entry under the `AnglesiteRemote` target in `project.yml`, with `buildPhase.copyFiles: {destination: wrapper, subpath: Contents/Library/LaunchAgents}`, mirroring Step 3's embed pattern:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.dwk.anglesite.remote</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/Anglesite Remote</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 6: Write the test**

```swift
import Testing
@testable import AnglesiteRemote

@Suite struct LoginItemRegisteringTests {
    @Test func registerIsIdempotentWhenAlreadyEnabled() throws {
        let fake = FakeLoginItemRegistering(initialStatus: .enabled)
        try fake.register()
        #expect(fake.registerCallCount == 1)  // called, but status logic is the real conformer's
        #expect(fake.status() == .enabled)
    }

    @Test func registerTransitionsNotRegisteredToEnabled() throws {
        let fake = FakeLoginItemRegistering(initialStatus: .notRegistered)
        try fake.register()
        #expect(fake.status() == .enabled)
    }

    @Test func unregisterTransitionsToNotRegistered() throws {
        let fake = FakeLoginItemRegistering(initialStatus: .enabled)
        try fake.unregister()
        #expect(fake.status() == .notRegistered)
    }
}
```

- [ ] **Step 7: Minimal `main.swift` placeholder (Task 7 replaces the body)**

```swift
import Foundation
import AnglesiteRemote

// Anywhere runtime (#1208 P1) helper entry point. Task 7 wires the full session loop; this
// placeholder proves the target builds and embeds correctly.
#if canImport(ServiceManagement)
let loginItem = SMAppServiceLoginItem()
try? loginItem.register()
#endif
print("anglesite-remote-helper started")
RunLoop.main.run()
```

- [ ] **Step 8: Amend `CLAUDE.md` and `AGENTS.md` ▸ "Build target"**

Change:

```
`Anglesite` is the only app target.
```

to:

```
`Anglesite` is the primary app target. A second, embedded app target — `AnglesiteRemote`
(#1208 P1, "Anywhere runtime") — is a faceless (`LSUIElement`) login-item helper living in
`Anglesite.app/Contents/Library/LoginItems/`, registered via `SMAppService.agent`. It has no
UI of its own, links `AnglesiteContainer` + `AnglesiteP2P`, and exists to serve P2P sessions
(container boot + MCP/preview bridging) when the main app is closed. It is never launched
directly by the user or Finder.
```

(Apply the same edit to both files — `CLAUDE.md` mirrors `AGENTS.md` per the repo's existing convention.)

- [ ] **Step 9: Regenerate and build**

```bash
xcodegen generate
scripts/check-xcodeproj-sync.sh
swift test --filter AnglesiteRemoteTests
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: all PASS; the built `Anglesite.app/Contents/Library/LoginItems/Anglesite Remote.app` bundle exists (`find Anglesite.app -name "Anglesite Remote.app"` after the build).

- [ ] **Step 10: Commit**

```bash
git add project.yml scripts/check-xcodeproj-sync.sh CLAUDE.md AGENTS.md \
  Resources/AnglesiteRemote.entitlements Resources/AnglesiteRemote-Info.plist \
  Resources/AnglesiteRemote-LaunchAgent.plist \
  Sources/AnglesiteRemote Sources/anglesite-remote-helper Tests/AnglesiteRemoteTests
git commit -m "feat(#1208): AnglesiteRemote helper target — scaffolding + login item"
```

---

### Task 2: `RemoteSessionRegistry` — cross-process "one container owner per site"

**Files:**
- Create: `Sources/AnglesiteRemote/RemoteSessionRegistry.swift`
- Test: `Tests/AnglesiteRemoteTests/RemoteSessionRegistryTests.swift`

**Interfaces:**
- Produces:

```swift
/// One process's claim on a site's running container, published so another process asking
/// "is someone already serving this site?" can bridge to the same ports instead of booting a
/// second container (design spec §Architecture 5, "one container owner per site, always").
public struct RemoteSessionClaim: Codable, Sendable, Equatable {
    public var siteID: String
    public var previewURL: URL
    public var mcpURL: URL
    public var ownerPID: Int32
    public init(siteID: String, previewURL: URL, mcpURL: URL, ownerPID: Int32)
}

/// Directory-backed registry: one `<siteID>.json` file per claim, written atomically. Any
/// process sharing the directory can publish/look up/withdraw a claim. Production wiring points
/// this at the App Group container (blocked on the Apple Developer portal step in Task 6 Step
/// 5); tests inject a temp directory — the type itself has no opinion about *which* directory.
public actor RemoteSessionRegistry {
    public init(directory: URL)
    /// Publishes (or replaces) this process's claim. Overwrites any existing claim for the same
    /// `siteID` unconditionally — a stale claim from a crashed owner is handled by
    /// `RemoteContainerSession`'s liveness check (Task 5), not by this type.
    public func publish(_ claim: RemoteSessionClaim) throws
    /// Reads the current claim for `siteID`, or `nil` if none exists.
    public func lookup(siteID: String) throws -> RemoteSessionClaim?
    /// Removes the claim for `siteID`. Safe to call when none exists.
    public func withdraw(siteID: String) throws
}
```

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import AnglesiteRemote

@Suite struct RemoteSessionRegistryTests {
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func publishThenLookupRoundTrips() throws {
        let registry = RemoteSessionRegistry(directory: try Self.makeTempDir())
        let claim = RemoteSessionClaim(
            siteID: "abc", previewURL: URL(string: "http://127.0.0.1:4321")!,
            mcpURL: URL(string: "http://127.0.0.1:4399")!, ownerPID: 42)
        try registry.publish(claim)
        #expect(try registry.lookup(siteID: "abc") == claim)
    }

    @Test func lookupMissingReturnsNil() throws {
        let registry = RemoteSessionRegistry(directory: try Self.makeTempDir())
        #expect(try registry.lookup(siteID: "nope") == nil)
    }

    @Test func withdrawRemovesClaim() throws {
        let registry = RemoteSessionRegistry(directory: try Self.makeTempDir())
        let claim = RemoteSessionClaim(
            siteID: "abc", previewURL: URL(string: "http://127.0.0.1:4321")!,
            mcpURL: URL(string: "http://127.0.0.1:4399")!, ownerPID: 42)
        try registry.publish(claim)
        try registry.withdraw(siteID: "abc")
        #expect(try registry.lookup(siteID: "abc") == nil)
    }

    @Test func withdrawMissingIsNoOp() throws {
        let registry = RemoteSessionRegistry(directory: try Self.makeTempDir())
        try registry.withdraw(siteID: "nope")  // must not throw
    }

    @Test func publishReplacesExistingClaimForSameSite() throws {
        let registry = RemoteSessionRegistry(directory: try Self.makeTempDir())
        let first = RemoteSessionClaim(
            siteID: "abc", previewURL: URL(string: "http://127.0.0.1:1111")!,
            mcpURL: URL(string: "http://127.0.0.1:2222")!, ownerPID: 1)
        let second = RemoteSessionClaim(
            siteID: "abc", previewURL: URL(string: "http://127.0.0.1:3333")!,
            mcpURL: URL(string: "http://127.0.0.1:4444")!, ownerPID: 2)
        try registry.publish(first)
        try registry.publish(second)
        #expect(try registry.lookup(siteID: "abc") == second)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter RemoteSessionRegistryTests` → FAIL.

- [ ] **Step 3: Implement.** `siteID` is filesystem-unsafe in general (it's a UUID string in practice, but don't assume) — hash it (`SHA256` via `Crypto`/`CryptoKit`, or simpler: percent-encode) into the filename rather than interpolating raw. Write with `Data.write(to:options:.atomic)` so a concurrent reader never sees a partial file (same technique P0's `FileSignalingChannel` already uses). `lookup` returns `nil` on a missing file (not an error) and re-throws on a malformed one (a corrupt claim should be loud, not silently treated as absent — logged, per "logs are sacred", but no `LogCenter` dependency needed in this actor; use `os.Logger`).

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(#1208): RemoteSessionRegistry — cross-process container-ownership claims"`

---

### Task 3: `LoopbackHTTPExecutor` — real fetch-bridge executor

**Files:**
- Create: `Sources/AnglesiteRemote/LoopbackHTTPExecutor.swift`
- Test: `Tests/AnglesiteRemoteTests/LoopbackHTTPExecutorTests.swift`

**Interfaces:**
- Consumes: `HTTPExecutor`, `BridgeRequestHead`, `BridgeResponseHead` (all from `AnglesiteP2P`, P0).
- Produces:

```swift
/// Replays a bridged HTTP request against a real base URL (the container's `previewURL`) via
/// `URLSession`. The production `HTTPExecutor` for P1+ — `DirectoryHTTPExecutor` (P0) stays
/// test-only infra.
public struct LoopbackHTTPExecutor: HTTPExecutor {
    /// - Parameters:
    ///   - baseURL: The container's loopback preview endpoint (`LocalContainerSession.previewURL`).
    ///   - urlSession: Injectable for tests.
    public init(baseURL: URL, urlSession: URLSession = .shared)
}
```

- [ ] **Step 1: Write failing tests** using `URLProtocol`-mocked `URLSession` (a small `MockURLProtocol` registering a handler closure — this repo has no existing shared mock-URLProtocol helper, so define it locally in the test file):

```swift
import Testing
import Foundation
@testable import AnglesiteRemote

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("no handler set") }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct LoopbackHTTPExecutorTests {
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func forwardsMethodPathAndHeaders() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                    Data("<h1>hi</h1>".utf8))
        }
        let executor = LoopbackHTTPExecutor(baseURL: URL(string: "http://127.0.0.1:4321")!, urlSession: Self.makeSession())
        let (head, body) = try await executor.execute(
            BridgeRequestHead(method: "GET", path: "/blog/?draft=1", headers: ["Accept": "text/html"]), body: nil)
        #expect(head.status == 200)
        #expect(head.headers["Content-Type"] == "text/html")
        var collected = Data()
        for try await chunk in body { collected.append(chunk) }
        #expect(String(decoding: collected, as: UTF8.self) == "<h1>hi</h1>")
        #expect(capturedRequest?.url?.path == "/blog/")
        #expect(capturedRequest?.url?.query == "draft=1")
        #expect(capturedRequest?.httpMethod == "GET")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Accept") == "text/html")
    }

    @Test func forwardsRequestBody() async throws {
        var capturedBody: Data?
        MockURLProtocol.handler = { request in
            capturedBody = request.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                return data
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: [:])!, Data())
        }
        let executor = LoopbackHTTPExecutor(baseURL: URL(string: "http://127.0.0.1:4321")!, urlSession: Self.makeSession())
        let (head, _) = try await executor.execute(
            BridgeRequestHead(method: "POST", path: "/api", headers: [:]), body: Data("payload".utf8))
        #expect(head.status == 201)
        #expect(capturedBody == Data("payload".utf8))
    }

    @Test func propagatesConnectionFailureAsThrow() async {
        MockURLProtocol.handler = { _ in fatalError("should not be called") }
        let unreachable = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [FailingProtocol.self]
            return c
        }())
        let executor = LoopbackHTTPExecutor(baseURL: URL(string: "http://127.0.0.1:1")!, urlSession: unreachable)
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(BridgeRequestHead(method: "GET", path: "/", headers: [:]), body: nil)
        }
    }
}

final class FailingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter LoopbackHTTPExecutorTests` → FAIL.

- [ ] **Step 3: Implement.** Build a `URLRequest` from `baseURL` + `request.path` (parse `path` for a query string, don't double-encode), set `httpMethod`, copy every header verbatim (the hop-by-hop stripping happens once, in P0's `FetchBridgeServer`, not here — this executor is upstream of that), set `httpBody` when non-nil, `try await urlSession.data(for:)`, wrap the response as `BridgeResponseHead(status:, headers:)` (flatten `HTTPURLResponse.allHeaderFields` to `[String: String]`) and return the body as a single-element `AsyncThrowingStream` (URLSession's `.data(for:)` already buffers the whole body — no need to hand-roll incremental streaming here; P0's `FetchBridgeServer` re-chunks into ≤64 KiB frames regardless of how many stream elements the executor yields).

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(#1208): LoopbackHTTPExecutor — real fetch-bridge backend"`

---

### Task 4: `LoopbackMCPBridge` — real MCP-channel handler

**Files:**
- Create: `Sources/AnglesiteRemote/LoopbackMCPBridge.swift`
- Test: `Tests/AnglesiteRemoteTests/LoopbackMCPBridgeTests.swift`

**Interfaces:**
- Consumes: `MCPChannelResponder.Handler` (`AnglesiteP2P`), `HTTPTransport` (`AnglesiteCore`, `Sources/AnglesiteCore/HTTPTransport.swift`), `JSONValue`.
- Produces:

```swift
/// Wraps a raw `HTTPTransport` pointed at the container's MCP endpoint and exposes it as an
/// `MCPChannelResponder.Handler` — a blind, faithful passthrough (not `MCPClient`'s structured
/// call API, which parses specific methods; this bridge must forward *any* JSON-RPC message the
/// phone sends, unmodified). Safe because `MCPChannelResponder.run()` processes inbound `mcp`
/// frames one at a time (`Sources/AnglesiteP2P/MCPChannelResponder.swift:33`, a single
/// sequential `for await` loop, no concurrent child tasks) — so exactly one request is ever
/// in flight through this bridge's `HTTPTransport`, and "send, then read the next inbound
/// value" is safe without id-correlation of its own.
public actor LoopbackMCPBridge {
    /// - Parameter mcpURL: The container's loopback MCP endpoint (`LocalContainerSession.mcpURL`).
    public init(mcpURL: URL, urlSession: URLSession = .shared)
    /// Conforms to `MCPChannelResponder.Handler`'s shape; pass `bridge.handle` directly to
    /// `MCPChannelResponder.init(connection:handler:)`.
    public func handle(_ message: JSONValue) async -> JSONValue?
}
```

- [ ] **Step 1: Write failing tests** against a tiny in-process HTTP stub (`URLProtocol`-mocked, same technique as Task 3) that echoes a canned MCP response:

```swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteRemote

@Suite struct LoopbackMCPBridgeTests {
    @Test func requestGetsMatchingResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            let bodyData = request.httpBodyStreamAsData() ?? Data()
            let body = try! JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
            let id = body["id"] as! Int
            let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": ["ok": true]]
            let data = try! JSONSerialization.data(withJSONObject: reply)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                     headerFields: ["Content-Type": "application/json"])!, data)
        }
        let bridge = LoopbackMCPBridge(mcpURL: URL(string: "http://127.0.0.1:4399")!,
                                        urlSession: URLSession(configuration: config))
        let reply = await bridge.handle(.object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize"),
        ]))
        guard case let .object(fields)? = reply, case let .int(id)? = fields["id"] else {
            Issue.record("no reply or missing id"); return
        }
        #expect(id == 1)
    }

    @Test func notificationReturnsNilAndStillSends() async throws {
        var sawNotification = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            sawNotification = true
            return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: [:])!, Data())
        }
        let bridge = LoopbackMCPBridge(mcpURL: URL(string: "http://127.0.0.1:4399")!,
                                        urlSession: URLSession(configuration: config))
        let reply = await bridge.handle(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/x")]))
        #expect(reply == nil)
        #expect(sawNotification)
    }
}
```

(Add `httpBodyStreamAsData()` as a small private test helper mirroring Task 3's inline stream-reading code, or factor Task 3's version into a shared test-support file both suites import — engineer's call; either is fine.)

- [ ] **Step 2: Run to verify failure** — `swift test --filter LoopbackMCPBridgeTests` → FAIL.

- [ ] **Step 3: Implement.** `init` builds `HTTPTransport(endpoint: mcpURL)` (no bearer token — the local container path doesn't require one, per `HTTPTransport`'s own doc comment) and starts one persistent iterator over `transport.inbound()`, stored as actor state. `handle(_:)`: `try? await transport.send(message)`; if the message is a notification (`JSONValue.object` with no `"id"` key), return `nil` immediately without waiting. Otherwise `await iterator.next()` and return it (or `nil` on transport failure — log via `os.Logger`, never crash the responder loop).

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(#1208): LoopbackMCPBridge — real MCP-channel handler"`

---

### Task 5: `RemoteContainerSession` — boot-or-reuse orchestration

**Files:**
- Create: `Sources/AnglesiteRemote/RemoteContainerSession.swift`
- Test: `Tests/AnglesiteRemoteTests/RemoteContainerSessionTests.swift`

**Interfaces:**
- Consumes: `RemoteSessionRegistry` (Task 2), `LocalContainerControl`/`LocalContainerSession` (`AnglesiteCore`, `Sources/AnglesiteCore/LocalContainerControl.swift`).
- Produces:

```swift
/// Boots (or reuses) the container for one site, publishing/withdrawing its
/// `RemoteSessionRegistry` claim around the container's lifetime. "One container owner per
/// site, always" (design spec §Architecture 5): if another process already published a claim
/// for this `siteID`, this session bridges to those ports instead of booting a second container.
public actor RemoteContainerSession {
    /// - Parameters:
    ///   - control: The container backend — `ContainerizationControl()` in production, a fake
    ///     in tests (same seam `LocalContainerSiteRuntime` and its tests already use).
    ///   - registry: Where ownership claims are published — see Global Constraints re: the App
    ///     Group portal step this depends on in production.
    ///   - pid: This process's PID, recorded in the published claim. Injectable for tests.
    public init(control: any LocalContainerControl, registry: RemoteSessionRegistry, pid: Int32 = ProcessInfo.processInfo.processIdentifier)

    /// Ensures a running container for `siteID`/`sourceRepo`/`ref` and returns its endpoints —
    /// either a freshly booted one (this session becomes the owner, publishes a claim) or an
    /// already-published one from another process (no boot, no claim change).
    public func ensureRunning(siteID: String, sourceRepo: URL, ref: String,
                               onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> LocalContainerSession

    /// Tears down — only if THIS session booted the container (owns the claim); a no-op when
    /// bridging to another process's container, since that process owns its lifecycle.
    public func tearDown(siteID: String) async
}
```

- [ ] **Step 1: Write failing tests** using `AnglesiteCore`'s existing `FakeLocalContainerControl` test double (confirmed to exist alongside `LocalContainerControl` for `LocalContainerSiteRuntime`'s own tests — reuse it, don't reinvent):

```swift
import Testing
import Foundation
@testable import AnglesiteRemote
@testable import AnglesiteCore

@Suite struct RemoteContainerSessionTests {
    static func makeRegistry() throws -> RemoteSessionRegistry {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RemoteSessionRegistry(directory: dir)
    }

    @Test func bootsFreshWhenNoExistingClaim() async throws {
        let control = FakeLocalContainerControl()
        let registry = try Self.makeRegistry()
        let session = RemoteContainerSession(control: control, registry: registry, pid: 111)
        let result = try await session.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        #expect(control.startCallCount == 1)
        let claim = try registry.lookup(siteID: "site-1")
        #expect(claim?.previewURL == result.previewURL)
        #expect(claim?.ownerPID == 111)
    }

    @Test func reusesExistingClaimWithoutBooting() async throws {
        let registry = try Self.makeRegistry()
        try registry.publish(RemoteSessionClaim(
            siteID: "site-1", previewURL: URL(string: "http://127.0.0.1:9001")!,
            mcpURL: URL(string: "http://127.0.0.1:9002")!, ownerPID: 999))
        let control = FakeLocalContainerControl()
        let session = RemoteContainerSession(control: control, registry: registry, pid: 111)
        let result = try await session.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        #expect(control.startCallCount == 0)
        #expect(result.previewURL == URL(string: "http://127.0.0.1:9001")!)
    }

    @Test func tearDownWithdrawsOwnClaimOnlyWhenOwner() async throws {
        let control = FakeLocalContainerControl()
        let registry = try Self.makeRegistry()
        let owner = RemoteContainerSession(control: control, registry: registry, pid: 111)
        _ = try await owner.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        let borrower = RemoteContainerSession(control: control, registry: registry, pid: 222)
        _ = try await borrower.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        await borrower.tearDown(siteID: "site-1")
        #expect(try registry.lookup(siteID: "site-1") != nil)  // borrower didn't withdraw the owner's claim
        await owner.tearDown(siteID: "site-1")
        #expect(try registry.lookup(siteID: "site-1") == nil)
        #expect(control.stopCallCount == 1)  // only the real owner's teardown stopped the container
    }
}
```

(If `FakeLocalContainerControl` doesn't already expose `startCallCount`/`stopCallCount`, add them there as part of this task — check `Sources/AnglesiteCore/` or wherever the fake lives, likely `Tests/AnglesiteCoreTests/Fakes/` or similar, before assuming; it's shared test infra, not `AnglesiteRemote`-private.)

- [ ] **Step 2: Run to verify failure** — `swift test --filter RemoteContainerSessionTests` → FAIL.

- [ ] **Step 3: Implement.** `ensureRunning`: `registry.lookup(siteID:)` first; if a claim exists, return a `LocalContainerSession(previewURL: claim.previewURL, mcpURL: claim.mcpURL)` built straight from it (no boot). Otherwise `control.start(siteID:sourceRepo:ref:onOutput:)`, then `registry.publish(RemoteSessionClaim(siteID:, previewURL: session.previewURL, mcpURL: session.mcpURL, ownerPID: pid))`, track `ownsContainer = true` in actor state for this `siteID`. `tearDown`: only call `control.stop(siteID:)` and `registry.withdraw(siteID:)` when this session's own state says it owns that site's container; otherwise no-op.

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(#1208): RemoteContainerSession — boot-or-reuse container ownership"`

---

### Task 6: `RemoteSiteResolver` — site lookup + powerbox bookmark

**Files:**
- Create: `Sources/AnglesiteRemote/RemoteSiteResolver.swift`
- Test: `Tests/AnglesiteRemoteTests/RemoteSiteResolverTests.swift`

**Interfaces:**
- Consumes: `SecurityScopedBookmarking`, `SecurityScopedBookmarkResolution` (`AnglesiteCore`, `Sources/AnglesiteCore/Platform/SecurityScopedBookmark.swift`).
- Produces:

```swift
/// Resolves a siteID to its `Source/` directory for the helper — independent of `SiteStore`
/// (that type's `recents.json` lives in the MAIN APP's sandbox container, which this helper's
/// distinct bundle ID cannot read without an App Group; see Step 5). Two paths, per design spec
/// §2 "File access": iCloud-stored sites resolve with zero prompts (both bundle IDs carry the
/// same ubiquity-container entitlement); everything else needs a one-time bookmark this resolver
/// mints and persists itself.
public actor RemoteSiteResolver {
    /// - Parameters:
    ///   - bookmarkStore: Where this resolver persists its OWN bookmarks (never the main app's).
    ///     Production: a JSON file under this helper's own `Application Support`. Tests: inject
    ///     a temp-file-backed store.
    ///   - bookmarking: The `SecurityScopedBookmarking` seam (`PlatformSecurityScopedBookmark.make()`
    ///     in production, a fake in tests).
    ///   - presentOpenPanel: Closure invoked when a site has no bookmark yet — production shows
    ///     a real `NSOpenPanel` pre-targeted at the expected package path; tests inject a stub
    ///     returning a canned URL (or `nil` for "user cancelled").
    public init(
        bookmarkStore: RemoteBookmarkStore,
        bookmarking: any SecurityScopedBookmarking,
        presentOpenPanel: @escaping @Sendable (URL) async -> URL?)

    /// Resolves `siteID` to its `Source/` directory. `expectedPackageURL` is only used to
    /// pre-target the open panel on the non-iCloud path (best-effort UX, not a security check —
    /// the user can navigate elsewhere in the panel, same as the main app's own Import flow).
    public func resolveSourceDirectory(siteID: String, expectedPackageURL: URL) async throws -> URL
}

/// Errors surfaced when the site can't be resolved.
public enum RemoteSiteResolverError: Error, Equatable {
    case userCancelledGrant
    case bookmarkResolutionFailed(String)
}

/// Tiny persisted `[siteID: Data]` bookmark map — the helper's own equivalent of
/// `SiteStore.Site.bookmarkData`, but stored under this bundle's own container, never shared
/// with the main app's `recents.json`.
public actor RemoteBookmarkStore {
    public init(fileURL: URL)
    public func bookmarkData(for siteID: String) throws -> Data?
    public func setBookmark(_ data: Data, for siteID: String) throws
}
```

- [ ] **Step 1: Write failing tests** — cover both paths with fakes (no real `NSOpenPanel`, no real iCloud):

```swift
import Testing
import Foundation
@testable import AnglesiteRemote
@testable import AnglesiteCore

struct FakeBookmarking: SecurityScopedBookmarking {
    var createResult: Result<Data, Error> = .success(Data("bookmark".utf8))
    var resolveResult: Result<SecurityScopedBookmarkResolution, Error>
    func create(for url: URL) throws -> Data { try createResult.get() }
    func resolve(_ data: Data) throws -> SecurityScopedBookmarkResolution { try resolveResult.get() }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}

@Suite struct RemoteSiteResolverTests {
    static func makeStore() throws -> RemoteBookmarkStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bookmarks-\(UUID().uuidString).json")
        return RemoteBookmarkStore(fileURL: file)
    }

    @Test func firstTimeGrantPersistsBookmarkAndReturnsSourceDirectory() async throws {
        let panelURL = URL(fileURLWithPath: "/tmp/MySite.anglesite")
        let sourceURL = panelURL.appendingPathComponent("Source")
        let resolver = RemoteSiteResolver(
            bookmarkStore: try Self.makeStore(),
            bookmarking: FakeBookmarking(resolveResult: .success(.init(url: sourceURL, isStale: false))),
            presentOpenPanel: { _ in panelURL })
        let result = try await resolver.resolveSourceDirectory(siteID: "site-1", expectedPackageURL: panelURL)
        #expect(result == sourceURL)
    }

    @Test func secondCallReusesPersistedBookmarkWithoutPanel() async throws {
        var panelCallCount = 0
        let panelURL = URL(fileURLWithPath: "/tmp/MySite.anglesite")
        let sourceURL = panelURL.appendingPathComponent("Source")
        let store = try Self.makeStore()
        let resolver = RemoteSiteResolver(
            bookmarkStore: store,
            bookmarking: FakeBookmarking(resolveResult: .success(.init(url: sourceURL, isStale: false))),
            presentOpenPanel: { url in panelCallCount += 1; return url })
        _ = try await resolver.resolveSourceDirectory(siteID: "site-1", expectedPackageURL: panelURL)
        _ = try await resolver.resolveSourceDirectory(siteID: "site-1", expectedPackageURL: panelURL)
        #expect(panelCallCount == 1)
    }

    @Test func cancelledPanelThrowsUserCancelledGrant() async {
        let resolver = RemoteSiteResolver(
            bookmarkStore: try! Self.makeStore(),
            bookmarking: FakeBookmarking(resolveResult: .failure(SecurityScopedBookmarkError.resolveFailed("n/a"))),
            presentOpenPanel: { _ in nil })
        await #expect(throws: RemoteSiteResolverError.userCancelledGrant) {
            _ = try await resolver.resolveSourceDirectory(siteID: "site-1", expectedPackageURL: URL(fileURLWithPath: "/tmp/x"))
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter RemoteSiteResolverTests` → FAIL.

- [ ] **Step 3: Implement `RemoteBookmarkStore`** — a `[String: Data]` dictionary, encoded/decoded as JSON, read/written atomically to `fileURL`, matching `RemoteSessionRegistry`'s atomic-write technique (Task 2).

- [ ] **Step 4: Implement `RemoteSiteResolver`.** `resolveSourceDirectory`: `bookmarkStore.bookmarkData(for: siteID)`; if present, `bookmarking.resolve(data)` and return `.url.appendingPathComponent("Source")` (re-`create`+persist on `isStale`, mirroring `SiteAccess`'s existing dance). If absent, call `presentOpenPanel(expectedPackageURL)`; `nil` → throw `.userCancelledGrant`; a URL → `bookmarking.create(for:)`, persist via `bookmarkStore.setBookmark(_:for:)`, then resolve+return as above. (The iCloud zero-prompt path — checking whether `expectedPackageURL` already sits inside the shared ubiquity container before ever trying a bookmark — is a fast-path optimization on top of this same method; implement it as an early check: if `FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.io.dwk.anglesite")` is a prefix of `expectedPackageURL`, return `expectedPackageURL.appendingPathComponent("Source")` directly, no bookmark involved. Add one more test for this branch: `iCloudSitePathSkipsBookmarkEntirely`, injecting a fake `expectedPackageURL` under a temp dir standing in for the ubiquity container URL via a small `ubiquityContainerURLProvider: @Sendable () -> URL?` init parameter, defaulting to the real `FileManager` call in production.)

- [ ] **Step 5: Run to verify pass** — PASS.

- [ ] **Step 6: Commit** — `git commit -m "feat(#1208): RemoteSiteResolver — helper-owned site access + bookmarks"`

**Manual/environmental note (not a code step):** Production wiring of `RemoteSessionRegistry` (Task 2) at a *shared* location, and any future cross-bundle iCloud-catalog read, need `com.apple.security.application-groups` enabled for both `io.dwk.anglesite` and `io.dwk.anglesite.remote` in the Apple Developer portal (Team `M34HBJZNYA`, which holds the paid Developer Program membership App Groups requires), with profiles regenerated — an owner action outside this plan's scope, tracked the same way #66's Workers-Paid-plan gate was. Until then, wire `RemoteSessionRegistry`'s production `directory:` to a helper-local path (e.g. `~/Library/Containers/io.dwk.anglesite.remote/Data/Library/Application Support/Anglesite/sessions/`) — this degrades "one owner per site" to "one owner per site *among helper-only sessions*" (the main app and the helper can each independently boot a container for the same site until the App Group lands), which is an acceptable, explicitly-logged limitation for P1's exit criterion (a single helper process, main app closed) and does not block Task 8.

---

### Task 7: Wire the helper session loop

**Files:**
- Modify: `Sources/anglesite-remote-helper/main.swift`

**Interfaces:**
- Consumes: everything above, plus `WebRTCPeer`, `FileSignalingChannel`, `FetchBridgeServer`, `MCPChannelResponder`, `ControlHeartbeat` (`AnglesiteP2P`, P0) and `ContainerizationControl` (`AnglesiteContainer`).
- Produces: `anglesite-remote-helper session <signal-dir> <site-root>` — accepts one P2P session over file signaling (matching P0's `anglesite-p2p-demo host` invocation shape), boots/reuses the site's container, and bridges all four channels until the connection closes or the process receives `SIGTERM`.

- [ ] **Step 1: Replace `main.swift`'s body**

```swift
import Foundation
import AnglesiteCore
import AnglesiteContainer
import AnglesiteP2P
import AnglesiteRemote
#if canImport(ServiceManagement)
import ServiceManagement
#endif

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

#if canImport(ServiceManagement)
try? SMAppServiceLoginItem().register()
#endif

let args = CommandLine.arguments
guard args.count == 4, args[1] == "session" else {
    die("usage: anglesite-remote-helper session <signal-dir> <site-root>")
}
let signalDir = URL(fileURLWithPath: args[2], isDirectory: true)
let siteRoot = URL(fileURLWithPath: args[3], isDirectory: true)
let siteID = siteRoot.lastPathComponent

let registryDir = FileManager.default.temporaryDirectory.appendingPathComponent("anglesite-remote-sessions")
try? FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
let containerSession = RemoteContainerSession(
    control: ContainerizationControl(),
    registry: RemoteSessionRegistry(directory: registryDir))

let session: LocalContainerSession
do {
    session = try await containerSession.ensureRunning(
        siteID: siteID, sourceRepo: siteRoot, ref: "HEAD",
        onOutput: { line, stream in FileHandle.standardError.write(Data(("[\(stream)] " + line + "\n").utf8)) })
} catch {
    die("container boot failed: \(error)")
}

let peer = try await WebRTCPeer.connect(
    role: .answerer, signaling: FileSignalingChannel(directory: signalDir, sender: "helper"))

let httpBridge = FetchBridgeServer(connection: peer, executor: LoopbackHTTPExecutor(baseURL: session.previewURL))
let mcpBridge = LoopbackMCPBridge(mcpURL: session.mcpURL)
let mcpResponder = MCPChannelResponder(connection: peer, handler: mcpBridge.handle)
let heartbeat = ControlHeartbeat(connection: peer, interval: .seconds(10), missLimit: 6, onMiss: { count in
    if count >= 6 { FileHandle.standardError.write(Data("control link presumed dead\n".utf8)) }
})

signal(SIGTERM) { _ in exit(0) }

async let a: Void = httpBridge.run()
async let b: Void = mcpResponder.run()
async let c: Void = heartbeat.run()
_ = await (a, b, c)

await containerSession.tearDown(siteID: siteID)
```

Note (same caveat P0's Task 8 flagged): if the toolchain rejects top-level `await` in a plain `main.swift`, wrap the whole body in `@main struct Helper { static func main() async throws { … } }` in a `Helper.swift` file instead — verify against this checkout's actual Swift 6.4 toolchain behavior, don't assume.

- [ ] **Step 2: Build**

```bash
xcodegen generate
swift build --product anglesite-remote-helper
```

Expected: builds clean (this task has no new unit tests of its own — Task 8 is the integration test that exercises this file end-to-end).

- [ ] **Step 3: Commit**

```bash
git add Sources/anglesite-remote-helper/main.swift
git commit -m "feat(#1208): wire the helper's full P2P session loop"
```

---

### Task 8: Exit-criterion E2E — a second Mac process edits a site with the main app closed

**Files:**
- Test: `Tests/AnglesiteRemoteTests/HelperContainerE2ETests.swift`

**Interfaces:**
- Consumes: everything above, plus a real container boot (same gate as `ContainerizationControlTests`, `Tests/AnglesiteContainerLocalTests/ContainerizationControlTests.swift:13-40`) and a real two-process P2P connection (same gate as P0's `TwoProcessE2ETests`).

- [ ] **Step 1: Write the gated test**

```swift
import Testing
import Foundation
@testable import AnglesiteRemote

@Suite(.enabled(if:
    ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_TESTS"] == "1" &&
    ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_E2E"] == "1" &&
    ProcessInfo.processInfo.environment["ANGLESITE_P2P_E2E"] == "1"))
struct HelperContainerE2ETests {
    @Test func secondProcessEditsSiteWithNoMainAppRunning() async throws {
        // Fixture: a minimal git-initialized Astro-shaped Source/ dir (mirrors the smoke-test repo
        // pattern from #66's comment history — a throwaway, not a real template scaffold).
        let siteRoot = FileManager.default.temporaryDirectory.appendingPathComponent("helper-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: siteRoot, withIntermediateDirectories: true)
        // ... git init + minimal astro.config + index page, following
        // ContainerizationControlTests's existing fixture-building helper; reuse it rather than
        // duplicating (import it if `internal`, or lift it to a shared test-support target if not).

        let signalDir = FileManager.default.temporaryDirectory.appendingPathComponent("helper-e2e-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: signalDir, withIntermediateDirectories: true)

        // Launch the helper as a REAL SECOND PROCESS — never the main Anglesite.app.
        let helperBinary = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("anglesite-remote-helper")
        let helper = Process()
        helper.executableURL = helperBinary
        helper.arguments = ["session", signalDir.path, siteRoot.path]
        try helper.run()
        defer { helper.terminate() }

        // Client side: the same WebRTCPeer/FetchBridgeClient/WebRTCTransport pieces P0's demo
        // used, connecting as the offerer against the same signalDir.
        let clientPeer = try await WebRTCPeer.connect(
            role: .offerer, signaling: FileSignalingChannel(directory: signalDir, sender: "client"))
        let mcp = WebRTCTransport(connection: clientPeer)
        try await mcp.open()

        // Perform one MCP edit-tool call (exact tool name/shape per the sidecar's current
        // schema — check `docs/` or the sidecar checkout for the real `apply_edit`/equivalent
        // tool contract before filling this in; this plan step deliberately leaves the specific
        // JSON-RPC payload for the engineer to confirm against the live schema rather than
        // guessing it, since it crosses the paired-PR MCP-schema boundary noted in CONTRIBUTING.md).
        try await mcp.send(/* initialize handshake, then a real content-edit tool call */ .null)
        var it = mcp.inbound().makeAsyncIterator()
        guard await it.next() != nil else { Issue.record("no MCP reply"); return }

        await clientPeer.close()
        helper.terminate()
        helper.waitUntilExit()

        // Assert the edit actually landed in Source/ on disk — the exit criterion.
        // (Concrete assertion depends on which file the edit tool touched; e.g. read it back
        // and check the new content is present.)
    }
}
```

This step is intentionally the one place in the plan with an unresolved detail: the exact MCP tool call to exercise (name, arguments) must be read from the live sidecar schema at implementation time, not guessed here — same spirit as P0's Task 4/8 flags about verifying `JSONValue` case spellings against the checkout rather than assuming them. Check `Anglesite/anglesite-skills`'s `server/` tool definitions (per `AGENTS.md` ▸ "Two-repo coordination") for the current edit-tool name and payload shape before finalizing this test.

- [ ] **Step 2: Run the exit criterion**

```bash
ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 ANGLESITE_P2P_E2E=1 \
  swift test --filter HelperContainerE2ETests
```

Expected: PASS. This is the epic's P1 exit: **a second Mac process edits a site with the main app closed.**

- [ ] **Step 3: Full-suite check**

```bash
swift test --package-path .
```

All green; gated suites skip cleanly without their env vars.

- [ ] **Step 4: Commit**

```bash
git add Tests/AnglesiteRemoteTests/HelperContainerE2ETests.swift
git commit -m "feat(#1208): P1 exit-criterion E2E — helper edits a site, main app closed"
```

---

### Task 9: PR

- [ ] **Step 1:** Re-read `CONTRIBUTING.md` ▸ "Commits and pull requests"; build the PR body from `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (**Summary**, **Paired PR check** — self-contained unless Task 8's MCP tool-call check surfaces a schema gap, in which case flag it there instead of silently working around it — and **Test plan** listing every command actually run, including all three `ANGLESITE_*_E2E=1` combinations). Reference `Part of #1208` (P1 is a checklist item on the epic; tick its box after merge, same as P0's Task 9 did).
- [ ] **Step 2:** Push and `gh pr create`; verify CI (the `xcodeproj-sync` job specifically, given Task 1's `project.yml` changes; Linux leg stays green since `AnglesiteRemote`/`AnglesiteContainer`/`AnglesiteP2P` are all Darwin-only-gated).

## Self-Review Notes

- **Spec coverage:** login item + `SMAppService.agent` (Task 1), on-demand container boot (Task 5), app-target-invariant doc update (Task 1 Step 8, per spec line 50), powerbox grants for non-iCloud sites + iCloud zero-prompt path (Task 6), one-container-owner-per-site coordination (Tasks 2 + 5), real fetch/MCP bridging replacing P0's test-only stand-ins (Tasks 3 + 4), exit criterion (Task 8). CloudKit signaling, QR pairing, TURN, and the iOS client are explicitly out of scope per the spec's phasing table and are not touched.
- **Known gaps flagged inline, not hidden:** the App Groups capability is a real portal/provisioning dependency this plan cannot satisfy (Task 6's manual note) — Task 2/5's registry is fully coded and tested against an injected directory, and production wiring degrades gracefully (documented) rather than blocking. Task 8's exact MCP tool-call payload is deliberately left for the implementing engineer to confirm against the live sidecar schema rather than guessed, consistent with this repo's paired-PR discipline for MCP schema surfaces.
- **Type consistency check:** `LocalContainerSession`/`LocalContainerControl`/`RemoteSessionClaim` field names (`previewURL`, `mcpURL`, `siteID`) are used identically across Tasks 2, 5, and 7 — verified against the as-built `Sources/AnglesiteCore/LocalContainerControl.swift` signatures rather than the earlier P0 plan's guesses. `JSONValue` case names (`.object`, `.string`, `.int`, `.array`, `.bool`, `.null` — **not** `.number`, which P0's own plan had flagged as an unverified guess) are taken from the as-built `Sources/AnglesiteCore/MCPClient.swift:10-25` enum, confirmed directly against this checkout.
