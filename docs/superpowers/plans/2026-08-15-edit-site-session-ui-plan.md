# "Edit Site" P2P Session UI (#1431) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the iOS/iPadOS v2.0 "Edit Site" session UI (design spec `docs/superpowers/specs/2026-08-12-ios-ipados-v2-design.md` §3): entry points in `SiteSplitScreen`, a full-screen-cover session screen with owner-comprehensible state rendering, the QR pairing-onboarding walk-in, and the preview leg — all consuming a `SiteRuntime` behind an injectable seam so #1208 P4's real `P2PSiteRuntime` plugs in with a one-closure swap.

**Architecture:** New portable models in `AnglesiteIOS` (`EditSessionModel`, `PairingOnboardingModel`, `EditSessionRouter`) tested by `AnglesiteIOSTests` under `swift test`; SwiftUI views in the `AnglesiteMobile` app target (`EditSiteScreen`, `PairingOnboardingScreen`, `QRScannerView`); a shared `DevicePairingPayload` wire type in `AnglesiteCore` single-sourcing the QR format the Mac already encodes; an `EditSiteIntent` in `AnglesiteIntents` routing through the router (the `WindowRouter` pattern). The production runtime factory returns a `PendingP2PSiteRuntime` that settles `.failed` with an honest message — #1208 P4 replaces exactly that factory closure with the real WebRTC-backed `P2PSiteRuntime`.

**Tech Stack:** Swift 6.4 / SwiftUI, Swift Testing (`@Test`/`#expect`), AVFoundation (QR capture), AppIntents.

## Global Constraints

- macOS 27+ / Xcode 27+, `swift test` needs `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (memory: default toolchain broken).
- Apple frameworks only; no new dependencies.
- Session-state copy must never say ICE/SDP/WebRTC — owner language only (spec §3).
- Strings user-visible in the app target must be `String(localized:)`/SwiftUI literals; after CLI builds run the `xcstringstool sync` recipe from CONTRIBUTING.md scoped to THIS worktree's BUILD_DIR, `--skip-marking-strings-stale`.
- Conventional commits, subject ≤72 chars, reference #1431.
- PR body must use `.github/PULL_REQUEST_TEMPLATE.md` headings: Summary, Paired PR check, Test plan. No MCP schema change → no paired PR.
- `AnglesiteMobile` links AnglesiteCore, AnglesiteBridge, AnglesiteIntents, AnglesiteIOS — NOT AnglesiteP2P; do not add it (P4's decision).
- Run `swift test --package-path .` serially (memory: concurrent runs cause FM-suite contention).

---

### Task 1: Shared pairing-payload wire type

**Files:**
- Create: `Sources/AnglesiteCore/DevicePairingPayload.swift`
- Modify: `Sources/AnglesiteApp/DevicePairingSettingsView.swift:183` (replace private `PairingQRPayload` with the shared type)
- Test: `Tests/AnglesiteCoreTests/DevicePairingPayloadTests.swift`

**Interfaces:**
- Produces: `public struct DevicePairingPayload: Codable, Sendable, Equatable { public let deviceID: String; public let publicKey: Data; public init(deviceID: String, publicKey: Data); public func encodedJSON() throws -> Data; public static func decode(from string: String) throws -> DevicePairingPayload }`
- `decode(from:)` throws `DevicePairingPayload.DecodeError.notAPairingCode` for anything that isn't this JSON shape or has an empty `deviceID`/`publicKey`.

- [ ] Step 1: Write failing tests in `Tests/AnglesiteCoreTests/DevicePairingPayloadTests.swift` (Swift Testing): round-trip encode→decode equality; decode rejects non-JSON (`"hello"`), JSON of wrong shape (`{"a":1}`), and empty `deviceID` — each throwing `.notAPairingCode`. Wire format check: encoded JSON's `publicKey` is base64 (JSONEncoder default `Data` strategy, matching the Mac's existing `PairingQRPayload` doc).
- [ ] Step 2: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter DevicePairingPayload` → FAIL (type not found).
- [ ] Step 3: Implement `DevicePairingPayload` in AnglesiteCore with doc comment noting it single-sources the QR wire shape (field names match `DeviceAnnounceRecord`: `deviceID`, `publicKey`).
- [ ] Step 4: Refactor `DevicePairingSettingsView` to encode `DevicePairingPayload` instead of its private struct; delete the private struct, keep its doc comment content on the shared type.
- [ ] Step 5: `swift test --filter DevicePairingPayload` → PASS; `swift build` (whole package compiles, AnglesiteAppCore included).
- [ ] Step 6: Commit `feat(#1431): shared DevicePairingPayload QR wire type`.

