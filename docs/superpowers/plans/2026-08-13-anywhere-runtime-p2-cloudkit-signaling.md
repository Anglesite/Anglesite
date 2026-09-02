# Anywhere Runtime P2 — CloudKit Signaling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the P1 helper's file-based signaling (`FileSignalingChannel`, local dev/test only) with real cross-network CloudKit signaling, add QR-code device pairing with key pinning, and add a Settings UI to manage/revoke paired devices — proven by two real Mac processes pairing and completing a signed, CloudKit-signaled MCP round trip.

**Architecture:** Six new pieces plus one fix to already-shipped P1 code, per `docs/superpowers/specs/2026-08-13-anywhere-runtime-p2-cloudkit-signaling-design.md` (owner-approved 2026-08-13): (1) an `NSApplication` run loop for the helper, a real gap in the shipped P1 code that blocks CloudKit push entirely; (2) `DevicePairingKeyPair`, mirroring the existing `DPoPKeyPair` CryptoKit/Keychain pattern; (3) `PairedDevice`/`PairedDeviceStore`, mirroring `ACPAgentConnection`/`ACPAgentStore`; (4) `SignedSignalingChannel`, a transport-agnostic decorator over any `SignalingChannel`; (5) `CloudKitSignalingChannel`, the real conformer; (6) Settings UI (QR pane + paired-device list); (7) a presence-heartbeat writer. Epic: [#1208](https://github.com/Anglesite/Anglesite/issues/1208).

**Tech Stack:** Swift 6.4 / Xcode 27, SwiftPM + XcodeGen, Swift Testing, `CryptoKit` (P-256 signing), `CloudKit` (private DB, `CKQuerySubscription`), `CoreImage` (`CIQRCodeGenerator`), `AnglesiteP2P` (P0's `SignalingChannel`/`WebRTCPeer`), `AnglesiteCore` (`SecretStore`, `DPoPKeyPair` pattern), `AnglesiteRemote` (P1's helper).

## Global Constraints

- `swift test` needs `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` on the owner's machine.
- New public API needs `///` doc comments per `docs/comment-style-guide.md` (CI fails on broken DocC links).
- Commit subjects ≤72 chars, conventional-commit format, reference #1208.
- Tests are Swift Testing (`@Test`, `#expect`), not XCTest.
- **Every `#if` platform guard that references a Darwin-only type must match that type's OWN guard exactly** (`#if canImport(Darwin)`, not `#if !os(iOS)` — those are not equivalent on Linux). This is a real, CI-only-visible bug class this epic has already hit once (`ContainerEditExport.swift`, fixed 2026-08-13) — every new file in this plan that touches `CryptoKit`/`CloudKit`/`AppKit` needs the exact right guard, verified against the type it's calling, not assumed.
- **CloudKit is genuinely new to this codebase** (confirmed by research 2026-08-13: zero prior `CKContainer`/`CKDatabase`/`CKRecord`/`CKSubscription` usage anywhere). Tasks 5–6 give the best-known-correct modern async CloudKit API shape, but the exact `CKSubscription.NotificationInfo` configuration and remote-notification payload parsing should be verified against Apple's current CloudKit documentation by the implementing engineer before finalizing — flagged explicitly at that step, not guessed silently.
- **Entitlements are a real, owner-portal-gated dependency**, mirroring P1's already-documented App-Groups gap: `com.apple.developer.icloud-container-identifiers` (`iCloud.io.dwk.anglesite`) + `CloudKit` in `com.apple.developer.icloud-services` need adding to `Resources/AnglesiteRemote.entitlements` (which currently has neither the iCloud container nor App Groups — see that file's own comment) and to the main app's entitlements (which already has the container id but only `CloudDocuments` in `icloud-services`, not `CloudKit`). This plan is designed so every task's code and tests work against injected seams regardless of entitlement state — only the *production* wiring (Task 9) depends on the portal capability being provisioned, exactly like P1's App-Groups note.
- **P2's practical exit criterion is a two-Mac-process harness**, not a real phone (no iOS client exists — that's P4). See the design spec's "Scope-setting findings" section for the full owner-approved rationale. The "phone" role consumes the QR payload as a string directly; only the camera-scan step is simulated. Real CloudKit is used throughout.
- Code lands on the current worktree/branch (`.claude/worktrees/1208-p2-cloudkit-signaling`, branch `worktree-1208-p2-cloudkit-signaling`, already cut fresh from `main`). Run `xcodegen generate` after any `project.yml` edit (Task 8 adds Settings UI files; verify whether `SettingsView.swift` needs a `project.yml` source-list update — it likely doesn't, being an existing file, but a *new* file for the QR pane does).

## File Structure

```
Sources/anglesite-remote-helper/main.swift        # modified — NSApplicationDelegate + run loop
Sources/AnglesiteCore/DevicePairingKeyPair.swift   # new
Sources/AnglesiteCore/PairedDevice.swift           # new
Sources/AnglesiteCore/PairedDeviceStore.swift      # new
Sources/AnglesiteCore/Platform/SecretStore.swift   # modified — + devicePairingKey slot
Sources/AnglesiteP2P/SignedSignalingChannel.swift  # new
Sources/AnglesiteP2P/CloudKitSignalingChannel.swift  # new, Darwin-gated
Sources/AnglesiteP2P/CloudKitPairingService.swift  # new — DeviceAnnounceRecord + subscription
Sources/AnglesiteP2P/PresenceHeartbeatWriter.swift # new
Sources/AnglesiteApp/SettingsView.swift            # modified — + 5th tab
Sources/AnglesiteApp/DevicePairingSettingsView.swift  # new — QR pane + device list
Tests/AnglesiteCoreTests/DevicePairingKeyPairTests.swift  # new
Tests/AnglesiteCoreTests/PairedDeviceStoreTests.swift     # new
Tests/AnglesiteP2PTests/SignedSignalingChannelTests.swift # new
Tests/AnglesiteP2PTests/CloudKitSignalingChannelTests.swift  # new, gated ANGLESITE_CK_TESTS=1
Tests/AnglesiteP2PTests/CloudKitPairingServiceTests.swift    # new, gated ANGLESITE_CK_TESTS=1
Tests/AnglesiteRemoteTests/HelperContainerE2ETests.swift     # modified — + P2 exit-criterion test
Resources/AnglesiteRemote.entitlements             # modified — manual note only (Task 9)
Resources/Anglesite.entitlements                   # modified — manual note only (Task 9)
```

Out of P2 scope (explicitly deferred, per the design spec's Non-goals): the real iOS QR-scanning client (P4); consuming the presence heartbeat in any UI (P4); TURN credential minting (P3); publish-from-phone (P5).

---

### Task 1: Helper `NSApplication` lifecycle fix

**Files:**
- Modify: `Sources/anglesite-remote-helper/main.swift`

**Interfaces:**
- Produces: the helper process now runs a real `NSApplication` event loop, unblocking `registerForRemoteNotifications()` for Task 5. No new public API — this task restructures existing top-level code into an `async` function, unchanged in substance.

- [ ] **Step 1: Read the current file in full** (`Sources/anglesite-remote-helper/main.swift`, ~129 lines as of this plan) before editing — it has evolved since P1 shipped (it now includes `RemoteSiteIdentity.siteID(forSourceDirectory:)` and `DispatchSource`-based SIGTERM handling that didn't exist in the original P1 plan). Do not work from a stale copy.

- [ ] **Step 2: Wrap the existing top-level logic in an `async` function, driven by a minimal `NSApplicationDelegate`.**

Replace the whole file's structure (keeping every line of existing logic — login-item registration, arg parsing, container boot, the `remote-helper: container ready`/`peer connected` markers, `WebRTCPeer.connect`, the SIGTERM `DispatchSource`, the bridge `async let`s, `containerSession.tearDown`) with:

```swift
import Foundation
import AppKit
import AnglesiteCore
import AnglesiteContainer
import AnglesiteP2P
import AnglesiteRemote
#if canImport(ServiceManagement)
import ServiceManagement
#endif

// Anywhere runtime (#1208 P2) helper entry point. P2 adds the NSApplication run loop this file
// never had in P1 — a real gap: the design spec's own rationale for the helper being "a real
// (faceless) app rather than a bare LaunchAgent" is "specifically so it can receive CloudKit
// push" (design spec §Architecture 2), but `registerForRemoteNotifications()` cannot be called
// without an NSApplication event loop, which this file did not run until now.
//
// `NSApplication.shared.run()` never returns on its own — the old top-level "fall off the end of
// main.swift" exit path is replaced by explicit `exit(0)`/`exit(1)` calls inside `runSession()`,
// matching what `die(_:)` and the SIGTERM handler already did.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@MainActor
final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await runSession() }
    }
}

func runSession() async {
    #if canImport(ServiceManagement)
    do {
        try SMAppServiceLoginItem().register()
    } catch {
        FileHandle.standardError.write(Data("login item registration failed: \(error)\n".utf8))
    }
    #endif

    let args = CommandLine.arguments
    guard args.count == 4, args[1] == "session" else {
        die("usage: anglesite-remote-helper session <signal-dir> <site-root>")
    }
    let signalDir = URL(fileURLWithPath: args[2], isDirectory: true)
    let siteRoot = URL(fileURLWithPath: args[3], isDirectory: true)
    let siteID = RemoteSiteIdentity.siteID(forSourceDirectory: siteRoot)

    let registryDir = FileManager.default.temporaryDirectory.appendingPathComponent("anglesite-remote-sessions")
    do {
        try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data("registry directory creation failed: \(error)\n".utf8))
    }
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

    FileHandle.standardError.write(Data(
        "remote-helper: container ready (preview \(session.previewURL), mcp \(session.mcpURL)); waiting for peer\n".utf8))

    let peer: WebRTCPeer
    do {
        peer = try await WebRTCPeer.connect(
            role: .answerer, signaling: FileSignalingChannel(directory: signalDir, sender: "helper"))
    } catch {
        await containerSession.tearDown(siteID: siteID)
        die("P2P connect failed: \(error)")
    }
    FileHandle.standardError.write(Data("remote-helper: peer connected; bridging\n".utf8))

    let httpBridge = FetchBridgeServer(connection: peer, executor: LoopbackHTTPExecutor(baseURL: session.previewURL))
    let mcpBridge = LoopbackMCPBridge(mcpURL: session.mcpURL)
    let mcpResponder = MCPChannelResponder(connection: peer, handler: { message in await mcpBridge.handle(message) })
    let heartbeat = ControlHeartbeat(connection: peer, interval: .seconds(10), missLimit: 6, onMiss: { count in
        if count >= 6 { FileHandle.standardError.write(Data("control link presumed dead\n".utf8)) }
    })

    signal(SIGTERM, { _ in })
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler {
        Task {
            await peer.close()
            await containerSession.tearDown(siteID: siteID)
            exit(0)
        }
    }
    sigtermSource.resume()

    async let httpTask: Void = httpBridge.run()
    async let mcpTask: Void = mcpResponder.run()
    async let heartbeatTask: Void = heartbeat.run()
    _ = await (httpTask, mcpTask, heartbeatTask)

    await containerSession.tearDown(siteID: siteID)
    exit(0)
}

let delegate = HelperAppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
```

Note the `sigtermSource` local inside `runSession()` — the original file's own comment warns GCD sources stop firing if deallocated. Since `runSession()` is a long-lived `async` function that doesn't return until teardown, the local `let` stays alive for the source's whole useful lifetime here (unlike a top-level `let`, which lived for the whole process before). If Step 4's build/E2E run shows the source firing unreliably, promote it to a `nonisolated(unsafe) var` at file scope instead — call this out in the task report if so, don't silently guess.

- [ ] **Step 3: Build**

```bash
xcodegen generate
swift build --product anglesite-remote-helper
```

Expected: builds clean. `import AppKit` is new to this file — confirm it doesn't break the target's non-Darwin build story (`Package.swift`'s `includeContainer`/Darwin gating for this product) if this target is ever built on Linux; check `Package.swift` for how `anglesite-remote-helper` is currently platform-gated before assuming `AppKit` is safe to add unconditionally. If the product is already Darwin-only (likely, given it links `AnglesiteContainer`), no further guard is needed.

- [ ] **Step 4: Run the existing P1 E2E test to confirm no regression**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 ANGLESITE_P2P_E2E=1 \
  swift test --filter HelperContainerE2ETests
```

Expected: PASS, unchanged behavior — the helper now runs under `NSApplication` but does exactly the same session work. This confirms the SIGTERM/teardown path still works correctly under the new run-loop structure (a real risk: `NSApplication.shared.run()` owns the main thread differently than a bare top-level script did).

- [ ] **Step 5: Commit**

```bash
git add Sources/anglesite-remote-helper/main.swift
git commit -m "feat(#1208): give the P2 helper a real NSApplication run loop"
```

---

### Task 2: `DevicePairingKeyPair`

**Files:**
- Create: `Sources/AnglesiteCore/DevicePairingKeyPair.swift`
- Modify: `Sources/AnglesiteCore/Platform/SecretStore.swift` (+ `devicePairingKey` slot + read/write/clear extension methods, mirroring `indieAuthDPoPKey`'s pattern exactly)
- Test: `Tests/AnglesiteCoreTests/DevicePairingKeyPairTests.swift`

**Interfaces:**
- Produces:

```swift
/// A device's own signing key pair for Anywhere-runtime pairing (design spec
/// §Architecture 2) — generated once per device, Keychain-persisted, and used to sign every
/// P2P signaling payload once paired. Mirrors `DPoPKeyPair` exactly (same CryptoKit P-256
/// primitive, same persistence shape) but exposes raw signing instead of DPoP-JWT construction:
/// pairing has no HTTP request to bind a proof to, just a payload to sign.
public struct DevicePairingKeyPair: Sendable {
    /// Generates a fresh P-256 key pair.
    public init()
    /// Reconstructs a previously persisted key pair from its raw 32-byte private scalar. `nil`
    /// if `data` isn't a valid P-256 private key.
    public init?(persistedRepresentation data: Data)
    /// The raw private-key bytes to persist via `SecretStore`.
    public var persistedRepresentation: Data { get }
    /// The public key as an X9.63 uncompressed point (0x04 + 32-byte X + 32-byte Y) — the format
    /// both the QR payload and CloudKit's `DeviceAnnounceRecord.publicKey` use.
    public var publicKeyData: Data { get }
    /// Signs `payload` with this device's private key.
    public func sign(_ payload: Data) throws -> Data
    /// Verifies `signature` over `payload` against a peer's public key (X9.63 format, as
    /// produced by `publicKeyData`). Returns `false` (never throws) for a malformed key or a
    /// genuine verification failure — callers branch on a single boolean, matching
    /// `SignedSignalingChannel`'s "drop, don't throw" posture for untrusted network input.
    public static func verify(signature: Data, for payload: Data, publicKeyData: Data) -> Bool
}

public enum DevicePairingKeyPairError: Error, Sendable {
    /// CryptoKit isn't available on this platform (matches `DPoPError.unavailable`'s posture).
    case unavailable
}
```

- [ ] **Step 1: Write failing tests**, mirroring `DPoPKeyPairTests`' persistence-round-trip and malformed-bytes cases, plus sign/verify:

```swift
import Testing
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import AnglesiteCore

@Suite
struct DevicePairingKeyPairTests {
    @Test("persistedRepresentation round-trips through init?(persistedRepresentation:)")
    func persistenceRoundTrips() throws {
        let original = DevicePairingKeyPair()
        let restored = DevicePairingKeyPair(persistedRepresentation: original.persistedRepresentation)
        #expect(restored != nil)
        #expect(restored?.persistedRepresentation == original.persistedRepresentation)
    }

    @Test("init?(persistedRepresentation:) rejects malformed bytes")
    func rejectsMalformedBytes() {
        #expect(DevicePairingKeyPair(persistedRepresentation: Data([0x01, 0x02, 0x03])) == nil)
    }

    #if canImport(CryptoKit)
    @Test("publicKeyData is a 65-byte X9.63 uncompressed point starting with 0x04")
    func publicKeyDataShape() {
        let keyPair = DevicePairingKeyPair()
        #expect(keyPair.publicKeyData.count == 65)
        #expect(keyPair.publicKeyData.first == 0x04)
    }

    @Test("a signature verifies against the signer's own public key")
    func signatureVerifiesAgainstOwnKey() throws {
        let keyPair = DevicePairingKeyPair()
        let payload = Data("offer-sdp-text".utf8)
        let signature = try keyPair.sign(payload)
        #expect(DevicePairingKeyPair.verify(signature: signature, for: payload, publicKeyData: keyPair.publicKeyData))
    }

    @Test("a signature does not verify against a different key pair's public key")
    func signatureRejectsWrongKey() throws {
        let signer = DevicePairingKeyPair()
        let other = DevicePairingKeyPair()
        let payload = Data("offer-sdp-text".utf8)
        let signature = try signer.sign(payload)
        #expect(!DevicePairingKeyPair.verify(signature: signature, for: payload, publicKeyData: other.publicKeyData))
    }

    @Test("a signature does not verify against tampered payload bytes")
    func signatureRejectsTamperedPayload() throws {
        let keyPair = DevicePairingKeyPair()
        let signature = try keyPair.sign(Data("original".utf8))
        #expect(!DevicePairingKeyPair.verify(signature: signature, for: Data("tampered".utf8), publicKeyData: keyPair.publicKeyData))
    }

    @Test("verify returns false (not a crash) for malformed public key data")
    func verifyRejectsMalformedPublicKey() throws {
        let keyPair = DevicePairingKeyPair()
        let signature = try keyPair.sign(Data("payload".utf8))
        #expect(!DevicePairingKeyPair.verify(signature: signature, for: Data("payload".utf8), publicKeyData: Data([0x01, 0x02])))
    }
    #endif
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter DevicePairingKeyPairTests` → FAIL.

- [ ] **Step 3: Implement `Sources/AnglesiteCore/DevicePairingKeyPair.swift`**, mirroring `DPoPKeyPair.swift`'s exact structure (`#if canImport(CryptoKit)` around the `P256.Signing.PrivateKey` stored property and every method body, matching that file's own guard placement precisely — not `#if !os(iOS)`, per this plan's Global Constraints):

```swift
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A device's own signing key pair for Anywhere-runtime pairing (design spec
/// §Architecture 2) — generated once per device, Keychain-persisted, and used to sign every
/// P2P signaling payload once paired. Mirrors `DPoPKeyPair`'s CryptoKit/persistence shape but
/// exposes raw signing instead of DPoP-JWT construction: pairing has no HTTP request to bind a
/// proof to, just a payload to sign.
public struct DevicePairingKeyPair: Sendable {
    #if canImport(CryptoKit)
    private let privateKey: P256.Signing.PrivateKey
    #endif

    /// Generates a fresh P-256 key pair.
    public init() {
        #if canImport(CryptoKit)
        self.privateKey = P256.Signing.PrivateKey()
        #endif
    }

    /// Reconstructs a previously persisted key pair from its raw 32-byte private scalar. `nil`
    /// if `data` isn't a valid P-256 private key.
    public init?(persistedRepresentation data: Data) {
        #if canImport(CryptoKit)
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else { return nil }
        self.privateKey = key
        #else
        return nil
        #endif
    }

    /// The raw private-key bytes to persist via `SecretStore`.
    public var persistedRepresentation: Data {
        #if canImport(CryptoKit)
        privateKey.rawRepresentation
        #else
        Data()
        #endif
    }

    /// The public key as an X9.63 uncompressed point (0x04 + 32-byte X + 32-byte Y) — the format
    /// both the QR payload and CloudKit's `DeviceAnnounceRecord.publicKey` use.
    public var publicKeyData: Data {
        #if canImport(CryptoKit)
        privateKey.publicKey.x963Representation
        #else
        Data()
        #endif
    }

    /// Signs `payload` with this device's private key.
    public func sign(_ payload: Data) throws -> Data {
        #if canImport(CryptoKit)
        try privateKey.signature(for: payload).rawRepresentation
        #else
        throw DevicePairingKeyPairError.unavailable
        #endif
    }

    /// Verifies `signature` over `payload` against a peer's public key (X9.63 format). Returns
    /// `false` — never throws — for a malformed key or a genuine verification failure, so callers
    /// branch on a single boolean (`SignedSignalingChannel`'s "drop, don't throw" posture for
    /// untrusted network input).
    public static func verify(signature: Data, for payload: Data, publicKeyData: Data) -> Bool {
        #if canImport(CryptoKit)
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData),
              let ecdsaSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
        else { return false }
        return publicKey.isValidSignature(ecdsaSignature, for: payload)
        #else
        return false
        #endif
    }
}

/// Why a `DevicePairingKeyPair` operation couldn't run — mirrors `DPoPError.unavailable`'s
/// posture (CryptoKit is Apple-platforms-only; there is no pairing UI on a platform without it).
public enum DevicePairingKeyPairError: Error, Sendable {
    case unavailable
}
```

- [ ] **Step 4: Add the `SecretStore` slot.** In `Sources/AnglesiteCore/Platform/SecretStore.swift`'s `SecretAccounts` enum, add (device-scoped, not site-scoped — one key pair per Mac, not per site):

```swift
    /// The raw private-key bytes (`DevicePairingKeyPair.persistedRepresentation`) for this
    /// device's Anywhere-runtime pairing identity (#1208 P2) — generated once per device, not
    /// per site.
    public static let devicePairingKey = "device-pairing-key"
```

And in the `public extension SecretStore` block, add read/write mirroring `readIndieAuthDPoPKeyPair`/`writeIndieAuthDPoPKeyPair` exactly (base64-encoded raw bytes, same shape):

```swift
    /// Read this device's pairing key pair, if any. `nil` when unset or the stored bytes no
    /// longer decode as a P-256 private key.
    func readDevicePairingKeyPair() throws -> DevicePairingKeyPair? {
        guard let base64 = try read(account: SecretAccounts.devicePairingKey),
              let data = Data(base64Encoded: base64) else { return nil }
        return DevicePairingKeyPair(persistedRepresentation: data)
    }

    /// Store this device's pairing key pair.
    func writeDevicePairingKeyPair(_ keyPair: DevicePairingKeyPair) throws {
        try write(keyPair.persistedRepresentation.base64EncodedString(), account: SecretAccounts.devicePairingKey)
    }
```

- [ ] **Step 5: Run to verify pass** — `swift test --filter DevicePairingKeyPairTests` → PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/DevicePairingKeyPair.swift Sources/AnglesiteCore/Platform/SecretStore.swift \
  Tests/AnglesiteCoreTests/DevicePairingKeyPairTests.swift
git commit -m "feat(#1208): DevicePairingKeyPair — device signing identity"
```

---

### Task 3: `PairedDevice` + `PairedDeviceStore`

**Files:**
- Create: `Sources/AnglesiteCore/PairedDevice.swift`
- Create: `Sources/AnglesiteCore/PairedDeviceStore.swift`
- Test: `Tests/AnglesiteCoreTests/PairedDeviceStoreTests.swift`

**Interfaces:**
- Produces:

```swift
/// A paired Anywhere-runtime device (design spec §Pairing and security) — persisted, non-secret
/// metadata plus the device's pinned public key. Not a secret itself (integrity, not
/// confidentiality, is what a pinned key protects), so it lives in the plain JSON record, not
/// Keychain — matching the design spec's framing ("The QR is the trust root; iCloud is just a
/// mailbox").
public struct PairedDevice: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    /// The peer's own stable device identifier (opaque string from the QR/announce payload —
    /// not this app's `id`, which is generated locally at pairing time).
    public var deviceID: String
    public var displayName: String
    /// X9.63 uncompressed point, matching `DevicePairingKeyPair.publicKeyData`'s format.
    public var pinnedPublicKey: Data
    public var pairedAt: Date
    public var lastConnectedAt: Date?

    public init(id: UUID = UUID(), deviceID: String, displayName: String, pinnedPublicKey: Data, pairedAt: Date, lastConnectedAt: Date? = nil)
}

/// Registry of paired Anywhere-runtime devices, persisted as JSON — mirrors `ACPAgentStore`
/// exactly (synchronous, not an actor; tiny; touched rarely — Settings edits and pairing events).
public final class PairedDeviceStore: @unchecked Sendable {
    public init(persistenceURL: URL? = nil, fileManager: FileManager = .default)
    /// Reads the full list fresh from disk. Returns `[]` if no file exists yet.
    public func load() throws -> [PairedDevice]
    /// Appends `device`. Callers are responsible for using a fresh `UUID`.
    public func add(_ device: PairedDevice) throws
    /// Replaces the entry whose `id` matches `device.id`. No-op if no entry matches.
    public func update(_ device: PairedDevice) throws
    /// Removes the entry with `id` — the Revoke action's model-layer half. No-op if no entry matches.
    public func remove(id: UUID) throws
    /// Looks up a paired device by its peer-supplied `deviceID` (not this store's own `id`) — the
    /// lookup `SignedSignalingChannel`/`CloudKitSignalingChannel` construction needs before
    /// opening a channel for an inbound connection request. `nil` for an unpaired/unknown device.
    public func device(deviceID: String) throws -> PairedDevice?
}
```

- [ ] **Step 1: Write failing tests**, mirroring `ACPAgentStoreTests` (read it first — `Tests/AnglesiteCoreTests/ACPAgentStoreTests.swift` — to match its exact fixture/temp-directory pattern) plus the new `device(deviceID:)` lookup:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite
struct PairedDeviceStoreTests {
    static func makeStore() -> PairedDeviceStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paired-devices-\(UUID().uuidString)")
        return PairedDeviceStore(persistenceURL: dir.appendingPathComponent("paired-devices.json"))
    }

    @Test func loadOnMissingFileReturnsEmpty() throws {
        #expect(try Self.makeStore().load() == [])
    }

    @Test func addThenLoadRoundTrips() throws {
        let store = Self.makeStore()
        let device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04, 0x01]), pairedAt: Date(timeIntervalSince1970: 1000))
        try store.add(device)
        #expect(try store.load() == [device])
    }

    @Test func updateReplacesMatchingID() throws {
        let store = Self.makeStore()
        var device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04]), pairedAt: Date(timeIntervalSince1970: 1000))
        try store.add(device)
        device.lastConnectedAt = Date(timeIntervalSince1970: 2000)
        try store.update(device)
        #expect(try store.load() == [device])
    }

    @Test func updateIsNoOpForUnknownID() throws {
        let store = Self.makeStore()
        try store.update(PairedDevice(deviceID: "ghost", displayName: "Ghost", pinnedPublicKey: Data(), pairedAt: Date()))
        #expect(try store.load() == [])
    }

    @Test func removeDeletesMatchingID() throws {
        let store = Self.makeStore()
        let device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04]), pairedAt: Date())
        try store.add(device)
        try store.remove(id: device.id)
        #expect(try store.load() == [])
    }

    @Test func deviceLookupFindsByPeerDeviceIDNotStoreID() throws {
        let store = Self.makeStore()
        let device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04]), pairedAt: Date())
        try store.add(device)
        #expect(try store.device(deviceID: "phone-1") == device)
        #expect(try store.device(deviceID: "unknown-device") == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement `PairedDevice.swift`** (the struct above, `Codable`/`Identifiable`/`Sendable`/`Equatable`, memberwise `init` with `id`/`lastConnectedAt` defaults).

- [ ] **Step 4: Implement `PairedDeviceStore.swift`**, copying `ACPAgentStore.swift`'s structure exactly (`load`/`add`/`update`/`remove`/private `persist`/encoder/decoder/`defaultPersistenceURL`), substituting `[PairedDevice]` for `[ACPAgentConnection]`, `"paired-devices.json"` for `"acp-agents.json"`, and adding the one new method:

```swift
    /// Looks up a paired device by its peer-supplied `deviceID`. `nil` if unpaired/unknown.
    public func device(deviceID: String) throws -> PairedDevice? {
        try load().first { $0.deviceID == deviceID }
    }
```

- [ ] **Step 5: Run to verify pass** — PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/PairedDevice.swift Sources/AnglesiteCore/PairedDeviceStore.swift \
  Tests/AnglesiteCoreTests/PairedDeviceStoreTests.swift
git commit -m "feat(#1208): PairedDevice + PairedDeviceStore"
```

---

### Task 4: `SignedSignalingChannel`

**Files:**
- Create: `Sources/AnglesiteP2P/SignedSignalingChannel.swift`
- Test: `Tests/AnglesiteP2PTests/SignedSignalingChannelTests.swift`

**Interfaces:**
- Consumes: `SignalingChannel`, `SignalingEnvelope` (P0, `Sources/AnglesiteP2P/Signaling.swift` — exact protocol reproduced in this plan's design spec §Architecture 4), `DevicePairingKeyPair` (Task 2, `AnglesiteCore` — this file needs `import AnglesiteCore`, check `Package.swift`'s `AnglesiteP2P` target doesn't already forbid that dependency direction; P0's `AnglesiteP2P` already depends on `AnglesiteCore` for `JSONValue`/`MCPClient`, so this should be unproblematic).
- Produces:

```swift
/// Wraps any `SignalingChannel` with sign-on-send / verify-on-receive against a pinned peer
/// public key (design spec §Architecture 4). Wraps only `SignalingEnvelope.payload` — `seq`/
/// `sender`/`kind` stay in the clear so the inner channel's own delivery/ordering logic (e.g.
/// `FileSignalingChannel`'s per-sender seq buffering) keeps working unmodified underneath.
///
/// A bad or missing signature drops that envelope from the stream entirely — it is never yielded
/// to a caller (`WebRTCPeer`) — logged loudly, not thrown, matching the design spec's "the caller
/// just sees the same stall a network partition would produce" posture (no distinct attack UX).
///
/// This type has no CloudKit dependency and is fully testable against `FileSignalingChannel` or
/// a fake `SignalingChannel` — this is where the adversarial pairing tests (tampered SDP, wrong
/// key) live, deliberately independent of whether real CloudKit entitlements are provisioned.
public actor SignedSignalingChannel: SignalingChannel {
    /// - Parameters:
    ///   - inner: The transport to wrap — `FileSignalingChannel` in tests, `CloudKitSignalingChannel`
    ///     in production.
    ///   - signingKey: This device's own key pair, used to sign outbound envelopes.
    ///   - peerPublicKey: The pinned public key (X9.63 format) inbound envelopes must verify
    ///     against. Callers resolve this from `PairedDeviceStore` *before* constructing this
    ///     channel — an unpaired/unknown device never reaches this type at all (design spec
    ///     §Error handling: "refused at channel-construction time").
    ///   - onLog: Fires once per dropped (unverifiable) envelope, with a human-readable reason.
    ///     Callers route this to their own log sink — "logs are sacred" applies to a dropped
    ///     envelope exactly as it does to any other failure in this codebase.
    public init(
        wrapping inner: any SignalingChannel,
        signingKey: DevicePairingKeyPair,
        peerPublicKey: Data,
        onLog: @escaping @Sendable (String) -> Void = { _ in }
    )

    public func send(_ envelope: SignalingEnvelope) async throws
    public func envelopes() -> AsyncStream<SignalingEnvelope>
    public func close() async
}
```

- [ ] **Step 1: Write failing tests.** Use `FileSignalingChannel` as the inner transport (two `SignedSignalingChannel`s sharing one `FileSignalingChannel` mailbox directory, mirroring `FileSignalingChannelTests`' own two-channels-sharing-a-mailbox pattern) for the happy path, and a small local fake `SignalingChannel` for the adversarial cases where a raw (unsigned) envelope needs to be injected directly:

```swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteP2P

@Suite
struct SignedSignalingChannelTests {
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signed-signaling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func signedEnvelopeRoundTripsAndVerifies() async throws {
        let dir = try Self.makeTempDir()
        let alice = DevicePairingKeyPair()
        let bob = DevicePairingKeyPair()
        let aliceChannel = SignedSignalingChannel(
            wrapping: FileSignalingChannel(directory: dir, sender: "alice"),
            signingKey: alice, peerPublicKey: bob.publicKeyData)
        let bobChannel = SignedSignalingChannel(
            wrapping: FileSignalingChannel(directory: dir, sender: "bob"),
            signingKey: bob, peerPublicKey: alice.publicKeyData)

        try await aliceChannel.send(SignalingEnvelope(seq: 1, sender: "alice", kind: .offer, payload: "sdp-offer-text"))

        var iterator = bobChannel.envelopes().makeAsyncIterator()
        let received = try #require(await iterator.next())
        #expect(received.payload == "sdp-offer-text")
        #expect(received.kind == .offer)

        await aliceChannel.close()
        await bobChannel.close()
    }

    /// A minimal `SignalingChannel` fake that hands back exactly the envelopes it's told to,
    /// letting adversarial tests inject a raw (unsigned or tampered) envelope directly — something
    /// `FileSignalingChannel` can't do, since it only ever delivers what a `SignedSignalingChannel`
    /// itself wrote.
    actor ScriptedChannel: SignalingChannel {
        private var continuation: AsyncStream<SignalingEnvelope>.Continuation?
        private(set) var sent: [SignalingEnvelope] = []
        func send(_ envelope: SignalingEnvelope) async throws { sent.append(envelope) }
        func envelopes() -> AsyncStream<SignalingEnvelope> {
            AsyncStream { continuation = $0 }
        }
        func close() async { continuation?.finish() }
        func inject(_ envelope: SignalingEnvelope) { continuation?.yield(envelope) }
    }

    @Test func tamperedPayloadIsDroppedNotDelivered() async throws {
        let alice = DevicePairingKeyPair()
        let bob = DevicePairingKeyPair()
        let inner = ScriptedChannel()
        var loggedReasons: [String] = []
        let bobChannel = SignedSignalingChannel(
            wrapping: inner, signingKey: bob, peerPublicKey: alice.publicKeyData,
            onLog: { reason in loggedReasons.append(reason) })

        // A legitimately-signed envelope from alice's key, over a DIFFERENT payload than what's
        // actually being delivered — simulates a tampered-in-transit SDP.
        let signature = try alice.sign(Data("original-sdp".utf8))
        let wrapped = try JSONSerialization.data(withJSONObject: [
            "payload": "tampered-sdp", "signature": signature.base64EncodedString(),
        ])
        await inner.inject(SignalingEnvelope(seq: 1, sender: "alice", kind: .offer, payload: String(decoding: wrapped, as: UTF8.self)))

        var iterator = bobChannel.envelopes().makeAsyncIterator()
        let raceResult = await withTaskGroup(of: SignalingEnvelope?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask { try? await Task.sleep(for: .milliseconds(300)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(raceResult == nil, "a tampered envelope must never be delivered")
        #expect(!loggedReasons.isEmpty)
    }

    @Test func envelopeFromUnpinnedKeyIsDroppedNotDelivered() async throws {
        let bob = DevicePairingKeyPair()
        let attacker = DevicePairingKeyPair()
        let pinnedButNotAttacker = DevicePairingKeyPair()
        let inner = ScriptedChannel()
        let bobChannel = SignedSignalingChannel(wrapping: inner, signingKey: bob, peerPublicKey: pinnedButNotAttacker.publicKeyData)

        let signature = try attacker.sign(Data("sdp-offer-text".utf8))
        let wrapped = try JSONSerialization.data(withJSONObject: [
            "payload": "sdp-offer-text", "signature": signature.base64EncodedString(),
        ])
        await inner.inject(SignalingEnvelope(seq: 1, sender: "attacker", kind: .offer, payload: String(decoding: wrapped, as: UTF8.self)))

        var iterator = bobChannel.envelopes().makeAsyncIterator()
        let raceResult = await withTaskGroup(of: SignalingEnvelope?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask { try? await Task.sleep(for: .milliseconds(300)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(raceResult == nil, "an envelope signed by an unpinned key must never be delivered")
    }

    @Test func malformedWrapperJSONIsDroppedNotDelivered() async throws {
        let bob = DevicePairingKeyPair()
        let alice = DevicePairingKeyPair()
        let inner = ScriptedChannel()
        let bobChannel = SignedSignalingChannel(wrapping: inner, signingKey: bob, peerPublicKey: alice.publicKeyData)

        await inner.inject(SignalingEnvelope(seq: 1, sender: "alice", kind: .offer, payload: "not-json-at-all"))

        var iterator = bobChannel.envelopes().makeAsyncIterator()
        let raceResult = await withTaskGroup(of: SignalingEnvelope?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask { try? await Task.sleep(for: .milliseconds(300)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(raceResult == nil)
    }

    @Test func closeFinishesTheEnvelopesStream() async throws {
        let dir = try Self.makeTempDir()
        let alice = DevicePairingKeyPair()
        let channel = SignedSignalingChannel(
            wrapping: FileSignalingChannel(directory: dir, sender: "alice"),
            signingKey: alice, peerPublicKey: alice.publicKeyData)
        var iterator = channel.envelopes().makeAsyncIterator()
        await channel.close()
        let result = await iterator.next()
        #expect(result == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement `Sources/AnglesiteP2P/SignedSignalingChannel.swift`.**

```swift
import Foundation
import AnglesiteCore

/// Wraps any `SignalingChannel` with sign-on-send / verify-on-receive against a pinned peer
/// public key (design spec §Architecture 4). See this plan's Task 4 doc comment for the full
/// rationale — summarized: only `payload` is wrapped, a failed verification drops the envelope
/// silently rather than throwing, and this type has zero CloudKit dependency.
public actor SignedSignalingChannel: SignalingChannel {
    private let inner: any SignalingChannel
    private let signingKey: DevicePairingKeyPair
    private let peerPublicKey: Data
    private let onLog: @Sendable (String) -> Void

    public init(
        wrapping inner: any SignalingChannel,
        signingKey: DevicePairingKeyPair,
        peerPublicKey: Data,
        onLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.inner = inner
        self.signingKey = signingKey
        self.peerPublicKey = peerPublicKey
        self.onLog = onLog
    }

    public func send(_ envelope: SignalingEnvelope) async throws {
        let signature = try signingKey.sign(Data(envelope.payload.utf8))
        let wrapped: [String: String] = [
            "payload": envelope.payload,
            "signature": signature.base64EncodedString(),
        ]
        let wrappedData = try JSONSerialization.data(withJSONObject: wrapped)
        var signedEnvelope = envelope
        signedEnvelope.payload = String(decoding: wrappedData, as: UTF8.self)
        try await inner.send(signedEnvelope)
    }

    public func envelopes() -> AsyncStream<SignalingEnvelope> {
        AsyncStream { continuation in
            let task = Task {
                for await envelope in inner.envelopes() {
                    guard let verified = verify(envelope) else {
                        onLog("dropped unverifiable envelope from \(envelope.sender) (seq \(envelope.seq))")
                        continue
                    }
                    continuation.yield(verified)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func close() async {
        await inner.close()
    }

    /// Verifies and unwraps one inbound envelope. `nil` for anything that doesn't parse as the
    /// wrapper JSON, doesn't carry a valid signature, or doesn't verify against `peerPublicKey`.
    private func verify(_ envelope: SignalingEnvelope) -> SignalingEnvelope? {
        guard let wrappedData = envelope.payload.data(using: .utf8),
              let wrapped = try? JSONSerialization.jsonObject(with: wrappedData) as? [String: String],
              let originalPayload = wrapped["payload"],
              let signatureBase64 = wrapped["signature"],
              let signature = Data(base64Encoded: signatureBase64)
        else { return nil }
        guard DevicePairingKeyPair.verify(signature: signature, for: Data(originalPayload.utf8), publicKeyData: peerPublicKey)
        else { return nil }
        var verifiedEnvelope = envelope
        verifiedEnvelope.payload = originalPayload
        return verifiedEnvelope
    }
}
```

Note: `envelopes()`'s `AsyncStream { continuation in ... }` initializer form (task launched inside the builder closure, cancelled via `onTermination`) mirrors the pattern `FileSignalingChannel`/`HTTPTransport` already use elsewhere in this codebase for wrapping one `AsyncStream` around another — verify against one of those two files' actual `envelopes()`/`inbound()` implementation before assuming this exact shape compiles as written; adjust to match this checkout's real `AsyncStream` continuation API if it differs.

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteP2P/SignedSignalingChannel.swift Tests/AnglesiteP2PTests/SignedSignalingChannelTests.swift
git commit -m "feat(#1208): SignedSignalingChannel — sign/verify decorator"
```

---

### Task 5: `CloudKitPairingService` — device announce + push registration wiring

**Files:**
- Create: `Sources/AnglesiteP2P/CloudKitPairingService.swift` (Darwin-gated, `#if canImport(CloudKit)`)
- Modify: `Sources/anglesite-remote-helper/main.swift` (call `registerForRemoteNotifications()` from `applicationDidFinishLaunching`, now that Task 1 makes it callable)
- Test: `Tests/AnglesiteP2PTests/CloudKitPairingServiceTests.swift`, gated `ANGLESITE_CK_TESTS=1`

**Interfaces:**
- Consumes: `DevicePairingKeyPair` (Task 2), `PairedDeviceStore` (Task 3).
- Produces:

```swift
#if canImport(CloudKit)
import CloudKit

/// Writes and observes `DeviceAnnounceRecord`s in the owner's private CloudKit database — the
/// pairing handshake's own CloudKit interaction, distinct from `CloudKitSignalingChannel`'s
/// signaling-envelope records (design spec §Architecture 5). Both devices share the same Apple
/// ID's private database; there is no server-side account or infrastructure.
public actor CloudKitPairingService {
    /// - Parameter container: `CKContainer(identifier: "iCloud.io.dwk.anglesite")` in
    ///   production — injectable so tests can point at a different (or the same, gated) real
    ///   container without touching production data.
    public init(container: CKContainer)

    /// Publishes this device's own announce record (deviceID, public key, display name) so a
    /// peer that already knows to look can find it.
    public func announce(deviceID: String, publicKeyData: Data, displayName: String) async throws

    /// Subscribes to new `DeviceAnnounceRecord`s and yields each one as it arrives — the
    /// CKQuerySubscription push-delivery seam. `AsyncStream` mirrors `SignalingChannel.envelopes()`'s
    /// shape for consistency, though this type does not itself conform to `SignalingChannel`
    /// (it's a distinct, smaller protocol surface — one-shot announce + a stream, not
    /// send/receive/close).
    public func announcedDevices() -> AsyncStream<DeviceAnnounceRecord>
}

/// One device's pairing announcement — CloudKit-record-shaped, not `Codable` (CloudKit's own
/// `CKRecord` is the wire format; this is the typed Swift view over it).
public struct DeviceAnnounceRecord: Sendable, Equatable {
    public let deviceID: String
    public let publicKeyData: Data
    public let displayName: String
    public let createdAt: Date
}
#endif
```

- [ ] **Step 1: Confirm the exact CloudKit API shape before writing tests.** This is the plan's single highest-uncertainty point (Global Constraints: CloudKit is genuinely new to this codebase, no existing precedent to crib from). Before implementing, the engineer must confirm against Apple's current documentation (developer.apple.com/documentation/cloudkit, current as of this checkout's SDK):
  - Whether `CKDatabase` exposes async `save(_:)`/`records(matching:)`/`delete(withID:)` directly (modern CloudKit does — verify the exact method names and `CKQuery`/`CKQueryOperation` vs. a newer async query API for this SDK version).
  - The exact `CKQuerySubscription` construction: `CKQuerySubscription(recordType:predicate:subscriptionID:options:)` with `notificationInfo` set to a `CKSubscription.NotificationInfo` configured for silent/content-available push (`shouldSendContentAvailable = true`) so `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` fires without a visible banner.
  - How `CKNotification.notification(fromRemoteNotificationDictionary:)` and `CKQueryNotification` are used to figure out which record changed inside the `didReceiveRemoteNotification` callback (vs. just re-querying on any push, which is simpler and likely sufficient for P2's scale — one owner, a handful of devices).
  Record the confirmed API shape in this task's implementation report before writing code — do not guess silently if the shape above turns out to be stale for the SDK this checkout targets.

- [ ] **Step 2: Write failing tests** (gated, since they need a real CloudKit container/entitlement):

```swift
import Testing
import Foundation
#if canImport(CloudKit)
import CloudKit
@testable import AnglesiteP2P

@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANGLESITE_CK_TESTS"] == "1"))
struct CloudKitPairingServiceTests {
    @Test func announceThenAnnouncedDevicesReceivesIt() async throws {
        let container = CKContainer(identifier: "iCloud.io.dwk.anglesite")
        let service = CloudKitPairingService(container: container)
        var iterator = service.announcedDevices().makeAsyncIterator()

        let deviceID = "test-device-\(UUID().uuidString)"
        try await service.announce(deviceID: deviceID, publicKeyData: Data([0x04, 0x01, 0x02]), displayName: "Test Device")

        let received = try #require(await iterator.next())
        #expect(received.deviceID == deviceID)
        #expect(received.publicKeyData == Data([0x04, 0x01, 0x02]))
        #expect(received.displayName == "Test Device")
    }
}
#endif
```

Note: this test needs real network I/O and a real signed-in iCloud account on the machine running it — matching the container-test pattern's own "opt-in, real infra" posture. It will very likely need a bounded timeout wrapper (mirroring `SignedSignalingChannelTests`' race-against-timeout pattern) rather than an unbounded `await iterator.next()`, since CloudKit push/propagation latency is not instant — add that wrapper when implementing if a bare `next()` proves flaky.

- [ ] **Step 3: Implement `CloudKitPairingService.swift`** per the confirmed API shape from Step 1. Structure: `announce` builds a `CKRecord(recordType: "DeviceAnnounceRecord")`, sets `deviceID`/`publicKeyData` (as `CKAsset` or raw `Data` field — confirm CloudKit's field-size limits don't require `CKAsset` for a 65-byte key; a plain `Data` field is almost certainly fine at this size, but confirm), `displayName`, `createdAt`, and saves it via the private database. `announcedDevices()` sets up the `CKQuerySubscription` (or, if Step 1's research finds subscriptions add more complexity than P2's scale warrants, a documented polling fallback is an acceptable simplification — note the choice and why in the implementation report, don't silently pick one without saying so).

- [ ] **Step 4: Wire push registration into the helper.** In `Sources/anglesite-remote-helper/main.swift`'s `HelperAppDelegate.applicationDidFinishLaunching` (Task 1), add:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
        Task { await runSession() }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        // Routes CloudKit push notifications to whichever service is listening (CloudKitPairingService
        // during pairing, CloudKitSignalingChannel during an active session — Task 6 wires the
        // session-side consumer). Exact dispatch shape depends on Step 1's confirmed notification
        // API; implement once that's settled, not before.
    }
```

Confirm the exact `NSApplicationDelegate` remote-notification callback signature for macOS (`application(_:didReceiveRemoteNotification:)` without a completion handler is the AppKit shape, distinct from UIKit's `fetchCompletionHandler` variant — verify against Apple's current AppKit docs, don't assume the UIKit signature carries over).

- [ ] **Step 5: Run to verify pass** — `ANGLESITE_CK_TESTS=1 swift test --filter CloudKitPairingServiceTests` → PASS (requires a real signed-in iCloud account; skips cleanly without the env var).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteP2P/CloudKitPairingService.swift Sources/anglesite-remote-helper/main.swift \
  Tests/AnglesiteP2PTests/CloudKitPairingServiceTests.swift
git commit -m "feat(#1208): CloudKitPairingService — device announce + push registration"
```

---

### Task 6: `CloudKitSignalingChannel`

**Files:**
- Create: `Sources/AnglesiteP2P/CloudKitSignalingChannel.swift` (Darwin-gated, `#if canImport(CloudKit)`)
- Test: `Tests/AnglesiteP2PTests/CloudKitSignalingChannelTests.swift`, gated `ANGLESITE_CK_TESTS=1`

**Interfaces:**
- Consumes: `SignalingChannel`, `SignalingEnvelope` (P0). Reuses whatever `CKQuerySubscription`/notification approach Task 5 Step 1 confirmed.
- Produces:

```swift
#if canImport(CloudKit)
import CloudKit

/// The real, cross-network `SignalingChannel` conformer (design spec §Architecture 5) — the P2
/// replacement for `FileSignalingChannel`'s local-dev-only mailbox. SDP/ICE envelopes as
/// short-TTL `SignalingEnvelopeRecord`s in the owner's private database, delivered by
/// `CKQuerySubscription` push (or the polling fallback Task 5 may have settled on). This type is
/// signing-agnostic — it transports whatever `payload` string it's given; production always
/// wraps it in `SignedSignalingChannel` (design spec's explicit clarification, self-review
/// 2026-08-13).
public actor CloudKitSignalingChannel: SignalingChannel {
    /// - Parameters:
    ///   - container: `CKContainer(identifier: "iCloud.io.dwk.anglesite")` in production.
    ///   - sessionID: Scopes this channel to one signaling session so concurrent unrelated
    ///     sessions in the same private database never cross-deliver.
    ///   - sender: This endpoint's stable id, same role as `FileSignalingChannel`'s `sender`.
    public init(container: CKContainer, sessionID: String, sender: String)

    public func send(_ envelope: SignalingEnvelope) async throws
    public func envelopes() -> AsyncStream<SignalingEnvelope>
    public func close() async
}
#endif
```

- [ ] **Step 1: Write failing tests**, mirroring `FileSignalingChannelTests`' three cases (never-echoes-own, out-of-order-delivered-in-order, close-finishes-stream) against two real `CloudKitSignalingChannel`s sharing a `sessionID`, gated the same way as Task 5's tests:

```swift
import Testing
import Foundation
#if canImport(CloudKit)
import CloudKit
@testable import AnglesiteP2P

@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANGLESITE_CK_TESTS"] == "1"))
struct CloudKitSignalingChannelTests {
    @Test func deliversOtherSendersEnvelopesButNeverEchoesOwn() async throws {
        let container = CKContainer(identifier: "iCloud.io.dwk.anglesite")
        let sessionID = "test-session-\(UUID().uuidString)"
        let host = CloudKitSignalingChannel(container: container, sessionID: sessionID, sender: "host")
        let client = CloudKitSignalingChannel(container: container, sessionID: sessionID, sender: "client")

        try await host.send(SignalingEnvelope(seq: 1, sender: "host", kind: .offer, payload: "offer-sdp"))

        var clientIterator = client.envelopes().makeAsyncIterator()
        let received = try #require(await clientIterator.next())
        #expect(received.payload == "offer-sdp")

        // host must never see its own write on its own stream.
        var hostIterator = host.envelopes().makeAsyncIterator()
        let neverArrives = await withTaskGroup(of: SignalingEnvelope?.self) { group in
            group.addTask { await hostIterator.next() }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(neverArrives == nil)

        await host.close()
        await client.close()
    }

    @Test func closeFinishesTheEnvelopesStream() async throws {
        let container = CKContainer(identifier: "iCloud.io.dwk.anglesite")
        let channel = CloudKitSignalingChannel(container: container, sessionID: "test-session-\(UUID().uuidString)", sender: "host")
        var iterator = channel.envelopes().makeAsyncIterator()
        await channel.close()
        let result = await iterator.next()
        #expect(result == nil)
    }
}
#endif
```

- [ ] **Step 2: Implement, reusing exactly the CKRecord/subscription approach Task 5 Step 1 confirmed and Task 5's implementation established** (don't re-derive the CloudKit plumbing from scratch — `CloudKitPairingService` and `CloudKitSignalingChannel` should share the same save/query/subscribe idioms, just different record types and fields). `send` builds a `SignalingEnvelopeRecord` (`seq`, `sender`, `kind`, `payload`, `sessionID`) and saves it. `envelopes()` subscribes/polls for new records matching `sessionID`, filters out records where `sender == self.sender` (never echo own writes — same rule `FileSignalingChannel` enforces), decodes into `SignalingEnvelope`, and — since CloudKit has no native TTL — deletes each record immediately after yielding it (the "short TTL" the design calls for is enforced by the reader, not the database).

- [ ] **Step 3: Run to verify pass** — `ANGLESITE_CK_TESTS=1 swift test --filter CloudKitSignalingChannelTests` → PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteP2P/CloudKitSignalingChannel.swift Tests/AnglesiteP2PTests/CloudKitSignalingChannelTests.swift
git commit -m "feat(#1208): CloudKitSignalingChannel — real cross-network signaling"
```

---

### Task 7: Presence heartbeat writer

**Files:**
- Create: `Sources/AnglesiteP2P/PresenceHeartbeatWriter.swift` (Darwin-gated)
- Test: `Tests/AnglesiteP2PTests/PresenceHeartbeatWriterTests.swift` (unit-level, injected CloudKit seam — no gated real-CloudKit test needed for this small a piece; write-only, one field)

**Interfaces:**
- Produces:

```swift
#if canImport(CloudKit)
/// Writes/replaces a single `PresenceHeartbeatRecord` (design spec's Failure Modes: "Mac writes
/// a lightweight presence heartbeat to CloudKit ~every 15 min"). Write-side only in P2 — nothing
/// consumes this yet (P4's job, once a phone UI exists to render "last reachable at...").
public actor PresenceHeartbeatWriter {
    /// - Parameters:
    ///   - save: The CKRecord-save seam (`container.privateCloudDatabase.save(_:)` in
    ///     production) — injected so tests can verify write timing/content without real CloudKit.
    ///   - interval: Defaults to 15 minutes per the design spec.
    public init(save: @escaping @Sendable (Date) async throws -> Void, interval: Duration = .seconds(900))

    /// Runs until cancelled: writes immediately, then every `interval`.
    public func run() async
}
#endif
```

- [ ] **Step 1: Write failing tests** using an injected `save` closure (no real CloudKit needed):

```swift
import Testing
import Foundation
@testable import AnglesiteP2P

@Suite
struct PresenceHeartbeatWriterTests {
    @Test func writesImmediatelyOnStart() async throws {
        let writes = LockedArray<Date>()
        let writer = PresenceHeartbeatWriter(save: { date in writes.append(date) }, interval: .seconds(3600))
        let task = Task { await writer.run() }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(writes.count == 1)
    }

    @Test func writesAgainAfterInterval() async throws {
        let writes = LockedArray<Date>()
        let writer = PresenceHeartbeatWriter(save: { date in writes.append(date) }, interval: .milliseconds(50))
        let task = Task { await writer.run() }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        #expect(writes.count >= 2)
    }
}

/// Thread-safe append-only collector for the writer's timing assertions.
final class LockedArray<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T] = []
    func append(_ value: T) { lock.lock(); values.append(value); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}
```

Check whether a similar locked-collector test helper already exists elsewhere in `Tests/AnglesiteP2PTests/` (P0's suites do a fair amount of concurrent-timing testing) before adding a new one — reuse if so.

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement.**

```swift
#if canImport(CloudKit)
import Foundation

public actor PresenceHeartbeatWriter {
    private let save: @Sendable (Date) async throws -> Void
    private let interval: Duration

    public init(save: @escaping @Sendable (Date) async throws -> Void, interval: Duration = .seconds(900)) {
        self.save = save
        self.interval = interval
    }

    public func run() async {
        while !Task.isCancelled {
            do { try await save(Date()) } catch { /* best-effort: a missed heartbeat is not fatal, next tick retries */ }
            try? await Task.sleep(for: interval)
        }
    }
}
#endif
```

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Wire the production `save` closure** to `CKRecord(recordType: "PresenceHeartbeatRecord", recordID: <fixed ID>)`-then-save-with-`.changedKeys` merge policy (so concurrent writes from a stale prior run don't conflict-fail) — implement once Task 5's confirmed CloudKit save idiom is established; reuse it rather than re-deriving.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteP2P/PresenceHeartbeatWriter.swift Tests/AnglesiteP2PTests/PresenceHeartbeatWriterTests.swift
git commit -m "feat(#1208): PresenceHeartbeatWriter — write-side only"
```

---

### Task 8: Settings UI — QR pairing pane + device list

**Files:**
- Create: `Sources/AnglesiteApp/DevicePairingSettingsView.swift`
- Modify: `Sources/AnglesiteApp/SettingsView.swift` (+ 5th `.tabItem`)
- Modify: `project.yml` if the new file needs an explicit `sources:` entry (check whether `Sources/AnglesiteApp` is already a wildcard-included directory — likely yes, given every other file in that directory isn't individually listed; confirm before assuming a `project.yml` edit is needed at all)

**Interfaces:**
- Consumes: `DevicePairingKeyPair` (Task 2), `PairedDeviceStore` (Task 3), `CloudKitPairingService` (Task 5).
- Produces: a SwiftUI view, no new public API beyond the view type itself (app-target-internal, matching every other `*SettingsView` in the file).

- [ ] **Step 1: Read `AgentsSettingsView` and `CloudflareOAuthSignInView` in full** (`Sources/AnglesiteApp/SettingsView.swift:71-178`, `Sources/AnglesiteApp/CloudflareOAuthSignInView.swift`) before writing this task's view — this plan's design spec names them as the exact templates to mirror; don't improvise a different Settings-pane shape.

- [ ] **Step 2: Implement `DevicePairingSettingsView`** — a `Form { Section { ... } }` matching the house style, with:
  - A QR code image (`CIFilter(name: "CIQRCodeGenerator")`, `inputMessage` = JSON `{deviceID, publicKey}` built from `DevicePairingKeyPair`/a locally-generated stable device ID, `inputCorrectionLevel` = `"M"`) rendered via `NSImage`/`Image(nsImage:)`, regenerated fresh each time the pane appears (not persisted, per the design spec).
  - A paired-devices list (`ForEach` over `PairedDeviceStore.load()`, `LabeledContent` rows showing `displayName` + `lastConnectedAt`, a "Revoke" button per row calling `store.remove(id:)` and refreshing the list) — mirror `AgentsSettingsView`'s `ForEach`/`Button("Remove")` row shape exactly, substituting "Revoke" for "Remove" as the button label per the design spec's own wording.
  - No Keychain cleanup on Revoke (unlike `AgentsSettingsView`'s ACP-token clear) — the pinned key isn't a secret, per the design spec.

Write concrete SwiftUI code here matching this file's exact house style (`.formStyle(.grouped)`, `.font(.caption).foregroundStyle(.secondary)` explanatory text) — the engineer implementing this task should produce it by directly following `AgentsSettingsView`'s real, current code shape rather than a plan-authored guess, since UI code drifts easily and the actual file is the ground truth; this step intentionally does not paste a full verbatim view body for that reason (contrast with every other task's fully-verbatim code — this is the plan's other deliberate "confirm against the real thing" point, alongside Task 5's CloudKit API research, per this repo's established precedent for handling genuine implementation-time unknowns honestly rather than guessing).

- [ ] **Step 3: Add the 5th tab to `SettingsView`:**

```swift
DevicePairingSettingsView().tabItem { Label("iPhone/iPad", systemImage: "iphone.and.arrow.forward") }
```

(Confirm the SF Symbol name renders sensibly on this Xcode/macOS SDK — pick a reasonable alternative like `"qrcode"` if `"iphone.and.arrow.forward"` doesn't exist on this toolchain.)

- [ ] **Step 4: Build**

```bash
xcodegen generate
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual smoke** — open Settings, confirm the new tab renders a QR code and an (empty, until Task 9's real pairing flow exists) device list without crashing.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/DevicePairingSettingsView.swift Sources/AnglesiteApp/SettingsView.swift
git commit -m "feat(#1208): Anglesite on iPhone/iPad Settings pane"
```

---

### Task 9: Wire it together — helper switches to CloudKit signaling

**Files:**
- Modify: `Sources/anglesite-remote-helper/main.swift`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Replace `runSession()`'s `FileSignalingChannel` construction** with the real production chain: resolve the requesting device's pinned key from `PairedDeviceStore` (refuse if unknown, per design spec §Error handling), construct `CloudKitSignalingChannel` wrapped in `SignedSignalingChannel`, keep everything else (`WebRTCPeer.connect(role:signaling:)`, the bridge/heartbeat `async let`s) unchanged — `WebRTCPeer` doesn't know or care which `SignalingChannel` conformer it's driving.

- [ ] **Step 2: Resolve `siteID` from the pairing/signaling payload instead of the CLI `<site-root>` argument** — closing the gap P1's own plan explicitly deferred ("P1 does not solve cross-sandbox site discovery... P2+ (real pairing) territory"; `RemoteSiteResolver`, already built and tested in P1 but never wired to a real caller, is exactly for this). Exact wire shape (where in the `control` channel or signaling handshake the siteID travels) is this task's own design call — check `RemoteSiteResolver`'s actual method signature (`Sources/AnglesiteRemote/RemoteSiteResolver.swift`) before wiring, and keep the existing CLI-arg path available behind a flag for the E2E test harness (Task 10) rather than deleting P1's own working test entry point outright.

- [ ] **Step 3: Manual entitlements note (not a code step).** Production wiring depends on `com.apple.developer.icloud-container-identifiers`/`CloudKit` being added to `Resources/AnglesiteRemote.entitlements` and `com.apple.developer.icloud-services` gaining `CloudKit` in `Resources/Anglesite.entitlements` — both require Apple Developer portal changes (Team `KH7H8Y25RT`) this plan cannot perform, mirroring P1's own App-Groups note. Until then, wire `CloudKitSignalingChannel`'s production construction behind the same kind of graceful-degradation check P1 established, with an honest owner-facing failure message when the container/service isn't available. Add the manual note text to `Resources/AnglesiteRemote.entitlements`'s existing comment block (which already documents the App-Groups gap) rather than a separate note.

- [ ] **Step 4: Build + run the existing E2E test in its CLI-arg-fallback mode** to confirm no regression:

```bash
xcodegen generate
swift build --product anglesite-remote-helper
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 ANGLESITE_P2P_E2E=1 \
  swift test --filter HelperContainerE2ETests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/anglesite-remote-helper/main.swift Resources/AnglesiteRemote.entitlements
git commit -m "feat(#1208): wire the helper to real CloudKit signaling"
```

---

### Task 10: Exit-criterion E2E — two Mac processes pair and connect over real CloudKit

**Files:**
- Modify: `Tests/AnglesiteRemoteTests/HelperContainerE2ETests.swift`

**Interfaces:**
- Consumes: everything above, plus a real container boot (existing gate) and real CloudKit (`ANGLESITE_CK_TESTS=1`).

- [ ] **Step 1: Write the gated test**, structured like `HelperContainerE2ETests`'s existing tests but with the "phone" role played by this test process directly (per the design spec's practical exit criterion — see Global Constraints):

```swift
@Suite(.enabled(if:
    ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_TESTS"] == "1" &&
    ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_E2E"] == "1" &&
    ProcessInfo.processInfo.environment["ANGLESITE_P2P_E2E"] == "1" &&
    ProcessInfo.processInfo.environment["ANGLESITE_CK_TESTS"] == "1"), .serialized)
struct CloudKitPairingE2ETests {
    @Test(.timeLimit(.minutes(15)))
    func twoMacProcessesPairAndConnectOverRealCloudKit() async throws {
        // 1. This test process plays "Mac": generates a DevicePairingKeyPair, gets the QR
        //    payload string DevicePairingSettingsView would encode (no image/camera involved —
        //    the design spec's own "phone consumes the payload string directly" simplification).
        // 2. Spawn anglesite-remote-helper as a real second process (mirrors
        //    HelperContainerE2ETests's existing pattern), pointed at real CloudKit.
        // 3. This test process plays "phone": writes its own DeviceAnnounceRecord using the QR
        //    payload's Mac public key + a fresh key pair of its own.
        // 4. Wait for the helper to pick up the announce (CloudKitPairingService), pin the key.
        // 5. Drive a real, signed CloudKitSignalingChannel handshake + MCP round trip, exactly
        //    like HelperContainerE2ETests's own apply_edit proof.
        // Concrete assertions: pairing completes (both sides show each other in
        // PairedDeviceStore/DeviceAnnounceRecord), the signaling handshake succeeds, and the MCP
        // round trip lands — same "host Source/ actually changed" proof style as the P1
        // persistence E2E test, reused rather than re-invented.
    }
}
```

This is deliberately the plan's other explicitly-left-for-implementation-time detail (alongside Task 5 Step 1 and Task 8 Step 2): the exact sequencing of "spawn helper → play phone → wait for pairing → open signed channel → MCP round trip" depends on API shapes Tasks 5/6/9 settle during implementation, not guessable in advance — same posture the P1 plan's own Task 8 took for its MCP tool-call payload.

- [ ] **Step 2: Run the exit criterion**

```bash
ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 ANGLESITE_P2P_E2E=1 ANGLESITE_CK_TESTS=1 \
  swift test --filter CloudKitPairingE2ETests
```

Expected: PASS. This is P2's exit criterion: **two Mac processes pair (via simulated-QR + real CloudKit) and complete a signed, cross-network signaling handshake plus a live MCP round trip.**

- [ ] **Step 3: Full-suite check**

```bash
swift test --package-path .
```

All green; every gated suite skips cleanly without its env vars.

- [ ] **Step 4: Commit**

```bash
git add Tests/AnglesiteRemoteTests/HelperContainerE2ETests.swift
git commit -m "feat(#1208): P2 exit-criterion E2E — two Mac processes pair over CloudKit"
```

---

### Task 11: PR

- [ ] **Step 1:** Re-read `CONTRIBUTING.md` ▸ "Commits and pull requests"; build the PR body from `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings. Reference `Part of #1208`. Note the entitlement/portal dependency (Task 9 Step 3) explicitly, mirroring how the P1 PR flagged its App-Groups gap.
- [ ] **Step 2:** Push and `gh pr create`; verify CI, paying particular attention to the Linux portable-target build — every new file in this plan that guards on `canImport(CryptoKit)`/`canImport(CloudKit)`/`canImport(AppKit)` needs to actually compile on Linux (where all three are absent), not just look correct on macOS (this epic already hit exactly this failure mode once — see Global Constraints).

## Self-Review Notes

- **Spec coverage:** all seven design-spec components have a task (helper lifecycle: Task 1; keypair: Task 2; device store: Task 3; signed decorator + adversarial tests: Task 4; pairing service + push registration: Task 5; signaling channel: Task 6; presence heartbeat: Task 7; Settings UI: Task 8; production wiring + entitlement note: Task 9; exit criterion: Task 10). The three owner-approved scope decisions (two-Mac exit criterion, NSApplication fix in-scope, presence heartbeat in-scope, shared CloudKit container, decorator signing architecture) are all reflected in the corresponding tasks, not just the design doc.
- **Known gaps flagged inline, not hidden:** the CloudKit API's exact shape (Task 5 Step 1), the Settings UI's exact SwiftUI body (Task 8 Step 2), and the exit-criterion E2E's exact sequencing (Task 10 Step 1) are the plan's three deliberately-left-for-implementation-time details — each is called out explicitly with a reason, not silently guessed, matching this repo's established precedent (P1's plan left its MCP tool-call payload the same way). The entitlement/portal dependency (Task 9) is documented exactly like P1's own App-Groups gap, not treated as a blocker on writing/testing the surrounding code.
- **Type consistency check:** `DevicePairingKeyPair.publicKeyData`'s X9.63 format is used identically by `PairedDevice.pinnedPublicKey`, `SignedSignalingChannel`'s verify calls, and `CloudKitPairingService.DeviceAnnounceRecord.publicKeyData` — no format mismatch across tasks. `SignalingChannel`'s three-method protocol (verified against the real `Sources/AnglesiteP2P/Signaling.swift` in this checkout, not assumed) is satisfied identically by `SignedSignalingChannel` (Task 4) and `CloudKitSignalingChannel` (Task 6), so either can wrap or be wrapped without the other knowing. `PairedDeviceStore`'s `device(deviceID:)` lookup (Task 3) is the seam Task 9's "refuse unknown device" step depends on — confirmed present before Task 9 needs it.