### Task 2: PairingOnboardingModel

**Files:**
- Create: `Sources/AnglesiteIOS/PairingOnboardingModel.swift`
- Test: `Tests/AnglesiteIOSTests/PairingOnboardingModelTests.swift`

**Interfaces:**
- Consumes: `DevicePairingPayload` (Task 1), `PairedDevice`/`PairedDeviceStore` (AnglesiteCore).
- Produces:
```swift
@MainActor @Observable public final class PairingOnboardingModel {
    public enum Step: Equatable { case explainer, cameraDenied, scanning, failed(message: String), done }
    public private(set) var step: Step  // starts .explainer
    public init(requestCameraAccess: @escaping () async -> Bool,
                storeDevice: @escaping (PairedDevice) throws -> Void)
    public func beginScan() async   // explainer/denied/failed → scanning, or cameraDenied
    public func handleScanned(_ code: String)  // scanning → done | failed
    public func retry()             // failed → explainer
}
```
- `handleScanned` decodes via `DevicePairingPayload.decode(from:)`, builds `PairedDevice(deviceID: payload.deviceID, displayName: String(localized: "My Mac"), pinnedPublicKey: payload.publicKey, pairedAt: .now)`, calls `storeDevice`, sets `.done`. Decode failure → `.failed(message: String(localized: "That code isn't an Anglesite pairing code. Show the code in Anglesite's settings on your Mac and try again."))`. Store failure → `.failed` with `String(localized: "Couldn't save the pairing on this device. Try again.")`. Only acts while `.scanning` (camera keeps emitting frames; first result wins).

- [ ] Step 1: Failing tests: granted access → `.scanning`; denied → `.cameraDenied`; valid payload string → stored device fields match payload + `.done`; garbage string → `.failed`; second `handleScanned` after `.done` is ignored; `storeDevice` throwing → `.failed`; `retry()` → `.explainer`.
- [ ] Step 2: `swift test --filter PairingOnboardingModel` → FAIL.
- [ ] Step 3: Implement; Step 4: tests PASS.
- [ ] Step 5: Commit `feat(#1431): pairing onboarding model for iOS QR walk-in`.

### Task 3: EditSessionModel + FakeP2PSiteRuntime

**Files:**
- Create: `Sources/AnglesiteIOS/EditSessionModel.swift`
- Test: `Tests/AnglesiteIOSTests/EditSessionModelTests.swift` (includes `FakeP2PSiteRuntime`)

**Interfaces:**
- Consumes: `SiteRuntime`, `SiteRuntimeState`, `MCPClient`, `ProcessSupervisor` (AnglesiteCore); `PreviewAnnotationProvider`(+Registry) (AnglesiteIntents) — NO: AnglesiteIOS must not depend on AnglesiteIntents (it's the other way round). Annotation-provider wiring stays in the view layer exactly like `RemoteSessionScreen` does today; the model only exposes `mcpClient`.
- Produces:
```swift
@MainActor @Observable public final class EditSessionModel {
    public enum Phase: Equatable {
        case pairingRequired, waking, starting, ready(URL), failed(message: String), idle
    }
    public let siteID: UUID
    public let siteDisplayName: String
    public private(set) var phase: Phase          // starts .idle
    public private(set) var mcpClient: MCPClient? // set while a session runs
    public init(siteID: UUID, siteDisplayName: String,
                pairedMacs: @escaping () throws -> [PairedDevice],
                makeRuntime: @escaping @MainActor () -> any SiteRuntime,
                lastMacContact: @escaping @Sendable () async -> Date? = { nil })
    public func open() async      // pairing gate → start-or-reuse warm runtime
    public func completePairing() async  // re-check store, then start
    public func stop() async      // ends runtime; phase .idle; mcpClient nil
    public var isSessionActive: Bool   // runtime exists and phase != .idle/.pairingRequired
}
```
- Semantics: `open()` with no paired Mac (or store throw) → `.pairingRequired`, runtime never built. With a paired Mac: builds runtime once (reuse on later `open()` — cover dismissal never stops it; that's the "warm session" contract, spec §3), sets `.waking`, subscribes `runtime.observe()`, maps states: `.starting` → `.starting`; `.ready(_, url, _)` → `.ready(url)`; `.failed(_, message)` → `.failed(message: composedFailureMessage(message))`; `.idle` → `.idle`. `mcpClient` set from `await runtime.mcpClient` when the runtime is created.
- `composedFailureMessage(_:)`: runtime's owner-facing message, plus — when `lastMacContact()` returns a date — a second sentence `"Your Mac was last reachable at \(date.formatted(date: .omitted, time: .shortened))."` (same-day) or `date.formatted(.dateTime.month().day().hour().minute())` otherwise; tests pin dates and compare against the same `formatted` API so locale never breaks CI.
- Superseded-site protection: observation task is owned by the model; `stop()` cancels it before `runtime.stop()` so a late emission can't resurrect the phase (same guard `RemoteSessionModel.stop()` uses).

- [ ] Step 1: Write `FakeP2PSiteRuntime`:
```swift
actor FakeP2PSiteRuntime: SiteRuntime {
    let mcpClient = MCPClient(supervisor: ProcessSupervisor())
    private let stateMachine = SiteRuntimeStateMachine()
    private(set) var startCalls: [String] = []
    private(set) var stopCount = 0
    private let script: [SiteRuntimeState]  // states start() settles through
    init(script: [SiteRuntimeState]) { self.script = script }
    func start(siteID: String, siteDirectory: URL) async {
        startCalls.append(siteID)
        let gen = stateMachine.beginStarting(siteID: siteID)
        for state in script { stateMachine.settle(gen: gen, to: state) }
    }
    func stop() async { stopCount += 1; stateMachine.settle(gen: stateMachine.beginAttempt(), to: .idle) }
    func observe() -> AsyncStream<SiteRuntimeState> { stateMachine.observe() }
}
```
  Failing tests: (a) unpaired → `open()` settles `.pairingRequired`, `makeRuntime` never called; (b) paired + script `[.ready]` → phase becomes `.ready(url)` and `mcpClient != nil`; (c) paired + script `[.failed(message:)]` + `lastMacContact` fixed date → `.failed` message contains both the runtime message and the formatted time; (d) second `open()` reuses the runtime (`makeRuntime` call count 1, fake `startCalls.count` 1) — the warm-session contract; (e) `stop()` → fake `stopCount == 1`, phase `.idle`, `mcpClient == nil`; `open()` after stop builds a fresh runtime; (f) `completePairing()` when the store now has a Mac → session starts. Await phase changes by polling with a bounded `for _ in 0..<N { if … break }; await Task.yield()` loop (existing AnglesiteIOSTests pattern) — no wall-clock sleeps (memory: `Task.sleep(.zero)` CI crash; avoid zero-duration sleeps).
- [ ] Step 2: `swift test --filter EditSessionModel` → FAIL.
- [ ] Step 3: Implement; Step 4: PASS.
- [ ] Step 5: Commit `feat(#1431): EditSessionModel over the SiteRuntime seam`.

### Task 4: EditSessionRouter + EditSiteIntent

**Files:**
- Create: `Sources/AnglesiteIOS/EditSessionRouter.swift`
- Create: `Sources/AnglesiteIntents/EditSiteIntent.swift`
- Test: `Tests/AnglesiteIOSTests/EditSessionRouterTests.swift`

**Interfaces:**
- Produces:
```swift
@MainActor @Observable public final class EditSessionRouter {
    public static let shared = EditSessionRouter()
    public internal(set) init …  // private init; test hook: public init() is fine — WindowRouter uses a singleton with private init; mirror it but keep a package-visible init for tests via @testable import
    public private(set) var requestedSiteID: UUID?
    public func requestEditSession(siteID: UUID)
    public func consume() -> UUID?   // returns and clears
}
```
- `EditSiteIntent` (whole file wrapped `#if os(iOS)`): `public struct EditSiteIntent: AppIntent` — title "Edit Site", description "Open a site's live preview for editing.", `openAppWhenRun = true`, `@Parameter(title: "Site") var site: SiteEntity`, `parameterSummary` "Edit \(\.$site)", `@MainActor perform()` → `EditSessionRouter.shared.requestEditSession(siteID: site.id)` then `.result(dialog: "Opening \(site.displayName) for editing.")`. (`SiteEntity.id` is the package UUID on iOS via `SiteEntityQueryIOS` — the spec's "sites named by stable package UUID".) Note: plain `AppIntent`, not `OpenIntent` — `OpenSiteIntent` already owns the open-verb entity action on macOS; this is a distinct verb.
- [ ] Step 1: Failing router tests (`@testable import AnglesiteIOS`, instantiate a fresh router): request sets `requestedSiteID`; `consume()` returns it and clears; second `consume()` → nil; last request wins.
- [ ] Step 2: FAIL run. Step 3: implement both files. Step 4: `swift test --filter EditSessionRouter` PASS and `swift build` compiles AnglesiteIntents on macOS (the `#if os(iOS)` gate makes the intent a no-op there).
- [ ] Step 5: Commit `feat(#1431): Edit Site intent + session router`.

### Task 5: Mobile views — scanner, onboarding, session screen, placeholder runtime

**Files:**
- Create: `Sources/AnglesiteMobile/QRScannerView.swift`
- Create: `Sources/AnglesiteMobile/PairingOnboardingScreen.swift`
- Create: `Sources/AnglesiteMobile/EditSiteScreen.swift`
- Create: `Sources/AnglesiteIOS/PendingP2PSiteRuntime.swift`
- Modify: `Resources/Info-iOS.plist` (add `NSCameraUsageDescription`)

**Interfaces:**
- Consumes: Tasks 2–3 models; `RemotePreviewWebView` (AnglesiteIOS), `WebViewBridge.localDevConfiguration`, `AnglesiteScriptHandler`, `MCPApplyEditRouter` (AnglesiteBridge), `PreviewAnnotationProvider`/`Registry` + `appEntityUIElementProvider` gated `#if compiler(>=6.4)` (AnglesiteIntents) — copy the composition from `RemoteSessionScreen.RemoteSandboxPreview` minus the session-token cookie injection (spec §3: DTLS replaces bearer auth; `prepareBeforeLoad` is omitted entirely).
- Produces:
  - `struct QRScannerView: UIViewControllerRepresentable { let onCode: (String) -> Void }` — AVCaptureSession + `AVCaptureMetadataOutput` (`.qr`), session started/stopped on a private queue in `makeUIViewController`/`dismantleUIViewController`, delegate forwards the first string payload to `onCode` on the main queue and ignores the rest.
  - `struct PairingOnboardingScreen: View { let model: PairingOnboardingModel; var onPaired: () -> Void }` — switches `model.step`: `.explainer` → `ContentUnavailableView` ("Pair Your Mac", systemImage "qrcode.viewfinder", description: "Editing your site happens through your Mac. In Anglesite on your Mac, open Settings → Devices, then scan the pairing code shown there." action Button "Scan Pairing Code" → `Task { await model.beginScan() }`); `.cameraDenied` → explainer text + "Open Settings" button (`UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)`) — the honest no-dead-end (spec §3); `.scanning` → `QRScannerView { model.handleScanned($0) }` full-bleed with a Cancel toolbar reverting to `.explainer` via `model.retry()`; `.failed` → message + "Try Again" (`model.retry()` then `beginScan()`); `.done` → `onPaired()` fired from `.onChange(of: model.step)`.
  - `struct EditSiteScreen: View { @Bindable var model: EditSessionModel }` + `@Environment(\.dismiss)`. `NavigationStack`; `.navigationTitle(model.siteDisplayName)`, inline. Toolbar: `.topBarLeading` Done button (plain `dismiss()` — suspends UI, session stays warm); `.topBarTrailing` Stop (`Label("Stop", systemImage: "stop.circle")`, shown when `model.isSessionActive`) → `Task { await model.stop(); dismiss() }`. Body by `model.phase`: `.pairingRequired` → `PairingOnboardingScreen(model: pairingModel) { Task { await model.completePairing() } }` (pairing model built in this view with production deps: `AVCaptureDevice.requestAccess(for: .video)` + `PairedDeviceStore().add`); `.waking` → ProgressView + `Text("Waking your Mac…")`; `.starting` → ProgressView + `Text("Starting your site…")`; `.ready(let url)` → `P2PSessionPreview(url: url, model: model)` ignoring bottom safe area; `.failed(let message)` → `ContentUnavailableView` "Couldn't Reach Your Site" + message + "Try Again" (`Task { await model.open() }`); `.idle` → ProgressView (transient). `.task { await model.open() }` so presenting the cover starts/resumes the session. Private `P2PSessionPreview` mirrors `RemoteSandboxPreview` (script handler + apply-edit router over `model.mcpClient`, annotation provider registered per siteID in this view, `#if compiler(>=6.4)` gate) with no cookie step.
  - `PendingP2PSiteRuntime` (AnglesiteIOS): actor conforming to `SiteRuntime`; `start` settles `.failed(siteID:, message: String(localized: "Editing from this device isn't available yet — a future update connects it to Anglesite on your Mac."))` via its own `SiteRuntimeStateMachine`; `let mcpClient = MCPClient(supervisor: ProcessSupervisor())`; doc comment: "#1208 P4 replaces the factory that builds this with the real P2PSiteRuntime."
- [ ] Step 1: Implement all files (view layer — no unit harness; `AnglesiteMobile` isn't a SwiftPM target).
- [ ] Step 2: Add `NSCameraUsageDescription` = "Anglesite uses the camera to scan the pairing code shown on your Mac." to `Resources/Info-iOS.plist`.
- [ ] Step 3: Build: `xcodegen generate && scripts/build-app.sh -project Anglesite.xcodeproj -scheme AnglesiteMobile -configuration Debug -destination 'generic/platform=iOS Simulator' build` → succeeds.
- [ ] Step 4: Commit `feat(#1431): Edit Site cover, pairing onboarding, QR scanner views`.

### Task 6: SiteSplitScreen entry points + router observation

**Files:**
- Modify: `Sources/AnglesiteMobile/SiteSplitScreen.swift`

**Interfaces:** Consumes Tasks 3–5. Produces the user-reachable feature.

- [ ] Step 1: Add state: `@State private var editSessions: [UUID: EditSessionModel] = [:]`, `@State private var editingSite: SitePickerModel.DiscoveredSite?`. Add `editSessionModel(for site:)` create-or-reuse helper wiring production deps: `pairedMacs: { try PairedDeviceStore().load() }`, `makeRuntime: { PendingP2PSiteRuntime() }` (comment: #1208 P4 swaps in the real `P2PSiteRuntime`), default `lastMacContact`. The dict (not the cover) owns the models — dismissing the cover keeps the session warm; switching sites never tears down another site's session.
- [ ] Step 2: Entry points (spec §3): content pane toolbar `ToolbarItem(placement: .secondaryAction)` Button `Label("Edit Site", systemImage: "paintbrush.pointed")` → `editingSite = site` (added alongside the existing site-switcher item, available in both `.signedOut` and `.ready` session states — editing needs pairing, not Micropub sign-in); sidebar site row `.contextMenu { Button("Edit Site", …) }` with the same action; `.fullScreenCover(item: $editingSite) { site in EditSiteScreen(model: editSessionModel(for: site)) }` (`DiscoveredSite` already `Identifiable`).
- [ ] Step 3: Router observation: `.task` loop or `.onChange` — poll pattern used by Mac scenes: add `.task { for await _ in … }` is overkill; use `.onAppear` + `.onChange(of: EditSessionRouter.shared.requestedSiteID)`: on non-nil, `consume()`, look up the site in `sitePicker.state`, `selectSite(it)`, set `editingSite`. (Observable singleton read inside `body` makes `.onChange` fire — same mechanism `WindowRouter` relies on Mac-side.)
- [ ] Step 4: Rebuild AnglesiteMobile (same command as Task 5) → succeeds. Run full `swift test --package-path .` (portable targets untouched by this task but the suite is the pre-push gate).
- [ ] Step 5: Localization catalog: run the CONTRIBUTING.md `xcstringstool sync` recipe against this worktree's own BUILD_DIR for the **AnglesiteMobile** scheme, `--skip-marking-strings-stale`; review the `Sources/AnglesiteMobile/Localizable.xcstrings` diff contains only this feature's keys; include it in the commit.
- [ ] Step 6: Commit `feat(#1431): Edit Site entry points + session cover in shell`.

### Task 7: Verification + PR

- [ ] Step 1: Full gates: `DEVELOPER_DIR=… swift test --package-path .` (all suites); `scripts/build-app.sh … -scheme Anglesite -configuration Debug build` (Mac app still compiles — Task 1 touched `DevicePairingSettingsView`); AnglesiteMobile sim build.
- [ ] Step 2: Re-read the diff against CONTRIBUTING.md (comment style, no stray formatting churn); verify no string mentions ICE/SDP/WebRTC.
- [ ] Step 3: Push branch, open PR: title `feat(#1431): "Edit Site" P2P session UI in SiteSplitScreen`, body from `.github/PULL_REQUEST_TEMPLATE.md` with `Closes #1431`, Paired PR check = not needed (no MCP schema change; template untouched), Test plan = commands above + note that the live P2P leg lands in #1208 P4 behind the factory seam and QR scanning needs Mac-hardware manual QA. Note the follow-ups this unblocks (#1432, #1433, #1435, #1436).

## Self-review

- Spec coverage: entry points (Task 6), cover + suspend/stop semantics (Tasks 3/5/6), owner-comprehensible states incl. last-reachable (Task 3), preview-leg reuse minus cookie (Task 5), pairing walk-in with in-context camera permission + honest dead-end handling (Tasks 2/5), package-UUID site identity (Tasks 3/4/6 — UUID keys throughout), App Intent (Task 4). "Waking your Mac…" appears pre-first-state; finer "Starting your site…" granularity arrives with the real runtime's state stream (P4) — rendering is in place now.
- Types cross-checked: `EditSessionModel.Phase`, `FakeP2PSiteRuntime` uses `SiteRuntimeStateMachine` exactly as `RemoteSandboxSiteRuntime` does; `MCPClient(supervisor: ProcessSupervisor())` matches `RemoteSessionModel`.
- Known deliberate deferrals: real `P2PSiteRuntime`, presence reader (`lastMacContact` production impl), publish leg — #1208 P4/P5, #1432.
